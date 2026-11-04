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
| rec.swift の行番号参照（RESEARCH / PLAN の `rec.swift:NN`） | 履歴参照（`git show 45301d8:rec.swift`）として扱い、新コードのコメントに写さない | `rg -n 'rec\.swift:[0-9]' Sources README.md` が 0 |
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

- [x] T8: `--url` の状態機械（`SessionPolicy`）と `RecordingSession`（オーケストレーション）
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
  - **T8 の実測（turn 10）**:
    - **PLAN 訂正: 対象ファイルを 3 つ足した**。(1) `Sources/RecCore/SessionAction.swift`（新規。
      `SessionAction` は A / B / C の 3 者が同時に参照する共有型なので、「共有型は親が先に確定させる」
      （T5 / T6 / T7 で 3 ターン続けて有効だった形）に従ってファイルごと親が作った。PLAN 本文は
      `SessionPolicy.swift` 内に置くと書いていたが、A がそのファイルの持ち主なので分けた）、
      (2) `Sources/RecCore/Messages.swift`（`ssaiWarning` / `silenceWarning` の 2 定数を追加。
      決めた事項 #10 の `warn(...)` の文面を Messages に集める既存方針に合わせ、親が先に確定させた。
      B のテストが `Messages.ssaiWarning` を参照できるようにするため）、
      (3) `Sources/rec/main.swift`（`Legacy.swift` から `recordURL` を削ると `--url` の呼び出し元が
      消えるので、`RecordingSession` への暫定配線を親が入れた。本配線は T9）
    - **決めた事項 #10 の表の補完（評価順を確定した）**: 表は行の羅列で順序を書いていないので、
      A / B / C に渡す仕様として次の順を固定した（これが T8 の唯一の正）:
      `gone` → 録音開始前（`none`/`nil`/`loading` の 60 秒判定 → 初回完全状態の live → startRecording）→
      録音開始後（`none` の 20 秒判定 → `main` の id 違い（nextVideo） → `main ended` →
      全ゼロ 10 秒（tapStalled / permissionSuspected） → gate 操作 1 つ → SSAI 警告 → 無音警告）。
      **stop が当たったら戻り値は `[.stop(理由)]` の 1 要素だけ**（gate 操作も警告も付けない）。
      境界は `60 秒超`（`>`）/ `20 秒連続`（`>=`）/ `全ゼロ 10 秒`（`>=`）/ `無音 5 秒`（`>=`）/
      `再警告は 30 秒超`（`>`）
    - **表に無かった入力の扱い**: 録音開始後の `main loading` は `wait`（表の `loading` 行は
      「録音開始前」限定なので、開始後は gate を動かさず待つ）。初回完全状態が `main ended` なら
      `[.startRecording(title:), .stop(.ended)]`（表をそのまま順に適用した結果。特別扱いを足さない）
    - **PLAN 訂正: 決めた事項 #8 に `len > 0` を足した**。#8 の条件は `dur` 有限 かつ `len` あり かつ
      `dur > len × 1.2` だけだが、`len == 0`（`vd.lengthSeconds` が `"0"`。`ProbeJS` の契約では
      `Number()` が NaN のときだけ `nil` になるので 0 は素通りする）だと `dur > 0` が必ず真になり、
      **普通の動画で毎回 SSAI 警告が出る**。#8 の「公称より長い」は公称が分かっている場合の話なので、
      `len == 0`（= 公称不明）では警告しない。サブ作業 A が「契約外なので実装しない」と報告で挙げ、
      親が仕様の不備と判断して入れた（`SessionPolicyTests` に 1 本追加して固定）
    - 確定した API（T9 はこの名前で配線する）:
      `SessionAction { wait, startRecording(title:), seekToStart, openGate, closeGateDiscard,
      closeGateHold, rewindThenOpenGate, warn(String), stop(StopReason) }`（`Equatable`）；
      `SessionPolicy(startedAt:)` / `mutating step(probe:meter:now:) -> [SessionAction]`（throw しない・空配列を返さない）；
      `SessionMode { system, app(TapTarget), url(String) }`；
      `SessionOutput(directory:explicitBaseName:ext:)`（`ext` の既定は `"m4a"`）；
      `RecordingSession(mode:output:adGuardSeconds:hal:runner:powerSource:signals:pollInterval:startTimeout:makeWriter:now:onMessage:completion:)`
      / `start()` / `requestStop(_:)`。**`completion` はちょうど 1 回**。`exit()` は呼ばない
    - 契約の補足（実装で確定）:
      (1) `RecordingSession` は `signals: []` と `powerSource: FakePowerSource()` でテストでき、
          `requestStop(.signal(SIGINT))` が中断の刺激口になる（本物のシグナルをテストプロセスに張らない）
      (2) **出力先の予約は「tap の開始に成功して format が確定した後」**（`reserveUniquePath` が
          0 バイトのファイルを作るので、tap が作れない場合に空ファイルを残さない）。
          `makeWriter` が失敗したときは予約したファイルを削除してから fail する
      (3) url モードは `pipeline` を作った直後に **gate を閉じて**始める（policy が同じ step の続きで開く）。
          `.system` / `.app` は `RecordingPipeline` の既定どおり gate 開で guard 0
      (4) `pipeline.finish()`（= `writer.close()`）が throw したときは、**停止理由の code が 0 のときだけ**
          `.outputUnavailable` に上書きする（決めた事項 #3 の優先順位と同じ扱い）
      (5) `Messages.overload` / `Messages.ssaiWarning` / `Messages.silenceWarning` を追加した
          （定型文は `Messages` に集める既存方針。`overload` は C がリテラルで書いたのを親が移した）
      (6) **`SessionPolicy` は stop をラッチしない**（`.stop` を返した後も通常の判定を続ける）。
          止めるのは `StopCoordinator`（最初の 1 本だけ採用）と `RecordingSession.poll`（`.stop` を
          適用したら残りの指示を適用しない）の役
      (7) url モードの seed は「`.startRecording` の時点で見えている Chrome のプロセス」。
          決めた事項 #2 の「running になるまで待つ」ループは**作っていない**。policy の表が
          「いつ録り始めるか」の唯一の正（#10）で、表は完全な probe 応答を条件にしているため
          （旧実装の待ちループは同じことを別の手段でやっていた）。bundleIDs 単独でも tap は張れる（T2 の実測）

