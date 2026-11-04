// Signals — テスト用の PCM バッファ生成（全ゼロ / 一定振幅 / 正弦 / 白色雑音 / 目印つき）。
//
// T4 の 3 つのテスト（DelayLine / SilenceMeter / RecordingPipeline）が共有する。
// 方針:
//   - 既定は 48 kHz / 2ch / float32 non-interleaved（`AVAudioFormat(standardFormatWithSampleRate:channels:)`）
//   - 振幅は **dBFS で指定**する。`constant` は RMS が指定どおりになる（正弦は窓の切り方で ±0.1 dB 程度ずれる）
//   - 乱数は xorshift64 で**決定的**（seed を固定すれば毎回同じ波形）
//
// 断言: `dBFS = 20·log10(rms)`。`constant(dBFS: -60)` の RMS は 10^(-3)。

import AVFoundation
import Foundation

enum Signals {
    /// 既定フォーマット（48 kHz / 2ch / float32 non-interleaved）。
    static func format(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    /// 全ゼロ。
    static func zeros(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        make(format: format, frames: frames) { _, _ in 0 }
    }

    /// 全チャンネルが `+a` / `-a` を 1 サンプルごとに交互に取る波（RMS はちょうど `a`）。
    /// `a = 10^(dBFS/20)`。境界値（-60.0 dBFS ちょうど）の確認に使う。
    static func constant(format: AVAudioFormat, frames: AVAudioFrameCount, dBFS: Double) -> AVAudioPCMBuffer {
        let a = pow(10.0, dBFS / 20.0)
        return make(format: format, frames: frames) { _, frame in
            Float(frame % 2 == 0 ? a : -a)
        }
    }

    /// 正弦波。`startFrame` を足すと前のバッファから位相が continuous になる。
    static func sine(format: AVAudioFormat,
                     frames: AVAudioFrameCount,
                     frequency: Double,
                     dBFS: Double,
                     startFrame: Int = 0) -> AVAudioPCMBuffer {
        // RMS = amplitude / √2 なので、目標 RMS から振幅を逆算する。
        let amplitude = pow(10.0, dBFS / 20.0) * 2.0.squareRoot()
        let step = 2.0 * Double.pi * frequency / format.sampleRate
        return make(format: format, frames: frames) { _, frame in
            Float(amplitude * sin(step * Double(startFrame + frame)))
        }
    }

    /// 決定的な白色雑音（指定 RMS に正規化する）。
    static func whiteNoise(format: AVAudioFormat,
                           frames: AVAudioFrameCount,
                           dBFS: Double,
                           seed: UInt64 = 0x2545_F491_4F6C_DD1D) -> AVAudioPCMBuffer {
        var state = seed == 0 ? 1 : seed
        let channels = Int(format.channelCount)
        let count = channels * Int(frames)
        var raw = [Double](repeating: 0, count: count)
        var sumSquares = 0.0
        for i in 0 ..< count {
            // xorshift64
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            // [-1, 1) の一様乱数
            let unit = Double(state >> 11) / Double(1 << 53)
            let v = unit * 2.0 - 1.0
            raw[i] = v
            sumSquares += v * v
        }
        let rms = (sumSquares / Double(count)).squareRoot()
        let scale = rms > 0 ? pow(10.0, dBFS / 20.0) / rms : 0
        return make(format: format, frames: frames) { channel, frame in
            Float(raw[channel * Int(frames) + frame] * scale)
        }
    }

    /// 全サンプルが `value` の目印バッファ（`DelayLine` が順序を保つかの確認に使う）。
    static func marked(format: AVAudioFormat, frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        make(format: format, frames: frames) { _, _ in value }
    }

    /// バッファの先頭サンプル（`marked` の目印を読む）。
    static func firstSample(_ buf: AVAudioPCMBuffer) -> Float {
        buf.floatChannelData![0][0]
    }

    /// `frameLength` を埋めたバッファを作る。`fill(channel, frame) -> Float`。
    static func make(format: AVAudioFormat,
                     frames: AVAudioFrameCount,
                     fill: (_ channel: Int, _ frame: Int) -> Float) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.floatChannelData!
        for channel in 0 ..< Int(format.channelCount) {
            let ptr = data[channel]
            for frame in 0 ..< Int(frames) {
                ptr[frame] = fill(channel, frame)
            }
        }
        return buf
    }
}
