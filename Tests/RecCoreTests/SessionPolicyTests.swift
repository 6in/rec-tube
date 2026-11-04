// SessionPolicyTests.swift — `SessionPolicy` の状態機械（決めた事項 #10 の表）を固定するテスト。
//
// Chrome にも `osascript` にも tap にも触らない。入力は 3 つだけ（`ProbeOutcome` / `MeterSnapshot` /
// `now`）で、出力は `[SessionAction]`。**実装を読まずに仕様文だけから書く**ことで、表との食い違いを
// 検出するのがこのファイルの役目。
//
// 確かめる契約（PLAN T8「完了基準」）:
//   1. 最優先: `probe` が `.gone` なら、録音開始の前でも後でも `[.stop(.tabClosed)]`
//   2. フェーズ A（まだ `.startRecording` を出していない）
//      2a. `.none` / `state == .loading` は待つ。`now - startedAt > Tuning.startTimeoutSeconds` を
//          **超えたら**（`>`。ちょうど 60.0 秒は `.wait`）`[.stop(.pageUnavailable)]`
//      2b. 初回の完全な状態で `live == true` → `[.stop(.liveStream)]`（録音開始済みにはならない）
//      2c. 初回の完全な状態の固定期待値 4 通り（main playing / main paused / ad playing / main ended）
//   3. フェーズ B（録音開始後）
//      3a. `.none` が `Tuning.unresponsiveSeconds` 連続（`>=`。ちょうど 20.0 秒で発火）→
//          `[.stop(.pageUnresponsive)]`。正常値で復帰したら計測はやり直し
//      3b. 判定順は b1 次動画 → b2 終了 → b3 tap 故障 → b4 gate → b5 警告。
//          b1〜b3 が当たったら戻り値は `[.stop(理由)]` の **1 要素だけ**
//      3c. b4 は gate 操作をちょうど 1 つ（`.ad` の連投は `.wait`、広告明けは `.rewindThenOpenGate`）。
//          広告明けの判定は **「`.ad` を見てから本編の `playing` をまだ見ていない」**であって
//          「直前が `.ad`」ではない（間に `main loading` / `main paused` が挟まっても巻き戻す = E12）
//      3d. b5 の警告は **自動再生拒否 → SSAI → 無音**の順。自動再生拒否（`playErr` が非 nil）と
//          SSAI はそれぞれ 1 セッション 1 回だけ。無音警告は **gate が開いている間だけ**で、
//          再送は `Tuning.silenceWarnIntervalSeconds` を**超えてから**（ちょうど 30.0 秒は出さない）
//   4. 純粋な値型: 時刻は必ず引数 `now` から来る（内部で `Date()` を読まない）ので、
//      同じ入力列を 2 つの `SessionPolicy` に流すと出力列は一致する。戻り値は空配列にならない
//
// 書き方の約束:
//   - 秒数・比率は**直書きしない**。必ず `Tuning.*` を参照する（Tuning.swift の規約）
//   - `ProbeResult` は memberwise init を持たない（`Decodable` のみ）ので、入力は JSON 文字列を
//     `parseProbe(_:)` に通して作る。ヘルパが壊れると全テストが `.none` 扱いになって気付けないため、
//     最後に「ヘルパの自己検査」を 1 本置く
//   - `MeterSnapshot` の memberwise init は internal なので `@testable import RecCore` から使う

import Foundation
import Testing

@testable import RecCore

@Suite("SessionPolicy")
struct SessionPolicyTests {
    // MARK: - 固定値

    /// セッションの開始時刻。`now` はすべてここからの相対秒で作る。
    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// 初回の probe が持つ動画 ID（= `firstID` になる値）。
    private static let firstVideoID = "VID1"

    /// 初回と違う動画 ID（次動画の判定に使う）。
    private static let otherVideoID = "VID2"

    /// `startRecording(title:)` に渡るはずのタイトル。
    private static let videoTitle = "テスト動画"

    /// `v.play()` の reject 名（`playErr`）。実機で最もよく出るのがこれ。
    private static let autoplayErrorName = "NotAllowedError"

    // MARK: - ヘルパ

    /// セッション開始から `seconds` 秒後の時刻。
    private func at(_ seconds: Double) -> Date {
        Self.startedAt.addingTimeInterval(seconds)
    }

    /// 新しい `SessionPolicy`（開始時刻は常に `Self.startedAt`）。
    private func makePolicy() -> SessionPolicy {
        SessionPolicy(startedAt: Self.startedAt)
    }

