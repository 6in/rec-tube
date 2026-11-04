// TapRecorder のユニットテスト。
//
// **`Sources/RecCore/TapRecorder.swift` は読まずに、PLAN T5 の契約だけから書いた**
// （仕様と実装の食い違いを検出するための構成）。Core Audio には触らない（`FakeHAL` が全部受ける）。
//
// 確かめる契約（PLAN T5「ユニット（P3, L2, L5）」）:
//   1. start → stop で create / destroy、addListener / removeListener の回数が一致し、format が確定する
//   2. start のどの段で throw しても、それまでに作った物**だけ**が逆順にちょうど 1 回壊れる
//   3. 破棄の順は removeListener（登録の逆順）→ stop → destroyIOProc → destroyAggregate → destroyTap
//   4. `stop()` は冪等（10 スレッドから同時に呼んでも各 destroy は 1 回）
//   5. `deinit` だけでも壊れる
//   6. listener は 5 本で、`fire` 5 種が `onEvent` に 1 回ずつ届く
//   7. watchdog: 無期限ブロックでも `start()` は有限時間で `.coreAudio` を throw し、作った物は壊れる
//   8. `sink` に渡るのは `start()` で確定した 1 つの format のバッファだけ
//   9. aggregate の辞書は `kAudioAggregateDeviceTapAutoStartKey` が false
//
// 書き方の約束:
//   - **破棄の順序は「log を破棄系だけに絞った列」と期待列の比較**で見る（回数と順序を 1 つの断言で見られる）
//   - `onEvent` / `sink` は IO キュー・listener キューから呼ばれるので、受け取り側は NSLock で守った箱に貯める
//   - 別スレッドの後始末を待つ場所だけ `waitUntil`（最大 2 秒のポーリング）を使う。それ以外は同期で済む

import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import RecCore

@Suite("TapRecorder", .serialized)
struct TapRecorderTests {
    // MARK: - 期待値の表

    /// `start()` の 1 段で失敗させたときに「壊れているべき物の数」。
    ///
    /// （`@Test(arguments:)` に渡すので `Sendable`。tuple ではなく struct にしているのは
    /// key path（`\.stage`）が tuple 要素には使えないため。）
    struct Teardown: Sendable {
        /// 失敗させる段。
        let stage: FakeHAL.Stage
        /// `failAt == .listener` のとき、何本目（0 始まり）で失敗させるか。
        let failListenerIndex: Int
        /// 期待する `removeListener` の回数。
        let removeListener: Int
        /// 期待する HAL `stop`（`AudioDeviceStop`）の回数。
        let stop: Int
        let destroyIOProc: Int
        let destroyAggregate: Int
        let destroyTap: Int
    }

    /// 6 段 + listener を途中（4 本目）で失敗させる変種。
    ///
    /// 読み方: `.format` で失敗した時点で作ってあるのは tap だけなので `destroyTap` 1 回・
    /// `destroyAggregate` 0 回。`defaultOutputDevice` / `deviceUID` / `tapFormat` は資源を作らないので、
    /// `.aggregate` で失敗しても壊すのは tap だけ。
    static let teardownCases: [Teardown] = [
        // tap すら無い → 何も壊さない。
        Teardown(stage: .tap, failListenerIndex: 0,
                 removeListener: 0, stop: 0, destroyIOProc: 0, destroyAggregate: 0, destroyTap: 0),
        // tap だけある。
        Teardown(stage: .format, failListenerIndex: 0,
                 removeListener: 0, stop: 0, destroyIOProc: 0, destroyAggregate: 0, destroyTap: 1),
        Teardown(stage: .aggregate, failListenerIndex: 0,
                 removeListener: 0, stop: 0, destroyIOProc: 0, destroyAggregate: 0, destroyTap: 1),
        // tap + aggregate。
        Teardown(stage: .ioproc, failListenerIndex: 0,
                 removeListener: 0, stop: 0, destroyIOProc: 0, destroyAggregate: 1, destroyTap: 1),
        // tap + aggregate + IOProc（listener は 1 本目で失敗するので 0 本）。
        Teardown(stage: .listener, failListenerIndex: 0,
                 removeListener: 0, stop: 0, destroyIOProc: 1, destroyAggregate: 1, destroyTap: 1),
        // 同じ段を 4 本目で失敗させる → 張れた 3 本だけが外れる。
        Teardown(stage: .listener, failListenerIndex: 3,
                 removeListener: 3, stop: 0, destroyIOProc: 1, destroyAggregate: 1, destroyTap: 1),
        // listener 5 本まで張れて `AudioDeviceStart` で失敗 → 開始していないので HAL `stop` は呼ばない。
        Teardown(stage: .start, failListenerIndex: 0,
                 removeListener: 5, stop: 0, destroyIOProc: 1, destroyAggregate: 1, destroyTap: 1),
    ]

