// RecordingSession のユニットテスト（PLAN T8 の完了基準の 3 本）。
//
// 確かめる契約:
//   1. url モード: 開始 → 本編再生 → `ended` で `completion(.ok)`。writer は 1 回だけ閉じられ、
//      タブは閉じられる
//   2. `.system` モード: 開始 → シグナル → `completion` が 130（`.signalINT`）。1 フレームも
//      書けていないので `Messages.noData` が出て、**予約した 0 バイトのファイルが消えている**
//   3. `.system` モード: 書き込みエラー → `pipeline.onWriteError` 経由で `completion` が 7
//
// 書き方の約束（`StopCoordinatorTests` の作法に合わせる）:
//   - `completion` / `onMessage` は別キュー（`rec.session`）から呼ばれるので、受け取り側は
//     NSLock で守った箱（`Sink`）に貯める
//   - 別キューの到着を待つ場所だけ `waitUntil`（最大 2 秒のポーリング）を使う
//   - `FakeRunner` / `FakeWriter` はスレッド安全でないので、**読み出しは `completion` が来た後**に行う
//   - 本物のシグナルは張らない（`signals: []`）。中断は `requestStop(.signal(SIGINT))` で再現する
//   - `pollInterval` は 0.01 秒に縮めて待ち時間を作らない
//   - 一時ディレクトリは `FileManager.default.temporaryDirectory` 配下に作って最後に消す

import AVFoundation
import Foundation
import Testing

@testable import RecCore

@Suite("RecordingSession")
struct RecordingSessionTests {
    // MARK: - 受け取り側の箱

    /// `completion` と `onMessage` の記録（別キューから呼ばれるのでロックで守る）。
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [ExitCode] = []
        private var messages: [String] = []

        func complete(_ code: ExitCode) { lock.withLock { codes.append(code) } }
        func message(_ text: String) { lock.withLock { messages.append(text) } }

