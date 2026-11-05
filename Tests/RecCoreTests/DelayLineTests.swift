// DelayLine のユニットテスト。
//
// Core Audio には触らない（`Signals` が作る PCM バッファを push するだけ）。
// 確認するのは PLAN の完了基準どおり 8 件:
//   溢れた分だけ出る / discard / flush / 遅延 0 の素通し / 長い遅延 / フレーム保存 / rethrows / FIFO と固定長。
//
// 断言: どのケースでも **emit 合計 + heldFrames == push 合計**（フレームが失われない・重複しない）。

import AVFoundation
import Foundation
import Testing

@testable import RecCore

@Suite("DelayLine")
struct DelayLineTests {
    // MARK: - helpers

    /// tap から来る形式に合わせた 48 kHz / 2ch（float32 non-interleaved）。
    private let format = Signals.format()

    /// IOProc 1 回分に相当するバッファ長。48000 はこれで割り切れない（端数が出る）。
    private let frames: AVAudioFrameCount = 512

    /// `guardSeconds` に対応するフレーム数（実装と同じ式）。
    private func guardFrames(_ seconds: Double) -> Int {
        Int((seconds * format.sampleRate).rounded())
    }

    /// `seconds` 秒分に届くまで `frames` フレームのバッファを push する。
    /// 戻り値は（push したフレーム合計, emit されたフレーム合計, emit された回数）。
    @discardableResult
    private func pushSeconds(_ line: DelayLine, _ seconds: Double) -> (pushed: Int, emitted: Int, emits: Int) {
        let target = Int((seconds * format.sampleRate).rounded())
        var pushed = 0
        var emitted = 0
        var emits = 0
        while pushed + Int(frames) <= target {
            line.push(Signals.zeros(format: format, frames: frames)) { buf in
                emitted += Int(buf.frameLength)
                emits += 1
            }
            pushed += Int(frames)
        }
        return (pushed, emitted, emits)
    }

    // MARK: - tests

    @Test("3 秒分 push すると guard 1 秒を残した分（≒2 秒）が emit される")
    func emitsEverythingBeyondTheGuard() {
        // `Tuning.adGuardSeconds` は `--ad-guard` の既定値（現在 1.0 s = 48000 フレーム）。
        let line = DelayLine(format: format, guardSeconds: Tuning.adGuardSeconds)
        let result = pushSeconds(line, 3.0)

        // 512 は 48000 を割り切らないので、保持は guardFrames を 1 バッファ未満だけ下回る。
        // 既定 1.0 s なら pushed = 143872 / emitted = 95872（= 2.0 s 分の 96000 の ±512 以内）。
        let expected = result.pushed - guardFrames(Tuning.adGuardSeconds)
        #expect(abs(result.emitted - expected) <= Int(frames))
        #expect(result.emitted + line.heldFrames == result.pushed)
        #expect(line.heldFrames <= guardFrames(Tuning.adGuardSeconds))
    }

    @Test("discard() は保持分を捨てて heldFrames を 0 にする")
    func discardDropsEverythingHeld() {
        let line = DelayLine(format: format, guardSeconds: Tuning.adGuardSeconds)
        pushSeconds(line, 3.0)
        #expect(line.heldFrames > 0)

        line.discard()
        #expect(line.heldFrames == 0)

        // 捨てたので、あとから flush しても何も出ない。
        var emits = 0
        line.flush { _ in emits += 1 }
        #expect(emits == 0)
    }

    @Test("flush(emit:) は保持分を全部出して heldFrames を 0 にする")
    func flushEmitsEverythingHeld() {
        let line = DelayLine(format: format, guardSeconds: Tuning.adGuardSeconds)
        let result = pushSeconds(line, 3.0)
        let heldBeforeFlush = line.heldFrames

        var flushed = 0
        line.flush { flushed += Int($0.frameLength) }

        #expect(flushed == heldBeforeFlush)
        #expect(result.emitted + flushed == result.pushed)
        #expect(line.heldFrames == 0)
    }

    @Test("guardSeconds 0 なら push ごとに即 emit する（保持 0）")
    func zeroGuardPassesThroughImmediately() {
        let line = DelayLine(format: format, guardSeconds: 0)

        var emits = 0
        var emitted = 0
        line.push(Signals.zeros(format: format, frames: frames)) { buf in
            emits += 1
            emitted += Int(buf.frameLength)
        }

        #expect(emits == 1)
        #expect(emitted == Int(frames))
        #expect(line.heldFrames == 0)
    }

