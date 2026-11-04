# PLAN — rec-cli-hardening

- 作成: 2026-11-04 / gsd-lite-plan（turn 2）
- 入力: REQUIREMENTS.md / DECISIONS.md / RESEARCH.md（§9 の要約 → §7 の落とし穴を完了基準に写した）
- 対象リポジトリ: `.`（in-repo 形）。`CLAUDE.md` / `AGENTS.md` は無い（`ls` で確認）

## 検証コマンド

impl の各ターンがテストに使うコマンド（リポジトリのルートで実行。T1 が作る）:

```bash
scripts/build.sh                 # DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer を script 内で export して swift build（引数は swift build にそのまま渡す）
scripts/test.sh                  # 同じ DEVELOPER_DIR で swift test（引数は swift test にそのまま渡す。例: scripts/test.sh --filter DelayLine）
```

**PLAN 訂正（turn 3 / T1 の実測）**: 無人ターンから `scripts/*.sh` は実行できない（`Bash(scripts/:*)` /
`Bash(bash scripts/:*)` の prefix ルールは「完全一致」か「prefix + 空白」でしか当たらず、`scripts/build.sh` という
形に当たらない。`bash` 単体も allowlist に無い）。**無人ターン（impl / verify）は等価な素のコマンドを使う**:

```bash
swift build                      # = scripts/build.sh（DEVELOPER_DIR は .claude/settings.json の env で設定済み）
swift build -c release           # = scripts/build.sh -c release
swift test                       # = scripts/test.sh
swift test --filter <name>       # = scripts/test.sh --filter <name>
```

scripts 側は人間と README 向けに残す（中身は上と同じ）。無人ターンから scripts を直に回したい場合は
`.claude/settings.json` の allow に `Bash(scripts/build.sh:*)` / `Bash(scripts/test.sh:*)` /
`Bash(scripts/final-check.sh:*)`（verify スクリプトも 1 本ずつ）を**完全なファイル名で**足す必要がある。
`final-check.sh` の中身は turn 3 で 1 ステップずつ素のコマンドで実行して全て green を確認した

- 環境の初期化（テストの前に毎回）: なし（`scripts/final-check.sh` だけが `.build` を消して回す）
- 最終判定（クリーンな状態から全検査。verify と T11 が使う）: `scripts/final-check.sh`
  （`rm -rf .build` → `swift build` debug と `-c release` → `otool -s __TEXT __info_plist` / `otool -P` で
  `NSAudioCaptureUsageDescription` を両ビルドで確認 → `swift test` → 下の「追従先チェックリスト」の `rg` 検査 →
  `.build/debug/rec --bogus` が exit 1 / `.build/debug/rec --list` が exit 0。実機録音は含めない）
- 実機検証（verify が使う。T10 / T11 が作る。TCC とオートメーションの許可が前提）:
  `scripts/verify-permission.sh` → `scripts/verify-signals.sh` → `scripts/verify-adtest.sh` →
  `scripts/verify-youtube.sh [URL]` → `scripts/verify-helper-restart.sh [URL]` → `scripts/verify-longrun.sh [分]`
- allowlist: `.claude/settings.json` は Claude Code が保護していて無人ターンからは編集できない（plan ターンで Edit が権限拒否）。
  「決めた事項」#1 の項目を**ユーザーが追加する**（BLOCKED.md に貼り付け用の一覧）。impl はそれが入っている前提で始まる。
  それでも承認待ちで止まる形が出たら、PROGRESS の「想定外」に**コマンドの先頭 2 語**を書く。
  `git -C <path> …` の形は `Bash(git <sub>:*)` に当たらないので、リポジトリのルートから `git status` 等の素の形で呼ぶ
- シェルの作法: 1 コール 1 コマンド。`&&` / `$(...)` / 先頭の `FOO=1` は使わない。`DEVELOPER_DIR` は scripts 内で export
  する（直接 swift を呼ぶなら `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift ...` の形も allow 済み）

## 追従先チェックリスト

| 変更の種類 | 直す場所 | 確かめ方 |
|---|---|---|
| 終了コード（`ExitCode`）を足す・変える | `Sources/RecCore/ExitCode.swift` の enum、`Tests/RecCoreTests/ExitCodeTests.swift`、README「終了コード」表、この PLAN の「決めた事項」#3 | enum の case 数と README の表の行数が一致（`rg -c '^case ' Sources/RecCore/ExitCode.swift` と `rg -c '^\| [0-9]' README.md` の該当表） |
| 停止理由（`StopReason`）を足す | `ExitCode.swift` の対応表（switch を exhaustive にし default を書かない）、`SessionPolicy` のテスト、README「既知の制約」 | `swift build` が exhaustive エラーで教える。README に理由名の説明が 1 行ある |
| CLI オプションを足す（`--ad-guard` 等） | `Sources/RecCore/CLI.swift` の parse と usage 文字列、README「使い方」 | `rg -c -- '--ad-guard' Sources/RecCore/CLI.swift README.md` が両方 ≥ 1 |
| 調整値（秒数・dBFS）を変える | `Sources/RecCore/Tuning.swift` に集約。README の該当数値、この PLAN の #4〜#8 | `rg -n 'Tuning\.' Sources` で参照が Tuning 経由だけ。README の数値は `rg -n '秒|dBFS' README.md` で Tuning と目視一致 |
| probe JSON のフィールドを足す | `Sources/RecCore/ProbeJS.swift`（JS 文字列と `ProbeResult` デコーダ）、`Tests/Fixtures/adtest.html`（同じ DOM を提供）、`ProbeResultTests` | デコーダのプロパティ数と JS の `JSON.stringify` のキー数が一致（テストで固定） |
| HAL 呼び出しを足す | `AudioHAL` protocol、`CoreAudioHAL`（実装）、`FakeHAL`（テスト）、`TapRecorder.stop()` の対応する destroy / remove | `FakeHAL` の「create と destroy の回数が一致」テスト（T5）が green |
| 許可の種類・案内文 | `Sources/RecCore/Messages.swift`、README「許可」節（3 種）、`scripts/verify-permission.sh` | `rg -c 'NSAudioCaptureUsageDescription|オートメーション|Apple Events' README.md` ≥ 3 |
| 検証スクリプトを足す | README「検証」節の一覧、この PLAN「検証コマンド」の実機検証行 | `ls scripts/verify-*.sh` の本数と README の一覧行数が一致 |
| rec.swift の行番号参照（RESEARCH / PLAN の `rec.swift:NN`） | 履歴参照（`git show main:rec.swift`）として扱い、新コードのコメントに写さない | `rg -n 'rec\.swift:[0-9]' Sources README.md` が 0 |
| 件数を書いた文書 | README の「許可 3 種」「終了コード N 個」「検証スクリプト N 本」 | 上記 3 行の `rg` が通る |

## Tasks

- [x] T1: SwiftPM 雛形・ビルド/テストスクリプト・Info.plist 埋め込み（rec.swift を Sources へ移す）
  - 完了基準:
    - `Package.swift`（swift-tools-version 6.0 以上、`platforms: [.macOS(.v26)]`、ダメなら `.macOS("26.0")`、
      `swiftLanguageModes: [.v6]`）。target は `RecCore`（library, `Sources/RecCore`）、`rec`（executableTarget,
      `Sources/rec`、`exclude: ["Info.plist"]`、`linkerSettings: [.unsafeFlags(["-Xlinker","-sectcreate","-Xlinker","__TEXT","-Xlinker","__info_plist","-Xlinker","Sources/rec/Info.plist"])]`）、
      `rec-probe`（executableTarget, `Sources/rec-probe`、T2 が中身を書く。T1 では `print("probe")` だけ）、
      `RecCoreTests`（testTarget, Swift Testing, `RecCore` に依存。実行ファイルには依存しない）
      （根拠: RESEARCH §4, §5.7 Peekaboo、`~/workspaces/openclaw/sample1/upstream/openclaw/Swabble/Package.swift` の形）
    - `rec.swift` の内容を移す: 16〜270 行（型・関数）→ `Sources/RecCore/Legacy.swift`（`public` を付けて main から呼べる
      最小限: `audioProcesses`, `Recorder`, `recordURL`, `recordLive`, `installSigint`, `RecError`）、274〜313 行（トップレベル）→
      `Sources/rec/main.swift`。`git mv rec.swift Sources/RecCore/Legacy.swift` で履歴を残す。リポジトリ直下に `rec.swift` が無い。
      Swift 6 言語モードのエラーは Legacy.swift 内だけ `nonisolated(unsafe)` / `@unchecked Sendable` で黙らせてよい
      （T3〜T9 で置き換えて消えるコード。言語モードは v5 に落とさない）
    - `Sources/rec/Info.plist`: `CFBundleIdentifier` = `dev.rec-tube.rec`、`CFBundleName` = `rec`、`CFBundleShortVersionString` = `0.2.0`、
      `LSMinimumSystemVersion` = `26.0`、`NSAudioCaptureUsageDescription` = 「rec は指定したアプリの音声を録音するためにシステム音声の取得を使います」
    - `scripts/build.sh` / `scripts/test.sh` / `scripts/final-check.sh`（検証コマンド節のとおり。`set -euo pipefail`、`cd "$(dirname "$0")/.."`、
      `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`、引数は `"$@"` で素通し。`chmod +x`）。
      final-check の `rg` 検査は T1 時点で通る項目だけ有効にし、残りは T11 で足す（コメントで TODO を残す）
    - `.gitignore` に `.build/`、`*.m4a`、`*.wav`（`Tests/Fixtures/` の生成物を含む）を追加
    - `README.md`（骨組み）: ビルド手順（scripts と素の swift コマンドの両方）、テスト手順（`DEVELOPER_DIR` が要る理由 = CLT では
      `import Testing` 不可）、`otool -s __TEXT __info_plist .build/debug/rec` / `otool -P .build/debug/rec` での埋め込み確認。
      使い方・許可・既知の制約は T11 が書く（見出しだけ置く）
    - 機械検証: `scripts/build.sh` と `scripts/build.sh -c release` が成功、`otool -s __TEXT __info_plist .build/debug/rec` と
      `.build/release/rec` にセクションあり、`otool -P .build/debug/rec` の出力に `NSAudioCaptureUsageDescription` を含む（B1, B2）、
      `scripts/test.sh` が成功（`@Test` 1 本: `RecError(description:)` の description が引数と一致、で可）（B3, B4）、
      `.build/debug/rec --list` が exit 0、`.build/debug/rec --bogus` が exit 1
    - 担う落とし穴: B1〜B4。`swift build` が承認待ちやサンドボックスで実行できなければ BLOCKED（試したコマンドと出力を BLOCKED.md に）
  - 対象: `Package.swift`, `Sources/RecCore/Legacy.swift`, `Sources/rec/main.swift`, `Sources/rec/Info.plist`, `Sources/rec-probe/main.swift`,
    `Tests/RecCoreTests/SmokeTests.swift`, `scripts/build.sh`, `scripts/test.sh`, `scripts/final-check.sh`, `.gitignore`, `README.md`
  - 依存: なし
  - 並列サブ作業: なし（ビルドが通るまで 1 人で回す方が速い）

