// FakeHAL — テスト用の `AudioHAL`。`TapRecorder` の「作った物は必ず 1 回だけ壊す」を数で確かめる。
//
// 方針:
//   - **呼び出しを順番に記録する**（`log`）。逆順破棄や「listener を先に外す」の検証は添字の比較で行う。
//   - **任意のステージで失敗・ブロックできる**（`failAt` / `blockAt`）。start の途中失敗と
//     watchdog（許可が降りていないと `createIOProc` が無期限ブロックする、T2 turn 4 の実測）の再現用。
//   - **本物のロックを持つ**。`stop()` を 10 スレッドから同時に呼ぶテストがあるので、
//     FakeWriter（単一スレッド前提）と違ってここは NSLock で守る。
//
// 設定用のプロパティ（`failAt` / `blockAt` / `tapFormatValue` / `processes`）は `start()` を呼ぶ前に
// 設定する前提（それ自体はロックで守らない）。記録の読み出しと刺激（`fire` / `emit`）はいつでも安全。

import AVFoundation
import CoreAudio
import Foundation

@testable import RecCore

final class FakeHAL: AudioHAL, @unchecked Sendable {
    /// `start()` の各段。`failAt` / `blockAt` で指定する。
    enum Stage: String, Sendable, CaseIterable {
        case tap, format, defaultDevice, deviceUID, aggregate, ioproc, listener, start
    }

    // MARK: - 設定（start の前に入れる）

    /// このステージで `RecError(code: .coreAudio, message: "fake failure: <stage>")` を throw する。
    var failAt: Stage?
    /// このステージで `unblock()` が呼ばれるまで戻らない。
    var blockAt: Stage?
    /// `failAt == .listener` のとき、何本目（0 始まり）の `addListener` で失敗するか。
    var failListenerIndex = 0
    /// `tapFormat` が返す format。
    var tapFormatValue = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    /// `processList()` が返す一覧。
    var processes: [AudioProc] = []
    /// `createTap` が返す ID。
    var tapIDValue = AudioObjectID(101)
    /// `createAggregate` が返す ID。
    var aggregateIDValue = AudioObjectID(201)
    /// `defaultOutputDevice` が返す ID。
    var outputDeviceIDValue = AudioObjectID(301)
    /// `deviceUID` が返す文字列。
    var deviceUIDValue = "FakeOutput-UID"

    // MARK: - 記録

    private let lock = NSLock()
    private var ops: [String] = []
    private var added: [AudioObjectPropertySelector] = []
    private var removed: [AudioObjectPropertySelector] = []
    private var listeners: [ObjectIdentifier: (selector: AudioObjectPropertySelector,
                                               queue: DispatchQueue,
                                               handler: @Sendable () -> Void)] = [:]
    private var ioBlock: TapIOBlock?
    private var ioQueue: DispatchQueue?
    private var aggregateDescriptions: [[String: Any]] = []
    private let gate = DispatchSemaphore(value: 0)

    /// 呼ばれた順の一覧（`"createTap"`, `"addListener"`, `"destroyTap"` …）。
    var log: [String] { lock.withLock { ops } }
    /// `log` のうち `op` の件数。
    func count(_ op: String) -> Int { lock.withLock { ops.filter { $0 == op }.count } }
    /// `log` の中で `op` が最初に現れた位置（無ければ nil）。
    func firstIndex(of op: String) -> Int? { lock.withLock { ops.firstIndex(of: op) } }
    /// 登録された listener の selector（登録順）。
    var addedListenerSelectors: [AudioObjectPropertySelector] { lock.withLock { added } }
    /// 解除された listener の selector（解除順）。
    var removedListenerSelectors: [AudioObjectPropertySelector] { lock.withLock { removed } }
    /// まだ張られている listener の件数。
    var liveListenerCount: Int { lock.withLock { listeners.count } }
    /// IOProc の block が登録されているか。
    var hasIOBlock: Bool { lock.withLock { ioBlock != nil } }
    /// `createAggregate` に渡された辞書（最後のもの）。
    var lastAggregateDescription: [String: Any]? { lock.withLock { aggregateDescriptions.last } }

