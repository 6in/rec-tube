import Testing

@testable import RecCore

import Darwin
import Dispatch
import Foundation

/// `Sources/RecCore/OutputPath.swift` の契約（PLAN T3 サブ作業 C の「必ず満たす断言」）を検証する。
/// 期待値は実装ではなく契約から書いている。食い違ったら実装のバグ。

// MARK: - テスト用の一時ディレクトリ

/// `FileManager.default.temporaryDirectory/<UUID>` を作り、`body` の後に必ず消す。
///
/// 書き込み不可テストで `chmod 0500` にしても消せるよう、削除前に `0700` へ戻す。
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir.path)
        try? fm.removeItem(at: dir)
    }
    return try body(dir)
}

/// 並行テストで返り値を集める箱（収集はロックで保護する）。
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    private(set) var failures: [String] = []

    func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func record(failure: String) {
        lock.lock()
        failures.append(failure)
        lock.unlock()
    }
}

// MARK: - sanitizeFileName

/// `/` と `:` は `_` になる。
@Test("sanitizeFileName replaces path separators with underscores")
func sanitizeReplacesSeparators() {
    #expect(sanitizeFileName("a/b:c") == "a_b_c")
}

/// 先頭の `.` は落ちる（隠しファイルにしない）。
@Test("sanitizeFileName drops a leading dot")
func sanitizeDropsLeadingDot() {
    #expect(sanitizeFileName(".hidden") == "hidden")
}

/// 空文字列とピリオドだけの文字列は `nil`。
@Test(
    "sanitizeFileName returns nil when nothing usable remains",
    arguments: ["", "..."]
)
func sanitizeReturnsNilForEmptyResult(input: String) {
    #expect(sanitizeFileName(input) == nil)
}

/// 200 バイト超はマルチバイト文字を割らずに切る（🎵 ×100 = 400 バイト）。
@Test("sanitizeFileName truncates to 200 UTF-8 bytes without splitting characters")
func sanitizeTruncatesAtCharacterBoundary() throws {
    let input = String(repeating: "🎵", count: 100)
    let result = try #require(sanitizeFileName(input))

    let bytes = Array(result.utf8)
    // UTF-8 で 200 バイト以下。
    #expect(bytes.count <= 200)
    // バイト列を読み直しても同じ文字列（= 壊れた UTF-8 になっていない）。
    #expect(String(decoding: bytes, as: UTF8.self) == result)
    // 置換文字 U+FFFD が混ざっていない = 文字の途中で切っていない。
    #expect(!result.unicodeScalars.contains("\u{FFFD}"))
    // 🎵 は 4 バイトなので 200 / 4 = 50 文字ちょうど。
    #expect(result.allSatisfy { $0 == "🎵" })
    #expect(result.count == 50)
}

/// 3 バイト文字は 66 文字（198 バイト）で止まる（67 文字 = 201 バイトは上限超え）。
@Test("sanitizeFileName truncates 3-byte characters to 66 characters (198 bytes)")
func sanitizeTruncatesThreeByteCharacters() throws {
    let input = String(repeating: "あ", count: 100)
    #expect(input.utf8.count == 300)

    let result = try #require(sanitizeFileName(input))
    #expect(result.count == 66)
    #expect(result.utf8.count == 198)
    #expect(result.allSatisfy { $0 == "あ" })
}

/// 基底文字 + 結合文字の Character が 200 バイト目をまたぐとき、結合文字だけを切り離さない。
///
/// 素材は `"a" × 197` + `(ア + U+0301)` × 10。1 クラスタは 5 バイト（3 + 2）で NFC では合成されない。
/// スカラ単位で切る実装なら 197 + 3 = 200 バイトまで入り、末尾が基底から切り離された `ア` になる。
/// Character 単位で切る契約なら、クラスタ全体（5 バイト）が入らないので `"a" × 197` で止まる。
@Test("sanitizeFileName keeps a combining mark attached to its base at the 200-byte cut")
func sanitizeDoesNotSplitCombiningMarks() throws {
    let cluster = "\u{30A2}\u{0301}"
    #expect(cluster.count == 1)
    #expect(cluster.utf8.count == 5)
    // NFC で合成されない（合成されると素材の前提が崩れる）。
    #expect(cluster.precomposedStringWithCanonicalMapping == cluster)

    let input = String(repeating: "a", count: 197) + String(repeating: cluster, count: 10)
    let result = try #require(sanitizeFileName(input))

    #expect(result.utf8.count <= 200)
    #expect(result == String(repeating: "a", count: 197))
    // 基底から切り離された結合文字も、基底だけ残った半端なクラスタも無い。
    #expect(!result.unicodeScalars.contains("\u{0301}"))
    #expect(!result.unicodeScalars.contains("\u{30A2}"))
    // Character 境界が保たれている = NFC 済みの入力の Character 列の接頭辞そのもの。
    let normalized = Array(input.precomposedStringWithCanonicalMapping)
    #expect(Array(result) == Array(normalized.prefix(result.count)))
}

