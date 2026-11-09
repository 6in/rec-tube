// rec — 実行可能ターゲットの入口。引数を解釈して録音を 1 本組み、終了コードをプロセスに返すだけ。
//
// 役割分担:
//   - 引数 → `Options`: `RecCore.parseArguments`（`Sources/RecCore/CLI.swift`）。ここは何も解釈しない
//   - `--list` の表示 / `--app` の解決: このファイル（`Options` と `RecordingSession` の橋渡し）
//   - `-o` の分解: `RecCore.splitOutputPath`（`Sources/RecCore/CLI.swift`）
//   - 実際の録音: `RecordingSession`（`Sources/RecCore/RecordingSession.swift`）
//
// 断言（PLAN P1）: **`exit()` を呼ぶのはこのファイルだけ**。`Sources/RecCore` 配下は終了コードを
// 値で返すだけ（`RecError.code` / `RecordingSession` の `completion`）でプロセスを殺さない。
// だからライブラリはそのままテストから呼べる。

import AVFoundation
import Foundation
import RecCore

// パイプの読み手が先に閉じても `print` で死なない（E14）。出力の失敗は黙って捨てる。
// **トップレベルの先頭**で張る（`--list` の `print` より前であること）。
_ = signal(SIGPIPE, SIG_IGN)

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

    // `-o` があれば分解する（不正なら `.usage` が飛ぶ）。無ければカレントディレクトリに
    // `rec-<日時>.m4a`（名前は `RecordingSession` が決める）。
    let output: SessionOutput
    if let path = options.output {
        output = try splitOutputPath(path, ext: options.format.rawValue)
    } else {
        output = SessionOutput(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                               explicitBaseName: nil,
                               ext: options.format.rawValue)
    }

    // 保存形式ごとの writer。MP3 は ffmpeg が無ければ録音を始める前に止める。
    let makeWriter: (URL, AVAudioFormat) throws -> AudioFileWriting
    switch options.format {
    case .m4a:
        makeWriter = { try AVAudioFileWriter(url: $0, format: $1) }
    case .mp3:
        guard let ffmpeg = findFFmpeg() else {
            throw RecError(code: .outputUnavailable, message: Messages.ffmpegMissing)
        }
        let convert = ffmpegMP3Converter(ffmpeg: ffmpeg)
        makeWriter = { try MP3FileWriter(url: $0, format: $1, convert: convert) }
    }

    let session = RecordingSession(mode: mode,
                                   output: output,
                                   adGuardSeconds: options.adGuard,
                                   startDelaySeconds: options.startDelay,
                                   makeWriter: makeWriter,
                                   completion: { code in exit(code.rawValue) })
    session.start()
    // `completion` が `exit()` を呼ぶまでここで待つ（`dispatchMain()` は戻らない）。
    dispatchMain()
} catch let e as RecError {
    // fd 2 が閉じていても死なない（E13）。出力の失敗は黙って捨てて終了コードだけ返す。
    writeStderr("error: \(e.message)")
    exit(e.code.rawValue)
} catch {
    writeStderr("error: \(error)")
    exit(ExitCode.coreAudio.rawValue)
}
