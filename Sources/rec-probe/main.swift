// rec-probe — tap の作り方（`bundleIDs` / `processes` / `isProcessRestoreEnabled`）を実機で確かめる道具。
//
// `rec` のサブコマンドにはしない（手動実行の道具。PLAN T2）。ここで測った結果が
// PLAN「決めた事項」#2 の `chromeTapTarget` を確定させる。
//
// 使い方:
//   rec-probe list
//       Core Audio に接続中の全プロセスを `running` 付きで表示する。
//       Chrome で音を鳴らしながら実行して「running になるバンドル ID の実名」を記録する（T2 (0)）。
//
//   rec-probe tap <system|processes|bundleids|hybrid> <秒数> [--prefix com.google.Chrome] [--bundle-id ID]... [--autostart]
//       tap を作って指定秒だけ回し、1 秒ごとに rms dBFS と allZero を表示する。ファイルは書かない。
//         system     … グローバル tap（除外なし）
//         processes  … prefix 一致プロセスの PID 列挙（従来方式）
//         bundleids  … bundleIDs のみ（seed なし）
//         hybrid     … bundleIDs + prefix 一致プロセスを seed
//       `--autostart` は `kAudioAggregateDeviceTapAutoStartKey` を立てる（既定は false。
//       true だと `AudioDeviceStart` が対象が音を出すまで戻らず、無音のときは無期限に止まる）。
//       作成・開始は 10 秒で打ち切る（許可ダイアログ待ちで固まらないため）。
//       終了コード: 0 = 一度でも非ゼロのサンプルが来た / 4 = 全編ゼロ（許可なしか対象が無音）/
//                   8 = tap・aggregate・IOProc の作成失敗・時間切れ / 1 = 引数不正
//
//   rec-probe tones <dir>
//       `<dir>` に `main.wav`（440 Hz・12 秒）と `ad.wav`（1 kHz・4 秒）を書く。
//       `Tests/Fixtures/adtest.html` が参照する素材で、`scripts/verify-adtest.sh` が最初に呼ぶ。
//       `<dir>` が無ければ作る。生成したパスを 1 行ずつ stdout に出す。
//       終了コード: 0 = 書けた / 8 = 作れない・書けない / 1 = 引数不正
//
//   rec-probe analyze <wav|m4a> [--main 440] [--ad 1000] [--expect-main 秒] [--silence]
//       録音結果のトーン判定（Goertzel）。既定は本編 440 Hz / 広告 1000 Hz。
//         既定（--silence なし） … `ToneVerdict` を JSON 1 行で stdout に出す
//                                  （adWindows / mainSeconds / silentSeconds / totalSeconds）。
//                                  `--expect-main 秒` があれば **adWindows == 0 かつ
//                                  |mainSeconds - 秒| < 1.0** のときだけ exit 0、他は exit 1。
//                                  `--expect-main` が無ければ JSON を出して exit 0（判定しない）。
//         --silence              … 全ゼロ判定だけを行う（他のオプションは無視）。
//                                  全ゼロなら stdout に出して exit 1、非ゼロなら exit 0。
//       終了コード: 0 = 期待どおり / 1 = 期待と不一致・全ゼロ・引数不正・ファイルが読めない

import AVFoundation
import CoreAudio
import Foundation
import RecCore

// パイプの読み手が先に閉じても `print` で死なない（E14）。出力の失敗は黙って捨てる。
// **トップレベルの先頭**で張る。
_ = signal(SIGPIPE, SIG_IGN)

// MARK: - 出力

/// 人向けの行は `RecCore.writeStderr`（fd 2 への `write(2)` ループ）だけを通す。
/// `FileHandle.standardError` の `write(_:)` は fd 2 が閉じていると SIGABRT になるので使わない（E13）。
func fail(_ message: String, _ code: Int32) -> Never {
    writeStderr("rec-probe: \(message)")
    exit(code)
}

/// 進行の目印。どの Core Audio 呼び出しで止まったかを時間切れの後からでも読めるようにする
/// （stdout はパイプ越しにバッファされるので stderr に即書きする）。
func step(_ message: String) {
    writeStderr("rec-probe: step \(message)")
}

let usage = """
usage:
  rec-probe list
  rec-probe tap <system|processes|bundleids|hybrid> <seconds> [--prefix <bundle-id-prefix>] [--bundle-id <id>]... [--autostart]
  rec-probe tones <dir>
  rec-probe analyze <file> [--main <Hz>] [--ad <Hz>] [--expect-main <seconds>] [--silence]
"""

