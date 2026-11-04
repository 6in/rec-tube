// Messages.swift — 許可の案内文（3 種）と定型文（データなし / 無音 / ライブ配信）。
//
// 追従先（PLAN「追従先チェックリスト」）: 許可の種類・案内文を変えたら README「許可」節（3 種）と
// `scripts/verify-permission.sh`（T11）を直す。各文字列は末尾に改行を含まない（改行を足すのは出力側）。

/// ユーザー向けの案内文・定型文の置き場（すべて stderr に出す前提の文字列）。
///
/// この enum は文字列を返すだけで、出力は呼び出し側の責務。
/// 名前空間として使うのでインスタンス化しない。
public enum Messages {
    /// システム音声（画面とシステムオーディオの録音）の許可が無いときの案内。
    public static let systemAudioPermission = """
        システム音声を録音する許可がありません。
        「システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音」で許可してください。

        注意: tmux / screen 越しに rec を起動すると、許可を求める「責任プロセス」は
        rec 自身ではなくターミナルアプリになります。許可はターミナルアプリ
        （iTerm2 / Terminal.app など）に対して与えてください。
        また、許可を与えたあとはターミナルアプリ自体を再起動する必要があります。

        許可の状態をやり直したいときは次のコマンドでリセットできます。
          tccutil reset ScreenCapture
        """

    /// Chrome のオートメーションが許可されていないとき（AppleScript エラー -1743）の案内。
    public static let chromeAutomationPermission = """
        Google Chrome を操作する許可がありません（AppleScript エラー -1743）。
        「システム設定 > プライバシーとセキュリティ > オートメーション」で、
        ターミナルアプリ（iTerm2 / Terminal.app など）に Google Chrome の操作を許可してください。
        """

    /// Chrome の JavaScript 実行（Apple Events からの JavaScript）が許可されていないときの案内。
    public static let chromeJavaScriptPermission = """
        Google Chrome で JavaScript を実行できません。
        Chrome のメニューから「表示 > 開発/管理 > Apple Events からの JavaScript を許可」を
        オンにしてください。
        """

    /// データなし: 1 フレームも書けなかったので出力ファイルを削除した。
    public static let noData = """
        音声データを 1 フレームも取得できませんでした。出力ファイルを削除しました。
        """

    /// 無音: 全編が無音だった（許可が無い疑い）。
    public static let silent = """
        録音の全編が無音でした。システム音声の録音許可が無い可能性があります。
        """

    /// ライブ配信: ライブ配信・プレミア公開は録音対象外なので中止した。
    public static let liveStream = """
        ライブ配信・プレミア公開は録音の対象外です。録音を中止しました。
        """

    /// overload 警告: IOProc が締め切りに間に合わなかった（`RecorderEvent.overload`）。
    ///
    /// **これ自体は録音を止めない**（決めた事項 #10 の最後の行「`.overload` はログのみ」）。
    public static let overload = """
        オーディオの処理が追いついていません（overload）。録音は続けます。
        """

    /// SSAI 警告: 尺が公称より長い（サーバ側広告挿入の疑い。決めた事項 #8）。
    ///
    /// `SessionPolicy` が `.warn(Messages.ssaiWarning)` で 1 回だけ出す。
    public static let ssaiWarning = """
        動画の尺が公称より長いため、SSAI（サーバ側広告挿入）の可能性があります。広告が録音に混ざるかもしれません。
        """

    /// 無音警告: gate が開いているのに無音が続いている（決めた事項 #6）。
    ///
    /// `SessionPolicy` が `.warn(Messages.silenceWarning)` で出す（再送は
    /// `Tuning.silenceWarnIntervalSeconds` 以内は抑える）。
    public static let silenceWarning = """
        無音が続いています。システム音声の録音許可と再生音量を確認してください。
        """
}
