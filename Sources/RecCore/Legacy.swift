// Legacy.swift — 単一ファイル版（移動元は `git show main:rec.swift`）から移した暫定コード。
//
// T3〜T9 で RecCore の各型（ExitCode / TapRecorder / ChromeController / SessionPolicy …）に
// 置き換えて、このファイルは消える。Swift 6 言語モードのエラーは、このファイル内だけ
// `nonisolated(unsafe)` / `@unchecked Sendable` で黙らせている（言語モードは落とさない）。
//
// usage（T9 で CLI.swift の usage 文字列に移す）:
//   rec --url 'https://www.youtube.com/watch?v=XXXX'   # Chromeで開いて本編だけ録音、終了で自動停止
//   rec                          # システム全体の音を録音（Ctrl-C で停止）
//   rec --app com.google.Chrome  # バンドルID前方一致のプロセスだけ録音
//   rec --list                   # 音声を扱っているプロセス一覧
//   -o out.m4a                   # 出力先（既定: rec-日時.m4a）
//
// --url には Chrome の「表示 > 開発/管理 > Apple Events からの JavaScript を許可」が必要。

import AVFoundation
import CoreAudio
import Foundation

// `check` / `address` / `read` / `readIDs` / `AudioProc` / `audioProcesses()` は T2 で HAL.swift に移した。
// `RecError` は T3 で ExitCode.swift に移した（`description` → `code` + `message`）。

// MARK: - Recorder

/// `@unchecked Sendable`: 可変状態（`writing` / `file`）は `queue` 上でだけ触る規約。
/// T5 の `TapRecorder` で、この規約をリスナー対応つきで作り直す。
public final class Recorder: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "rec.io")
    private var writing: Bool
    private var stopped = false
    public let format: AVAudioFormat

    /// targets == nil ならシステム全体
    public init(targets: [AudioObjectID]?, path: String, writing: Bool = true) throws {
        self.writing = writing
        let desc = targets.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "rec-tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")

        var asbd = try read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw RecError(code: .coreAudio, message: "unsupported tap format")
        }
        format = fmt

        let outDev = try read(AudioObjectID(kAudioObjectSystemObject),
                              kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
        let outUID = try read(outDev, kAudioDevicePropertyDeviceUID, "" as CFString) as String
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "rec-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "create aggregate device")

        file = try AVAudioFile(forWriting: URL(fileURLWithPath: path),
                               settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                          AVSampleRateKey: fmt.sampleRate,
                                          AVNumberOfChannelsKey: fmt.channelCount,
                                          AVEncoderBitRateKey: 192_000],
                               commonFormat: fmt.commonFormat,
                               interleaved: fmt.isInterleaved)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [unowned self] _, input, _, _, _ in
            guard self.writing,
                  let buf = AVAudioPCMBuffer(pcmFormat: self.format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            try? self.file?.write(from: buf)
        }, "create IOProc")
        try check(AudioDeviceStart(aggID, procID), "start device")
    }

    public func setWriting(_ on: Bool) { queue.async { self.writing = on } }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        AudioDeviceStop(aggID, procID)
        queue.sync {}
        if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
        file = nil // flush & close
    }
}

// MARK: - Chrome control (AppleScript)

@discardableResult
func osa(_ script: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if msg.contains("turned off") || msg.contains("オフ") {
            print("\nChrome の「Apple Events からの JavaScript を許可」をオンにしてください。")
            exit(1)
        }
        return nil
    }
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func chromeOpen(_ url: String) -> String? {
    let u = url.replacingOccurrences(of: "\"", with: "%22")
    return osa("""
    tell application "Google Chrome"
      activate
      set w to make new window
      set URL of active tab of w to "\(u)"
      return (id of active tab of w) as text
    end tell
    """)
}

@discardableResult
func chromeTab(_ tabID: String, _ body: String) -> String? {
    osa("""
    tell application "Google Chrome"
      repeat with w in windows
        repeat with t in tabs of w
          if (id of t as text) is "\(tabID)" then
            \(body)
          end if
        end repeat
      end repeat
      return "gone"
    end tell
    """)
}

