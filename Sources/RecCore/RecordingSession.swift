// RecordingSession.swift — 1 回の録音を端から端まで回すオーケストレータ。
//
// ここは「判断」をしない。判断はすべて他の型が持っている:
//   - 何を録るか / いつ gate を開閉するか / いつ止めるか → `SessionPolicy`（`SessionAction` で指示が来る）
//   - 停止要求の一本化 → `StopCoordinator`
//   - tap / aggregate / IOProc の寿命 → `TapRecorder`
//   - 測る / 遅らせる / 書く → `RecordingPipeline`（+ `SilenceMeter` / `DelayLine` / `AudioFileWriting`）
//   - Chrome 操作 → `ChromeController` / `ProbeJS`
// この型の仕事は「それらを正しい順序・正しいキューで呼び、後始末をちょうど 1 回通す」こと。
//
// **断言（この型の契約）**:
//   - `completion` は**ちょうど 1 回**だけ呼ばれる
//   - `finish` は冪等で、どの経路（正常終了・シグナル・スリープ・`RecorderEvent`・書き込みエラー・
//     起動失敗）から来ても同じ後始末を通る
//   - **`exit()` は呼ばない**（`exit` を呼ぶのは `Sources/rec/main.swift` だけ、という PLAN P1 の約束）
//
// キューの規約（破ると自己デッドロックする）:
//   - セッションキュー `rec.session`（直列）: タイマー・policy・`chrome` の呼び出し・`finish`
//   - IO キュー `rec.io`（直列）: `TapRecorder` に渡す。`pipeline` / `meter` / `writer` を触るのはここだけ
//   - `TapRecorder.stop()` は内部で `ioQueue.sync {}` を呼ぶので、**IO キューの上から
//     `recorder.stop()` を呼ばない**。`finish` はセッションキュー上なので問題ない
//
// 追従先: `SessionAction` に case を足したら `apply(_:)` を同じターンで直す（switch は
// exhaustive にして `default` を書かない。build が漏れを教える）。

import AVFoundation
import Foundation

// MARK: - 入力

/// 何を録るか。T9（CLI）が引数を解決してからこの形で渡す。
public enum SessionMode: Sendable {
    /// システム全体。probe なし・gate 常時開・guard 0。
    case system
    /// `--app` で解決済みの対象。probe なし・gate 常時開・guard 0。
    case app(TapTarget)
    /// Chrome で URL を開いて本編だけ録る。probe あり・gate は policy が開閉・guard あり。
    case url(String)
}

/// 出力先の 3 要素。`-o` の分解（親ディレクトリ / 名前 / 拡張子）は T9 の仕事で、ここは分解済みを受ける。
public struct SessionOutput: Sendable {
    /// 保存先ディレクトリ。
    public let directory: URL
    /// `-o` で指定された名前（拡張子なし）。nil ならタイトル → `defaultBaseName`。
    public let explicitBaseName: String?
    /// ドットなしの拡張子。
    public let ext: String

    public init(directory: URL, explicitBaseName: String?, ext: String = "m4a") {
        self.directory = directory
        self.explicitBaseName = explicitBaseName
        self.ext = ext
    }
}

// MARK: - RecordingSession

/// 1 回の録音セッション。`start()` を呼ぶと非同期に走り、終わると `completion` がちょうど 1 回呼ばれる。
///
/// `@unchecked Sendable`: 可変状態はキューの規約（上記）と `stateLock`（`coordinator` と「終了済み」の旗）で
/// 守る。`coordinator` と `finished` だけがセッションキュー以外から触られるので、そこだけロックで囲む。
public final class RecordingSession: @unchecked Sendable {
    // MARK: 不変（init で決まる）

    private let mode: SessionMode
    private let output: SessionOutput
    private let adGuardSeconds: Double
    private let hal: AudioHAL
    private let runner: ScriptRunner
    private let powerSource: PowerSource
    private let signals: [Int32]
    private let pollInterval: Double
    private let startTimeout: Double
    private let makeWriter: (URL, AVAudioFormat) throws -> AudioFileWriting
    private let now: () -> Date
    private let onMessage: (String) -> Void
    private let completion: (ExitCode) -> Void

    /// タイマー・policy・`chrome` の呼び出し・`finish` を載せる直列キュー。
    private let sessionQueue = DispatchQueue(label: "rec.session")
    /// `TapRecorder` に渡す直列キュー。`pipeline` / `meter` / `writer` を触るのはここだけ。
    private let ioQueue = DispatchQueue(label: "rec.io")

    // MARK: `stateLock` 下でだけ触る可変状態

