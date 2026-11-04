// Tuning.swift — 調整値（秒数・dBFS・セレクタ）の唯一の置き場。
//
// 断言: **他のファイルはこれらの数値を直書きしない**。秒数・dBFS・比率を使う箇所は必ず
// `Tuning.<名前>` を経由する（PLAN「追従先チェックリスト」の「調整値を変える」行）。
// 値の根拠は PLAN「決めた事項」#4〜#8。値を変えたら README の該当数値も直す。
//
// `--ad-guard` のようにコマンドラインで上書きできる値は、ここが**既定値**で、
// 範囲（`adGuardRange`）もここに置く。

import Foundation

/// 調整値。インスタンスを作らない名前空間。
public enum Tuning {
    // MARK: - 広告ガード（決めた事項 #4）

    /// 遅延線の長さ（秒）。広告の境界が録音に混ざらないように出力を遅らせる幅。
    /// `--ad-guard` で `adGuardRange` の範囲に上書きできる。URL モード以外は 0。
    public static let adGuardSeconds: Double = 1.0

    /// `--ad-guard` で受け付ける範囲（秒）。
    public static let adGuardRange: ClosedRange<Double> = 0.0 ... 10.0

    /// 広告明けに本編を巻き戻す量（秒）。`rewindJS` → gate を開く、の順序は固定。
    public static let adResumeRewindSeconds: Double = 0.7

    /// 広告中を表す `#movie_player` のクラス（probe JS が `matches` に渡す）。
    public static let adShowingSelector: String = "#movie_player.ad-showing, #movie_player.ad-interrupting"

    // MARK: - ポーリングとタイムアウト（決めた事項 #5）

    /// ページ状態を取りに行く間隔（秒）。
    public static let pollIntervalSeconds: Double = 0.5

    /// 録音開始までの待ち時間の上限（秒）。超えたら `.pageUnavailable`。
    public static let startTimeoutSeconds: Double = 60

    /// 録音開始後、ページから応答が無いまま許す時間（秒）。超えたら `.pageUnresponsive`。
    public static let unresponsiveSeconds: Double = 20

    /// `osascript` 1 回の実行に許す時間（秒）。
    public static let osascriptTimeoutSeconds: Double = 15

    /// `osascript` を打ち切るとき、`terminate()`（SIGTERM）から SIGKILL に進むまで待つ時間（秒）。
    /// SIGKILL を送った後に終了を待つ時間にも同じ値を使う。
    public static let osascriptKillGraceSeconds: Double = 2

    /// 打ち切った `osascript` のパイプの読み出しが終わるのを待つ時間（秒）。
    /// 超えたら読めた分だけで返す（相手がパイプを握り続けていても戻る）。
    public static let osascriptPipeGraceSeconds: Double = 2

    /// `AudioDeviceCreateIOProcIDWithBlock` 等、tap 開始の各段に許す時間（秒）。
    /// 許可が降りていないと無期限にブロックするので watchdog が必要（T2 turn 4 の実測）。
    public static let tapStartTimeoutSeconds: Double = 10

    // MARK: - 無音（決めた事項 #6）

    /// 無音とみなす閾値（dBFS）。silent iff `dBFS < silenceDBFS`（**ちょうどは silent ではない**）。
    public static let silenceDBFS: Double = -60.0

    /// メータが 1 窓を確定する長さ（秒）。
    public static let meterWindowSeconds: Double = 1.0

    /// 無音が何秒続いたら警告するか（秒）。
    public static let silenceWarnAfterSeconds: Double = 5

    /// 無音警告の再送を抑える間隔（秒）。この間は再警告しない。
    public static let silenceWarnIntervalSeconds: Double = 30

    // MARK: - tap 故障（決めた事項 #7）

    /// 本編再生中に全ゼロが何秒続いたら tap 故障 / 権限なしと判定するか（秒）。
    public static let tapStallSeconds: Double = 10

    // MARK: - SSAI（決めた事項 #8）

    /// `dur > len × ssaiDurationRatio` なら SSAI（サーバ側広告挿入）の可能性を 1 回だけ警告する。
    public static let ssaiDurationRatio: Double = 1.2

    // MARK: - トーン判定（検証用。PLAN T10）

    /// 「広告が優勢な窓」と判定する比率。ad のトーンのエネルギーが main の
    /// `toneAdDominanceRatio` 倍を超えたら広告混入とみなす（`ToneAnalyzer.analyze`）。
    public static let toneAdDominanceRatio: Double = 3.0

    /// トーン判定で「可聴」とみなす下限（dBFS）。これ以下の窓は比率に関わらず広告混入に数えない
    /// （無音の数値雑音で ad 優勢になるのを防ぐ）。無音判定そのものは `silenceDBFS`。
    public static let toneAudibleDBFS: Double = -50.0
}
