// TapRecorder.swift — tap / aggregate / IOProc / listener の寿命を 1 箇所に閉じ込める。
//
// 移行元は単一ファイル版の `Recorder`（`git show main:rec.swift`。+ `rec-probe` の `ProbeTap` / `makeProbeTap`）。
// 違いは 3 つ: (1) Core Audio 呼び出しを `AudioHAL` 越しにしてテストできるようにした、
// (2) 中断の 5 種を `RecorderEvent` としてリスナーから配る、(3) 後始末の関数を 1 本にした。
//
// **断言（この型の契約）**:
//   - `start()` は**有限時間で必ず戻る**。許可が降りていないと `AudioDeviceCreateIOProcIDWithBlock` が
//     ダイアログも出さずに無期限ブロックする実測（PLAN T2 turn 4）があるので、本体は別キューで走らせて
//     `DispatchSemaphore.wait(timeout:)` で打ち切る。時間切れは `.coreAudio` + `Messages.systemAudioPermission`
//   - `create` 系に対応する `destroy` / `remove` が `stop()` までに**ちょうど 1 回ずつ**呼ばれる
//     （多くても 1 回、少なくても 1 回）。`start()` の途中で失敗しても、そこまでに作った物だけが逆順に 1 回
//   - 後始末の順は**常に**「listener を登録の逆順に解除 → 開始済みなら `hal.stop` → `ioQueue.sync {}` →
//     `destroyIOProc` → `destroyAggregate` → `destroyTap`」。成功後の `stop()` も、途中失敗の巻き戻しも、
//     打ち切り後の遅れた後始末も、すべて `destroy(_:)` の 1 本を通る
//   - `stop()` は冪等で、複数スレッドから同時に呼んでも各 destroy はちょうど 1 回
//   - `sink` には `start()` で確定した**1 つの `format`** のバッファだけを渡す
//     （`AVAudioFile.write(from:)` は format が違うバッファで ObjC 例外を投げ、Swift では catch できない）
//
// 追従先（PLAN「追従先チェックリスト」の「HAL 呼び出しを足す」行）: `AudioHAL` に create / destroy の対を
// 足したら、`Progress`（控え）と `destroy(_:)`（逆順の破棄）を同じターンで直す。

import AVFoundation
import CoreAudio
import Foundation

// MARK: - 中断の種類

/// 録音中に外から降ってくる出来事。`onEvent` で配る。
///
/// 対応する `StopReason` は呼び出し側（T6 の `StopCoordinator`）が決める。ここは「何が起きたか」だけ。
/// `.overload` は記録用で、これ自体は録音を止めない（PLAN T5）。
public enum RecorderEvent: Sendable, Equatable {
    case defaultOutputChanged, ioStoppedAbnormally, deviceDied, serviceRestarted, overload
}

// MARK: - 非 Sendable な値の持ち込み箱

/// 非 Sendable な値を `@Sendable` クロージャ（IOProc の block / listener の handler）に持ち込む箱。
///
/// `sink` / `onEvent` には `@Sendable` を付けない（テストが任意のクロージャを渡せるようにする）ので、
/// そのままでは Swift 6 の Sendable 検査を通らない。`AVAudioFormat` も Sendable ではない。
/// 中身は生成後に書き換えないので `@unchecked Sendable` で安全。
private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// `start()` 1 回ぶんの結果の受け渡し箱（作成キューが書き、`start()` の呼び出し元が読む）。
///
/// `TapRecorder` の可変状態にしないのは、打ち切ったあとに遅れて戻ってくる作成スレッドが、
/// 次の `start()` の結果を上書きしないようにするため（箱は呼び出しごとに新しく作る）。
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func put(_ value: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        result = value
    }

    func take() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

// MARK: - TapRecorder

/// tap を作って IOProc を回し、バッファを `sink` に、中断を `onEvent` に流す。
///
/// `@unchecked Sendable`: 可変状態は `lock`（控えと旗）か `ioQueue`（IOProc の中）でだけ触る規約。
public final class TapRecorder: @unchecked Sendable {
    // MARK: 控え

