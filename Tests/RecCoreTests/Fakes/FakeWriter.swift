// FakeWriter — テスト用の `AudioFileWriting`。T4 / T5 のテストから使う。
//
// 方針: 観測しやすさを優先して状態は `var` で素直に公開する（本物の排他規約は持ち込まない）。
// テストは単一スレッドから触る前提。

import AVFoundation
import Foundation

@testable import RecCore

final class FakeWriter: AudioFileWriting, @unchecked Sendable {
    /// 非 nil なら `write` がこれを throw する。
    var writeError: Error?
    /// `write` に渡されたバッファの `frameLength` の累計。
    var framesWritten: AVAudioFramePosition = 0
    /// `write` が呼ばれた回数（throw した分も数える）。
    var writeCount = 0
    /// `close()` が呼ばれた回数。
    var closeCount = 0
    /// 書き出し先（本物のファイルは作らない）。
    var url: URL

    init(url: URL = URL(fileURLWithPath: "/dev/null/fake.m4a"), writeError: Error? = nil) {
        self.url = url
        self.writeError = writeError
    }

    func write(_ buf: AVAudioPCMBuffer) throws {
        writeCount += 1
        if let writeError { throw writeError }
        framesWritten += AVAudioFramePosition(buf.frameLength)
    }

    func close() throws {
        closeCount += 1
    }
}
