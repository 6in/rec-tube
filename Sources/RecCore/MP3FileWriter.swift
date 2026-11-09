// MP3FileWriter.swift — MP3 で保存する writer。
//
// macOS には MP3 のエンコーダが無いので、録音中はロスレス（ALAC / .caf）の一時ファイルに書き、
// `close()` で ffmpeg（libmp3lame）を呼んで MP3 に変換する。圧縮は 1 回だけで済む。
//
// 断言（この型の契約）:
//   - 1 フレームも書いていなければ変換しない。一時ファイルを消し、`url`（予約済みの 0 バイトの mp3）は
//     呼び出し側（`RecordingSession` の noData 経路）が消す
//   - 変換に成功したら一時ファイルを消す
//   - 変換に失敗したら壊れた mp3 を消し、**`url` を一時ファイルに差し替えて**一時ファイルを残す
//     （`RecordingSession` が保存先として一時ファイルの場所を出す）。エラーは `.outputUnavailable`
//   - エラーはすべて `RecError(code: .outputUnavailable, ...)` に畳む

import AVFoundation
import Foundation

/// 一時ファイルから MP3 を作る関数（テストでは差し替える）。
public typealias MP3Converter = (_ source: URL, _ destination: URL) throws -> Void

/// MP3 で保存する `AudioFileWriting`。
///
/// `@unchecked Sendable`: `AVAudioFileWriter` と同じく IO キュー上でだけ触る規約。
public final class MP3FileWriter: AudioFileWriting, @unchecked Sendable {
    public private(set) var url: URL
    public var framesWritten: AVAudioFramePosition { intermediate.framesWritten }

    /// 録音中の一時ファイル（ALAC / .caf）。
    public let intermediateURL: URL

    private let intermediate: AVAudioFileWriter
    private let convert: MP3Converter
    private var isOpen = true

    /// - Parameters:
    ///   - url: 最終的な mp3 の場所（予約済み）
    ///   - format: tap の format
    ///   - convert: 変換する関数（既定は `ffmpegMP3Converter(ffmpeg:)` を呼び出し側が渡す）
    public init(url: URL, format: AVAudioFormat, convert: @escaping MP3Converter) throws {
        self.url = url
        self.convert = convert
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        intermediateURL = try reserveUniquePath(directory: directory,
                                                baseName: base + ".recording",
                                                ext: "caf")
        do {
            intermediate = try AVAudioFileWriter(url: intermediateURL,
                                                 format: format,
                                                 settings: AVAudioFileWriter.losslessSettings(for: format))
        } catch {
            try? FileManager.default.removeItem(at: intermediateURL)
            throw error
        }
    }

    public func write(_ buf: AVAudioPCMBuffer) throws {
        try intermediate.write(buf)
    }

    public func close() throws {
        guard isOpen else { return }
        isOpen = false
        try intermediate.close()

        guard framesWritten > 0 else {
            try? FileManager.default.removeItem(at: intermediateURL)
            return
        }
        do {
            try convert(intermediateURL, url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            url = intermediateURL
            let reason = (error as? RecError)?.message ?? "\(error)"
            throw RecError(code: .outputUnavailable,
                           message: "MP3 に変換できませんでした: \(reason)\n"
                               + "変換前の音声（ロスレス）を残しました: \(intermediateURL.path)")
        }
        try? FileManager.default.removeItem(at: intermediateURL)
    }
}

// MARK: - ffmpeg

/// ffmpeg の場所を探す。`PATH` に加えて Homebrew の既定の場所も見る
/// （ターミナル以外から起動されると `PATH` に Homebrew が入っていないことがある）。
public func findFFmpeg(environment: [String: String] = ProcessInfo.processInfo.environment,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
    -> URL? {
    let fromPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for directory in fromPath + ["/opt/homebrew/bin", "/usr/local/bin"] where !directory.isEmpty {
        let candidate = (directory as NSString).appendingPathComponent("ffmpeg")
        if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
    }
    return nil
}

/// ffmpeg で MP3 に変換する関数を作る。
public func ffmpegMP3Converter(ffmpeg: URL) -> MP3Converter {
    return { source, destination in
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                             "-i", source.path,
                             "-codec:a", "libmp3lame", "-q:a", "\(Tuning.mp3Quality)",
                             destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw RecError(code: .outputUnavailable, message: "ffmpeg を起動できませんでした: \(error)")
        }
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecError(code: .outputUnavailable,
                           message: "ffmpeg が失敗しました（終了状態 \(process.terminationStatus)）"
                               + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }
}
