// ToneAnalyzer / ToneFiles のユニットテスト（PLAN T10 サブ作業 A の完了基準）。
//
// Core Audio には触らない（合成した正弦波を WAV に書いて読み直すだけ）。
// 一時ディレクトリは `FileManager.default.temporaryDirectory` 配下に UUID 名で作り、
// テストの最後に必ず消す（`AudioFileWriterTests` / `OutputPathTests` と同じ流儀）。
//
// 期待値は実装ではなく契約から書いている。食い違ったら実装のバグ。

import AVFoundation
import Foundation
import Testing

@testable import RecCore

@Suite("ToneAnalyzer")
struct ToneAnalyzerTests {
    // MARK: - helpers

    /// 検証用の固定サンプルレート（`writeTone` の既定と同じ）。
    private let sampleRate = 48000.0

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 後片付け。失敗しても握り潰す（テスト結果に影響させない）。
    private func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 任意のサンプル列を 16 bit PCM / 1ch の WAV として書く（`writeTone` と同じファイル形式）。
    ///
    /// `writeTone` は 1 周波数しか書けないので、「中央だけ別の周波数」のような信号はこれで作る。
    private func writeSamples(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let chunk = 4096
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(chunk)))
        let channel = try #require(buffer.floatChannelData?[0])

        var written = 0
        while written < samples.count {
            let take = min(chunk, samples.count - written)
            for frame in 0 ..< take {
                channel[frame] = samples[written + frame]
            }
            buffer.frameLength = AVAudioFrameCount(take)
            try file.write(from: buffer)
            written += take
        }
        file.close()
    }

    /// `hz` の正弦波を `frames` フレームぶん。位相は 0 から始まる。
    private func sine(hz: Double, frames: Int, amplitude: Double = 0.5) -> [Float] {
        let radiansPerFrame = 2.0 * Double.pi * hz / sampleRate
        return (0 ..< frames).map { Float(amplitude * sin(radiansPerFrame * Double($0))) }
    }

    // MARK: - analyze

    @Test("440 Hz 12 秒は全部が本編の窓になる（広告の窓は 0）")
    func pureMainToneHasNoAdWindows() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("main.wav")

        try writeTone(url: url, hz: 440, seconds: 12)

        let verdict = try analyze(url: url, mainHz: 440, adHz: 1000)
        #expect(verdict.adWindows == 0)
        #expect(abs(verdict.mainSeconds - 12.0) < 0.5)
    }

    @Test("中央 1 秒だけ 1 kHz にすると広告の窓が 10 個前後になる")
    func centerAdToneIsCountedAsAdWindows() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("mixed.wav")

        // 12 秒のうち 5.5〜6.5 秒だけ 1 kHz。窓は 0.1 秒なので 10 窓ぶんが広告になる。
        let second = Int(sampleRate)
        let head = sine(hz: 440, frames: Int(5.5 * sampleRate))
        let middle = sine(hz: 1000, frames: second)
        let tail = sine(hz: 440, frames: Int(5.5 * sampleRate))
        try writeSamples(head + middle + tail, to: url)

        let verdict = try analyze(url: url, mainHz: 440, adHz: 1000)
        #expect(verdict.adWindows >= 9)
        #expect(verdict.adWindows <= 11)
    }

    // MARK: - isAllZero

    @Test("全ゼロのファイルは isAllZero が true")
    func allZeroFileIsAllZero() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("zero.wav")

        try writeSamples([Float](repeating: 0, count: Int(sampleRate)), to: url)

        #expect(try isAllZero(url: url) == true)
    }

    @Test("-70 dBFS の微小な正弦波は isAllZero が false（しきい値判定をしない）")
    func quietNoiseIsNotAllZero() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("quiet.wav")

        // -70 dBFS 相当の振幅（10^(-70/20) ≈ 0.000316）。16 bit の量子化段（≈ 3.05e-5）より
        // 十分大きいので、WAV に書いて読み直しても 0 にはならない。
        try writeTone(url: url, hz: 440, seconds: 1, amplitude: pow(10.0, -70.0 / 20.0))

        #expect(try isAllZero(url: url) == false)
    }

    // MARK: - writeTone

    @Test("writeTone で書いた WAV を読み戻すと長さが一致する")
    func writeToneProducesRequestedDuration() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("tone.wav")

        try writeTone(url: url, hz: 440, seconds: 2.5)

        let read = try AVAudioFile(forReading: url)
        let seconds = Double(read.length) / read.processingFormat.sampleRate
        #expect(abs(seconds - 2.5) < 0.05)
    }
}