- [x] T2: HAL 層と `TapTarget`、`rec-probe` による bundleIDs の実機プローブ（tap の作り方を確定する）
  - 完了基準:
    - `Sources/RecCore/HAL.swift`: `check` / `address` / `read` / `readIDs`（Legacy から移動）、`AudioProc`、`audioProcesses()`、
      `enum TapTarget { case system; case processes([AudioObjectID]); case bundleIDs([String], seed: [AudioObjectID]) }`、
      `func makeTapDescription(_ target: TapTarget) -> CATapDescription`（`uuid` 新規、`name` = `rec-tap`、`isPrivate` = true、
      `muteBehavior` = `.unmuted`。`.system` は `stereoGlobalTapButExcludeProcesses: []`、`.processes` は `stereoMixdownOfProcesses:`、
      `.bundleIDs` は `stereoMixdownOfProcesses: seed` の後に `bundleIDs` を設定し、`.processes` と `.bundleIDs` は
      `isProcessRestoreEnabled = true`）。ユニット: 3 variant でプロパティが上記どおり（`FakeHAL` 不要。description を読むだけ）
    - `Sources/rec-probe/main.swift`（手動実行の道具。`rec` のサブコマンドにはしない）:
      `rec-probe list`（`audioProcesses()` を `running` 付きで表示）、
      `rec-probe tap <system|processes|bundleids|hybrid> <秒数> [--prefix com.google.Chrome]`（Legacy の `Recorder` 相当を直接組み立て、
      1 秒ごとに `rms dBFS` と `allZero` を表示。`hybrid` = bundleIDs + 現在の prefix 一致プロセスを seed）、
      `rec-probe analyze <wav|m4a> [--main 440 --ad 1000 --expect-main 秒] [--silence]`（T10 で中身を書く。T2 は usage だけ）
    - 実機プローブ（Chrome のオートメーション許可とシステム音声の許可が前提。URL は `https://www.youtube.com/watch?v=jNQXAC9IVRw`
      を `osascript -e 'tell application "Google Chrome" to open location "…"'` で開き、終了時に閉じる）:
      (0) 再生中に `rec-probe list` で **running になる Chrome のバンドル ID の実名**を記録する（`com.google.Chrome.helper` か別か）
      (a) `hybrid` 3 秒: 作成成功かつ allZero でない
      (b) `bundleids` 3 秒（seed なし、Chrome 再生中に作成）: 作成成功かつ allZero でない
      (c) `bundleids` を Chrome 停止中に作成 → 作成後に再生開始 → 音が入るか
      (d) `hybrid` 録音中に `pkill -f audio.mojom.AudioService`（Chrome の音声サービスだけ再起動）→ 再生が戻った後 RMS が戻るか（L1 (c)）
      (e) `processes` 3 秒（従来方式。これも allZero なら許可が無い）
    - 結果でこの PLAN の「決めた事項」#2 の `chromeTapTarget` を**impl が書き換えて確定**する（優先順: (b)(c)(d) すべて可 → `bundleIDs`
      seed なし / (a)(d) 可 → `bundleIDs` seed あり（hybrid）/ hybrid が作成失敗 → `processes` + restore）。
      (e) まで allZero なら「許可なし」: 決めた事項は hybrid のまま、PROGRESS と PLAN メモに「verify 前に許可が要る」と書いて**続行する**（BLOCKED にしない。
      verify-permission.sh が最初に検出する）。Chrome のオートメーション許可が無い（-1743）場合も同様に記録して続行
    - 担う落とし穴: L1、§2.1 の未確認事項、§5.1 catap の「満たせない description は tap ID 0」
  - 対象: `Sources/RecCore/HAL.swift`, `Sources/RecCore/Legacy.swift`（HAL 部分を削る）, `Sources/rec-probe/main.swift`,
    `Tests/RecCoreTests/TapTargetTests.swift`, `.gsd-lite/PLAN.md`（決めた事項 #2 の確定値）
  - 依存: T1
  - 並列サブ作業: なし（プローブ結果を見ながら進める）
  - **T2 の実測（turn 4）**:
    - (0) 済み: YouTube 再生中に `running` になる Chrome のバンドル ID は **`com.google.Chrome.helper` だけ**
      （`com.google.Chrome` は再生中も `no`）。プロセス一覧に出るのはこの 2 名のみ（`.helper.renderer` / `.helper.gpu` 等は出ない）。
      → `Chrome.bundleIDs = ["com.google.Chrome", "com.google.Chrome.helper"]` に確定（決めた事項 #2）
    - (a)〜(e) **未実測（許可なし）**: tap と aggregate の作成までは成功するが、
      **`AudioDeviceCreateIOProcIDWithBlock` が無期限にブロックする**（10 秒の watchdog で打ち切り）。
      許可ダイアログは出ない（System Events でフォアグラウンドプロセスと全ウィンドウを確認。tccd /
      UserNotificationCenter に新規プロセスなし）。`system` / `hybrid` の両 variant で同じ、
      `kAudioAggregateDeviceTapAutoStartKey` を false にしても同じ、Bash のサンドボックスを外しても同じ。
      → システム音声の取得の許可が**責任プロセス（iTerm2）に降りていない**（RESEARCH §2.5）。
      PLAN どおり BLOCKED にせず続行。決めた事項 #2 は hybrid のまま。**verify の前に許可が必要**（T11 / メモ参照）
    - `rec-probe` は `swift run rec-probe …` で呼ぶ（`.build/debug/rec-probe` は allowlist の
      `Bash(.build/debug/rec:*)` に当たらない。prefix は「完全一致」か「prefix + 空白」でしか当たらないため）

- [x] T3: 終了コード・エラー型・メッセージ、ファイルライタ、出力パス（純粋ロジック + ユニットテスト）
  - 完了基準:
    - `Sources/RecCore/ExitCode.swift`: `enum ExitCode: Int32`（決めた事項 #3 の表のとおり）、`enum StopReason`（#3 の理由一覧）、
      `extension StopReason { var exitCode: ExitCode }`（switch は exhaustive、default なし）、
      `struct RecError: Error { let code: ExitCode; let message: String }`。ユニット: 表の全行を 1 ケースずつ（`ExitCodeTests`）
    - `Sources/RecCore/Messages.swift`: 許可の案内文 3 種（システム音声: 「システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音」+
      tmux の注意 + `tccutil reset ScreenCapture`、オートメーション: 「…> オートメーション」、JS: 「表示 > 開発/管理 > Apple Events からの JavaScript を許可」）、
      「データなし」「無音」「ライブ配信」の定型文。すべて `stderr` 用（エラーは stderr、進捗は stdout。rec.swift:311 は stdout に出していた）
    - `Sources/RecCore/AudioFileWriter.swift`: `protocol AudioFileWriting: AnyObject { func write(_ buf: AVAudioPCMBuffer) throws; func close() throws; var framesWritten: AVAudioFramePosition { get }; var url: URL { get } }`、
      `final class AVAudioFileWriter: AudioFileWriting`（`AVAudioFile(forWriting:settings:commonFormat:interleaved:)` を rec.swift:106-112 と同じ設定
      AAC 192 kbps で開く。`close()` は `isOpen` を見て 1 回だけ `AVAudioFile.close()`。2 回目以降は何もしない）。
      ユニット（P4, P8）: 一時ディレクトリで 1 フレーム書いて close → `AVAudioFile(forReading:)` が開けて `length ≥ 1`；
      `close()` 2 回で例外なし；書き込み不可ディレクトリ（`chmod 0500` の一時ディレクトリ）で open が `RecError`（code `.outputUnavailable`）；
      `FakeWriter`（テスト用、`writeError` を注入できる）を `Tests/RecCoreTests/Fakes/` に置く
    - `Sources/RecCore/OutputPath.swift`:
      `func sanitizeFileName(_ title: String) -> String?`（`/` `:` `\0` と C0/C1 制御文字 → `_`、先頭の `.` を落とす、末尾の空白とピリオドを落とす、
      NFC 正規化、UTF-8 バイト長 200 で切る（結合文字の途中で切らない）、結果が空なら nil）、
      `func defaultBaseName(now: Date) -> String`（`rec-yyyyMMdd-HHmmss`）、
      `func reserveUniquePath(directory: URL, baseName: String, ext: String = "m4a") throws -> URL`（`name.m4a`, `name-2.m4a`, `name-3.m4a` … を
      `open(O_CREAT|O_EXCL|O_WRONLY, 0o644)` で原子的に確保。EEXIST は次の連番、他の `errno` は `RecError(.outputUnavailable)`。上限 1000 で諦めて同エラー）。
      `-o` 指定時も同じ関数を通す（拡張子の手前に連番。拡張子が無ければ末尾に付ける）。
      ユニット（P5, P6）: `a.m4a`, `a-2.m4a` がある → `a-3.m4a`；10 スレッド同時に同じ baseName を要求して全員別名；
      `"a/b:c"` → `a_b_c`；`".hidden"` → `hidden`；`""` と `"..."` → nil；`"🎵"×100` → 200 バイト以下で UTF-8 として妥当；
      NFD の「ガ」→ NFC 1 文字；`"name. "` → `name`；制御文字クラス（`\u{1}`, `\u{7f}`, `\u{85}`, `\u{2028}`）→ すべて `_`
    - 担う落とし穴: P4, P5, P6, P8、§8-2、§8-3。**例外は親クラスで扱う**: OSError 相当（`errno` 全般 / `NSError` の `NSCocoaErrorDomain`）を
      `.outputUnavailable` に畳む。列挙した errno 以外（例 `EROFS`）もテストに 1 件入れる
  - 対象: `Sources/RecCore/ExitCode.swift`, `Sources/RecCore/Messages.swift`, `Sources/RecCore/AudioFileWriter.swift`, `Sources/RecCore/OutputPath.swift`,
    `Tests/RecCoreTests/ExitCodeTests.swift`, `Tests/RecCoreTests/AudioFileWriterTests.swift`, `Tests/RecCoreTests/OutputPathTests.swift`, `Tests/RecCoreTests/Fakes/FakeWriter.swift`
  - 依存: T1
  - 並列サブ作業:
    - A: ExitCode / StopReason / RecError / Messages + テスト（対象: `ExitCode.swift`, `Messages.swift`, `ExitCodeTests.swift`）
    - B: AudioFileWriter + FakeWriter + テスト（対象: `AudioFileWriter.swift`, `Fakes/FakeWriter.swift`, `AudioFileWriterTests.swift`）
    - C: OutputPath + テスト（対象: `OutputPath.swift`, `OutputPathTests.swift`）
    - 注: B と C は A の `RecError(.outputUnavailable)` を使う。親が最初に A の 3 型の骨（case 名と init）だけ作ってから分配する
  - **T3 の実測（turn 5）**:
    - **PLAN 訂正: `ExitCode` の signal は 1 case ではなく 3 case**（`signalHUP = 129` / `signalINT = 130` / `signalTERM = 143`）。
      根拠: `enum ExitCode: Int32`（raw value つき）に `case signal(Int32)` のような payload 付き case は入れられない。
      `StopReason.signal(Int32)` は残し、`exitCode` で `ExitCode(rawValue: 128 &+ sig) ?? .coreAudio` に変換する
      （HUP / INT / TERM 以外の番号は「その他の予期しないエラー」= 8 に畳む）。
      → **決めた事項 #3 の表は 12 行**（signal 行を 3 行に割る）。**README の「終了コード」表（T11）も 12 行で書く**
    - **PLAN 訂正: サブ作業 A の分担**。共有型（`ExitCode` / `StopReason` / `RecError`）は**親が全部実装**し、
      A は `Messages.swift` + `ExitCodeTests.swift`（決めた事項 #3 の表だけを渡して独立に記述）に変更した。
      根拠: B と C が `RecError(.outputUnavailable)` に依存するため、骨だけ置くと 3 人ともビルドできない
      （「テストを仕様表から独立に書かせる」構成は維持した。結果: 表と実装の食い違い 0 件）
    - **PLAN 訂正: `sanitizeFileName` の制御文字判定に Unicode カテゴリ `Cf`（書式制御）を含めない**。
      契約は「C0 / C1 制御文字（= `Cc`）と `\u{2028}`（= `Zl`）」なのでこれで満たせる。`Cf` を含めると
      ZWJ（U+200D）が `_` になり、YouTube タイトルの連結絵文字（👨‍👩‍👧 等）が分解される
    - **既存テストの期待値を変えた箇所（1 件）**: `Tests/RecCoreTests/SmokeTests.swift` の
      `recErrorKeepsItsDescription` → `recErrorKeepsItsCodeAndMessage`。理由: `RecError` が
      `description: String` から `code: ExitCode` + `message: String` に変わった（PLAN T3 の完了基準どおり）
    - 署名の確定: `AVAudioFileWriter.init(url: URL, format: AVAudioFormat) throws`、
      `Messages` は `public enum Messages` の `static let` 6 本
      （`systemAudioPermission` / `chromeAutomationPermission` / `chromeJavaScriptPermission` / `noData` / `silent` / `liveStream`。
      末尾に改行を含まないので、出力側が改行を足す）
    - `Sources/rec/main.swift` の catch を `RecError.code` で `exit` する形に変えた（T9 の配線一本化の前倒し。最小限）。
      `--bogus` が 1 / `--list` が 0 / `--app` 不一致が 1 は変わらず

