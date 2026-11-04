// ProbeJS.swift — Chrome のタブで走らせる JS 本文と、その戻り値のデコーダ。
//
// 断言 1: **JS が返すのは「裸の文字列 `none`」か「9 キーの JSON」だけ**。例外は外に出さない
// （IIFE 全体を try/catch で囲み、壊れたら `none` を返す）。`gone`（タブが見つからない）は
// JS ではなく AppleScript 側（`ChromeController` のタブ探索）が返す文字列。
//
// 断言 2: **JSON のキーは 9 個固定**（kind / state / id / cur / dur / live / title / playErr / len）。
// `ProbeResult` のプロパティ数・`CodingKeys.allCases.count` とこの 9 個は 1 対 1 で対応する。
// 追従先: キーを増減したら `ProbeResult`・`CodingKeys`・`ProbeResultTests`（キー数と JS 本文の
// 検査）の 3 箇所を同時に直す。テストが数のずれを検出する。
//
// 断言 3: **セレクタと秒数を JS に直書きしない**。`Tuning.adShowingSelector` /
// `Tuning.adResumeRewindSeconds` を Swift の文字列補間で埋める（Tuning.swift の「他のファイルは
// これらの数値を直書きしない」規約）。JS 側に別のセレクタを書き足さない。
//
// 根拠: `execute t javascript` はページワールドで走るので `window.ytInitialPlayerResponse` が見える。
// JS は `ScriptRunner` の `arguments`（= `on run argv`）でスクリプト本文の外から渡されるため、
// `'` と `"` のエスケープは不要。ただし保守の都合で本文は改行なしの 1 行に畳んでいる
// （`"""` + 行末 `\` の継続。次行の先頭空白もそのまま入るので継続行はインデントしない）。
// JS のテンプレートリテラル `${}` は Swift の補間 `\(...)` と混ざるので使わない。

import Foundation

// MARK: - JS 本文

/// タブの状態を 1 回だけ取る JS。戻り値は `none` か 9 キーの JSON 文字列。
///
/// 副作用: `v.paused && !v.ended` なら `v.play()` を呼ぶ（旧実装の挙動）。`play()` が返す
/// Promise の reject 名は `playErr` に入れるが、**reject を待つためにブロックはしない**ので、
/// 同期的に取れない場合は `null` になる（次の poll で拾える）。
public let probeJS = """
(function(){try{\
var v=document.querySelector('video');if(!v)return 'none';\
var kind=document.querySelector('\(Tuning.adShowingSelector)')?'ad':'main';\
var playErr=null;\
if(v.paused&&!v.ended){var p=v.play();if(p&&typeof p.catch==='function'){p.catch(function(e){playErr=(e&&e.name)?e.name:'PlayError';});}}\
var state=v.ended?'ended':(v.readyState<1?'loading':(v.paused?'paused':'playing'));\
var id=new URLSearchParams(location.search).get('v')||'-';\
var vd=window.ytInitialPlayerResponse&&window.ytInitialPlayerResponse.videoDetails;\
var dur=isFinite(v.duration)?v.duration:(v.duration===Infinity?'inf':'nan');\
var live=(vd&&(vd.isLive===true||vd.isUpcoming===true))||v.duration===Infinity;\
var title=(vd&&vd.title)?vd.title:document.title.replace(/ - YouTube$/,'');\
var len=vd?Number(vd.lengthSeconds):null;\
return JSON.stringify({kind:kind,state:state,id:id,cur:v.currentTime,dur:dur,live:!!live,title:title,len:len,playErr:playErr});\
}catch(e){return 'none';}})()
"""

/// 広告明けに本編を少し巻き戻す JS。video が無ければ何もしない。戻り値は `ok`。
///
/// 巻き戻し量は `Tuning.adResumeRewindSeconds`（直書き禁止）。
public let rewindJS = """
(function(){var v=document.querySelector('video');\
if(v)v.currentTime=Math.max(0,v.currentTime-\(Tuning.adResumeRewindSeconds));return 'ok';})()
"""

/// 本編の頭出し（`currentTime = 0`）をする JS。video が無ければ何もしない。戻り値は `ok`。
public let seekToStartJS = """
(function(){var v=document.querySelector('video');if(v)v.currentTime=0;return 'ok';})()
"""

// MARK: - デコード結果

/// 本編か広告か。`probeJS` の `kind` と 1 対 1。
public enum ProbeKind: String, Decodable, Sendable {
    case main
    case ad
}

