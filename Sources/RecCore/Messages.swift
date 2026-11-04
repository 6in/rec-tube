// Messages.swift — 許可の案内文（3 種）と定型文（データなし / 無音 / ライブ配信）、
// 停止理由の 1 行（`stopReason`）・保存先の 1 行（`savedTo`）・自動再生拒否の 1 行（`autoplayRejected`）。
//
// 追従先（PLAN「追従先チェックリスト」）: 許可の種類・案内文を変えたら README「許可」節（3 種）と
// `scripts/verify-permission.sh`（T11）を直す。各文字列は末尾に改行を含まない（改行を足すのは出力側）。
// `StopReason` に case を足したら `stopReason(_:probeSummary:)` の switch が build で落ちる
// （`default` を書かない約束）。文言を変えたら README「終了コード」表の「主な StopReason」も見る。

import Foundation

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

    /// 無音: 全編が無音だった（許可が無い疑い）。許可の確認方法まで含める。
    public static let silent = """
        録音の全編が無音でした。システム音声の録音許可が無い可能性があります。
        「システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音」で、
        ターミナルアプリ（iTerm2 / Terminal.app など）が許可されているか確認してください。
        許可の状態は scripts/verify-permission.sh でも確認できます。
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

    // MARK: - 停止理由・保存先・自動再生（F1）

    /// 停止理由の 1 行。**どの理由でも必ず 1 行出す**（`RecordingSession.finish` / `fail`）。
    ///
    /// `switch` は exhaustive にして `default` を書かない（`StopReason` に case が増えたら
    /// build が漏れを教える）。秒数は `Tuning.*` から作る（このファイルに直書きしない）。
    ///
    /// - Parameters:
    ///   - reason: 止めた理由。
    ///   - probeSummary: `.pageUnavailable` のときだけ使う「最後に見たページの状態」の 1 語
    ///     （`RecordingSession` が覚える `none` / `loading` / `欠測`）。nil なら括弧ごと省く。
    public static func stopReason(_ reason: StopReason, probeSummary: String? = nil) -> String {
        switch reason {
        case .ended:
            return "再生が最後まで終わったので録音を終了しました。"
        case .nextVideo:
            return "次の動画へ遷移したので録音を終了しました。"
        case .liveStream:
            return "ライブ配信・プレミア公開だったので録音を中止しました。"
        case .permissionSuspected:
            return "本編の再生中に音声が全く入らないので録音を中止しました（システム音声の録音許可が無い疑い）。"
        case .deviceChanged:
            return "既定の出力デバイスが変わったので録音を終了しました。"
        case .sleep:
            return "システムがスリープに入るので録音を終了しました。"
        case .serviceRestarted:
            return "オーディオサービス（coreaudiod）が再起動したので録音を終了しました。"
        case .ioStopped:
            return "オーディオの入出力が異常停止したので録音を終了しました。"
        case .deviceDied:
            return "使用していたオーディオデバイスが消えたので録音を終了しました。"
        case .tapStalled:
            return "オーディオの取り込みが止まったので録音を終了しました（tap の故障）。"
        case .tabClosed:
            return "対象のタブが閉じられたので録音を終了しました。"
        case .pageUnavailable:
            let head = "\(seconds(Tuning.startTimeoutSeconds)) 秒以内に動画の再生が始まらなかったので録音を中止しました"
            guard let probeSummary else { return head + "。" }
            return head + "（最後に見たページの状態: \(probeSummary)）。"
        case .pageUnresponsive:
            return "ページから \(seconds(Tuning.unresponsiveSeconds)) 秒間応答が無いので録音を終了しました。"
        case .writeFailed:
            return "出力ファイルへの書き込みに失敗したので録音を終了しました。"
        case let .signal(sig):
            return "\(signalName(sig)) を受け取ったので録音を終了しました。"
        }
    }

    /// 保存先の 1 行（絶対パス）。ファイルが残るときだけ、**最後に**出す。
    public static func savedTo(_ url: URL) -> String {
        "保存先: \(url.standardizedFileURL.path)"
    }

    /// 自動再生が拒否された（probe の `playErr` が非 nil）ときの 1 行。1 セッションに 1 回だけ。
    ///
    /// - Parameter name: `HTMLMediaElement.play()` の reject の `name`（`NotAllowedError` など）。
    ///   **ページ由来なので呼び出し側が `sanitizeForTerminal` を通してから渡す**（F4 / E21。
    ///   通すのは `SessionPolicy.autoplayWarning` の 1 か所）。ここでは加工しない
    ///   （この型は文言を組むだけ、という役割分担を崩さない）。
    public static func autoplayRejected(name: String) -> String {
        """
        ブラウザが自動再生を拒否しました（\(name)）。録音は続けますが、本編が始まらない場合は
        対象のタブで一度再生ボタンを押してください。
        """
    }

    // MARK: - 補助

    /// 秒数を人向けの文字列にする（整数なら小数点を付けない）。
    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// シグナル番号の名前。入口（`SignalWatcher`）が張るのは HUP / INT / TERM の 3 本だけ。
    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        case SIGTERM: return "SIGTERM"
        default: return "シグナル \(sig)"
        }
    }
}