    /// `coordinatorStorage` と `finished` を守る。別キュー（`TapRecorder` のイベントキュー・
    /// IO キュー・呼び出し側のスレッド）から触られるのはこの 2 つだけ。
    private let stateLock = NSLock()
    private var coordinatorStorage: StopCoordinator?
    /// 後始末を通したか（`finish` / `fail` が共有する「1 回だけ」の旗）。
    private var finished = false

    /// 停止要求の受付口。`request` はどのスレッドからでも呼べる（ハンドラはセッションキューで走る）。
    private var coordinator: StopCoordinator? {
        get { stateLock.withLock { coordinatorStorage } }
        set { stateLock.withLock { coordinatorStorage = newValue } }
    }

    // MARK: セッションキュー上でだけ触る可変状態

    /// シグナル監視。**変数に保持し続ける**（手放すと deinit で監視が止まる）。
    private var signalWatcher: SignalWatcher?
    /// スリープ監視。同じく保持し続ける。
    private var powerWatcher: PowerWatcher?
    /// url モードの Chrome 操作口（他のモードでは nil）。
    private var chrome: ChromeController?
    /// url モードで開いたタブ ID。
    private var tab: String?
    /// url モードの poll タイマー。
    private var timer: DispatchSourceTimer?
    /// url モードの状態機械。
    private var policy: SessionPolicy?
    /// tap の寿命。`finish` で `stop()` する。
    private var recorder: TapRecorder?
    /// 「録音開始の手順」を通したか（1 セッションに 1 回だけ）。
    private var recordingStarted = false

    // MARK: IO キュー上でだけ触る可変状態

    private var pipeline: RecordingPipeline?
    private var meter: SilenceMeter?

    // MARK: 初期化

    /// - Parameters:
    ///   - mode: 何を録るか
    ///   - output: 出力先（分解済み）
    ///   - adGuardSeconds: 遅延線の長さ（秒）。**url モードだけ**使う（他は 0）
    ///   - hal: Core Audio への入口（テストは `FakeHAL`）
    ///   - runner: AppleScript の実行口（テストは `FakeRunner`）
    ///   - powerSource: 電源通知（テストは `FakePowerSource`）
    ///   - signals: 張るシグナル（テストは `[]` で本物を張らない）
    ///   - pollInterval: probe の間隔（秒）
    ///   - startTimeout: tap の開始を打ち切るまでの秒数
    ///   - makeWriter: 出力先と format から writer を作る（テストは `FakeWriter`）
    ///   - now: 現在時刻（policy と既定ファイル名に渡す）
    ///   - onMessage: 人向けの 1 行（既定は stderr へ改行付きで書く）
    ///   - completion: 終了コードを**ちょうど 1 回**受け取る
    public init(mode: SessionMode,
                output: SessionOutput,
                adGuardSeconds: Double = Tuning.adGuardSeconds,
                hal: AudioHAL = CoreAudioHAL(),
                runner: ScriptRunner = OsascriptRunner(),
                powerSource: PowerSource = IOKitPowerSource(),
                signals: [Int32] = [SIGINT, SIGTERM, SIGHUP],
                pollInterval: Double = Tuning.pollIntervalSeconds,
                startTimeout: Double = Tuning.tapStartTimeoutSeconds,
                makeWriter: @escaping (URL, AVAudioFormat) throws -> AudioFileWriting
                    = { try AVAudioFileWriter(url: $0, format: $1) },
                now: @escaping () -> Date = Date.init,
                onMessage: @escaping (String) -> Void = { message in
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                },
                completion: @escaping (ExitCode) -> Void) {
        self.mode = mode
        self.output = output
        self.adGuardSeconds = adGuardSeconds
        self.hal = hal
        self.runner = runner
        self.powerSource = powerSource
        self.signals = signals
        self.pollInterval = pollInterval
        self.startTimeout = startTimeout
        self.makeWriter = makeWriter
        self.now = now
        self.onMessage = onMessage
        self.completion = completion
    }

    // MARK: - 公開 API

    /// 開始する。セッションキュー上で非同期に走り、終わると `completion` がちょうど 1 回呼ばれる。
    public func start() {
        sessionQueue.async { [weak self] in
            self?.run()
        }
    }

    /// 外から停止を要求する（シグナル以外の経路・テストの刺激口）。
    ///
    /// 最初の 1 本だけが採用され、2 回目以降は黙って捨てられる（`StopCoordinator` の契約）。
    public func requestStop(_ reason: StopReason) {
        _ = coordinator?.request(reason)
    }