/// 200 バイトで切った直後の末尾が空白 / ピリオドになる素材では、もう一度落とす。
///
/// 素材は `"a" × 199` + 空白（またはピリオド）+ `"b" × 50`。200 バイト目がちょうど空白 /
/// ピリオドなので、切ったあとに末尾を落とし直さないと末尾の空白 / ピリオドが残ってしまう。
@Test(
    "sanitizeFileName trims a trailing space or period exposed by the 200-byte cut",
    arguments: [" ", "."]
)
func sanitizeTrimsTrailingAfterTruncation(trailing: String) throws {
    let input = String(repeating: "a", count: 199) + trailing + String(repeating: "b", count: 50)
    let result = try #require(sanitizeFileName(input))

    #expect(result == String(repeating: "a", count: 199))
    #expect(result.utf8.count == 199)
    let last = try #require(result.last)
    #expect(last != ".")
    #expect(!last.isWhitespace)
}

/// NFD の「ガ」は NFC の 1 文字（U+30AC）になる。
@Test("sanitizeFileName normalizes NFD to NFC")
func sanitizeNormalizesToNFC() throws {
    let result = try #require(sanitizeFileName("\u{30AB}\u{3099}"))
    #expect(result == "\u{30AC}")
    #expect(Array(result.unicodeScalars) == ["\u{30AC}"])
}

/// 末尾の空白とピリオドは落ちる。
@Test("sanitizeFileName trims trailing spaces and periods")
func sanitizeTrimsTrailingSpacesAndPeriods() {
    #expect(sanitizeFileName("name. ") == "name")
}

/// C0 / C1 / Zl の制御文字はすべて `_` になる。
@Test(
    "sanitizeFileName replaces control characters with underscores",
    arguments: ["\u{1}", "\u{7f}", "\u{85}", "\u{2028}"]
)
func sanitizeReplacesControlCharacters(control: String) {
    #expect(sanitizeFileName("a\(control)b") == "a_b")
}

// MARK: - sanitizeForTerminal（F4 / E21）

/// `Cc` / `Cf` / `Zl` / `Zp` はすべて `_` になる。
///
/// `sanitizeFileName` との違いは **`Cf`（ZWJ・RLO 等）も落とす**こと（端末の表示を偽装されるより
/// 絵文字の連結が壊れるほうがましな場所。`sanitizeFileName` は逆の判断）。
@Test(
    "sanitizeForTerminal replaces control, format and separator scalars",
    arguments: ["\u{0}", "\n", "\r", "\u{1B}", "\u{07}", "\u{7F}", "\u{85}",
                "\u{200D}", "\u{202E}", "\u{2028}", "\u{2029}"]
)
func sanitizeForTerminalReplacesDisallowedScalars(control: String) {
    #expect(sanitizeForTerminal("a\(control)b") == "a_b")
}

/// `/` と `:` は残す（ファイル名ではないので無害。消すと原文が読めなくなる）。
@Test("sanitizeForTerminal keeps path punctuation")
func sanitizeForTerminalKeepsPathPunctuation() {
    #expect(sanitizeForTerminal("a/b:c") == "a/b:c")
}

/// 境界: 空文字列・64 バイトちょうど・64 バイト超・マルチバイト文字・結合文字。
@Test("sanitizeForTerminal truncates at 64 UTF-8 bytes without splitting characters")
func sanitizeForTerminalBoundaries() {
    // 空文字列はそのまま空文字列（`nil` に落とす契約ではない）。
    #expect(sanitizeForTerminal("") == "")

    // 64 バイトちょうどは切らない。
    let exact = String(repeating: "a", count: 64)
    #expect(sanitizeForTerminal(exact) == exact)
    // 65 バイトは 64 バイトに切る。
    #expect(sanitizeForTerminal(exact + "b") == exact)

    // 4 バイト文字（🎵）は 16 個（64 バイト）で止まる。17 個目を割らない。
    let truncatedNotes = sanitizeForTerminal(String(repeating: "🎵", count: 17))
    #expect(truncatedNotes == String(repeating: "🎵", count: 16))
    #expect(truncatedNotes.utf8.count == 64)

    // 基底 + 結合文字のクラスタが 64 バイト目をまたぐとき、結合文字だけを切り離さない。
    // 素材は `"a" × 61`（61 バイト）+ (ア + U+0301)（3 + 2 = 5 バイト）= 66 バイト。
    // **スカラ単位で切る実装なら** `ア`（3 バイト）だけ入って 64 バイトになり、結合文字が落ちる。
    // Character 単位で切る契約なら、クラスタ全体が入らないので `"a" × 61` で止まる。
    let cluster = String(repeating: "a", count: 61) + "ア\u{301}"
    #expect(cluster.utf8.count == 66, "素材の前提が崩れている: \(cluster.utf8.count)")
    #expect(sanitizeForTerminal(cluster) == String(repeating: "a", count: 61))

    // 長い文字列に制御文字が混ざっていても、切った結果に制御文字は残らない。
    let long = String(repeating: "x", count: 70) + "\u{1B}"
    #expect(!sanitizeForTerminal(long).contains("\u{1B}"))
    #expect(sanitizeForTerminal(long).utf8.count == 64)
}

