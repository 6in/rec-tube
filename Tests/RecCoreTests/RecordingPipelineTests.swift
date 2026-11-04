// RecordingPipeline のユニットテスト。
//
// 本物のファイルには書かない（`FakeWriter` に差し替える）。Core Audio にも触らない。
//
// 遅延線の保持量の算術（このファイルで何度も使う）:
//   `guardFrames = Int((guardSeconds * sampleRate).rounded())`。`DelayLine` は保持合計が
//   `guardFrames` を**超える間**だけ最古のバッファを丸ごと押し出すので、`bufferFrames` ずつ
//   十分に push した後の保持量は常に `(guardFrames / bufferFrames) * bufferFrames`（整数除算）になる。
//   例: 48 kHz / guard 1.0 秒（48000）/ 512 フレームなら保持は 93 × 512 = 47616 フレーム。

import AVFoundation
import Foundation
import Testing

@testable import RecCore

@Suite("RecordingPipeline")
struct RecordingPipelineTests {
    // MARK: - helpers

    private static let sampleRate: Double = 48_000
    private static let bufferFrames: AVAudioFrameCount = 512

    /// `guardSeconds` と 1 バッファのフレーム数から、押し出しが落ち着いた後の保持フレーム数。
    private func steadyHeldFrames(guardSeconds: Double) -> Int {
        let guardFrames = Int((guardSeconds * Self.sampleRate).rounded())
        let per = Int(Self.bufferFrames)
        return (guardFrames / per) * per
    }

    /// `format` / `FakeWriter` / `SilenceMeter` を揃えてパイプラインを組む。
    private func makePipeline(guardSeconds: Double,
                              writeError: Error? = nil)
        -> (RecordingPipeline, FakeWriter, AVAudioFormat) {
        let format = Signals.format(sampleRate: Self.sampleRate, channels: 2)
        let writer = FakeWriter(writeError: writeError)
        let meter = SilenceMeter(sampleRate: Self.sampleRate)
        let pipeline = RecordingPipeline(format: format,
                                         writer: writer,
                                         guardSeconds: guardSeconds,
                                         meter: meter)
        return (pipeline, writer, format)
    }

    /// 目印つきバッファを `count` 個 ingest する。返り値は push したフレーム合計。
    @discardableResult
    private func ingest(_ pipeline: RecordingPipeline,
                        format: AVAudioFormat,
                        count: Int,
                        value: Float) -> Int {
        for _ in 0 ..< count {
            pipeline.ingest(Signals.marked(format: format, frames: Self.bufferFrames, value: value))
        }
        return count * Int(Self.bufferFrames)
    }

    // MARK: - tests

    @Test("finish() すると遅延線の保持分も flush されて framesWritten が push 合計と一致する")
    func finishFlushesHeldFrames() throws {
        let (pipeline, writer, format) = makePipeline(guardSeconds: 1.0)
        // 2 秒分（188 × 512 = 96256 フレーム）。
        let pushed = ingest(pipeline, format: format, count: 188, value: 1.0)

        // flush 前: 遅延線が保持している分（47616）は、まだ書かれていない。
        #expect(writer.framesWritten == AVAudioFramePosition(pushed - steadyHeldFrames(guardSeconds: 1.0)))

        try pipeline.finish()

        #expect(writer.framesWritten == AVAudioFramePosition(pushed))
        #expect(writer.closeCount == 1)
        #expect(pipeline.firstWriteError == nil)
    }

    @Test("gate 閉 → discard → gate 開 で、閉じている間のバッファと保持分が書かれない")
    func closedGateWithDiscardDropsAdAudio() throws {
        let (pipeline, writer, format) = makePipeline(guardSeconds: 1.0)
        let held = steadyHeldFrames(guardSeconds: 1.0)

        // 本編 2 秒。
        let main1 = ingest(pipeline, format: format, count: 188, value: 1.0)
        // 広告に入る: 遅延線の保持分（境界に広告が混ざっている可能性がある 1 秒）を捨てる。
        pipeline.setGate(false, discardHeld: true)
        #expect(pipeline.gateOpen == false)
        // 広告 2 秒 — gate が閉じているので 1 フレームも書かれない。
        ingest(pipeline, format: format, count: 188, value: 2.0)
        #expect(writer.framesWritten == AVAudioFramePosition(main1 - held))

        // 広告明け: gate を開く（保持分は既に空）。
        pipeline.setGate(true, discardHeld: false)
        let main2 = ingest(pipeline, format: format, count: 188, value: 3.0)
        try pipeline.finish()

        // 書かれたのは「本編 1（保持分を捨てた残り）+ 本編 2（全部）」だけ。広告 2 秒は入らない。
        #expect(writer.framesWritten == AVAudioFramePosition((main1 - held) + main2))

        // メータは gate の開閉に関係なく全バッファを見ている（3 × 2 秒 = 6 窓）。
        #expect(pipeline.meter.snapshot.totalWindows == 6)
    }

    @Test("gate 閉 かつ discardHeld false なら保持分は残り、再開後に書かれる")
    func closedGateWithoutDiscardKeepsHeldFrames() throws {
        let (pipeline, writer, format) = makePipeline(guardSeconds: 1.0)

        // 本編 2 秒 → 一時停止（捨てない）→ 再開して 2 秒。
        let main1 = ingest(pipeline, format: format, count: 188, value: 1.0)
        pipeline.setGate(false, discardHeld: false)
        pipeline.setGate(true, discardHeld: false)
        let main2 = ingest(pipeline, format: format, count: 188, value: 3.0)
        try pipeline.finish()

        // 捨てていないので push した全フレームが書かれる。
        #expect(writer.framesWritten == AVAudioFramePosition(main1 + main2))
    }

    @Test("書き込みエラーは 1 回だけ onWriteError を呼び、以後 write を試みない")
    func firstWriteErrorStopsWriting() throws {
        let injected = RecError(code: .outputUnavailable, message: "注入したエラー")
        let (pipeline, writer, format) = makePipeline(guardSeconds: 0, writeError: injected)

        var reported: [Error] = []
        pipeline.onWriteError = { reported.append($0) }

        // guard 0 なので 1 個目の ingest で即 write が走って失敗する。
        ingest(pipeline, format: format, count: 5, value: 1.0)

        #expect(reported.count == 1)
        #expect(reported.first as? RecError == injected)
        #expect(pipeline.firstWriteError as? RecError == injected)
        // write を試したのは最初の 1 回だけ（残り 4 バッファは書かない）。
        #expect(writer.writeCount == 1)
        #expect(writer.framesWritten == 0)

        // エラー後も finish() は writer を閉じる（flush はしない）。
        try pipeline.finish()
        #expect(writer.closeCount == 1)
        #expect(writer.writeCount == 1)
        #expect(reported.count == 1)
    }

    @Test("guard 0 なら遅延せずに毎バッファ書く")
    func zeroGuardWritesImmediately() throws {
        let (pipeline, writer, format) = makePipeline(guardSeconds: 0)
        let pushed = ingest(pipeline, format: format, count: 10, value: 1.0)

        #expect(writer.writeCount == 10)
        #expect(writer.framesWritten == AVAudioFramePosition(pushed))

        try pipeline.finish()
        #expect(writer.framesWritten == AVAudioFramePosition(pushed))
    }
}