    /// `start()` の各段で作った物の控え。
    ///
    /// `tapID` / `aggID` / `ioProc` / `listeners` / `started` は**破棄が要る**物で、後始末のときに
    /// まとめて取り出して空にする。`format` / `outputDevice` は破棄の要らない記録なので残す
    /// （`format` は `start()` 後も読めなければならない）。
    private struct Progress {
        var tapID: AudioObjectID?
        var aggID: AudioObjectID?
        var ioProc: IOProcToken?
        var listeners: [ListenerToken] = []
        var started = false
        var format: AVAudioFormat?
        var outputDevice: AudioObjectID?

        /// 破棄が要る物だけを取り出して空にする。取り出した側だけが破棄する
        /// （「取り出し」と「破棄」が同時に起きないので、destroy はちょうど 1 回になる）。
        mutating func takeDestroyables() -> Progress {
            var taken = Progress()
            taken.tapID = tapID
            taken.aggID = aggID
            taken.ioProc = ioProc
            taken.listeners = listeners
            taken.started = started
            tapID = nil
            aggID = nil
            ioProc = nil
            listeners = []
            started = false
            return taken
        }

        /// 1 つも持っていないか（空なら `destroy` は何もしない）。
        var isEmpty: Bool {
            tapID == nil && aggID == nil && ioProc == nil && listeners.isEmpty
        }
    }

    // MARK: 不変

    private let hal: AudioHAL
    private let target: TapTarget
    /// IOProc の block が呼ばれるキュー（呼び出し側が渡す `rec.io`）。
    private let ioQueue: DispatchQueue
    private let startTimeout: Double

    /// `onEvent` を呼ぶ直列キュー。listener は全部このキューに載せるので、5 種が混ざらない。
    private let eventQueue = DispatchQueue(label: "rec.recorder.events")
    /// 後始末を直列化するキュー。`stop()` はここで `sync` する。
    private let stopQueue = DispatchQueue(label: "rec.stop")

    /// `@Sendable` な IOProc の block / listener の handler から呼ぶための箱。
    private let sink: Unchecked<(AVAudioPCMBuffer) -> Void>
    private let onEvent: Unchecked<(RecorderEvent) -> Void>

    // MARK: `lock` 下でだけ触る可変状態

    /// 控えと旗を守る（`NSLock`。`Synchronization.Mutex` は値型の制約が強いので使わない）。
    private let lock = NSLock()
    private var progress = Progress()
    /// 「もう捨てる」旗。打ち切り（時間切れ）と `stop()` が立てる。
    /// 作成スレッドは各段のあとでこれを見て、自分で後始末して打ち切る。
    private var discarding = false

    // MARK: 初期化

    /// - Parameters:
    ///   - hal: Core Audio への入口（テストは `FakeHAL`）
    ///   - target: 何を録るか
    ///   - ioQueue: IOProc の block を呼ぶキュー
    ///   - startTimeout: `start()` を打ち切るまでの秒数
    ///   - sink: 1 ブロックごとのバッファ。`ioQueue` 上で呼ばれる。format は常に `self.format`
    ///   - onEvent: 中断の 5 種。`rec.recorder.events` 上で呼ばれる
    public init(hal: AudioHAL,
                target: TapTarget,
                ioQueue: DispatchQueue,
                startTimeout: Double = Tuning.tapStartTimeoutSeconds,
                sink: @escaping (AVAudioPCMBuffer) -> Void,
                onEvent: @escaping (RecorderEvent) -> Void) {
        self.hal = hal
        self.target = target
        self.ioQueue = ioQueue
        self.startTimeout = startTimeout
        self.sink = Unchecked(sink)
        self.onEvent = Unchecked(onEvent)
    }

    deinit {
        // `stop()` を呼び忘れても資源は壊れる（PLAN T5 の完了基準）。
        stop()
    }

