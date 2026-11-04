import Foundation
import Testing

@testable import RecCore

/// `Sources/RecCore/CLI.swift` の契約（PLAN T4 の「必ず満たす断言」1〜11 と検証表）を検証する。
/// 期待値は実装ではなく契約から書いている（実装は読んでいない）。食い違ったら実装のバグ。

// MARK: - 共通ヘルパー

/// 不正な引数列は必ず `RecError(code: .usage)` を throw し、
/// その `message` に `usageText` が丸ごと含まれること（断言 6・7）を確かめる。
private func expectUsageError(
    _ args: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let options = try parseArguments(args)
        #expect(
            Bool(false),
            "\(args) は .usage を throw すべきなのに \(options) を返した",
            sourceLocation: sourceLocation
        )
    } catch let error as RecError {
        // 断言 6: code は必ず .usage（= 1）。他の code にはならない。
        #expect(error.code == .usage, "\(args) の code", sourceLocation: sourceLocation)
        #expect(error.code.rawValue == 1, "\(args) の code の rawValue", sourceLocation: sourceLocation)
        // 断言 7: message には usageText が丸ごと含まれる。
        #expect(
            error.message.contains(usageText),
            "\(args) の message に usageText が含まれていない",
            sourceLocation: sourceLocation
        )
    } catch {
        #expect(
            Bool(false),
            "\(args) は RecError 以外を throw した: \(error)",
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - モード（断言 1・2・3）

/// 引数なしは `.system` モードで、`output` は nil、`adGuard` は既定値（断言 1）。
@Test("parseArguments with no arguments returns the system mode defaults")
func cliNoArgumentsIsSystemMode() throws {
    let options = try parseArguments([])
    #expect(options == Options(mode: .system, output: nil, adGuard: Tuning.adGuardSeconds))
    #expect(options.mode == .system)
    #expect(options.output == nil)
    #expect(options.adGuard == Tuning.adGuardSeconds)
}

/// `--list` は `.list` モード（断言 2）。残りは既定値のまま。
@Test("--list selects the list mode")
func cliListMode() throws {
    let options = try parseArguments(["--list"])
    #expect(options == Options(mode: .list, output: nil, adGuard: Tuning.adGuardSeconds))
}

/// `--app <値>` は `.app(値)`（断言 3）。
@Test("--app takes the next argument as the app name")
func cliAppMode() throws {
    let options = try parseArguments(["--app", "Music"])
    #expect(options.mode == .app("Music"))
}

/// `--url <値>` は `.url(値)`（断言 3）。値は加工されずそのまま入る。
@Test("--url takes the next argument as the url")
func cliURLMode() throws {
    let options = try parseArguments(["--url", "https://x.test/v"])
    #expect(options.mode == .url("https://x.test/v"))
}

// MARK: - 値を取る引数（断言 4）

/// `-o <値>` は `output == 値`（断言 4）。
@Test("-o sets the output path")
func cliOutputOption() throws {
    let options = try parseArguments(["-o", "out.m4a"])
    #expect(options.output == "out.m4a")
    #expect(options.mode == .system)
}

/// `--ad-guard <数値>` は `adGuard == その数値`（断言 4）。
@Test("--ad-guard sets the ad guard seconds")
func cliAdGuardOption() throws {
    let options = try parseArguments(["--ad-guard", "2.5"])
    #expect(options.adGuard == 2.5)
}

/// モード・`-o`・`--ad-guard` は同時に指定できる。
@Test("mode, -o and --ad-guard combine into one Options")
func cliCombinedOptions() throws {
    let options = try parseArguments(["--url", "https://x.test/v", "-o", "out.m4a", "--ad-guard", "2"])
    #expect(options == Options(mode: .url("https://x.test/v"), output: "out.m4a", adGuard: 2))
}

// MARK: - モードの後勝ち（断言 5）

/// モードが複数あったら最後に来たものが勝つ（断言 5）。
@Test(
    "the last mode argument wins",
    arguments: [
        (["--app", "a", "--url", "https://x.test/v"], Options.Mode.url("https://x.test/v")),
        (["--url", "https://x.test/v", "--app", "a"], Options.Mode.app("a")),
        (["--list", "--app", "a"], Options.Mode.app("a")),
        (["--app", "a", "--list"], Options.Mode.list),
        (["--app", "a", "--app", "b"], Options.Mode.app("b")),
    ]
)
func cliLastModeWins(args: [String], expected: Options.Mode) throws {
    let options = try parseArguments(args)
    #expect(options.mode == expected)
}

// MARK: - PLAN の検証表（throw する行）

/// 未知の引数は `.usage`（断言 11 / 検証表 `["--bogus"]`）。
@Test("an unknown argument is a usage error")
func cliUnknownArgument() {
    expectUsageError(["--bogus"])
}

/// 値を取る引数で値が無いまま引数列が終わったら `.usage`（断言 10 / 検証表 `["--url"]`）。
@Test(
    "a value-taking argument without a value is a usage error",
    arguments: [
        ["--url"],
        ["--app"],
        ["-o"],
        ["--ad-guard"],
    ]
)
func cliMissingValue(args: [String]) {
    expectUsageError(args)
}

/// `--url` の値が条件を満たさないときは `.usage`（断言 8 / 検証表の `not a url` と `https://`）。
///
/// - `"not a url"`: `URL(string:)` で解釈できない（または scheme が無い）。
/// - `"https://"`: scheme は https だが host が空。
/// - `"ftp://x.test/a"`: scheme が http / https / file のどれでもない。
@Test(
    "--url rejects values outside the allowed scheme/host conditions",
    arguments: [
        "not a url",
        "https://",
        "http://",
        "ftp://x.test/a",
    ]
)
func cliInvalidURL(value: String) {
    expectUsageError(["--url", value])
}

/// `--ad-guard` の値が条件を満たさないときは `.usage`（断言 9 / 検証表の `-1`・`abc`・`11`）。
///
/// `inf` / `nan` は `Double` に変換できるが有限ではないので弾かれる。
@Test(
    "--ad-guard rejects non-numeric, non-finite and out-of-range values",
    arguments: [
        "-1",
        "abc",
        "11",
        "10.1",
        "-0.1",
        "inf",
        "nan",
        "",
    ]
)
func cliInvalidAdGuard(value: String) {
    expectUsageError(["--ad-guard", value])
}

// MARK: - PLAN の検証表（成功する行）

/// `file:` の URL は host が空でも通る（検証表 `["--url", "file:///x.html?v=1"]`）。
@Test("--url accepts a file URL with an empty host")
func cliFileURL() throws {
    let options = try parseArguments(["--url", "file:///x.html?v=1"])
    #expect(options.mode == .url("file:///x.html?v=1"))
}

/// `http` / `https` で host があれば通る（断言 8）。
@Test(
    "--url accepts http and https URLs that have a host",
    arguments: [
        "https://x.test/v",
        "http://x.test/v",
        "https://x.test/watch?v=abc",
    ]
)
func cliValidHTTPURL(value: String) throws {
    let options = try parseArguments(["--url", value])
    #expect(options.mode == .url(value))
}

/// `Tuning.adGuardRange` の境界は含む（検証表 `["--ad-guard", "0"]` と上端 10）。
@Test(
    "--ad-guard accepts the inclusive bounds of Tuning.adGuardRange",
    arguments: [
        ("0", 0.0),
        ("10", 10.0),
        ("0.0", 0.0),
        ("4.5", 4.5),
    ]
)
func cliValidAdGuard(value: String, expected: Double) throws {
    let options = try parseArguments(["--ad-guard", value])
    #expect(options.adGuard == expected)
    #expect(Tuning.adGuardRange.contains(options.adGuard))
}

// MARK: - `-o` の分解（検証表 E16 / E17 / E18）

/// `splitOutputPath` も不正な値は必ず `RecError(code: .usage)` + `usageText` で返すこと
/// （`parseArguments` と同じ作法）。
private func expectOutputUsageError(
    _ path: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let output = try splitOutputPath(path)
        #expect(
            Bool(false),
            "-o '\(path)' は .usage を throw すべきなのに \(output.directory.path) を返した",
            sourceLocation: sourceLocation
        )
    } catch let error as RecError {
        #expect(error.code == .usage, "-o '\(path)' の code", sourceLocation: sourceLocation)
        #expect(
            error.message.contains(usageText),
            "-o '\(path)' の message に usageText が含まれていない",
            sourceLocation: sourceLocation
        )
    } catch {
        #expect(
            Bool(false),
            "-o '\(path)' は RecError 以外を throw した: \(error)",
            sourceLocation: sourceLocation
        )
    }
}