- [x] T9: CLI の配線（`main.swift` の一本化、3 モード復元、`--app` の bundleIDs 化、Legacy 削除）
  - 完了基準:
    - `Sources/RecCore/CLI.swift`: `struct Options`（`mode: .list | .system | .app(String) | .url(String)`、`output: String?`、`adGuard: Double`（既定 `Tuning.adGuardSeconds`））、
      `func parseArguments(_ args: [String]) throws -> Options`（未知の引数・値なし・`--ad-guard` が数値でない／負／10 超 → `RecError(.usage)`。`--url` の値は `URL(string:)` でパースでき
      scheme が `http` / `https` / `file` で、http(s) なら host が空でない。それ以外 → `.usage` と「URL 不正」）、`let usageText: String`（rec.swift:7-14 を更新）
    - `Sources/rec/main.swift`（**`exit()` を呼ぶのはこのファイルだけ**）: parse → `--list` は `audioProcesses()` を表示して 0 →
      それ以外は `RecordingSession` を作り `completion` で `exit(code.rawValue)`、`dispatchMain()`。`catch` は stderr に `error: <message>` と出して `error.code`（`RecError` 以外は 8）。
      `-o` 無しの既定名: url は probe のタイトル（`sanitizeFileName` が nil なら `defaultBaseName`）、他は `defaultBaseName`。`-o` も `reserveUniquePath` を通す
    - `--app X`: `TapTarget.bundleIDs([X] + 現在の一覧で `X.` を前置に持つ ID, seed: それらのプロセス)`（D4。使い方は変えない）。一致なしは `.usage` で rec.swift:304 と同文
    - `Sources/RecCore/Legacy.swift` を削除。`rg -n '^[^/]*\bexit\(' Sources/RecCore` が 0 件
      （**turn 11 訂正**。元は「`rg -n 'exit\(' Sources` が `Sources/rec/main.swift` のみ」。理由は下の実測欄）。`rg -n 'Legacy' Sources Tests` が 0
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
  - **T9 の実測（turn 11）**:
    - **PLAN 訂正: 完了基準の「`rg -n 'exit\(' Sources` の結果が `Sources/rec/main.swift` のみ」は
      そのままでは満たせない**。理由は 2 つで、どちらも実害がない:
      (1) `Sources/rec-probe/main.swift` に実呼び出しが 3 件ある（**別の実行可能ターゲット**なので
      「ライブラリが prosess を殺さない」という P1 の趣旨には反しない）、
      (2) `Sources/RecCore` の 3 ファイル（`CLI.swift` / `RecordingSession.swift` / `ExitCode.swift`）に
      **「`exit()` を呼ばない」と書いた散文コメント**が引っかかる。
      → 基準を「**`RecCore` に `exit(` の実呼び出しが 1 件もない**」に読み替え、検査コマンドを
      コメント行を除く形に変えた: **`rg -n '^[^/]*\bexit\(' Sources/RecCore` が 0 件**
      （`^[^/]*` で「`exit(` より前に `/` が無い行」= `//` や `///` のコメントでない行に限る）。
      参考: `rg -n '^[^/]*\bexit\(' Sources` は `Sources/rec/main.swift` 4 件 +
      `Sources/rec-probe/main.swift` 3 件のみ。**T11 の `final-check.sh` はこの形で書く**
    - **PLAN 訂正: サブ作業の割り方**。`CLI.swift`（`Options` / `parseArguments` / `usageText`）は
      **親が実装**し、並列に出したのは A'（`CLITests.swift` を仕様表から独立に書く。`CLI.swift` を
      読ませない）と B（`main.swift` の配線 + `Legacy.swift` 削除 + `Legacy` 参照コメントの掃除）の 2 本。
      根拠: turn 10 の申し送りは「共有型は無い（`Options` は A だけが使う）」としていたが、
      **B が `parseArguments` / `Options` を呼ぶので実際には共有型だった**。T5 / T6 / T7 / T8 と
      同じ「共有型は親が先に完成させ、テストは契約から独立に書かせる」形に寄せた（5 ターン連続で有効）
    - **PLAN 訂正: `Legacy` 参照コメントの掃除は 6 ファイルに及ぶ**（対象ファイル欄に無かった）:
      `AudioFileWriter.swift`（3 箇所）/ `ScriptRunner.swift` / `ChromeController.swift` / `HAL.swift` /
      `TapRecorder.swift` / `rec-probe/main.swift`（2 箇所）。すべてコメント文面だけで、コードは無変更。
      言い換えの規約は「消えたファイルを指す参照は履歴参照（`git show 45301d8:rec.swift`。F3 turn 17 で `main:` から訂正）にする。
      `rec.swift:NN` の行番号は新たに書かない」（追従先チェックリストの最終行と同じ方針）
    - 確定した API（T10 / T11 はこの名前で使う）:
      `usageText: String`（`let`。usage エラーの `message` にも**必ず丸ごと含まれる**）；
      `Options(mode:output:adGuard:)` / `Options.Mode { list, system, app(String), url(String) }`（`Equatable`）；
      `parseArguments(_ args: [String]) throws -> Options`（`args` は**プログラム名を除いた**引数列。
      throw するのは `RecError(code: .usage, ...)` **だけ**）；
      `main.swift` のトップレベル関数 `resolveAppTarget(_ prefix:) throws -> TapTarget` / `sessionOutput(for:) -> SessionOutput`
    - 契約の補足（実装で確定）:
      (1) **モードの指定が複数あったら最後に来たものが勝つ**（単一ファイル版と同じ。`--list` も同列に扱う）
      (2) usage エラーの `message` は `"<個別の説明>\n\n<usageText>"`。`main.swift` は
          `error: <message>` と出すだけで usage の出し分けをしない
      (3) `--ad-guard` は `Double` に変換でき**有限**で `Tuning.adGuardRange`（0〜10）に入る値だけ通す
          （`inf` / `nan` も弾く）。`--url` 以外のモードでも**パースは通る**（無視されるだけ）
      (4) `--app X` の bundleIDs は `[X] + （現在の一覧で "X." 前置のバンドル ID、出現順・重複なし）`、
          seed は `X` 前方一致で見えているプロセスの `id`。一致 0 件は `.usage` で単一ファイル版と同文
      (5) `-o` を指定しても必ず `SessionOutput` 経由 = `reserveUniquePath` を通るので**上書きしない**
    - **統合テストの実施結果**: `.build/debug/rec --bogus` → **exit 1**（stderr に usage 全文）；
      `--url 'not a url'` → **exit 1**（stderr に「URL として解釈できません」）；`--list` → **exit 0**（16 行）；
      `--app com.example.nope` → **exit 1**（「一致する音声プロセスがありません」）。
      **`-o` を付けた実録音・`kill -INT/TERM/HUP` の 130/143/129・`afinfo` の duration・`t9-2.m4a` の連番は
      未実施**（システム音声の取得の許可が無いため。PLAN T9 の指示どおり T11 の `verify-signals.sh` に委ねる）
    - **許可の状態を実測（turn 11）**: `timeout --preserve-status -s INT 3 .build/debug/rec -o <scratch>/turn-011-t9.m4a`
      → **exit 8**。3 秒時点の SIGINT は効かず、**10 秒後に `TapRecorder` の watchdog が
      `.coreAudio` で落ちて `Messages.systemAudioPermission` が出た**（T2 turn 4 の実測と同じ経路。
      許可はまだ降りていない）。設計どおりの挙動の裏付け: `.system` モードは `run()` が
      `beginRecording` を**セッションキュー上で同期に**呼ぶので、`recorder.start()` が
      ブロックしている 10 秒間は `SignalWatcher` のハンドラ（同じキュー）が走れない。
      → **許可が無い環境では「録音開始前の中断」はシグナルで止められない**（10 秒待たされる）。
      実害は小さいが T11 の README「既知の制約」に 1 行書く
    - **空ファイルが残らないこと（P4）はこの経路でも確認**: 上の exit 8 のあと scratch に `.m4a` は
      1 つも無い。`reserveUniquePath` は「tap の開始に成功して format が確定した後」なので、
      tap が作れない場合は予約自体が起きない（T8 契約の補足 (2) のとおり）