/// 再生状態。`probeJS` の `state` と 1 対 1（判定の優先順は JS 側: ended → loading → paused → playing）。
public enum ProbeState: String, Decodable, Sendable {
    case playing
    case paused
    case ended
    case loading
}

/// `probeJS` が返す JSON の 9 キーに 1 対 1 で対応する値。
///
/// 断言: プロパティは 9 個ちょうど。増やすなら JS の `JSON.stringify` と `CodingKeys` も同時に直す。
///
/// 注意（`Equatable`）: `dur` は `Double.nan` になりうるので、NaN を含む 2 つの `ProbeResult` は
/// `==` が false になる（IEEE 754）。テストは構造体同体の比較ではなく `dur.isNaN` で見る。
public struct ProbeResult: Decodable, Equatable, Sendable {
    /// 本編 / 広告。
    public let kind: ProbeKind
    /// 再生状態。
    public let state: ProbeState
    /// `?v=` の動画 ID。取れなければ `-`。
    public let id: String
    /// 再生位置（秒）。
    public let cur: Double
    /// 尺（秒）。JSON が数値ならその値、`"inf"` なら `.infinity`、`"nan"` なら `.nan`。
    public let dur: Double
    /// ライブ / 配信予定か。**JSON の `live` をそのまま読む**（`dur` が無限だから true、のような
    /// Swift 側の推論は入れない。その判定は JS 側の契約）。
    public let live: Bool
    /// 動画タイトル。取れなければ `nil`。
    public let title: String?
    /// `videoDetails.lengthSeconds`（秒）。非公開動画などで取れなければ `nil`。
    public let len: Double?
    /// `v.play()` が reject したときの `name`。同期的に取れなければ `nil`。
    public let playErr: String?

    /// `probeJS` の `JSON.stringify` のキーと 1 対 1。`allCases.count == 9` をテストで固定する。
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case state
        case id
        case cur
        case dur
        case live
        case title
        case len
        case playErr
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ProbeKind.self, forKey: .kind)
        state = try container.decode(ProbeState.self, forKey: .state)
        id = try container.decode(String.self, forKey: .id)
        cur = try container.decode(Double.self, forKey: .cur)
        live = try container.decode(Bool.self, forKey: .live)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        len = try container.decodeIfPresent(Double.self, forKey: .len)
        playErr = try container.decodeIfPresent(String.self, forKey: .playErr)

        // `dur` だけは数値と文字列の両方を受ける（JSON に Infinity / NaN のリテラルが無いため）。
        // `"inf"` / `"nan"` 以外の文字列は契約違反なのでデコード失敗にする（= `parseProbe` が `.none`）。
        if let number = try? container.decode(Double.self, forKey: .dur) {
            dur = number
        } else {
            let text = try container.decode(String.self, forKey: .dur)
            switch text {
            case "inf":
                dur = .infinity
            case "nan":
                dur = .nan
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .dur,
                    in: container,
                    debugDescription: "dur は数値か \"inf\" か \"nan\" のいずれか（実際: \(text)）"
                )
            }
        }
    }
}

/// `probeJS`（と AppleScript 側のタブ探索）の戻り値を分類した結果。
public enum ProbeOutcome: Sendable {
    /// video が無い / 応答が空 / JSON が壊れている（= 今回は何も分からない）。
    case none
    /// タブが見つからない（AppleScript が `gone` を返した）。
    case gone
    /// 9 キーの JSON が読めた。
    case result(ProbeResult)
}

/// `probeJS` の生の戻り値を `ProbeOutcome` にする。
///
/// 断言: **throw しない**。JSON が壊れていても、未知の `kind` / `state` でも、必須キーが
/// 欠けていても `.none` に落とす（poll のループを例外で止めないため）。
///
/// - Parameter raw: `osascript` の標準出力（trim 前でよい）。応答が無いときは `nil`。
/// - Returns: `nil` / 空 / `none` → `.none`、`gone` → `.gone`、デコードできた JSON → `.result`。
public func parseProbe(_ raw: String?) -> ProbeOutcome {
    guard let raw else { return .none }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed {
    case "", "none":
        return .none
    case "gone":
        return .gone
    default:
        break
    }
    guard let data = trimmed.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(ProbeResult.self, from: data)
    else {
        return .none
    }
    return .result(decoded)
}