    @Test("guard より短い push では 1 回も emit されず、flush で全部出る")
    func guardLongerThanInputEmitsNothingUntilFlush() {
        let line = DelayLine(format: format, guardSeconds: 5.0)
        let result = pushSeconds(line, 3.0)

        #expect(result.emits == 0)
        #expect(line.heldFrames == result.pushed)

        var flushed = 0
        line.flush { flushed += Int($0.frameLength) }
        #expect(flushed == result.pushed)
        #expect(line.heldFrames == 0)
    }

    @Test("guardFrames がバッファ長で割り切れなくても emit 合計 + heldFrames == push 合計")
    func framesAreNeitherLostNorDuplicated() {
        // 48000（1.0 s）は 512 で割り切れない（93.75 バッファ）。
        let line = DelayLine(format: format, guardSeconds: Tuning.adGuardSeconds)

        var pushed = 0
        var emitted = 0
        var emits = 0
        var pushes = 0
        for _ in 0 ..< 300 {
            line.push(Signals.zeros(format: format, frames: frames)) { buf in
                emitted += Int(buf.frameLength)
                emits += 1
            }
            pushed += Int(frames)
            pushes += 1
            // 各 push 後も保存則が成り立つ。
            #expect(emitted + line.heldFrames == pushed)
        }

        // バッファは分割されないので、個数でも保存される（emit 済み + 保持中 == push 済み）。
        let heldBuffers = line.heldFrames / Int(frames)
        #expect(line.heldFrames % Int(frames) == 0)
        #expect(emits + heldBuffers == pushes)
    }

    @Test("emit が throw したら push / flush の呼び出し側に伝わる")
    func emitErrorsAreRethrown() {
        struct EmitFailure: Error {}

        // guard 0 の push は即 emit するので、その場で throw が伝わる。
        let passthrough = DelayLine(format: format, guardSeconds: 0)
        #expect(throws: EmitFailure.self) {
            try passthrough.push(Signals.zeros(format: self.format, frames: self.frames)) { _ in
                throw EmitFailure()
            }
        }

        // 溢れた分を吐く push でも伝わる。
        let overflowing = DelayLine(format: format, guardSeconds: Tuning.adGuardSeconds)
        pushSeconds(overflowing, 3.0)
        #expect(throws: EmitFailure.self) {
            try overflowing.push(Signals.zeros(format: self.format, frames: self.frames)) { _ in
                throw EmitFailure()
            }
        }

        // flush でも伝わる。
        #expect(throws: EmitFailure.self) {
            try overflowing.flush { _ in throw EmitFailure() }
        }
    }

    @Test("emit の順序は push の順序と一致し、heldFrames は常に guardFrames 以下")
    func keepsFifoOrderAndFixedLength() {
        let line = DelayLine(format: format, guardSeconds: Tuning.adGuardSeconds)
        let limit = guardFrames(Tuning.adGuardSeconds)
        let count = 200

        var marks: [Float] = []
        for index in 1 ... count {
            line.push(Signals.marked(format: format, frames: frames, value: Float(index))) { buf in
                marks.append(Signals.firstSample(buf))
            }
            // 固定長: push から戻った時点で保持は必ず guardFrames 以下。
            #expect(line.heldFrames <= limit)
        }
        line.flush { marks.append(Signals.firstSample($0)) }

        // 全部出て、目印は 1, 2, 3, … の昇順（= push 順）。
        #expect(marks.count == count)
        #expect(marks == (1 ... count).map { Float($0) })
        #expect(line.heldFrames == 0)
    }

    @Test("push は中身をコピーして保持する（IOProc の使い回しバッファが壊れても影響しない）")
    func pushCopiesTheBuffer() {
        let line = DelayLine(format: format, guardSeconds: Tuning.adGuardSeconds)

        // IOProc は同じバッファを使い回すので、push 後に中身を書き換えても保持分は元の値のまま。
        let reused = Signals.marked(format: format, frames: frames, value: 1.0)
        line.push(reused) { _ in #expect(Bool(false), "guard 1 秒なら 1 回の push で emit は起きない") }
        reused.floatChannelData![0][0] = 99.0

        var emitted: [Float] = []
        line.flush { emitted.append(Signals.firstSample($0)) }
        #expect(emitted == [1.0])
    }
}
