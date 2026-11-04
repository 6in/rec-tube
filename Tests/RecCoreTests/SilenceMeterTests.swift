// SilenceMeter のユニットテスト。
//
// Core Audio には触らない（`Signals` が作る float32 バッファを ingest するだけ）。
// 窓長は 1 秒（`Tuning.meterWindowSeconds`）なので、48 kHz では 1 窓 = 48000 フレーム。
//
// 断言: 正弦・雑音の dBFS は窓の切り方で誤差が出るので ±0.5 dB の許容を付ける。
// **境界（-60.0 ちょうどが silent ではない）だけは `classify` で厳密に見る**。

import AVFoundation
import Foundation
import Testing

@testable import RecCore

@Suite("SilenceMeter")
struct SilenceMeterTests {
    private let sampleRate = 48_000.0
    /// 1 窓 = 1 秒ぶんのフレーム数。
    private var oneSecond: AVAudioFrameCount { AVAudioFrameCount(sampleRate) }

    // MARK: - 1. 4 種の信号で allZero と silent の組

    @Test("全ゼロ 1 秒: allZero == true、silent == true")
    func allZeroWindowIsSilent() throws {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        meter.ingest(Signals.zeros(format: format, frames: oneSecond), gateOpen: true)

        let window = try #require(meter.lastWindow)
        #expect(window.allZero == true)
        #expect(meter.classify(dBFS: window.dBFS) == true)
        // rms == 0 でも -inf にならず、下限 1e-8 の -160 dBFS になる。
        #expect(abs(window.dBFS - (-160.0)) < 0.5)
    }

    @Test("-70 dBFS 白色雑音 1 秒: allZero == false、silent == true")
    func quietNoiseWindowIsSilentButNotAllZero() throws {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        meter.ingest(Signals.whiteNoise(format: format, frames: oneSecond, dBFS: -70), gateOpen: true)

        let window = try #require(meter.lastWindow)
        #expect(window.allZero == false)
        #expect(meter.classify(dBFS: window.dBFS) == true)
        #expect(abs(window.dBFS - (-70.0)) < 0.5)
    }

    @Test("-20 dBFS 正弦 1 秒: allZero == false、silent == false")
    func loudSineWindowIsNotSilent() throws {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        meter.ingest(Signals.sine(format: format, frames: oneSecond, frequency: 440, dBFS: -20),
                     gateOpen: true)

        let window = try #require(meter.lastWindow)
        #expect(window.allZero == false)
        #expect(meter.classify(dBFS: window.dBFS) == false)
        #expect(abs(window.dBFS - (-20.0)) < 0.5)
    }

    @Test("ちょうど -60.0 dBFS 1 秒: allZero == false、silent == false（境界は silent ではない）")
    func exactThresholdWindowIsNotSilent() throws {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        meter.ingest(Signals.constant(format: format, frames: oneSecond, dBFS: Tuning.silenceDBFS),
                     gateOpen: true)

        let window = try #require(meter.lastWindow)
        #expect(window.allZero == false)
        #expect(meter.classify(dBFS: window.dBFS) == false)
        #expect(abs(window.dBFS - Tuning.silenceDBFS) < 0.5)
    }

    @Test("classify の境界: -60.0 ちょうどは silent ではなく、わずかに下は silent")
    func classifyBoundaryIsStrictlyLessThan() {
        let meter = SilenceMeter(sampleRate: sampleRate)
        #expect(meter.classify(dBFS: Tuning.silenceDBFS) == false)
        #expect(meter.classify(dBFS: -60.0) == false)
        #expect(meter.classify(dBFS: -60.0001) == true)
    }

    // MARK: - 2. 全ゼロ 10 秒

    @Test("全ゼロ 10 秒: consecutiveAllZeroSeconds == 10、everNonZero == false、totalWindows == 10")
    func tenSecondsOfZeros() {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        for _ in 0 ..< 10 {
            meter.ingest(Signals.zeros(format: format, frames: oneSecond), gateOpen: true)
        }

        let snapshot = meter.snapshot
        #expect(snapshot.consecutiveAllZeroSeconds == 10)
        #expect(snapshot.everNonZero == false)
        #expect(snapshot.totalWindows == 10)
    }

    // MARK: - 3. 全ゼロ 5 秒 → 音あり 1 秒 → 全ゼロ 2 秒

    @Test("全ゼロ 5 秒 → 音あり 1 秒 → 全ゼロ 2 秒: 連続カウントは 0 に戻ってから数え直す")
    func audibleWindowResetsAllZeroRun() {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        for _ in 0 ..< 5 {
            meter.ingest(Signals.zeros(format: format, frames: oneSecond), gateOpen: true)
        }
        #expect(meter.snapshot.consecutiveAllZeroSeconds == 5)

        meter.ingest(Signals.sine(format: format, frames: oneSecond, frequency: 440, dBFS: -20),
                     gateOpen: true)
        #expect(meter.snapshot.consecutiveAllZeroSeconds == 0)

        for _ in 0 ..< 2 {
            meter.ingest(Signals.zeros(format: format, frames: oneSecond), gateOpen: true)
        }

        let snapshot = meter.snapshot
        #expect(snapshot.consecutiveAllZeroSeconds == 2)
        #expect(snapshot.everNonZero == true)
        #expect(snapshot.totalWindows == 8)
    }

    // MARK: - 4. gateOpen と audibleGateOpenWindows

    @Test("gate が閉じている間の音は audibleGateOpenWindows に数えない")
    func gateClosedAudioIsNotCounted() {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        for i in 0 ..< 3 {
            meter.ingest(Signals.sine(format: format,
                                      frames: oneSecond,
                                      frequency: 440,
                                      dBFS: -20,
                                      startFrame: i * Int(oneSecond)),
                         gateOpen: false)
        }

        let snapshot = meter.snapshot
        #expect(snapshot.audibleGateOpenWindows == 0)
        #expect(snapshot.totalWindows == 3)
    }

    @Test("gate が開いている間の音は audibleGateOpenWindows に数える")
    func gateOpenAudioIsCounted() {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        for i in 0 ..< 3 {
            meter.ingest(Signals.sine(format: format,
                                      frames: oneSecond,
                                      frequency: 440,
                                      dBFS: -20,
                                      startFrame: i * Int(oneSecond)),
                         gateOpen: true)
        }

        let snapshot = meter.snapshot
        #expect(snapshot.audibleGateOpenWindows == 3)
        #expect(snapshot.totalWindows == 3)
    }
}
