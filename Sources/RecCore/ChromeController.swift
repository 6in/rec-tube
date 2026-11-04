// ChromeController.swift — Chrome を AppleScript 越しに操る（開く / JS を実行 / タイトル / 閉じる）。
//
// 断言（この型の最重要の契約）: **URL / JS / タブ ID をスクリプト本文に文字列補間しない**。
// スクリプト本文は入力に依存しない定数（`static let`）で、可変部は必ず `arguments`
// （= AppleScript の `on run argv`）で渡す。
// 根拠: RESEARCH §3.1。AppleScript の文字列リテラルは `\` と実リテラル改行で壊れる
// （旧 `Legacy.swift` の `"` → `%22` 置換や `"\(js)"` 補間はそこで破綻する）。
//
// 役割分担:
//   - `ScriptRunner` は「osascript をどう呼ぶか」だけを知る。stdout / stderr は**生のまま**返す。
//   - この型は「返ってきた文字列をどう読むか」だけを知る。**trim はここの責任**。
//   - 「応答が取れなかった」を終了コードに変えるのは上位（連続回数で `.pageUnresponsive` を判定）。
//     だから `execute` / `title` は status 非 0 を（許可系を除いて）throw せず `nil` で返す。
//
// 追従先: スクリプト本文（`openScript` / `executeScript` / `titleScript` / `closeScript`）を
// 直したら `Tests/RecCoreTests/ChromeControllerTests.swift` の「2 回の呼び出しで script が一致」
// 「arguments に生の値が入る」の検査も見直す。

import Foundation

/// Chrome を AppleScript 越しに操る口。`ScriptRunner` を差し替えればテストで osascript を起動しない。
///
/// 内部可変状態を持たない（`runner` を `let` で保持するだけ）ので `Sendable`。
public final class ChromeController: Sendable {
    private let runner: any ScriptRunner

    public init(runner: ScriptRunner) {
        self.runner = runner
    }

    // MARK: - スクリプト本文（定数。入力に依存しない）

    /// オートメーション許可の確認。引数なし。
    private static let versionScript = """
        tell application "Google Chrome" to get version
        """

    /// 新しいウィンドウを作って `item 1 of argv`（URL）を開き、タブ ID を返す。
    private static let openScript = """
        on run argv
          tell application "Google Chrome"
            activate
            set w to make new window
            set URL of active tab of w to (item 1 of argv)
            return (id of active tab of w) as text
          end tell
        end run
        """

    /// `item 1 of argv`（タブ ID）のタブで `item 2 of argv`（JS）を実行する。
    /// 見つからなければ `"gone"`。
    private static let executeScript = """
        on run argv
          tell application "Google Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                if (id of t as text) is (item 1 of argv) then
                  return execute t javascript (item 2 of argv)
                end if
              end repeat
            end repeat
            return "gone"
          end tell
        end run
        """

    /// `item 1 of argv`（タブ ID）のタブのタイトルを返す。見つからなければ `"gone"`。
    private static let titleScript = """
        on run argv
          tell application "Google Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                if (id of t as text) is (item 1 of argv) then
                  return title of t
                end if
              end repeat
            end repeat
            return "gone"
          end tell
        end run
        """

    /// `item 1 of argv`（タブ ID）のタブを閉じる。見つからなければ `"gone"`。
    private static let closeScript = """
        on run argv
          tell application "Google Chrome"
            repeat with w in windows
              repeat with t in tabs of w
                if (id of t as text) is (item 1 of argv) then
                  close t
                  return "ok"
                end if
              end repeat
            end repeat
            return "gone"
          end tell
        end run
        """

    // MARK: - 公開 API

    /// Chrome を操作できるか（オートメーション許可があるか）を確かめる。
    ///
    /// - Throws: 許可が無い（stderr に `-1743`）とき `RecError(.chromeUnavailable)` と
    ///   `Messages.chromeAutomationPermission`。それ以外の失敗は stderr の 1 行目を添えた
    ///   `RecError(.chromeUnavailable)`。`runner.run` 自体の throw は**そのまま伝播**させる。
    public func checkAutomation() throws {
        let result = try runner.run(script: Self.versionScript, arguments: [])
        guard result.status == 0 else {
            throw Self.controlFailure(stderr: result.stderr)
        }
    }

    /// 新しいウィンドウで `url` を開き、そのタブ ID を返す。
    ///
    /// - Parameter url: 開く URL。**スクリプト本文には埋め込まず** `argv` で渡す。
    /// - Returns: タブ ID（trim 済み）。
    /// - Throws: ウィンドウを作れなかった（成功したのに出力が空）とき、または Chrome を
    ///   制御できないとき `RecError(.chromeUnavailable)`。
    public func open(url: String) throws -> String {
        let result = try runner.run(script: Self.openScript, arguments: [url])
        guard result.status == 0 else {
            throw Self.controlFailure(stderr: result.stderr)
        }
        let tab = Self.trimmed(result.stdout)
        guard !tab.isEmpty else {
            throw RecError(
                code: .chromeUnavailable,
                message: "Chrome のウィンドウを作成できませんでした"
            )
        }
        return tab
    }

