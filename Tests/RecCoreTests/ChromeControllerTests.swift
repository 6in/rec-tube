// ChromeController のユニットテスト。
//
// 実装（`Sources/RecCore/ChromeController.swift`）は**見ずに**、T7 の API 契約だけから書いてある。
// 契約違反を検出するのがこのファイルの目的なので、「実装がこうなっているから」で緩めない。
//
// 確かめる契約:
//   0. **最重要**: URL / JS / タブ ID はスクリプト本文に埋め込まれない。
//      スクリプト本文は入力に依存しない定数で、値は `arguments`（AppleScript の `on run argv`）で渡る。
//      → `"` `\` `'` 改行 `%` を含む 2 種類の値で呼び、script が完全一致すること +
//        `arguments` が**加工されていない生の値**であること + script が値を含まないことを見る。
//   1. `checkAutomation()`: status 0 → throw しない / `-1743` → オートメーション案内 /
//      その他の非 0 → `"Chrome を制御できません: <stderr の 1 行目>"` /
//      `runner.run` 自体の throw はそのまま伝播。
//   2. `open(url:)`: stdout を trim して返す / 空なら「ウィンドウを作成できませんでした」/
//      非 0 の分類は `checkAutomation` と同じ。
//   3. `execute(tab:js:)`: `turned off` / `オフ` → JS 許可案内、`-1743` → オートメーション案内、
//      **それ以外の非 0 は throw せず nil** / `gone` → `.pageLost` / `missing value` ・空 → nil /
//      普通の文字列は trim して返す。
//   4. `title(tab:)`: trim だけ（サフィックスは落とさない）/ `gone` → `.pageLost` /
//      `missing value` ・空 → nil。
//   5. `close(tab:)`: `throws` なし。runner が throw しても、非 0 でも、`gone` でも何も起きない。
//
// 書き方の約束:
//   - `FakeRunner`（`Fakes/FakeRunner.swift`）に結果を積んで `osascript` は一切起動しない。
//   - 「1 行目」は stderr 全体を trim したあとの先頭行。先頭に空白・改行を足した stderr で
//     「trim → 改行で分割」の順序まで見る。
//   - `#require` に `Bool?` を渡すと warning になるので `#expect(x == false)` で書く。

import Foundation
import Testing

@testable import RecCore

@Suite("ChromeController")
struct ChromeControllerTests {
    // MARK: - 補助

    /// 契約 #0 の検査に使う「意地の悪い値」。`"` `\` `'` `%` と実改行を全部含む。
    private static let nastyA = #"https://e.com/a?x="b"\c'd&y=%20"#
    private static let nastyB = "https://e.com/b?x=\"q\"\\r's\n&y=%25\nz"

    /// 非 0 のときの定型文（`-1743` 以外）。
    private func controlFailureMessage(_ firstLine: String) -> String {
        "Chrome を制御できません: \(firstLine)"
    }

    // MARK: - 0. 値はスクリプト本文に埋め込まれない（最重要）

    @Test("open(url:) のスクリプト本文は入力に依存しない定数で、URL は生のまま arguments で渡る")
    func openPassesURLThroughArgumentsNotScriptBody() throws {
        let runner = FakeRunner()
        // どちらの呼び出しも成功させる（戻り値ではなく script / arguments を見たい）。
        runner.enqueue(stdout: "1\n")
        runner.enqueue(stdout: "2\n")
        let controller = ChromeController(runner: runner)

        _ = try controller.open(url: Self.nastyA)
        _ = try controller.open(url: Self.nastyB)

        #expect(runner.calls.count == 2, "open が 2 回呼ばれていない: \(runner.calls.count) 回")
        let first = try #require(runner.calls.first)
        let second = try #require(runner.calls.last)

        // スクリプト本文は入力に依存しない（= 完全一致）。
        #expect(first.script == second.script, "URL によってスクリプト本文が変わっている（値を埋め込んでいる疑い）")

        // 値は加工されずに arguments で渡る。
        #expect(first.arguments == [Self.nastyA], "URL が加工されている: \(first.arguments)")
        #expect(second.arguments == [Self.nastyB], "URL が加工されている: \(second.arguments)")

        // スクリプト本文に値が出てこない。
        #expect(first.script.contains(Self.nastyA) == false, "スクリプト本文に URL が埋め込まれている")
        #expect(second.script.contains(Self.nastyB) == false, "スクリプト本文に URL が埋め込まれている")
    }

