// OutputPath.swift — 出力ファイル名の決め方（タイトルの正規化・既定名・連番の原子的確保）。
//
// 役割は 4 つだけ:
//   - `sanitizeFileName(_:)`  動画タイトル → ファイル名として安全な文字列（ダメなら nil）
//   - `sanitizeForTerminal(_:)` ページ由来の文字列 → 端末の 1 行に埋め込める文字列（F4 / E21）
//   - `defaultBaseName(now:)` タイトルが取れないときの既定名 `rec-yyyyMMdd-HHmmss`
//   - `reserveUniquePath(directory:baseName:ext:)` `name.m4a` / `name-2.m4a` … を O_EXCL で確保
//
// 「外から来た文字列の正規化」を 2 つともここに置くのは、判定（禁止スカラ・UTF-8 バイト切り）を
// 1 か所で見比べられるようにするため。**2 つは契約が違う**（下の各関数のコメント）ので共用しない。
//
// `-o` で渡されたパスを「親ディレクトリ / baseName / 拡張子」に分解するのは T9 の仕事で、
// ここは分解済みの 3 つを受け取るだけ。
//
// 追従先（PLAN「追従先チェックリスト」）: 上限（UTF-8 200 バイト / 連番 1000 / 端末の 1 行 64 バイト）や
// 置換文字を変えたら `Tests/RecCoreTests/OutputPathTests.swift` を直す（200 バイトと連番は
// README「出力ファイル名」にも出る。64 バイトは警告 1 行の中なので README には出ない）。

import Darwin
import Foundation

// MARK: - 定数

/// ファイル名の上限（UTF-8 バイト長）。APFS の 255 バイトより十分内側に取る。
private let fileNameByteLimit = 200

/// 端末の 1 行に埋め込むページ由来の文字列の上限（UTF-8 バイト長）。
///
/// `playErr` の `name`（`NotAllowedError` 等）が入る場所なので短くてよい。長い文字列で
/// 画面を埋め尽くされないように 64 バイトで切る。
private let terminalFieldByteLimit = 64

/// 連番の試行上限。`name` / `name-2` … `name-1000` まで試す。
private let uniqueSuffixLimit = 1000

/// 禁止文字の置換先。
private let replacementScalar: Unicode.Scalar = "_"

// MARK: - 共用の補助

/// UTF-8 で `limit` バイトに収まるところまで `Character` 単位で足し直す。
///
/// `Character`（grapheme cluster）単位なので、**途中で切れたマルチバイト列や基底文字から
/// 切り離された結合文字が出ない**。1 文字が `limit` より大きい（結合文字を大量に重ねた
/// grapheme cluster）場合は空文字列になる。
private func truncatingUTF8(_ s: String, limit: Int) -> String {
    guard s.utf8.count > limit else { return s }
    var truncated = ""
    var used = 0
    for character in s {
        let width = String(character).utf8.count
        if used + width > limit { break }
        truncated.append(character)
        used += width
    }
    return truncated
}

// MARK: - タイトル → ファイル名

/// ファイル名に入れてはいけないスカラか。
///
/// - `/` はパス区切り、`:` は Finder / HFS 由来のパス区切りなので落とす。
/// - 制御文字は Unicode の一般カテゴリで判定する。`Cc`（C0 / C1。`\0` / `\u{1}` / `\u{7f}` /
///   `\u{85}` NEL）と `Zl`（`\u{2028}` LINE SEPARATOR）・`Zp`（`\u{2029}`）が対象。
/// - `Cf`（書式制御）は**含めない**: ZWJ（U+200D）を落とすと絵文字の連結が壊れ、
///   YouTube のタイトルにある絵文字が `_` に分解されてしまう（PLAN の契約は C0 / C1 と `\u{2028}`）。
private func isDisallowedInFileName(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "/" || scalar == ":" { return true }
    switch scalar.properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator:
        return true
    default:
        return false
    }
}

/// 動画タイトルからファイル名（拡張子なし・ディレクトリ成分なし）を作る。
///
/// 処理順:
///   1. `/` `:` `\0` と C0 / C1 制御文字を `_` に置き換える
///   2. 先頭の `.` を落とす（隠しファイルにしない）
///   3. 末尾の空白とピリオドを落とす
///   4. NFC 正規化する
///   5. UTF-8 200 バイトで切る（Character 境界で切るので結合文字・マルチバイト文字を割らない）
///   6. 切った末尾に出た空白とピリオドをもう一度落とす
///
/// - Returns: 残るものが無ければ `nil`（呼び出し側は `defaultBaseName(now:)` に落とす）。
public func sanitizeFileName(_ title: String) -> String? {
    // 1. 禁止文字の置換。制御文字は結合文字ではないのでスカラ単位で触っても
    //    grapheme cluster を壊さない。
    var scalars = String.UnicodeScalarView()
    for scalar in title.unicodeScalars {
        scalars.append(isDisallowedInFileName(scalar) ? replacementScalar : scalar)
    }
    var work = String(scalars)

    // 2. 先頭の `.` を落とす。`"..."` のように全部ピリオドなら空になる。
    while work.hasPrefix(".") { work.removeFirst() }

    // 3. 末尾の空白とピリオドを落とす。
    while let last = work.last, last == "." || last.isWhitespace { work.removeLast() }

    // 4. NFC 正規化（NFD の「ガ」= U+30AB U+3099 を U+30AC の 1 文字にする）。
    work = work.precomposedStringWithCanonicalMapping

    // 5. UTF-8 200 バイトで切る。Character 単位で足していくので、途中で切れたマルチバイト列や
    //    基底文字から切り離された結合文字が出ない。
    if work.utf8.count > fileNameByteLimit {
        work = truncatingUTF8(work, limit: fileNameByteLimit)

        // 6. 切った末尾が空白やピリオドになることがある（`"…a ."` のように 200 バイト目の直前が
        //    空白 / ピリオドの素材）。3. と同じ条件でもう一度落とす。全部落ちたら下で nil になる。
        while let last = work.last, last == "." || last.isWhitespace { work.removeLast() }
    }

    return work.isEmpty ? nil : work
}