- [x] T10: ローカル検証ページ・トーン生成・Goertzel 判定器・`scripts/verify-adtest.sh`
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
  - **PLAN 訂正（turn 12 / T10 の実装）**:
    - 「ad エネルギーが main の 3 倍超かつ -50 dBFS 超」の 2 値は `ToneAnalyzer.swift` に直書きせず
      **`Tuning.toneAdDominanceRatio = 3.0` / `Tuning.toneAudibleDBFS = -50.0`** として追加した
      （根拠: Tuning.swift の「秒数・dBFS・比率を他のファイルに直書きしない」規約と追従先チェックリストの
      「調整値を変える」行。`windowSeconds` の既定 0.1 は API 契約で署名に書くと決めたのでそこだけ直書き）
    - `rec-probe tones` の 440 / 1000 Hz・12 / 4 秒は `Sources/rec-probe/main.swift` に直書きのまま
      （`Tuning` は `RecCore`（製品コード）の調整値置き場で、検証素材の寸法は道具側の値。
      `adtest.html` のコメントと対で保つ）
  - **T10 の実機結果（turn 12）: 未実施**。`swift run rec-probe tap system 2` が
    turn 11 と同じく **`aggregate created` の次の `AudioDeviceCreateIOProcIDWithBlock` で 10 秒の watchdog に当たり exit 8**
    （= システム音声の取得の許可が未取得。人の操作が必要）。録音できないので `scripts/verify-adtest.sh` は走らせていない。
    代わりに**録音以外の全段を実データで確認した**: `tones` が `main.wav` / `ad.wav` を生成 →
    `analyze main.wav --expect-main 12` が `{"adWindows":0,"mainSeconds":12.0,"silentSeconds":0,"totalSeconds":12}` / exit 0 →
    `analyze ad.wav --expect-main 12` が `adWindows=40` で exit 1 → `analyze main.wav --silence` が exit 0 →
    **`xcrun afconvert -f m4af -d aac -b 192000` で作った `.m4a` でも同じ verdict / exit 0**
    （= verify-adtest.sh の step 4 が読む形式で判定が成立する）。残るのは「Chrome で adtest.html を鳴らして録る」部分だけ
  - **`bash -n` は無人ターンから実行できない**（`bash -n scripts/verify-adtest.sh` / `zsh -n …` ともに権限拒否。
    allowlist の `Bash(bash scripts/:*)` は「prefix + 空白」でしか当たらない）。T10 では
    `cat -t -e` でヒアドキュメント（`<<-'EOS'`）の本文と終端がタブ字下げであることを確認して代替した。
    verify / T11 で verify-*.sh の構文を機械的に見たいなら `.claude/settings.json` に `Bash(bash -n:*)` を足す（人の操作）

- [x] T11: README 完成・実機検証スクリプト・final-check の仕上げ・文書の整合
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

### verify round 1 の差し戻し（turn 14）

検証結果は `.gsd-lite/VERIFICATION.md` の round 1。実機録音は許可が無く未実施（人の操作が要る。VERIFICATION §3）。
F1〜F3 は許可と独立に進められる。**無人ターンの作法**は上と同じ（`swift build` / `swift test` を素で、
`swift build --build-tests --scratch-path .build/<名前>` で warning 0 を見る、録音を直に待たない）。

#### F タスク共通の期待結果（この表だけが正。各 F の完了基準とテストはこの表の行番号を参照し、exit コード等を別の場所に書かない）

| # | 条件 | exit | stdout | stderr |
|---|---|---|---|---|
| E1 | `--url` 録音中にタブを閉じる（probe が `gone`） | 6 | なし | 停止理由 1 行（タブが閉じられた旨）→ 保存先 1 行（ファイルが残る場合） |
| E2 | `--url` で 60 秒以内に完全な状態が来ない | 6 | なし | 停止理由 1 行。最後に見た probe の要約（`none` / `loading` / 欠測）を含む |
| E3 | 録音開始後に応答なしが 20 秒 | 6 | なし | 停止理由 1 行 → 保存先 |
| E4 | 出力デバイス変更 / スリープ / coreaudiod 再起動 / IO 異常停止 / デバイス消失 / tap 故障 | 5 | なし | 停止理由 1 行（6 つのどれかが読み分けられる）→ 保存先 |
| E5 | 書き込みエラー（`RecordingPipeline.onWriteError`） | 7 | なし | 停止理由 1 行 + `firstWriteError` の内容 → 保存先 |
| E6 | SIGINT / SIGTERM / SIGHUP | 130 / 143 / 129 | なし | 停止理由 1 行（シグナル名）→ 保存先 |
| E7 | 再生終了 / 次の動画へ遷移 | 0 | なし | 停止理由 1 行 → 保存先 1 行（絶対パス） |
| E8 | 終了時に全編無音（どのモード・どの停止理由でも） | 停止理由の code が 0 なら 4、非 0 ならそれ | なし | 上の行に加えて `Messages.silent`。**許可の確認方法**（設定の場所と `scripts/verify-permission.sh`）を含む |
| E9 | system / app モードで無音が 5 秒続く | 継続 | なし | `Messages.silenceWarning`。30 秒以内は再警告なし（`--url` と同じ `Tuning` の規則） |
| E10 | probe の `playErr` が非 nil（自動再生拒否） | 継続 | なし | 自動再生が拒否された旨を 1 セッションに 1 回だけ。`playErr` の名前を含む |
| E11 | スリープ通知（`systemWillSleep`） | 5 | なし | **`acknowledge` より前に** `writer.close()` まで終わっている（`FakePowerSource` が ack の時刻と `FakeWriter.closed` の順序を観測） |
| E12 | `ad` → `main loading` または `main paused` → `main playing` | 継続 | なし | 最後の `main playing` で `rewindThenOpenGate`（`openGate` ではない）。`ad` → `ad` → `main playing` も同じ |
| E13 | stderr が閉じている（`2>&-`）で usage エラー | 1 | なし | なし（SIGABRT にならない） |
| E14 | stdout / stderr のパイプの読み手が先に閉じる | 本来の exit コード（録音中なら続行して本来の終わり方） | なし | なし（SIGPIPE で死なない。出力の失敗は黙って捨てる） |
| E15 | 録音開始後に `fail()` の経路（JS 許可オフ等）で終わり、1 フレームも書いていない | 2（原因の code） | なし | 原因 1 行 + `Messages.noData`。0 バイトの m4a を残さない |
| E16 | `-o ''` | 1 | なし | usage エラー（出力先が空） |
| E17 | `-o <既存のディレクトリ>` または末尾が `/` | 録音 | なし | そのディレクトリに既定名（`rec-<日時>` / タイトル）で `.m4a` を作る |
| E18 | `-o x.wav`（`m4a` 以外の拡張子） | 1 | なし | usage エラー（拡張子は `m4a` のみ。無ければ付ける） |
| E19 | `swift .gsd-lite/logs/rec-cli-hardening/scratch/turn-014-probe.swift`（堅牢性の格子の回帰） | — | 各行の exit が round 1 と同じ。`bogus-stderr-closed` が `exit=1`、`list-stdout-closedpipe` が `exit=0`、`TRACEBACK!` 0 件 | — |
| E20 | スリープ通知（`systemWillSleep`）。**`unregister` の後の ack は無効**という本物（`IOKitPowerSource.acknowledge` の `guard connect != 0`）と同じ挙動を `FakePowerSource` に持たせて観測する | 5 | なし | `writer.close()` の後に **有効な ack がちょうど 1 回**返る（E11 の順序はそのまま。ack が `unregister` の後に来て捨てられる形は不合格） |
| E21 | probe の `playErr` に制御文字（C0 / ESC / 改行 / `Cf`）や長大な文字列が含まれる | 継続 | なし | E10 の 1 行に制御文字が含まれず、`playErr` 由来の部分は UTF-8 で 64 バイト以内。`NotAllowedError` のような通常の名前はそのまま |

