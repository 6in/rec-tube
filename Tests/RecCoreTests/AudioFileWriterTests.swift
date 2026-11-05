// AVAudioFileWriter / FakeWriter のユニットテスト。
//
// Core Audio には触らない（無音の `AVAudioPCMBuffer` を自前で作って書くだけ）。
// 一時ディレクトリは `FileManager.default.temporaryDirectory` 配下に UUID 名で作り、
// テストの最後に必ず消す（`chmod 0500` にしたものは消す前に 0700 に戻す）。

import AVFoundation
import Foundation
import Testing

@testable import RecCore

@Suite("AVAudioFileWriter")
struct AudioFileWriterTests {
    // MARK: - helpers

    /// tap から来る形式に合わせた 48 kHz / 2ch（float32 non-interleaved）。
    private func makeFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    }

    /// 無音のバッファ（`frameLength` だけ立てる）。
    private func makeBuffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        return buf
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 後片付け（権限を戻してから消す）。失敗しても握り潰す（テスト結果に影響させない）。
    private func cleanUp(_ dir: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - tests

    @Test("1 フレーム書いて close すると読み出せるファイルになる")
    func writeThenCloseProducesReadableFile() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("out.m4a")

        let format = makeFormat()
        let writer = try AVAudioFileWriter(url: url, format: format)
        #expect(writer.url == url)
        try writer.write(makeBuffer(format, frames: 1))
        try writer.close()

        let read = try AVAudioFile(forReading: url)
        #expect(read.length >= 1)
    }

    @Test("close は 2 回呼んでも投げない（1 回目で確かに閉じている）")
    func closeIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("out.m4a")

        let format = makeFormat()
        let writer = try AVAudioFileWriter(url: url, format: format)
        try writer.write(makeBuffer(format, frames: 1024))
        try writer.close()
        try writer.close() // 何も起きない

        // 1 回目で閉じている証拠: もう書けない（RecError になる）/ ファイルは読み出せる。
        #expect(throws: RecError.self) {
            try writer.write(self.makeBuffer(format, frames: 1024))
        }
        let read = try AVAudioFile(forReading: url)
        #expect(read.length >= 1)
    }

    @Test("書き込み不可ディレクトリでは init が .outputUnavailable の RecError を投げる")
    func initOnUnwritableDirectoryThrowsOutputUnavailable() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        let url = dir.appendingPathComponent("out.m4a")
        let format = makeFormat()
        let error = #expect(throws: RecError.self) {
            _ = try AVAudioFileWriter(url: url, format: format)
        }
        #expect(error?.code == .outputUnavailable)
        // NSError / errno をそのまま外に出していない（message に畳んである）。
        #expect(error?.message.contains(url.path) == true)
    }

    @Test("framesWritten は書いたフレーム数の累計")
    func framesWrittenAccumulates() throws {
        let dir = try makeTempDir()
        defer { cleanUp(dir) }
        let url = dir.appendingPathComponent("out.m4a")

        let format = makeFormat()
        let writer = try AVAudioFileWriter(url: url, format: format)
        #expect(writer.framesWritten == 0)
        try writer.write(makeBuffer(format, frames: 512))
        #expect(writer.framesWritten == 512)
        try writer.write(makeBuffer(format, frames: 1024))
        #expect(writer.framesWritten == 1536)
        try writer.close()
        #expect(writer.framesWritten == 1536)
    }

    @Test("FakeWriter: writeError を注入すると write が投げる")
    func fakeWriterInjectedWriteErrorThrows() throws {
        let format = makeFormat()
        let injected = RecError(code: .outputUnavailable, message: "injected")
        let fake = FakeWriter(writeError: injected)

        #expect(throws: injected) {
            try fake.write(self.makeBuffer(format, frames: 256))
        }
        #expect(fake.framesWritten == 0)
        #expect(fake.writeCount == 1)

        fake.writeError = nil
        try fake.write(makeBuffer(format, frames: 256))
        #expect(fake.framesWritten == 256)

        try fake.close()
        #expect(fake.closeCount == 1)
    }
}