- [x] T4: 遅延線（広告ガード）・無音メータ・録音パイプライン（純粋ロジック + ユニットテスト）
  - 完了基準:
    - `Sources/RecCore/Tuning.swift`: 決めた事項 #4〜#8 の定数を `enum Tuning { static let … }` に集約（他ファイルは数値を直書きしない）
    - `Sources/RecCore/DelayLine.swift`: `final class DelayLine`（`init(format: AVAudioFormat, guardSeconds: Double)`、`guardFrames = Int((guardSeconds * sampleRate).rounded())`、
      `func push(_ buf: AVAudioPCMBuffer, emit: (AVAudioPCMBuffer) throws -> Void) rethrows`（バッファを**コピーして**保持し、保持フレーム合計が `guardFrames` を超える間、
      最古のバッファを丸ごと emit）、`func discard()`（保持分を捨てる）、`func flush(emit:)`（保持分を全部 emit）、`var heldFrames: Int`）。
      スレッド規約: 呼び出し側（IO キュー）がシリアライズする。内部ロックなし
      ユニット（A1）: 48 kHz・512 フレームのバッファを 3 秒分 push → guard 1.0 で emit 済みが 2.0 秒 ± 1 バッファ、discard 後の `heldFrames` = 0、
      flush で残りが全部出る；guard 0 → 毎回即 emit；guard 5.0 で 3 秒 push → emit 0・flush で 3 秒；48000 が 512 で割り切れない端数でも合計フレームが一致；
      `rethrows` で emit の例外が伝わる
    - `Sources/RecCore/SilenceMeter.swift`: `final class SilenceMeter`（`init(sampleRate:)`、`func ingest(_ buf: AVAudioPCMBuffer, gateOpen: Bool)`：
      vDSP で RMS、`allZero` 判定、1 秒窓（`Tuning.meterWindowSeconds`）ごとに `MeterWindow { dBFS, allZero, gateOpen }` を確定、
      `var snapshot: MeterSnapshot`（`everNonZero`, `consecutiveAllZeroSeconds`, `consecutiveSilentSeconds`, `audibleGateOpenWindows`, `totalWindows`）、
      `func classify(dBFS:) -> Bool`（silent iff `dBFS < -60.0`。**ちょうど -60.0 は silent ではない**）。
      ユニット（P7）: 全ゼロ / -70 dBFS 白色雑音 / -20 dBFS 正弦 / ちょうど -60.0 dBFS 正弦 の 4 種で `allZero` と silent の組が期待どおり；
      全ゼロ 10 秒で `consecutiveAllZeroSeconds == 10`、途中 1 窓だけ音ありで 0 に戻る；`gateOpen=false` の窓は `audibleGateOpenWindows` に数えない
    - `Sources/RecCore/RecordingPipeline.swift`: `final class RecordingPipeline`（`init(format:, writer: AudioFileWriting, guardSeconds:, meter:)`、
      `func ingest(_ buf: AVAudioPCMBuffer)`（IO キュー上: meter → gate が開いていれば delayLine.push → writer.write。最初の write エラーを `firstWriteError` に保持し
      `onWriteError` を 1 回だけ呼ぶ、以後は書かない）、`func setGate(_ open: Bool, discardHeld: Bool)`、`func finish() throws`（gate 開なら flush → writer.close、閉なら discard → close）。
      `firstWriteError` / `onWriteError` のスレッド規約は IO キュー
      ユニット: FakeWriter で「gate 閉→discard→開」で広告分が書かれない、`finish()` 後 `framesWritten` が期待値、write エラー注入で `onWriteError` 1 回・以降 write 0 回
    - 担う落とし穴: A1, A2（遅延線側）, P7, P8（パイプライン側）, L4 の入力（`consecutiveAllZeroSeconds`, `everNonZero`）, L6（遅延線は固定長: `heldFrames ≤ guardFrames + 1 バッファ`をテスト）
  - 対象: `Sources/RecCore/Tuning.swift`, `Sources/RecCore/DelayLine.swift`, `Sources/RecCore/SilenceMeter.swift`, `Sources/RecCore/RecordingPipeline.swift`,
    `Tests/RecCoreTests/DelayLineTests.swift`, `Tests/RecCoreTests/SilenceMeterTests.swift`, `Tests/RecCoreTests/RecordingPipelineTests.swift`, `Tests/RecCoreTests/Fakes/Signals.swift`（正弦・雑音・全ゼロの生成）
  - 依存: T3（`AudioFileWriting`, `FakeWriter`）
  - 並列サブ作業:
    - A: Tuning + DelayLine + テスト（対象: `Tuning.swift`, `DelayLine.swift`, `DelayLineTests.swift`）
    - B: SilenceMeter + Signals + テスト（対象: `SilenceMeter.swift`, `Fakes/Signals.swift`, `SilenceMeterTests.swift`）
    - C: RecordingPipeline + テスト（対象: `RecordingPipeline.swift`, `RecordingPipelineTests.swift`。A/B の公開 API 名は上記のとおり固定して先に伝える）
  - **T4 の実測（turn 6）**:
    - **PLAN 訂正: 共有物（`Tuning.swift` と `Tests/RecCoreTests/Fakes/Signals.swift`）は親が先に作り、
      サブ作業 C（`RecordingPipeline`）も親が実装した**。A / B の 2 本だけを並列サブエージェントに出した。
      根拠: `RecordingPipeline` は `DelayLine`（A）と `SilenceMeter`（B）の両方を使うため、A / B が揃うまで
      ビルドも単体確認もできない（T3 turn 5 の「共有型は親が完成させる」と同じ理屈）。`Tuning` は A / B / C 全員が
      参照し、`Signals` は 3 つのテスト全部が使うので、分配前に親が確定させた
    - 確定した API（T5 / T8 はこの名前で配線する）:
      `DelayLine(format:guardSeconds:)` / `heldFrames` / `push(_:emit:)` / `discard()` / `flush(emit:)`；
      `SilenceMeter(sampleRate:)` / `ingest(_:gateOpen:)` / `snapshot` / `lastWindow` / `classify(dBFS:) -> Bool`；
      `MeterWindow { dBFS, allZero, gateOpen }` / `MeterSnapshot { everNonZero, consecutiveAllZeroSeconds,
      consecutiveSilentSeconds, audibleGateOpenWindows, totalWindows }`（秒は `Double`）；
      `RecordingPipeline(format:writer:guardSeconds:meter:)` / `ingest(_:)` / `setGate(_:discardHeld:)` /
      `finish() throws` / `gateOpen` / `firstWriteError: Error?` / `onWriteError: ((Error) -> Void)?` /
      `writer`（`let`。`framesWritten` はここから読む） / `meter`（`let`）
    - `RecordingPipeline` の契約の補足（PLAN 本文に無かった点を実装で確定）:
      (1) **gate の初期値は開**（system / app モードは `setGate` を呼ばずに録り続ける）
      (2) `ingest` は gate が閉じていても `meter.ingest` を通す（広告中の全ゼロも tap 故障の材料になる）
      (3) `write` エラーは `firstWriteError` に畳んで `onWriteError` を 1 回だけ呼び、`push` / `flush` の
          `emit` からは throw しない。よって `finish()` が throw するのは `writer.close()` の失敗だけで、
          **flush が失敗しても `writer.close()` は必ず呼ばれる**
    - `DelayLine` の実測:
      (1) 保持量は「`guardFrames` を**超えている間**だけ最古を丸ごと押し出す」ので、`bufferFrames` ずつ
          十分 push した後の保持は常に `(guardFrames / bufferFrames) * bufferFrames`（整数除算）。
          48 kHz / guard 1.0 / 512 フレームなら 93 × 512 = 47616 フレーム（テストはこの式で期待値を出す）
      (2) `guardSeconds == 0` は**コピーも保持もせず素通し**（system / app モードの経路）
      (3) コピーは `AudioBufferList` 越しの `memcpy`（サンプル型に依存しない）。`frameCapacity` の下限は 1
      (4) **`guardSeconds` の範囲チェック（`Tuning.adGuardRange`）は `DelayLine` に入れていない**。
          負値を渡すと素通しになる。`--ad-guard` のパース側（T9）で弾くこと
    - `SilenceMeter` の実測: **二乗和は Double で累算する**（`vDSP_vspdp` で float32 → Double に広げてから
      `vDSP_svesqD`）。`Signals.constant(dBFS: -60.0)` の振幅 `Float(1e-3)` は真値より 4.1e-7 dB だけ上にしか
      ないので、float32 累算（`vDSP_svesq`）では「ちょうど -60.0 は silent ではない」が丸め次第になる。
      `allZero` は二乗和ではなく `vDSP_maxmgv`（最大絶対値 == 0）で別に測る（アンダーフロー対策）。
      1 バッファが窓境界をまたぐ場合は `ingest` 内で区間分割する