    // MARK: - 起動（セッションキュー上）

    private func run() {
        // 1. 停止要求の受付口。ここから下はどの経路も `finish` の 1 本に合流する。
        coordinator = StopCoordinator(queue: sessionQueue) { [weak self] reason in
            self?.finish(reason)
        }

        // 2. シグナル監視（保持し続ける。手放すと deinit で監視が止まる）。
        signalWatcher = SignalWatcher(signals: signals, queue: sessionQueue) { [weak self] sig in
            _ = self?.coordinator?.request(.signal(sig))
        }

        // 3. スリープ監視。**失敗しても続行する**（スリープ監視の失敗で録音を諦めない）。
        let watcher = PowerWatcher(source: powerSource, queue: sessionQueue) { [weak self] reason in
            _ = self?.coordinator?.request(reason)
        }
        powerWatcher = watcher
        do {
            try watcher.start()
        } catch let error as RecError {
            onMessage(error.message)
        } catch {
            onMessage("スリープ通知を登録できませんでした: \(error)")
        }

        // 4. モード別。
        switch mode {
        case .system, .app:
            // probe が無いので policy もタイマーも作らない。ただちに録り始める。
            beginRecording(title: nil)
        case .url(let url):
            let chrome = ChromeController(runner: runner)
            self.chrome = chrome
            do {
                try chrome.checkAutomation()
                tab = try chrome.open(url: url)
            } catch let error as RecError {
                fail(error)
                return
            } catch {
                fail(RecError(code: .chromeUnavailable, message: "Chrome を制御できません: \(error)"))
                return
            }
            policy = SessionPolicy(startedAt: now())
            let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
            // 最初の発火も `pollInterval` 後（start() の直後に probe を取りに行かない）。
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.activate()
        }
    }

    // MARK: - poll（url モードだけ。セッションキュー上）

    /// probe を 1 回取って policy に渡し、返ってきた指示を順番に適用する。
    private func poll() {
        guard !isFinished, let chrome, let tab else { return }

        // 1. probe。`.pageLost` は `.gone` に畳む（T7 の申し送り。`parseProbe("gone")` と同じ行に合流する）。
        let outcome: ProbeOutcome
        do {
            outcome = parseProbe(try chrome.execute(tab: tab, js: probeJS))
        } catch let error as RecError where error.code == .pageLost {
            outcome = .gone
        } catch let error as RecError {
            // 許可系（`.chromeUnavailable`）。録音を続けられないので起動失敗と同じ扱いで終わる。
            fail(error)
            return
        } catch {
            fail(RecError(code: .coreAudio, message: "ページの状態を取得できませんでした: \(error)"))
            return
        }

        // 2. メータの snapshot（IO キュー上で読む）。まだ録音開始前ならすべて 0。
        let snapshot = ioQueue.sync { meter?.snapshot } ?? Self.zeroSnapshot

        // 3. policy の指示を順番に適用する。`.stop` を適用したら残りは適用しない。
        guard var policy else { return }
        let actions = policy.step(probe: outcome, meter: snapshot, now: now())
        self.policy = policy
        for action in actions {
            if !apply(action) { return }
        }
    }

    /// まだ録音を開始していないときに policy へ渡す「すべて 0」の snapshot。
    private static let zeroSnapshot = MeterSnapshot(everNonZero: false,
                                                    consecutiveAllZeroSeconds: 0,
                                                    consecutiveSilentSeconds: 0,
                                                    audibleGateOpenWindows: 0,
                                                    totalWindows: 0)

    /// 指示 1 つを実行する。
    ///
    /// - Returns: 続けて次の指示を適用してよいか（`.stop` を適用したら `false`）。
    private func apply(_ action: SessionAction) -> Bool {
        // `default` を書かない: `SessionAction` に case が増えたら build が漏れを教える。
        switch action {
        case .wait:
            break
        case .startRecording(let title):
            beginRecording(title: title)
        case .seekToStart:
            if let chrome, let tab {
                _ = try? chrome.execute(tab: tab, js: seekToStartJS)
            }
        case .openGate:
            ioQueue.async { [weak self] in
                self?.pipeline?.setGate(true, discardHeld: false)
            }
        case .closeGateDiscard:
            ioQueue.async { [weak self] in
                self?.pipeline?.setGate(false, discardHeld: true)
            }
        case .closeGateHold:
            ioQueue.async { [weak self] in
                self?.pipeline?.setGate(false, discardHeld: false)
            }
        case .rewindThenOpenGate:
            // **順序は固定**（決めた事項 #4）: まず巻き戻し、その後で gate を開く。
            if let chrome, let tab {
                _ = try? chrome.execute(tab: tab, js: rewindJS)
            }
            ioQueue.async { [weak self] in
                self?.pipeline?.setGate(true, discardHeld: false)
            }
        case .warn(let message):
            onMessage(message)
        case .stop(let reason):
            _ = coordinator?.request(reason)
            return false
        }
        return true
    }