/// dBFS = 20·log10(max(rms, 1e-8))（決めた事項 #6 と同じ式）。
func dBFS(_ rms: Double) -> Double {
    20.0 * log10(max(rms, 1e-8))
}

// MARK: - 1 秒ごとのメータ

/// IOProc が書き、メインスレッドが `snapshot()` で読む集計。
/// `@unchecked Sendable`: 可変状態は `queue` 上でだけ触る規約（HAL.swift / 単一ファイル版と同じ）。
final class Meter: @unchecked Sendable {
    struct Snapshot {
        var frames: Int
        var rms: Double
        var allZero: Bool
    }

    private let queue: DispatchQueue
    private var samples = 0
    private var sumSquares = 0.0
    private var nonZero = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// IOProc から呼ぶ（`queue` 上）。
    func add(_ list: UnsafePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count {
                let v = Double(floats[i])
                sumSquares += v * v
                if v != 0 { nonZero += 1 }
            }
            samples += count
        }
    }

    /// 直近の集計を取り出して 0 に戻す（メインスレッドから）。
    func snapshot() -> Snapshot {
        queue.sync {
            let s = Snapshot(frames: samples,
                             rms: samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0,
                             allZero: nonZero == 0)
            samples = 0
            sumSquares = 0
            nonZero = 0
            return s
        }
    }
}

// MARK: - tap + aggregate + IOProc

/// 単一ファイル版の `Recorder`（`git show main:rec.swift`）から「ファイルに書く」部分を抜いたもの。
/// T5 の `TapRecorder` の下敷き。
///
/// 作成の途中で失敗したら、作った分だけを逆順で壊してから throw する（RESEARCH §5.1 AudioCap）。
final class ProbeTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "rec-probe.io")
    private var stopped = false
    let meter: Meter
    let format: AVAudioFormat

    /// `autoStart`: `kAudioAggregateDeviceTapAutoStartKey`。
    ///
    /// **true にすると `AudioDeviceStart` が「tap 対象プロセスが音を受け取り始めるまで」戻らない**
    /// （RESEARCH §2.1 の原文どおり）。対象が無音のときは無期限に止まるので、プローブの既定は false。
    /// T5 の `TapRecorder` も false 側（自前で開始を待つ）にする。
    init(target: TapTarget, autoStart: Bool) throws {
        meter = Meter(queue: queue)

        let desc = makeTapDescription(target)
        step("AudioHardwareCreateProcessTap")
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")
        step("tap created: \(tapID)")
        // catap の記録: 満たせない description では tap ID 0 が返る（RESEARCH §5.1）。
        guard tapID != AudioObjectID(kAudioObjectUnknown), tapID != 0 else {
            throw RecError(code: .coreAudio, message: "create tap returned tap ID 0 (description を満たせない)")
        }

        var asbd: AudioStreamBasicDescription
        do {
            asbd = try read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RecError(code: .coreAudio, message: "unsupported tap format")
        }
        format = fmt

        step("tap format: \(Int(fmt.sampleRate))Hz/\(fmt.channelCount)ch")
        do {
            let outUID = try deviceUID(try defaultOutputDevice())
            step("AudioHardwareCreateAggregateDevice (main \(outUID))")
            let aggDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "rec-probe-aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: autoStart,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID),
                      "create aggregate device")
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        step("aggregate created: \(aggID)")
        do {
            let meter = self.meter
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, input, _, _, _ in
                meter.add(input)
            }, "create IOProc")
            step("AudioDeviceStart")
            try check(AudioDeviceStart(aggID, procID), "start device")
            step("started")
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        AudioDeviceStop(aggID, procID)
        queue.sync {}
        if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// MARK: - サブコマンド

func runList() {
    let procs: [AudioProc]
    do {
        procs = try audioProcesses()
    } catch {
        fail("プロセス一覧を取得できません: \(error)", 8)
    }
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    print("\(pad("id", 8)) \(pad("running", 8)) bundleID")
    for p in procs.sorted(by: { ($0.bundle, $0.id) < ($1.bundle, $1.id) }) {
        let bundle = p.bundle.isEmpty ? "(none)" : p.bundle
        print("\(pad("\(p.id)", 8)) \(pad(p.running ? "yes" : "no", 8)) \(bundle)")
    }
    let running = procs.filter(\.running).map(\.bundle).filter { !$0.isEmpty }.sorted()
    print("running: \(running.isEmpty ? "(none)" : running.joined(separator: ", "))")
}

struct TapOptions {
    var variant = ""
    var seconds = 3
    var prefix = Chrome.bundleIDPrefix
    var bundleIDs: [String] = []
    var autoStart = false
}