- [x] T5: `TapRecorder`（HAL 抽象化・リスナー・冪等 stop・途中失敗の後始末）+ `FakeHAL`
  - 完了基準:
    - `Sources/RecCore/AudioHAL.swift`: `protocol AudioHAL`（createTap / destroyTap / tapFormat / defaultOutputDevice / deviceUID / createAggregate / destroyAggregate /
      createIOProc / destroyIOProc / start / stop / addListener / removeListener / processList。名前は目安、**契約は「create 系に対応する destroy / remove が
      `stop()` で 1 回ずつ呼ばれる」**）、`final class CoreAudioHAL: AudioHAL`（実装。T2 の HAL.swift の関数を使う）
    - `Sources/RecCore/TapRecorder.swift`: `final class TapRecorder: @unchecked Sendable`、
      `init(hal: AudioHAL, target: TapTarget, ioQueue: DispatchQueue, sink: @escaping (AVAudioPCMBuffer) -> Void, onEvent: @escaping (RecorderEvent) -> Void)`、
      `func start() throws`（順: tap → format → **`kAudioHardwarePropertyDefaultOutputDevice`** の UID（rec.swift:88-89 の `DefaultSystemOutputDevice` から変更。§8-7）→
      aggregate（rec.swift:91-103 と同じ辞書）→ IOProc → listener 4 つ（system: `DefaultOutputDevice`, `ServiceRestarted`；aggregate: `IOStoppedAbnormally`；
      出力サブデバイス: `DeviceIsAlive`。`ProcessorOverload` は aggregate にログ用）→ `AudioDeviceStart`。**どの段で throw しても、それまでに作ったものを逆順に破棄**してから投げる）、
      `func stop()`（内部の直列キュー `rec.stop` で `sync`、`stopped` フラグで 1 回だけ。順: listener 解除 → `AudioDeviceStop` → `ioQueue.sync {}` → IOProc 破棄 → aggregate 破棄 → tap 破棄）、
      `deinit { stop() }`、`var format: AVAudioFormat?`（start 後）。`enum RecorderEvent { case defaultOutputChanged, ioStoppedAbnormally, deviceDied, serviceRestarted, overload }`。
      IOProc ブロックは `[weak self]` で `sink` を呼ぶだけ（rec.swift:114-119 の `try?` 書き込みは RecordingPipeline に移った）
    - `Tests/RecCoreTests/Fakes/FakeHAL.swift`: 各 create / destroy / add / remove の呼び出しを記録、任意の段で throw させられる、`fire(event)` で listener を呼べる、
      `emit(buffer)` で IOProc ブロックを呼べる
    - ユニット（P3, L2, L5）: start→stop で create と destroy、add と remove の回数が一致；start の各段（tap / format / aggregate / ioproc / listener / start の 6 箇所）で throw させて、
      作成済みのものが全部 destroy されている；`stop()` を 10 スレッドから同時に呼んで destroy が各 1 回；`deinit` だけで destroy される；
      `fire(.defaultOutputChanged)` 等 5 種がそれぞれ `onEvent` に届く；**`scripts/test.sh --sanitize=thread --filter TapRecorder` を 1 回回して警告なし**
      （sanitize が Swift Testing で動かなければ PROGRESS に記録して通常実行のみ）
    - Legacy.swift から `Recorder` を削る（`recordLive` / `recordURL` は T9 まで Legacy の `Recorder` を使うので、`LegacyRecorder` に改名して残す）
    - **PLAN 追記（T2 turn 4 の実測）**: `start()` は**有限時間で必ず戻る**こと。許可が降りていないと
      `AudioDeviceCreateIOProcIDWithBlock` が**ダイアログも出さずに無期限ブロックする**（T2 の実測欄）。
      `Tuning.tapStartTimeoutSeconds = 10` を足し、`start()` の本体を別キューで走らせて
      `DispatchSemaphore.wait(timeout:)` で打ち切り、時間切れなら「許可が降りていない可能性」の案内（`Messages.swift`）
      とともに `.coreAudio`（exit 8）で throw する（打ち切り後も作成スレッドは残るので、後始末は
      プロセス終了に任せる = `exit` する側で問題にしない）。`kAudioAggregateDeviceTapAutoStartKey` は
      **false**（true だと `AudioDeviceStart` が対象が音を出すまで戻らない。RESEARCH §2.1 の原文どおりの挙動）。
      `rec-probe` の `makeProbeTap` / `ProbeTap` が参考実装。ユニット: `FakeHAL` の `createIOProc` を
      ブロックさせて、`start()` が timeout で throw し、それまでに作ったものが逆順に destroy されること
    - **PLAN 追記（T3 turn 5 の申し送り）**: `AVAudioFile.write(from:)` は、渡すバッファの `format` が
      `AVAudioFile.processingFormat` と違うと **Objective-C 例外で即クラッシュする（Swift では catch できない）**。
      `TapRecorder` は `start()` で確定した `format` のバッファだけを sink に渡すこと（途中で tap の format が
      変わる経路を作らない）。T4 の `RecordingPipeline` も同じ format を `AVAudioFileWriter` に渡す
  - 対象: `Sources/RecCore/AudioHAL.swift`, `Sources/RecCore/TapRecorder.swift`, `Sources/RecCore/Legacy.swift`, `Tests/RecCoreTests/Fakes/FakeHAL.swift`, `Tests/RecCoreTests/TapRecorderTests.swift`
  - 依存: T2, T4
  - 並列サブ作業:
    - A: AudioHAL protocol + CoreAudioHAL（対象: `AudioHAL.swift`）
    - B: TapRecorder（対象: `TapRecorder.swift`。A の protocol 名は上記で固定）
    - C: FakeHAL + テスト（対象: `Fakes/FakeHAL.swift`, `TapRecorderTests.swift`。PLAN の契約からテストを書く。B の実装は見ない）
  - **T5 の実測（turn 7）**:
    - **PLAN 訂正: サブ作業の割り方**。共有物（`AudioHAL.swift` の protocol + `CoreAudioHAL`、`Tests/.../Fakes/FakeHAL.swift`）は
      **親が両方作り**、並列に出したのは B（`TapRecorder.swift`）と「テストだけ」の 2 本にした。
      根拠: protocol と、それを実装する test double は**同時に書かないと噛み合わない**（別々に出すと
      署名のすり合わせで 2 往復する）。T3 turn 5 / T4 turn 6 の「共有型は親が完成させる」と同じ理屈。
      「テストを契約から独立に書かせる」構成（テスト担当は `TapRecorder.swift` を読まない）は維持した
    - **PLAN 訂正: IOProc と listener の受け渡しは生の `AudioDeviceIOProcID` ではなく `IOProcToken` /
      `ListenerToken`（`AudioHAL.swift` の `public final class`）**。根拠: `AudioDeviceIOProcID` は C の
      関数ポインタ型なので `FakeHAL` が値を作れない（`AudioObjectAddPropertyListenerBlock` の解除も
      「登録した block と queue の両方」が要る）。実装が解除に必要な物を `payload: Any?` に入れる箱にした。
      protocol の該当メソッドは `createIOProc(device:queue:block:) -> IOProcToken` / `destroyIOProc(_:)` /
      `start(_:)` / `stop(_:)` / `addListener(objectID:selector:queue:handler:) -> ListenerToken` / `removeListener(_:)`
    - **PLAN 追記: `TapRecorder.init` に `startTimeout: Double = Tuning.tapStartTimeoutSeconds` を足した**。
      根拠: watchdog のテストを 10 秒待たずに回すため（テストは 0.2 秒を渡す）。既定値は `Tuning` のまま
    - **打ち切り（時間切れ）のときの後始末の持ち主は「作成スレッド」**。`start()` の呼び出し側は
      「捨てる旗」を立てるだけで**何も破棄しない**。作成スレッドがブロックから戻ったところで旗に気づき、
      それまでに作った物を逆順に 1 回破棄する。戻って来なければ後始末はプロセス終了に任せる。
      根拠: まだ Core Audio の呼び出しの中にいる相手（その呼び出しが掴んでいる aggregate / tap）を
      外から壊すのは安全でない。**実装は最初「打ち切り側が即破棄する」形で、テスト（契約から独立に
      書いた側）が「逆順になっていない」と落とした** → 契約どおり作成スレッド側に寄せて green。
      これが今回の並列構成が拾った唯一の食い違い
    - **`swift test --sanitize=thread` はこの環境で動かない**（PLAN の「sanitize が動かなければ
      PROGRESS に記録して通常実行のみ」の経路）。ビルドは通るが実行時に dyld が
      `libclang_rt.tsan_osx_dynamic.dylib` を読めない（`code signature ... not valid for use in process:
      Sanitizer load violates platform policy`）。Swift Testing 側の問題ではなく Xcode の sanitizer
      ランタイムと OS のポリシーの不整合。`--sanitize=address` も同じ（T5 では通常実行のみで green）
    - 確定した API（T6 / T8 はこの名前で配線する）:
      `RecorderEvent { defaultOutputChanged, ioStoppedAbnormally, deviceDied, serviceRestarted, overload }`；
      `TapRecorder(hal:target:ioQueue:startTimeout:sink:onEvent:)` / `start() throws` / `stop()` / `format: AVAudioFormat?`；
      `AudioHAL` / `CoreAudioHAL()` / `IOProcToken` / `ListenerToken` / `TapIOBlock`
    - `TapRecorder` の契約の補足（PLAN 本文に無かった点を実装で確定）:
      (1) `sink` は `ioQueue` 上、`onEvent` は内部の直列キュー `rec.recorder.events` 上で呼ばれる
      (2) 後始末の実体は `destroy(_:)` の 1 本だけ。入口は `stop()` / `deinit` / 途中失敗の巻き戻し /
          打ち切り後の作成スレッド の 4 つで、順序は常に
          「listener 逆順解除 → 開始済みなら `hal.stop` → `ioQueue.sync {}` → `destroyIOProc` → `destroyAggregate` → `destroyTap`」
      (3) **`sink` の中から `stop()` を呼ぶと `ioQueue.sync {}` で自己デッドロックする**。
          T8 は停止要求をセッションキューに逃がすこと（`coordinator.request` を ioQueue 上で完了させない）
      (4) `stop()` は「捨てる旗」を立てるので、**`stop()` 後の `start()` は即座に失敗する**（再開はしない）。
          `start()` の二重呼び出しのガードは入れていない（契約外。T8 は 1 回しか呼ばない）
      (5) `format` は `stop()` 後も読める（破棄の対象ではない記録として残す）
    - `Legacy.swift` の `Recorder` は **`LegacyRecorder` に改名**（`recordURL` / `recordLive` もろとも T9 で消える）。
      `AudioFileWriter.swift` のコメントの参照も合わせた

- [x] T6: 停止の一本化（`StopCoordinator`）、シグナル（INT/TERM/HUP）、スリープ（IOKit）
  - 完了基準:
    - `Sources/RecCore/StopCoordinator.swift`: `final class StopCoordinator: @unchecked Sendable`（`func request(_ reason: StopReason) -> Bool`（最初の 1 回だけ true。
      `OSAllocatedUnfairLock` か直列キュー）、`var reason: StopReason?`、`onFirstRequest: (StopReason) -> Void` を**セッションキュー**で 1 回呼ぶ）。
      ユニット: 10 スレッドから別々の理由で request → `reason` は 1 つ、`onFirstRequest` 1 回
    - `Sources/RecCore/SignalWatcher.swift`: `final class SignalWatcher`（`init(signals: [Int32] = [SIGINT, SIGTERM, SIGHUP], queue:, handler: (Int32) -> Void)`。
      `signal(sig, SIG_IGN)` を先に呼んでから `DispatchSource.makeSignalSource` + `activate()`（§2.3。参考: `~/workspaces/openclaw/sample1/upstream/openclaw/apps/macos/Sources/OpenClaw/TerminationSignalWatcher.swift`）。
      ハンドラは `coordinator.request(.signal(sig))` を呼ぶだけで `exit` しない（rec.swift:267 の `exit(0)` を撤廃）。
      ユニット: 自プロセスに `kill(getpid(), SIGUSR1)`（テストでは SIGUSR1 を指定）→ handler が 1 回呼ばれる
    - `Sources/RecCore/PowerWatcher.swift`: `protocol PowerSource`（登録 / 解除 / ack を抽象化）と `final class IOKitPowerSource: PowerSource`（`IORegisterForSystemPower` +
      `IONotificationPortSetDispatchQueue(port, queue)`。CFRunLoop は使わない）、`final class PowerWatcher`（`kIOMessageSystemWillSleep` と `kIOMessageCanSystemSleep` の
      **両方で必ず `IOAllowPowerChange`** を呼び、`WillSleep` で `handler(.sleep)`）。参考: QA1340（RESEARCH §2.2）。
      ユニット（L3）: `FakePowerSource` で `WillSleep` / `CanSleep` / `HasPoweredOn` の 3 メッセージを送り、ack が各 1 回、handler は WillSleep の 1 回だけ。
      **ack を呼ばない経路が無いこと**をテスト名で明示する
    - 担う落とし穴: P1（exit の撤廃は T9 で完成）、P2、P3（coordinator 側）、L3。P2 の統合（`kill -TERM` → `afinfo`）は T9 / T11 のスクリプトで行う
  - 対象: `Sources/RecCore/StopCoordinator.swift`, `Sources/RecCore/SignalWatcher.swift`, `Sources/RecCore/PowerWatcher.swift`,
    `Tests/RecCoreTests/StopCoordinatorTests.swift`, `Tests/RecCoreTests/SignalWatcherTests.swift`, `Tests/RecCoreTests/PowerWatcherTests.swift`, `Tests/RecCoreTests/Fakes/FakePowerSource.swift`
  - 依存: T3（`StopReason`）
  - 並列サブ作業:
    - A: StopCoordinator + SignalWatcher + テスト（対象: `StopCoordinator.swift`, `SignalWatcher.swift`, 両テスト）
    - B: PowerWatcher + FakePowerSource + テスト（対象: `PowerWatcher.swift`, `Fakes/FakePowerSource.swift`, `PowerWatcherTests.swift`）
  - **T6 の実測（turn 8）**:
    - **PLAN 追記: IOKit のメッセージ種別は Swift から参照できない**。`kIOMessageSystemWillSleep` 等は
      `iokit_common_msg(0x280)` という入れ子マクロで、clang importer が
      `macro 'kIOMessageSystemWillSleep' unavailable: structure not supported` と落とす。
      → `PowerNotification` の static 定数 3 本に値を書いた
      （`systemWillSleep = 0xE000_0280` / `canSystemSleep = 0xE000_0270` / `systemHasPoweredOn = 0xE000_0300`。
      導出 `iokit_common_msg(m) = 0xE000_0000 | m` はコメントに、値は `_Static_assert` を clang で通して確認）。
      秒数・dBFS ではないので `Tuning` には置かない（この 3 本が唯一の置き場）
    - **PLAN 追記: `Package.swift` の変更は不要**。`import IOKit` / `import IOKit.pwr_mgt` だけで
      autolink され、`rec` / `rec-probe` のリンクも通る（`-framework IOKit` は要らない）
    - 確定した API（T8 / T9 はこの名前で配線する）:
      `StopCoordinator(queue:onFirstRequest:)` / `request(_:) -> Bool` / `reason: StopReason?`；
      `SignalWatcher(signals:queue:handler:)` / `cancel()`；
      `PowerNotification(messageType:argument:)` + 上の static 定数 3 本 / `PowerSource`（`register(queue:handler:)` /
      `unregister()` / `acknowledge(_:)`）/ `IOKitPowerSource()` / `PowerWatcher(source:queue:handler:)` /
      `start() throws` / `stop()`
    - 契約の補足（PLAN 本文に無かった点を実装で確定）:
      (1) **`onFirstRequest` と `handler` は init で注入する**（後から差せるプロパティにしない）。
          根拠: 可変プロパティにすると「`request` と代入の競合」を型の中で防げない
      (2) `StopCoordinator.request` は**ロックの外で** `queue.async` する。IO キュー（`sink` の中）から
          呼ばれても、ハンドラは必ずセッションキューに移る（`TapRecorder.stop()` の `ioQueue.sync {}` 回避）
      (3) `PowerWatcher.handler` の引数は `StopReason`（`.sleep` を渡す）。専用の enum は作らない
      (4) `IOKitPowerSource.unregister` の順序は QA1340 のサンプルどおり
          「`IONotificationPortSetDispatchQueue(port, nil)`（配送停止）→ `IODeregisterForSystemPower` →
          `IOServiceClose` → `IONotificationPortDestroy`」。**配送を止めてから port を壊す**
          （走っているコールバックと破棄がすれ違わない）
      (5) ack は `receive` の `defer` に置いた。`WillSleep` は handler → ack、`CanSystemSleep` は ack のみ、
          `HasPoweredOn` は `default` で何もしない（ack を呼ばない経路を作らない）
      (6) `request(_:)` に `@discardableResult` は**付けていない**。T8 / T9 で戻り値を見ない呼び出しは
          `_ = coordinator.request(...)` と書く
    - **既存テストの期待値を変えた箇所（1 件・期待値そのものは不変）**:
      `Tests/RecCoreTests/TapRecorderTests.swift` の `aggregateDescriptionDisablesTapAutoStart` で
      `try #require(boolValue(...))` → `#expect(autoStart == false)` に変えた。理由: `Bool?` を `#require` に
      渡すと「条件として見るか unwrap するか」が曖昧で warning になる（T5 からの持ち越し）。
      比較 1 本で「辞書にある」と「false」を同時に見るので検査の強さは同じ

