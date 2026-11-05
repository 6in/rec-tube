// SignalWatcher のユニットテスト。
//
// 確かめる契約（PLAN T6「完了基準」の 2 本目）:
//   1. `kill(getpid(), SIGUSR1)` → handler が**1 回**呼ばれ、引数が `SIGUSR1`
//   2. handler は init で渡した `queue` 上で呼ばれる
//   3. `cancel()` の後に再度 `kill` しても handler は増えない。しかも**プロセスが死なない**
//      （= `signal(sig, SIG_IGN)` が先に入っているので既定の処理に殺されない）
//   4. `cancel()` は冪等（2 回呼んでも何も起きない）、`deinit` だけでも監視が止まる
//
// 書き方の約束:
//   - **シグナルはプロセス全体の状態**なので `.serialized` を付け、テストごとに 1 つの watcher を使う
//   - **`SIGINT` / `SIGTERM` / `SIGHUP` は送らない**（テストランナーが死ぬ）。既定の 3 本は
//     `init` の既定引数として受け取るだけで、ここでは必ず `SIGUSR1` を明示して張る
//   - handler は別キューから呼ばれるので、受け取り側は NSLock で守った箱（`SignalLog`）に貯める
//   - 到着を待つ場所は `waitUntil`（最大 2 秒のポーリング）。「増えないこと」は 0.3 秒待って確かめる

import Foundation
import Testing

@testable import RecCore

@Suite("SignalWatcher", .serialized)
struct SignalWatcherTests {
    // MARK: - 受け取り側の箱

    /// handler の呼び出しを記録する箱（別キューから呼ばれるのでロックで守る）。
    private final class SignalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var signals: [Int32] = []
        private var labels: [String?] = []

        func record(_ sig: Int32, label: String?) {
            lock.lock()
            defer { lock.unlock() }
            signals.append(sig)
            labels.append(label)
        }

        var count: Int { lock.withLock { signals.count } }
        var allSignals: [Int32] { lock.withLock { signals } }
        var allLabels: [String?] { lock.withLock { labels } }
    }

    // MARK: - 補助

    /// `condition` が true になるまで最大 `timeout` 秒待つ（シグナルの到着を待つ）。
    private func waitUntil(timeout: Double = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// 自プロセスに SIGUSR1 を送る。
    private func raiseUSR1() {
        #expect(kill(getpid(), SIGUSR1) == 0, "kill に失敗しました: errno=\(errno)")
    }

    // MARK: - 1 / 2. 届く・指定したキューで走る

    @Test("SIGUSR1 を張って kill すると handler が 1 回だけ、指定したキュー上で呼ばれる")
    func deliversSignalOnceOnTheGivenQueue() {
        let queue = DispatchQueue(label: "test.signal.handler")
        let key = DispatchSpecificKey<String>()
        queue.setSpecific(key: key, value: "handler")

        let log = SignalLog()
        let watcher = SignalWatcher(signals: [SIGUSR1], queue: queue) { sig in
            log.record(sig, label: DispatchQueue.getSpecific(key: key))
        }
        defer { watcher.cancel() }

        raiseUSR1()

        #expect(waitUntil { log.count == 1 }, "handler が呼ばれていない: \(log.count) 回")
        #expect(log.allSignals == [SIGUSR1], "引数が SIGUSR1 ではない: \(log.allSignals)")
        #expect(log.allLabels == ["handler"], "handler が指定キュー以外で走った: \(log.allLabels)")

        // 1 回の kill で 2 回呼ばれたりしない。
        Thread.sleep(forTimeInterval: 0.3)
        #expect(log.count == 1, "handler が 2 回以上呼ばれた: \(log.allSignals)")
    }

    // MARK: - 3. cancel 後は増えない / プロセスが死なない

    @Test("cancel() の後に kill しても handler は増えず、プロセスも死なない（SIG_IGN が効いている）")
    func cancelStopsDeliveryAndSignalStaysIgnored() {
        let queue = DispatchQueue(label: "test.signal.cancel")
        let log = SignalLog()
        let watcher = SignalWatcher(signals: [SIGUSR1], queue: queue) { sig in
            log.record(sig, label: nil)
        }

        raiseUSR1()
        #expect(waitUntil { log.count == 1 }, "1 回目が届いていない: \(log.count) 回")

        watcher.cancel()
        // 冪等: 2 回目の cancel で落ちたり、何かが起きたりしない。
        watcher.cancel()

        // ここで既定の処理（= プロセス終了）に戻っていたら、この kill でテストランナーが死ぬ。
        raiseUSR1()
        Thread.sleep(forTimeInterval: 0.3)

        // この行に到達できること自体が「プロセスが死なない」の確認。
        #expect(log.count == 1, "cancel 後も handler が呼ばれた: \(log.allSignals)")
    }

    // MARK: - 4. deinit だけでも止まる

    @Test("watcher を手放す（deinit）だけでも監視が止まり、プロセスも死なない")
    func deinitStopsDelivery() {
        let queue = DispatchQueue(label: "test.signal.deinit")
        let log = SignalLog()

        do {
            let watcher = SignalWatcher(signals: [SIGUSR1], queue: queue) { sig in
                log.record(sig, label: nil)
            }
            raiseUSR1()
            #expect(waitUntil { log.count == 1 }, "1 回目が届いていない: \(log.count) 回")
            _ = watcher  // ここでスコープを抜けて deinit → cancel()
        }

        raiseUSR1()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(log.count == 1, "deinit 後も handler が呼ばれた: \(log.allSignals)")
    }
}
