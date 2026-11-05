// ProbeResultTests.swift — `parseProbe` / `ProbeResult` / JS 本文の契約を固定するテスト。
//
// Chrome にも `osascript` にも触らない（`probeJS` は文字列として検査し、JSON は手で書く）。
//
// 断言（ここで固定していること）:
//  1. `parseProbe` は throw しない。壊れた JSON・未知の enum 値・必須キー欠落はすべて `.none`。
//  2. `dur` は数値 / `"inf"` / `"nan"` の 3 通りだけを受け、それ以外の文字列はデコード失敗。
//  3. `live` は JSON の `live` をそのまま読む（`dur` が無限でも Swift 側で推論しない）。
//  4. `CodingKeys.allCases.count == 9` かつ `probeJS` の `JSON.stringify({...})` のキー集合が
//     `CodingKeys` の rawValue 集合と**完全一致**する（部分文字列照合ではなく集合比較なので、
//     JS 側とデコーダ側のキーの過不足を両方向で検出する）。
//  5. セレクタと巻き戻し秒は `Tuning` 由来（JS 直書きの禁止）。

import Foundation
import Testing

@testable import RecCore

@Suite("ProbeResult")
struct ProbeResultTests {
    // MARK: - ヘルパ（`ProbeOutcome` は Equatable ではないのでパターンマッチで見る）

    private func isNone(_ outcome: ProbeOutcome) -> Bool {
        if case .none = outcome { return true }
        return false
    }

    private func isGone(_ outcome: ProbeOutcome) -> Bool {
        if case .gone = outcome { return true }
        return false
    }

    private func decoded(_ outcome: ProbeOutcome) -> ProbeResult? {
        if case let .result(value) = outcome { return value }
        return nil
    }

    // MARK: - 1. 文字列の分類

    @Test("raw が nil なら .none")
    func nilRawIsNone() {
        #expect(isNone(parseProbe(nil)))
    }

    @Test("none は .none（前後の改行・空白を無視する）")
    func noneStringIsNone() {
        #expect(isNone(parseProbe("none")))
        #expect(isNone(parseProbe("none\n")))
        #expect(isNone(parseProbe("  none  \n")))
    }

    @Test("gone は .gone（前後の改行・空白を無視する）")
    func goneStringIsGone() {
        #expect(isGone(parseProbe("gone")))
        #expect(isGone(parseProbe("gone\n")))
        #expect(isGone(parseProbe("  gone  \n")))
    }

    @Test("空文字列・空白だけは .none")
    func emptyStringIsNone() {
        #expect(isNone(parseProbe("")))
        #expect(isNone(parseProbe("   \n")))
    }

    // MARK: - 2. デコード失敗はすべて .none（throw しない）

    @Test("壊れた JSON は .none")
    func brokenJSONIsNone() {
        #expect(isNone(parseProbe("{kind:")))
        #expect(isNone(parseProbe("{")))
        #expect(isNone(parseProbe("ok")))
    }

    @Test("未知の kind は .none")
    func unknownKindIsNone() {
        let json = #"{"kind":"movie","state":"playing","id":"abc","cur":1,"dur":2,"live":false,"title":"t","len":2,"playErr":null}"#
        #expect(isNone(parseProbe(json)))
    }

    @Test("未知の state は .none")
    func unknownStateIsNone() {
        let json = #"{"kind":"main","state":"buffering","id":"abc","cur":1,"dur":2,"live":false,"title":"t","len":2,"playErr":null}"#
        #expect(isNone(parseProbe(json)))
    }

    @Test("必須キー（id）が無ければ .none")
    func missingRequiredKeyIsNone() {
        let json = #"{"kind":"main","state":"playing","cur":1,"dur":2,"live":false,"title":"t","len":2,"playErr":null}"#
        #expect(isNone(parseProbe(json)))
    }

    // MARK: - 3. 9 キーが全部埋まった JSON