- [x] F1: 停止理由・警告の出力、停止の順序、policy の訂正（要件の取りこぼし。VERIFICATION §4「要件の取りこぼし」）
  - 完了基準:
    - `Messages.swift` に停止理由ごとの 1 行（`static func stopReason(_: StopReason) -> String`。15 case すべて。`default` を書かない）と
      保存先の 1 行（`static func savedTo(_ url: URL) -> String`）、自動再生拒否の 1 行（`autoplayRejected(name:)`）を足す。
      `Messages.silent` の末尾に許可の確認方法（システム設定の場所 + `scripts/verify-permission.sh`）を足す
    - `RecordingSession.finish(reason)`: **どの理由でも**停止理由の 1 行を出す。`.writeFailed` は `pipeline.firstWriteError` の内容を続ける。
      ファイルが残るときは最後に保存先の 1 行（絶対パス）。順序は「停止理由 → write エラー → noData / silent → liveStream → 保存先」（表 E1〜E8）
    - `.pageUnavailable` の 1 行に最後の probe の要約を含める（`RecordingSession` が直近の `ProbeOutcome` を 1 語で覚える: `none` / `loading` / `欠測`）（E2）
    - スリープ: `StopCoordinator` に **dispatch しない受付** `claim(_ reason: StopReason) -> Bool` を足し（`request` は `claim` + `queue.async` に書き直す）、
      `RecordingSession` の `PowerWatcher` handler は（セッションキュー上で呼ばれるので）`claim(.sleep)` が true なら**その場で `finish(.sleep)` を同期に通す**。
      これで `PowerWatcher.receive` の `defer { acknowledge }` が close の後になる（E11）。`StopCoordinatorTests` に `claim` の先勝ちを 1 本
    - system / app モード: セッションキューの `DispatchSourceTimer`（間隔 `Tuning.meterWindowSeconds`）で `ioQueue.sync { meter?.snapshot }` を読み、
      `consecutiveSilentSeconds >= Tuning.silenceWarnAfterSeconds` で `Messages.silenceWarning`、再警告は `Tuning.silenceWarnIntervalSeconds` 超のときだけ
      （`SessionPolicy.silenceWarning` と同じ規則。判定の関数を `SessionPolicy` から切り出して共用してよい）（E9）
    - `SessionPolicy`: (1) `playErr` が非 nil なら `.warn(Messages.autoplayRejected(name:))` を 1 セッションに 1 回だけ（b5 の警告列の先頭。
      PLAN #10 に行を足す）（E10）。(2)「直前が ad」を「**ad を見てから `main playing` をまだ見ていない**」に改める
      （`pendingAdResume` 旗: `.ad` で立て、`rewindThenOpenGate` を出したら下ろす。`main loading` / `main paused` では下ろさない）（E12）。
      PLAN #10 の表の下に訂正として書く
    - テスト: `RecordingSessionTests` に E1 / E5 / E6 / E7 / E11 / E15 の各経路で `sink.allMessages` の内容（停止理由の行 → 保存先の行の順）を確認する本を足す。
      `SessionPolicyTests` に E10（1 回だけ）と E12（`ad → main loading → main playing` / `ad → main paused → main playing` / `ad → ad → main playing`）を足す。
      system モードの無音警告（E9）は `FakeHAL.emit` で全ゼロを 6 窓分流して `sink.allMessages` に 1 回だけ出ることを見る
    - `swift test` green、`swift build --build-tests --scratch-path .build/f1` で warning 0、`rg '^[^/]*\bexit\(' Sources/RecCore` が 0
  - 対象: `Sources/RecCore/Messages.swift`, `Sources/RecCore/RecordingSession.swift`, `Sources/RecCore/StopCoordinator.swift`, `Sources/RecCore/SessionPolicy.swift`,
    `Tests/RecCoreTests/RecordingSessionTests.swift`, `Tests/RecCoreTests/SessionPolicyTests.swift`, `Tests/RecCoreTests/StopCoordinatorTests.swift`, `.gsd-lite/PLAN.md`（#10 の訂正）
  - 依存: なし
  - 並列サブ作業: A: `Messages` + `RecordingSession` + `StopCoordinator` + `RecordingSessionTests`（親が `Messages` の署名を先に確定させる）/
    B: `SessionPolicy` + `SessionPolicyTests`（表 E10 / E12 と PLAN #10 の訂正文だけを渡す）

