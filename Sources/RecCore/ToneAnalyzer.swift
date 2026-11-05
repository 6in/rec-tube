// ToneAnalyzer.swift — 合成トーンの入った音声ファイルを窓ごとに「本編 / 広告 / 無音」へ分類する（検証用）。
//
// 役割は 3 つだけ:
//   - `goertzelPower(_:sampleRate:hz:)` 1 窓ぶんのサンプルから特定周波数のエネルギーを測る
//   - `analyze(url:mainHz:adHz:windowSeconds:)` ファイル全体を窓に切って分類し `ToneVerdict` にする
//   - `isAllZero(url:)` 全サンプルがちょうど 0.0 か（tap 故障 / 権限なしの疑いを見分ける）
//
// 断言: 読み取りは `AVAudioFile(forReading:)` だけで行う。**ffmpeg も外部コマンドも使わない**
// （`.wav` と `.m4a` のどちらも `AVAudioFile` が読める）。
// 断言: 多チャンネルのファイルは**チャンネル平均でモノラルに落としてから**窓ごとに解析する。
// 断言: 窓は `windowSeconds` 秒ぶんのフレーム。**末尾の端数窓（1 窓に満たないもの）は数に入れない**。
// 断言: 1 窓は 1 分類だけ（無音 → 広告 → 本編 の順に判定し、重複して数えない）。
// 断言: `totalSeconds` は**ファイル全体の長さ**（`length / sampleRate`）。端数窓の切り捨ては入らない。
// 断言: `isAllZero` はしきい値判定をしない。全サンプルがちょうど 0.0 のときだけ true
// （-70 dBFS の微小な雑音は false）。`SilenceMeter` の「全ゼロ」と「無音」の区別と同じ考え方。
//
// 追従先（PLAN「追従先チェックリスト」）: 閾値・比率はここに直書きせず、必ず
// `Tuning.silenceDBFS` / `Tuning.toneAdDominanceRatio` / `Tuning.toneAudibleDBFS` を参照する
// （`windowSeconds` の既定 0.1 だけは API 契約で署名に書くと決まっている例外）。

import AVFoundation
import Foundation

// MARK: - Goertzel

/// `samples` に含まれる `hz` のエネルギー（窓長 N で正規化済み）。
///
/// Goertzel 法。1 周波数だけ測るので FFT を回すより軽く、窓長が 2 の冪でなくてもよい。
/// 返す値は `(s1² + s2² − coeff·s1·s2) / N²` で、N で正規化してあるので窓長が違っても比較できる。
///
/// `samples` が空なら 0 を返す（0 除算もクラッシュもしない）。
public func goertzelPower(_ samples: [Float], sampleRate: Double, hz: Double) -> Double {
    let count = samples.count
    guard count > 0 else { return 0 }

    let coeff = 2.0 * cos(2.0 * Double.pi * hz / sampleRate)
    var s1 = 0.0
    var s2 = 0.0
    for sample in samples {
        let s0 = coeff * s1 - s2 + Double(sample)
        s2 = s1
        s1 = s0
    }
    let n = Double(count)
    return (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n * n)
}

// MARK: - 判定結果

/// ファイル 1 本の分類結果。窓ごとに 1 つだけ数えるので、
/// `silentSeconds + mainSeconds + adWindows × windowSeconds` が「端数を切り捨てた長さ」になる。
public struct ToneVerdict: Equatable, Sendable, Codable {
    /// 広告のトーンが優勢だった窓の数（秒ではなく窓数で数える。PLAN T10 の契約）。
    public var adWindows: Int
    /// 本編の窓の長さの合計（秒）。
    public var mainSeconds: Double
    /// 無音の窓（`dBFS < Tuning.silenceDBFS`）の長さの合計（秒）。
    public var silentSeconds: Double
    /// ファイル全体の長さ（秒）。端数窓を切り捨てた値ではない。
    public var totalSeconds: Double
}

// MARK: - 解析

