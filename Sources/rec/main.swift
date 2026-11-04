// rec — 実行可能ターゲットの入口。引数を解釈して録音を 1 本組み、終了コードをプロセスに返すだけ。
//
// 役割分担:
//   - 引数 → `Options`: `RecCore.parseArguments`（`Sources/RecCore/CLI.swift`）。ここは何も解釈しない
//   - `--list` の表示 / `--app` の解決 / `-o` の分解: このファイル（`Options` と `RecordingSession` の橋渡し）
//   - 実際の録音: `RecordingSession`（`Sources/RecCore/RecordingSession.swift`）
//
// 断言（PLAN P1）: **`exit()` を呼ぶのはこのファイルだけ**。`Sources/RecCore` 配下は終了コードを
// 値で返すだけ（`RecError.code` / `RecordingSession` の `completion`）でプロセスを殺さない。
// だからライブラリはそのままテストから呼べる。

import Foundation
import RecCore

// MARK: - 橋渡し（`Options` → `RecordingSession` の入力）

/// `--app X` を tap の対象に解決する（PLAN D4。一致判定は前方一致で、使い方は単一ファイル版と同じ）。
///
/// - `X` 自体を必ず先頭に置き、`X.` で始まるバンドル ID（ヘルパープロセス）を出現順で足す
/// - `seed` は今見えているプロセス（`bundleIDs` だけで後から起動したプロセスを拾えるか未確認なので混ぜる）
func resolveAppTarget(_ prefix: String) throws -> TapTarget {
    let matched = try audioProcesses().filter { $0.bundle.hasPrefix(prefix) }
    guard !matched.isEmpty else {
        throw RecError(code: .usage,
                       message: "'\(prefix)' に一致する音声プロセスがありません。再生後に --list で確認してください。")
    }
    var bundleIDs = [prefix]
    for proc in matched where proc.bundle.hasPrefix(prefix + ".") && !bundleIDs.contains(proc.bundle) {
        bundleIDs.append(proc.bundle)
    }
    return .bundleIDs(bundleIDs, seed: matched.map(\.id))
}

/// `-o` の値を `SessionOutput` の 3 要素（親ディレクトリ / 名前 / 拡張子）に分ける。
///
/// `-o` があっても必ず `SessionOutput` 経由にする。`RecordingSession` が `reserveUniquePath` を
/// 通すので、同名のファイルがあれば `-2` / `-3` … が付く。
func sessionOutput(for path: String?) -> SessionOutput {
    guard let path else {
        // 既定: カレントディレクトリに `rec-<日時>.m4a`（名前は `RecordingSession` が決める）。
        return SessionOutput(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                             explicitBaseName: nil,
                             ext: "m4a")
    }
    let url = URL(fileURLWithPath: path)
    return SessionOutput(directory: url.deletingLastPathComponent(),
                         explicitBaseName: url.deletingPathExtension().lastPathComponent,
                         ext: url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
}

// MARK: - 本体

do {
    let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))

    let mode: SessionMode
    switch options.mode {
    case .list:
        // 録音しない。一覧を出して終わる（取得に失敗したら下の catch-all が `.coreAudio` にする）。
        for proc in try audioProcesses() where !proc.bundle.isEmpty {
            print("\(proc.running ? "▶" : " ") \(proc.bundle)")
        }
        exit(ExitCode.ok.rawValue)
    case .system:
        mode = .system
    case .app(let prefix):
        mode = .app(try resolveAppTarget(prefix))
    case .url(let url):
        mode = .url(url)
    }

    let session = RecordingSession(mode: mode,
                                   output: sessionOutput(for: options.output),
                                   adGuardSeconds: options.adGuard,
                                   completion: { code in exit(code.rawValue) })
    session.start()
    // `completion` が `exit()` を呼ぶまでここで待つ（`dispatchMain()` は戻らない）。
    dispatchMain()
} catch let e as RecError {
    FileHandle.standardError.write(Data("error: \(e.message)\n".utf8))
    exit(e.code.rawValue)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(ExitCode.coreAudio.rawValue)
}
