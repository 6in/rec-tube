// ScriptRunner.swift — AppleScript を外部プロセスで走らせる口（注入可能）。
//
// 断言: **URL / JS / タブ ID はスクリプト本文に埋め込まない**。必ず `arguments`（= `on run argv`）で渡す。
// 根拠: RESEARCH §3.1。AppleScript の文字列リテラルで意味を持つのは `\` と `"` だけで、
// 実リテラル改行は文字列終端扱いになり構文エラーになる（単一ファイル版の `chromeOpen`（`git show main:rec.swift`）
// がやっていた `"` → `%22` 置換では、`\` と改行を含む URL で壊れる）。
//
// 契約（ここだけが「osascript をどう呼ぶか」を知っている）:
//  1. 組み立てる引数列は常に `["-e", script, "--"] + arguments`（`--` は RESEARCH §2.6）。
//  2. `stdout` / `stderr` は**生のまま**返す（末尾の改行も落とさない）。
//     解釈する側（`ChromeController`）が trim する。
//  3. プロセスを起動できなければ `RecError(.chromeUnavailable)` を throw する。
//  4. `timeout` 秒で応答が無ければ `terminate()` して
//     `ScriptResult(status: -1, stderr: <打ち切りの説明>)` を返す（throw しない）。
//     「応答なし」をエラーにするか待ちにするかは呼び出し側の判断（probe の nil → `.pageUnresponsive` 等）。

import Foundation

/// 外部スクリプトの実行結果。
public struct ScriptResult: Sendable, Equatable {
    /// 終了コード。`osascript` は失敗時に非 0。打ち切り（タイムアウト）は `-1`。
    public let status: Int32
    /// 標準出力（生のまま。末尾の改行を含む）。
    public let stdout: String
    /// 標準エラー（生のまま）。
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// スクリプトを 1 回走らせる口。テストでは `FakeRunner` を差して `osascript` を起動しない。
public protocol ScriptRunner: AnyObject, Sendable {
    /// `script` を走らせ、`arguments` を `on run argv` の引数として渡す。
    ///
    /// - Throws: プロセスを起動できなかったとき `RecError(.chromeUnavailable)`。
    ///   スクリプト自体の失敗（非 0 終了）は throw せず `ScriptResult.status` で返す。
    func run(script: String, arguments: [String]) throws -> ScriptResult
}

/// `/usr/bin/osascript` を使う本番の `ScriptRunner`。
public final class OsascriptRunner: ScriptRunner {
    private let executable: URL
    private let timeout: Double

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/osascript"),
        timeout: Double = Tuning.osascriptTimeoutSeconds
    ) {
        self.executable = executable
        self.timeout = timeout
    }

    /// 組み立てる引数列（テストから検証できるように切り出してある）。
    public static func argumentList(script: String, arguments: [String]) -> [String] {
        ["-e", script, "--"] + arguments
    }

    public func run(script: String, arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.argumentList(script: script, arguments: arguments)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // 終了を待つ前に通知を張る（`run()` の直後に終わっても取りこぼさない）。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw RecError(
                code: .chromeUnavailable,
                message: "osascript を起動できませんでした: \(error.localizedDescription)"
            )
        }

        // パイプの読み出しは別スレッドへ。出力が 64 KB を超えるとパイプが詰まり、
        // 読まずに終了を待つと永久に戻らない。
        let out = DataBox()
        let err = DataBox()
        let reads = DispatchGroup()
        let readQueue = DispatchQueue(label: "rec.osascript.read", attributes: .concurrent)
        readQueue.async(group: reads) {
            out.data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        readQueue.async(group: reads) {
            err.data = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + Tuning.osascriptKillGraceSeconds) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + Tuning.osascriptKillGraceSeconds)
            }
        }

        // パイプが閉じるまで待つ。打ち切った相手が握り続けている場合は諦めて進む。
        _ = reads.wait(timeout: .now() + Tuning.osascriptPipeGraceSeconds)

        let stdout = String(decoding: out.data, as: UTF8.self)
        let stderr = String(decoding: err.data, as: UTF8.self)

        if timedOut {
            let note = "osascript が \(Int(timeout)) 秒以内に応答しなかったので打ち切りました"
            return ScriptResult(
                status: -1,
                stdout: stdout,
                stderr: stderr.isEmpty ? note : "\(note)\n\(stderr)"
            )
        }
        return ScriptResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// 並行キューのクロージャから書き込むための箱（`var` を直接キャプチャできないため）。
///
/// 読みも書きも `NSLock` で守る。`DispatchGroup` の完了だけには頼れない: 打ち切り経路では
/// `reads.wait` が `Tuning.osascriptPipeGraceSeconds` で諦めて先に進むので、読み出しスレッドが
/// まだ書いている最中に本体が `data` を読む可能性がある。
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