// MARK: - ページ由来の文字列 → 端末の 1 行

/// 端末に出す 1 行に埋め込んではいけないスカラか。
///
/// `isDisallowedInFileName` と判定が 2 つ違う:
///   - **`Cf`（書式制御）も落とす**。ファイル名では ZWJ（U+200D）を残して絵文字の連結を守る
///     （T3 turn 5 の訂正）が、端末に出す行では RLO / LRO（U+202E / U+202D）で**表示の向きを
///     偽装される**ほうが害が大きい。ここに来るのは `playErr` の `name` で、絵文字は想定しない
///   - **`/` `:` は落とさない**。パスの意味を持たない行なので無害で、消すと原文が読めなくなる
///
/// `Cc`（C0 / C1）を落とすことで `\n`（偽の行の注入）・`\r`（行の上書き）・`\u{1B}`（ANSI /
/// OSC エスケープ）・`\u{07}`（BEL）がまとめて `_` になる。
private func isDisallowedInTerminal(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator:
        return true
    default:
        return false
    }
}

/// ページが自由に決められる文字列を、端末の 1 行に埋め込める形にする（F4 / E21）。
///
/// `playErr`（`HTMLMediaElement.play()` の reject の `name`）はページの JS が上書きできるので
/// **任意の文字列**が来る。そのまま stderr の 1 行に埋めると、改行で偽の「保存先: …」行を作ったり、
/// ESC で OSC / ANSI を注入して端末のタイトルを書き換えたりできる。**JS 側では守れない**
/// （ページが `JSON.stringify` の前に何でも仕込める）ので、Swift 側のここで必ず通す。
///
/// 処理順:
///   1. `Cc` / `Cf` / `Zl` / `Zp` を `_` に置き換える
///   2. UTF-8 64 バイトで切る（`Character` 境界なので結合文字・マルチバイト文字を割らない）
///
/// 空文字列はそのまま空文字列（`nil` に落とさない。呼び出し側は「名前が取れない」ことを
/// 区別せず、probe が `PlayError` を入れてくれる契約）。
///
/// **ファイル名には使わない**（`savedTo` が出すパスは `sanitizeFileName` の契約のまま。
/// `Cf` の扱いが逆なので混ぜると絵文字のタイトルが壊れる）。
public func sanitizeForTerminal(_ s: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        scalars.append(isDisallowedInTerminal(scalar) ? replacementScalar : scalar)
    }
    return truncatingUTF8(String(scalars), limit: terminalFieldByteLimit)
}

// MARK: - 既定のファイル名

/// タイトルが取れないときの既定名。`rec-yyyyMMdd-HHmmss`（例 `rec-20261104-193012`）。
///
/// ローカルタイムゾーン。`locale` は `en_US_POSIX` に固定する（和暦などのカレンダー設定で
/// 桁数や数字が変わらないようにする）。
public func defaultBaseName(now: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "rec-" + formatter.string(from: now)
}

// MARK: - 連番の原子的確保

/// `name.m4a` を確保する。既にあれば `name-2.m4a` → `name-3.m4a` … と進める。
///
/// 確保は `open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)` で行う。つまり「存在確認してから作る」
/// ではなく「作れたら勝ち」なので、同じ `baseName` を複数スレッド / 複数プロセスが同時に要求しても
/// 返る URL は必ず別になる（ロックもカウンタも持たない）。作れた fd はすぐ閉じ、空ファイルを
/// 予約済みの印として残す。実際の書き込みは `AudioFileWriter` が同じパスを開き直して行う。
///
/// - Parameters:
///   - directory: 作る先のディレクトリ。存在しなければ `ENOENT` でエラーになる。
///   - baseName: 拡張子を含まない名前。`sanitizeFileName(_:)` か `defaultBaseName(now:)` の結果。
///   - ext: ドットなしの拡張子（`"m4a"`）。空文字列なら拡張子を付けない。
/// - Throws: `EEXIST` 以外の `errno` と、連番が `uniqueSuffixLimit` まで埋まっていた場合に
///   `RecError(code: .outputUnavailable, ...)`。
public func reserveUniquePath(directory: URL, baseName: String, ext: String = "m4a") throws -> URL {
    for attempt in 1...uniqueSuffixLimit {
        // 1 回目は連番なし、2 回目以降は `-2` / `-3` …（拡張子の手前に入る）。
        let stem = attempt == 1 ? baseName : "\(baseName)-\(attempt)"
        let fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
        let url = directory.appendingPathComponent(fileName)
        let path = url.path

        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        if fd >= 0 {
            close(fd)
            return url
        }

        let code = errno
        // 誰かに先を越された（= 既にある）ときだけ次の連番へ。
        if code == EEXIST { continue }
        // それ以外は全部出力不可（EACCES / EROFS / ENOENT / ENOSPC / 想定外の errno も同じ扱い）。
        throw RecError(code: .outputUnavailable,
                       message: "cannot create \(path): \(String(cString: strerror(code))) (errno \(code))")
    }

    throw RecError(code: .outputUnavailable,
                   message: "cannot create a unique file for \(baseName) in "
                       + "\(directory.path): tried \(uniqueSuffixLimit) names")
}