    /// `start()` が成功したあとの tap の format。IOProc が渡すバッファは常にこの format。
    public var format: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return progress.format
    }

    // MARK: - start

    /// tap → format → 出力デバイス → aggregate → IOProc → listener 5 本 → 開始、の順で組み立てる。
    ///
    /// 本体は別キューで走らせ、`startTimeout` 秒で打ち切って必ず戻る。打ち切りのときは
    /// 「捨てる旗」を立てるだけで、破棄は資源の持ち主（作成スレッド）に任せる。作成スレッドは
    /// ブロックから戻ったところで旗に気づき、それまでに作った物を**逆順に 1 回**破棄して終わる。
    public func start() throws {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        // 作成キュー: 直列キューにすると打ち切り後の再試行が詰まるので global を使う（`makeProbeTap` と同じ）。
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try build()
                box.put(.success(()))
            } catch {
                box.put(.failure(error))
            }
            done.signal()
        }

        guard done.wait(timeout: .now() + startTimeout) == .success else {
            // 打ち切り。**ここでは破棄しない**（旗だけ立てる）。
            //
            // 理由: 作成スレッドはまだ Core Audio の呼び出しの中にいる。その最中に、同じ呼び出しが
            // 相手にしている aggregate / tap をこちらから壊すのは安全ではない。資源の持ち主は
            // 作成スレッドなので、ブロックから戻ったときに `record` が旗を見て**自分で逆順に**破棄する。
            // 戻って来ない場合（許可が無いときの `AudioDeviceCreateIOProcIDWithBlock` が実測でこれ）は
            // 後始末をプロセス終了に任せる（PLAN T5。`exit` する側で問題にしない）。
            requestDiscard()
            throw RecError(code: .coreAudio,
                           message: "tap の作成・開始が \(Int(startTimeout)) 秒で戻りませんでした"
                               + "（システム音声の取得の許可が降りていない可能性があります）。\n"
                               + Messages.systemAudioPermission)
        }

        if case .failure(let error) = box.take() {
            throw error
        }
    }

    /// 作成キューの中身。どの段で throw しても、それまでに作った物を逆順にちょうど 1 回破棄してから投げる。
    private func build() throws {
        do {
            // (1) `CATapDescription` は非 Sendable なので、このキューの中で組む（外から持ち込まない）。
            let desc = makeTapDescription(target)

            // (2) tap
            let tapID = try hal.createTap(desc)
            try record { $0.tapID = tapID }

            // (3) format（ここで 1 つに確定させ、以後 sink には必ずこの format のバッファだけを渡す）
            let format = try hal.tapFormat(tapID)
            try record { $0.format = format }

            // (4) 既定の出力デバイス（決めた事項 #16: `DefaultOutputDevice`）
            let outputDevice = try hal.defaultOutputDevice()
            try record { $0.outputDevice = outputDevice }
            let outputUID = try hal.deviceUID(outputDevice)

            // (5) aggregate（`ProbeTap` と同じ辞書。`TapAutoStart` は false:
            //     true だと `AudioDeviceStart` が対象が音を出すまで戻らない）
            let aggID = try hal.createAggregate(description: [
                kAudioAggregateDeviceNameKey: "rec-aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                ]],
            ])
            try record { $0.aggID = aggID }

            // (6) IOProc。block は確定済みの format と sink だけを捕まえる（`[weak self]` にしない:
            //     format が 1 つであることを型の上でも担保するため）。
            let context = Unchecked((format: format, sink: sink.value))
            let token = try hal.createIOProc(device: aggID, queue: ioQueue) { input in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: context.value.format,
                                                    bufferListNoCopy: input,
                                                    deallocator: nil)
                else { return }
                context.value.sink(buffer)
            }
            try record { $0.ioProc = token }

            // (7) listener 5 本（この順で登録し、後始末では逆順に解除する）
            let events = onEvent
            let system = AudioObjectID(kAudioObjectSystemObject)
            let listeners: [(AudioObjectID, AudioObjectPropertySelector, RecorderEvent)] = [
                (system, kAudioHardwarePropertyDefaultOutputDevice, .defaultOutputChanged),
                (system, kAudioHardwarePropertyServiceRestarted, .serviceRestarted),
                (aggID, kAudioDevicePropertyIOStoppedAbnormally, .ioStoppedAbnormally),
                (outputDevice, kAudioDevicePropertyDeviceIsAlive, .deviceDied),
                (aggID, kAudioDeviceProcessorOverload, .overload),
            ]
            for (objectID, selector, event) in listeners {
                let listenerToken = try hal.addListener(objectID: objectID,
                                                       selector: selector,
                                                       queue: eventQueue) {
                    events.value(event)
                }
                try record { $0.listeners.append(listenerToken) }
            }

            // (8) 開始
            try hal.start(token)
            try record { $0.started = true }
        } catch {
            // 打ち切り（`record` が投げる）以外の失敗。ここまでに作った物を逆順に 1 回破棄する。
            // 旗は立てない（この `TapRecorder` を使えなくするのは呼び出し側の判断）。
            teardown()
            throw error
        }
    }

    /// 1 段ぶんの控えを記録する。「捨てる旗」が立っていたら、その場で後始末して打ち切る。
    ///
    /// 記録と旗の確認を同じロックで行うので、「記録した直後に旗が立って、誰も破棄しない」隙間がない
    /// （旗を立てた側が先に取り出していれば旗はもう true なので、ここで気づいて自分の分を破棄する）。
    private func record(_ mutate: (inout Progress) -> Void) throws {
        lock.lock()
        mutate(&progress)
        let aborting = discarding
        lock.unlock()
        guard aborting else { return }
        teardown()
        throw RecError(code: .coreAudio,
                       message: "録音の開始中に停止が要求されたので、作成した資源を破棄しました")
    }

    // MARK: - stop / 後始末

    /// 録音を止めて、作った物を逆順にちょうど 1 回破棄する。冪等で、複数スレッドから同時に呼んでもよい。
    public func stop() {
        discardAll()
    }

    /// 「捨てる旗」だけを立てる（`start()` の打ち切り用）。
    ///
    /// 破棄しないのは、まだ Core Audio の呼び出しの中にいる作成スレッドが資源の持ち主だから。
    /// 作成スレッドは次の `record` で旗に気づき、自分で逆順に破棄する。
    private func requestDiscard() {
        lock.lock()
        discarding = true
        lock.unlock()
    }

    /// 「捨てる旗」を立てて、いま控えている物を後始末する（`stop()` / `deinit` から呼ぶ）。
    private func discardAll() {
        stopQueue.sync {
            lock.lock()
            discarding = true
            let taken = progress.takeDestroyables()
            lock.unlock()
            // 破棄はロックの外（`ioQueue.sync {}` をロック保持中に走らせない）。
            destroy(taken)
        }
    }

    /// 旗を立てずに後始末する（`start()` の途中失敗の巻き戻し）。
    private func teardown() {
        stopQueue.sync {
            lock.lock()
            let taken = progress.takeDestroyables()
            lock.unlock()
            destroy(taken)
        }
    }

    /// 控えを逆順に破棄する。**後始末の実体はこの 1 本だけ**（部分的に作られた状態でも同じ関数が働く）。
    ///
    /// 順: listener を登録の逆順に解除 → 開始済みなら `hal.stop` → `ioQueue.sync {}`（配信中の block を
    /// 出し切る）→ `destroyIOProc` → `destroyAggregate` → `destroyTap`。
    ///
    /// `ioQueue.sync {}` は IOProc を作ったときだけ（作っていないならキューに何も載っていない）。
    /// この関数を `ioQueue` 上から呼ぶと `sync` で止まるので、`sink` の中から `stop()` を呼ばないこと。
    private func destroy(_ taken: Progress) {
        guard !taken.isEmpty else { return }
        for token in taken.listeners.reversed() {
            hal.removeListener(token)
        }
        if let ioProc = taken.ioProc {
            if taken.started {
                hal.stop(ioProc)
            }
            ioQueue.sync {}
            hal.destroyIOProc(ioProc)
        }
        if let aggID = taken.aggID {
            hal.destroyAggregate(aggID)
        }
        if let tapID = taken.tapID {
            hal.destroyTap(tapID)
        }
    }
}
