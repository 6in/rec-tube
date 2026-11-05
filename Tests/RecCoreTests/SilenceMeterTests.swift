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

    @Test("gate が開いた窓と閉じた窓が混じったら gateOpen == false で audible に数えない")
    func mixedGateWindowIsNotGateOpen() throws {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        let half = AVAudioFrameCount(oneSecond / 2)

        // 1 窓を半分ずつ、gate 開 → gate 閉で埋める（音の大きさは両方 -20 dBFS）。
        meter.ingest(Signals.sine(format: format, frames: half, frequency: 440, dBFS: -20),
                     gateOpen: true)
        meter.ingest(Signals.sine(format: format,
                                  frames: half,
                                  frequency: 440,
                                  dBFS: -20,
                                  startFrame: Int(half)),
                     gateOpen: false)

        let window = try #require(meter.lastWindow)
        #expect(meter.snapshot.totalWindows == 1)
        // 1 バッファでも閉じていたら窓は閉じている扱い。
        #expect(window.gateOpen == false)
        // 音自体は鳴っている（silent ではない）が、gate が閉じているので audible に数えない。
        #expect(meter.classify(dBFS: window.dBFS) == false)
        #expect(meter.snapshot.audibleGateOpenWindows == 0)
    }

    // MARK: - 5. interleaved バッファ（stride 読み）

    @Test("interleaved でも non-interleaved と dBFS / allZero / gateOpen が一致する")
    func interleavedMatchesNonInterleaved() throws {
        // 窓の前半と後半、左と右で振幅を変える。interleaved を stride 1 で読むと
        // 「窓の前半だけを 2 回読む」ことになり dBFS が大きくずれる素材。
        let halfWindow = Int(oneSecond) / 2
        func fill(channel: Int, frame: Int) -> Float {
            let level: Float = frame < halfWindow ? 0.01 : 0.5
            let side: Float = channel == 0 ? 1.0 : 0.25
            return (frame % 2 == 0 ? 1 : -1) * level * side
        }

        let plainMeter = SilenceMeter(sampleRate: sampleRate)
        plainMeter.ingest(Signals.make(format: Signals.format(sampleRate: sampleRate),
                                       frames: oneSecond,
                                       fill: fill),
                          gateOpen: true)

        let interleavedFormat = Signals.interleavedFormat(sampleRate: sampleRate)
        #expect(interleavedFormat.isInterleaved == true)
        let interleavedBuffer = Signals.make(format: interleavedFormat, frames: oneSecond, fill: fill)
        // interleaved なら 1 チャンネルのサンプル間隔はチャンネル数ぶん。
        #expect(interleavedBuffer.stride == Int(interleavedFormat.channelCount))

        let interleavedMeter = SilenceMeter(sampleRate: sampleRate)
        interleavedMeter.ingest(interleavedBuffer, gateOpen: true)

        let plain = try #require(plainMeter.lastWindow)
        let interleaved = try #require(interleavedMeter.lastWindow)
        // 同じサンプル列を同じ順で累算するので dBFS はビット単位で一致する。
        #expect(interleaved.dBFS == plain.dBFS)
        #expect(interleaved.allZero == plain.allZero)
        #expect(interleaved.gateOpen == plain.gateOpen)
        #expect(interleaved.allZero == false)
        #expect(interleaved.gateOpen == true)
        // 期待値（平均二乗 = (0.01² + 0.5²)/2 × (1² + 0.25²)/2）。stride 1 で読むと -45 dB 付近になる。
        let meanSquare = (0.0001 + 0.25) / 2.0 * (1.0 + 0.0625) / 2.0
        #expect(abs(interleaved.dBFS - 20.0 * log10(meanSquare.squareRoot())) < 0.01)
    }

    // MARK: - 6. 窓またぎ（小さいバッファが窓の境界を越える）

    @Test("512 フレームのバッファを 2.5 窓ぶん流すと窓は 2 つ確定し、各窓の dBFS は分かれる")
    func smallBuffersStraddleWindowBoundary() throws {
        let format = Signals.format(sampleRate: sampleRate)
        let meter = SilenceMeter(sampleRate: sampleRate)
        let windowFrames = Int(oneSecond)
        let chunk: AVAudioFrameCount = 512
        // 窓 0 は -20 dBFS、窓 1 以降は -40 dBFS。境界 48000 は 512 の倍数ではないので
        // 1 つのバッファが 2 つの窓にまたがる（フレームの振り分けを間違えると dBFS が混ざる）。
        let loud = Float(pow(10.0, -20.0 / 20.0))
        let quiet = Float(pow(10.0, -40.0 / 20.0))
        func buffer(startFrame: Int, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
            Signals.make(format: format, frames: frames) { _, frame in
                let absolute = startFrame + frame
                let amplitude = absolute < windowFrames ? loud : quiet
                return absolute % 2 == 0 ? amplitude : -amplitude
            }
        }

        // 235 × 512 = 120320 フレーム ≒ 2.5 窓。
        let chunkCount = 235
        var dBFSPerWindow: [Double] = []
        var fed = 0
        for _ in 0 ..< chunkCount {
            meter.ingest(buffer(startFrame: fed, frames: chunk), gateOpen: true)
            fed += Int(chunk)
            if meter.snapshot.totalWindows > dBFSPerWindow.count {
                dBFSPerWindow.append(try #require(meter.lastWindow).dBFS)
            }
        }

        #expect(fed == 120_320)
        #expect(meter.snapshot.totalWindows == 2)
        #expect(dBFSPerWindow.count == 2)
        #expect(abs(dBFSPerWindow[0] - (-20.0)) < 0.01)
        #expect(abs(dBFSPerWindow[1] - (-40.0)) < 0.01)

        // 合計フレーム数の検算: 2 窓 = 96000 を確定済みなので窓に 24320 フレーム残っている。
        // あと 23679 では確定せず、1 フレーム足すとちょうど 3 窓目が確定する。
        meter.ingest(buffer(startFrame: fed, frames: 23_679), gateOpen: true)
        #expect(meter.snapshot.totalWindows == 2)
        meter.ingest(buffer(startFrame: fed + 23_679, frames: 1), gateOpen: true)
        #expect(meter.snapshot.totalWindows == 3)
        #expect(fed + 23_680 == 3 * windowFrames)
    }
}