- [x] T7: Chrome 制御（`ScriptRunner` / `ChromeController` / probe JS と `ProbeResult`）
  - 完了基準:
    - `Sources/RecCore/ScriptRunner.swift`: `struct ScriptResult { status: Int32; stdout: String; stderr: String }`、
      `protocol ScriptRunner { func run(script: String, arguments: [String]) throws -> ScriptResult }`、
      `final class OsascriptRunner: ScriptRunner`（`/usr/bin/osascript -e <script> -- <args…>`。**URL / JS / tab ID は argv で渡し、script 本文に埋め込まない**。
      `Process` の起動失敗は `RecError(.chromeUnavailable)`。タイムアウト 15 秒で `terminate()`）
    - `Sources/RecCore/ChromeController.swift`: `final class ChromeController`（`init(runner: ScriptRunner)`）
      `func checkAutomation() throws`（`tell application "Google Chrome" to get version`。stderr に `-1743` → `RecError(.chromeUnavailable, オートメーション案内)`、
      その他の失敗 → `RecError(.chromeUnavailable, "Chrome を制御できません: <stderr 1 行目>")`。参考: `~/workspaces/openclaw/sample1/upstream/openclaw/apps/macos/Sources/OpenClaw/PermissionManager.swift` 380-395 付近）、
      `func open(url: String) throws -> String`（`on run argv` で `make new window` → `set URL of active tab of w to (item 1 of argv)` → id を返す。RESEARCH §3.1 の形）、
      `func execute(tab: String, js: String) throws -> String?`（全ウィンドウ走査で id 一致 → `return execute t javascript (item 2 of argv)`。見つからなければ `"gone"`。
      戻り値が `"gone"` なら `.tabClosed` を throw、stderr に `turned off` か `オフ` → `RecError(.chromeUnavailable, JS 許可の案内)`（rec.swift:151 の判定を維持、`exit(1)` は撤廃）、
      `missing value` / 空は `nil`）、`func title(tab:) throws -> String?`（`title of t`）、`func close(tab:)`（失敗は無視）
    - `Sources/RecCore/ProbeJS.swift`: `let probeJS: String`（1 つの JS。副作用: `v.paused && !v.ended` なら `play()`（rec.swift:192 を維持）。
      戻り値: video が無ければ `"none"`、あれば `JSON.stringify({kind, state, id, cur, dur, live, title, len, playErr})`、決めた事項 #9）、
      `let rewindJS: String`（`v.currentTime = Math.max(0, v.currentTime - <Tuning.adResumeRewindSeconds>)`）、`let seekToStartJS: String`（rec.swift:226）、
      `struct ProbeResult: Decodable`（#9 のフィールド）と `enum ProbeOutcome { case none, gone, result(ProbeResult) }`、`func parseProbe(_ raw: String?) -> ProbeOutcome`
      （JSON が壊れていれば `.none` 扱い。例外を外に出さない）
    - ユニット（§3.1 検証方法, A4, A6, §5.3）: `FakeRunner` に `"`、`\`、`'`、改行、`%` を含む URL と JS を渡して script 本文が固定文字列と一致し、argv に生の値が入る；
      stderr `-1743` → `.chromeUnavailable`；stderr `… is turned off` と `…オフ…` → JS 案内付き `.chromeUnavailable`；stdout `gone` → `.tabClosed`；
      `missing value` → nil；`"none"` → `.none`；壊れた JSON → `.none`；`dur: "inf"` → `live` が true で解釈される；`len` 無し（非公開動画）でも decode できる。
      **実機 1 回**（Chrome がありオートメーション許可があれば）: `OsascriptRunner` で `on run argv … return item 1 of argv` に `a"b\c'd` を渡して往復一致
      （許可が無ければ PROGRESS に記録して続行）
    - 担う落とし穴: §3.1（エスケープ）、§3.2（-1743 / JS 許可）、A4（セレクタ OR）、A6（nil と none の区別）、§2.6（`--`）、P1 の一部（exit 撤廃）
  - 対象: `Sources/RecCore/ScriptRunner.swift`, `Sources/RecCore/ChromeController.swift`, `Sources/RecCore/ProbeJS.swift`,
    `Tests/RecCoreTests/Fakes/FakeRunner.swift`, `Tests/RecCoreTests/ChromeControllerTests.swift`, `Tests/RecCoreTests/ProbeResultTests.swift`
  - 依存: T3（`RecError`, `ExitCode`）, T4（`Tuning`）
  - 並列サブ作業:
    - A: ScriptRunner + ChromeController + FakeRunner + テスト（対象: `ScriptRunner.swift`, `ChromeController.swift`, `Fakes/FakeRunner.swift`, `ChromeControllerTests.swift`）
    - B: ProbeJS + ProbeResult + テスト（対象: `ProbeJS.swift`, `ProbeResultTests.swift`）
  - **T7 の実測（turn 9）**:
    - **PLAN 訂正: サブ作業の割り方**。共有物（`ScriptRunner.swift` の `ScriptResult` + protocol + `OsascriptRunner`、
      `Tests/.../Fakes/FakeRunner.swift`）は**親が両方作り**、並列に出したのは 3 本にした:
      A（`ChromeController.swift` の実装）/ B（`ChromeControllerTests.swift` を契約から独立に記述。
      実装は読まない）/ C（`ProbeJS.swift` + `ProbeResultTests.swift`）。
      根拠: T5 turn 7 と同じ「protocol とその test double は同時に書かないと噛み合わない」。
      結果: **B のテスト 25 本は A の実装に 1 行も手を入れずそのままコンパイル・green**（API サーフェスの食い違い 0 件）
    - **PLAN 訂正: `Legacy.swift` の `probeJS` を `legacyProbeJS` に改名した**（宣言 + 参照 3 箇所）。
      根拠: 旧実装の内部トップレベル `let probeJS`（空白区切り 5 フィールドを返す JS）が
      新しい `public let probeJS` と**同じモジュール内で名前衝突**する（`invalid redeclaration`）。
      `LegacyRecorder` と同じ扱い（T9 でこのファイルもろとも消える）
    - 確定した API（T8 / T9 はこの名前で配線する）:
      `ScriptResult(status:stdout:stderr:)` / `ScriptRunner.run(script:arguments:)` /
      `OsascriptRunner(executable:timeout:)` + `OsascriptRunner.argumentList(script:arguments:)`；
      `ChromeController(runner:)` / `checkAutomation() throws` / `open(url:) throws -> String` /
      `execute(tab:js:) throws -> String?` / `title(tab:) throws -> String?` / `close(tab:)`（throws なし）；
      `probeJS` / `rewindJS` / `seekToStartJS`（トップレベル `public let`）/ `ProbeKind { main, ad }` /
      `ProbeState { playing, paused, ended, loading }` / `ProbeResult`（9 プロパティ + `CodingKeys: CaseIterable`）/
      `ProbeOutcome { none, gone, result(ProbeResult) }` / `parseProbe(_:) -> ProbeOutcome`（throws なし）
    - 契約の補足（PLAN 本文に無かった点を実装で確定）:
      (1) **`OsascriptRunner` は stdout / stderr を生のまま返す**（末尾の改行も落とさない）。trim は
          `ChromeController` の責任。引数列は常に `["-e", script, "--"] + arguments`
      (2) **`osascript` の打ち切り（既定 `Tuning.osascriptTimeoutSeconds` = 15 秒）は throw せず
          `ScriptResult(status: -1, stderr: <打ち切りの説明>)` を返す**。「応答なしをエラーにするか待ちにするか」は
          呼び出し側の判断（`execute` では `nil` に落ち、上位が連続回数で `.pageUnresponsive` を決める）。
          パイプの読み出しは別スレッドに逃がす（64 KB を超えると読まずに終了を待つと戻らない）
      (3) `execute` / `title` の判定順は固定: `turned off` / `オフ` → `-1743` → **それ以外の非 0 は
          throw せず `nil`** → `gone` は `RecError(.pageLost)` → `missing value` / 空は `nil` → それ以外は trim 済み文字列。
          `title` も `execute` と同じ規則（非 0 は `nil`）
      (4) `checkAutomation` / `open` の非 0 は `-1743` → `Messages.chromeAutomationPermission`、
          それ以外 → `"Chrome を制御できません: <stderr の 1 行目>"`（1 行目 = 全体を trim してから改行で分割した先頭）。
          **`runner.run` 自体の throw は握りつぶさず伝播する**
      (5) `ProbeResult.live` は **JSON の `live` をそのまま読む**。`dur` が無限だから `live` を true にする
          Swift 側の推論は入れていない（その判定は JS 側の契約 = 決めた事項 #9）
      (6) `ProbeKind` / `ProbeState` は raw String の enum。**未知の値はデコード失敗 → `parseProbe` が `.none`**。
          `ProbeOutcome` に `Equatable` は付けていない（テスト側がパターンマッチの helper を持つ）。
          `ProbeResult` は `Equatable` だが `dur` が NaN の 2 値は `==` が false になる
      (7) `len` は JS の `Number(vd.lengthSeconds)` が NaN のとき `JSON.stringify` が `null` にするのに依存して
          `len: nil` になる（`vd` はあるが `lengthSeconds` が無い場合。JavaScriptCore で実測確認済み）
    - **T8 への申し送り（#10 の表との橋渡し）**: `execute` はタブ消失で `RecError(.pageLost)` を **throw する**が、
      決めた事項 #10 の表は `gone` を**入力**に持つ。T8 は probe の呼び出しを `catch` して
      `RecError(code: .pageLost)` を `ProbeOutcome.gone` として policy に渡すこと（`parseProbe("gone")` も
      `.gone` を返すので、どちらの経路でも表の `gone` 行に合流する）
    - **実機の実測（turn 9）**: (a) `osascript -e 'on run argv … return item 1 of argv' -- <値>` の往復を
      `a"b\c'd%20` と**改行を含む値**で確認 → どちらも生のまま戻る（文字数 7 を AppleScript 側で数えて確認）。
      §3.1 のエスケープ方針は実機で裏が取れた。(b) **Chrome のオートメーション許可はすでにある**:
      `timeout 10 osascript -e 'tell application "Google Chrome" to get version'` が `157.0.8103.39` を返した
      （-1743 は出ない。T2 turn 4 で足りないと分かったのは**システム音声の取得**の許可だけ）。
      (c) JS 許可（表示 > 開発/管理 > Apple Events からの JavaScript）は**未確認**（タブを開く副作用を
      無人ターンで起こさないため。verify-permission.sh / T10 で確かめる）

