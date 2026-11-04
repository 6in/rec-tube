// PowerWatcher.swift — システムのスリープ通知（IOKit 電源管理）を受けて `StopReason.sleep` を上げる。
//
// **断言（このファイルの契約）**: `kIOMessageSystemWillSleep` と `kIOMessageCanSystemSleep` の
// **どちらでも必ず `IOAllowPowerChange`（= `PowerSource.acknowledge`）を呼ぶ**。ack を返さない経路が
// 1 つでもあると、システムのスリープが最大 30 秒ブロックされる（QA1340 / RESEARCH §2.2）。
// 実装では ack を `defer` に置いて、handler がどんな経路を通っても漏れないようにしている。
//
// handler（`.sleep`）を呼ぶのは `WillSleep` のときだけ。`CanSystemSleep` は「スリープしていいか」の
// 問い合わせ（ユーザー操作ではなくアイドルによる要求）で、録音を止める理由にはしない
// （止めるのは実際に寝る `WillSleep`）。`HasPoweredOn` は復帰の通知で、ack も handler も要らない。
//
// なぜ protocol（`PowerSource`）にするか: 実機のスリープはテストから起こせないので、
// 「ack が漏れない」契約は test double（`FakePowerSource`）でしか確かめられない。
// 本物の `IOKitPowerSource` はテストで使わない（VERIFICATION の手動項目）。
//
// CFRunLoop は回さない（この CLI は `dispatchMain()` で待つ）。`IONotificationPortSetDispatchQueue`
// で通知を指定キューに載せる（RESEARCH §2.2 の「CFRunLoop の代わり」）。

import Foundation
import IOKit
import IOKit.pwr_mgt

/// 電源通知 1 件。`argument` は ack（`IOAllowPowerChange`）に渡す notificationID。
public struct PowerNotification: Sendable {
    /// `kIOMessageSystemWillSleep` / `kIOMessageCanSystemSleep` / `kIOMessageSystemHasPoweredOn` 等。
    public let messageType: UInt32
    /// C コールバックの `messageArgument`（notificationID）をそのまま整数にした値。
    public let argument: UInt

    public init(messageType: UInt32, argument: UInt) {
        self.messageType = messageType
        self.argument = argument
    }
}

extension PowerNotification {
    // **IOKit のメッセージ種別は Swift から C マクロとして見えない**。`IOMessage.h` の定義は
    // `#define kIOMessageSystemWillSleep iokit_common_msg(0x280)` という入れ子マクロで、
    // clang importer が `macro 'kIOMessageSystemWillSleep' unavailable: structure not supported`
    // と落とす（T6 turn で実測）。そこで定義どおりの値をここに 1 か所だけ書く:
    //
    //   iokit_common_msg(m) = sys_iokit | sub_iokit_common | m
    //                       = err_system(0x38) | err_sub(0) | m
    //                       = ((0x38 & 0x3f) << 26) | 0 | m
    //                       = 0xE000_0000 | m
    //
    // 値は `_Static_assert(kIOMessageSystemWillSleep == 0xE0000280u, …)` を clang で通して確認した。

    /// `kIOMessageSystemWillSleep`（これから寝る。ack を返すと寝る）。
    public static let systemWillSleep: UInt32 = 0xE000_0280
    /// `kIOMessageCanSystemSleep`（アイドルで寝ていいかの問い合わせ）。
    public static let canSystemSleep: UInt32 = 0xE000_0270
    /// `kIOMessageSystemHasPoweredOn`（復帰した。ack も要らない）。
    public static let systemHasPoweredOn: UInt32 = 0xE000_0300
}

public protocol PowerSource: AnyObject {
    /// 通知の受け取りを始める。handler は queue 上で呼ばれる。
    func register(queue: DispatchQueue, handler: @escaping (PowerNotification) -> Void) throws
    /// 受け取りをやめる（冪等）。
    func unregister()
    /// 通知に返答する（実装は `IOAllowPowerChange`）。
    func acknowledge(_ notification: PowerNotification)
}

