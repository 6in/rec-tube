// RecordingSession のユニットテスト（PLAN T8 の完了基準の 3 本 + F1 の E 表）。
//
// 確かめる契約:
//   1. url モード: 開始 → 本編再生 → `ended` で `completion(.ok)`。writer は 1 回だけ閉じられ、
//      タブは閉じられる。**E7**: `Messages.stopReason(.ended)` → `Messages.savedTo`（絶対パス）の順で、
//      保存先は最後の 1 行
//   2. `.system` モード: 開始 → シグナル → `completion` が 130（`.signalINT`）。1 フレームも
//      書けていないので `Messages.noData` が出て、**予約した 0 バイトのファイルが消えている**。
//      **E6**: 停止理由の 1 行にシグナル名（`SIGINT`）が入り、**保存先は出ない**
//   3. `.system` モード: 書き込みエラー → `pipeline.onWriteError` 経由で `completion` が 7。
//      **E5**: 停止理由の 1 行 → `firstWriteError` の内容（`fake write failure`）の順
//   4. **E1**: url モードで probe が `gone` → `completion` が 6。停止理由 → 保存先の順で、
//      タブは**閉じない**
//   5. **E11**: スリープ通知（`systemWillSleep`）→ `completion` が 5。**`writer.close()` が
//      ack より前**に終わっている（順序ログで見る）
//   6. **E15**: 録音開始後に JS 許可オフで `fail` → `completion` が 2。原因 1 行 + `Messages.noData` で、
//      **0 バイトの予約ファイルが消えている**（保存先は出ない）
//   7. **E9**: `.system` モードで無音が `Tuning.silenceWarnAfterSeconds` 続くと
//      `Messages.silenceWarning` が**ちょうど 1 回**（`Tuning.silenceWarnIntervalSeconds` 以内は再警告なし）。
//      録音は止まらない
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
        /// `message` と**完全に一致する**行の件数（警告が 1 回だけかを数える）。
        func count(of message: String) -> Int {
            lock.withLock { messages.filter { $0 == message }.count }
        }
    }

    /// 「どちらが先に起きたか」を見るための順序ログ（別キューから書くのでロックで守る）。
    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        func append(_ item: String) { lock.withLock { items.append(item) } }
        var entries: [String] { lock.withLock { items } }
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

    // MARK: - 0. url モードの開始順

    @Test("url モードは 止めて頭出し → 録音開始 → 待ち（probe なし）→ 再生 の順で進む")
    func urlModeHoldsThenPlaysAfterDelay() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        hal.processes = [AudioProc(id: 42, bundle: "com.google.Chrome", running: true)]
        let audio = makeBuffer(format: hal.tapFormatValue, frames: 48_000, value: 0.5)

        let lock = NSLock()
        var events: [String] = []
        func record(_ event: String) { lock.withLock { events.append(event) } }

        let runner = FakeRunner()
        var probes = 0
        runner.handler = { call in
            if call.script.contains("get version") {
                return ScriptResult(status: 0, stdout: "140.0.0.0", stderr: "")
            }
            if call.script.contains("set URL of active tab") {
                return ScriptResult(status: 0, stdout: "9001", stderr: "")
            }
            if call.script.contains("execute t javascript") {
                let js = call.arguments.count >= 2 ? call.arguments[1] : ""
                // `emit` は tap が動いていないと false を返すので、録音開始との前後が分かる。
                let recording = hal.emit(audio)
                if js == holdAtStartJS {
                    record("hold recording=\(recording)")
                } else if js == playJS {
                    record("play recording=\(recording)")
                } else if js == probeJS {
                    record("probe")
                    probes += 1
                    let json = probes == 1 ? Self.playingJSON : Self.endedJSON
                    return ScriptResult(status: 0, stdout: json, stderr: "")
                }
            }
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
            startDelaySeconds: 0.2,
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
                "completion が来ない: messages=\(sink.allMessages)")

        let seen = lock.withLock { events }
        #expect(seen == ["probe", "hold recording=false", "play recording=true", "probe"],
                "開始の順序が違う: \(seen)")
    }

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
                    // `holdAtStartJS` / `playJS` / `rewindJS`。
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
            startDelaySeconds: 0.01,
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

        // E7: 停止理由の 1 行 → 保存先の 1 行（絶対パス）の順。保存先は**最後の 1 行**。
        let messages = sink.allMessages
        let reasonIndex = try #require(messages.firstIndex(of: Messages.stopReason(.ended)),
                                       "停止理由の 1 行が無い: \(messages)")
        let savedIndex = try #require(messages.firstIndex(of: Messages.savedTo(writer.url)),
                                      "保存先の 1 行が無い: \(messages)")
        #expect(reasonIndex < savedIndex, "保存先が停止理由より前に出た: \(messages)")
        #expect(savedIndex == messages.count - 1, "保存先が最後の 1 行ではない: \(messages)")
        #expect(writer.url.standardizedFileURL.path.hasPrefix("/"),
                "予約されたファイルの URL が絶対パスではない: \(writer.url.path)")
        #expect(messages[savedIndex].contains(writer.url.standardizedFileURL.path),
                "保存先の 1 行に絶対パスが入っていない: \(messages[savedIndex])")

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
            startDelaySeconds: 0.01,
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

        // E6: 停止理由の 1 行にシグナル名が入り、その後に `noData`。ファイルが残らないので
        // 保存先の 1 行は**出ない**。
        let messages = sink.allMessages
        let reasonLine = Messages.stopReason(.signal(SIGINT))
        #expect(reasonLine.contains("SIGINT"), "停止理由の 1 行にシグナル名が無い: \(reasonLine)")
        let reasonIndex = try #require(messages.firstIndex(of: reasonLine),
                                       "停止理由の 1 行が無い: \(messages)")
        let noDataIndex = try #require(messages.firstIndex(of: Messages.noData),
                                       "noData の 1 行が無い: \(messages)")
        #expect(reasonIndex < noDataIndex, "noData が停止理由より前に出た: \(messages)")
        let writer = try #require(writers.writer, "writer が作られていない")
        #expect(!messages.contains(Messages.savedTo(writer.url)),
                "ファイルが残らないのに保存先が出た: \(messages)")

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
            startDelaySeconds: 0.01,
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

        // E5: 停止理由の 1 行 → `firstWriteError` の内容（何に失敗したのか）の順。
        let messages = sink.allMessages
        let reasonIndex = try #require(messages.firstIndex(of: Messages.stopReason(.writeFailed)),
                                       "停止理由の 1 行が無い: \(messages)")
        let detailIndex = try #require(messages.firstIndex(where: { $0.contains("fake write failure") }),
                                       "書き込みエラーの内容が出ていない: \(messages)")
        #expect(reasonIndex < detailIndex, "書き込みエラーの内容が停止理由より前に出た: \(messages)")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(sink.completionCount == 1, "completion が 2 回以上呼ばれた: \(sink.allCodes)")
    }

    // MARK: - 4. E1: url モードでタブが閉じられる → 6

    @Test("url モードで録音中にタブが閉じられると 6 で終わり、停止理由 → 保存先の順に出てタブは閉じない")
    func tabClosedStopsWithExitCode6() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        hal.processes = [AudioProc(id: 42, bundle: "com.google.Chrome", running: true)]
        let format = hal.tapFormatValue
        let audio = makeBuffer(format: format, frames: Self.windowFrames(format), value: 0.5)

        let runner = FakeRunner()
        let emits = EmitCounter()
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
                    return ScriptResult(status: 0, stdout: "ok", stderr: "")
                }
                if emits.count < 4 {
                    if hal.emit(audio) { emits.increment() }
                    return ScriptResult(status: 0, stdout: Self.playingJSON, stderr: "")
                }
                // 4 窓流し終えたらタブが見つからなくなる（AppleScript 側が `gone` を返す）。
                // `ChromeController.execute` は `.pageLost` で throw し、`poll` が `.gone` に畳む。
                return ScriptResult(status: 0, stdout: "gone", stderr: "")
            }
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
            startDelaySeconds: 0.01,
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

        #expect(sink.allCodes == [.pageLost],
                "終了コードが 6 ではない: \(sink.allCodes) / messages=\(sink.allMessages)")
        #expect(sink.allCodes.first?.rawValue == 6)

        let writer = try #require(writers.writer, "writer が作られていない")
        #expect(writer.framesWritten > 0, "1 フレームも書けていない")

        // 停止理由の 1 行 → 保存先の 1 行（ファイルが残るので出る）。
        let messages = sink.allMessages
        let reasonIndex = try #require(messages.firstIndex(of: Messages.stopReason(.tabClosed)),
                                       "停止理由の 1 行が無い: \(messages)")
        let savedIndex = try #require(messages.firstIndex(of: Messages.savedTo(writer.url)),
                                      "保存先の 1 行が無い: \(messages)")
        #expect(reasonIndex < savedIndex, "保存先が停止理由より前に出た: \(messages)")
        #expect(savedIndex == messages.count - 1, "保存先が最後の 1 行ではない: \(messages)")

        // タブ閉鎖はユーザー操作なので、こちらからは閉じに行かない（決めた事項 #11）。
        let closed = runner.calls.filter { $0.script.contains("close t") }
        #expect(closed.isEmpty, "タブを閉じに行った: \(closed)")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(sink.completionCount == 1, "completion が 2 回以上呼ばれた: \(sink.allCodes)")
    }

    // MARK: - 5. E11: スリープは ack より前に writer.close() まで終わる

    @Test("スリープ通知では ack を返す前に writer.close() まで終わっていて 5 で終わる")
    func sleepClosesWriterBeforeAcknowledge() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        let format = hal.tapFormatValue
        let audio = makeBuffer(format: format, frames: Self.windowFrames(format), value: 0.5)

        let runner = FakeRunner()
        let sink = Sink()
        let writers = WriterBox()
        let order = OrderLog()
        let powerSource = FakePowerSource()
        let expected = directory.appendingPathComponent("sleep-test.m4a")

        let session = RecordingSession(
            mode: .system,
            output: SessionOutput(directory: directory, explicitBaseName: "sleep-test"),
            hal: hal,
            runner: runner,
            powerSource: powerSource,
            signals: [],
            startDelaySeconds: 0.01,
            pollInterval: 0.01,
            makeWriter: { url, _ in
                let writer = FakeWriter(url: url)
                // `close()` の時点で ack が 0 件なら「close が ack より前」。
                // ack が先に返っていたら 1 件になるので、1 本の順序ログで読み分けられる。
                writer.onClose = {
                    let acks = powerSource.acknowledgeCount(messageType: PowerNotification.systemWillSleep)
                    order.append("close(ack=\(acks))")
                }
                writers.put(writer)
                return writer
            },
            onMessage: { sink.message($0) },
            completion: { sink.complete($0) }
        )

        session.start()
        // 予約ファイルができた = 「録音開始の手順」を通った（= スリープ監視の登録も済んでいる）。
        #expect(waitUntil { FileManager.default.fileExists(atPath: expected.path) },
                "0 バイトの予約ファイルができていない: \(expected.path)")
        #expect(hal.hasIOBlock, "IOProc が張られていない")
        // 1 窓ぶん音を流す（ファイルが残る側の経路を通す）。
        #expect(hal.emit(audio), "IOProc に流せない")

        #expect(powerSource.send(messageType: PowerNotification.systemWillSleep, argument: 1),
                "スリープ通知を配れない（register されていない）")
        #expect(waitUntil { sink.completionCount == 1 },
                "completion が来ない: messages=\(sink.allMessages)")

        #expect(sink.allCodes == [.interrupted], "終了コードが 5 ではない: \(sink.allCodes)")
        #expect(sink.allCodes.first?.rawValue == 5)
        #expect(sink.allMessages.contains(Messages.stopReason(.sleep)),
                "停止理由の 1 行が無い: \(sink.allMessages)")

        // ここが E11 の本体: close は ack より前。
        #expect(order.entries == ["close(ack=0)"],
                "writer.close() が ack より後に走った（または呼ばれていない）: \(order.entries)")
        #expect(powerSource.acknowledgeCount(messageType: PowerNotification.systemWillSleep) == 1,
                "ack が 1 回ではない: \(powerSource.log)")
        #expect(writers.writer?.closeCount == 1, "close() が 1 回ではない")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(sink.completionCount == 1, "completion が 2 回以上呼ばれた: \(sink.allCodes)")
    }

    // MARK: - 6. E15: 録音開始後に fail → 原因 1 行 + noData、0 バイトのファイルを残さない

    @Test("録音開始後に JS 許可オフで落ちると 2 で終わり、0 バイトの予約ファイルが消える")
    func failAfterRecordingStartedRemovesEmptyFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        hal.processes = [AudioProc(id: 42, bundle: "com.google.Chrome", running: true)]

        let runner = FakeRunner()
        let probes = EmitCounter()
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
                    return ScriptResult(status: 0, stdout: "ok", stderr: "")
                }
                probes.increment()
                if probes.count == 1 {
                    // 1 回目で録音が始まる（writer まで作られて 0 バイトのファイルが予約される）。
                    return ScriptResult(status: 0, stdout: Self.playingJSON, stderr: "")
                }
                // 2 回目以降は「Apple Events からの JavaScript を許可」がオフの状態
                // （`ChromeControllerTests` と同じ stderr / status 非 0）。
                return ScriptResult(
                    status: 1,
                    stdout: "",
                    stderr: "34:48: execution error: Executing JavaScript through AppleScript is turned off. (-2700)\n"
                )
            }
            return ScriptResult(status: 0, stdout: "ok", stderr: "")
        }

        let sink = Sink()
        let writers = WriterBox()
        let expected = directory.appendingPathComponent("js-off.m4a")

        let session = RecordingSession(
            mode: .url("https://www.youtube.com/watch?v=abc123"),
            output: SessionOutput(directory: directory, explicitBaseName: "js-off"),
            hal: hal,
            runner: runner,
            powerSource: FakePowerSource(),
            signals: [],
            startDelaySeconds: 0.01,
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
                "completion が来ない: messages=\(sink.allMessages)")

        // 原因の code（JS 許可オフ → `.chromeUnavailable` = 2）。無音 / noData で上書きしない。
        #expect(sink.allCodes == [.chromeUnavailable],
                "終了コードが 2 ではない: \(sink.allCodes) / messages=\(sink.allMessages)")
        #expect(sink.allCodes.first?.rawValue == 2)

        // 1 フレームも流していないので writer は作られたが何も書いていない。
        // `writer.url` が予約されたパスであること自体が「0 バイトのファイルが作られた」証拠
        // （`reserveUniquePath` は `O_EXCL` で作れたときだけ URL を返す）。予約直後に `fail` が
        // 走るので、消える前の存在をテストから覗くのは間に合わない。
        let writer = try #require(writers.writer, "writer が作られていない")
        #expect(writer.url.standardizedFileURL.path == expected.standardizedFileURL.path,
                "予約されたパスが違う: \(writer.url.path)")
        #expect(writer.framesWritten == 0, "1 フレーム以上書けている")
        #expect(!FileManager.default.fileExists(atPath: expected.path),
                "0 バイトの予約ファイルが残っている: \(expected.path)")

        // 原因 1 行 → `noData` の順。保存先は出ない。
        let messages = sink.allMessages
        let causeIndex = try #require(messages.firstIndex(of: Messages.chromeJavaScriptPermission),
                                      "原因の 1 行が無い: \(messages)")
        let noDataIndex = try #require(messages.firstIndex(of: Messages.noData),
                                       "noData の 1 行が無い: \(messages)")
        #expect(causeIndex < noDataIndex, "noData が原因より前に出た: \(messages)")
        #expect(!messages.contains(Messages.savedTo(writer.url)),
                "ファイルが残らないのに保存先が出た: \(messages)")

        // `fail` はタブを閉じない（開いたばかりのタブをユーザーに残す）。
        let closed = runner.calls.filter { $0.script.contains("close t") }
        #expect(closed.isEmpty, "タブを閉じに行った: \(closed)")

        Thread.sleep(forTimeInterval: 0.1)
        #expect(sink.completionCount == 1, "completion が 2 回以上呼ばれた: \(sink.allCodes)")
    }

    // MARK: - 7. E9: system モードの無音警告はちょうど 1 回

    @Test("system モードで無音が続くと silenceWarning が 1 回だけ出て、録音は止まらない")
    func systemModeWarnsOnceWhileSilent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hal = FakeHAL()
        let format = hal.tapFormatValue
        // 全ゼロ = `allZero` かつ silent。`.system` モードには tap 故障の判定が無いので止まらない。
        let silence = makeBuffer(format: format, frames: Self.windowFrames(format), value: 0)

        let runner = FakeRunner()
        let sink = Sink()
        let writers = WriterBox()
        let expected = directory.appendingPathComponent("silence-test.m4a")

        let session = RecordingSession(
            mode: .system,
            output: SessionOutput(directory: directory, explicitBaseName: "silence-test"),
            hal: hal,
            runner: runner,
            powerSource: FakePowerSource(),
            signals: [],
            startDelaySeconds: 0.01,
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
        #expect(waitUntil { FileManager.default.fileExists(atPath: expected.path) },
                "0 バイトの予約ファイルができていない: \(expected.path)")
        #expect(hal.hasIOBlock, "IOProc が張られていない")

        // 6 窓ぶん（`Tuning.silenceWarnAfterSeconds` = 5 秒を超える）流す。
        for _ in 0 ..< 6 {
            #expect(hal.emit(silence), "IOProc に流せない")
        }

        // タイマーは `Tuning.meterWindowSeconds` ごとに見るので、最初の警告まで 1 窓待つ。
        #expect(waitUntil(timeout: 4.0) { sink.count(of: Messages.silenceWarning) == 1 },
                "silenceWarning が 1 回出ていない: \(sink.count(of: Messages.silenceWarning)) 回")
        // さらに待っても再警告しない（`Tuning.silenceWarnIntervalSeconds` = 30 秒以内）。
        Thread.sleep(forTimeInterval: 1.0)
        #expect(sink.count(of: Messages.silenceWarning) == 1,
                "silenceWarning が 2 回以上出た: \(sink.count(of: Messages.silenceWarning)) 回")
        // 無音でも録音は続いている。
        #expect(sink.completionCount == 0, "無音警告で録音が止まった: \(sink.allCodes)")

        session.requestStop(.signal(SIGINT))
        #expect(waitUntil { sink.completionCount == 1 },
                "completion が来ない: messages=\(sink.allMessages)")
        #expect(sink.allCodes == [.signalINT], "終了コードが 130 ではない: \(sink.allCodes)")
    }

    // MARK: - 補助（窓長）

    /// メータの 1 窓ぶんのフレーム数（秒数は `Tuning.meterWindowSeconds` から作る。直書きしない）。
    private static func windowFrames(_ format: AVAudioFormat) -> AVAudioFrameCount {
        AVAudioFrameCount((format.sampleRate * Tuning.meterWindowSeconds).rounded())
    }
}
