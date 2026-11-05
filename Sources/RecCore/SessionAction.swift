// SessionAction.swift — `SessionPolicy` が返す指示の型（T8 の共有型）。
//
// なぜ `SessionPolicy.swift` から分けてあるか: この enum は状態機械（`SessionPolicy`）と
// その実行役（`RecordingSession`）とテストの 3 者が同時に参照する共有型で、3 者を並列に
// 書くには先に 1 箇所で確定していなければならない（PLAN T5 / T6 / T7 で繰り返した
// 「共有型は親が先に確定させる」の形）。PLAN T8 の完了基準では `SessionPolicy.swift` 内に
// 置くと書いてあるが、ファイルの持ち主を分けるためにここへ出した（PROGRESS に PLAN 訂正）。
//
// **断言: この enum に case を足さない**。決めた事項 #10 の表の「行動」列と 1 対 1 で、
// 表に無い行動（リトライ、フォールバック、再開など）は作らない。
//
// 追従先: case を足すなら #10 の表・`SessionPolicy`・`RecordingSession.apply` ・
// `SessionPolicyTests` を同じターンで直す。

import Foundation

/// 状態機械が 1 回の `step` で出す指示。`RecordingSession` が受け取った順に実行する。
///
/// `Equatable` にしてあるのはテストが配列ごと `==` で比較するため
/// （`StopReason` も `Equatable`。`warn` は文字列の同値で比較する）。
public enum SessionAction: Sendable, Equatable {
    /// 何もしない（次の poll を待つ）。
    case wait

    /// 録音を開始する。`title` は出力ファイル名の種（取れなければ `nil`）。
    ///
    /// 1 セッションで**ちょうど 1 回**だけ出る。
    case startRecording(title: String?)

    /// 本編を一時停止して先頭に戻す（`holdAtStartJS`）。`.startRecording` より**前**に実行する。
    /// 頭出し前の音が録音に入らないようにするため。以後 `.playAfterDelay` まで probe を止める
    /// （probe は `v.paused` なら `v.play()` を呼ぶので、止めないと待たずに再生が始まる）。
    case holdAtStart

    /// `startDelaySeconds` 待ってから再生し（`playJS`）、probe を再開する。
    case playAfterDelay

    /// gate を開く（録音を書く）= `pipeline.setGate(true, discardHeld: false)`。
    case openGate

    /// gate を閉じて遅延線の保持分を**捨てる**（広告に入った）
    /// = `pipeline.setGate(false, discardHeld: true)`。
    case closeGateDiscard

    /// gate を閉じて保持分は**残す**（一時停止に入った）
    /// = `pipeline.setGate(false, discardHeld: false)`。
    case closeGateHold

    /// 広告明け: `rewindJS` を投げてから gate を開く（**この順序は固定**。決めた事項 #4）。
    case rewindThenOpenGate

    /// 人向けの警告を 1 行出す（録音は続ける）。
    case warn(String)

    /// 録音を終える。`RecordingSession` は `StopCoordinator.request(reason)` に渡す。
    case stop(StopReason)
}