/// `ProbeTap` の作成を別キューで行い、`timeout` 秒で諦める。
///
/// `AudioHardwareCreateProcessTap` も `AudioDeviceStart`（autostart 時）も無期限に止まりうるので、
/// 無人ターンから回せるよう必ず有限時間で戻す。時間切れのときは作成スレッドを残したまま exit する。
func makeProbeTap(target: TapTarget, autoStart: Bool, timeout: Double) -> ProbeTap {
    let box = Mutex<Result<ProbeTap, Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        let result: Result<ProbeTap, Error>
        do {
            result = .success(try ProbeTap(target: target, autoStart: autoStart))
        } catch {
            result = .failure(error)
        }
        box.withLock { $0 = result }
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else {
        fail("tap の作成・開始が \(Int(timeout)) 秒で戻らなかった"
            + (autoStart ? "（autostart は対象が音を出すまで戻らない）"
                         : "（システム音声の取得の許可ダイアログ待ちの可能性）"), 8)
    }
    switch box.withLock({ $0 })! {
    case .success(let tap):
        return tap
    case .failure(let error):
        fail("tap を作れません: \(error)", 8)
    }
}

/// 最小の排他箱（`Synchronization.Mutex` を使わずに Swift 6 の Sendable 検査を通すため）。
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

func parseTapOptions(_ args: [String]) -> TapOptions {
    var o = TapOptions()
    guard args.count >= 2 else { fail(usage, 1) }
    o.variant = args[0]
    guard ["system", "processes", "bundleids", "hybrid"].contains(o.variant) else {
        fail("未知の variant: \(o.variant)\n\(usage)", 1)
    }
    guard let seconds = Int(args[1]), seconds > 0, seconds <= 600 else {
        fail("秒数は 1〜600 の整数で指定してください: \(args[1])", 1)
    }
    o.seconds = seconds

    var i = 2
    while i < args.count {
        switch args[i] {
        case "--prefix":
            guard i + 1 < args.count else { fail("--prefix に値がありません", 1) }
            o.prefix = args[i + 1]
            i += 2
        case "--bundle-id":
            guard i + 1 < args.count else { fail("--bundle-id に値がありません", 1) }
            o.bundleIDs.append(args[i + 1])
            i += 2
        case "--autostart":
            o.autoStart = true
            i += 1
        default:
            fail("未知のオプション: \(args[i])\n\(usage)", 1)
        }
    }
    if o.bundleIDs.isEmpty {
        o.bundleIDs = o.prefix == Chrome.bundleIDPrefix ? Chrome.bundleIDs : [o.prefix]
    }
    return o
}

func runTap(_ args: [String]) {
    let o = parseTapOptions(args)

    let procs = (try? audioProcesses()) ?? []
    let matched = procs.filter { $0.bundle.hasPrefix(o.prefix) }
    let seed = matched.map(\.id)
    print("prefix \"\(o.prefix)\" に一致: \(matched.count) 件 "
        + "(running \(matched.filter(\.running).count) 件) "
        + "\(matched.map { "\($0.bundle)#\($0.id)\($0.running ? "*" : "")" }.joined(separator: " "))")

    let target: TapTarget
    switch o.variant {
    case "system":
        target = .system
    case "processes":
        if seed.isEmpty { print("警告: 一致プロセスが 0 件。processes tap は何も拾わない") }
        target = .processes(seed)
    case "bundleids":
        target = .bundleIDs(o.bundleIDs, seed: [])
    default:
        target = .bundleIDs(o.bundleIDs, seed: seed)
    }
    print("variant=\(o.variant) bundleIDs=\(o.bundleIDs) seed=\(o.variant == "bundleids" ? [] : seed)")

    print("autostart=\(o.autoStart)")
    let tap = makeProbeTap(target: target, autoStart: o.autoStart, timeout: 10)
    print("tap format: \(Int(tap.format.sampleRate))Hz/\(tap.format.channelCount)ch "
        + "\(tap.format.commonFormat == .pcmFormatFloat32 ? "float32" : "other")")

    var everNonZero = false
    var allZeroSeconds = 0
    var totalFrames = 0
    var totalSumSquares = 0.0
    for t in 1...o.seconds {
        Thread.sleep(forTimeInterval: 1.0)
        let s = tap.meter.snapshot()
        if !s.allZero { everNonZero = true }
        if s.allZero { allZeroSeconds += 1 }
        totalFrames += s.frames
        totalSumSquares += s.rms * s.rms * Double(s.frames)
        print("t=\(t)s frames=\(s.frames) "
            + String(format: "rms=%.1f dBFS", dBFS(s.rms))
            + " allZero=\(s.allZero)")
    }
    tap.stop()

    let overall = totalFrames > 0 ? (totalSumSquares / Double(totalFrames)).squareRoot() : 0
    print("result variant=\(o.variant) seconds=\(o.seconds) frames=\(totalFrames) "
        + String(format: "overallRMS=%.1f dBFS", dBFS(overall))
        + " everNonZero=\(everNonZero) allZeroSeconds=\(allZeroSeconds)")
    if totalFrames == 0 {
        fail("IOProc が 1 フレームも配信しなかった（aggregate か tap が動いていない）", 8)
    }
    exit(everNonZero ? 0 : 4)
}

/// `Tests/Fixtures/adtest.html` が参照する 2 本のトーンを書く。
///
/// 本編 440 Hz・12 秒 / 広告 1 kHz・4 秒（PLAN「決めた事項」#12 の adtest.html と対になる値）。
func runTones(_ args: [String]) {
    guard args.count == 1 else { fail(usage, 1) }
    let dir = URL(fileURLWithPath: args[0], isDirectory: true)
    let mainURL = dir.appendingPathComponent("main.wav")
    let adURL = dir.appendingPathComponent("ad.wav")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeTone(url: mainURL, hz: 440, seconds: 12)
        try writeTone(url: adURL, hz: 1000, seconds: 4)
    } catch {
        fail("トーンを書けません（\(dir.path)）: \(error)", 8)
    }
    print(mainURL.path)
    print(adURL.path)
}

