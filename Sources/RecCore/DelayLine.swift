// DelayLine.swift — 固定長の遅延線（広告ガード）。
//
// 役割は 1 つだけ: tap から来たバッファを `guardSeconds` 分だけ手元に溜め、溢れた分を古い順に
// 下流（ファイルライタ）へ渡す。広告の境界が録音に混ざらないように出力を遅らせるための部品。
//
// 断言:
//   - `guardFrames = Int((guardSeconds * format.sampleRate).rounded())`
//   - `push` は渡されたバッファを**コピーして**保持する。呼び出し側は Core Audio の IOProc から
//     来た使い回しバッファを渡すので、参照だけ持つと次の IOProc で中身が壊れる。
//   - `push` から戻った時点で常に `heldFrames <= guardFrames`（**固定長**＝メモリが伸び続けない）。
//   - `emit` される順序は push された順序と完全に一致する（FIFO）。バッファは**分割しない**。
//   - `guardSeconds == 0`（= `guardFrames == 0`）なら push は渡されたバッファをそのまま即 `emit`
//     する（コピーも保持もしない）。
//
// 秒数は直書きしない。既定値が要る場面の `guardSeconds` は `Tuning.adGuardSeconds`
// （`--ad-guard` の既定値 / 範囲は `Tuning.adGuardRange`）を渡す。
//
// `init` で受けた format と違うバッファが来ることは想定しない（1 セッションには 1 つの format の
// バッファだけが流れる）。コピー先も `init` の format で作る。

import AVFoundation
import Foundation

/// 固定長の遅延線。`push` されたバッファを `guardSeconds` 分だけ保持し、溢れた分を古い順に `emit` する。
///
/// `@unchecked Sendable`: 可変状態（`held` / `heldFrameTotal`）は IO キュー（`TapRecorder` の `rec.io`）
/// 上でだけ触る規約。**内部ロックは持たない**ので、呼び出し側が `push` / `discard` / `flush` /
/// `heldFrames` を 1 本のキューにシリアライズすること。このリポジトリの `AVAudioFileWriter` と同じ方針。
public final class DelayLine: @unchecked Sendable {
    /// 保持できるフレーム数の上限。`push` から戻った時点で常に `heldFrames <= guardFrames`。
    let guardFrames: Int

    /// コピー先バッファを作るときの format（`init` で受けたもの）。
    private let format: AVAudioFormat

    /// 保持中のバッファ（先頭が最古）。要素数は `guardFrames / 1 バッファのフレーム数` 程度。
    private var held: [AVAudioPCMBuffer] = []

    /// `held` の `frameLength` の合計（毎回数え直さないためのキャッシュ）。
    private var heldFrameTotal = 0

    /// `guardSeconds` 分の遅延線を作る。`guardSeconds == 0` なら遅延しない（素通し）。
    public init(format: AVAudioFormat, guardSeconds: Double) {
        self.format = format
        guardFrames = Int((guardSeconds * format.sampleRate).rounded())
    }

    /// 保持しているフレーム数の合計。`discard()` / `flush(emit:)` の直後は 0。
    public var heldFrames: Int { heldFrameTotal }

    /// バッファ 1 つを流し込む。保持が `guardFrames` を超えている間、最古のバッファを丸ごと `emit` に渡す。
    ///
    /// `emit` が throw したらその例外は呼び出し側に伝わる（`rethrows`）。`emit` に渡したバッファは
    /// その時点で保持から外れているので、throw した分は失われる（二重に `emit` されることはない）。
    public func push(_ buf: AVAudioPCMBuffer, emit: (AVAudioPCMBuffer) throws -> Void) rethrows {
        // 遅延 0 のときは溜めずにそのまま下流へ（コピーもしない）。
        guard guardFrames > 0 else {
            try emit(buf)
            return
        }
        held.append(copy(buf))
        heldFrameTotal += Int(buf.frameLength)
        // `guardFrames` を**超えている間**だけ吐く（ちょうどは保持したまま）。
        // `held.first` を見るので、1 バッファが `guardFrames` より長くても空回りしない。
        while heldFrameTotal > guardFrames, let oldest = held.first {
            held.removeFirst()
            heldFrameTotal -= Int(oldest.frameLength)
            try emit(oldest)
        }
    }

    /// 保持分を全部捨てる（`emit` は呼ばない）。広告区間の破棄に使う。
    public func discard() {
        held.removeAll()
        heldFrameTotal = 0
    }

    /// 保持分を全部古い順に `emit` して空にする。録音終了時の締めに使う。
    public func flush(emit: (AVAudioPCMBuffer) throws -> Void) rethrows {
        while let oldest = held.first {
            held.removeFirst()
            heldFrameTotal -= Int(oldest.frameLength)
            try emit(oldest)
        }
        heldFrameTotal = 0
    }

    // MARK: - コピー

    /// バッファの中身ごと複製する。IOProc の使い回しバッファを保持するために必須。
    ///
    /// `AVAudioPCMBuffer` のサンプル型（float32 / int16 …）に依存しないよう、`AudioBufferList` 越しに
    /// `memcpy` する。`frameCapacity: 0` は作れないので下限を 1 にする。
    private func copy(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(buf.frameLength, 1))!
        out.frameLength = buf.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buf.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for index in 0 ..< min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return out
    }
}