- [ ] T8: `--url` の状態機械（`SessionPolicy`）と `RecordingSession`（オーケストレーション）
  - 完了基準:
    - `Sources/RecCore/SessionPolicy.swift`: 純粋な状態機械。`struct SessionPolicy`（`mutating func step(probe: ProbeOutcome, meter: MeterSnapshot, now: Date) -> [SessionAction]`、
      `enum SessionAction { case wait, startRecording(title: String?), seekToStart, openGate, closeGateDiscard, closeGateHold, rewindThenOpenGate, warn(String), stop(StopReason) }`）。
      決めた事項 #10 の表を**そのまま**実装する（表に無い挙動を足さない）
    - `Sources/RecCore/RecordingSession.swift`: `final class RecordingSession`（セッションキュー `rec.session` 上で動く。`DispatchSourceTimer` で `Tuning.pollIntervalSeconds` ごとに
      probe → policy → action 実行。`StopCoordinator` / `SignalWatcher` / `PowerWatcher` / `TapRecorder.onEvent` / `RecordingPipeline.onWriteError` をすべて `coordinator.request` に接続。
      停止処理 `finish()`: timer 停止 → `recorder.stop()` → `pipeline.finish()` → 0 フレームならファイル削除 + 「データなし」→ 無音判定（#7）→ tab を閉じる（#11）→
      `completion(ExitCode)` を 1 回。`finish()` は冪等）。3 モード（system / app / url）を同じクラスで扱う（url 以外は probe なし・gate 常時開・guard 0）
    - ユニット（A5, A6, A7, L4, P7, #10 の全行）: `SessionPolicy` に系列を流す — `none`×N（60 秒未満）→ wait；`none` 60 秒超 → stop(.pageUnavailable)；
      初回完全状態で live → stop(.liveStream)；初回 `main playing` → `[startRecording, seekToStart, openGate]`；`ad` → closeGateDiscard（1 回だけ）；`ad`→`main playing` → rewindThenOpenGate；
      `main paused` → closeGateHold；`main ended` → stop(.ended)；`main playing` 別 id → stop(.nextVideo)；`ad playing` 別 id → 継続；録音開始後 `nil`×（20 秒）→ stop(.pageUnresponsive)、
      19 秒後に正常値で復帰；`main playing` + `consecutiveAllZeroSeconds ≥ 10` で `everNonZero` → stop(.tapStalled)、`!everNonZero` → stop(.permissionSuspected)；
      `dur > len × 1.2` → warn 1 回だけ；`consecutiveSilentSeconds ≥ 5`（gate 開）→ warn、30 秒以内は再警告なし。
      `RecordingSession` は FakeHAL + FakeRunner + FakeWriter で「開始→ended→completion(.ok)」と「開始→signal→completion(130)」と「write エラー→completion(7)」の 3 本
    - Legacy.swift から `recordURL` を削る（`recordLive` は T9 で消す）
    - 担う落とし穴: A2（巻き戻し）, A3（README 記載は T11）, A5, A6, A7, L4, P7（警告のレート制限）, §5.2
  - 対象: `Sources/RecCore/SessionPolicy.swift`, `Sources/RecCore/RecordingSession.swift`, `Sources/RecCore/Legacy.swift`,
    `Tests/RecCoreTests/SessionPolicyTests.swift`, `Tests/RecCoreTests/RecordingSessionTests.swift`
  - 依存: T5, T6, T7
  - 並列サブ作業:
    - A: SessionPolicy（対象: `SessionPolicy.swift`）
    - B: SessionPolicy のテストを #10 の表から独立に書く（対象: `SessionPolicyTests.swift`。A の実装は見ない）
    - C: RecordingSession + テスト（対象: `RecordingSession.swift`, `RecordingSessionTests.swift`。A の `SessionAction` 名は上記で固定）

- [ ] T9: CLI の配線（`main.swift` の一本化、3 モード復元、`--app` の bundleIDs 化、Legacy 削除）
  - 完了基準:
    - `Sources/RecCore/CLI.swift`: `struct Options`（`mode: .list | .system | .app(String) | .url(String)`、`output: String?`、`adGuard: Double`（既定 `Tuning.adGuardSeconds`））、
      `func parseArguments(_ args: [String]) throws -> Options`（未知の引数・値なし・`--ad-guard` が数値でない／負／10 超 → `RecError(.usage)`。`--url` の値は `URL(string:)` でパースでき
      scheme が `http` / `https` / `file` で、http(s) なら host が空でない。それ以外 → `.usage` と「URL 不正」）、`let usageText: String`（rec.swift:7-14 を更新）
    - `Sources/rec/main.swift`（**`exit()` を呼ぶのはこのファイルだけ**）: parse → `--list` は `audioProcesses()` を表示して 0 →
      それ以外は `RecordingSession` を作り `completion` で `exit(code.rawValue)`、`dispatchMain()`。`catch` は stderr に `error: <message>` と出して `error.code`（`RecError` 以外は 8）。
      `-o` 無しの既定名: url は probe のタイトル（`sanitizeFileName` が nil なら `defaultBaseName`）、他は `defaultBaseName`。`-o` も `reserveUniquePath` を通す
    - `--app X`: `TapTarget.bundleIDs([X] + 現在の一覧で `X.` を前置に持つ ID, seed: それらのプロセス)`（D4。使い方は変えない）。一致なしは `.usage` で rec.swift:304 と同文
    - `Sources/RecCore/Legacy.swift` を削除。`rg -n 'exit\(' Sources` の結果が `Sources/rec/main.swift` のみ。`rg -n 'Legacy' Sources Tests` が 0
    - ユニット: `parseArguments` の表（`--bogus`、`--url` 値なし、`--url 'not a url'`、`--url 'https://'`、`--url 'file:///x.html?v=1'` 可、`--ad-guard -1` / `abc` / `11` 不可、`--ad-guard 0` 可）
    - 統合（このターンで実行。TCC / オートメーション許可が無い項目は PROGRESS に「未実施」と書いて T11 のスクリプトに委ねる）:
      `.build/debug/rec --bogus` → exit 1；`.build/debug/rec --url 'not a url'` → exit 1 で stderr に「URL」；`.build/debug/rec -o .gsd-lite/logs/rec-cli-hardening/scratch/t9.m4a`
      を 3 秒後に `kill -INT` → exit 130、`afinfo` が duration を返す、同名で再実行すると `t9-2.m4a`；`kill -TERM` → 143；`kill -HUP` → 129；
      1 秒未満で `kill -INT` → 空ファイルが残らない（P4）
    - 担う落とし穴: P1（完成）, P2, P4, P5（`-o`）, §8-2, §8-3, D14（3 モード維持）
    - **PLAN 追記（T3 turn 5 の申し送り）**: `reserveUniquePath` は `O_EXCL` で **0 バイトのファイルを先に作って
      予約する**。録音が 1 フレームも書けずに終わったときは、決めた事項 #7 の「`framesWritten == 0` →
      ファイル削除 + 「データなし」（`Messages.noData`）」でこの空ファイルを必ず消すこと（上の「空ファイルが
      残らない（P4）」は同じことを言っている）。`Messages` の各文字列は末尾に改行を含まないので、
      stderr に出す側で改行を足す
  - 対象: `Sources/RecCore/CLI.swift`, `Sources/rec/main.swift`, `Sources/RecCore/Legacy.swift`（削除）, `Tests/RecCoreTests/CLITests.swift`, `README.md`（使い方節の下書き）
  - 依存: T8
  - 並列サブ作業:
    - A: CLI.swift + CLITests（対象: `CLI.swift`, `CLITests.swift`）
    - B: main.swift の配線と Legacy 削除（対象: `main.swift`, `Legacy.swift`）

- [ ] T10: ローカル検証ページ・トーン生成・Goertzel 判定器・`scripts/verify-adtest.sh`
  - 完了基準:
    - `Sources/RecCore/ToneAnalyzer.swift`: `func goertzelPower(_ samples: [Float], sampleRate: Double, hz: Double) -> Double`、
      `struct ToneVerdict { adWindows: Int; mainSeconds: Double; silentSeconds: Double; totalSeconds: Double }`、
      `func analyze(url: URL, mainHz: Double, adHz: Double, windowSeconds: Double = 0.1) throws -> ToneVerdict`（`AVAudioFile(forReading:)` で読み、100 ms 窓ごとに
      main / ad のエネルギー比較。「ad 優勢の窓」= ad エネルギーが main の 3 倍超かつ -50 dBFS 超）、`func isAllZero(url:) throws -> Bool`（verify-permission 用）
    - `Sources/RecCore/ToneFiles.swift`: `func writeTone(url:, hz:, seconds:, sampleRate: 48000, amplitude: 0.5)`（`AVAudioFile` で WAV。ffmpeg 不要）
    - `rec-probe tones <dir>`（`main.wav` 440 Hz 12 秒、`ad.wav` 1 kHz 4 秒を生成）、`rec-probe analyze <file> --main 440 --ad 1000 --expect-main 12`
      （JSON で verdict を出し、`adWindows == 0` かつ `|mainSeconds − expect| < 1.0` なら exit 0、それ以外 1）、`rec-probe analyze <file> --silence`（全ゼロなら exit 1）
    - `Tests/Fixtures/adtest.html`（決めた事項 #12 の DOM と進行。`?v=` を id に使う。`document.title` = `Local Ad Test`）
    - `scripts/verify-adtest.sh`: `scripts/build.sh` → `rec-probe tones Tests/Fixtures` → `.build/debug/rec --url "file://<絶対パス>/adtest.html?v=local1" -o <scratch>/adtest.m4a`
      （180 秒で諦めて kill）→ `rec-probe analyze … --expect-main 12` → 結果を stdout に出して exit を伝播。rec の exit が 6 で stderr に `playErr` があれば
      「自動再生が拒否された」と案内して exit 2（メモ「自動再生の段階的対処」）
    - ユニット: 合成信号（440 Hz 12 秒）→ `adWindows == 0`, `mainSeconds ≈ 12`；中央 1 秒を 1 kHz にした信号 → `adWindows ≈ 10`；全ゼロ → `isAllZero` true、
      -70 dBFS 雑音 → false；`writeTone` → 読み戻して長さ一致
    - 実機（このターンで 1 回試す。許可が無ければ PROGRESS に記録）: `scripts/verify-adtest.sh` を実行し、exit 0 なら「広告混入 0・境界 < 1 秒」を PROGRESS に数値で残す。
      exit 2（自動再生拒否）ならメモの段階的対処を順に試し、どこまで試したかを PROGRESS と README に書く
    - 担う落とし穴: A1, A2（実測）, §7.5, B5（`--silence`）, D11
  - 対象: `Sources/RecCore/ToneAnalyzer.swift`, `Sources/RecCore/ToneFiles.swift`, `Sources/rec-probe/main.swift`, `Tests/Fixtures/adtest.html`, `scripts/verify-adtest.sh`,
    `Tests/RecCoreTests/ToneAnalyzerTests.swift`
  - 依存: T9
  - 並列サブ作業:
    - A: ToneAnalyzer + ToneFiles + テスト（対象: `ToneAnalyzer.swift`, `ToneFiles.swift`, `ToneAnalyzerTests.swift`）
    - B: adtest.html + verify-adtest.sh + rec-probe のサブコマンド（対象: `Tests/Fixtures/adtest.html`, `scripts/verify-adtest.sh`, `Sources/rec-probe/main.swift`。A の関数名は上記で固定）