    // MARK: - 録音開始の手順（セッションキュー上。1 セッションに 1 回だけ）

    private func beginRecording(title: String?) {
        guard !isFinished, !recordingStarted else { return }
        recordingStarted = true

        // 1. 何を録るか。
        let target: TapTarget
        switch mode {
        case .system:
            target = .system
        case .app(let appTarget):
            target = appTarget
        case .url:
            // bundleIDs 単独で後から起動したプロセスを拾うか未確認なので、今見えている Chrome を seed に混ぜる。
            let seed = ((try? hal.processList()) ?? [])
                .filter { $0.bundle.hasPrefix(Chrome.bundleIDPrefix) }
                .map(\.id)
            target = .bundleIDs(Chrome.bundleIDs, seed: seed)
        }

        // 2. tap を開始する。`sink` は IO キュー上、`onEvent` は `TapRecorder` のイベントキュー上で呼ばれる。
        let recorder = TapRecorder(hal: hal,
                                   target: target,
                                   ioQueue: ioQueue,
                                   startTimeout: startTimeout,
                                   sink: { [weak self] buf in self?.ingest(buf) },
                                   onEvent: { [weak self] event in self?.handle(event) })
        self.recorder = recorder
        do {
            try recorder.start()
        } catch {
            fail(Self.recError(error, default: .coreAudio))
            return
        }

        // 3. format（以後この 1 つだけが流れる）。
        guard let format = recorder.format else {
            fail(RecError(code: .coreAudio, message: "tap の format を取得できませんでした"))
            return
        }

        // 4. 出力先を予約する（`O_EXCL` なので 0 バイトのファイルが残る）。
        let base = output.explicitBaseName
            ?? (title.flatMap(sanitizeFileName) ?? defaultBaseName(now: now()))
        let url: URL
        do {
            url = try reserveUniquePath(directory: output.directory, baseName: base, ext: output.ext)
        } catch {
            fail(Self.recError(error, default: .outputUnavailable))
            return
        }

        // 5. writer。作れなかったら**予約した 0 バイトのファイルを削除してから**失敗する。
        let writer: AudioFileWriting
        do {
            writer = try makeWriter(url, format)
        } catch {
            try? FileManager.default.removeItem(at: url)
            fail(Self.recError(error, default: .outputUnavailable))
            return
        }

        // 6. メータとパイプライン。遅延線は **url モードだけ** `adGuardSeconds`（他は 0）。
        let guardSeconds: Double
        switch mode {
        case .url:
            guardSeconds = adGuardSeconds
        case .system, .app:
            guardSeconds = 0
        }
        let meter = SilenceMeter(sampleRate: format.sampleRate)
        let pipeline = RecordingPipeline(format: format,
                                         writer: writer,
                                         guardSeconds: guardSeconds,
                                         meter: meter)

        // 7. 書き込みエラーは最初の 1 回だけ届く（`RecordingPipeline` の契約）。
        pipeline.onWriteError = { [weak self] _ in
            _ = self?.coordinator?.request(.writeFailed)
        }

        // 8. IO キューへ渡す（ここから `sink` が書き始める）。
        ioQueue.sync {
            self.pipeline = pipeline
            self.meter = meter
            if case .url = mode {
                // url モードは gate を閉じて始める（policy が同じ step の続きで開く）。
                pipeline.setGate(false, discardHeld: false)
            }
            // `.system` / `.app` は `RecordingPipeline` の既定どおり gate 開のまま。
        }
    }

    /// IO キュー上で呼ばれる（`TapRecorder` の `sink`）。
    private func ingest(_ buf: AVAudioPCMBuffer) {
        pipeline?.ingest(buf)
    }

    /// `TapRecorder` のイベントキュー上で呼ばれる。**停止要求に写すだけ**にする
    /// （`StopCoordinator` がセッションキューへ移してくれる）。
    private func handle(_ event: RecorderEvent) {
        switch event {
        case .defaultOutputChanged:
            _ = coordinator?.request(.deviceChanged)
        case .ioStoppedAbnormally:
            _ = coordinator?.request(.ioStopped)
        case .deviceDied:
            _ = coordinator?.request(.deviceDied)
        case .serviceRestarted:
            _ = coordinator?.request(.serviceRestarted)
        case .overload:
            // 記録用。これ自体は録音を止めない（決めた事項 #10 の最後の行）。
            onMessage(Messages.overload)
        }
    }

