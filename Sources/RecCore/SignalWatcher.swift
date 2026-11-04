// SignalWatcher.swift — SIGINT / SIGTERM / SIGHUP を「停止要求」に変える。
//
// 参考実装: OpenClaw の `TerminationSignalWatcher.swift`（`signal(SIG_IGN)` → `DispatchSource` の順）
//
// **断言（この型の契約）**:
//   - `DispatchSource.makeSignalSource` を作る**前に** `signal(sig, SIG_IGN)` を呼ぶ。
//     これを忘れると既定のシグナル処理が先に走ってプロセスが即死し、ファイルを閉じられない
//   - handler は init で渡された `queue` 上で呼ばれる
//   - handler は **`exit` を呼ばない**。停止要求を渡すだけ（`exit` を呼ぶのは
//     `Sources/rec/main.swift` だけ、という PLAN P1 の約束）
//   - `cancel()` は冪等で、`deinit` からも呼ぶ
//
// シグナルハンドラの中で async-signal-safe でないことをするのは禁じ手なので、`signal(2)` には
// SIG_IGN を渡すだけにして、実際の処理は `DispatchSourceSignal`（= ハンドラ文脈の外）で受ける。

import Foundation

/// handler（非 Sendable なクロージャ）を `DispatchSource` のイベントハンドラに持ち込む箱。
///
/// `setEventHandler` のクロージャは `@Sendable` なので、そのままでは非 Sendable な
/// クロージャを捕まえられない。中身は init 後に書き換えないので `@unchecked Sendable` で安全。
private final class SignalHandlerBox: @unchecked Sendable {
    let handler: (Int32) -> Void
    init(_ handler: @escaping (Int32) -> Void) { self.handler = handler }
}

/// シグナルを監視して `handler(sig)` を呼ぶ。
///
/// `@unchecked Sendable`: 可変状態は `sources` だけで、**必ず `lock` の中でだけ**触る規約。
public final class SignalWatcher: @unchecked Sendable {
    /// `sources` を守る。
    private let lock = NSLock()
    /// 張っている source。`cancel()` で空にする（= 二重 cancel を自然に冪等にする）。
    private var sources: [DispatchSourceSignal] = []

    /// - Parameters:
    ///   - signals: 監視するシグナル。既定は停止系の 3 本。
    ///   - queue: handler を呼ぶキュー。
    ///   - handler: シグナルを受けたときに呼ばれる。シグナル番号が渡る。
    public init(signals: [Int32] = [SIGINT, SIGTERM, SIGHUP],
                queue: DispatchQueue,
                handler: @escaping (Int32) -> Void) {
        let box = SignalHandlerBox(handler)
        var made: [DispatchSourceSignal] = []
        for sig in signals {
            // **source を作る前に**既定の処理を止める（順序が逆だと取りこぼしてプロセスが死ぬ）。
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { box.handler(sig) }
            source.activate()
            made.append(source)
        }
        lock.lock()
        sources = made
        lock.unlock()
    }

    deinit {
        cancel()
    }

    /// 監視をやめる。冪等（2 回目以降は何もしない）。
    public func cancel() {
        lock.lock()
        let targets = sources
        sources = []
        lock.unlock()

        // ロックの外で cancel する（handler が走っている最中でも詰まらないように）。
        for source in targets {
            source.cancel()
        }
    }
}