- [ ] T11: README 完成・実機検証スクリプト・final-check の仕上げ・文書の整合
  - 完了基準:
    - `README.md`: 使い方（4 モードと `-o` / `--ad-guard`）、ビルド / テスト（T1）、**許可 3 種**（システム音声 / オートメーション / Apple Events からの JavaScript）と
      tmux の注意（RESEARCH §2.5: 許可はターミナルアプリに付く。tmux 内で出ない場合は tmux の外で 1 回実行し `tmux kill-server` 後に再起動）、`tccutil reset` の手順、
      終了コード表（決めた事項 #3 と同一）、既知の制約（他タブの音の混入（D5）、SSAI 時の精度低下、SIGKILL / 電源断で m4a が壊れる、手動一時停止を自動再生してしまう（A3）、
      ライブ配信非対応、出力デバイス切替・スリープで停止して保存（自動復旧なし）、`--url` は `<video>` のあるページをベストエフォート・広告判定は YouTube のみ、
      macOS 26 以上）、検証スクリプト一覧（本数を書く）、ローカル検証ページの使い方と自動再生の対処
    - `scripts/verify-permission.sh`（2 秒のシステム全体録音 → `rec-probe analyze --silence` → 全ゼロなら許可案内を出して exit 1。B5）。
      **T2 turn 4 の実測を反映**: 許可が無いときは「全ゼロ」ではなく**録音開始が無期限にブロックする**（ダイアログも出ない）。
      このスクリプトは最初に `swift run rec-probe tap system 2`（内部 10 秒 watchdog, exit 8）で**開始できるか**を見て、
      exit 8 なら「システム音声の取得の許可」案内（**責任プロセスはターミナルアプリ = iTerm2**。
      システム設定 > プライバシーとセキュリティ > システム音声の録音 で iTerm2 を許可し、**iTerm2 を再起動**する。
      RESEARCH §2.5 / §5.1「許可変更はホストアプリ再起動後に反映」）を出して exit 1、その後に全ゼロ判定を行う
      `scripts/verify-signals.sh`（INT / TERM / HUP それぞれ: 3 秒録音 → kill → exit 130/143/129 と `afinfo` duration ≥ 2 秒。P2）、
      `scripts/verify-youtube.sh [URL]`（既定 `https://www.youtube.com/watch?v=jNQXAC9IVRw`。完走で exit 0、`afinfo` duration > 0、出力名がタイトル由来）、
      `scripts/verify-helper-restart.sh [URL]`（録音 10 秒後に `pkill -f audio.mojom.AudioService` → 完走後 `rec-probe analyze` で後半にも可聴窓がある。L1 (c)）、
      `scripts/verify-longrun.sh [分=10]`（システム全体録音を N 分、`ps -o rss=` を 1 分と N 分で比較し差 < 10 MB。L6, L7）。
      いずれも `timeout` コマンドに依存せず bash の `sleep` + `kill` で制御。出力は `.gsd-lite/logs/rec-cli-hardening/scratch/` 配下
    - `scripts/final-check.sh` の `rg` 検査を全部有効化（追従先チェックリストの各行 + `rg -n 'rec\.swift:[0-9]' Sources README.md` が 0 + `ls rec.swift` が失敗）
    - 実機（このターンで実行できるものは実行し、結果を PROGRESS に数値で。許可が無ければ「未実施」と理由）: verify-permission → verify-signals → verify-youtube。
      verify-helper-restart と verify-longrun は時間があれば（longrun は 3 分で代用可、既定は 10 分）
    - 担う落とし穴: B5, P2, L1(c), L6, L7, §8-4（README の既知の制約）、D5
  - 対象: `README.md`, `scripts/verify-permission.sh`, `scripts/verify-signals.sh`, `scripts/verify-youtube.sh`, `scripts/verify-helper-restart.sh`, `scripts/verify-longrun.sh`, `scripts/final-check.sh`
  - 依存: T10
  - 並列サブ作業:
    - A: README（対象: `README.md`）
    - B: verify スクリプト 5 本 + final-check 仕上げ（対象: `scripts/*`）

## 決めた事項

1. **allowlist**（ユーザーが `.claude/settings.json` に追加する。plan ターンの Edit は権限拒否。一覧は BLOCKED.md と同一）: `Bash(swift:*)`, `Bash(env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift:*)`,
   `Bash(scripts/:*)`, `Bash(./scripts/:*)`, `Bash(bash scripts/:*)`, `Bash(.build/:*)`, `Bash(xcrun:*)`, `Bash(otool:*)`, `Bash(afinfo:*)`, `Bash(plutil:*)`,
   `Bash(osascript:*)`, `Bash(kill:*)`, `Bash(ps:*)`, `Bash(pkill -f audio.mojom.AudioService)`, `Bash(chmod:*)`, `Bash(cp:*)`, `Bash(touch:*)`, `Bash(git mv:*)`, `Bash(git rm:*)`,
   `Bash(rm -rf .build)`, `Bash(rm .gsd-lite/logs/:*)`, `Bash(rm -f .gsd-lite/logs/:*)`, `Bash(rm -rf .gsd-lite/logs/:*)`, `Bash(timeout:*)`, `Bash(python3 -m http.server:*)`,
   `Bash(defaults read:*)`, `Bash(sw_vers:*)`, `Bash(which:*)`, `Bash(file:*)`, `Bash(stat:*)`, `Bash(tr:*)`, `Bash(xxd:*)`, `Read(/Applications/Xcode.app/**)`, `Read(/Library/Developer/CommandLineTools/**)`
   （根拠: RESEARCH §0、PROGRESS turn 1 の申し送り、loop.log の WARN「allowlist に足すか」）。`pmset sleepnow` / `defaults write` / `sudo` は**入れない**
   （無人ループ中にスリープや Chrome 設定を変えない。スリープ検証は VERIFICATION に「手動確認」として残す）
2. **Chrome の tap 対象（T2 が確定して書き換える）**: 初期値 `chromeTapTarget = .bundleIDs(chromeBundleIDs, seed: <起動時に prefix "com.google.Chrome" で一致した running 含む全プロセス>)`
   （hybrid）、`chromeBundleIDs = ["com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.helper.renderer", "com.google.Chrome.helper.gpu", "com.google.Chrome.helper.plugin", "com.google.Chrome.helper.alerts"]`
   （T2 (0) の実測で `["com.google.Chrome", "com.google.Chrome.helper"]` の 2 名に確定。コードは `RecCore.Chrome.bundleIDs`）。`isProcessRestoreEnabled = true`。
   録音開始（`TapRecorder.start`）は rec.swift:212-219 と同じく「Chrome の音声プロセスが running になった後」に
   行う（seed を取るため。bundleIDs 単独で動いてもこの待ちは残す）。
   **T2 の結果（turn 4）: `hybrid`（`bundleIDs` + seed）のまま確定。** (a)〜(e) の音の有無は許可が降りていないため未実測
   （`AudioDeviceCreateIOProcIDWithBlock` がブロックする。T2 の実測欄）。許可が降りた後に `swift run rec-probe tap bundleids 3` /
   `hybrid` / `processes` を回して、(b)(c)(d) が全部可なら seed なしに落とす（verify の宿題。VERIFICATION に手動項目として残す）。
   実測で `running` になるのは `com.google.Chrome.helper` だけなので、seed にはこのヘルパーが必ず入る
3. **終了コードと停止理由**（根拠: RESEARCH §8-2、audiograb の方式。README の表はこれと同一にする）:

   | code | `ExitCode` | 意味 | `StopReason` / 発生箇所 |
   |---|---|---|---|
   | 0 | `.ok` | 正常終了 | `.ended`（再生終了）, `.nextVideo`（次の動画へ遷移: 現行動作 rec.swift:241 を維持） |
   | 1 | `.usage` | 引数・URL 不正、`--app` に一致なし | `parseArguments` |
   | 2 | `.chromeUnavailable` | Chrome 制御不可（起動不可・オートメーション未許可 -1743・JS 許可オフ・ウィンドウ作成失敗） | `ChromeController` |
   | 3 | `.liveStream` | ライブ配信 / プレミア公開 | `.liveStream`（録音開始前。開いたタブは閉じる） |
   | 4 | `.silent` | 全編無音（権限なしの疑い）。ファイルは残す | 終了時判定（#7）, `.permissionSuspected` |
   | 5 | `.interrupted` | 出力デバイス変更・スリープ・coreaudiod 再起動・IO 異常停止・デバイス消失・tap 故障 | `.deviceChanged`, `.sleep`, `.serviceRestarted`, `.ioStopped`, `.deviceDied`, `.tapStalled` |
   | 6 | `.pageLost` | タブ閉鎖・60 秒以内に動画が見つからない/再生開始しない・20 秒応答なし | `.tabClosed`, `.pageUnavailable`, `.pageUnresponsive` |
   | 7 | `.outputUnavailable` | 出力ファイルを作れない・書き込みエラー | `OutputPath`, `AVAudioFileWriter`, `.writeFailed` |
   | 8 | `.coreAudio` | tap / aggregate / IOProc の作成・開始失敗、`--list` 取得失敗、その他の予期しないエラー | `TapRecorder.start`, main の catch-all |
   | 129 / 130 / 143 | `.signal(HUP/INT/TERM)` | シグナルで中断（128 + 番号） | `.signal(Int32)` |

   優先順位: 停止理由の code が非ゼロならそれ。ゼロ（`.ended` / `.nextVideo`）のときだけ無音判定で 4 になりうる。無音の案内文は理由に関係なく全編無音なら出す
4. **広告ガード**: `Tuning.adGuardSeconds = 1.0`（`--ad-guard` で 0〜10）、`Tuning.adResumeRewindSeconds = 0.7`（広告明けに `rewindJS` → gate を開く。順序固定）、
   広告判定セレクタ `#movie_player.ad-showing, #movie_player.ad-interrupting`（RESEARCH §5.3, A4）。遅延線は URL モードだけ。他モードは guard 0
5. **ポーリング**: `Tuning.pollIntervalSeconds = 0.5`（rec.swift:232 の 0.3 から緩める。L7）、`Tuning.startTimeoutSeconds = 60`（rec.swift:211 と同じ）、
   `Tuning.unresponsiveSeconds = 20`（A6）、osascript 1 回のタイムアウト 15 秒
6. **無音の閾値**: `Tuning.silenceDBFS = -60.0`（silent iff `dBFS < -60.0`、ちょうどは非 silent）、`Tuning.meterWindowSeconds = 1.0`、
   警告は `Tuning.silenceWarnAfterSeconds = 5` 連続で 1 回、`Tuning.silenceWarnIntervalSeconds = 30` 以内は再警告なし。dBFS = `20·log10(max(rms, 1e-8))`（RESEARCH §5.4）
7. **全編無音の判定と tap 故障**: 終了時に `framesWritten > 0` かつ `audibleGateOpenWindows == 0` → exit 4（ファイルは残す）。`framesWritten == 0` → ファイル削除 + 「データなし」（exit は停止理由のまま。§8-3）。
   URL モードで `main playing` かつ `consecutiveAllZeroSeconds ≥ Tuning.tapStallSeconds (10)`: `everNonZero` なら `.tapStalled`（5）、そうでなければ `.permissionSuspected`（4）（§5.2, §8-1）。
   system / app モードではこの 10 秒判定は行わない（無音が正当にありうる）
8. **SSAI 警告**: `dur` が有限で `len` があり `dur > len × 1.2` なら 1 回だけ警告（A5）
9. **probe JSON**（`ProbeResult` のフィールド。JS と Decodable で同数にする）: `kind` (`"main"` / `"ad"`), `state` (`"playing"` / `"paused"` / `"ended"` / `"loading"`。`loading` は `v.readyState < 1`),
   `id` (`?v=` の値、無ければ `"-"`), `cur` (Double), `dur` (Double。`Infinity` は `"inf"`、`NaN` は `"nan"` の文字列で送り Swift 側で解釈), `live` (Bool:
   `vd.isLive === true || vd.isUpcoming === true || v.duration === Infinity`。`vd = window.ytInitialPlayerResponse?.videoDetails`), `title` (String?: `vd.title` → `document.title.replace(/ - YouTube$/, '')`),
   `len` (Double?: `Number(vd.lengthSeconds)`), `playErr` (String?: `play()` の reject 名)。video が無ければ文字列 `none`
