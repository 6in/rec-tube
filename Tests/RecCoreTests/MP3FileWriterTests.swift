// MP3FileWriter のユニットテスト。
//
// 変換は差し替えた関数で見る（成功 / 失敗 / 0 フレーム）。ffmpeg がある環境では実際に変換して
// 出来た MP3 を `AVAudioFile` で読めることも確かめる（無ければその 1 本は飛ばす）。

import AVFoundation
import Foundation
import Testing

@testable import RecCore

@Suite("MP3FileWriter")
struct MP3FileWriterTests {
    private func makeFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    }

    /// 440 Hz の正弦波のバッファ（無音だとエンコーダの挙動が読みにくいので音を入れる）。
    private func makeBuffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for channel in 0 ..< Int(format.channelCount) {
            let data = buf.floatChannelData![channel]
            for i in 0 ..< Int(frames) {
                data[i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 48000)
            }
        }
        return buf
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `RecordingSession` と同じく、mp3 の場所を予約してから writer を作る。
    private func makeWriter(in dir: URL, convert: @escaping MP3Converter) throws -> MP3FileWriter {
        let url = try reserveUniquePath(directory: dir, baseName: "out", ext: "mp3")
        return try MP3FileWriter(url: url, format: makeFormat(), convert: convert)
    }

    @Test("録音中はロスレスの一時ファイル（.caf）に書き、変換に成功したら一時ファイルを消す")
    func convertsAndRemovesIntermediate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var converted: (URL, URL)?
        let writer = try makeWriter(in: dir) { source, destination in
            converted = (source, destination)
            try Data("mp3".utf8).write(to: destination)
        }
        #expect(writer.intermediateURL.lastPathComponent == "out.recording.caf")
        try writer.write(makeBuffer(makeFormat(), frames: 4800))
        try writer.close()

        #expect(converted?.0 == writer.intermediateURL)
        #expect(converted?.1.lastPathComponent == "out.mp3")
        #expect(writer.url.lastPathComponent == "out.mp3")
        #expect(writer.framesWritten == 4800)
        #expect(!FileManager.default.fileExists(atPath: writer.intermediateURL.path), "一時ファイルが残った")
        #expect(FileManager.default.fileExists(atPath: writer.url.path))
    }

    @Test("変換に失敗したら壊れた mp3 を消し、url を一時ファイルに差し替えて残す（.outputUnavailable）")
    func keepsIntermediateOnFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = try makeWriter(in: dir) { _, destination in
            try Data("broken".utf8).write(to: destination)
            throw RecError(code: .outputUnavailable, message: "fake ffmpeg failure")
        }
        try writer.write(makeBuffer(makeFormat(), frames: 4800))
        #expect {
            try writer.close()
        } throws: { error in
            guard let error = error as? RecError else { return false }
            return error.code == .outputUnavailable
                && error.message.contains("fake ffmpeg failure")
                && error.message.contains(writer.intermediateURL.path)
        }
        #expect(writer.url == writer.intermediateURL)
        #expect(FileManager.default.fileExists(atPath: writer.intermediateURL.path), "一時ファイルが消えた")
        let mp3 = dir.appendingPathComponent("out.mp3")
        #expect(!FileManager.default.fileExists(atPath: mp3.path), "壊れた mp3 が残った")
        // 2 回目の close は何もしない（投げない）。
        try writer.close()
    }

    @Test("1 フレームも書いていなければ変換せず、一時ファイルを消す")
    func skipsConversionWithoutFrames() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var calls = 0
        let writer = try makeWriter(in: dir) { _, _ in calls += 1 }
        try writer.close()

        #expect(calls == 0)
        #expect(!FileManager.default.fileExists(atPath: writer.intermediateURL.path))
        #expect(writer.url.lastPathComponent == "out.mp3")
    }

    @Test("ffmpeg で実際に変換し、MP3 として読める", .enabled(if: findFFmpeg() != nil))
    func convertsWithRealFFmpeg() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ffmpeg = try #require(findFFmpeg())
        let writer = try makeWriter(in: dir, convert: ffmpegMP3Converter(ffmpeg: ffmpeg))
        for _ in 0 ..< 10 {
            try writer.write(makeBuffer(makeFormat(), frames: 4800))
        }
        try writer.close()

        let file = try AVAudioFile(forReading: writer.url)
        #expect(file.fileFormat.channelCount == 2)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 1.0) < 0.1, "長さが 1 秒前後ではない: \(seconds)")
        #expect(!FileManager.default.fileExists(atPath: writer.intermediateURL.path))
    }

    @Test("findFFmpeg は PATH を先に、無ければ Homebrew の既定の場所を見る")
    func findsFFmpeg() {
        #expect(findFFmpeg(environment: ["PATH": "/a:/b"], isExecutable: { $0 == "/b/ffmpeg" })?.path
            == "/b/ffmpeg")
        #expect(findFFmpeg(environment: ["PATH": "/a"], isExecutable: { $0 == "/opt/homebrew/bin/ffmpeg" })?.path
            == "/opt/homebrew/bin/ffmpeg")
        #expect(findFFmpeg(environment: [:], isExecutable: { _ in false }) == nil)
    }
}