    @Test("execute(tab:js:) のスクリプト本文は定数で、arguments は [タブ ID, JS] の順")
    func executePassesTabAndJSThroughArgumentsNotScriptBody() throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: "ok\n")
        runner.enqueue(stdout: "ok\n")
        let controller = ChromeController(runner: runner)

        let tabA = #"12"3\4'5%6"#
        let jsA = #"document.querySelector("video")['x']+"\n"+'%'"#
        let tabB = "7\"8\\9'0\n%1"
        let jsB = "var s = \"a\\b'c\";\ns + '%d'\n"

        _ = try controller.execute(tab: tabA, js: jsA)
        _ = try controller.execute(tab: tabB, js: jsB)

        #expect(runner.calls.count == 2, "execute が 2 回呼ばれていない: \(runner.calls.count) 回")
        let first = try #require(runner.calls.first)
        let second = try #require(runner.calls.last)

        #expect(first.script == second.script, "JS / タブ ID によってスクリプト本文が変わっている")

        // item 1 = タブ ID、item 2 = JS の順。
        #expect(first.arguments == [tabA, jsA], "arguments が [タブ ID, JS] の順で生の値になっていない: \(first.arguments)")
        #expect(second.arguments == [tabB, jsB], "arguments が [タブ ID, JS] の順で生の値になっていない: \(second.arguments)")

        #expect(first.script.contains(jsA) == false, "スクリプト本文に JS が埋め込まれている")
        #expect(first.script.contains(tabA) == false, "スクリプト本文にタブ ID が埋め込まれている")
        #expect(second.script.contains(jsB) == false, "スクリプト本文に JS が埋め込まれている")
        #expect(second.script.contains(tabB) == false, "スクリプト本文にタブ ID が埋め込まれている")
    }

    @Test("title(tab:) のスクリプト本文は定数で、タブ ID は生のまま arguments で渡る")
    func titlePassesTabThroughArgumentsNotScriptBody() throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: "a\n")
        runner.enqueue(stdout: "b\n")
        let controller = ChromeController(runner: runner)

        let tabA = #"12"3\4'5%6"#
        let tabB = "7\"8\\9'0\n%1"

        _ = try controller.title(tab: tabA)
        _ = try controller.title(tab: tabB)

        #expect(runner.calls.count == 2, "title が 2 回呼ばれていない: \(runner.calls.count) 回")
        let first = try #require(runner.calls.first)
        let second = try #require(runner.calls.last)

        #expect(first.script == second.script, "タブ ID によってスクリプト本文が変わっている")
        #expect(first.arguments == [tabA], "タブ ID が加工されている: \(first.arguments)")
        #expect(second.arguments == [tabB], "タブ ID が加工されている: \(second.arguments)")
        #expect(first.script.contains(tabA) == false, "スクリプト本文にタブ ID が埋め込まれている")
        #expect(second.script.contains(tabB) == false, "スクリプト本文にタブ ID が埋め込まれている")
    }

    @Test("close(tab:) のスクリプト本文は定数で、タブ ID は生のまま arguments で渡る")
    func closePassesTabThroughArgumentsNotScriptBody() {
        let runner = FakeRunner()
        let controller = ChromeController(runner: runner)

        let tabA = #"12"3\4'5%6"#
        let tabB = "7\"8\\9'0\n%1"

        controller.close(tab: tabA)
        controller.close(tab: tabB)

        #expect(runner.calls.count == 2, "close が 2 回呼ばれていない: \(runner.calls.count) 回")
        guard runner.calls.count == 2 else { return }
        #expect(runner.calls[0].script == runner.calls[1].script, "タブ ID によってスクリプト本文が変わっている")
        #expect(runner.calls[0].arguments == [tabA], "タブ ID が加工されている: \(runner.calls[0].arguments)")
        #expect(runner.calls[1].arguments == [tabB], "タブ ID が加工されている: \(runner.calls[1].arguments)")
        #expect(runner.calls[0].script.contains(tabA) == false, "スクリプト本文にタブ ID が埋め込まれている")
        #expect(runner.calls[1].script.contains(tabB) == false, "スクリプト本文にタブ ID が埋め込まれている")
    }

    // MARK: - 1. checkAutomation()

    @Test("checkAutomation は status 0 なら throw せず、引数なしで 1 回だけ走る")
    func checkAutomationSucceedsOnZeroStatus() throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: "")
        let controller = ChromeController(runner: runner)

        try controller.checkAutomation()

        #expect(runner.calls.count == 1, "呼び出しが 1 回ではない: \(runner.calls.count) 回")
        let call = try #require(runner.calls.first)
        #expect(call.arguments == [], "checkAutomation は引数を渡さないはず: \(call.arguments)")
    }

    @Test("checkAutomation は stderr に -1743 を含む失敗をオートメーション許可の案内にする")
    func checkAutomationMapsMinus1743() {
        let runner = FakeRunner()
        runner.enqueue(status: 1, stderr: "34:48: execution error: Not authorized to send Apple events to Google Chrome. (-1743)\n")
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.checkAutomation()
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == Messages.chromeAutomationPermission,
                "オートメーション許可の案内文になっていない: \(String(describing: error?.message))")
    }

    @Test("checkAutomation の -1743 以外の失敗は stderr の 1 行目だけを message に入れる")
    func checkAutomationUsesFirstStderrLine() {
        let runner = FakeRunner()
        // 先頭の空白・改行は trim されたあとに改行で分割される（trim → split の順）。
        runner.enqueue(status: 1, stderr: "\n  34:48: execution error: foo\nbar\n")
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.checkAutomation()
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == controlFailureMessage("34:48: execution error: foo"),
                "stderr の 1 行目だけが入っていない: \(String(describing: error?.message))")
    }

    @Test("checkAutomation は runner.run の throw をそのまま伝播する")
    func checkAutomationPropagatesRunnerError() {
        let runner = FakeRunner()
        let injected = RecError(
            code: .chromeUnavailable,
            message: "osascript を起動できませんでした: boom"
        )
        runner.enqueue(error: injected)
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.checkAutomation()
        }
        #expect(error == injected, "runner のエラーが別物に置き換わっている: \(String(describing: error))")
    }

    // MARK: - 2. open(url:)

    @Test("open は stdout を trim したタブ ID を返す")
    func openTrimsStdout() throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: "1234\n")
        let controller = ChromeController(runner: runner)

        let tab = try controller.open(url: "https://example.com/watch?v=abc")

        #expect(tab == "1234", "stdout が trim されていない: \(tab.debugDescription)")
        #expect(runner.calls.count == 1, "呼び出しが 1 回ではない: \(runner.calls.count) 回")
        #expect(runner.calls.first?.arguments == ["https://example.com/watch?v=abc"])
    }

    @Test("open は stdout が空ならウィンドウ作成失敗にする", arguments: ["", "\n", "   ", " \n\t \n"])
    func openRejectsEmptyStdout(stdout: String) {
        let runner = FakeRunner()
        runner.enqueue(stdout: stdout)
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.open(url: "https://example.com/")
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == "Chrome のウィンドウを作成できませんでした",
                "想定の定型文ではない: \(String(describing: error?.message))")
    }

    @Test("open の -1743 失敗はオートメーション許可の案内になる")
    func openMapsMinus1743() {
        let runner = FakeRunner()
        runner.enqueue(status: 1, stderr: "execution error: Not authorized ... (-1743)\n")
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.open(url: "https://example.com/")
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == Messages.chromeAutomationPermission)
    }

    @Test("open の -1743 以外の失敗は stderr の 1 行目だけを message に入れる")
    func openUsesFirstStderrLine() {
        let runner = FakeRunner()
        runner.enqueue(status: 1, stderr: "\n 34:48: execution error: foo\nbar\n")
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.open(url: "https://example.com/")
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == controlFailureMessage("34:48: execution error: foo"),
                "stderr の 1 行目だけが入っていない: \(String(describing: error?.message))")
    }

    @Test("open は runner.run の throw をそのまま伝播する")
    func openPropagatesRunnerError() {
        let runner = FakeRunner()
        let injected = RecError(code: .chromeUnavailable, message: "osascript を起動できませんでした: boom")
        runner.enqueue(error: injected)
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.open(url: "https://example.com/")
        }
        #expect(error == injected, "runner のエラーが別物に置き換わっている: \(String(describing: error))")
    }

    // MARK: - 3. execute(tab:js:)

    @Test("execute は JS 許可オフ（英語ロケール: turned off）を JS 許可の案内にする")
    func executeMapsJavaScriptTurnedOffEnglish() {
        let runner = FakeRunner()
        runner.enqueue(
            status: 1,
            stderr: "34:48: execution error: Executing JavaScript through AppleScript is turned off. (-2700)\n"
        )
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.execute(tab: "1", js: "1+1")
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == Messages.chromeJavaScriptPermission,
                "JS 許可の案内文になっていない: \(String(describing: error?.message))")
    }

    @Test("execute は JS 許可オフ（日本語ロケール: オフ）を JS 許可の案内にする")
    func executeMapsJavaScriptTurnedOffJapanese() {
        let runner = FakeRunner()
        runner.enqueue(
            status: 1,
            stderr: "34:48: 実行エラー: AppleScript による JavaScript の実行はオフになっています。 (-2700)\n"
        )
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.execute(tab: "1", js: "1+1")
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == Messages.chromeJavaScriptPermission,
                "JS 許可の案内文になっていない: \(String(describing: error?.message))")
    }

    @Test("execute の -1743 失敗はオートメーション許可の案内になる")
    func executeMapsMinus1743() {
        let runner = FakeRunner()
        runner.enqueue(status: 1, stderr: "execution error: Not authorized ... (-1743)\n")
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.execute(tab: "1", js: "1+1")
        }
        #expect(error?.code == .chromeUnavailable)
        #expect(error?.message == Messages.chromeAutomationPermission)
    }

    @Test("execute はそれ以外の非 0 では throw せず nil を返す")
    func executeReturnsNilOnOtherFailures() throws {
        let runner = FakeRunner()
        runner.enqueue(status: 1, stderr: "some other error\n")
        let controller = ChromeController(runner: runner)

        let result = try controller.execute(tab: "1", js: "1+1")

        #expect(result == nil, "非 0（分類外）は nil のはず: \(String(describing: result))")
    }

    @Test("execute は trim 後の stdout が gone なら pageLost を throw する")
    func executeMapsGoneToPageLost() {
        let runner = FakeRunner()
        runner.enqueue(stdout: "gone\n")
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.execute(tab: "1", js: "1+1")
        }
        #expect(error?.code == .pageLost)
        #expect(error?.message == "対象のタブが閉じられました",
                "想定の定型文ではない: \(String(describing: error?.message))")
    }

    @Test("execute は missing value / 空の stdout を nil にする",
          arguments: ["missing value", "missing value\n", "", "\n", "   ", " \n\t "])
    func executeMapsMissingValueAndEmptyToNil(stdout: String) throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: stdout)
        let controller = ChromeController(runner: runner)

        let result = try controller.execute(tab: "1", js: "1+1")

        #expect(result == nil, "nil のはず: \(String(describing: result))")
    }

    @Test("execute は普通の stdout を trim してそのまま返す")
    func executeReturnsTrimmedStdout() throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: "main playing 12.5 345.0\n")
        let controller = ChromeController(runner: runner)

        let result = try controller.execute(tab: "1", js: "probe()")

        #expect(result == "main playing 12.5 345.0", "trim 後の文字列と違う: \(String(describing: result))")
    }

    // MARK: - 4. title(tab:)

    @Test("title は stdout を trim するだけで、- YouTube サフィックスは落とさない")
    func titleTrimsOnly() throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: "動画名 - YouTube\n")
        let controller = ChromeController(runner: runner)

        let title = try controller.title(tab: "1234")

        #expect(title == "動画名 - YouTube", "trim 以外の加工が入っている: \(String(describing: title))")
        #expect(runner.calls.count == 1, "呼び出しが 1 回ではない: \(runner.calls.count) 回")
        #expect(runner.calls.first?.arguments == ["1234"], "arguments が [タブ ID] ではない")
    }

    @Test("title は trim 後の stdout が gone なら pageLost を throw する")
    func titleMapsGoneToPageLost() {
        let runner = FakeRunner()
        runner.enqueue(stdout: "gone\n")
        let controller = ChromeController(runner: runner)

        let error = #expect(throws: RecError.self) {
            try controller.title(tab: "1234")
        }
        #expect(error?.code == .pageLost)
        #expect(error?.message == "対象のタブが閉じられました",
                "想定の定型文ではない: \(String(describing: error?.message))")
    }

    @Test("title は missing value / 空の stdout を nil にする",
          arguments: ["missing value", "missing value\n", "", "\n", "   ", " \n\t "])
    func titleMapsMissingValueAndEmptyToNil(stdout: String) throws {
        let runner = FakeRunner()
        runner.enqueue(stdout: stdout)
        let controller = ChromeController(runner: runner)

        let title = try controller.title(tab: "1234")

        #expect(title == nil, "nil のはず: \(String(describing: title))")
    }

    // MARK: - 5. close(tab:)

    @Test("close はタブ ID を引数に 1 回だけ走る")
    func closeCallsRunnerOnce() throws {
        let runner = FakeRunner()
        let controller = ChromeController(runner: runner)

        controller.close(tab: "1234")

        #expect(runner.calls.count == 1, "呼び出しが 1 回ではない: \(runner.calls.count) 回")
        #expect(runner.calls.first?.arguments == ["1234"], "arguments が [タブ ID] ではない")
    }

    // `close` は `throws` なしなので、エラーを握り潰す契約はシグネチャだけでは足りない
    // （中で fatalError / try! していないこと、runner の失敗で落ちないことをここで見る）。
    @Test("close は runner が throw しても、非 0 でも、gone でも何も起こさない")
    func closeSwallowsEverything() {
        // (1) runner.run 自体が throw。
        let throwing = FakeRunner()
        throwing.enqueue(error: RecError(code: .chromeUnavailable, message: "osascript を起動できませんでした: boom"))
        ChromeController(runner: throwing).close(tab: "1")
        #expect(throwing.calls.count == 1)

        // (2) 非 0 終了（-1743 を含む stderr でも案内に化けない = そもそも throw できない）。
        let failing = FakeRunner()
        failing.enqueue(status: 1, stderr: "execution error: Not authorized ... (-1743)\n")
        ChromeController(runner: failing).close(tab: "2")
        #expect(failing.calls.count == 1)

        // (3) stdout が gone（タブはもう無い）。
        let gone = FakeRunner()
        gone.enqueue(stdout: "gone\n")
        ChromeController(runner: gone).close(tab: "3")
        #expect(gone.calls.count == 1)

        // (4) 打ち切り（status -1）。
        let timedOut = FakeRunner()
        timedOut.enqueue(ScriptResult(status: -1, stdout: "", stderr: "osascript が応答しなかったので打ち切りました"))
        ChromeController(runner: timedOut).close(tab: "4")
        #expect(timedOut.calls.count == 1)
    }
}