10. **SessionPolicy の表**（T8 はこの表だけを実装する。impl が表の不備を見つけたら PLAN を直して PROGRESS に `PLAN 訂正`）:

   | 状態 / 入力 | 行動 |
   |---|---|
   | 録音開始前、`none` / `nil` / `state == loading`、経過 < 60 秒 | `wait` |
   | 録音開始前、同上が 60 秒超 | `stop(.pageUnavailable)` |
   | `gone`（いつでも） | `stop(.tabClosed)` |
   | 録音開始前、初回の完全な状態で `live == true` | `stop(.liveStream)`（タブは閉じる） |
   | 録音開始前、初回の完全な状態（live でない） | `startRecording(title:)` → `kind == main && state == playing` なら `seekToStart` → 以降は下の行を同じ step で適用 |
   | `kind == main && state == playing`（直前が ad） | `rewindThenOpenGate` |
   | `kind == main && state == playing`（直前が ad 以外） | `openGate` |
   | `kind == main && state == paused` | `closeGateHold`（捨てない） |
   | `kind == ad`（直前が ad 以外） | `closeGateDiscard`（1 回） |
   | `kind == ad`（直前も ad） | `wait` |
   | `kind == main && id != 初回の id` | `stop(.nextVideo)` |
   | `kind == main && state == ended` | `stop(.ended)` |
   | `kind == ad && id != 初回の id` | 無視して継続（A7。rec.swift:239-243 の現行動作） |
   | 録音開始後、`none` / `nil` が 20 秒連続 | `stop(.pageUnresponsive)` |
   | `main playing` かつ `consecutiveAllZeroSeconds ≥ 10` | `everNonZero` → `stop(.tapStalled)`、否 → `stop(.permissionSuspected)` |
   | `dur` 有限 かつ `len` あり かつ `dur > len × 1.2`（未警告） | `warn("SSAI の可能性…")` |
   | gate 開 かつ `consecutiveSilentSeconds ≥ 5`（30 秒以内に未警告） | `warn("無音が続いています")` |
   | `RecorderEvent`（セッションが直接 coordinator へ） | `.defaultOutputChanged → .deviceChanged`, `.ioStoppedAbnormally → .ioStopped`, `.deviceDied → .deviceDied`, `.serviceRestarted → .serviceRestarted`, `.overload` はログのみ |
   | スリープ / シグナル / write エラー | `.sleep` / `.signal(sig)` / `.writeFailed` |

11. **タブの後始末**: 自分で開いたウィンドウのタブを閉じるのは `.ended` / `.nextVideo` / `.liveStream` のとき。シグナル・エラー・中断では閉じない（現行動作 rec.swift:252 を維持）
12. **ローカル検証ページ**（`Tests/Fixtures/adtest.html`）: `<div id="movie_player"><video id="v" src="main.wav"></video></div>`。進行: 本編 0→4 秒 → 広告 4 秒
    （`src` を `ad.wav` に替え `#movie_player` に `ad-showing` を付与、`currentTime = 0`）→ 本編を 4 秒の位置から再開（class を外す）→ 12 秒で `ended`。
    `?v=local1` を id として扱えるよう `location.search` をそのまま使う。期待: 本編合計 12 秒、広告混入 0 窓、欠落・重複 < 1 秒。`document.title = "Local Ad Test"`、
    `ytInitialPlayerResponse` は置かない（タイトルのフォールバック経路を通す）
13. **実機検証の既定 URL**: `https://www.youtube.com/watch?v=jNQXAC9IVRw`（19 秒、YouTube 最初の動画。差し替えは各 verify スクリプトの第 1 引数）
14. **出力名**: `--url` はタイトル → `sanitizeFileName` → nil なら `rec-yyyyMMdd-HHmmss`。連番は `name-2.m4a` から。`-o` も同じ連番規則（D15）。保存先は `-o` のディレクトリ、無ければカレント
15. **main の構造**: `exit()` は `Sources/rec/main.swift` のみ。`dispatchMain()` で待ち、`RecordingSession.completion` から `exit`。IOKit は `IONotificationPortSetDispatchQueue`
    でセッションキューに載せる（CFRunLoop を回さない）。シグナルは `SIG_IGN` → `DispatchSource`。（根拠: RESEARCH §2.2, §2.3、rec.swift:153/267/287/290/312 の `exit`）
16. **aggregate の主デバイス**: `kAudioHardwarePropertyDefaultOutputDevice`（rec.swift:89 の `DefaultSystemOutputDevice` から変更。RESEARCH §8-7）
17. **言語モード**: Swift 6（`swiftLanguageModes: [.v6]`）。IO / セッションの状態を持つクラスは `@unchecked Sendable` + 「指定キューでのみ触る」規約（RESEARCH §4）

## メモ

- **振り返り**: `.gsd-lite/reflect/` は空（初回マイルストーン）。反映した提案はなし
- **【verify 前に必要な人の操作】システム音声の取得の許可**（T2 turn 4 で判明）: tap と aggregate は作れるが
  `AudioDeviceCreateIOProcIDWithBlock` が**無期限にブロックし、許可ダイアログも出ない**。`system` / `hybrid` 両 variant、
  `TapAutoStart` false、Bash サンドボックス解除のいずれでも同じ。CLI の責任プロセスはターミナルアプリなので、
  **システム設定 > プライバシーとセキュリティ > システム音声の録音 で iTerm2（ループを起動した端末）を許可し、iTerm2 を再起動する**
  必要がある（RESEARCH §2.5、§5.1 catap「許可変更はホストアプリ再起動後に反映」）。
  これが済むまで T2 (a)〜(e)・T10 の実機トーン検証・T11 の verify-* は実行できない（T1〜T9 の機械検証は影響なし）。
  **無人ターンの作法**: 録音を開始するコマンドを `swift run` で直に待たない（固まる）。必ず
  `rec-probe` の 10 秒 watchdog 相当を通すか `run_in_background` にする
- **`.build` 配下の実行**: `Bash(.build/debug/rec:*)` は allowlist の prefix ルール（完全一致 or prefix + 空白）により
  `rec` には当たるが `rec-probe` には当たらない。無人ターンは **`swift run rec-probe …`**（`Bash(swift:*)` に当たる）を使う
- **タスク数 11**: 目安 8〜15 の範囲内。T3 / T4 / T6 / T7 は純粋ロジックで並列サブ作業が効くのでまとめた。T5（HAL 抽象化）と T8（状態機械）は
  テストの契約が独立しているので分けたまま
- **RESEARCH の「盗める点」採否**:

  | 出典 | 内容 | 採否 | 理由 |
  |---|---|---|---|
  | catap §5.1 | bundle-ID tap + `isProcessRestoreEnabled` | 採用（T2） | D4。実機プローブで確定 |
  | catap §5.1 | `TranslatePIDToProcessObject` | 却下 | PID 列挙自体をやめるので不要 |
  | catap §5.1 | 「満たせない description は tap ID 0」 | 採用（T2, T5） | 作成失敗を `.coreAudio` で扱う |
  | audiograb §5.1 | 終了コードを権限 / デバイス / IO で分ける | 採用（#3） | verify が原因を判別できる |
  | audiograb §5.1 | ロックフリー ring + 書き出しスレッド | 却下 | IOProc は同一直列キュー。遅延線で足りる（§5.5） |
  | Mimir §5.1 | デバイス変更で全部作り直し | 却下（listener 登録は採用） | D13 は「停止して確定」 |
  | AudioCap §5.1 | Stop / Destroy を全部呼ぶ | 採用（T5） | リーク防止。途中失敗の逆順破棄も |
  | AudioTee §5.1 | 再生中でない PID を含めると失敗 | 保留（T2 (a) で観測） | rec.swift は全 prefix 一致を渡して動いている |
  | forums 825780 §5.2 | 全ゼロ故障は listener で拾えない | 採用（#7） | 10 秒ルール |
  | OpenClaw TerminationSignalWatcher §6 | DispatchSource でシグナル | 採用（T6） | そのまま使える |
  | OpenClaw AudioInputDeviceObserver §6 | listener の登録と解除の対 | 採用（T5） | FakeHAL で回数一致を検証 |
  | OpenClaw PermissionManager §6 | -1743 でオートメーション未許可 | 採用（T7） | 起動前チェック |
  | Strata folder-dialog §6 | 実行コマンド注入でテスト | 採用（T7 `ScriptRunner`） | osascript なしでテスト |
  | §2.5 | CAF 中間ファイル + remux | 却下 | SIGKILL はスコープ外。README に記載 |
  | §2.5 | `AVAssetWriter.movieFragmentInterval` | 却下 | m4a での保証なし |
  | §2.5 | `AVAudioFile.close()` を明示 | 採用（T3） | `file = nil` 依存をやめる |
  | §8-5 | `--ad-guard` オプション | 採用（#4） | verify が境界を調整できる |
  | §5.3 | スキップボタン自動クリック | 却下 | 境界は遅延線で切れる。DOM 依存を増やさない |
  | §5.6 | `youtube.com/embed/` で広告回避 | 却下 | 未検証・要件外 |
  | §3 | `title of t` によるタイトル取得 | 採用（T7 `title(tab:)`） | JS 許可に依存しないフォールバック（probe の `title` が nil のとき） |
  | §5.7 Peekaboo | Package.swift の形 | 採用（T1） | library + executable + Swift Testing |
  | §2.2 | IOKit `IORegisterForSystemPower` | 採用（T6）。CFRunLoop の代わりに `IONotificationPortSetDispatchQueue` | CLI で確実。`dispatchMain()` と両立 |

- **落とし穴 → タスクの対応（漏れ確認）**: P1→T6/T7/T9、P2→T6/T9/T11、P3→T5/T6、P4→T3/T9、P5→T3/T9、P6→T3、P7→T4/T8、P8→T3/T4；
  A1→T4、A2→T4/T8/T10、A3→T11（README）、A4→T7、A5→T8、A6→T7/T8、A7→T8；L1→T2/T11、L2→T5、L3→T6、L4→T4/T8、L5→T5、L6→T4/T11、L7→T8（#5）/T11；
  B1〜B4→T1、B5→T10/T11。並行性: T3（連番の同時要求）、T5（stop の同時呼び出し、TSan）、T6（coordinator）。境界値: T3（255 バイト・空・結合文字）、
  T4（guard 0 / 超過 / 端数、-60.0 ちょうど）、T8（19 秒で復帰、別 id の広告）。異常系: T3（EROFS 等 errno 全般）、T4（write エラー）、T5（各段の失敗）、T7（-1743、turned off、壊れた JSON）
- **自動再生の段階的対処**（T10 の実機で `playErr` が出たとき。順に試し、どこまでで動いたかを README に書く）:
  (1) `file://` のまま（probe の `play()` で動く見込み）→ (2) `python3 -m http.server 8765 --directory Tests/Fixtures` で `http://localhost:8765/adtest.html?v=local1`
  （allow 済み。スクリプト内で起動して終了時に kill）→ (3) Chrome のポリシー `AutoplayAllowlist`（`defaults write com.google.Chrome AutoplayAllowlist -array 'file://*' 'http://localhost:8765'`。
  **impl は実行しない**。README に「ローカル検証ページ用の設定」として書き、verify は VERIFICATION に手動項目として残す）
- **サンドボックス**: `swift build` が `~/Library/Caches/org.swift.swiftpm` 等への書き込みで失敗したら、scripts に `--cache-path .build/.cache --config-path .build/.config --security-path .build/.security`
  を足す。それでも動かなければ BLOCKED（出力を添える）
- **Chrome を開く手段**（T2 / T7 / T10 / T11 の実機）: `osascript -e 'tell application "Google Chrome" to open location "<URL>"'` と、終了時に `rec` 自身の close。
  `open` コマンドは allow していない
- **並列サブ作業の依頼文に必ず入れる文言**（impl スキルの固定文言に加えて）: 「PLAN の API 名（型名・関数名・`Tuning` の定数名）はそのまま使う。
  別名にしたいときは実装せず報告に書く」
- **rec.swift の行番号**: この PLAN と RESEARCH の `rec.swift:NN` は T1 以降 `git show main:rec.swift` で参照する（ファイルは移動する）
