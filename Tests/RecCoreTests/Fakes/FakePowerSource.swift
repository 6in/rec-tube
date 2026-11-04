// FakePowerSource — テスト用の `PowerSource`。`PowerWatcher` の「ack を返さない経路が無い」を数で確かめる。
//
// 方針（`FakeHAL` と同じ）:
//   - **呼び出しを順番に記録する**（`log`）。ack が「どのメッセージに」返ったかまで控える
//     （`WillSleep` と `CanSleep` に各 1 回、`HasPoweredOn` に 0 回、を 1 つの断言で見たい）
//   - **任意の通知を流せる**（`send`）。実機のスリープはテストから起こせないので、ここが唯一の刺激口
//   - **`register` を失敗させられる**（`registerError`）
//   - **本物のロックを持つ**（NSLock）。通知は `register` で渡されたキュー上で配るので、
//     記録の読み出しはテストのスレッドと別スレッドから同時に来る
//   - **本物の「登録が解けたら ack は届かない」制約を持つ**（F4 / E20）。`IOKitPowerSource.acknowledge`
//     は `guard connect != 0 else { return }` で、`unregister`（`rootPort = 0` / `IOServiceClose`）の
//     後に呼ばれた ack を**捨てる**。fake がこれを再現していなかったため、「スリープ経路で
//     `IOAllowPowerChange` が呼ばれない」回帰が E11 のテストに映らなかった。
//     そこで `unregister` 後（または `register` 前）の ack は `log` に**記録せず**、
//     `droppedAcknowledges` に数える。`log` / `acknowledgeCount` に残るのは**有効な ack だけ**
//
// `send` は **`register` で渡されたキューに `async` で載せる**（直列キューなら送った順に届く）。
// 本物（`IONotificationPortSetDispatchQueue`）と同じく「handler は queue 上で呼ばれる」を再現するため。
// 届くのを待つ側は無限待ちにしない（テスト側の `waitUntil` が最大 2 秒）。

import Foundation

@testable import RecCore

final class FakePowerSource: PowerSource, @unchecked Sendable {
    /// 記録する呼び出し。ack はどのメッセージに返したかも持つ。
    enum Call: Equatable, Sendable {
        case register
        case unregister
        case acknowledge(messageType: UInt32, argument: UInt)
    }

    // MARK: - 設定（register の前に入れる）

    /// 非 nil なら `register` がこれを throw する。
    var registerError: Error?

    // MARK: - 記録

    /// handler を `DispatchQueue.async`（`@Sendable` クロージャ）に渡すための箱。
    ///
    /// `PowerSource.register` の handler は `@Sendable` ではない（本物は C コールバックから直に呼ぶので
    /// 要らない）。そのまま `queue.async { handler(…) }` と書くと Swift 6 が
    /// 「non-Sendable を `@Sendable` クロージャが捕まえた」と警告するので、箱に入れて渡す。
    /// 中身は `register` で受けた 1 個を持つだけで誰も書き換えない（`@unchecked Sendable`）。
    private final class HandlerBox: @unchecked Sendable {
        let call: (PowerNotification) -> Void
        init(_ call: @escaping (PowerNotification) -> Void) { self.call = call }
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var queue: DispatchQueue?
    private var handler: HandlerBox?
    private var droppedAcks = 0

    /// 呼ばれた順の一覧。**有効な ack だけ**が入る（登録が解けた後の ack は `droppedAcknowledges`）。
    var log: [Call] { lock.withLock { calls } }
    /// 登録が解けた後（または `register` の前）に呼ばれて捨てられた ack の回数。
    ///
    /// 本物では `IOAllowPowerChange` が呼ばれないので、システムのスリープが最大 30 秒ブロックされる。
    /// つまりこれが 1 以上なら「ack を返さない経路」がある。
    var droppedAcknowledges: Int { lock.withLock { droppedAcks } }
    /// `log` のうち `call` の件数。
    func count(_ call: Call) -> Int { lock.withLock { calls.filter { $0 == call }.count } }
    /// `messageType` に ack を返した回数。
    func acknowledgeCount(messageType: UInt32) -> Int {
        lock.withLock {
            calls.filter {
                if case let .acknowledge(type, _) = $0 { return type == messageType }
                return false
            }.count
        }
    }

    /// `register` が成功していて、まだ `unregister` されていない。
    var isRegistered: Bool { lock.withLock { handler != nil } }

    // MARK: - テストからの刺激

    /// 通知 1 件を流す（登録されたキュー上で非同期に配る）。戻り値は配れたかどうか。
    @discardableResult
    func send(messageType: UInt32, argument: UInt) -> Bool {
        let (handler, queue) = lock.withLock { (self.handler, self.queue) }
        guard let handler, let queue else { return false }
        let notification = PowerNotification(messageType: messageType, argument: argument)
        queue.async { handler.call(notification) }
        return true
    }

    // MARK: - PowerSource

    func register(queue: DispatchQueue, handler: @escaping (PowerNotification) -> Void) throws {
        lock.withLock { calls.append(.register) }
        if let registerError {
            throw registerError
        }
        lock.withLock {
            self.queue = queue
            self.handler = HandlerBox(handler)
        }
    }

    func unregister() {
        lock.withLock {
            calls.append(.unregister)
            queue = nil
            handler = nil
        }
    }

    func acknowledge(_ notification: PowerNotification) {
        lock.withLock {
            // 本物と同じ: 登録が解けていたら ack は届かない（`guard connect != 0`）。
            guard handler != nil else {
                droppedAcks += 1
                return
            }
            calls.append(.acknowledge(messageType: notification.messageType,
                                      argument: notification.argument))
        }
    }
}
