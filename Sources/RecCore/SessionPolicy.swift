// SessionPolicy.swift — `--url` モードの状態機械。probe の結果と無音メータを見て
// 「次に何をするか」（`SessionAction`）を決めるだけの純粋な値型。
//
// **断言（この型の契約）**:
//   - **決めた事項 #10 の表だけを実装する**。表に無い行動（リトライ、フォールバック、
//     録音の再開、`SessionAction` の新 case）を一切足さない
//   - **純粋な値型**。`Date()` も I/O も内部で呼ばない。時刻は必ず引数 `now` で受け取る
//     （テストが 1 秒刻みの系列を手で作れるように）
//   - `step` は **throw しない**。戻り値は**空配列にしない**（該当が無ければ `[.wait]`）
//   - `startRecording` は 1 セッションでちょうど 1 回。`stop` を返したあとに呼ばれても
//     この型は何も覚えない（止めるのは `StopCoordinator` の仕事。最初の 1 本だけが効く）
//
// 境界（テストが固定する値。`>` と `>=` の違いが仕様）:
//   - 録音開始の待ち: **ちょうど `Tuning.startTimeoutSeconds` は `.wait`**（`>`）
//   - 録音開始後の連続欠測: **ちょうど `Tuning.unresponsiveSeconds` で stop**（`>=`）
//   - 全ゼロの tap 故障: **ちょうど `Tuning.tapStallSeconds` で stop**（`>=`）
//   - 無音警告: 継続は `>= Tuning.silenceWarnAfterSeconds`（`>=`）、
//     再警告は **ちょうど `Tuning.silenceWarnIntervalSeconds` では出さない**（`>`）
//
// 追従先（PLAN「追従先チェックリスト」）: 秒数・比率はこのファイルに直書きせず必ず
// `Tuning.*` を経由する。表を変えたら PLAN 決めた事項 #10・`SessionPolicyTests`・
// `RecordingSession.apply` を同じターンで直す。

import Foundation

/// `--url` モードの状態機械。1 回の poll ごとに `step` を呼ぶ。
///
/// `Sendable`: 格納しているのは `Date` / `Bool` / `String?` / `ProbeKind?` だけで、
/// すべて値型かつ `Sendable`。`mutating func` なので呼び出し側（`RecordingSession`）が
/// セッションキュー上で 1 つのインスタンスを持つ使い方になる。
public struct SessionPolicy: Sendable {
    // MARK: - 不変

    /// 待ち始めた時刻。録音開始前のタイムアウト（`Tuning.startTimeoutSeconds`）の基準。
    private let startedAt: Date

    // MARK: - 可変状態（`step` だけが書き換える）

    /// `.startRecording` を出したか（= フェーズ B に入ったか）。
    private var didStartRecording = false

    /// 初回の完全な状態で見た動画 ID。`.main` でこれと違う ID が来たら `.nextVideo`。
    private var firstID: String?

    /// 直前の `.result` の `kind`。`.none`（欠測）では更新しない（`.none` は kind を持たない）。
    private var lastKind: ProbeKind?

    /// 録音開始後、連続欠測が始まった時刻（欠測していなければ `nil`）。
    private var missingSince: Date?

    /// gate が開いているか（`.openGate` / `.rewindThenOpenGate` を出したら開、
    /// `.closeGateDiscard` / `.closeGateHold` を出したら閉）。初期値は閉。
    /// 無音警告はこの内部状態を見る。
    private var gateOpen = false

    /// SSAI 警告を出したか（1 セッションに 1 回だけ）。
    private var didWarnSSAI = false

    /// 直前に無音警告を出した時刻（まだなら `nil`）。
    private var lastSilenceWarnAt: Date?

    /// - Parameter startedAt: 録音開始を待ち始めた時刻。
    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    // MARK: - 唯一の入口