/// 本物の電源通知（`IORegisterForSystemPower`）。
///
/// `@unchecked Sendable`: 寿命を持つ 3 つの資源（`rootPort` / `notifyPort` / `notifier`）と handler を
/// `lock` で守る。C コールバックは `IONotificationPortSetDispatchQueue` で指定したキュー上で呼ばれる。
public final class IOKitPowerSource: PowerSource, @unchecked Sendable {
    private let lock = NSLock()

    /// `IORegisterForSystemPower` が暗黙に開く Root Power Domain の接続（ack の宛先）。0 は未登録。
    private var rootPort: io_connect_t = 0
    /// 通知の受け口。`IONotificationPortSetDispatchQueue` でキューに載せる。
    private var notifyPort: IONotificationPortRef?
    /// 解除に使う notifier。0 は未登録。
    private var notifier: io_object_t = 0
    private var handler: ((PowerNotification) -> Void)?

    public init() {}

    deinit {
        // **refcon に `Unmanaged.passUnretained(self)` を入れているので、self より先に登録を解く必要がある**。
        // deinit まで来ているなら誰も参照していないが、C 側の通知が生きていると解放済みの self を
        // 掴んだコールバックが走りうる。ここで必ず解除する（`unregister` は冪等）。
        unregister()
    }

    public func register(queue: DispatchQueue, handler: @escaping (PowerNotification) -> Void) throws {
        lock.lock()
        // 二重登録は資源を取りこぼすので弾く（呼ぶのは `PowerWatcher.start()` の 1 回だけ）。
        guard rootPort == 0 else {
            lock.unlock()
            throw RecError(code: .coreAudio, message: "電源通知の登録が二重に呼ばれました")
        }
        self.handler = handler
        lock.unlock()

        var port: IONotificationPortRef?
        var newNotifier: io_object_t = 0
        // refcon は unretained。保持すると `deinit` が来ず、通知を解除する機会を失う（循環参照）。
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let connect = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let source = Unmanaged<IOKitPowerSource>.fromOpaque(refcon).takeUnretainedValue()
            source.deliver(messageType: messageType,
                           argument: UInt(bitPattern: messageArgument))
        }, &newNotifier)

        guard connect != 0, let port else {
            // 失敗時は普通どちらも 0 / nil だが、片方だけ返っていても取りこぼさない
            // （`unregister` と同じ順序で壊す）。
            if newNotifier != 0 {
                var mutableObject = newNotifier
                IODeregisterForSystemPower(&mutableObject)
            }
            if connect != 0 {
                _ = IOServiceClose(connect)
            }
            if let port {
                IONotificationPortDestroy(port)
            }
            lock.withLock { self.handler = nil }
            throw RecError(code: .coreAudio, message: "スリープ通知を登録できませんでした（IORegisterForSystemPower）")
        }

        lock.withLock {
            rootPort = connect
            notifyPort = port
            notifier = newNotifier
        }
        // CFRunLoop は回さない。通知をこのキューに載せる。
        IONotificationPortSetDispatchQueue(port, queue)
    }

    public func unregister() {
        // 取り出してから壊す（冪等。2 回目は全部 nil / 0 なので何もしない）。
        let (connect, port, obj) = lock.withLock { () -> (io_connect_t, IONotificationPortRef?, io_object_t) in
            let values = (rootPort, notifyPort, notifier)
            rootPort = 0
            notifyPort = nil
            notifier = 0
            handler = nil
            return values
        }

        // 順序は QA1340 のサンプルどおり:
        //   1. 通知の配送を止める（dispatch queue を外す。CFRunLoop 版の CFRunLoopRemoveSource に相当）
        //   2. `IODeregisterForSystemPower` で通知を解除
        //   3. `IORegisterForSystemPower` が暗黙に開いた Root Power Domain を `IOServiceClose` で閉じる
        //   4. `IONotificationPortDestroy` で受け口を壊す
        // **port の破棄を最後にするのは、1 で配送を止めてから壊すため**（走っているコールバックと
        // 破棄がすれ違わない）。
        if let port {
            IONotificationPortSetDispatchQueue(port, nil)
        }
        if obj != 0 {
            var mutableObject = obj
            IODeregisterForSystemPower(&mutableObject)
        }
        if connect != 0 {
            _ = IOServiceClose(connect)
        }
        if let port {
            IONotificationPortDestroy(port)
        }
    }

    public func acknowledge(_ notification: PowerNotification) {
        let connect = lock.withLock { rootPort }
        guard connect != 0 else { return }
        // ack を返さないとスリープが最大 30 秒ブロックされる（QA1340）。戻り値は見ない
        // （失敗しても代わりにできることが無い）。
        _ = IOAllowPowerChange(connect, Int(bitPattern: notification.argument))
    }

    /// C コールバックから呼ばれる（`IONotificationPortSetDispatchQueue` で指定したキュー上）。
    private func deliver(messageType: UInt32, argument: UInt) {
        guard let handler = lock.withLock({ self.handler }) else { return }
        handler(PowerNotification(messageType: messageType, argument: argument))
    }
}

