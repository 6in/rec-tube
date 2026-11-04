// PowerWatcher のユニットテスト。
//
// **本物の `IOKitPowerSource` は使わない**。実機のスリープはテストから起こせないので、
// ここは `FakePowerSource` に通知を流して契約を数で確かめる（実機での確認は VERIFICATION の手動項目）。
//
// 確かめる契約（PLAN T6「ユニット（L3）」）:
//   1. `WillSleep` / `CanSleep` の**両方で必ず ack**（`IOAllowPowerChange`）を返す。ack を返さない
//      経路が 1 つも無い（返さないとシステムのスリープが最大 30 秒ブロックされる。QA1340）
//   2. ack に渡す `argument` は受けた通知の notificationID と同じ
//   3. handler が呼ばれるのは `WillSleep` の 1 回だけで、引数は `.sleep`
//      （`CanSleep` でも `HasPoweredOn` でも呼ばない）
//   4. `HasPoweredOn` では ack も handler も呼ばない
//   5. handler は `init` で渡した `queue` 上で呼ばれる
//   6. `stop()` は `unregister` を呼び、2 回呼んでも `unregister` は 1 回だけ（冪等）
//   7. `deinit` だけでも `unregister` される
//   8. `register` が throw したら `start()` は `RecError(code: .coreAudio, …)` を投げる
//
// 書き方の約束:
//   - 通知は `FakePowerSource.send` から**登録されたキューに非同期で載る**ので、断言の前に
//     `drain(queue)` でそのキューを空にする（最大 2 秒。無限待ちにしない）
//   - handler は別キューから呼ばれるので、受け取り側は NSLock で守った箱に貯める
//   - 「どのキュー上で呼ばれたか」は `DispatchSpecificKey` の目印で見る（スレッド名に頼らない）

import Foundation
import Testing

@testable import RecCore

@Suite("PowerWatcher", .serialized)
struct PowerWatcherTests {
    // MARK: - 受け取り箱（別キューから呼ばれるのでロックで守る）

