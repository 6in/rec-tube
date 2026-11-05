// AudioHAL.swift — tap / aggregate / IOProc / listener のライフサイクルを持つ Core Audio 呼び出しの境界。
//
// なぜ protocol にするか: `TapRecorder` の「作った物は必ず壊す」「途中で失敗したら逆順に壊す」という
// 契約は、実機の許可やデバイスに依存せずテストできなければならない（RESEARCH §5.1 AudioCap /
// OpenClaw AudioInputDeviceObserver）。`FakeHAL`（テスト側）が同じ protocol を実装して回数を数える。
//
// **断言（この protocol の契約）**: `create…` / `addListener` が成功して返した物は、`TapRecorder.stop()`
// までに対応する `destroy…` / `removeListener` が**ちょうど 1 回**呼ばれる。start の途中で失敗した場合も、
// そこまでに作った物だけが逆順にちょうど 1 回壊される。
//
// 追従先（PLAN「追従先チェックリスト」の「HAL 呼び出しを足す」行）: ここに create / destroy の対を
// 足したら `CoreAudioHAL`、`FakeHAL`、`TapRecorder` の teardown を同じターンで直す。
//
// HAL のプロパティ読み出し（`check` / `read` / `readIDs` / `audioProcesses`）と `CATapDescription` の
// 組み立て（`makeTapDescription`）は HAL.swift にある。ここはその上の「寿命を持つ資源」だけ。

import AVFoundation
import CoreAudio
import Foundation

/// IOProc が 1 ブロック配信するたびに呼ばれる。引数は入力側の `AudioBufferList`。
///
/// `AVAudioPCMBuffer` に包むのは `TapRecorder` の仕事（tap の format を 1 つに固定するため。
/// `AVAudioFile.write(from:)` は format が違うバッファを渡すと ObjC 例外で即クラッシュする）。
public typealias TapIOBlock = @Sendable (UnsafePointer<AudioBufferList>) -> Void

/// IOProc 1 件の控え。`AudioDeviceIOProcID`（C の関数ポインタ）を直接やり取りすると
/// `FakeHAL` が値を作れないので、実装が解除に必要なものを `payload` に入れる箱に包む。
///
/// `@unchecked Sendable`: 生成後は書き換えない。
public final class IOProcToken: @unchecked Sendable {
    /// 登録先のデバイス（aggregate）。
    public let device: AudioObjectID
    /// 実装が解除に使う箱。呼び出し側（`TapRecorder`）は中身を見ない。
    public let payload: Any?

    public init(device: AudioObjectID, payload: Any?) {
        self.device = device
        self.payload = payload
    }
}

/// プロパティリスナー 1 件の控え。解除に必要なものは実装側が `payload` に入れる。
///
/// `@unchecked Sendable`: `payload` は実装が入れた不変の値だけを持つ（`CoreAudioHAL` は登録した
/// block と queue、`FakeHAL` は handler）。生成後は誰も書き換えない。
public final class ListenerToken: @unchecked Sendable {
    public let objectID: AudioObjectID
    public let selector: AudioObjectPropertySelector
    /// 実装が解除に使う箱。呼び出し側（`TapRecorder`）は中身を見ない。
    public let payload: Any?

    public init(objectID: AudioObjectID, selector: AudioObjectPropertySelector, payload: Any?) {
        self.objectID = objectID
        self.selector = selector
        self.payload = payload
    }
}

/// Core Audio の「寿命を持つ資源」への入口。
///
/// `destroy…` / `removeListener` が throws しないのは、後始末の途中で失敗しても残りを必ず壊すため
/// （失敗したら実装側がログに落とす。呼び出し側は分岐しない）。
public protocol AudioHAL: AnyObject, Sendable {
    /// tap を作る。満たせない description では tap ID 0 が返るので、実装側で `.coreAudio` に変える。
    func createTap(_ description: CATapDescription) throws -> AudioObjectID
    func destroyTap(_ tapID: AudioObjectID)

    /// tap が配信する format（`kAudioTapPropertyFormat`）。
    func tapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat

    /// 既定の出力デバイス（決めた事項 #16: `DefaultOutputDevice`。`DefaultSystemOutputDevice` ではない）。
    func defaultOutputDevice() throws -> AudioObjectID
    func deviceUID(_ device: AudioObjectID) throws -> String