    /// `probeJS` が返す 9 キーの JSON を組んで `parseProbe` に通す。
    ///
    /// `durJSON` / `lenJSON` は**生の JSON トークン**で渡す（`213` / `"inf"` / `null` を
    /// 書き分けたいため。`dur` は数値と文字列の両方を受ける契約）。
    /// `playErr` は `nil` なら JSON の `null`（= 自動再生は拒否されていない）。
    private func probe(_ kind: String,
                      _ state: String,
                      id: String = SessionPolicyTests.firstVideoID,
                      live: Bool = false,
                      title: String? = SessionPolicyTests.videoTitle,
                      durJSON: String = "213",
                      lenJSON: String = "213",
                      playErr: String? = nil) -> ProbeOutcome {
        let titleJSON = title.map { "\"\($0)\"" } ?? "null"
        let playErrJSON = playErr.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"kind":"\(kind)","state":"\(state)","id":"\(id)","cur":0,"dur":\(durJSON),\
        "live":\(live),"title":\(titleJSON),"len":\(lenJSON),"playErr":\(playErrJSON)}
        """
        return parseProbe(json)
    }

    /// メータの累計。既定は「音が入っていて、全ゼロも無音も続いていない」= 何も発火しない値。
    private func meter(everNonZero: Bool = true,
                       allZero: Double = 0,
                       silent: Double = 0) -> MeterSnapshot {
        MeterSnapshot(everNonZero: everNonZero,
                      consecutiveAllZeroSeconds: allZero,
                      consecutiveSilentSeconds: silent,
                      audibleGateOpenWindows: 0,
                      totalWindows: 0)
    }

    /// 「本編再生中の初回 probe を食わせて録音開始済みにする」までを済ませた `SessionPolicy`。
    ///
    /// フェーズ B のテストはここから始める（戻り値の 1 本目は毎回同じなので検査もしておく）。
    private func startedPolicy(now: Double = 0) -> SessionPolicy {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(now))
        #expect(actions == [.startRecording(title: Self.videoTitle), .seekToStart, .openGate],
                "前提が崩れている（初回 main playing の固定期待値）: \(actions)")
        return policy
    }

    // MARK: - 1. `.gone` は最優先

    @Test("録音開始前の .gone は [.stop(.tabClosed)]")
    func goneBeforeRecordingStops() {
        var policy = makePolicy()
        #expect(policy.step(probe: .gone, meter: meter(), now: at(0)) == [.stop(.tabClosed)])
    }

    @Test("録音開始後の .gone も [.stop(.tabClosed)]")
    func goneAfterRecordingStops() {
        var policy = startedPolicy()
        #expect(policy.step(probe: .gone, meter: meter(), now: at(1)) == [.stop(.tabClosed)])
    }

    @Test("タイムアウトを超えた時刻の .gone でも理由は .tabClosed（pageUnavailable より優先）")
    func goneWinsOverStartTimeout() {
        var policy = makePolicy()
        let now = at(Tuning.startTimeoutSeconds + 10)
        #expect(policy.step(probe: .gone, meter: meter(), now: now) == [.stop(.tabClosed)])
    }

    // MARK: - 2a. フェーズ A の待ちとタイムアウト

    @Test("録音開始前の .none はタイムアウト前なら毎回 [.wait]")
    func noneBeforeTimeoutWaits() {
        var policy = makePolicy()
        for seconds in [0.0, 0.5, 1.0, Tuning.startTimeoutSeconds / 2, Tuning.startTimeoutSeconds - 0.5] {
            let actions = policy.step(probe: .none, meter: meter(), now: at(seconds))
            #expect(actions == [.wait], "\(seconds) 秒で待たなかった: \(actions)")
        }
    }

    @Test("ちょうど startTimeoutSeconds は [.wait]、超えたら [.stop(.pageUnavailable)]")
    func noneAtAndAfterStartTimeout() {
        var policy = makePolicy()
        // 境界: `>` なので「ちょうど」はまだ待つ。
        let atBoundary = policy.step(probe: .none, meter: meter(), now: at(Tuning.startTimeoutSeconds))
        #expect(atBoundary == [.wait], "ちょうど \(Tuning.startTimeoutSeconds) 秒で停止した: \(atBoundary)")

        let justOver = policy.step(probe: .none, meter: meter(), now: at(Tuning.startTimeoutSeconds + 0.5))
        #expect(justOver == [.stop(.pageUnavailable)], "超過で停止しなかった: \(justOver)")
    }

    @Test("state == loading も A1 扱い（タイムアウト前は [.wait]）")
    func loadingBeforeTimeoutWaits() {
        var policy = makePolicy()
        #expect(policy.step(probe: probe("main", "loading"), meter: meter(), now: at(1)) == [.wait])
        // `.loading` は kind を問わず A1（録音開始の条件は「loading 以外の完全な状態」）。
        #expect(policy.step(probe: probe("ad", "loading"), meter: meter(), now: at(2)) == [.wait])
        #expect(policy.step(probe: probe("main", "loading"),
                            meter: meter(),
                            now: at(Tuning.startTimeoutSeconds)) == [.wait])
    }

    @Test("state == loading のままタイムアウトを超えたら [.stop(.pageUnavailable)]")
    func loadingAfterTimeoutStops() {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("main", "loading"),
                                  meter: meter(),
                                  now: at(Tuning.startTimeoutSeconds + 0.5))
        #expect(actions == [.stop(.pageUnavailable)], "loading の超過で停止しなかった: \(actions)")
    }

    @Test(".none と loading が混ざってもタイムアウトの基準は startedAt のまま")
    func timeoutMeasuredFromStartedAt() {
        var policy = makePolicy()
        #expect(policy.step(probe: .none, meter: meter(), now: at(10)) == [.wait])
        #expect(policy.step(probe: probe("main", "loading"), meter: meter(), now: at(40)) == [.wait])
        #expect(policy.step(probe: .none, meter: meter(), now: at(59)) == [.wait])
        let actions = policy.step(probe: probe("main", "loading"),
                                  meter: meter(),
                                  now: at(Tuning.startTimeoutSeconds + 1))
        #expect(actions == [.stop(.pageUnavailable)], "startedAt 基準で超過していない: \(actions)")
    }

    // MARK: - 2b. ライブ配信

    @Test("初回の完全な状態で live == true なら [.stop(.liveStream)]")
    func liveStreamStopsBeforeRecording() {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("main", "playing", live: true, durJSON: "\"inf\"", lenJSON: "null"),
                                  meter: meter(),
                                  now: at(1))
        #expect(actions == [.stop(.liveStream)], "ライブで停止しなかった: \(actions)")
    }

    @Test("live == true は録音開始済みにしない（次に通常の状態が来たら startRecording が出る）")
    func liveStreamDoesNotStartRecording() {
        var policy = makePolicy()
        #expect(policy.step(probe: probe("main", "playing", live: true, durJSON: "\"inf\"", lenJSON: "null"),
                            meter: meter(),
                            now: at(1)) == [.stop(.liveStream)])

        // まだフェーズ A のままなので、`.startRecording` は未消費。
        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(2))
        #expect(actions == [.startRecording(title: Self.videoTitle), .seekToStart, .openGate],
                "ライブ検出で録音開始済みになっていた: \(actions)")
    }

    @Test("live == true は paused でも ad でも [.stop(.liveStream)]")
    func liveStreamStopsRegardlessOfStateAndKind() {
        var paused = makePolicy()
        #expect(paused.step(probe: probe("main", "paused", live: true, durJSON: "\"inf\"", lenJSON: "null"),
                            meter: meter(),
                            now: at(1)) == [.stop(.liveStream)])

        var ad = makePolicy()
        #expect(ad.step(probe: probe("ad", "playing", live: true, durJSON: "\"inf\"", lenJSON: "null"),
                        meter: meter(),
                        now: at(1)) == [.stop(.liveStream)])
    }

    // MARK: - 2c. 初回の完全な状態の固定期待値

    @Test("初回 main playing → [.startRecording(title:), .seekToStart, .openGate]")
    func firstMainPlayingStartsAndOpensGate() {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(1))
        #expect(actions == [.startRecording(title: Self.videoTitle), .seekToStart, .openGate],
                "固定期待値と違う: \(actions)")
    }

    @Test("初回 main paused → [.startRecording(title:), .closeGateHold]")
    func firstMainPausedStartsAndHolds() {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("main", "paused"), meter: meter(), now: at(1))
        #expect(actions == [.startRecording(title: Self.videoTitle), .closeGateHold],
                "固定期待値と違う: \(actions)")
    }

    @Test("初回 ad playing → [.startRecording(title:), .closeGateDiscard]")
    func firstAdPlayingStartsAndDiscards() {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1))
        #expect(actions == [.startRecording(title: Self.videoTitle), .closeGateDiscard],
                "固定期待値と違う: \(actions)")
    }

    @Test("初回 main ended → [.startRecording(title:), .stop(.ended)]")
    func firstMainEndedStartsAndStops() {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("main", "ended"), meter: meter(), now: at(1))
        #expect(actions == [.startRecording(title: Self.videoTitle), .stop(.ended)],
                "固定期待値と違う: \(actions)")
    }

    // MARK: - 3a. 録音開始後の欠測（pageUnresponsive）

    @Test("録音開始後の .none が unresponsiveSeconds 連続したら [.stop(.pageUnresponsive)]")
    func missingProbeAfterRecordingStops() {
        var policy = startedPolicy()

        // 最初の欠測そのものは経過 0 なので待つ。
        #expect(policy.step(probe: .none, meter: meter(), now: at(1)) == [.wait])
        #expect(policy.step(probe: .none, meter: meter(), now: at(1 + Tuning.unresponsiveSeconds / 2)) == [.wait])
        #expect(policy.step(probe: .none, meter: meter(), now: at(1 + Tuning.unresponsiveSeconds - 1)) == [.wait])

        // 境界: `>=` なので「ちょうど」で発火する。
        let actions = policy.step(probe: .none, meter: meter(), now: at(1 + Tuning.unresponsiveSeconds))
        #expect(actions == [.stop(.pageUnresponsive)], "ちょうど \(Tuning.unresponsiveSeconds) 秒で停止しなかった: \(actions)")
    }

    @Test("最初の欠測は経過 0 なので、1 回だけの .none では停止しない")
    func singleMissingProbeWaits() {
        var policy = startedPolicy()
        // 遠い未来の `now` でも、欠測の計測は「最初の欠測」からなので経過 0。
        let actions = policy.step(probe: .none,
                                  meter: meter(),
                                  now: at(Tuning.unresponsiveSeconds * 10))
        #expect(actions == [.wait], "最初の欠測で停止した: \(actions)")
    }

    @Test("欠測の途中で正常値に復帰すると停止せず、再び欠測が始まったら計測もやり直す")
    func missingProbeCounterResetsOnRecovery() {
        var policy = startedPolicy()

        // 1 回目の欠測列: unresponsiveSeconds の 1 秒前まで。
        #expect(policy.step(probe: .none, meter: meter(), now: at(1)) == [.wait])
        #expect(policy.step(probe: .none, meter: meter(), now: at(1 + Tuning.unresponsiveSeconds - 1)) == [.wait])

        // 復帰（`missingSince` はここでクリアされる）。
        let recovered = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(21))
        #expect(recovered == [.openGate], "復帰時に gate を開かなかった: \(recovered)")

        // 2 回目の欠測列: 計測がやり直しなので、1 回目からの通算では超えていても停止しない。
        #expect(policy.step(probe: .none, meter: meter(), now: at(22)) == [.wait])
        let beforeDeadline = policy.step(probe: .none,
                                         meter: meter(),
                                         now: at(22 + Tuning.unresponsiveSeconds - 1))
        #expect(beforeDeadline == [.wait], "欠測の計測がやり直されていない: \(beforeDeadline)")

        let atDeadline = policy.step(probe: .none,
                                     meter: meter(),
                                     now: at(22 + Tuning.unresponsiveSeconds))
        #expect(atDeadline == [.stop(.pageUnresponsive)], "2 回目の欠測列で停止しなかった: \(atDeadline)")
    }

    @Test(".none は広告明けの記憶を消さない（広告中の欠測から復帰したら .rewindThenOpenGate）")
    func missingProbeKeepsPreviousKind() {
        var policy = makePolicy()
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1))
            == [.startRecording(title: Self.videoTitle), .closeGateDiscard])

        // 欠測を挟んでも「広告を見た（巻き戻しが未消費）」の記憶は消えない。
        #expect(policy.step(probe: .none, meter: meter(), now: at(2)) == [.wait])
        #expect(policy.step(probe: .none, meter: meter(), now: at(3)) == [.wait])

        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(4))
        #expect(actions == [.rewindThenOpenGate], ".none が広告明けの記憶を消した: \(actions)")
    }

    // MARK: - 3b. b1 / b2 / b3（当たったら 1 要素だけ）

    @Test("main playing で id が初回と違う → [.stop(.nextVideo)]")
    func mainWithDifferentIDStopsAsNextVideo() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing", id: Self.otherVideoID),
                                  meter: meter(),
                                  now: at(1))
        #expect(actions == [.stop(.nextVideo)], "次動画で停止しなかった: \(actions)")
    }

    @Test("b1 は b2 / b3 / gate 操作より先（id 違い + ended + 全ゼロでも .nextVideo の 1 要素）")
    func nextVideoWinsOverEndedAndStall() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "ended", id: Self.otherVideoID),
                                  meter: meter(everNonZero: false, allZero: Tuning.tapStallSeconds),
                                  now: at(1))
        #expect(actions == [.stop(.nextVideo)], "b1 が最優先になっていない: \(actions)")
    }

    @Test("main ended → [.stop(.ended)] の 1 要素だけ（gate 操作も警告も付かない）")
    func mainEndedStops() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "ended", durJSON: "300", lenJSON: "100"),
                                  meter: meter(silent: Tuning.silenceWarnAfterSeconds),
                                  now: at(1))
        #expect(actions == [.stop(.ended)], "終了が 1 要素になっていない: \(actions)")
    }

    @Test("b2 は b3 より先（ended + 全ゼロ継続なら .ended）")
    func endedWinsOverStall() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "ended"),
                                  meter: meter(everNonZero: true, allZero: Tuning.tapStallSeconds),
                                  now: at(1))
        #expect(actions == [.stop(.ended)], "b2 が b3 より先になっていない: \(actions)")
    }

    @Test("main playing + 全ゼロが tapStallSeconds 継続、everNonZero == true → [.stop(.tapStalled)]")
    func tapStalledWhenAudioWasHeardBefore() {
        var policy = startedPolicy()
        // 境界: `>=` なので「ちょうど」で発火する。
        let actions = policy.step(probe: probe("main", "playing"),
                                  meter: meter(everNonZero: true, allZero: Tuning.tapStallSeconds),
                                  now: at(1))
        #expect(actions == [.stop(.tapStalled)], "tap 故障で停止しなかった: \(actions)")
    }

    @Test("main playing + 全ゼロが tapStallSeconds 継続、everNonZero == false → [.stop(.permissionSuspected)]")
    func permissionSuspectedWhenNoAudioEver() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing"),
                                  meter: meter(everNonZero: false, allZero: Tuning.tapStallSeconds),
                                  now: at(1))
        #expect(actions == [.stop(.permissionSuspected)], "権限疑いで停止しなかった: \(actions)")
    }

    @Test("全ゼロが tapStallSeconds に届いていなければ停止せず gate 操作に落ちる")
    func stallBelowThresholdDoesNotStop() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing"),
                                  meter: meter(everNonZero: false, allZero: Tuning.tapStallSeconds - 1),
                                  now: at(1))
        #expect(actions == [.openGate], "閾値未満で停止した: \(actions)")
    }

    @Test("b3 は本編の playing だけ（paused / 広告では全ゼロが続いても停止しない）")
    func stallOnlyAppliesToMainPlaying() {
        var paused = startedPolicy()
        let pausedActions = paused.step(probe: probe("main", "paused"),
                                        meter: meter(everNonZero: false, allZero: Tuning.tapStallSeconds),
                                        now: at(1))
        #expect(pausedActions == [.closeGateHold], "paused で tap 故障と判定した: \(pausedActions)")

        var ad = startedPolicy()
        let adActions = ad.step(probe: probe("ad", "playing"),
                                meter: meter(everNonZero: false, allZero: Tuning.tapStallSeconds),
                                now: at(1))
        #expect(adActions == [.closeGateDiscard], "広告中に tap 故障と判定した: \(adActions)")
    }

    @Test("ad playing で id が初回と違っても b1 は当たらない（継続して gate 操作に落ちる）")
    func adWithDifferentIDKeepsGoing() {
        var policy = startedPolicy()

        // 直前は `.main` なので広告に入ったところ = 捨てて閉じる。
        let first = policy.step(probe: probe("ad", "playing", id: Self.otherVideoID),
                                meter: meter(),
                                now: at(1))
        #expect(first == [.closeGateDiscard], "広告の id 違いで停止した: \(first)")

        // 続けて広告なら `.wait`（gate 操作は 1 回だけ）。
        let second = policy.step(probe: probe("ad", "playing", id: Self.otherVideoID),
                                 meter: meter(),
                                 now: at(2))
        #expect(second == [.wait], "広告の連投で gate を触った: \(second)")
    }

    // MARK: - 3c. b4 の gate 操作

    @Test("広告に入ったら closeGateDiscard は 1 回だけ（続けて広告なら .wait）")
    func adGateClosesOnlyOnce() {
        var policy = makePolicy()
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1))
            == [.startRecording(title: Self.videoTitle), .closeGateDiscard])

        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(2)) == [.wait])
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(3)) == [.wait])
        // state を問わず `.ad` なら同じ扱い。
        #expect(policy.step(probe: probe("ad", "paused"), meter: meter(), now: at(4)) == [.wait])
    }

    @Test("広告明け（ad の直後に main playing）→ [.rewindThenOpenGate]")
    func adToMainPlayingRewindsThenOpens() {
        var policy = makePolicy()
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1))
            == [.startRecording(title: Self.videoTitle), .closeGateDiscard])

        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(2))
        #expect(actions == [.rewindThenOpenGate], "広告明けの巻き戻しが出ていない: \(actions)")

        // 2 回目以降は通常の `.openGate`（巻き戻しが消費されている）。
        let again = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(3))
        #expect(again == [.openGate], "広告明けの旗が消費されていない: \(again)")
    }

    /// F1 の E12。判定が「直前が `.ad`」だと、広告と本編再生の間に 1 回でも別の状態が
    /// 挟まった瞬間に巻き戻しが落ちる。実機ではここに `main loading` が入るのが普通。
    @Test("ad → main loading → main playing でも [.rewindThenOpenGate]")
    func adThenLoadingThenMainPlayingRewinds() {
        var policy = startedPolicy()
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1)) == [.closeGateDiscard])
        #expect(policy.step(probe: probe("main", "loading"), meter: meter(), now: at(2)) == [.wait])

        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(3))
        #expect(actions == [.rewindThenOpenGate], "loading を挟んだら巻き戻しが落ちた: \(actions)")
    }

    @Test("ad → main paused → main playing でも [.rewindThenOpenGate]")
    func adThenPausedThenMainPlayingRewinds() {
        var policy = startedPolicy()
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1)) == [.closeGateDiscard])
        #expect(policy.step(probe: probe("main", "paused"), meter: meter(), now: at(2)) == [.closeGateHold])

        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(3))
        #expect(actions == [.rewindThenOpenGate], "一時停止を挟んだら巻き戻しが落ちた: \(actions)")
    }

    @Test("ad → ad → main playing でも [.rewindThenOpenGate]（広告の連投を跨ぐ）")
    func adRepeatedThenMainPlayingRewinds() {
        var policy = startedPolicy()
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1)) == [.closeGateDiscard])
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(2)) == [.wait])

        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(3))
        #expect(actions == [.rewindThenOpenGate], "広告の連投のあと巻き戻さなかった: \(actions)")
    }

    @Test("rewindThenOpenGate を出したら旗は下りる（以降の main playing は .openGate）")
    func rewindConsumesPendingAdResume() {
        var policy = startedPolicy()
        #expect(policy.step(probe: probe("ad", "playing"), meter: meter(), now: at(1)) == [.closeGateDiscard])
        #expect(policy.step(probe: probe("main", "playing"), meter: meter(), now: at(2)) == [.rewindThenOpenGate])

        // 旗を下ろすのは巻き戻しを出した 1 回だけ。一時停止や loading を挟んでも立ち直らない。
        #expect(policy.step(probe: probe("main", "paused"), meter: meter(), now: at(3)) == [.closeGateHold])
        #expect(policy.step(probe: probe("main", "loading"), meter: meter(), now: at(4)) == [.wait])

        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(5))
        #expect(actions == [.openGate], "巻き戻しを出したのに旗が立ったままだった: \(actions)")
    }

    // MARK: - 3d-0. 自動再生拒否の警告（F1 の E10。1 セッション 1 回だけ）

    @Test("playErr が非 nil なら警告列の先頭に .warn(autoplayRejected)（録音は継続）")
    func autoplayRejectedWarnsOnce() {
        var policy = startedPolicy()
        let expected = SessionAction.warn(Messages.autoplayRejected(name: Self.autoplayErrorName))

        let first = policy.step(probe: probe("main", "playing", playErr: Self.autoplayErrorName),
                                meter: meter(),
                                now: at(1))
        #expect(first == [.openGate, expected], "自動再生拒否の警告が出ていない: \(first)")

        // 同じ `playErr` が続いても警告は最初の 1 回だけ（録音は止めない）。
        let second = policy.step(probe: probe("main", "playing", playErr: Self.autoplayErrorName),
                                 meter: meter(),
                                 now: at(2))
        #expect(second == [.openGate], "自動再生拒否の警告が 2 回出た: \(second)")

        let third = policy.step(probe: probe("main", "playing", playErr: Self.autoplayErrorName),
                                meter: meter(),
                                now: at(3))
        #expect(third == [.openGate], "自動再生拒否の警告が 3 回目に出た: \(third)")
    }

    @Test("playErr が nil なら自動再生拒否の警告は出ない")
    func autoplayRejectedStaysQuietWithoutPlayErr() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(1))
        #expect(actions == [.openGate], "playErr が nil なのに警告が出た: \(actions)")
    }

    @Test("警告が 3 つ同時に立つ場合は gate 操作 → 自動再生拒否 → SSAI → 無音 の順")
    func autoplayWarningComesBeforeOtherWarnings() {
        var policy = startedPolicy()
        let length = 100.0
        let longDur = "\(length * Tuning.ssaiDurationRatio + 1)"

        let actions = policy.step(probe: probe("main", "playing",
                                               durJSON: longDur,
                                               lenJSON: "\(length)",
                                               playErr: Self.autoplayErrorName),
                                  meter: meter(silent: Tuning.silenceWarnAfterSeconds),
                                  now: at(1))
        #expect(actions == [.openGate,
                            .warn(Messages.autoplayRejected(name: Self.autoplayErrorName)),
                            .warn(Messages.ssaiWarning),
                            .warn(Messages.silenceWarning)],
                "警告の順序が違う: \(actions)")
    }

    @Test("b1〜b3 で停止する probe に playErr が付いていても警告は付かない（旗も立たない）")
    func autoplayWarningIsNotAddedWhenStopping() {
        var policy = startedPolicy()
        let stopping = policy.step(probe: probe("main", "ended", playErr: Self.autoplayErrorName),
                                   meter: meter(),
                                   now: at(1))
        #expect(stopping == [.stop(.ended)], "停止が 1 要素になっていない: \(stopping)")

        // 旗も立っていないので、b4 に届く probe が来たらそこで初めて 1 回出る。
        let later = policy.step(probe: probe("main", "playing", playErr: Self.autoplayErrorName),
                                meter: meter(),
                                now: at(2))
        #expect(later == [.openGate, .warn(Messages.autoplayRejected(name: Self.autoplayErrorName))],
                "停止した step で警告の旗が立っていた: \(later)")
    }

    @Test("main playing（直前も main）→ [.openGate]")
    func mainPlayingAfterMainOpensGate() {
        var policy = startedPolicy()
        #expect(policy.step(probe: probe("main", "playing"), meter: meter(), now: at(1)) == [.openGate])
        #expect(policy.step(probe: probe("main", "playing"), meter: meter(), now: at(2)) == [.openGate])
    }

    @Test("main paused → [.closeGateHold]")
    func mainPausedHoldsGate() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "paused"), meter: meter(), now: at(1))
        #expect(actions == [.closeGateHold], "一時停止で保持しなかった: \(actions)")
    }

    @Test("main paused のあと main playing に戻ったら .openGate（ad を見ていないので巻き戻さない）")
    func mainPausedThenPlayingOpensGateWithoutRewind() {
        var policy = startedPolicy()
        #expect(policy.step(probe: probe("main", "paused"), meter: meter(), now: at(1)) == [.closeGateHold])
        let actions = policy.step(probe: probe("main", "playing"), meter: meter(), now: at(2))
        #expect(actions == [.openGate], "一時停止明けで巻き戻した: \(actions)")
    }

    @Test("録音開始後の main loading は [.wait]（b4 の「それ以外」）")
    func mainLoadingAfterRecordingWaits() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "loading"), meter: meter(), now: at(1))
        #expect(actions == [.wait], "録音開始後の loading が待ちになっていない: \(actions)")
    }

    // MARK: - 3d-1. SSAI 警告（1 セッション 1 回だけ）

    @Test("dur > len × ssaiDurationRatio なら .warn(ssaiWarning) が 1 回だけ付く")
    func ssaiWarningFiresOnlyOnce() {
        var policy = startedPolicy()
        let length = 100.0
        let longDur = "\(length * Tuning.ssaiDurationRatio + 1)"

        let first = policy.step(probe: probe("main", "playing", durJSON: longDur, lenJSON: "\(length)"),
                                meter: meter(),
                                now: at(1))
        #expect(first == [.openGate, .warn(Messages.ssaiWarning)], "SSAI 警告が出ていない: \(first)")

        let second = policy.step(probe: probe("main", "playing", durJSON: longDur, lenJSON: "\(length)"),
                                 meter: meter(),
                                 now: at(2))
        #expect(second == [.openGate], "SSAI 警告が 2 回出た: \(second)")

        let third = policy.step(probe: probe("main", "playing", durJSON: longDur, lenJSON: "\(length)"),
                                meter: meter(),
                                now: at(3))
        #expect(third == [.openGate], "SSAI 警告が 3 回目に出た: \(third)")
    }

    @Test("dur が len × ssaiDurationRatio を超えていなければ SSAI 警告は出ない")
    func ssaiWarningNeedsRatio() {
        var policy = startedPolicy()
        let length = 100.0
        let shortDur = "\(length * Tuning.ssaiDurationRatio - 1)"
        let actions = policy.step(probe: probe("main", "playing", durJSON: shortDur, lenJSON: "\(length)"),
                                  meter: meter(),
                                  now: at(1))
        #expect(actions == [.openGate], "比率未満で SSAI 警告が出た: \(actions)")
    }

    @Test("dur が無限（\"inf\"）なら SSAI 警告は出ない")
    func ssaiWarningSkipsInfiniteDur() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing", durJSON: "\"inf\"", lenJSON: "100"),
                                  meter: meter(),
                                  now: at(1))
        #expect(actions == [.openGate], "dur が無限なのに SSAI 警告が出た: \(actions)")
    }

    @Test("len == nil なら SSAI 警告は出ない")
    func ssaiWarningSkipsMissingLength() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing", durJSON: "300", lenJSON: "null"),
                                  meter: meter(),
                                  now: at(1))
        #expect(actions == [.openGate], "len が nil なのに SSAI 警告が出た: \(actions)")
    }

    /// turn 10 の PLAN 訂正（決めた事項 #8 に `len > 0` を足した）。
    ///
    /// `len == 0`（`vd.lengthSeconds` が `"0"`）は「公称の尺が分からない」という意味で、
    /// `dur > 0 × 1.2` が必ず真になる。ここを塞がないと普通の動画で毎回 SSAI 警告が出る。
    @Test("len == 0 なら SSAI 警告は出ない（公称が不明なので比べられない）")
    func ssaiWarningSkipsZeroLength() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing", durJSON: "300", lenJSON: "0"),
                                  meter: meter(),
                                  now: at(1))
        #expect(actions == [.openGate], "len == 0 なのに SSAI 警告が出た: \(actions)")
    }

    // MARK: - 3d-2. 無音警告（gate が開いている間だけ・30 秒は抑える）

    @Test("gate 開 かつ 無音が silenceWarnAfterSeconds 続いたら .warn(silenceWarning)")
    func silenceWarningFiresWhenGateIsOpen() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing"),
                                  meter: meter(silent: Tuning.silenceWarnAfterSeconds),
                                  now: at(1))
        #expect(actions == [.openGate, .warn(Messages.silenceWarning)], "無音警告が出ていない: \(actions)")
    }

    @Test("無音が silenceWarnAfterSeconds に届いていなければ無音警告は出ない")
    func silenceWarningNeedsThreshold() {
        var policy = startedPolicy()
        let actions = policy.step(probe: probe("main", "playing"),
                                  meter: meter(silent: Tuning.silenceWarnAfterSeconds - 1),
                                  now: at(1))
        #expect(actions == [.openGate], "閾値未満で無音警告が出た: \(actions)")
    }

    @Test("無音警告の再送は silenceWarnIntervalSeconds を超えてから（ちょうど 30.0 秒は出さない）")
    func silenceWarningRepeatsOnlyAfterInterval() {
        var policy = startedPolicy()
        let silent = meter(silent: Tuning.silenceWarnAfterSeconds)
        let firstWarnAt = 1.0

        let first = policy.step(probe: probe("main", "playing"), meter: silent, now: at(firstWarnAt))
        #expect(first == [.openGate, .warn(Messages.silenceWarning)], "1 回目の無音警告が出ていない: \(first)")

        // 間隔の内側では出さない。
        let soon = policy.step(probe: probe("main", "playing"),
                               meter: silent,
                               now: at(firstWarnAt + Tuning.silenceWarnIntervalSeconds / 2))
        #expect(soon == [.openGate], "間隔の内側で再警告した: \(soon)")

        // 境界: `>` なので「ちょうど」はまだ出さない。
        let atBoundary = policy.step(probe: probe("main", "playing"),
                                     meter: silent,
                                     now: at(firstWarnAt + Tuning.silenceWarnIntervalSeconds))
        #expect(atBoundary == [.openGate],
                "ちょうど \(Tuning.silenceWarnIntervalSeconds) 秒で再警告した: \(atBoundary)")

        // 超えたら再度出す。
        let afterBoundary = policy.step(probe: probe("main", "playing"),
                                        meter: silent,
                                        now: at(firstWarnAt + Tuning.silenceWarnIntervalSeconds + 0.5))
        #expect(afterBoundary == [.openGate, .warn(Messages.silenceWarning)],
                "間隔を超えても再警告しなかった: \(afterBoundary)")
    }

    @Test("gate が閉じている間は無音警告を出さない（main paused / 広告中）")
    func silenceWarningStaysQuietWhileGateIsClosed() {
        let silent = meter(silent: Tuning.silenceWarnAfterSeconds * 10)

        // 一時停止で gate を閉じたあとは出さない。
        var paused = startedPolicy()
        #expect(paused.step(probe: probe("main", "paused"), meter: meter(), now: at(1)) == [.closeGateHold])
        let whilePaused = paused.step(probe: probe("main", "paused"), meter: silent, now: at(2))
        #expect(whilePaused == [.closeGateHold], "gate が閉じているのに無音警告が出た: \(whilePaused)")

        // 広告で gate を閉じたあとも出さない（`.wait` のときも警告は付かない）。
        var ad = startedPolicy()
        #expect(ad.step(probe: probe("ad", "playing"), meter: meter(), now: at(1)) == [.closeGateDiscard])
        let whileAd = ad.step(probe: probe("ad", "playing"), meter: silent, now: at(2))
        #expect(whileAd == [.wait], "広告中に無音警告が出た: \(whileAd)")
    }

    @Test("初回 main paused（gate は初期値のまま閉）でも無音警告は出ない")
    func silenceWarningStaysQuietBeforeGateEverOpened() {
        var policy = makePolicy()
        let actions = policy.step(probe: probe("main", "paused"),
                                  meter: meter(silent: Tuning.silenceWarnAfterSeconds * 10),
                                  now: at(1))
        #expect(actions == [.startRecording(title: Self.videoTitle), .closeGateHold],
                "gate を開く前に無音警告が出た: \(actions)")
    }

    @Test("gate を閉じて開き直したら無音警告は再び出せる")
    func silenceWarningResumesAfterGateReopens() {
        var policy = startedPolicy()
        let silent = meter(silent: Tuning.silenceWarnAfterSeconds)

        // 一時停止中は出ない。
        #expect(policy.step(probe: probe("main", "paused"), meter: silent, now: at(1)) == [.closeGateHold])

        // 開き直したら（未警告なので）出る。
        let actions = policy.step(probe: probe("main", "playing"), meter: silent, now: at(2))
        #expect(actions == [.openGate, .warn(Messages.silenceWarning)],
                "gate を開き直しても無音警告が出ない: \(actions)")
    }

    @Test("SSAI 警告と無音警告が同時に立つ場合は gate 操作 → SSAI → 無音 の順")
    func warningsAreOrderedAfterGateAction() {
        var policy = startedPolicy()
        let length = 100.0
        let longDur = "\(length * Tuning.ssaiDurationRatio + 1)"
        let actions = policy.step(probe: probe("main", "playing", durJSON: longDur, lenJSON: "\(length)"),
                                  meter: meter(silent: Tuning.silenceWarnAfterSeconds),
                                  now: at(1))
        #expect(actions == [.openGate, .warn(Messages.ssaiWarning), .warn(Messages.silenceWarning)],
                "警告の順序が違う: \(actions)")
    }

    // MARK: - 4. 純粋な値型（時刻は引数からだけ）

    @Test("同じ入力列を 2 つの SessionPolicy に流すと出力列が一致し、どの step も空配列を返さない")
    func sameInputsProduceSameOutputs() {
        // フェーズ A → 広告 → 広告明け → 無音 → 一時停止 → 欠測 → 次動画 まで一通り通す列。
        let silent = meter(silent: Tuning.silenceWarnAfterSeconds)
        let steps: [(probe: ProbeOutcome, meter: MeterSnapshot, now: Date)] = [
            (.none, meter(), at(0)),
            (probe("main", "loading"), meter(), at(1)),
            (probe("main", "playing"), meter(), at(2)),
            (probe("ad", "playing"), meter(), at(3)),
            (probe("ad", "playing"), meter(), at(4)),
            (probe("main", "playing", durJSON: "300", lenJSON: "100"), silent, at(5)),
            (probe("main", "playing"), silent, at(6)),
            (probe("main", "paused"), meter(), at(7)),
            (.none, meter(), at(8)),
            (probe("main", "playing"), meter(), at(9)),
            (probe("main", "playing", id: Self.otherVideoID), meter(), at(10)),
        ]

        func run() -> [[SessionAction]] {
            var policy = makePolicy()
            return steps.map { policy.step(probe: $0.probe, meter: $0.meter, now: $0.now) }
        }

        let firstRun = run()
        let secondRun = run()

        #expect(firstRun == secondRun, "同じ入力列で出力列が変わった:\n\(firstRun)\n\(secondRun)")
        for (index, actions) in firstRun.enumerated() {
            #expect(actions.isEmpty == false, "step \(index) が空配列を返した")
        }
        // 列の最後は次動画で止まる（列そのものが意図どおり組めていることの確認）。
        #expect(firstRun.last == [.stop(.nextVideo)], "入力列の最後が次動画になっていない: \(String(describing: firstRun.last))")
    }

    @Test("now が過去に戻っても内部で Date() を読まない（startedAt 基準の判定が壊れない）")
    func stepUsesOnlyProvidedNow() {
        // `startedAt` は 2023 年の固定値なので、実時刻を読む実装ならタイムアウトが即発火する。
        var policy = makePolicy()
        #expect(policy.step(probe: .none, meter: meter(), now: at(0)) == [.wait],
                "実時刻を読んでいる疑い（startedAt + 0 秒で待たなかった）")
        #expect(policy.step(probe: probe("main", "playing"), meter: meter(), now: at(1))
            == [.startRecording(title: Self.videoTitle), .seekToStart, .openGate])
    }

    // MARK: - ヘルパの自己検査

    @Test("ヘルパの JSON は parseProbe を通って .result になる（全テストが .none 扱いになるのを防ぐ）")
    func probeHelperProducesResult() throws {
        for (kind, state) in [("main", "playing"), ("main", "paused"), ("main", "ended"),
                              ("main", "loading"), ("ad", "playing"), ("ad", "loading")] {
            guard case let .result(value) = probe(kind, state) else {
                Issue.record("ヘルパの JSON が .result にならない: \(kind) / \(state)")
                continue
            }
            #expect(value.kind.rawValue == kind)
            #expect(value.state.rawValue == state)
            #expect(value.id == Self.firstVideoID)
            #expect(value.title == Self.videoTitle)
        }

        // `dur` / `len` の生トークンも意図どおり読めている。
        guard case let .result(infinite) = probe("main", "playing", durJSON: "\"inf\"", lenJSON: "null") else {
            Issue.record("dur: \"inf\" / len: null のヘルパが .result にならない")
            return
        }
        #expect(infinite.dur.isFinite == false)
        #expect(infinite.len == nil)

        guard case let .result(live) = probe("main", "playing", live: true) else {
            Issue.record("live: true のヘルパが .result にならない")
            return
        }
        #expect(live.live == true)

        // `playErr` も生トークンで書き分けている（既定は `null` = 拒否されていない）。
        guard case let .result(rejected) = probe("main", "playing", playErr: Self.autoplayErrorName),
              case let .result(allowed) = probe("main", "playing")
        else {
            Issue.record("playErr のヘルパが .result にならない")
            return
        }
        #expect(rejected.playErr == Self.autoplayErrorName)
        #expect(allowed.playErr == nil)
    }
}