    /// handler に届いた `StopReason` と、呼ばれたキューの目印を控える。
    private final class ReasonBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StopReason] = []
        private var marks: [String?] = []

        var all: [StopReason] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
        /// handler が呼ばれたキューの目印（`queueMarkKey` の値）。
        var queueMarks: [String?] { lock.withLock { marks } }

        func append(_ reason: StopReason, mark: String?) {
            lock.withLock {
                items.append(reason)
                marks.append(mark)
            }
        }
    }

    // MARK: - helpers

    /// 直列キューを作る（通知の順序を保つため直列）。`mark` を渡すとキューに目印をつける。
    ///
    /// 目印の key を型のプロパティにしないのは、`DispatchSpecificKey` が `Sendable` ではなく
    /// Swift 6 では suite（`Sendable` が要る）に持たせられないため。各テストのローカルに置く。
    private func makeQueue(_ label: String, mark key: DispatchSpecificKey<String>? = nil) -> DispatchQueue {
        let queue = DispatchQueue(label: label)
        if let key {
            queue.setSpecific(key: key, value: label)
        }
        return queue
    }

    /// `queue` に積まれた仕事が全部終わるまで待つ（最大 `timeout` 秒。無限待ちにしない）。
    @discardableResult
    private func drain(_ queue: DispatchQueue, timeout: Double = 2.0) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// `condition` が true になるまで最大 `timeout` 秒待つ（`deinit` の後始末を待つ場所だけで使う）。
    private func waitUntil(timeout: Double = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    // MARK: - ack（契約 1, 2, 4）

    @Test("スリープを許可する経路でも拒否しない経路でも必ず ack を返す（ack を呼ばない経路が無い）")
    func acknowledgesEveryPath() throws {
        let source = FakePowerSource()
        let queue = makeQueue("test.rec.power.ack")
        let box = ReasonBox()
        let watcher = PowerWatcher(source: source, queue: queue) { reason in
            box.append(reason, mark: nil)
        }
        try watcher.start()

        // 3 種類を流す。argument は ack の宛先（notificationID）が混ざらないように別の値にする。
        #expect(source.send(messageType: PowerNotification.systemWillSleep, argument: 11))
        #expect(source.send(messageType: PowerNotification.canSystemSleep, argument: 22))
        #expect(source.send(messageType: PowerNotification.systemHasPoweredOn, argument: 33))
        #expect(drain(queue), "通知の配送が 2 秒で終わりませんでした")

        // 1. WillSleep と CanSleep には ack が各 1 回
        #expect(source.acknowledgeCount(messageType: PowerNotification.systemWillSleep) == 1,
                "WillSleep に ack を返していません（スリープが 30 秒ブロックされる）: \(source.log)")
        #expect(source.acknowledgeCount(messageType: PowerNotification.canSystemSleep) == 1,
                "CanSystemSleep に ack を返していません（スリープが 30 秒ブロックされる）: \(source.log)")
        // 4. HasPoweredOn には ack を返さない
        #expect(source.acknowledgeCount(messageType: PowerNotification.systemHasPoweredOn) == 0,
                "HasPoweredOn に ack を返しています: \(source.log)")

        // 2. ack に渡す argument は受けた通知のまま
        #expect(source.count(.acknowledge(messageType: PowerNotification.systemWillSleep, argument: 11)) == 1)
        #expect(source.count(.acknowledge(messageType: PowerNotification.canSystemSleep, argument: 22)) == 1)

        watcher.stop()
    }

    @Test("handler は WillSleep の 1 回だけ呼ばれ、引数は .sleep")
    func callsHandlerOnlyForWillSleep() throws {
        let source = FakePowerSource()
        let markKey = DispatchSpecificKey<String>()
        let queue = makeQueue("test.rec.power.handler", mark: markKey)
        let box = ReasonBox()
        let watcher = PowerWatcher(source: source, queue: queue) { reason in
            box.append(reason, mark: DispatchQueue.getSpecific(key: markKey))
        }
        try watcher.start()

        source.send(messageType: PowerNotification.canSystemSleep, argument: 1)
        source.send(messageType: PowerNotification.systemHasPoweredOn, argument: 2)
        source.send(messageType: PowerNotification.systemWillSleep, argument: 3)
        #expect(drain(queue), "通知の配送が 2 秒で終わりませんでした")

        #expect(box.all == [.sleep], "handler に届いた理由が違います: \(box.all)")
        // 5. handler は init で渡した queue 上
        #expect(box.queueMarks == ["test.rec.power.handler"],
                "handler が別のキューで呼ばれました: \(box.queueMarks)")

        watcher.stop()
    }

    // MARK: - 後始末（契約 6, 7）

    @Test("stop() は unregister を呼び、2 回呼んでも unregister は 1 回だけ")
    func stopIsIdempotent() throws {
        let source = FakePowerSource()
        let queue = makeQueue("test.rec.power.stop")
        let watcher = PowerWatcher(source: source, queue: queue) { _ in }
        try watcher.start()
        #expect(source.isRegistered)

        watcher.stop()
        #expect(source.count(.unregister) == 1, "stop() で unregister が呼ばれていません: \(source.log)")
        #expect(!source.isRegistered)

        watcher.stop()
        #expect(source.count(.unregister) == 1, "stop() の 2 回目で unregister が増えました: \(source.log)")
    }

    @Test("deinit だけでも unregister される")
    func deinitUnregisters() throws {
        let source = FakePowerSource()
        let queue = makeQueue("test.rec.power.deinit")
        var watcher: PowerWatcher? = PowerWatcher(source: source, queue: queue) { _ in }
        try watcher?.start()
        #expect(source.isRegistered)

        watcher = nil
        #expect(waitUntil { source.count(.unregister) == 1 },
                "deinit で unregister が呼ばれていません: \(source.log)")
    }

    // MARK: - 登録の失敗（契約 8）

    @Test("register が失敗したら start() は RecError(.coreAudio) を投げる")
    func startFailsWithCoreAudioError() {
        let source = FakePowerSource()
        source.registerError = RecError(code: .coreAudio, message: "fake failure: register")
        let queue = makeQueue("test.rec.power.fail")
        let watcher = PowerWatcher(source: source, queue: queue) { _ in }

        do {
            try watcher.start()
            Issue.record("throw されませんでした（RecError(.coreAudio) を期待）")
        } catch let error as RecError {
            #expect(error.code == .coreAudio, "RecError.code が .coreAudio ではありません: \(error)")
        } catch {
            Issue.record("RecError 以外が throw されました: \(error)")
        }

        // 登録できていないので、後片付けで unregister を呼ぶ必要はない（呼んでも無害だが数えない）。
        #expect(!source.isRegistered)
    }
}
