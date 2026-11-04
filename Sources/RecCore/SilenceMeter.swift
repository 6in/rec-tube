// SilenceMeter.swift — tap から流れてくる PCM を 1 秒窓で測り、「無音」と「全ゼロ」を見分ける。
//
// 「全ゼロ」と「無音」は別物で、区別が本質:
//   - **全ゼロ**（`allZero`）: 全サンプルがちょうど 0.0。tap が動いていない / 権限が降りていない疑い。
//   - **無音**（silent）: `dBFS < Tuning.silenceDBFS`。音は流れているが聞こえないほど小さい。
// 前者は故障（`Tuning.tapStallSeconds`）、後者は警告（`Tuning.silenceWarnAfterSeconds`）につながる。
//
// 断言: silent iff `dBFS < Tuning.silenceDBFS`。**ちょうど閾値は silent ではない**（`<` であって `<=`）。
// 断言: `dBFS = 20·log10(max(rms, 1e-8))` なので rms が 0 でも `-inf` ではなく -160 dBFS になる。
// 断言: **窓の配列を溜めない**。長時間録音でメモリが伸びないよう、持つのはカウンタと `lastWindow` だけ。
//
// 追従先（PLAN「追従先チェックリスト」): 閾値・窓長はこのファイルに直書きせず、必ず
// `Tuning.silenceDBFS` / `Tuning.meterWindowSeconds` を参照する。

import Accelerate
import AVFoundation
import Foundation

/// 確定した 1 窓（`Tuning.meterWindowSeconds` 分）の測定結果。
public struct MeterWindow: Sendable, Equatable {
    /// 窓の全サンプルの RMS から求めた dBFS（`20·log10(max(rms, 1e-8))`）。
    public let dBFS: Double
    /// 窓に入った全サンプルがちょうど 0.0 だったか。
    public let allZero: Bool
    /// 窓に入った全バッファが `gateOpen == true` だったか（1 つでも閉じていたら false）。
    public let gateOpen: Bool
}

/// 録音開始からの累計（窓単位）。`SilenceMeter.snapshot` で読む。
public struct MeterSnapshot: Sendable, Equatable {
    /// これまでに確定した窓のうち 1 つでも `allZero == false` があったか。
    public let everNonZero: Bool
    /// 末尾から連続する `allZero == true` の窓の長さ（秒）。
    public let consecutiveAllZeroSeconds: Double
    /// 末尾から連続する silent な窓の長さ（秒）。
    public let consecutiveSilentSeconds: Double
    /// `gateOpen == true` かつ silent でない窓の累計数。
    public let audibleGateOpenWindows: Int
    /// 確定した窓の累計数。
    public let totalWindows: Int
}

/// PCM を `Tuning.meterWindowSeconds` ごとの窓に区切って測るメータ。
///
/// `@unchecked Sendable`: 可変状態（窓の途中の累算・カウンタ・`lastWindow`）は IO キュー
/// （`TapRecorder` の `rec.io`）上でだけ触る規約。**内部ロックは持たない**ので、呼び出し側が
/// `ingest` と `snapshot` / `lastWindow` の読みを同じキューにシリアライズすること。
/// このリポジトリの `AVAudioFileWriter` と同じ方針。
public final class SilenceMeter: @unchecked Sendable {
    /// 1 窓のフレーム数。
    private let windowFrames: Int

    // MARK: - 窓の途中の累算（確定するたびにリセットする）

    /// 窓に入ったフレーム数（`windowFrames` に達したら確定）。
    private var windowFrameCount = 0
    /// 窓に入ったサンプル数（= フレーム数 × チャンネル数）。RMS の分母。
    private var windowSampleCount = 0
    /// 窓の二乗和（Double で累算する。float32 のままだと -60 dBFS 近傍で桁が足りない）。
    private var windowSumSquares = 0.0
    /// ここまでのサンプルが全部ちょうど 0.0 か。
    private var windowAllZero = true
    /// ここまでのバッファが全部 `gateOpen == true` か。
    private var windowGateOpen = true

    // MARK: - 累計カウンタ（窓の配列は持たない）

    private var everNonZero = false
    private var consecutiveAllZeroWindows = 0
    private var consecutiveSilentWindows = 0
    private var audibleGateOpenWindows = 0
    private var totalWindows = 0

    /// 直近に確定した窓。まだ 1 つも確定していなければ nil。
    public private(set) var lastWindow: MeterWindow?

    /// float32 → Double 変換の作業領域。1 回の累算で扱う最大長は `windowFrames` なので使い回せる。
    private var scratch: [Double]

    public init(sampleRate: Double) {
        windowFrames = Int((Tuning.meterWindowSeconds * sampleRate).rounded())
        scratch = [Double](repeating: 0, count: max(windowFrames, 0))
    }