        var completionCount: Int { lock.withLock { codes.count } }
        var allCodes: [ExitCode] { lock.withLock { codes } }
        var allMessages: [String] { lock.withLock { messages } }
    }

    /// `makeWriter` が作った `FakeWriter` を test から見るための箱。
    private final class WriterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: FakeWriter?

        func put(_ writer: FakeWriter) { lock.withLock { value = writer } }
        var writer: FakeWriter? { lock.withLock { value } }
    }

    /// `FakeRunner.handler`（セッションキュー上で走る）が数える「音を流した回数」。
    private final class EmitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }

    // MARK: - 補助

    /// `condition` が true になるまで最大 `timeout` 秒待つ（別キューの到着を待つ場所だけで使う）。
    private func waitUntil(timeout: Double = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// テスト用の一時ディレクトリ（呼び出し側が `defer` で消す）。
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 全サンプルが `value` のバッファ（`value != 0` なら「全ゼロでない」かつ `-6 dBFS` で無音でもない）。
    private func makeBuffer(format: AVAudioFormat,
                            frames: AVAudioFrameCount,
                            value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0 ..< Int(format.channelCount) {
                for frame in 0 ..< Int(frames) {
                    channels[channel][frame] = value
                }
            }
        }
        return buffer
    }

    // MARK: - probe の応答（9 キー固定。`ProbeJS.swift` の契約）

    private static let playingJSON = """
        {"kind":"main","state":"playing","id":"abc123","cur":0.0,"dur":120.0,\
        "live":false,"title":"テスト動画","len":120,"playErr":null}
        """

    private static let endedJSON = """
        {"kind":"main","state":"ended","id":"abc123","cur":120.0,"dur":120.0,\
        "live":false,"title":"テスト動画","len":120,"playErr":null}
        """

    // MARK: - 1. url モード: 開始 → ended → completion(.ok)

    @Test("url モードで本編を録り、ended で completion(.ok) が 1 回だけ呼ばれてタブが閉じられる")
    func urlModeEndsWithOK() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        hal.processes = [AudioProc(id: 42, bundle: "com.google.Chrome", running: true)]
        // `FakeHAL.tapFormatValue` の既定は 48kHz / 2ch。1 窓 = 48000 フレーム。
        let format = hal.tapFormatValue
        let audio = makeBuffer(format: format, frames: 48_000, value: 0.5)

        let runner = FakeRunner()
        let emits = EmitCounter()
        // スクリプト本文で呼び出しを見分ける（`ChromeController` の本文は定数なので中身で判別できる）。
        runner.handler = { call in
            if call.script.contains("get version") {
                return ScriptResult(status: 0, stdout: "140.0.0.0", stderr: "")
            }
            if call.script.contains("set URL of active tab") {
                return ScriptResult(status: 0, stdout: "9001", stderr: "")
            }
            if call.script.contains("execute t javascript") {
                let js = call.arguments.count >= 2 ? call.arguments[1] : ""
                guard js == probeJS else {
                    // `seekToStartJS` / `rewindJS`。
                    return ScriptResult(status: 0, stdout: "ok", stderr: "")
                }
                // 録音が始まって gate が開いたあと、1 窓ぶんずつ音を流す。
                // `emit` は IOProc が無い間 false を返すので、カウンタは「実際に流せた回数」になる。
                if emits.count < 4 {
                    if hal.emit(audio) { emits.increment() }
                    return ScriptResult(status: 0, stdout: Self.playingJSON, stderr: "")
                }
                // 4 窓流し終えたら再生終了にする。
                return ScriptResult(status: 0, stdout: Self.endedJSON, stderr: "")
            }
            // close。
            return ScriptResult(status: 0, stdout: "ok", stderr: "")
        }

        let sink = Sink()
        let writers = WriterBox()
        let session = RecordingSession(
            mode: .url("https://www.youtube.com/watch?v=abc123"),
            output: SessionOutput(directory: directory, explicitBaseName: nil),
            hal: hal,
            runner: runner,
            powerSource: FakePowerSource(),
            signals: [],
            pollInterval: 0.01,
            makeWriter: { url, _ in
                let writer = FakeWriter(url: url)
                writers.put(writer)
                return writer
            },
            onMessage: { sink.message($0) },
            completion: { sink.complete($0) }
        )

        session.start()
        #expect(waitUntil(timeout: 5.0) { sink.completionCount == 1 },
                "completion が来ない: \(sink.completionCount) 回 / messages=\(sink.allMessages)")

        // ここから下は completion が来た後なので `FakeRunner` / `FakeWriter` を読んでよい。
        #expect(sink.allCodes == [.ok],
                "終了コードが .ok ではない: \(sink.allCodes) / messages=\(sink.allMessages)")

        let writer = try #require(writers.writer, "writer が作られていない")
        #expect(writer.closeCount == 1, "close() が 1 回ではない: \(writer.closeCount)")
        #expect(writer.framesWritten > 0, "1 フレームも書けていない")
        #expect(!sink.allMessages.contains(Messages.noData), "noData が出た: \(sink.allMessages)")
        #expect(!sink.allMessages.contains(Messages.silent), "silent が出た: \(sink.allMessages)")

        // 正常終了なのでタブを閉じている（決めた事項 #11）。
        let closed = runner.calls.filter { $0.script.contains("close t") }
        #expect(closed.count == 1, "close スクリプトが 1 回ではない: \(closed.count)")
        #expect(closed.first?.arguments == ["9001"], "close に渡したタブ ID が違う: \(closed)")

        // しばらく待っても completion は増えない（ちょうど 1 回）。
        Thread.sleep(forTimeInterval: 0.1)
        #expect(sink.completionCount == 1, "completion が 2 回以上呼ばれた: \(sink.allCodes)")
    }

    // MARK: - 2. 開始 → シグナル → completion が 130

    @Test("録音開始後にシグナルで中断すると 130 で終わり、0 バイトの予約ファイルが消える")
    func signalStopsWithExitCode130() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        let runner = FakeRunner()
        let sink = Sink()
        let writers = WriterBox()
        let expected = directory.appendingPathComponent("signal-test.m4a")

        let session = RecordingSession(
            mode: .system,
            output: SessionOutput(directory: directory, explicitBaseName: "signal-test"),
            hal: hal,
            runner: runner,
            powerSource: FakePowerSource(),
            signals: [],
            pollInterval: 0.01,
            makeWriter: { url, _ in
                let writer = FakeWriter(url: url)
                writers.put(writer)
                return writer
            },
            onMessage: { sink.message($0) },
            completion: { sink.complete($0) }
        )

        session.start()
        // 予約ファイルができた = tap が起動して writer まで作られた（「録音開始の手順」を通った）。
        #expect(waitUntil { FileManager.default.fileExists(atPath: expected.path) },
                "0 バイトの予約ファイルができていない: \(expected.path)")
        #expect(hal.hasIOBlock, "IOProc が張られていない")

        session.requestStop(.signal(SIGINT))
        #expect(waitUntil { sink.completionCount == 1 },
                "completion が来ない: messages=\(sink.allMessages)")

        #expect(sink.allCodes == [.signalINT], "終了コードが 130 ではない: \(sink.allCodes)")
        #expect(sink.allCodes.first?.rawValue == 130)
        // 1 フレームも書けていないのでファイルは消えて noData が出る（code は上書きしない）。
        #expect(sink.allMessages.contains(Messages.noData), "noData が出ていない: \(sink.allMessages)")
        #expect(!FileManager.default.fileExists(atPath: expected.path),
                "0 バイトの予約ファイルが残っている: \(expected.path)")
        #expect(writers.writer?.framesWritten == 0)
        #expect(writers.writer?.closeCount == 1, "close() が 1 回ではない")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(sink.completionCount == 1, "completion が 2 回以上呼ばれた: \(sink.allCodes)")
    }

    // MARK: - 3. write エラー → completion が 7

    @Test("書き込みエラーは onWriteError 経由で停止要求になり、completion が 7 になる")
    func writeErrorStopsWithExitCode7() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        let format = hal.tapFormatValue
        let audio = makeBuffer(format: format, frames: 4_800, value: 0.5)

        let runner = FakeRunner()
        let sink = Sink()
        let writers = WriterBox()
        let expected = directory.appendingPathComponent("write-error.m4a")
        let writeError = RecError(code: .outputUnavailable, message: "fake write failure")

        let session = RecordingSession(
            mode: .system,
            output: SessionOutput(directory: directory, explicitBaseName: "write-error"),
            hal: hal,
            runner: runner,
            powerSource: FakePowerSource(),
            signals: [],
            pollInterval: 0.01,
            makeWriter: { url, _ in
                let writer = FakeWriter(url: url, writeError: writeError)
                writers.put(writer)
                return writer
            },
            onMessage: { sink.message($0) },
            completion: { sink.complete($0) }
        )

        session.start()
        #expect(waitUntil { FileManager.default.fileExists(atPath: expected.path) },
                "0 バイトの予約ファイルができていない: \(expected.path)")

        // `pipeline` が IO キューへ公開されるのは writer を作った直後なので、
        // 届くまで（= completion が来るまで）バッファを流し続ける。2 回目以降の `write` は
        // `firstWriteError` で止まるので、エラーは 1 回しか上がらない。
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, sink.completionCount == 0 {
            _ = hal.emit(audio)
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(sink.completionCount == 1, "completion が来ない: messages=\(sink.allMessages)")
        #expect(sink.allCodes == [.outputUnavailable], "終了コードが 7 ではない: \(sink.allCodes)")
        #expect(sink.allCodes.first?.rawValue == 7)
        #expect(writers.writer?.writeCount == 1, "write が 1 回ではない: \(writers.writer?.writeCount ?? -1)")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(sink.completionCount == 1, "completion が 2 回以上呼ばれた: \(sink.allCodes)")
    }
}