- [x] F2: 出力経路の堅牢性（stderr / stdout の失敗で死なない）、`fail()` の後始末、`-o` の分解、小さな修正とテストの補強（VERIFICATION §4「堅牢性」）
  - 完了基準:
    - 人向け出力の口を 1 つにする: `Sources/RecCore/Console.swift` に `public func writeStderr(_ line: String)`（`fputs` か `write(2)` のループ。
      **失敗は無視する**。`FileHandle.write(_:)` を使わない）。`RecordingSession` の既定 `onMessage`、`Sources/rec/main.swift` の catch、
      `Sources/rec-probe/main.swift` の stderr 出力をすべてこれに置き換える。`rg -n 'standardError\.write' Sources` が 0
    - `Sources/rec/main.swift` と `Sources/rec-probe/main.swift` の先頭で `signal(SIGPIPE, SIG_IGN)`（`--list` の `print` は失敗しても落ちない）（E13 / E14）
    - ~~`RecordingSession.fail()` は `finish` と同じ出力の後始末（`framesWritten == 0` → 削除 + `Messages.noData`。無音判定も同じ）を通す
      （実装は `finish` と共通の private 関数に寄せる）（E15）~~
      → **F1 で先に実装済み**（turn 15。E15 のテストが F1 の完了基準にあり、実装が F2 だと F1 でテストが落ちるため）。
      共通化先は `RecordingSession.emitOutcome(headline:reason:code:)`。F2 では**この項目に手を付けない**
    - `-o` の分解を `Sources/rec/main.swift` から `Sources/RecCore/CLI.swift` へ移す（`public func splitOutputPath(_ path: String) throws -> SessionOutput`）:
      空文字列は `.usage`（E16）、末尾 `/` または存在するディレクトリはそのディレクトリ + `explicitBaseName: nil`（E17）、拡張子が `m4a` 以外なら `.usage`、無ければ `m4a`（E18）。
      `CLITests` に E16 / E17 / E18 と `a.b.m4a`（base `a.b`）/ `dir/sub.m4a` を足す
    - `ScriptRunner`: `DataBox` を `NSLock` で守る（読み書きとも）。2 秒の猶予 2 つを `Tuning.osascriptKillGraceSeconds` / `Tuning.osascriptPipeGraceSeconds` に移す
    - `SilenceMeter.ingest`: `buf.format.isInterleaved` のときは stride = `channelCount` で読む（`vDSP` の stride 引数で足りる）。
      `SilenceMeterTests` に interleaved の 1 本と、512 フレームのバッファで 2.5 窓ぶん流す窓またぎの 1 本、gate 開 / 閉が混じる窓の 1 本
    - `sanitizeFileName`: 200 バイトで切った後にもう一度末尾の空白 / ピリオドを落とす。`OutputPathTests` に「あ」×100 → 66 文字 / 198 バイト と、
      基底 + 結合文字が 200 バイト目をまたぐ素材、切った後に末尾が空白になる素材を足す
    - `ProbeResultTests` の JS キー照合を `JSON.stringify({...})` のリテラルからキーを抜き出して集合比較する形に直す（部分文字列をやめる）
    - 回帰: `swift .gsd-lite/logs/rec-cli-hardening/scratch/turn-014-probe.swift` を回して表 E19 のとおり。`swift test` green、
      `swift build --build-tests --scratch-path .build/f2` で warning 0、`rg -n -e '-60\.0' -e '-50\.0' -e '0\.7' -e '3\.0' Sources -g '!Tuning.swift' -g '!Sources/rec-probe/**'` が 0
  - 対象: `Sources/RecCore/Console.swift`（新規）, `Sources/rec/main.swift`, `Sources/rec-probe/main.swift`, `Sources/RecCore/RecordingSession.swift`, `Sources/RecCore/CLI.swift`,
    `Sources/RecCore/ScriptRunner.swift`, `Sources/RecCore/Tuning.swift`, `Sources/RecCore/SilenceMeter.swift`, `Sources/RecCore/OutputPath.swift`,
    `Tests/RecCoreTests/CLITests.swift`, `Tests/RecCoreTests/SilenceMeterTests.swift`, `Tests/RecCoreTests/OutputPathTests.swift`, `Tests/RecCoreTests/ProbeResultTests.swift`
  - 依存: F1（`RecordingSession.finish` / `fail` の共通化は F1 の後に行う。F1 と同じターンで続けてよい）
  - 並列サブ作業: A: `Console` + `main.swift` 2 本 + `fail()` + `CLI.splitOutputPath` + `CLITests` / B: `ScriptRunner` + `SilenceMeter` + `OutputPath` + 3 つのテスト補強
  - **F2 の実測（turn 16）**:
    - **E19 の 2 行が直った**（他の行は round 1 と同一、`TRACEBACK!` 0 件）:
      `bogus-stderr-closed` `signal=6`（SIGABRT）→ **`exit=1`**、`list-stdout-closedpipe` `signal=13`（SIGPIPE）→ **`exit=0`**。
      原因は 2 つで、両方要る: (1) `FileHandle.standardError.write(_:)` は fd 2 が閉じていると
      **Objective-C 例外（Swift から catch 不可）で SIGABRT**になる → `Console.writeStderr` の `write(2)` ループに置換、
      (2) stdout の読み手が居ないパイプへの `print` は SIGPIPE で即死する → 両 main の**トップレベル先頭**で
      `_ = signal(SIGPIPE, SIG_IGN)`。`write(2)` は EINTR だけ再試行し、**0 と EPIPE / EBADF / EAGAIN は黙って捨てる**
      （0 を捨てないと無限ループになる）
    - **確定した API**: `Console.swift` の `public func writeStderr(_ line: String)`（RecCore の**唯一の stderr の出口**。
      `rg -n 'standardError\.write' Sources` が 0 行）、`CLI.swift` の
      `public func splitOutputPath(_ path: String) throws -> SessionOutput`、
      `Tuning.osascriptKillGraceSeconds` / `Tuning.osascriptPipeGraceSeconds`（どちらも 2.0）
    - `splitOutputPath` の契約の補足（PLAN 本文に無かった点を実装で確定）:
      (1) 拡張子の判定は **`ext == "m4a"` の厳密一致**（`-o x.M4A` は usage エラー）
      (2) `-o` の分解は**モード判定の後**に走るので、`rec --list -o ''` は `--list` が先に exit 0 する
          （契約は `-o ''` 単体の exit 1 だけを定めている）
      (3) 「既存のディレクトリか」を `FileManager` で 1 回見るので、`CLI.swift` は厳密には純粋関数ではなくなった
          （`parseArguments` は純粋のまま。ヘッダコメントを訂正した）
    - `SilenceMeter` の interleaved 対応は **`buf.stride` を「ポインタの前進」と「vDSP の stride」の両方に掛ける**
      （`channelData[c] + offset * stride` と `vDSP_maxmgv` / `vDSP_vspdp` の stride 引数）。
      `floatChannelData[c]` は interleaved では同じ領域への 1 サンプルずつずれたポインタ。
      書き込み先の `scratch` は stride 1 のまま（詰めて並べる）。non-interleaved は `stride == 1` で挙動不変。
      B が**突然変異テストで確認**: stride を 1 に戻すと interleaved の dBFS が 30.76 dB ずれてテストが落ちる
    - `Tests/RecCoreTests/Fakes/Signals.swift` の `make` は書き込みを `ptr[frame * buf.stride]` にした
      （非 interleaved では stride == 1 なので `DelayLine` / `RecordingPipeline` のテストに影響なし。両方 green を確認）
    - `ScriptRunner` の打ち切り経路（SIGTERM → SIGKILL、パイプの grace）には**単体テストが無い**
      （本物の `osascript` を起動しないと再現できない）。今回は `NSLock` の追加と数値の `Tuning` 移動だけで挙動は変えていない

