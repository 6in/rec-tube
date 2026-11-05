// ExitCode.swift — 終了コード・停止理由・エラー型。
//
// 根拠: PLAN「決めた事項」#3 の表。README の「終了コード」表（T11）はこの enum と同一にする。
//
// 追従先（PLAN「追従先チェックリスト」）: ここに case を足したら
// `Tests/RecCoreTests/ExitCodeTests.swift`、README「終了コード」表、PLAN「決めた事項」#3 を直す。
// `StopReason` を足したら `exitCode` の switch（default を書かない。build が漏れを教える）、
// `SessionPolicy` のテスト（T8）、README「既知の制約」も直す。

import Foundation

/// プロセスの終了コード。`exit(_:)` に渡す値そのもの。
///
/// シグナルによる中断は 128 + シグナル番号（`signalHUP` / `signalINT` / `signalTERM`）。
/// PLAN #3 の表では 1 行にまとめてあるが、`Int32` の raw value を持つ enum にするため 3 case に分けた。
public enum ExitCode: Int32, Sendable, CaseIterable {
    /// 正常終了（再生終了・次の動画への遷移）。
    case ok = 0
    /// 引数・URL 不正、`--app` に一致なし。
    case usage = 1
    /// Chrome 制御不可（起動不可・オートメーション未許可 -1743・JS 許可オフ・ウィンドウ作成失敗）。
    case chromeUnavailable = 2
    /// ライブ配信 / プレミア公開。
    case liveStream = 3
    /// 全編無音（権限なしの疑い）。ファイルは残す。
    case silent = 4
    /// 出力デバイス変更・スリープ・coreaudiod 再起動・IO 異常停止・デバイス消失・tap 故障。
    case interrupted = 5
    /// タブ閉鎖・60 秒以内に動画が見つからない/再生開始しない・20 秒応答なし。
    case pageLost = 6
    /// 出力ファイルを作れない・書き込みエラー。
    case outputUnavailable = 7
    /// tap / aggregate / IOProc の作成・開始失敗、`--list` 取得失敗、その他の予期しないエラー。
    case coreAudio = 8
    /// SIGHUP で中断（128 + 1）。
    case signalHUP = 129
    /// SIGINT で中断（128 + 2）。
    case signalINT = 130
    /// SIGTERM で中断（128 + 15）。
    case signalTERM = 143
}

/// 録音を止めた理由。終了コードは `exitCode` で決まる。
///
/// 優先順位（PLAN #3）: 停止理由の code が非ゼロならそれ。ゼロ（`.ended` / `.nextVideo`）の
/// ときだけ無音判定で `.silent` になりうる。
public enum StopReason: Sendable, Equatable {
    // MARK: 0 — 正常終了
    /// 再生が最後まで終わった。
    case ended
    /// 次の動画へ遷移した（現行動作を維持）。
    case nextVideo

    // MARK: 3 — ライブ配信
    /// ライブ配信 / プレミア公開を検出した（録音開始前）。
    case liveStream

    // MARK: 4 — 無音
    /// 全ゼロが続き、まだ一度も音が入っていない（許可なしの疑い）。
    case permissionSuspected

    // MARK: 5 — 中断
    /// 既定の出力デバイスが変わった。
    case deviceChanged
    /// システムがスリープに入った。
    case sleep
    /// coreaudiod が再起動した。
    case serviceRestarted
    /// IOProc が異常停止した。
    case ioStopped
    /// 使っていたデバイスが消えた。
    case deviceDied
    /// 一度は音が入ったのに全ゼロが続いた（tap の故障）。
    case tapStalled

    // MARK: 6 — ページ喪失
    /// 対象のタブが閉じられた。
    case tabClosed
    /// 60 秒待っても動画が見つからない / 再生が始まらない。
    case pageUnavailable
    /// 20 秒応答がない。
    case pageUnresponsive

    // MARK: 7 — 出力不可
    /// 書き込みに失敗した。
    case writeFailed

    // MARK: 129 / 130 / 143 — シグナル
    /// シグナルで中断した（`SIGHUP` / `SIGINT` / `SIGTERM`）。
    case signal(Int32)
}

extension StopReason {
    /// この理由で終わるときの終了コード（PLAN #3 の表）。
    ///
    /// `switch` は exhaustive にして `default` を書かない（case を足したら build が漏れを教える）。
    public var exitCode: ExitCode {
        switch self {
        case .ended, .nextVideo:
            return .ok
        case .liveStream:
            return .liveStream
        case .permissionSuspected:
            return .silent
        case .deviceChanged, .sleep, .serviceRestarted, .ioStopped, .deviceDied, .tapStalled:
            return .interrupted
        case .tabClosed, .pageUnavailable, .pageUnresponsive:
            return .pageLost
        case .writeFailed:
            return .outputUnavailable
        case let .signal(sig):
            // 入口（T6）が張るのは HUP / INT / TERM の 3 本だけ。
            // それ以外の番号は「その他の予期しないエラー」として .coreAudio に畳む。
            return ExitCode(rawValue: 128 &+ sig) ?? .coreAudio
        }
    }
}

/// 終了コードを持つエラー。`message` は stderr に出す人向けの 1 行（進捗は stdout、エラーは stderr）。
public struct RecError: Error, Equatable {
    public let code: ExitCode
    public let message: String

    public init(code: ExitCode, message: String) {
        self.code = code
        self.message = message
    }
}
