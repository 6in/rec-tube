// CLI.swift — コマンドラインの解釈。**ここは何も実行しない**（純粋関数 + 文字列）。
//
// 役割分担:
//   - 引数 → `Options`（このファイル）
//   - `Options` → 実際の録音（`Sources/rec/main.swift` が `RecordingSession` を組む）
//   - `exit()` を呼ぶのは `Sources/rec/main.swift` だけ（PLAN P1）
//
// 追従先（PLAN「追従先チェックリスト」の「CLI オプションを足す」行）: ここに引数を足したら
// `usageText`、README「使い方」、`Tests/RecCoreTests/CLITests.swift` を同じターンで直す
// （`rg -c -- '--ad-guard' Sources/RecCore/CLI.swift README.md` が両方 ≥ 1 になること）。
//
// 断言（この型の契約）:
//   - 引数が不正なら**必ず** `RecError(code: .usage, ...)` を throw する（他の code は返さない）
//   - `message` には必ず `usageText` が付く（人が次に何をすればよいか分かるように）
//   - モードの指定が複数あったら**最後に来たものが勝つ**（旧実装 `git show main:rec.swift` と同じ）

import Foundation

/// 使い方（`--help` と usage エラーの両方で出す本文）。
public let usageText = """
rec — macOS の音声を m4a に録音する

使い方:
  rec                            システム全体の音を録音（Ctrl-C で停止）
  rec --app <バンドルID>         バンドル ID 前方一致のプロセスだけ録音
  rec --url <URL>                Chrome で開いて本編だけ録音（再生終了で自動停止）
  rec --list                     音声を扱っているプロセスの一覧

オプション:
  -o <パス>                      出力先（既定: rec-<日時>.m4a。同名があれば -2 / -3 … を付ける）
  --ad-guard <秒>                広告ガードの遅延（既定 1.0、範囲 0〜10）。--url のときだけ効く

--url には Chrome の「表示 > 開発/管理 > Apple Events からの JavaScript を許可」が必要。
"""

/// 解釈済みの引数。
public struct Options: Sendable, Equatable {
    /// 何をするか。
    public enum Mode: Sendable, Equatable {
        /// `--list`: 音声を扱っているプロセスを並べて終わる（録音しない）。
        case list
        /// 引数なし: システム全体を録音する。
        case system
        /// `--app X`: バンドル ID が `X` で始まるプロセスだけを録音する。
        case app(String)
        /// `--url U`: Chrome で `U` を開いて本編だけを録音する。
        case url(String)
    }

    public let mode: Mode
    /// `-o` の値（未指定なら nil）。分解は `Sources/rec/main.swift` の仕事。
    public let output: String?
    /// 広告ガードの秒数。既定は `Tuning.adGuardSeconds`。
    public let adGuard: Double

    public init(mode: Mode, output: String? = nil, adGuard: Double = Tuning.adGuardSeconds) {
        self.mode = mode
        self.output = output
        self.adGuard = adGuard
    }
}

/// 引数を解釈する。
///
/// - Parameter args: **プログラム名を除いた**引数（`Array(CommandLine.arguments.dropFirst())`）
/// - Throws: `RecError(code: .usage, ...)` のみ
public func parseArguments(_ args: [String]) throws -> Options {
    var mode = Options.Mode.system
    var output: String?
    var adGuard = Tuning.adGuardSeconds

    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--list":
            mode = .list
        case "--app":
            guard let value = it.next() else { throw usageError("--app にバンドル ID がありません。") }
            mode = .app(value)
        case "--url":
            guard let value = it.next() else { throw usageError("--url に URL がありません。") }
            try validate(url: value)
            mode = .url(value)
        case "-o":
            guard let value = it.next() else { throw usageError("-o に出力先がありません。") }
            output = value
        case "--ad-guard":
            guard let value = it.next() else { throw usageError("--ad-guard に秒数がありません。") }
            guard let seconds = Double(value), seconds.isFinite else {
                throw usageError("--ad-guard の値が数値ではありません: \(value)")
            }
            guard Tuning.adGuardRange.contains(seconds) else {
                throw usageError("--ad-guard は \(Tuning.adGuardRange.lowerBound)〜"
                    + "\(Tuning.adGuardRange.upperBound) の範囲で指定してください: \(value)")
            }
            adGuard = seconds
        default:
            throw usageError("不明な引数: \(arg)")
        }
    }

    return Options(mode: mode, output: output, adGuard: adGuard)
}

// MARK: - 補助

/// `--url` の値を検査する。
///
/// 通すのは「`URL(string:)` で解釈でき、scheme が `http` / `https` / `file`、
/// http(s) なら host が空でない」もの（決めた事項 #3 の `.usage` 行）。
private func validate(url value: String) throws {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
        throw usageError("URL として解釈できません: \(value)")
    }
    switch scheme {
    case "http", "https":
        guard let host = url.host, !host.isEmpty else {
            throw usageError("URL にホストがありません: \(value)")
        }
    case "file":
        break
    default:
        throw usageError("URL の scheme は http / https / file のいずれかにしてください: \(value)")
    }
}

/// 引数エラー。**`message` には必ず `usageText` を付ける**（契約）。
private func usageError(_ detail: String) -> RecError {
    RecError(code: .usage, message: detail + "\n\n" + usageText)
}