    /// 録音開始からの累計。
    public var snapshot: MeterSnapshot {
        MeterSnapshot(everNonZero: everNonZero,
                      consecutiveAllZeroSeconds: Double(consecutiveAllZeroWindows) * Tuning.meterWindowSeconds,
                      consecutiveSilentSeconds: Double(consecutiveSilentWindows) * Tuning.meterWindowSeconds,
                      audibleGateOpenWindows: audibleGateOpenWindows,
                      totalWindows: totalWindows)
    }

    /// 無音判定。**silent iff `dBFS < Tuning.silenceDBFS`**（ちょうどは silent ではない）。
    public func classify(dBFS: Double) -> Bool {
        dBFS < Tuning.silenceDBFS
    }

    /// バッファ 1 つを取り込む。窓の境界に達したらその場で窓を確定し、端数は次の窓へ繰り越す。
    ///
    /// `floatChannelData` が nil（float32 以外）のバッファと `frameLength == 0` のバッファは無視する。
    ///
    /// interleaved / non-interleaved の両方を読む。`floatChannelData[c]` は interleaved なら
    /// **同じ領域への 1 サンプルずつずれたポインタ**で、1 チャンネルのサンプルは `buf.stride`
    /// （= チャンネル数）間隔に並ぶ。non-interleaved なら `buf.stride == 1`。どちらも
    /// 「ポインタの前進」と「vDSP の stride」の両方に `buf.stride` を掛ける必要がある。
    public func ingest(_ buf: AVAudioPCMBuffer, gateOpen: Bool) {
        guard let channelData = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }
        // `windowFrames <= 0`（sampleRate が 0 など）だと窓が永遠に確定せず下のループが進まないので弾く。
        guard windowFrames > 0 else { return }

        let channelCount = Int(buf.format.channelCount)
        let sampleStride = buf.stride
        var offset = 0
        while offset < frames {
            // 窓の残りとバッファの残りの小さい方だけ取り込む（1 バッファが複数の窓にまたがる場合がある）。
            let take = min(windowFrames - windowFrameCount, frames - offset)
            for channel in 0 ..< channelCount {
                // 窓の途中から読むときの前進もサンプル単位なので `stride` 倍する。
                accumulate(channelData[channel] + offset * sampleStride,
                           count: take,
                           stride: sampleStride)
            }
            windowFrameCount += take
            windowSampleCount += take * channelCount
            if !gateOpen { windowGateOpen = false }
            offset += take

            if windowFrameCount >= windowFrames { finalizeWindow() }
        }
    }

    /// 1 チャンネル分の区間を窓の累算に足す（二乗和と「全ゼロか」）。
    ///
    /// `stride` は 1 チャンネルのサンプル間隔（interleaved ならチャンネル数、non-interleaved なら 1）。
    private func accumulate(_ samples: UnsafePointer<Float>, count: Int, stride: Int) {
        guard count > 0 else { return }
        let length = vDSP_Length(count)
        let sampleStride = vDSP_Stride(stride)

        // 「ちょうど 0.0 か」は最大絶対値で見る（二乗和はアンダーフローで 0 になり得るため分けて測る）。
        if windowAllZero {
            var maxMagnitude: Float = 0
            vDSP_maxmgv(samples, sampleStride, &maxMagnitude, length)
            if maxMagnitude != 0 { windowAllZero = false }
        }

        // float32 → Double に広げてから二乗和を取る。-60 dBFS ちょうどの境界を float32 の
        // 丸めで踏み外さないため、累算は必ず Double で行う。
        // 読み出し側だけ `sampleStride`、書き込み先の `scratch` は詰めて並べる（stride 1）。
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vspdp(samples, sampleStride, base, 1, length)
            var sumSquares = 0.0
            vDSP_svesqD(base, 1, &sumSquares, length)
            windowSumSquares += sumSquares
        }
    }

    /// 窓を 1 つ確定し、`lastWindow` とカウンタを進めて累算をリセットする。
    private func finalizeWindow() {
        let rms = windowSampleCount > 0
            ? (windowSumSquares / Double(windowSampleCount)).squareRoot()
            : 0
        // `max(rms, 1e-8)` で下限を切るので、全ゼロでも -160 dBFS になり `-inf` にはならない。
        let dBFS = 20.0 * log10(max(rms, 1e-8))
        let window = MeterWindow(dBFS: dBFS, allZero: windowAllZero, gateOpen: windowGateOpen)
        lastWindow = window
        totalWindows += 1

        if window.allZero {
            consecutiveAllZeroWindows += 1
        } else {
            everNonZero = true
            consecutiveAllZeroWindows = 0
        }

        if classify(dBFS: dBFS) {
            consecutiveSilentWindows += 1
        } else {
            consecutiveSilentWindows = 0
            if window.gateOpen { audibleGateOpenWindows += 1 }
        }

        windowFrameCount = 0
        windowSampleCount = 0
        windowSumSquares = 0
        windowAllZero = true
        windowGateOpen = true
    }
}
