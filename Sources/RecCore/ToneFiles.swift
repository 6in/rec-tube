// ToneFiles.swift — 検証用の合成トーン WAV を作る（`ToneAnalyzer` の入力になるファイル）。
//
// 役割は 1 つだけ: `writeTone(url:hz:seconds:sampleRate:amplitude:)` で正弦波の WAV を書く。
//
// 断言: 書き出しは `AVAudioFile` だけで行う。**ffmpeg も外部コマンドも使わない**。
// 断言: ファイル形式は `kAudioFormatLinearPCM` / 16 bit 整数 / リトルエンディアン /
// インターリーブ / 1 チャンネル / 引数の `sampleRate`。
// これは Chrome の `<video src="main.wav">` が再生できる形式にするため（float WAV は再生できない）。
// 断言: 書き込みは float32 の `AVAudioPCMBuffer`（ファイルの `processingFormat`）で行い、
// 16 bit への変換は `AVAudioFile` に任せる。
// 断言: 最後に必ず `close()` する（`file = nil` による暗黙の flush には頼らない。
// `AudioFileWriter.close` と同じ方針）。
//
// 追従先（PLAN「追従先チェックリスト」）: ここで書く形式を変えたら、この WAV を
// `<video>` で再生する検証ページ（T10 の fixtures）も合わせる。

import AVFoundation
import Foundation

/// 振幅 `amplitude` の `hz` Hz 正弦波を `seconds` 秒ぶん、16 bit PCM の WAV として `url` に書く。
///
/// - Throws: 開けない / 書けないときは `RecError(code: .outputUnavailable, ...)`。
public func writeTone(url: URL,
                      hz: Double,
                      seconds: Double,
                      sampleRate: Double = 48000,
                      amplitude: Double = 0.5) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    let file: AVAudioFile
    do {
        // `commonFormat: .pcmFormatFloat32` で `processingFormat` を float32 にし、
        // 16 bit への変換は `AVAudioFile` に任せる。
        file = try AVAudioFile(forWriting: url,
                               settings: settings,
                               commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    } catch {
        throw toneWriteFailed("トーンファイルを開けませんでした", url: url, error: error)
    }

    let format = file.processingFormat
    let chunkFrames: AVAudioFrameCount = 4096
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
          let channel = buffer.floatChannelData?[0] else {
        file.close()
        throw RecError(code: .outputUnavailable,
                       message: "トーン書き込み用のバッファを作れませんでした: \(url.path)")
    }

    let totalFrames = max(Int((seconds * sampleRate).rounded()), 0)
    // 位相はファイル先頭からの通し番号で決める（チャンクの境目で途切れないように）。
    let radiansPerFrame = sampleRate > 0 ? 2.0 * Double.pi * hz / sampleRate : 0
    var written = 0

    while written < totalFrames {
        let take = min(Int(chunkFrames), totalFrames - written)
        for frame in 0 ..< take {
            channel[frame] = Float(amplitude * sin(radiansPerFrame * Double(written + frame)))
        }
        buffer.frameLength = AVAudioFrameCount(take)
        do {
            try file.write(from: buffer)
        } catch {
            file.close()
            throw toneWriteFailed("トーンファイルに書き込めませんでした", url: url, error: error)
        }
        written += take
    }

    file.close()
}

/// OS 由来のエラー（`NSError` など）を `RecError` に畳む。`NSError` を外へ出さない。
private func toneWriteFailed(_ what: String, url: URL, error: Error) -> RecError {
    let ns = error as NSError
    return RecError(code: .outputUnavailable,
                    message: "\(what): \(url.path) (\(ns.domain) \(ns.code): \(ns.localizedDescription))")
}