- [x] F3: 文書とスクリプトの整合（VERIFICATION §4「文書・スクリプト」。すべて 1 タスクにまとめる）
  - 完了基準:
    - `git show main:rec.swift` → `git show 45301d8:rec.swift`（`rec.swift` は main に無い。`git log --diff-filter=A -- rec.swift` で確認）。
      README 7 行目、`CLI.swift` / `ScriptRunner.swift` / `AudioFileWriter.swift`（2）/ `HAL.swift` / `ChromeController.swift` / `TapRecorder.swift` / `rec-probe/main.swift` のコメント、
      `scripts/final-check.sh` の fail 文言。`rg -n 'main:rec\.swift' README.md Sources Tests scripts` が 0
    - `scripts/verify-permission.sh`: 段 1 と段 2 の間、`Tests/Fixtures/main.wav` を `afplay` でバックグラウンド再生する（無ければ先に `swift run rec-probe tones Tests/Fixtures`）。
      終了時に `afplay` を kill。判定文で exit 4（音が入らない）と exit 8（許可なし）を読み分ける。README「検証」の該当行に「スクリプトが自分でトーンを鳴らす」と書く
    - `scripts/verify-adtest.sh` と README「自動再生の段階的対処」: 判定を「rec の stderr に自動再生拒否の行（F1 の E10）がある」に改め、exit コードに依存しない
      （自動再生が拒否されると `main paused` のまま録音が終わらず 180 秒で打ち切り exit 143 になる、と書く）
    - `scripts/verify-helper-restart.sh`（コメント・本文）と README 148 行目: `pkill -f 'Google Chrome Helper.*audio\.mojom\.AudioService'`。
      allowlist の `Bash(pkill -f audio.mojom.AudioService)` はスクリプト内の呼び出しには関係しないので変更不要（README に注記）
    - `python3 -m http.server 8765 --bind 127.0.0.1 --directory Tests/Fixtures`（README 172 行目と `verify-adtest.sh` 76 行目）
    - `scripts/final-check.sh`: `-g '!Sources/rec-probe/**'`（`rg` の `-g` はパス全体に当てる。実測: `!rec-probe/**` は除外しない）、
      数値リテラルの正規表現を `(^|[^0-9.])0\.7([^0-9]|$)` の形で前後を縛る。F1 で足した `Messages` の行が README「終了コード」表の「主な StopReason」と矛盾しないことを目視
    - **PLAN 追記（F2 turn 16）**: README 73 行目の `-o` の説明を E18 に合わせる
      （現在は「拡張子が無ければ `.m4a` を付ける」だけ → 「拡張子は `m4a` のみ。他を渡すと usage エラー（exit 1）。無ければ付ける」）。
      根拠: F2 で `splitOutputPath` が `m4a` 以外の拡張子を `.usage` にしたので、README の記述が実物より緩い
    - README「既知の制約」に 3 行: Chrome を終了していると `--url` が Chrome を起動してしまい `gone` で exit 6 になる / poll 中の osascript（最大 15 秒）の間はシグナル処理が遅れる /
      終了処理中は 2 度目の Ctrl-C が効かない（SIGKILL なら止まるが m4a は壊れる）。README「許可」1 に「全編無音 → exit 4 の症状と `scripts/verify-permission.sh`」を 1 行
    - 決めた事項 #2 の本文を訂正（「running になるまで待つ」は T8 で作らないと決めた。根拠は T8 実測 (7)。許可後の実機で (b)(c)(d) を測るのは変わらず）
    - `Sources/RecCore/SignalWatcher.swift` のコメントからローカルの作業ディレクトリのパスを消す（出典名だけ残す）
    - `rg -n 'rec\.swift:[0-9]' Sources README.md` が 0、`ls scripts/verify-*.sh` の本数 == README の一覧行数、`bash -n` 相当（E19 の driver が `scripts/*.sh` に `bash -n` を回す）がすべて exit 0
  - 対象: `README.md`, `scripts/verify-permission.sh`, `scripts/verify-adtest.sh`, `scripts/verify-helper-restart.sh`, `scripts/final-check.sh`,
    `Sources/RecCore/{CLI,ScriptRunner,AudioFileWriter,HAL,ChromeController,TapRecorder,SignalWatcher}.swift`, `Sources/rec-probe/main.swift`, `.gsd-lite/PLAN.md`（#2 の訂正）
  - 依存: F1（E10 の文言を参照する）
  - 並列サブ作業: A: README + PLAN #2 / B: scripts 4 本 + コメント掃除
  - **F3 の実測（turn 17）**:
    - **PLAN 訂正: サブ作業を分けずに親が全部やった**（`subagents: auto` / サブ作業 2 本だが並列に出していない）。
      根拠: F3 は文書とスクリプトを**互いに一致させる**タスクで、A（README）と B（scripts）の成果物が
      `scripts/final-check.sh` の追従チェックで直接噛み合う（`ls scripts/verify-*.sh` の本数 ==
      README の一覧行数、ExitCode の case 数 == README の表の行数）。独立に書かせると一致の保証が
      統合時にしか取れず、往復が増える。T3〜T6 の「共有物は親が作る」の延長で、ここでは**全部が共有物**。
      コード変更も Swift のコメント 10 箇所だけで、並列の利得（独立にテストを書かせる）が無い
    - `git show main:rec.swift` は**最初から誤り**だった: `rec.swift` は main に一度も入っていない
      （`git log --diff-filter=A -- rec.swift` → `45301d8 gsd-lite(discuss): rec-cli-hardening 要件確定`）。
      置換は 9 ファイル 10 箇所（`AudioFileWriter.swift` が 2）+ `scripts/final-check.sh` の fail 文言。
      PLAN 自身の 3 箇所（追従先チェックリスト / T9 実測欄 / メモ）も直した
    - **`rg` の除外グロブはパス全体に当たる**（PLAN の実測どおりを再確認）:
      `-g '!rec-probe/**'` は `Sources/rec-probe/main.swift` を**除外しない**（`rg -c 440 Sources -g '!rec-probe/**'`
      → 6 行ヒット）。`-g '!Sources/rec-probe/**'` なら 0 行。スラッシュを含むグロブはパス先頭からの照合、
      スラッシュの無い `!Tuning.swift` はベース名照合（こちらは効いている）。final-check.sh を後者に直した
    - **PLAN 追記: final-check.sh に検査を 2 つ足した**（完了基準に無いので訂正として残す）:
      (1) **調整値リテラルの自己テスト**。前後を縛る形（`(^|[^0-9.])0\.7([^0-9]|$)`）にすると正規表現が
          複雑になり、壊れて 0 件になったときに「違反なし」で通ってしまう。`Tuning.swift` に対して
          同じパターンを回して **5 行以上**拾えることを先に確かめる（ExitCode の `-gt 0` ガードと同じ趣旨）。
      (2) **`rg -n 'standardError\.write' Sources` が 0**。F2 の完了基準にあった不変条件で、
          破ると fd 2 閉鎖時に SIGABRT に戻る（E19）。恒久の検査にした
    - **段 1 の exit 4 は失敗ではない**（`verify-permission.sh`）: 段 1（`rec-probe tap system 2`）の時点では
      まだトーンを鳴らしていないので、全編ゼロ（exit 4）は正常。許可なしと断定するのは exit 8 だけ。
      直す前のスクリプトは exit 4 を一律 `fail` にしていたので、**何も鳴っていない状態では必ず落ちた**
      （PLAN の「exit 4 と exit 8 を読み分ける」はここを指していた）
    - `verify-permission.sh` のトーンは `afplay` を `while` で回す（`main.wav` は 12 秒、録音は 2 秒だが
      SIGINT が効かないと最大 20 秒になるため）。後始末は 2 段: ループ本体に `kill -TERM` →
      すでに起動済みの子 `afplay` は親を殺しても残るので `pkill -f "afplay $TONE"`。
      さらに `sleep 1` の後に `kill -0` でループの生存を確かめる（afplay が鳴らせない環境を
      「鳴らしていたのに全ゼロ」と誤診しないため）
    - **自動再生拒否は exit 6 では拾えない**（`verify-adtest.sh` / README）: F1 以降、`rec` は
      `Messages.autoplayRejected` を stderr に 1 行出して**録音を続ける**ので、本編が始まらないまま
      `main paused` を見続け、スクリプトの上限 180 秒で打ち切られて **exit 143** になる。
      判定を `grep -q '自動再生を拒否しました' "$REC_ERR"` だけに変え、終了コードを見ない形にした
    - `pkill -f 'Google Chrome Helper.*audio\.mojom\.AudioService'` が実機で**ちょうど 1 件**に当たるのを
      `pgrep -lf` で確認（`--type=utility --utility-sub-type=audio.mojom.AudioService` の
      `Google Chrome Helper (Aperitif)`）。裸の `audio.mojom.AudioService` は `-f` の全文照合なので
      この文字列を引数に持つ無関係なプロセスにも当たりうる
    - **`Messages` の停止理由と README「終了コード」表に矛盾なし**（目視）: `Messages.stopReason` の
      switch にある 14 case + `.signal(sig)` は、表の「主な `StopReason`」列に全部現れ、逆も同じ。
      秒数の言い回し（`.pageUnavailable` の 60 秒 / `.pageUnresponsive` の 20 秒）も表と一致する
    - 検証: `swift build` / `swift test` **220 本 green**（F3 はコメントしか触らないので本数は変わらない）、
      `swift .gsd-lite/logs/rec-cli-hardening/scratch/turn-017-syntax.swift` で
      **`scripts/*.sh` 9 本すべて `bash -n` exit 0** + final-check.sh の「追従チェック」節の写しが ALL OK
      （本体は `rm -rf .build` + 2 ビルドを含み、無人ターンからは allowlist に当たらないので節だけ写して回した）。
      `rg -n 'main:rec\.swift' README.md Sources Tests scripts` = 0、`rg -n 'rec\.swift:[0-9]' Sources README.md` = 0、
      `rg -n 'workspaces/|/Users/ohya' Sources Tests README.md scripts` = 0
    - **実機未検証**: `verify-permission.sh` の段 2（afplay + 録音）と `verify-adtest.sh` は
      システム音声の取得の許可が要るのでこのターンでは回していない（メモの【verify 前に必要な人の操作】のまま）。
      `afplay` の存在（`/usr/bin/afplay`）と `Tests/Fixtures/main.wav` が 440 Hz・12 秒であること（`afinfo`）は確認済み