    @Test("main / playing の完全な JSON は各フィールドが期待どおり")
    func fullJSONDecodesEveryField() throws {
        let json = #"""
        {"kind":"main","state":"playing","id":"dQw4w9WgXcQ","cur":12.5,"dur":213.5,"live":false,"title":"Never Gonna Give You Up","len":213,"playErr":null}
        """#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.kind == .main)
        #expect(probe.state == .playing)
        #expect(probe.id == "dQw4w9WgXcQ")
        #expect(probe.cur == 12.5)
        #expect(probe.dur == 213.5)
        #expect(probe.live == false)
        #expect(probe.title == "Never Gonna Give You Up")
        #expect(probe.len == 213)
        #expect(probe.playErr == nil)
    }

    @Test("ad / loading も読める（kind と state の残りの値）")
    func adAndLoadingDecode() throws {
        let json = #"{"kind":"ad","state":"loading","id":"-","cur":0,"dur":15,"live":false,"title":null,"len":null,"playErr":null}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.kind == .ad)
        #expect(probe.state == .loading)
        #expect(probe.id == "-")
    }

    // MARK: - 4. dur の 3 通り

    @Test("dur が数値ならその値")
    func durAsNumber() throws {
        let json = #"{"kind":"main","state":"playing","id":"a","cur":1,"dur":213.5,"live":false,"title":"t","len":213,"playErr":null}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.dur == 213.5)
        #expect(probe.dur.isInfinite == false)
        #expect(probe.dur.isNaN == false)
    }

    @Test("dur が \"inf\" なら無限、同じ JSON の live:true はそのまま true として読む")
    func durInfiniteAndLiveComesFromJSON() throws {
        let json = #"{"kind":"main","state":"playing","id":"live1","cur":42,"dur":"inf","live":true,"title":"配信中","len":null,"playErr":null}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.dur.isInfinite == true)
        // `live` は JS 側の判定をそのまま読む契約（Swift 側で dur から推論しない）。
        #expect(probe.live == true)
    }

    @Test("dur が \"inf\" でも live:false なら false（Swift 側で推論しない）")
    func infiniteDurDoesNotImplyLive() throws {
        let json = #"{"kind":"main","state":"playing","id":"live2","cur":42,"dur":"inf","live":false,"title":"t","len":null,"playErr":null}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.dur.isInfinite == true)
        #expect(probe.live == false)
    }

    @Test("dur が \"nan\" なら NaN")
    func durNaN() throws {
        let json = #"{"kind":"main","state":"loading","id":"a","cur":0,"dur":"nan","live":false,"title":"t","len":null,"playErr":null}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.dur.isNaN == true)
    }

    @Test("dur が未知の文字列なら .none")
    func durUnknownStringIsNone() {
        let json = #"{"kind":"main","state":"playing","id":"a","cur":1,"dur":"abc","live":false,"title":"t","len":null,"playErr":null}"#
        #expect(isNone(parseProbe(json)))
    }

    // MARK: - 5. 省略できるキー（title / len / playErr）

    @Test("len が null なら nil")
    func lenNullIsNil() throws {
        let json = #"{"kind":"main","state":"playing","id":"a","cur":1,"dur":2,"live":false,"title":"t","len":null,"playErr":null}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.len == nil)
    }

    @Test("len のキー自体が無くてもデコードできる（非公開動画）")
    func lenKeyMissingIsNil() throws {
        let json = #"{"kind":"main","state":"playing","id":"a","cur":1,"dur":2,"live":false,"title":"t","playErr":null}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.len == nil)
    }

    @Test("title が null なら nil、playErr は reject の name をそのまま持つ")
    func titleNullAndPlayError() throws {
        let json = #"{"kind":"main","state":"paused","id":"a","cur":0,"dur":2,"live":false,"title":null,"len":2,"playErr":"NotAllowedError"}"#
        let probe = try #require(decoded(parseProbe(json)))
        #expect(probe.title == nil)
        #expect(probe.state == .paused)
        #expect(probe.playErr == "NotAllowedError")
    }

    // MARK: - 6. キー数のずれ検出（JS ↔ デコーダ）

    @Test("CodingKeys はちょうど 9 個")
    func codingKeysCountIsNine() {
        #expect(ProbeResult.CodingKeys.allCases.count == 9)
    }

    /// `probeJS` の `JSON.stringify({...})` のリテラルから `キー名:` の並びを抜き出す。
    ///
    /// リテラルの形が変わって読めなくなったら `nil`（テストを落とすため。黙って通さない）。
    /// 重複キーを検出できるよう `Set` ではなく出現順の配列で返す。
    private func probeJSStringifyKeys() -> [String]? {
        let marker = "JSON.stringify({"
        guard let open = probeJS.range(of: marker),
              let close = probeJS.range(of: "})", range: open.upperBound ..< probeJS.endIndex)
        else { return nil }

        let body = probeJS[open.upperBound ..< close.lowerBound]
        guard !body.isEmpty else { return nil }

        var keys: [String] = []
        // 現在のリテラルは値にカンマを含まない（`kind:kind,…,playErr:playErr`）。
        for pair in body.split(separator: ",") {
            guard let colon = pair.firstIndex(of: ":") else { return nil }
            let key = pair[pair.startIndex ..< colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            keys.append(key)
        }
        return keys.isEmpty ? nil : keys
    }

    @Test("probeJS の JSON.stringify のキー集合は CodingKeys と完全一致する（過不足の両方を検出）")
    func probeJSKeysMatchCodingKeysExactly() throws {
        let keys = try #require(probeJSStringifyKeys(),
                                "probeJS の JSON.stringify({...}) からキー名を抜き出せなかった")
        let expected = Set(ProbeResult.CodingKeys.allCases.map(\.rawValue))

        // 重複キーが Set に潰されていないこと（JS 側で同じキーを 2 回書いた場合の検出）。
        #expect(keys.count == Set(keys).count)
        #expect(Set(keys) == expected)
    }

    // MARK: - 7. 調整値の直書き禁止

    @Test("probeJS は Tuning.adShowingSelector を埋め込んでいる")
    func probeJSUsesTuningSelector() {
        #expect(probeJS.contains(Tuning.adShowingSelector))
    }

    @Test("rewindJS は Tuning.adResumeRewindSeconds を埋め込んでいる")
    func rewindJSUsesTuningRewindSeconds() {
        #expect(rewindJS.contains("\(Tuning.adResumeRewindSeconds)"))
    }

    @Test("holdAtStartJS は一時停止してから currentTime を 0 にして ok を返す")
    func holdAtStartJSPausesAndSeeksToZero() {
        #expect(holdAtStartJS.contains("v.pause();v.currentTime=0"))
        #expect(holdAtStartJS.contains("'ok'"))
    }

    @Test("playJS は play() を呼び、reject を外へ漏らさず ok を返す")
    func playJSPlays() {
        #expect(playJS.contains("v.play()"))
        #expect(playJS.contains("p.catch("))
        #expect(playJS.contains("'ok'"))
    }
}