    /// 1 回の poll ぶんの判定。
    ///
    /// 評価順は #10 の表どおり: `gone`（最優先）→ 録音開始前（フェーズ A）→ 録音開始後（フェーズ B）。
    ///
    /// - Parameters:
    ///   - probe: 今回の probe の結果。`execute` がタブ消失で throw した場合も呼び出し側が
    ///     `.gone` に直して渡す（T7 の申し送り）。
    ///   - meter: 録音開始からの無音メータの累計。
    ///   - now: 今の時刻。**この型は時計を持たない**ので必ず渡す。
    /// - Returns: 実行する指示の列。**空配列にはならない**。
    public mutating func step(probe: ProbeOutcome, meter: MeterSnapshot, now: Date) -> [SessionAction] {
        switch probe {
        case .gone:
            // 0. 最優先。録音開始の前後に関係なくここで終わり。
            return [.stop(.tabClosed)]

        case .none:
            // A1 / B1。録音開始前は「まだ始まらない」、開始後は「応答がない」で別物。
            return didStartRecording ? missing(now: now) : waitOrStartTimeout(now: now)

        case let .result(result):
            if didStartRecording {
                // フェーズ B。
                return apply(result, meter: meter, now: now)
            }
            if result.state == .loading {
                // A1。まだ「完全な状態」ではないので待ちの扱い。
                return waitOrStartTimeout(now: now)
            }
            // A2。初回の完全な状態。
            return start(with: result, meter: meter, now: now)
        }
    }

    // MARK: - フェーズ A（まだ `.startRecording` を出していない）

    /// A1: 録音が始まる前の待ち。`Tuning.startTimeoutSeconds` を**超えたら**打ち切る。
    ///
    /// ちょうど `startTimeoutSeconds` は `.wait`（`>` であって `>=` ではない）。
    private func waitOrStartTimeout(now: Date) -> [SessionAction] {
        if now.timeIntervalSince(startedAt) > Tuning.startTimeoutSeconds {
            return [.stop(.pageUnavailable)]
        }
        return [.wait]
    }

    /// A2: 初回の完全な状態。live なら中止、そうでなければ録音を始めて**同じ step で**
    /// フェーズ B の判定（`apply`）を同じ `result` に続けて適用する。
    private mutating func start(with result: ProbeResult, meter: MeterSnapshot, now: Date) -> [SessionAction] {
        if result.live {
            // この時点では録音開始済みにしない（`startRecording` を出していないので）。
            return [.stop(.liveStream)]
        }

        firstID = result.id
        didStartRecording = true

        var actions: [SessionAction] = [.startRecording(title: result.title)]
        if result.kind == .main, result.state == .playing {
            actions.append(.seekToStart)
        }
        // 表の「以降は下の行を同じ step で適用」。特別扱いを足さず素直に連結する
        // （初回 `main ended` が `[.startRecording, .stop(.ended)]` になるのはこの結果）。
        actions += apply(result, meter: meter, now: now)
        return actions
    }

    // MARK: - フェーズ B（すでに `.startRecording` を出した）

    /// B1: 録音開始後の連続欠測。**ちょうど `Tuning.unresponsiveSeconds` で stop**（`>=`）。
    ///
    /// 最初の欠測そのものは経過 0 秒なので `.wait` になる。`lastKind` は変えない。
    private mutating func missing(now: Date) -> [SessionAction] {
        let since = missingSince ?? now
        missingSince = since
        if now.timeIntervalSince(since) >= Tuning.unresponsiveSeconds {
            return [.stop(.pageUnresponsive)]
        }
        return [.wait]
    }

