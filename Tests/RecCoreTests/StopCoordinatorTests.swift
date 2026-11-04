// StopCoordinator のユニットテスト。
//
// 確かめる契約（PLAN T6「完了基準」の 1 本目 + T5 turn 7 の申し送り (3)）:
//   1. `request(_:)` は最初の 1 回だけ `true`。2 回目以降は理由が何であれ `false`
//   2. `reason` は最初に受け付けた理由のまま変わらない（後から来た理由で上書きしない）。
//      `request` 前は `nil`
//   3. 10 スレッドから**別々の理由**で同時に `request` → `true` は**ちょうど 1 つ**、
//      `reason` は 1 つに確定し、`onFirstRequest` は**その理由で 1 回だけ**呼ばれる
//   4. `onFirstRequest` は**呼び出し元のスレッドでは走らない**。init で渡したセッションキュー上で
//      非同期に走る（IO キューから `request` を呼んだときに `TapRecorder.stop()` の
//      `ioQueue.sync {}` で自己デッドロックしないための要件）
//   5. `claim(_:)` は先勝ちで最初の 1 回だけ `true`。`reason` は上書きせず、**ハンドラを呼ばない・
//      dispatch もしない**。`claim` のあとの `request` は `false` でハンドラも走らない
//      （スリープで ack より前に `writer.close()` を終わらせるための受付口。E11）
//
// 書き方の約束:
//   - `onFirstRequest` は別キューから呼ばれるので、受け取り側は NSLock で守った箱（`CallLog`）に貯める
//   - 「同期的に呼ばれない」は**セッションキューをセマフォで塞いでおく**ことで決定的に見る
//     （`Thread.sleep` で「たぶん走っていない」を見るのではなく、走れない状況を作る）
//   - ハンドラがどのキュー上に居るかは `DispatchSpecificKey` で見る
//   - 別キューの到着を待つ場所だけ `waitUntil`（最大 2 秒のポーリング）を使う

import Foundation
import Testing

@testable import RecCore

@Suite("StopCoordinator")
struct StopCoordinatorTests {
    // MARK: - 受け取り側の箱

    /// `onFirstRequest` の呼び出しを記録する箱（別キューから呼ばれるのでロックで守る）。
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [StopReason] = []
        private var labels: [String?] = []

        /// ハンドラから呼ぶ。`label` は「走っているキューの目印」。
        func record(_ reason: StopReason, label: String?) {
            lock.lock()
            defer { lock.unlock() }
            reasons.append(reason)
            labels.append(label)
        }

