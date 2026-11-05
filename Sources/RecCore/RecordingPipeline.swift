// RecordingPipeline.swift — IO キューから来たバッファを「測る → 遅らせる → 書く」の 1 本道に通す。
//
// 役割:
//   1. 全バッファを `SilenceMeter` に通す（gate が閉じていても測る。無音・全ゼロの判定は録音の可否と独立）
//   2. gate が開いている間だけ `DelayLine` に push し、遅延線から押し出された分を `writer` に書く
//   3. 書き込みエラーは**最初の 1 回だけ**上へ知らせ、以後は一切書かない（同じエラーで溢れさせない）
//
// 断言: `ingest` / `setGate` / `finish` は**すべて同じ IO キュー**（`TapRecorder` の `rec.io`）から呼ぶ。
// `firstWriteError` / `onWriteError` もそのキュー上でだけ触る。内部ロックは持たない。
//
// gate の既定は**開**（system / app モードは遅延線 0 で `setGate` を呼ばずに録り続ける）。
// URL モードだけが広告・一時停止に合わせて `setGate` を呼ぶ（決めた事項 #10 の SessionPolicy の表）。
//
// 追従先（PLAN「追従先チェックリスト」）: 遅延線の既定値を変えるときは `Tuning.adGuardSeconds` だけを直す。

import AVFoundation
import Foundation

/// 録音パイプライン。`@unchecked Sendable`: 可変状態は IO キュー上でだけ触る規約。
public final class RecordingPipeline: @unchecked Sendable {
    /// 書き出し先。`framesWritten` は呼び出し側（終了時の無音判定・決めた事項 #7）が読む。
    public let writer: AudioFileWriting
    /// 無音・全ゼロのメータ。`snapshot` を SessionPolicy が読む。
    public let meter: SilenceMeter

    /// gate が開いているか（開 = 録音中、閉 = 広告中 / 一時停止中）。
    public private(set) var gateOpen: Bool

    /// 最初の書き込みエラー。非 nil になった後は `write` を一切行わない。
    public private(set) var firstWriteError: Error?

    /// 最初の書き込みエラーのときに**1 回だけ**呼ばれる。IO キュー上で呼ばれる。
    public var onWriteError: ((Error) -> Void)?

    private let delayLine: DelayLine

    public init(format: AVAudioFormat,
                writer: AudioFileWriting,
                guardSeconds: Double,
                meter: SilenceMeter) {
        self.writer = writer
        self.meter = meter
        self.delayLine = DelayLine(format: format, guardSeconds: guardSeconds)
        self.gateOpen = true
    }

    /// IO キューから 1 バッファ。順序は「meter →（gate 開なら）delayLine.push → writer.write」で固定。
    public func ingest(_ buf: AVAudioPCMBuffer) {
        // gate の状態に関係なく測る（広告中の全ゼロも tap 故障の判定材料になる）。
        meter.ingest(buf, gateOpen: gateOpen)
        guard gateOpen, firstWriteError == nil else { return }
        // `write` は throw しない（エラーは firstWriteError に畳む）ので push も throw しない。
        delayLine.push(buf) { self.write($0) }
    }

    /// gate を開閉する。`discardHeld` が true なら遅延線の保持分を捨てる。
    ///
    /// - 広告に入る: `setGate(false, discardHeld: true)`（境界に混ざった広告音を捨てる）
    /// - 一時停止に入る: `setGate(false, discardHeld: false)`（再開後に続きとして書く）
    public func setGate(_ open: Bool, discardHeld: Bool) {
        gateOpen = open
        if discardHeld { delayLine.discard() }
    }

    /// 終了する。gate が開なら遅延線を flush してから閉じ、閉なら保持分を捨ててから閉じる。
    ///
    /// flush 中の書き込みエラーも `onWriteError` に流す（外へ投げない）ので、`writer.close()` は必ず呼ばれる。
    /// `throws` するのは `writer.close()` の失敗だけ。
    public func finish() throws {
        if gateOpen, firstWriteError == nil {
            delayLine.flush { self.write($0) }
        } else {
            delayLine.discard()
        }
        try writer.close()
    }

    /// 1 回だけエラーを覚えて、以後は書かない。
    private func write(_ buf: AVAudioPCMBuffer) {
        guard firstWriteError == nil else { return }
        do {
            try writer.write(buf)
        } catch {
            firstWriteError = error
            onWriteError?(error)
        }
    }
}