struct AnalyzeOptions {
    var path = ""
    var mainHz = 440.0
    var adHz = 1000.0
    var expectMain: Double?
    var silence = false
}

func parseAnalyzeOptions(_ args: [String]) -> AnalyzeOptions {
    var o = AnalyzeOptions()
    guard let path = args.first else { fail(usage, 1) }
    o.path = path

    /// `--main` / `--ad` / `--expect-main` の値を読む（読めなければ exit 1）。
    func number(_ args: [String], _ i: Int, _ flag: String) -> Double {
        guard i + 1 < args.count else { fail("\(flag) に値がありません", 1) }
        guard let value = Double(args[i + 1]) else {
            fail("\(flag) は数値で指定してください: \(args[i + 1])", 1)
        }
        return value
    }

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--main":
            o.mainHz = number(args, i, "--main")
            i += 2
        case "--ad":
            o.adHz = number(args, i, "--ad")
            i += 2
        case "--expect-main":
            o.expectMain = number(args, i, "--expect-main")
            i += 2
        case "--silence":
            o.silence = true
            i += 1
        default:
            fail("未知のオプション: \(args[i])\n\(usage)", 1)
        }
    }
    return o
}

func runAnalyze(_ args: [String]) {
    let o = parseAnalyzeOptions(args)
    let url = URL(fileURLWithPath: o.path)

    // `--silence` は他のオプションと併用されても全ゼロ判定だけを行う。
    if o.silence {
        let zero: Bool
        do {
            zero = try isAllZero(url: url)
        } catch {
            fail("読めません（\(url.path)）: \(error)", 1)
        }
        if zero {
            print("全ゼロ: \(url.path)")
            exit(1)
        }
        exit(0)
    }

    let verdict: ToneVerdict
    do {
        verdict = try analyze(url: url, mainHz: o.mainHz, adHz: o.adHz)
    } catch {
        fail("解析できません（\(url.path)）: \(error)", 1)
    }

    // 4 キーのアルファベット順 = adWindows / mainSeconds / silentSeconds / totalSeconds。
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(verdict),
          let line = String(data: data, encoding: .utf8)
    else {
        fail("verdict を JSON にできません", 1)
    }
    print(line)

    // `--expect-main` が無いときは判定しない。
    guard let expect = o.expectMain else { exit(0) }
    guard verdict.adWindows == 0, abs(verdict.mainSeconds - expect) < 1.0 else {
        fail("期待と不一致（adWindows=\(verdict.adWindows) "
            + String(format: "mainSeconds=%.2f expect-main=%.2f", verdict.mainSeconds, expect)
            + "。合格は adWindows == 0 かつ差 < 1.0 秒）", 1)
    }
    exit(0)
}

// MARK: - エントリ

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    print(usage)
    exit(1)
}
switch command {
case "list":
    runList()
case "tap":
    runTap(Array(argv.dropFirst()))
case "tones":
    runTones(Array(argv.dropFirst()))
case "analyze":
    runAnalyze(Array(argv.dropFirst()))
case "-h", "--help", "help":
    print(usage)
default:
    fail("未知のサブコマンド: \(command)\n\(usage)", 1)
}