// MARK: - defaultBaseName

/// 固定の `Date` に対して `rec-` + 8 桁 + `-` + 6 桁の形になる。
@Test("defaultBaseName produces rec-yyyyMMdd-HHmmss")
func defaultBaseNameShape() {
    let name = defaultBaseName(now: Date(timeIntervalSince1970: 1_793_000_000))

    #expect(name.hasPrefix("rec-"))
    #expect(name.count == 4 + 8 + 1 + 6)

    let body = name.dropFirst(4)
    let parts = body.split(separator: "-", omittingEmptySubsequences: false)
    #expect(parts.count == 2)
    #expect(parts.first?.count == 8)
    #expect(parts.last?.count == 6)
    #expect(body.allSatisfy { $0.isNumber || $0 == "-" })
}

// MARK: - reserveUniquePath

/// 空のディレクトリでは連番なしの `name.m4a` が返り、空ファイルが残る。
@Test("reserveUniquePath creates name.m4a in an empty directory")
func reserveCreatesFirstName() throws {
    try withTemporaryDirectory { dir in
        let url = try reserveUniquePath(directory: dir, baseName: "a")
        #expect(url.lastPathComponent == "a.m4a")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

/// `a.m4a` と `a-2.m4a` が既にあれば `a-3.m4a` が返る（PLAN 落とし穴 P5）。
@Test("reserveUniquePath skips existing names and returns a-3.m4a")
func reserveSkipsExistingNames() throws {
    try withTemporaryDirectory { dir in
        for name in ["a.m4a", "a-2.m4a"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let url = try reserveUniquePath(directory: dir, baseName: "a")
        #expect(url.lastPathComponent == "a-3.m4a")
    }
}

/// `ext` が空文字列なら拡張子を付けない（`name` / `name-2`）。
@Test("reserveUniquePath omits the extension when ext is empty")
func reserveWithEmptyExtension() throws {
    try withTemporaryDirectory { dir in
        let first = try reserveUniquePath(directory: dir, baseName: "a", ext: "")
        #expect(first.lastPathComponent == "a")
        let second = try reserveUniquePath(directory: dir, baseName: "a", ext: "")
        #expect(second.lastPathComponent == "a-2")
    }
}

/// `EEXIST` 以外の errno は全部 `.outputUnavailable`（存在しないディレクトリ = `ENOENT`）。
@Test("reserveUniquePath maps ENOENT to outputUnavailable")
func reserveMapsENOENT() throws {
    try withTemporaryDirectory { dir in
        let missing = dir.appendingPathComponent("no-such-dir", isDirectory: true)
        let error = #expect(throws: RecError.self) {
            try reserveUniquePath(directory: missing, baseName: "a")
        }
        #expect(error?.code == .outputUnavailable)
        #expect(error?.message.contains(missing.path) == true)
    }
}

/// `EEXIST` 以外の errno は全部 `.outputUnavailable`（書き込み不可ディレクトリ = `EACCES`）。
@Test("reserveUniquePath maps EACCES to outputUnavailable")
func reserveMapsEACCES() throws {
    try withTemporaryDirectory { dir in
        let readOnly = dir.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o500)],
                                              ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                                   ofItemAtPath: readOnly.path)
        }

        let error = #expect(throws: RecError.self) {
            try reserveUniquePath(directory: readOnly, baseName: "a")
        }
        #expect(error?.code == .outputUnavailable)
        #expect(error?.message.contains(readOnly.path) == true)
    }
}

/// 連番が 1000 まで埋まっていたら `.outputUnavailable`。
@Test("reserveUniquePath gives up after 1000 candidates")
func reserveGivesUpAfter1000() throws {
    try withTemporaryDirectory { dir in
        // `a.m4a` と `a-2.m4a` … `a-1000.m4a` を全部埋める。
        try Data().write(to: dir.appendingPathComponent("a.m4a"))
        for i in 2...1000 {
            try Data().write(to: dir.appendingPathComponent("a-\(i).m4a"))
        }

        let error = #expect(throws: RecError.self) {
            try reserveUniquePath(directory: dir, baseName: "a")
        }
        #expect(error?.code == .outputUnavailable)

        // 1001 番目は作られていない（上限を超えて確保しない）。
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a-1001.m4a").path))
    }
}

/// 10 スレッドが同時に同じ baseName を要求しても、返る 10 個の URL は全部別（PLAN 落とし穴 P6）。
@Test("reserveUniquePath hands out distinct paths to concurrent callers")
func reserveIsAtomicUnderConcurrency() throws {
    try withTemporaryDirectory { dir in
        let collector = URLCollector()
        let iterations = 10

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            do {
                collector.record(try reserveUniquePath(directory: dir, baseName: "a"))
            } catch {
                collector.record(failure: "\(error)")
            }
        }

        #expect(collector.failures.isEmpty)
        #expect(collector.urls.count == iterations)
        #expect(Set(collector.urls.map(\.path)).count == iterations)
    }
}