    /// B2: 完全な状態が取れたときの判定。順序がそのまま仕様。
    ///
    /// b1〜b3（停止）のいずれかが当たったら**返すのは `[.stop(理由)]` の 1 要素だけ**で、
    /// gate の操作も警告も付けない（内部状態も更新しない）。
    private mutating func apply(_ result: ProbeResult, meter: MeterSnapshot, now: Date) -> [SessionAction] {
        // 応答が戻ったので連続欠測は切れる。
        missingSince = nil

        // b1: 次の動画へ遷移した。`.ad` で id が違っても何もしない（表の「無視して継続」）。
        if result.kind == .main, result.id != firstID {
            return [.stop(.nextVideo)]
        }
        // b2: 最後まで再生した。
        if result.kind == .main, result.state == .ended {
            return [.stop(.ended)]
        }
        // b3: 本編再生中なのに全ゼロが続く = tap 故障か許可なし（決めた事項 #7）。
        if result.kind == .main, result.state == .playing,
           meter.consecutiveAllZeroSeconds >= Tuning.tapStallSeconds {
            return [.stop(meter.everNonZero ? .tapStalled : .permissionSuspected)]
        }

        // b4: gate の操作をちょうど 1 つ決める。
        let gateAction = gateActionFor(result)
        updateGateState(after: gateAction)
        var actions: [SessionAction] = [gateAction]

        // b5: 警告をこの順で足す（SSAI → 無音）。
        if let ssai = ssaiWarning(for: result) {
            actions.append(ssai)
        }
        if let silence = silenceWarning(meter: meter, now: now) {
            actions.append(silence)
        }

        // b6.
        lastKind = result.kind
        return actions
    }

    /// b4 の表。`.main playing` だけが直前の kind を見る（広告明けの巻き戻し。決めた事項 #4）。
    private func gateActionFor(_ result: ProbeResult) -> SessionAction {
        switch (result.kind, result.state) {
        case (.main, .playing):
            return lastKind == .ad ? .rewindThenOpenGate : .openGate
        case (.main, .paused):
            return .closeGateHold
        case (.ad, _):
            // state は問わない。広告が続いている間は閉じ直さない（捨てるのは 1 回だけ）。
            return lastKind == .ad ? .wait : .closeGateDiscard
        default:
            // 残るのは `.main` + `.loading` だけ（`.main` + `.ended` は b2 で返している）。
            return .wait
        }
    }

    /// b4 で出した指示にあわせて gate の内部状態を進める。
    private mutating func updateGateState(after action: SessionAction) {
        switch action {
        case .openGate, .rewindThenOpenGate:
            gateOpen = true
        case .closeGateDiscard, .closeGateHold:
            gateOpen = false
        default:
            // `.wait` は gate を動かさない。
            break
        }
    }

    /// SSAI 警告（決めた事項 #8）。1 セッションに 1 回だけ。
    ///
    /// `dur` が NaN / 無限のときは `isFinite` が false になるので出さない。
    ///
    /// **`len > 0` を要求する**（turn 10 の PLAN 訂正）: #8 の条件は `dur > len × 1.2` だけだが、
    /// `len == 0`（`vd.lengthSeconds` が `"0"`。ライブ以外でも稀に来る）だと `dur > 0` が必ず真になり、
    /// 普通の動画で毎回 SSAI 警告が出てしまう。#8 の「公称より長い」は公称が分かっている場合の話なので、
    /// 公称が 0 = 不明のときは警告しない。
    private mutating func ssaiWarning(for result: ProbeResult) -> SessionAction? {
        guard !didWarnSSAI,
              result.dur.isFinite,
              let len = result.len,
              len > 0,
              result.dur > len * Tuning.ssaiDurationRatio
        else {
            return nil
        }
        didWarnSSAI = true
        return .warn(Messages.ssaiWarning)
    }

    /// 無音警告（決めた事項 #6）。**b4 を適用した後の gate が開いている**ときだけ見る。
    ///
    /// 再警告の間隔は `>` で判定する（ちょうど `Tuning.silenceWarnIntervalSeconds` では出さない）。
    private mutating func silenceWarning(meter: MeterSnapshot, now: Date) -> SessionAction? {
        guard gateOpen, meter.consecutiveSilentSeconds >= Tuning.silenceWarnAfterSeconds else {
            return nil
        }
        if let last = lastSilenceWarnAt,
           now.timeIntervalSince(last) <= Tuning.silenceWarnIntervalSeconds {
            return nil
        }
        lastSilenceWarnAt = now
        return .warn(Messages.silenceWarning)
    }
}