    /// `tab` のタブで `js` を実行し、結果の文字列を返す。
    ///
    /// 引数の順は **`[tab, js]`**（`item 1 of argv` = タブ ID、`item 2 of argv` = JS）で固定。
    ///
    /// - Returns: 結果（trim 済み）。応答が取れなかったとき・結果が `missing value` や空のときは `nil`。
    ///   `nil` は「今回は取れなかった」だけを意味する（連続回数で `.pageUnresponsive` を決めるのは上位）。
    /// - Throws: JS 許可オフ / オートメーション未許可のとき `RecError(.chromeUnavailable)`、
    ///   タブが見つからない（`"gone"`）とき `RecError(.pageLost)`。
    public func execute(tab: String, js: String) throws -> String? {
        let result = try runner.run(script: Self.executeScript, arguments: [tab, js])
        return try Self.interpretTabResult(result)
    }

    /// `tab` のタブのタイトルを返す。解釈の規則は `execute(tab:js:)` と同じ。
    ///
    /// - Returns: タイトル（trim 済み）。応答が取れなかったとき・`missing value` や空のときは `nil`。
    /// - Throws: 許可系のとき `RecError(.chromeUnavailable)`、タブが見つからないとき `RecError(.pageLost)`。
    public func title(tab: String) throws -> String? {
        let result = try runner.run(script: Self.titleScript, arguments: [tab])
        return try Self.interpretTabResult(result)
    }

    /// `tab` のタブを閉じる。
    ///
    /// **失敗は全部無視する**（後始末なので、すでに閉じていても Chrome が落ちていても構わない）。
    /// だから `throws` を付けず、戻り値も status も見ない。
    public func close(tab: String) {
        _ = try? runner.run(script: Self.closeScript, arguments: [tab])
    }

    // MARK: - 解釈（private ヘルパ）

    /// 末尾・先頭の空白と改行を落とす。`ScriptRunner` が生のまま返す契約の裏返し。
    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stderr の「1 行目」。全体を trim してから改行で分割した先頭要素（空なら空文字列）。
    ///
    /// 断言: この導出はここ 1 箇所だけ。メッセージを組む全員がこれを使う。
    private static func firstLine(of stderr: String) -> String {
        trimmed(stderr).components(separatedBy: .newlines).first ?? ""
    }

    /// 「Chrome を制御できない」系の失敗を `RecError` に畳む。
    ///
    /// `-1743`（オートメーション未許可）だけは案内文を差し替える。それ以外は stderr の 1 行目を添える。
    private static func controlFailure(stderr: String) -> RecError {
        if stderr.contains("-1743") {
            return RecError(code: .chromeUnavailable, message: Messages.chromeAutomationPermission)
        }
        return RecError(
            code: .chromeUnavailable,
            message: "Chrome を制御できません: \(firstLine(of: stderr))"
        )
    }

    /// タブ走査系（`execute` / `title`）の結果を読む。
    ///
    /// 判定の順序は固定:
    ///   1. status 非 0 で `turned off` / `オフ` → JS 許可オフ（旧実装の判定を維持。`-1743` より先に見る）
    ///   2. status 非 0 で `-1743` → オートメーション未許可
    ///   3. それ以外の status 非 0 → **throw せず `nil`**（応答が取れなかっただけ）
    ///   4. status 0 で `"gone"` → タブが閉じられた（`.pageLost`）
    ///   5. status 0 で `missing value` / 空 → `nil`
    ///   6. それ以外 → trim 済みの文字列
    private static func interpretTabResult(_ result: ScriptResult) throws -> String? {
        if result.status != 0 {
            if result.stderr.contains("turned off") || result.stderr.contains("オフ") {
                throw RecError(
                    code: .chromeUnavailable,
                    message: Messages.chromeJavaScriptPermission
                )
            }
            if result.stderr.contains("-1743") {
                throw RecError(
                    code: .chromeUnavailable,
                    message: Messages.chromeAutomationPermission
                )
            }
            // タイムアウト（status == -1）もここ。上位が連続回数で `.pageUnresponsive` を決める。
            return nil
        }

        let output = trimmed(result.stdout)
        if output == "gone" {
            throw RecError(code: .pageLost, message: "対象のタブが閉じられました")
        }
        if output == "missing value" || output.isEmpty {
            return nil
        }
        return output
    }
}