    /// aggregate デバイスを作る。辞書の組み立ては `TapRecorder` 側（方針なので HAL に置かない）。
    func createAggregate(description: [String: Any]) throws -> AudioObjectID
    func destroyAggregate(_ device: AudioObjectID)

    /// IOProc を登録する。`block` は `queue` 上で呼ばれる。
    func createIOProc(device: AudioObjectID,
                      queue: DispatchQueue,
                      block: @escaping TapIOBlock) throws -> IOProcToken
    func destroyIOProc(_ token: IOProcToken)

    func start(_ token: IOProcToken) throws
    func stop(_ token: IOProcToken)

    /// プロパティリスナーを張る。`handler` は `queue` 上で呼ばれ、引数を取らない
    /// （rec が見るのは「変わった」という事実だけで、新しい値はいらない）。
    func addListener(objectID: AudioObjectID,
                     selector: AudioObjectPropertySelector,
                     queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) throws -> ListenerToken
    func removeListener(_ token: ListenerToken)

    /// Core Audio に接続中のプロセス一覧（`--list` と `--app` の解決に使う）。
    func processList() throws -> [AudioProc]
}

// MARK: - 実機実装

/// 本物の Core Audio。状態を持たないので `Sendable`。
public final class CoreAudioHAL: AudioHAL {
    /// `removeListener` に必要な控え（登録した block と queue の両方が要る）。
    private struct Registration {
        let block: AudioObjectPropertyListenerBlock
        let queue: DispatchQueue
    }

    public init() {}

    public func createTap(_ description: CATapDescription) throws -> AudioObjectID {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")
        // catap の記録（RESEARCH §5.1）: description を満たせないときは成功のまま tap ID 0 が返る。
        guard tapID != AudioObjectID(kAudioObjectUnknown), tapID != 0 else {
            throw RecError(code: .coreAudio,
                           message: "tap を作れませんでした（tap ID 0: 指定した対象では tap を張れません）")
        }
        return tapID
    }

    public func destroyTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
    }

    public func tapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var asbd = try read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecError(code: .coreAudio, message: "tap の format を解釈できません")
        }
        return format
    }

    public func defaultOutputDevice() throws -> AudioObjectID {
        try RecCore.defaultOutputDevice()
    }

    public func deviceUID(_ device: AudioObjectID) throws -> String {
        try RecCore.deviceUID(device)
    }

    public func createAggregate(description: [String: Any]) throws -> AudioObjectID {
        var aggID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID),
                  "create aggregate device")
        return aggID
    }

    public func destroyAggregate(_ device: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(device)
    }

    public func createIOProc(device: AudioObjectID,
                             queue: DispatchQueue,
                             block: @escaping TapIOBlock) throws -> IOProcToken {
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, _, _, _ in
            block(input)
        }, "create IOProc")
        guard let procID else {
            throw RecError(code: .coreAudio, message: "IOProc を作れませんでした")
        }
        return IOProcToken(device: device, payload: procID)
    }

    public func destroyIOProc(_ token: IOProcToken) {
        guard let procID = token.payload as? AudioDeviceIOProcID else { return }
        AudioDeviceDestroyIOProcID(token.device, procID)
    }

    public func start(_ token: IOProcToken) throws {
        guard let procID = token.payload as? AudioDeviceIOProcID else {
            throw RecError(code: .coreAudio, message: "IOProc の控えが壊れています")
        }
        try check(AudioDeviceStart(token.device, procID), "start device")
    }

    public func stop(_ token: IOProcToken) {
        guard let procID = token.payload as? AudioDeviceIOProcID else { return }
        AudioDeviceStop(token.device, procID)
    }

    public func addListener(objectID: AudioObjectID,
                            selector: AudioObjectPropertySelector,
                            queue: DispatchQueue,
                            handler: @escaping @Sendable () -> Void) throws -> ListenerToken {
        var addr = address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, block),
                  "add listener \(selector)")
        return ListenerToken(objectID: objectID,
                             selector: selector,
                             payload: Registration(block: block, queue: queue))
    }

    public func removeListener(_ token: ListenerToken) {
        guard let registration = token.payload as? Registration else { return }
        var addr = address(token.selector)
        AudioObjectRemovePropertyListenerBlock(token.objectID, &addr,
                                               registration.queue, registration.block)
    }

    public func processList() throws -> [AudioProc] {
        try audioProcesses()
    }
}