// 状態: "<ad|main> <ended|paused|playing> <videoId> <currentTime> <duration>" / "none"
let probeJS = """
(function(){var v=document.querySelector('video');if(!v)return 'none';\
var ad=!!document.querySelector('.ad-showing');\
if(v.paused&&!v.ended){var p=v.play();if(p)p.catch(function(){});}\
var id=new URLSearchParams(location.search).get('v')||'-';\
return (ad?'ad':'main')+' '+(v.ended?'ended':(v.paused?'paused':'playing'))+' '+id+' '\
+v.currentTime.toFixed(1)+' '+(isFinite(v.duration)?v.duration.toFixed(1):'0');})()
"""

@discardableResult
func chromeJS(_ tabID: String, _ js: String) -> String? {
    chromeTab(tabID, "return execute t javascript \"\(js)\"")
}

// MARK: - modes

public func recordURL(_ url: String, path: String) throws {
    guard let tab = chromeOpen(url) else {
        throw RecError(code: .chromeUnavailable, message: "Chrome を開けませんでした")
    }
    print("Chrome で開きました。再生待ち…")

    // Chrome の音声プロセスが出力を始めるまで待つ
    let prefix = "com.google.Chrome"
    var targets: [AudioObjectID] = []
    let deadline = Date().addingTimeInterval(60)
    while targets.isEmpty {
        guard Date() < deadline else {
            throw RecError(code: .pageLost, message: "60秒待っても音が出ませんでした")
        }
        _ = chromeJS(tab, probeJS)
        Thread.sleep(forTimeInterval: 0.5)
        if try audioProcesses().contains(where: { $0.bundle.hasPrefix(prefix) && $0.running }) {
            targets = try audioProcesses().filter { $0.bundle.hasPrefix(prefix) }.map(\.id)
        }
    }

    let rec = try Recorder(targets: targets, path: path, writing: false)
    installSigint { rec.stop(); print("\n中断: \(path)") }

    // 本編が既に流れていたら頭出し（取りこぼし防止）
    if let s = chromeJS(tab, probeJS), s.hasPrefix("main") {
        chromeJS(tab, "(function(){var v=document.querySelector('video');if(v)v.currentTime=0;return 'ok';})()")
    }

    var videoID: String?
    var lastWriting = false
    loop: while true {
        Thread.sleep(forTimeInterval: 0.3)
        guard let s = chromeJS(tab, probeJS) else { continue }
        if s == "gone" { print("\nタブが閉じられました"); break }
        let f = s.split(separator: " ").map(String.init)
        guard f.count == 5 else { continue }
        let (kind, state, vid, cur, dur) = (f[0], f[1], f[2], f[3], f[4])

        if kind == "main" {
            if videoID == nil { videoID = vid }
            if vid != videoID { print("\n次の動画に遷移したので停止"); break loop }
            if state == "ended" { print("\n再生終了"); break loop }
        }
        let w = kind == "main" && state == "playing"
        if w != lastWriting { rec.setWriting(w); lastWriting = w }
        let label = kind == "ad" ? "広告(スキップ)" : (w ? "録音中" : "待機")
        print("\r\(label) \(cur)/\(dur)s   ", terminator: "")
        fflush(stdout)
    }

    rec.stop()
    chromeTab(tab, "close t\nreturn \"ok\"")
    print("保存しました: \(path)")
}

public func recordLive(targets: [AudioObjectID]?, path: String) throws -> Never {
    let rec = try Recorder(targets: targets, path: path)
    print("録音中: \(path)  (\(Int(rec.format.sampleRate))Hz/\(rec.format.channelCount)ch)  Ctrl-C で停止")
    installSigint { rec.stop(); print("\n保存しました: \(path)") }
    dispatchMain()
}

nonisolated(unsafe) var sigSource: DispatchSourceSignal?

public func installSigint(_ handler: @escaping @Sendable () -> Void) {
    signal(SIGINT, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    s.setEventHandler { handler(); exit(0) }
    s.resume()
    sigSource = s
}
