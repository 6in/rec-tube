// AudioFileWriter.swift — 出力ファイルへの書き出し（AAC 192 kbps / m4a）。
//
// 役割は 2 つだけ:
//   1. `AVAudioFile` を開く / 書く / 閉じるを 1 か所に閉じ込める
//   2. OS 由来のエラー（`errno` 全般 / `NSError`）を `RecError(code: .outputUnavailable, ...)` に畳む
//
// 断言: このファイルの外へ `NSError` / `errno` をそのまま出さない。
// 呼び出し側（T5 の TapRecorder、T4 の出力先決定）は `RecError.code` だけ見れば終了コードが決まる。
//
// 追従先（PLAN「追従先チェックリスト」）: エンコード設定を変えたら README の「出力形式」も合わせる
// （エンコード設定を持つのは、この下の `AVAudioFileWriter.init` 1 か所だけ）。

import AVFoundation
import Foundation

/// 出力ファイルへ PCM バッファを書き出すもの。テストでは `FakeWriter` に差し替える。
public protocol AudioFileWriting: AnyObject {
    /// バッファ 1 つを書く。失敗したら `RecError(code: .outputUnavailable, ...)`。
    func write(_ buf: AVAudioPCMBuffer) throws
    /// 閉じる（flush 込み）。2 回目以降は何もしない。
    func close() throws
    /// `write` に渡されたバッファの `frameLength` の累計。
    var framesWritten: AVAudioFramePosition { get }
    /// 書き出し先。
    var url: URL { get }
}

/// `AVAudioFile` 実装の `AudioFileWriting`（AAC 192 kbps）。
///
/// `@unchecked Sendable`: 可変状態（`file` / `isOpen` / `framesWritten`）は IO キュー
/// （`TapRecorder` の `rec.io`）上でだけ触る規約。単一ファイル版の `Recorder`（`git show main:rec.swift`）と同じ方針。
public final class AVAudioFileWriter: AudioFileWriting, @unchecked Sendable {
    public let url: URL
    public private(set) var framesWritten: AVAudioFramePosition = 0

    private var file: AVAudioFile?
    private var isOpen = false

    /// 書き出し先を開く。開けなければ `RecError(code: .outputUnavailable, ...)`。
    public init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        do {
            // 設定は単一ファイル版の `Recorder.init`（`git show main:rec.swift`）と同一（AAC 192 kbps）。
            file = try AVAudioFile(forWriting: url,
                                   settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                              AVSampleRateKey: format.sampleRate,
                                              AVNumberOfChannelsKey: format.channelCount,
                                              AVEncoderBitRateKey: 192_000],
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        } catch {
            throw Self.outputUnavailable("出力ファイルを開けませんでした", url: url, error: error)
        }
        isOpen = true
    }

    public func write(_ buf: AVAudioPCMBuffer) throws {
        guard let file else {
            throw RecError(code: .outputUnavailable,
                           message: "出力ファイルは既に閉じています: \(url.path)")
        }
        do {
            try file.write(from: buf)
        } catch {
            throw Self.outputUnavailable("出力ファイルに書き込めませんでした", url: url, error: error)
        }
        framesWritten += AVAudioFramePosition(buf.frameLength)
    }

    /// `isOpen` を見て 1 回だけ `AVAudioFile.close()` を呼ぶ。2 回目以降は何もしない（投げない）。
    ///
    /// `file = nil` による暗黙の flush には頼らない（明示的に閉じる）。
    public func close() throws {
        guard isOpen else { return }
        isOpen = false
        file?.close()
        file = nil
    }

    /// OS 由来のエラー（`errno` 全般 / `NSError` の `NSCocoaErrorDomain` など）をまとめて畳む。
    ///
    /// errno を列挙して分岐はしない（`EACCES` でも `EROFS` でも「出力不可」は同じ）。
    /// `message` には元のエラーの内容と対象パスを残す。
    private static func outputUnavailable(_ what: String, url: URL, error: Error) -> RecError {
        let ns = error as NSError
        return RecError(code: .outputUnavailable,
                        message: "\(what): \(url.path) (\(ns.domain) \(ns.code): \(ns.localizedDescription))")
    }
}