/// E16: `-o ''`（空文字列）は usage エラー。
@Test("splitOutputPath rejects an empty path")
func cliSplitOutputEmptyPath() {
    expectOutputUsageError("")
}

/// E17（既存のディレクトリ）: そのディレクトリ + 名前は `RecordingSession` 任せ + `m4a`。
@Test("splitOutputPath treats an existing directory as a destination directory")
func cliSplitOutputExistingDirectory() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rec-cli-split-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 末尾に `/` を付けずに渡して「既存のディレクトリ」の判定だけを確かめる。
    let output = try splitOutputPath(dir.path)
    #expect(output.directory.path == dir.path)
    #expect(output.explicitBaseName == nil)
    #expect(output.ext == "m4a")
}

/// E17（末尾が `/`）: 存在しなくてもディレクトリ指定として扱う。
@Test("splitOutputPath treats a trailing slash as a destination directory")
func cliSplitOutputTrailingSlash() throws {
    let output = try splitOutputPath("out/sub/")
    #expect(output.directory.lastPathComponent == "sub")
    #expect(output.explicitBaseName == nil)
    #expect(output.ext == "m4a")
}

/// E18: 拡張子が `m4a` 以外なら usage エラー。
@Test("splitOutputPath rejects an extension other than m4a")
func cliSplitOutputWrongExtension() {
    expectOutputUsageError("x.wav")
}

/// 名前の中のドットは名前の一部（`a.b.m4a` → base は `a.b`）。
@Test("splitOutputPath keeps dots inside the base name")
func cliSplitOutputDottedBaseName() throws {
    let output = try splitOutputPath("a.b.m4a")
    #expect(output.explicitBaseName == "a.b")
    #expect(output.ext == "m4a")
}

/// 親ディレクトリ付きのパスは directory と base に分かれる。
@Test("splitOutputPath splits a path with a parent directory")
func cliSplitOutputWithParentDirectory() throws {
    let output = try splitOutputPath("dir/sub.m4a")
    #expect(output.directory.lastPathComponent == "dir")
    #expect(output.explicitBaseName == "sub")
    #expect(output.ext == "m4a")
}