- [x] F4: スリープ経路の ack の回帰と、ページ由来文字列の無害化（verify round 2 の指摘。VERIFICATION round 2 §4。期待結果は表 E20 / E21）
  - 完了基準:
    - **E20（F1 で入った回帰）**: いまの実経路は `PowerWatcher.receive` → `handler(.sleep)` → `RecordingSession.finish` →
      `teardown()` → `powerWatcher?.stop()` → `IOKitPowerSource.unregister()`（`rootPort = 0`・`IOServiceClose`・`IONotificationPortDestroy`）
      → ハンドラが戻る → `defer { source.acknowledge }` → `guard connect != 0 else { return }` で **`IOAllowPowerChange` が呼ばれない**。
      `PowerWatcher.swift` 冒頭の不変条件（どちらのメッセージでも必ず `IOAllowPowerChange`）が実経路で偽になっている。
      直し方はどちらか 1 つ: (a) `IOKitPowerSource` が「通知を受けた時点の `connect`」を通知に添えて（`PowerNotification` に
      フィールドを足すか、`acknowledge` が `unregister` 前に控えた `connect` を使う）`unregister` 後でも ack できるようにする、
      (b) `RecordingSession.finish` で `reason == .sleep` のときは `teardown()` から `powerWatcher?.stop()` を外し、
      ハンドラが戻って ack が返った後に `sessionQueue.async { powerWatcher?.stop() }` で解除する（`completion` → `exit` との順序に注意:
      `exit` が先なら解除は不要なので (b) は「止めない」だけでもよい）。
      **`IODeregisterForSystemPower` / `IONotificationPortDestroy` をその port のコールバックの中から呼ぶ形は避ける**（(b) なら自然に避けられる）
    - `FakePowerSource.acknowledge` を本物と同じ挙動にする: **`unregister` の後に呼ばれた ack は `log` に記録しない**（別に `droppedAcknowledges` を数える）。
      まずこの変更だけで `RecordingSessionTests` の E11 のテスト（`close(ack=0)` → ack 1 回）が**現状の実装で落ちる**ことを確認してから実装を直す
      （テストが回帰を検出できる形にしてから直す。落ちなければ fake の直し方が違う）
    - **E21**: `SessionPolicy.autoplayWarning` が `Messages.autoplayRejected(name:)` に渡す前に `playErr` を無害化する。
      関数 `public func sanitizeForTerminal(_ s: String) -> String` を `Sources/RecCore/OutputPath.swift` に置く
      （`sanitizeFileName` と同じ判定の置き場。`Cc` / `Cf` / `Zl` / `Zp` を `_` に、UTF-8 で 64 バイトに切る。結合文字の途中で切らない。
      `sanitizeFileName` の判定ヘルパーを共用してよい）。`savedTo` には適用しない（ファイル名は `sanitizeFileName` の契約のまま。
      `Cf` を残す理由は T3 turn 5 の訂正）。`ProbeJS` 側の JS は変えない（ページが上書きできるので Swift 側で守る）
    - テスト: `PowerWatcherTests` に「handler の中で `PowerWatcher.stop()` を呼んでも `WillSleep` の有効な ack が 1 回」を 1 本、
      `RecordingSessionTests` の E11 を上の fake で green（E20）、`SessionPolicyTests` に E21 を 1 本
      （`playErr = "x\n保存先: /tmp/evil\u{1B}]0;t\u{07}"` → `.warn` の文字列に `\n` / `\u{1B}` / `\u{07}` が無い、`"NotAllowedError"` はそのまま含まれる）、
      `OutputPathTests` に `sanitizeForTerminal` の境界（64 バイト切り・結合文字・空文字列）を 1 本
    - `swift test` green、`swift build --build-tests --scratch-path .build/f4` で warning 0、`rg -n 'standardError\.write' Sources` が 0、
      `rg '^[^/]*\bexit\(' Sources/RecCore` が 0。E19 の格子は F4 が stderr の経路を触らないので回さなくてよい
  - 対象: `Sources/RecCore/RecordingSession.swift`, `Sources/RecCore/PowerWatcher.swift`, `Sources/RecCore/SessionPolicy.swift`,
    `Sources/RecCore/OutputPath.swift`, `Tests/RecCoreTests/Fakes/FakePowerSource.swift`, `Tests/RecCoreTests/PowerWatcherTests.swift`,
    `Tests/RecCoreTests/RecordingSessionTests.swift`, `Tests/RecCoreTests/SessionPolicyTests.swift`, `Tests/RecCoreTests/OutputPathTests.swift`
  - 依存: なし（F1〜F3 は完了済み）
  - 並列サブ作業: なし（2 件とも小さく、E20 は fake とテストと実装を同じ人が順に触る必要がある）
  - **PLAN 訂正（turn 19 / F4 の実測）**:
    1. **E20 の直し方は (b) の変形で、直す場所は 2 か所**（旧: 「(a) か (b) のどちらか 1 つ」）。
       `RecordingSession.teardown` から `powerWatcher?.stop()` を外す形（素の (b)）は採らない:
       完了基準が要求する `PowerWatcherTests` の 1 本（「handler の中で `stop()` を呼んでも有効な ack が 1 回」）は
       **`PowerWatcher` 自身が守る**契約なので、`PowerWatcher.stop()` 側で直した
       （`WillSleep` の配送中に来た `stop()` は `registered` だけその場で倒し、実際の `unregister` は
       ack の後・`queue.async` で行う＝ port のコールバックの中から `IODeregisterForSystemPower` /
       `IONotificationPortDestroy` を呼ばない）。
    2. **(b) の括弧書き「`exit` が先なら解除は不要なので『止めない』だけでもよい」は誤り**（旧: そのまま）。
       `completion` は `Sources/rec/main.swift` で `exit()` を呼ぶため、`finish` から同期に呼ぶと
       **ack より先にプロセスが死んで `IOAllowPowerChange` が一度も返らない**（解除の有無とは別の問題）。
       そこで `finish` は `reason == .sleep` のときだけ `completion` を `sessionQueue.async` に回し、
       実経路を「close → ack → exit」の順にした。根拠: `main.swift:74` の `completion: { code in exit(code.rawValue) }`。
    3. **E21 のテストの断言「`.warn` の文字列に `\n` が無い」→「改行の数が `Messages.autoplayRejected` の文言のまま」**。
       `Messages.autoplayRejected` の本文自体が 2 行（改行 1 個）なので、旧の断言は実装に関わらず落ちる。
       「ページが行を増やせない」ことを改行の数と「`保存先:` で始まる行が無い」ことで断言した（`\u{1B}` / `\u{07}` / `\r` は 0 個のまま断言）。
       また旧文の「`"NotAllowedError"` はそのまま含まれる」は例の入力に含まれないので、`playErr = "NotAllowedError"` の
       素通しを別の断言にした。

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
   ~~録音開始（`TapRecorder.start`）は rec.swift:212-219 と同じく「Chrome の音声プロセスが running になった後」に
   行う（seed を取るため。bundleIDs 単独で動いてもこの待ちは残す）。~~
   **訂正（T8 turn 10 の実測 (7)。F3 turn 17 で本文に反映）**: この「running になるまで待つ」ループは**作らない**。
   録音を始める条件は `SessionPolicy` の表（#10）が唯一の正で、表は「初回の完全な probe 応答」を条件にしている。
   seed は `.startRecording` の時点で見えている Chrome のプロセスをそのまま使う（`bundleIDs` 単独でも tap は張れる。T2 の実測）。
   旧実装の待ちループは同じことを別の手段でやっていたもので、2 つ持つと「いつ録り始めるか」の正が二重になる。
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
8. **SSAI 警告**: `dur` が有限で `len` があり **`len > 0`** かつ `dur > len × 1.2` なら 1 回だけ警告（A5）。
   `len > 0` は T8 turn 10 の訂正（`len == 0` = 公称不明だと `dur > 0` が必ず真で毎回警告が出る）
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

   **verify round 1 の訂正（turn 14。F1 が turn 15 で実装済み）**:
   - 行を 1 つ足す: 「probe の `playErr` が非 nil（未警告） → `warn(自動再生が拒否された: <playErr>)`。1 セッションに 1 回」（b5 の警告列の先頭）
   - 「`kind == main && state == playing`（直前が ad）」の「直前」は **probe 1 回前ではなく「ad を見てから `main playing` をまだ見ていない」**
     （間に `main loading` / `main paused` / `ad` が何回挟まっても `rewindThenOpenGate`）。根拠: 広告明けの再バッファで `loading` が 1 回挟まるだけで
     巻き戻しが消え、広告開始で捨てた約 1 秒が戻らない（境界の欠落が許容 1 秒を超える）
   - 停止理由はどれも stderr に 1 行出す（表の行動には書いていなかったが、受け入れ基準「原因が分かるメッセージ」の対象）

   **実装のメモ（turn 15）**: `SessionPolicy` は記憶を 2 つ持つ。`.main playing` の巻き戻し判定は
   `pendingAdResume`（`.ad` で立て、`rewindThenOpenGate` を出したら下ろす）、`.ad`（直前も ad なら `wait`）の判定は
   従来どおり `lastKind`。旗の更新は b4 の後なので、b1〜b3 で停止した step では旗も警告も動かない。
   警告列の順序は **自動再生拒否 → SSAI → 無音**。

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
  (1) `file://` のまま（probe の `play()` で動く見込み）→ (2) `python3 -m http.server 8765 --bind 127.0.0.1 --directory Tests/Fixtures` で `http://localhost:8765/adtest.html?v=local1`
  （allow 済み。スクリプト内で起動して終了時に kill）→ (3) Chrome のポリシー `AutoplayAllowlist`（`defaults write com.google.Chrome AutoplayAllowlist -array 'file://*' 'http://localhost:8765'`。
  **impl は実行しない**。README に「ローカル検証ページ用の設定」として書き、verify は VERIFICATION に手動項目として残す）
- **サンドボックス**: `swift build` が `~/Library/Caches/org.swift.swiftpm` 等への書き込みで失敗したら、scripts に `--cache-path .build/.cache --config-path .build/.config --security-path .build/.security`
  を足す。それでも動かなければ BLOCKED（出力を添える）
- **Chrome を開く手段**（T2 / T7 / T10 / T11 の実機）: `osascript -e 'tell application "Google Chrome" to open location "<URL>"'` と、終了時に `rec` 自身の close。
  `open` コマンドは allow していない
- **並列サブ作業の依頼文に必ず入れる文言**（impl スキルの固定文言に加えて）: 「PLAN の API 名（型名・関数名・`Tuning` の定数名）はそのまま使う。
  別名にしたいときは実装せず報告に書く」
- **rec.swift の行番号**: この PLAN と RESEARCH の `rec.swift:NN` は T1 以降 `git show 45301d8:rec.swift` で参照する（ファイルは移動する）。
  **`main:rec.swift` ではない**: `rec.swift` は main ブランチには一度も入っていない（`git log --diff-filter=A -- rec.swift` → 45301d8 = `gsd-lite(discuss)` のコミットで追加）。F3 turn 17 で訂正