    // MARK: - テストからの刺激

    /// `blockAt` で止めたステージを進ませる。
    func unblock() { gate.signal() }

    /// 指定 selector の listener を全部呼ぶ。戻り値は呼んだ件数。
    @discardableResult
    func fire(_ selector: AudioObjectPropertySelector) -> Int {
        let targets = lock.withLock {
            listeners.values.filter { $0.selector == selector }
        }
        for target in targets {
            target.queue.sync { target.handler() }
        }
        return targets.count
    }

    /// IOProc の block を 1 回呼ぶ（登録されたキュー上で同期的に）。
    /// 戻り値は呼べたかどうか。
    @discardableResult
    func emit(_ buf: AVAudioPCMBuffer) -> Bool {
        let (block, queue) = lock.withLock { (ioBlock, ioQueue) }
        guard let block, let queue else { return false }
        queue.sync { block(buf.audioBufferList) }
        return true
    }

    // MARK: - 内部

    private func record(_ op: String) { lock.withLock { ops.append(op) } }

    /// ステージの入口で共通に呼ぶ。ブロック指定なら待ち、失敗指定なら throw する。
    private func enter(_ stage: Stage) throws {
        if blockAt == stage { gate.wait() }
        if failAt == stage {
            throw RecError(code: .coreAudio, message: "fake failure: \(stage.rawValue)")
        }
    }

    // MARK: - AudioHAL

    func createTap(_ description: CATapDescription) throws -> AudioObjectID {
        try enter(.tap)
        record("createTap")
        return tapIDValue
    }

    func destroyTap(_ tapID: AudioObjectID) {
        record("destroyTap")
    }

    func tapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        try enter(.format)
        record("tapFormat")
        return tapFormatValue
    }

    func defaultOutputDevice() throws -> AudioObjectID {
        try enter(.defaultDevice)
        record("defaultOutputDevice")
        return outputDeviceIDValue
    }

    func deviceUID(_ device: AudioObjectID) throws -> String {
        try enter(.deviceUID)
        record("deviceUID")
        return deviceUIDValue
    }

    func createAggregate(description: [String: Any]) throws -> AudioObjectID {
        try enter(.aggregate)
        lock.withLock {
            ops.append("createAggregate")
            aggregateDescriptions.append(description)
        }
        return aggregateIDValue
    }

    func destroyAggregate(_ device: AudioObjectID) {
        record("destroyAggregate")
    }

    func createIOProc(device: AudioObjectID,
                      queue: DispatchQueue,
                      block: @escaping TapIOBlock) throws -> IOProcToken {
        try enter(.ioproc)
        lock.withLock {
            ops.append("createIOProc")
            ioBlock = block
            ioQueue = queue
        }
        return IOProcToken(device: device, payload: "fake-ioproc")
    }

    func destroyIOProc(_ token: IOProcToken) {
        lock.withLock {
            ops.append("destroyIOProc")
            ioBlock = nil
            ioQueue = nil
        }
    }

    func start(_ token: IOProcToken) throws {
        try enter(.start)
        record("start")
    }

    func stop(_ token: IOProcToken) {
        record("stop")
    }

    func addListener(objectID: AudioObjectID,
                     selector: AudioObjectPropertySelector,
                     queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) throws -> ListenerToken {
        if blockAt == .listener { gate.wait() }
        if failAt == .listener, lock.withLock({ added.count }) == failListenerIndex {
            throw RecError(code: .coreAudio, message: "fake failure: listener")
        }
        let token = ListenerToken(objectID: objectID, selector: selector, payload: nil)
        lock.withLock {
            ops.append("addListener")
            added.append(selector)
            listeners[ObjectIdentifier(token)] = (selector, queue, handler)
        }
        return token
    }

    func removeListener(_ token: ListenerToken) {
        lock.withLock {
            ops.append("removeListener")
            removed.append(token.selector)
            listeners[ObjectIdentifier(token)] = nil
        }
    }

    func processList() throws -> [AudioProc] {
        record("processList")
        return processes
    }
}