    /// `fire(selector)` → `onEvent` の対応 1 件。
    struct EventCase: Sendable {
        let selector: AudioObjectPropertySelector
        let event: RecorderEvent
    }

    /// `fire(selector)` → `onEvent` の対応表（契約の 5 本）。
    ///
    /// 定数は SDK 上すでに `AudioObjectPropertySelector` 型だが、明示変換を挟んでおけば
    /// 別の整数型で import されても通る。
    static let eventMap: [EventCase] = [
        EventCase(selector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
                  event: .defaultOutputChanged),
        EventCase(selector: AudioObjectPropertySelector(kAudioHardwarePropertyServiceRestarted),
                  event: .serviceRestarted),
        EventCase(selector: AudioObjectPropertySelector(kAudioDevicePropertyIOStoppedAbnormally),
                  event: .ioStoppedAbnormally),
        EventCase(selector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsAlive),
                  event: .deviceDied),
        EventCase(selector: AudioObjectPropertySelector(kAudioDeviceProcessorOverload),
                  event: .overload),
    ]

    /// 破棄系の op（`log` をこれだけに絞って期待列と比べる）。
    private static let teardownOps: Set<String> = [
        "removeListener", "stop", "destroyIOProc", "destroyAggregate", "destroyTap",
    ]

    // MARK: - 受け取り箱（別キューから呼ばれるのでロックで守る）

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RecorderEvent] = []

        var all: [RecorderEvent] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
        func append(_ event: RecorderEvent) { lock.withLock { items.append(event) } }
    }

    /// `sink` に届いたバッファの「format と長さ」だけを控える。
    ///
    /// バッファ自体は持たない: IOProc の `AudioBufferList` を包んだバッファは block を抜けると
    /// 中身が無効になる（`bufferListNoCopy`）。
    private final class SinkBox: @unchecked Sendable {
        /// 届いたバッファの控え（struct にしているのは key path を使うため）。
        struct Received {
            let format: AVAudioFormat
            let frames: AVAudioFrameCount
        }

        private let lock = NSLock()
        private var items: [Received] = []

        var all: [Received] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock { items.append(Received(format: buffer.format, frames: buffer.frameLength)) }
        }
    }

    // MARK: - helpers

    /// `TapRecorder` を揃えて作る（`start()` はしない）。
    ///
    /// closure を `@Sendable` で宣言しておく: 実装側の init が非 `@Sendable` でも受け取れる。
    private func makeRecorder(hal: FakeHAL,
                              startTimeout: Double = Tuning.tapStartTimeoutSeconds,
                              sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void = { _ in },
                              onEvent: @escaping @Sendable (RecorderEvent) -> Void = { _ in })
        -> TapRecorder {
        TapRecorder(hal: hal,
                    target: .system,
                    ioQueue: DispatchQueue(label: "test.rec.io"),
                    startTimeout: startTimeout,
                    sink: sink,
                    onEvent: onEvent)
    }

    /// `log` を破棄系だけに絞った列。
    private func teardownSequence(_ hal: FakeHAL) -> [String] {
        hal.log.filter { Self.teardownOps.contains($0) }
    }

    /// `condition` が true になるまで最大 `timeout` 秒待つ（別スレッドの後始末を待つ場所だけで使う）。
    private func waitUntil(timeout: Double = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// `body` が `RecError(code: .coreAudio, ...)` を throw することを確かめる。
    private func expectCoreAudioError(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("throw されませんでした（RecError(.coreAudio) を期待）")
        } catch let error as RecError {
            #expect(error.code == .coreAudio, "RecError.code が .coreAudio ではありません: \(error)")
        } catch {
            Issue.record("RecError 以外が throw されました: \(error)")
        }
    }

    // MARK: - 1. start → stop の対応

    @Test("start() → stop() で create と destroy、addListener と removeListener の回数が一致する")
    func startThenStopBalancesEveryResource() throws {
        let hal = FakeHAL()
        let recorder = makeRecorder(hal: hal)

        #expect(recorder.format == nil, "start() 前の format は nil のはず")

        try recorder.start()

        // 作ったもの: tap 1・aggregate 1・IOProc 1・listener 5、そして AudioDeviceStart 1。
        #expect(hal.count("createTap") == 1)
        #expect(hal.count("createAggregate") == 1)
        #expect(hal.count("createIOProc") == 1)
        #expect(hal.count("addListener") == 5, "listener は 5 本: \(hal.log)")
        #expect(hal.count("start") == 1)
        #expect(hal.liveListenerCount == 5)
        #expect(hal.hasIOBlock)

        // format は start() で確定し、tap の format と一致する。
        let format = try #require(recorder.format, "start() 後の format が nil")
        #expect(format == hal.tapFormatValue)

        recorder.stop()

        // 壊したもの: 作った数とちょうど同じ。
        #expect(hal.count("destroyTap") == 1)
        #expect(hal.count("destroyAggregate") == 1)
        #expect(hal.count("destroyIOProc") == 1)
        #expect(hal.count("removeListener") == 5)
        #expect(hal.count("stop") == 1)
        #expect(hal.liveListenerCount == 0)
        #expect(hal.hasIOBlock == false)

        // stop() 後も format は start() で確定した値のまま（sink に渡した format と同じ）。
        #expect(recorder.format == hal.tapFormatValue)
    }

    // MARK: - 2. start の各段で失敗したときの後始末

    @Test("start() のどの段で throw しても、それまでに作った物だけが逆順にちょうど 1 回壊れる",
          arguments: TapRecorderTests.teardownCases)
    func teardownOnStageFailure(expected: Teardown) throws {
        let hal = FakeHAL()
        hal.failAt = expected.stage
        hal.failListenerIndex = expected.failListenerIndex
        let recorder = makeRecorder(hal: hal)

        expectCoreAudioError { try recorder.start() }

        // 回数（契約の「ちょうど 1 回ずつ」）。
        #expect(hal.count("destroyTap") == expected.destroyTap,
                "destroyTap: \(hal.log)")
        #expect(hal.count("destroyAggregate") == expected.destroyAggregate,
                "destroyAggregate: \(hal.log)")
        #expect(hal.count("destroyIOProc") == expected.destroyIOProc,
                "destroyIOProc: \(hal.log)")
        #expect(hal.count("removeListener") == expected.removeListener,
                "removeListener: \(hal.log)")
        #expect(hal.count("stop") == expected.stop,
                "HAL stop: \(hal.log)")

        // 順序（removeListener → stop → destroyIOProc → destroyAggregate → destroyTap）。
        var wanted = [String](repeating: "removeListener", count: expected.removeListener)
        if expected.stop == 1 { wanted.append("stop") }
        if expected.destroyIOProc == 1 { wanted.append("destroyIOProc") }
        if expected.destroyAggregate == 1 { wanted.append("destroyAggregate") }
        if expected.destroyTap == 1 { wanted.append("destroyTap") }
        #expect(teardownSequence(hal) == wanted, "破棄の順序が違います: \(hal.log)")

        // 外し損ねた listener が残っていない。
        #expect(hal.liveListenerCount == 0)
        #expect(hal.hasIOBlock == false)

        // 失敗後に stop() を呼んでも二重に壊さない。
        recorder.stop()
        #expect(teardownSequence(hal) == wanted, "stop() が二重に壊しています: \(hal.log)")
    }

    // MARK: - 3. 破棄は逆順

    @Test("stop() の破棄は逆順（removeListener → stop → destroyIOProc → destroyAggregate → destroyTap）")
    func teardownRunsInReverseOrder() throws {
        let hal = FakeHAL()
        let recorder = makeRecorder(hal: hal)
        try recorder.start()
        recorder.stop()

        let log = hal.log
        let lastRemoveListener = try #require(log.lastIndex(of: "removeListener"), "removeListener なし: \(log)")
        let halStop = try #require(log.firstIndex(of: "stop"), "stop なし: \(log)")
        let destroyIOProc = try #require(log.firstIndex(of: "destroyIOProc"), "destroyIOProc なし: \(log)")
        let destroyAggregate = try #require(log.firstIndex(of: "destroyAggregate"),
                                            "destroyAggregate なし: \(log)")
        let destroyTap = try #require(log.firstIndex(of: "destroyTap"), "destroyTap なし: \(log)")

        #expect(lastRemoveListener < halStop, "listener 解除より先に stop しています: \(log)")
        #expect(halStop < destroyIOProc, "stop より先に IOProc を壊しています: \(log)")
        #expect(destroyIOProc < destroyAggregate, "IOProc より先に aggregate を壊しています: \(log)")
        #expect(destroyAggregate < destroyTap, "aggregate より先に tap を壊しています: \(log)")

        // listener は登録の逆順で外す。
        let added = hal.addedListenerSelectors
        let removed = hal.removedListenerSelectors
        #expect(removed == Array(added.reversed()),
                "解除順が登録の逆順ではありません（登録 \(added) / 解除 \(removed)）")
    }

    // MARK: - 4. stop() の冪等性

    @Test("stop() を 10 スレッドから同時に呼んでも各 destroy はちょうど 1 回")
    func concurrentStopIsIdempotent() throws {
        let hal = FakeHAL()
        let recorder = makeRecorder(hal: hal)
        try recorder.start()

        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            recorder.stop()
        }

        #expect(hal.count("destroyTap") == 1, "destroyTap: \(hal.log)")
        #expect(hal.count("destroyAggregate") == 1, "destroyAggregate: \(hal.log)")
        #expect(hal.count("destroyIOProc") == 1, "destroyIOProc: \(hal.log)")
        #expect(hal.count("stop") == 1, "HAL stop: \(hal.log)")
        #expect(hal.count("removeListener") == 5, "removeListener: \(hal.log)")
        #expect(hal.liveListenerCount == 0)
    }

    // MARK: - 5. deinit だけで壊れる

    @Test("stop() を呼ばず deinit だけでも全部壊れる")
    func deinitReleasesEverything() throws {
        // FakeHAL は recorder より長く持つ（破棄の記録を後から読むため）。
        let hal = FakeHAL()
        do {
            var recorder: TapRecorder? = makeRecorder(hal: hal)
            try #require(recorder).start()
            #expect(hal.count("createTap") == 1)
            #expect(hal.count("destroyTap") == 0, "まだ壊れていないはず: \(hal.log)")
            // 最後の参照を落とす = deinit。
            recorder = nil
        }

        let destroyed = waitUntil { hal.count("destroyTap") == 1 }
        #expect(destroyed, "deinit で destroyTap が呼ばれていません: \(hal.log)")
        #expect(hal.count("destroyAggregate") == 1, "destroyAggregate: \(hal.log)")
        #expect(hal.count("destroyIOProc") == 1, "destroyIOProc: \(hal.log)")
        #expect(hal.count("removeListener") == 5, "removeListener: \(hal.log)")
        #expect(hal.count("stop") == 1, "HAL stop: \(hal.log)")
        #expect(hal.liveListenerCount == 0)
        #expect(hal.hasIOBlock == false)
    }

    // MARK: - 6. listener → onEvent

    @Test("listener は 5 本張られ、fire 5 種がそれぞれ onEvent に 1 回ずつ届く")
    func listenerSelectorsMapToEvents() throws {
        let hal = FakeHAL()
        let events = EventBox()
        let recorder = makeRecorder(hal: hal, onEvent: { events.append($0) })
        try recorder.start()
        defer { recorder.stop() }

        let expectedSelectors = Self.eventMap.map(\.selector)
        let expectedEvents = Self.eventMap.map(\.event)

        #expect(hal.count("addListener") == 5, "listener は 5 本: \(hal.addedListenerSelectors)")
        #expect(Set(hal.addedListenerSelectors) == Set(expectedSelectors),
                "張られた selector が契約の 5 本と違います: \(hal.addedListenerSelectors)")

        for (index, entry) in Self.eventMap.enumerated() {
            // `fire` は登録キュー上で同期的に呼ぶので、戻った時点で届いているのが期待値。
            // 実装が onEvent を別キューに投げる場合もあるので、少しだけ待てるようにしておく。
            #expect(hal.fire(entry.selector) == 1,
                    "selector \(entry.selector) の listener が 1 本ではありません")
            let delivered = waitUntil { events.count == index + 1 }
            #expect(delivered, "onEvent が届きません（selector \(entry.selector)）: \(events.all)")
            let last = events.all.last
            #expect(last == entry.event,
                    "selector \(entry.selector) → \(String(describing: last))（期待: \(entry.event)）")
        }

        #expect(events.all == expectedEvents, "届いた順と内容: \(events.all)")
    }

    // MARK: - 7. watchdog

    @Test("createIOProc が無期限ブロックしても start() は startTimeout で throw し、作った物は逆順に壊れる")
    func watchdogAbortsAndCleansUp() throws {
        let hal = FakeHAL()
        hal.blockAt = .ioproc
        let recorder = makeRecorder(hal: hal, startTimeout: 0.2)

        let began = Date()
        expectCoreAudioError { try recorder.start() }
        let elapsed = Date().timeIntervalSince(began)
        // 有限時間で戻る（0.2 秒の watchdog に対して十分な余裕を見る）。
        #expect(elapsed < 2.0, "start() が \(elapsed) 秒かかりました（startTimeout 0.2 秒）")

        // 打ち切った時点ではまだ createIOProc の中で止まっている。
        #expect(hal.count("createTap") == 1)
        #expect(hal.count("createAggregate") == 1)
        #expect(hal.count("createIOProc") == 0, "まだ IOProc は返っていないはず: \(hal.log)")

        // 止めていたスレッドを進ませる → 後始末が走る。
        hal.unblock()

        let cleanedUp = waitUntil { hal.count("destroyTap") == 1 }
        #expect(cleanedUp, "unblock 後に destroyTap が呼ばれていません: \(hal.log)")
        #expect(hal.count("destroyAggregate") == 1, "destroyAggregate: \(hal.log)")
        #expect(hal.count("destroyIOProc") == 1, "destroyIOProc: \(hal.log)")
        #expect(hal.count("removeListener") == hal.count("addListener"),
                "張った listener が全部外れていません: \(hal.log)")
        #expect(hal.liveListenerCount == 0)
        #expect(hal.hasIOBlock == false)

        // 壊した順は IOProc → aggregate → tap。
        let log = hal.log
        let destroyIOProc = try #require(log.firstIndex(of: "destroyIOProc"))
        let destroyAggregate = try #require(log.firstIndex(of: "destroyAggregate"))
        let destroyTap = try #require(log.firstIndex(of: "destroyTap"))
        #expect(destroyIOProc < destroyAggregate, "逆順になっていません: \(log)")
        #expect(destroyAggregate < destroyTap, "逆順になっていません: \(log)")
    }

    // MARK: - 8. sink に渡る format

    @Test("sink には start() で確定した format のバッファだけが渡る")
    func sinkReceivesTheStartFormatOnly() throws {
        let hal = FakeHAL()
        let sink = SinkBox()
        let recorder = makeRecorder(hal: hal, sink: { sink.append($0) })
        try recorder.start()
        defer { recorder.stop() }

        let format = try #require(recorder.format)
        #expect(format == hal.tapFormatValue)

        // 長さの違う 2 本を流す（frameLength が固定値になっていないことも見る）。
        let sizes: [AVAudioFrameCount] = [1024, 512]
        for (index, frames) in sizes.enumerated() {
            let buffer = Signals.marked(format: hal.tapFormatValue, frames: frames, value: 0.25)
            #expect(hal.emit(buffer), "IOProc の block が登録されていません")
            let delivered = waitUntil { sink.count == index + 1 }
            #expect(delivered, "sink に届きません（frames \(frames)）")
        }

        let received = sink.all
        let receivedFrames = received.map(\.frames)
        #expect(received.count == sizes.count)
        #expect(receivedFrames == sizes, "frameLength: \(receivedFrames)")
        for item in received {
            #expect(item.format == hal.tapFormatValue, "sink の format が tap の format と違います")
            #expect(item.format == format, "sink の format が start() で確定した format と違います")
        }
    }

    // MARK: - 9. aggregate の辞書

    @Test("aggregate の辞書は TapAutoStart が false で、主サブデバイスが既定出力の UID")
    func aggregateDescriptionDisablesTapAutoStart() throws {
        let hal = FakeHAL()
        let recorder = makeRecorder(hal: hal)
        try recorder.start()
        defer { recorder.stop() }

        let description = try #require(hal.lastAggregateDescription, "createAggregate が呼ばれていません")

        // true だと `AudioDeviceStart` が「対象が音を出すまで」戻らない（RESEARCH §2.1）。
        let autoStart = try #require(boolValue(description[kAudioAggregateDeviceTapAutoStartKey]),
                                     "TapAutoStart が辞書にありません: \(description.keys.sorted())")
        #expect(autoStart == false, "kAudioAggregateDeviceTapAutoStartKey は false のはず")

        // 主サブデバイスは既定出力デバイスの UID。
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == hal.deviceUIDValue,
                "MainSubDevice: \(String(describing: description[kAudioAggregateDeviceMainSubDeviceKey]))")
    }

    /// `[String: Any]` に入った真偽値を読む（`Bool` でも `NSNumber` でも取れるように）。
    private func boolValue(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}