/// スリープ通知を受けて `handler(.sleep)` を呼ぶ監視。
///
/// `@unchecked Sendable`: 可変の状態は「登録したか」の旗だけで、`lock` で守る。
public final class PowerWatcher: @unchecked Sendable {
    private let source: PowerSource
    private let queue: DispatchQueue
    private let handler: (StopReason) -> Void

    private let lock = NSLock()
    /// `register` が成功していて、まだ `unregister` していない。
    private var registered = false

    public init(source: PowerSource = IOKitPowerSource(),
                queue: DispatchQueue,
                handler: @escaping (StopReason) -> Void) {
        self.source = source
        self.queue = queue
        self.handler = handler
    }

    deinit {
        // 監視を張ったまま解放されても必ず解除する（`stop()` は冪等）。
        stop()
    }

    /// 監視を始める。`IORegisterForSystemPower` の失敗は `RecError(code: .coreAudio, …)`。
    public func start() throws {
        do {
            try source.register(queue: queue) { [weak self] notification in
                self?.receive(notification)
            }
        } catch {
            // どんなエラーで来ても呼び出し側が見るのは `.coreAudio` の 1 本（PLAN T6 の完了基準）。
            throw RecError(code: .coreAudio,
                           message: "スリープ通知を登録できませんでした: \(error)")
        }
        lock.withLock { registered = true }
    }

    /// 監視をやめる（`deinit` からも呼ぶ。冪等）。
    public func stop() {
        let shouldUnregister = lock.withLock { () -> Bool in
            guard registered else { return false }
            registered = false
            return true
        }
        guard shouldUnregister else { return }
        source.unregister()
    }

    /// 通知 1 件を処理する（`queue` 上）。
    private func receive(_ notification: PowerNotification) {
        switch notification.messageType {
        case PowerNotification.systemWillSleep:
            // **ack は `defer`**。handler がどこを通っても ack が漏れない（QA1340）。
            // handler を先に走らせるのは、ack を返した後はシステムが寝てしまうため
            // （handler は停止要求を投げるだけで、ブロックしない契約）。
            defer { source.acknowledge(notification) }
            handler(.sleep)
        case PowerNotification.canSystemSleep:
            // 「寝ていいか」の問い合わせ。rec は拒否しない（録音中でも寝させる）が、
            // **返事をしない経路は作らない**。ここで ack を落とすとスリープが 30 秒止まる。
            source.acknowledge(notification)
        default:
            // `kIOMessageSystemHasPoweredOn`（復帰）など。ack も handler も要らない。
            break
        }
    }
}