        var count: Int { lock.withLock { reasons.count } }
        var allReasons: [StopReason] { lock.withLock { reasons } }
        var allLabels: [String?] { lock.withLock { labels } }
    }

    /// `request` の戻り値を数える箱（複数スレッドから書く）。
    private final class AcceptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var accepted: [StopReason] = []

        func record(_ reason: StopReason, returned: Bool) {
            guard returned else { return }
            lock.lock()
            defer { lock.unlock() }
            accepted.append(reason)
        }

        var acceptedReasons: [StopReason] { lock.withLock { accepted } }
    }

    // MARK: - 補助

    /// 10 スレッドから投げる「別々の理由」。`StopReason` の代表を 10 個並べた。
    private static let distinctReasons: [StopReason] = [
        .ended, .nextVideo, .liveStream, .permissionSuspected, .deviceChanged,
        .sleep, .serviceRestarted, .ioStopped, .deviceDied, .signal(SIGUSR1),
    ]

    /// `condition` が true になるまで最大 `timeout` 秒待つ（別キューの到着を待つ場所だけで使う）。
    private func waitUntil(timeout: Double = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    // MARK: - 1 / 2. 最初の 1 回だけ true、理由は上書きしない

    @Test("request は最初の 1 回だけ true を返し、reason は後から来た理由で上書きされない")
    func firstRequestWinsAndReasonNeverChanges() {
        let session = DispatchQueue(label: "test.stop.session.first")
        let calls = CallLog()
        let coordinator = StopCoordinator(queue: session) { reason in
            calls.record(reason, label: nil)
        }

        #expect(coordinator.reason == nil, "request 前の reason は nil のはず")

        #expect(coordinator.request(.sleep), "1 回目は true のはず")
        #expect(coordinator.reason == .sleep)

        // 2 回目以降は理由が何であれ false。
        #expect(coordinator.request(.ended) == false, "2 回目は false のはず")
        #expect(coordinator.request(.signal(SIGINT)) == false, "3 回目も false のはず")
        #expect(coordinator.request(.sleep) == false, "同じ理由の再要求も false のはず")

        #expect(coordinator.reason == .sleep, "reason は最初の理由のまま: \(String(describing: coordinator.reason))")

        // ハンドラはちょうど 1 回、最初の理由で呼ばれる。
        #expect(waitUntil { calls.count == 1 }, "onFirstRequest が 1 回呼ばれていない: \(calls.count) 回")
        #expect(calls.allReasons == [.sleep])

        // 念のため、しばらく待っても増えない。
        Thread.sleep(forTimeInterval: 0.1)
        #expect(calls.count == 1, "onFirstRequest が 2 回以上呼ばれた: \(calls.allReasons)")
    }

    // MARK: - 3. 10 スレッドから別々の理由で同時に

    @Test("10 スレッドから別々の理由で同時に request → true はちょうど 1 つで reason と一致する")
    func concurrentRequestsElectExactlyOneReason() throws {
        let session = DispatchQueue(label: "test.stop.session.race")
        let calls = CallLog()
        let coordinator = StopCoordinator(queue: session) { reason in
            calls.record(reason, label: nil)
        }
        let accepts = AcceptLog()
        let reasons = Self.distinctReasons

        // できるだけ同時に投げる（全スレッドをセマフォの前で待たせ、一斉に放つ）。
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let pool = DispatchQueue(label: "test.stop.race", attributes: .concurrent)
        for index in reasons.indices {
            pool.async(group: group) {
                start.wait()
                let reason = reasons[index]
                accepts.record(reason, returned: coordinator.request(reason))
            }
        }
        for _ in reasons { start.signal() }
        #expect(group.wait(timeout: .now() + 5) == .success, "10 スレッドの request が終わらない")

        // true を返したのはちょうど 1 つ。
        let accepted = accepts.acceptedReasons
        #expect(accepted.count == 1, "true を返した request が 1 つではない: \(accepted)")
        let winner = try #require(accepted.first)

        // reason はその 1 つに確定している。
        #expect(coordinator.reason == winner, "reason が勝者と違う: \(String(describing: coordinator.reason)) / \(winner)")

        // onFirstRequest はちょうど 1 回、引数は reason と一致。
        #expect(waitUntil { calls.count == 1 }, "onFirstRequest が 1 回呼ばれていない: \(calls.count) 回")
        #expect(calls.allReasons == [winner], "onFirstRequest の引数が reason と違う: \(calls.allReasons)")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(calls.count == 1, "onFirstRequest が 2 回以上呼ばれた: \(calls.allReasons)")
    }

    // MARK: - 4. 呼び出し元では走らない / セッションキューで走る

    @Test("request を直列キュー上で呼んでも onFirstRequest はその場では走らず、セッションキューで走る")
    func handlerRunsAsynchronouslyOnSessionQueue() {
        let session = DispatchQueue(label: "test.stop.session.async")
        // 「このキュー上に居る」の目印。
        let key = DispatchSpecificKey<String>()
        session.setSpecific(key: key, value: "session")

        let calls = CallLog()
        let coordinator = StopCoordinator(queue: session) { reason in
            calls.record(reason, label: DispatchQueue.getSpecific(key: key))
        }

        // セッションキューを塞ぐ: gate を開けるまでハンドラは走れない。
        let gate = DispatchSemaphore(value: 0)
        session.async { gate.wait() }

        // 別の直列キュー（本番では IO キューに相当）から request する。
        let caller = DispatchQueue(label: "test.stop.caller")
        let (returned, callsInsideCaller) = caller.sync { () -> (Bool, Int) in
            let accepted = coordinator.request(.ioStopped)
            // ここが肝: request から戻った直後、呼び出し元のキュー上ではまだハンドラは走っていない。
            return (accepted, calls.count)
        }
        #expect(returned, "1 回目なので true のはず")
        #expect(callsInsideCaller == 0, "onFirstRequest が request の呼び出し元で同期的に走った")
        #expect(coordinator.reason == .ioStopped, "reason は request の時点で読めるはず")

        // gate を開けるとセッションキュー上で走る。
        gate.signal()
        #expect(waitUntil { calls.count == 1 }, "onFirstRequest が呼ばれていない: \(calls.count) 回")
        #expect(calls.allReasons == [.ioStopped])
        #expect(calls.allLabels == ["session"], "onFirstRequest がセッションキュー以外で走った: \(calls.allLabels)")
    }

    // MARK: - 5. claim は受け付けるだけ（ハンドラを呼ばない・dispatch しない）

    @Test("claim は最初の 1 回だけ true を返し、ハンドラを呼ばず dispatch もしない")
    func claimWinsFirstWithoutDispatchingHandler() {
        let session = DispatchQueue(label: "test.stop.session.claim")
        let calls = CallLog()
        let coordinator = StopCoordinator(queue: session) { reason in
            calls.record(reason, label: nil)
        }

        #expect(coordinator.reason == nil, "claim 前の reason は nil のはず")

        // 1 回目だけ true。
        #expect(coordinator.claim(.sleep), "1 回目の claim は true のはず")
        #expect(coordinator.reason == .sleep, "claim の時点で reason が読めるはず")

        // 2 回目以降は理由が何であれ false で、`reason` は最初のまま。
        #expect(coordinator.claim(.ended) == false, "2 回目の claim は false のはず")
        #expect(coordinator.claim(.sleep) == false, "同じ理由の再 claim も false のはず")
        #expect(coordinator.reason == .sleep,
                "reason が上書きされた: \(String(describing: coordinator.reason))")

        // `claim` のあとに `request` を呼んでも false。**ハンドラは走らない**
        // （`request` が false のときは dispatch しない契約）。
        #expect(coordinator.request(.signal(SIGINT)) == false, "claim 済みなら request は false のはず")
        #expect(coordinator.reason == .sleep, "request で reason が上書きされた")

        // セッションキューが空になるのを待ってから数える（`async` が残っていれば必ず拾える）。
        session.sync {}
        #expect(calls.count == 0, "claim でハンドラが呼ばれた: \(calls.allReasons)")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(calls.count == 0, "claim のあとでハンドラが呼ばれた: \(calls.allReasons)")
    }
}
