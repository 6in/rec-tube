// HAL.swift — Core Audio HAL への薄い入口と、tap の作り方（`TapTarget`）。
//
// T2 で Legacy.swift から切り出した。ここは「HAL のプロパティを読む」「`CATapDescription` を組む」
// までで、tap / aggregate / IOProc のライフサイクルは T5 の `TapRecorder` が持つ。
//
// 追従先（PLAN「追従先チェックリスト」）: HAL 呼び出しを足したら `AudioHAL` protocol（T5）、
// `CoreAudioHAL`、`FakeHAL`、`TapRecorder.stop()` の destroy / remove を対で直す。

import AVFoundation
import CoreAudio
import Foundation

// MARK: - プロパティ読み出し

/// `OSStatus` を `RecError` に変える。`noErr` 以外は全部エラー。
public func check(_ st: OSStatus, _ what: String) throws {
    if st != noErr { throw RecError(description: "\(what) failed (OSStatus \(st))") }
}

/// グローバルスコープ・メイン要素のアドレス（rec が使うのはこの形だけ）。
public func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

/// 固定サイズのプロパティを 1 つ読む。`initial` は型の決定と既定値の両方を兼ねる。
public func read<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var addr = address(sel)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try withUnsafeMutablePointer(to: &value) { p in
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, p), "get property \(sel)")
    }
    return value
}

/// 可変長の `AudioObjectID` 配列プロパティを読む（プロセス一覧・デバイス一覧）。
public func readIDs(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    var addr = address(sel)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "get size \(sel)")
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard !ids.isEmpty else { return [] }
    try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids), "get property \(sel)")
    return ids
}

// MARK: - プロセス一覧

public struct AudioProc: Sendable, Equatable {
    public let id: AudioObjectID
    public let bundle: String
    public let running: Bool

    public init(id: AudioObjectID, bundle: String, running: Bool) {
        self.id = id
        self.bundle = bundle
        self.running = running
    }
}

/// Core Audio に接続している全クライアントプロセス。
///
/// `kAudioProcessPropertyIsRunningOutput` の listener は発火しない報告があるので（RESEARCH §2.2）、
/// `running` は「今この瞬間の値」としてポーリングで使う。
public func audioProcesses() throws -> [AudioProc] {
    try readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map {
        let bundle = ((try? read($0, kAudioProcessPropertyBundleID, "" as CFString)) as String?) ?? ""
        let running = ((try? read($0, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0
        return AudioProc(id: $0, bundle: bundle, running: running)
    }
}

/// 既定の出力デバイス。aggregate の主サブデバイスに使う（決めた事項 #16 / RESEARCH §2.2:
/// `DefaultSystemOutputDevice` は警告音用で、アプリの音は `DefaultOutputDevice` に出る）。
public func defaultOutputDevice() throws -> AudioObjectID {
    try read(AudioObjectID(kAudioObjectSystemObject),
             kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
}

public func deviceUID(_ device: AudioObjectID) throws -> String {
    try read(device, kAudioDevicePropertyDeviceUID, "" as CFString) as String
}

// MARK: - Chrome のバンドル ID

public enum Chrome {
    /// `--app` 既定値と、プロセス一覧の絞り込みに使う前方一致。
    public static let bundleIDPrefix = "com.google.Chrome"

    /// `TapTarget.bundleIDs` に渡す名前（T2 (0) の実測で絞る）。
    public static let bundleIDs = [
        "com.google.Chrome",
        "com.google.Chrome.helper",
    ]
}

// MARK: - tap の作り方

/// tap が何を録るか。`makeTapDescription` がこれを `CATapDescription` に落とす。
public enum TapTarget: Sendable, Equatable {
    /// システム全体（除外なしのグローバル tap）。
    case system
    /// 指定したプロセスオブジェクトだけ（従来方式。開始時点の列挙で固定される）。
    case processes([AudioObjectID])
    /// バンドル ID で指定（macOS 26+）。`seed` は作成時点で分かっているプロセス
    /// （bundleIDs 単独で後から起動したプロセスを拾うか未確認なので、保険として混ぜられる）。
    case bundleIDs([String], seed: [AudioObjectID])
}

/// `TapTarget` から `CATapDescription` を組む。
///
/// - `uuid` は毎回新規（aggregate の `kAudioSubTapUIDKey` と対応させる）
/// - `isPrivate` = true で他プロセスから見えないようにする
/// - `muteBehavior` = `.unmuted`（録りながら本人も聞ける）
/// - `.processes` / `.bundleIDs` は `isProcessRestoreEnabled = true`
///   （対象プロセスが落ちて再起動したら tap に戻す。RESEARCH §2.1 / L1）
public func makeTapDescription(_ target: TapTarget) -> CATapDescription {
    let desc: CATapDescription
    switch target {
    case .system:
        desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    case .processes(let ids):
        desc = CATapDescription(stereoMixdownOfProcesses: ids)
    case .bundleIDs(let ids, let seed):
        desc = CATapDescription(stereoMixdownOfProcesses: seed)
        desc.bundleIDs = ids
    }
    desc.uuid = UUID()
    desc.name = "rec-tap"
    desc.isPrivate = true
    desc.muteBehavior = .unmuted
    switch target {
    case .system:
        break
    case .processes, .bundleIDs:
        desc.isProcessRestoreEnabled = true
    }
    return desc
}
