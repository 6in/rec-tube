// StopCoordinator.swift — 「録音を止める」という決定を 1 箇所に集める。
//
// 停止要求はいろいろな所から同時に降ってくる（シグナル、スリープ、`RecorderEvent`、書き込み失敗、
// 状態機械の `.stop`）。最初の 1 本だけを採用して、後から来たものは黙って捨てる役。
//
// **断言（この型の契約）**:
//   - `request(_:)` は**最初の 1 回だけ `true`**。2 回目以降は理由が何であれ `false`
//   - `reason` は**最初に受け付けた理由のまま変わらない**（後から来た理由で上書きしない）
//   - `onFirstRequest` は**ちょうど 1 回**、init で渡された**セッションキュー上で非同期に**呼ばれる。
//     `request` の呼び出し元のスレッドでは呼ばない
//
// 3 番目が必須な理由（PLAN T5 turn 7 の申し送り (3)）: `TapRecorder.stop()` は内部で
// `ioQueue.sync {}` を呼ぶ。IO キュー（= `sink` の中）から `request` を呼んだときに、
// ハンドラが同じ IO キュー上で走ると、その `ioQueue.sync {}` で自己デッドロックする。
// だから「受け付けたという記録」と「後始末の実行」を別のキューに切り離す。

import Foundation

/// `onFirstRequest`（非 Sendable なクロージャ）をセッションキューに持ち込む箱。
///
/// `DispatchQueue.async` のクロージャは `@Sendable` なので、そのままでは非 Sendable な
/// クロージャを捕まえられない。中身は init 後に書き換えないので `@unchecked Sendable` で安全。
/// （`TapRecorder.swift` の `Unchecked` と同じ手口。）
private final class StopHandlerBox: @unchecked Sendable {
    let handler: (StopReason) -> Void
    init(_ handler: @escaping (StopReason) -> Void) { self.handler = handler }
}

/// 停止要求の受付口。最初の 1 本だけを採用する。
///
/// `@unchecked Sendable`: 可変状態は `accepted` だけで、**必ず `lock` の中でだけ**触る規約。
/// `queue` と `box` は init で決まったら変わらない。
public final class StopCoordinator: @unchecked Sendable {
    /// `onFirstRequest` を走らせるキュー（セッションキュー）。
    private let queue: DispatchQueue
    /// 最初の 1 回だけ呼ぶハンドラ。
    private let box: StopHandlerBox

    /// `accepted` を守る（`NSLock`。`TapRecorder` と同じ道具立てに揃える）。
    private let lock = NSLock()
    /// 最初に受け付けた理由。一度入ったら書き換えない。
    private var accepted: StopReason?

    /// - Parameters:
    ///   - queue: `onFirstRequest` を走らせるキュー（セッションキュー）。
    ///   - onFirstRequest: 最初の停止要求を受け付けたときに、`queue` 上で 1 回だけ呼ばれる。
    public init(queue: DispatchQueue, onFirstRequest: @escaping (StopReason) -> Void) {
        self.queue = queue
        self.box = StopHandlerBox(onFirstRequest)
    }

    /// 停止を要求する。
    ///
    /// - Returns: この呼び出しが**最初**だったときだけ `true`。そのときだけ `onFirstRequest` を
    ///   `queue` に非同期で投げる（この関数は投げるだけで戻る）。
    public func request(_ reason: StopReason) -> Bool {
        lock.lock()
        if accepted != nil {
            // すでに決まっている。理由は上書きしない。
            lock.unlock()
            return false
        }
        accepted = reason
        lock.unlock()

        // ロックの外で投げる（ハンドラが `reason` を読んでも詰まらないように）。
        let box = self.box
        queue.async { box.handler(reason) }
        return true
    }

    /// 最初に受け付けた理由（まだなら `nil`）。どのスレッドからでも読める。
    public var reason: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }
}