    // MARK: - 終了（セッションキュー上。冪等）

    /// 停止理由 1 本で後始末を通して `completion` を呼ぶ。**どの経路から来てもここに合流する**。
    private func finish(_ reason: StopReason) {
        // 1. 旗を立てる（`fail` と共有。2 回目以降は何もしない）。
        guard claimFinish() else { return }

        // 2. 監視をやめる（これ以降の停止要求は `StopCoordinator` が捨てる）。
        timer?.cancel()
        timer = nil
        signalWatcher?.cancel()
        powerWatcher?.stop()

        // 3. tap を止める。**IO キューの外から呼ぶ**（内部で `ioQueue.sync {}` するため）。
        recorder?.stop()

        var code = reason.exitCode

        // 4. パイプラインを締める（IO キュー上）。`finish()` は遅延線の flush と `writer.close()`。
        var framesWritten: AVAudioFramePosition = 0
        var audibleGateOpenWindows = 0
        var fileURL: URL?
        var closeError: Error?
        ioQueue.sync {
            guard let pipeline else { return }
            do {
                try pipeline.finish()
            } catch {
                closeError = error
            }
            framesWritten = pipeline.writer.framesWritten
            audibleGateOpenWindows = pipeline.meter.snapshot.audibleGateOpenWindows
            fileURL = pipeline.writer.url
        }
        if let closeError {
            // 閉じられなかった = 中身が保証できない。停止理由の code が 0 のときだけ上書きする。
            if code == .ok { code = .outputUnavailable }
            onMessage(Self.message(of: closeError))
        }

        // 5. 出力の始末（決めた事項 #7）。録音を開始していない（= ファイルが無い）ときは何もしない。
        if let fileURL {
            if framesWritten == 0 {
                // 1 フレームも書けなかった: 0 バイトのファイルを残さない。**code は変えない**。
                try? FileManager.default.removeItem(at: fileURL)
                onMessage(Messages.noData)
            } else if audibleGateOpenWindows == 0 {
                // 全編無音（許可が無い疑い）。ファイルは残す。
                onMessage(Messages.silent)
                // 優先順位（決めた事項 #3）: 停止理由の code が非ゼロならそれ。
                if code == .ok { code = .silent }
            }
        }

        // 6. ライブ配信の案内。
        if reason == .liveStream {
            onMessage(Messages.liveStream)
        }

        // 7. タブの後始末（決めた事項 #11）。**正常終了系のときだけ閉じる**
        //    （シグナル・エラー・中断では、ユーザーが見ているタブを勝手に閉じない）。
        switch reason {
        case .ended, .nextVideo, .liveStream:
            if let chrome, let tab {
                chrome.close(tab: tab)
            }
        case .permissionSuspected, .deviceChanged, .sleep, .serviceRestarted, .ioStopped,
             .deviceDied, .tapStalled, .tabClosed, .pageUnavailable, .pageUnresponsive,
             .writeFailed, .signal:
            break
        }

        // 8. ちょうど 1 回。
        completion(code)
    }

    /// 起動失敗の経路（セッションキュー上。冪等）。`finish` と同じ旗を共有する。
    ///
    /// タブは**閉じない**（開いたばかりのタブをユーザーに残す）。
    private func fail(_ error: RecError) {
        guard claimFinish() else { return }

        timer?.cancel()
        timer = nil
        signalWatcher?.cancel()
        powerWatcher?.stop()
        recorder?.stop()
        ioQueue.sync {
            try? pipeline?.finish()
        }

        onMessage(error.message)
        completion(error.code)
    }

    // MARK: - 補助

    /// 「終了済み」の旗を立てる。立てられたのが**最初の 1 回**のときだけ `true`。
    private func claimFinish() -> Bool {
        stateLock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    /// すでに後始末を通したか（poll と「録音開始の手順」の入口で見る）。
    private var isFinished: Bool { stateLock.withLock { finished } }

    /// 任意のエラーを `RecError` に畳む（すでに `RecError` ならそのまま）。
    private static func recError(_ error: Error, default code: ExitCode) -> RecError {
        if let recError = error as? RecError { return recError }
        return RecError(code: code, message: message(of: error))
    }

    /// 人に見せる 1 行。`RecError` は `message` をそのまま使う。
    private static func message(of error: Error) -> String {
        if let recError = error as? RecError { return recError.message }
        return "\(error)"
    }
}