/// `url` の音声を `windowSeconds` 秒の窓に切り、各窓を「無音 / 広告 / 本編」のどれか 1 つに分類する。
///
/// 分類の順序は固定（1 窓につき 1 分類だけ）:
///   1. 窓の RMS dBFS が `Tuning.silenceDBFS` 未満 → 無音の窓
///   2. そうでなく `goertzelPower(adHz) > goertzelPower(mainHz) × Tuning.toneAdDominanceRatio`
///      かつ窓の dBFS が `Tuning.toneAudibleDBFS` を超える → 広告の窓
///   3. それ以外 → 本編の窓
///
/// dBFS は `20·log10(max(rms, 1e-8))`（`SilenceMeter` と同じ式）。
///
/// - Throws: 読めないファイルは `RecError(code: .outputUnavailable, ...)`。
public func analyze(url: URL,
                    mainHz: Double,
                    adHz: Double,
                    windowSeconds: Double = 0.1) throws -> ToneVerdict {
    let file = try openForReading(url)
    let format = file.processingFormat
    let sampleRate = format.sampleRate
    let totalSeconds = sampleRate > 0 ? Double(file.length) / sampleRate : 0

    var verdict = ToneVerdict(adWindows: 0, mainSeconds: 0, silentSeconds: 0, totalSeconds: totalSeconds)

    let windowFrames = Int((windowSeconds * sampleRate).rounded())
    // 窓が 0 フレームだと読み進まないので、分類せず長さだけ返す。
    guard windowFrames > 0 else { return verdict }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(windowFrames)) else {
        throw RecError(code: .outputUnavailable,
                       message: "解析用のバッファを作れませんでした: \(url.path)")
    }

    // 残りが 1 窓に満たなくなったら終わり（**端数窓は数に入れない**）。
    // 終端で `read` を呼ぶと throw するので、`framePosition` と `length` で先に止める。
    while file.length - file.framePosition >= AVAudioFramePosition(windowFrames) {
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(windowFrames))
        } catch {
            throw readFailed("音声ファイルを読めませんでした", url: url, error: error)
        }
        guard Int(buffer.frameLength) == windowFrames else { break }

        let mono = monoSamples(buffer)
        let dBFS = 20.0 * log10(max(rms(mono), 1e-8))

        if dBFS < Tuning.silenceDBFS {
            verdict.silentSeconds += windowSeconds
            continue
        }

        let adPower = goertzelPower(mono, sampleRate: sampleRate, hz: adHz)
        let mainPower = goertzelPower(mono, sampleRate: sampleRate, hz: mainHz)
        if adPower > mainPower * Tuning.toneAdDominanceRatio, dBFS > Tuning.toneAudibleDBFS {
            verdict.adWindows += 1
        } else {
            verdict.mainSeconds += windowSeconds
        }
    }

    return verdict
}

/// `url` の全サンプルがちょうど 0.0 か。
///
/// しきい値判定はしない: -70 dBFS の微小な雑音が入っていれば **false**。
///
/// - Throws: 読めないファイルは `RecError(code: .outputUnavailable, ...)`。
public func isAllZero(url: URL) throws -> Bool {
    let file = try openForReading(url)
    let format = file.processingFormat

    // `AVAudioFile(forReading:)` の `processingFormat` は float32 非インターリーブなので
    // `floatChannelData` は必ず取れる。取れなければバッファを作れていない。
    let chunkFrames: AVAudioFrameCount = 8192
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
          let channels = buffer.floatChannelData else {
        throw RecError(code: .outputUnavailable,
                       message: "解析用のバッファを作れませんでした: \(url.path)")
    }

    // 終端で `read` を呼ぶと throw するので、`framePosition` と `length` で先に止める。
    while file.framePosition < file.length {
        let remaining = file.length - file.framePosition
        let take = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunkFrames)))
        do {
            try file.read(into: buffer, frameCount: take)
        } catch {
            throw readFailed("音声ファイルを読めませんでした", url: url, error: error)
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { break }

        for channel in 0 ..< Int(format.channelCount) {
            let samples = channels[channel]
            for frame in 0 ..< frames where samples[frame] != 0 {
                return false
            }
        }
    }
    return true
}

// MARK: - 内部ヘルパ

/// 読み取り用に開く。失敗は `.outputUnavailable` に畳む（`AudioFileWriter` と同じ流儀）。
private func openForReading(_ url: URL) throws -> AVAudioFile {
    do {
        return try AVAudioFile(forReading: url)
    } catch {
        throw readFailed("音声ファイルを開けませんでした", url: url, error: error)
    }
}

/// OS 由来のエラー（`NSError` など）を `RecError` に畳む。`NSError` を外へ出さない。
private func readFailed(_ what: String, url: URL, error: Error) -> RecError {
    let ns = error as NSError
    return RecError(code: .outputUnavailable,
                    message: "\(what): \(url.path) (\(ns.domain) \(ns.code): \(ns.localizedDescription))")
}

/// バッファをチャンネル平均でモノラルに落とす。`frameLength` ぶんだけ返す。
private func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    let frames = Int(buffer.frameLength)
    guard frames > 0, let channels = buffer.floatChannelData else { return [] }

    let channelCount = Int(buffer.format.channelCount)
    guard channelCount > 1 else {
        return Array(UnsafeBufferPointer(start: channels[0], count: frames))
    }

    var mono = [Float](repeating: 0, count: frames)
    for channel in 0 ..< channelCount {
        let samples = channels[channel]
        for frame in 0 ..< frames {
            mono[frame] += samples[frame]
        }
    }
    let scale = 1.0 / Float(channelCount)
    for frame in 0 ..< frames {
        mono[frame] *= scale
    }
    return mono
}

/// 二乗平均平方根。累算は Double で行う（float32 のままだと -60 dBFS 近傍で桁が足りない）。
private func rms(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return 0 }
    var sumSquares = 0.0
    for sample in samples {
        let value = Double(sample)
        sumSquares += value * value
    }
    return (sumSquares / Double(samples.count)).squareRoot()
}
