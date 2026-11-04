# RESEARCH — rec-cli-hardening

作成: 2026-11-04（research turn 1）。調査対象は state.json の `research.targets`
（similar_oss / official_docs / local_projects）。要件（REQUIREMENTS.md）は書き換えない。
受け入れ基準への追加は末尾「要件への影響」に**提案**として置く。

## 0. 調査環境の制約（plan への申し送り）

- この無人ターンの Bash allowlist は `cat/grep/find/ls/rg/git/...` のみで、しかも Claude Code の
  作業ディレクトリ制限により **リポジトリ外のファイル（Xcode SDK ヘッダ、Chrome の sdef、
  `~/Library/.../Chrome/Preferences`）は読めなかった**。`swift` / `sdef` / `xcrun` も承認待ちになる。
  → ヘッダと sdef は Web 上のミラーから取得した（§2, §3）。impl ターンで `swift build` /
  `swift test` を使うには、`.claude/settings.json` の allow に `Bash(swift:*)`、
  `Bash(env DEVELOPER_DIR=*)` 相当を足す必要がある（plan の最初のタスクで確認・追加する）。
- SwiftPM + `-sectcreate` + Swift Testing の組み合わせは、このターンでは**実行検証できていない**
  （§4 の一次資料に基づく）。plan の最初のタスク（雛形作成）で必ずビルドとテストを通して確かめる。

## 1. 既存コード（rec.swift 313 行）の読解で確定した事実

plan が直接参照できるよう、行番号付きで記す。

| 箇所 | 現状 | 改善で触る理由 |
|---|---|---|
| `Recorder.init` rec.swift:72-121 | tap → aggregate → `AVAudioFile` → IOProc → `AudioDeviceStart` を 1 つの init で行う | 失敗時に途中まで作った tap/aggregate を破棄しない（リーク）。分割して `deinit`/`stop` で必ず破棄する |
| `Recorder.stop` rec.swift:125-134 | `file = nil` で flush/close に頼る | m4a の確定が「解放」依存。SIGTERM や `exit(1)` 経路では呼ばれない |
| IOProc ブロック rec.swift:114-119 | `try? self.file?.write(from:)`。書き込み失敗は無視 | ディスクフル等を検知できない。無音検知のための RMS 計算もここに入る |
| `osa()` rec.swift:140-159 | JS 許可オフを検出すると **`exit(1)`** | Recorder が生きたまま exit → m4a 未確定。throw に変えて上位で stop する |
| `chromeOpen` rec.swift:161-171 | `"` → `%22` 置換のみ | `\` や改行を含む URL で AppleScript 文字列が壊れる。`on run argv` で引数渡しにする（§3） |
| `chromeTab` rec.swift:173-186 | 全ウィンドウ・全タブを走査して id 照合 | 0.3 秒ごとに osascript をプロセス起動（rec.swift:232）。間隔は 0.3→0.5〜1.0 秒に緩めても広告境界は遅延バッファで吸収できる |
| `probeJS` rec.swift:189-196 | `.ad-showing` の有無、`v.paused` なら `play()`、`?v=` を videoId に | ライブ判定・タイトル取得がない。`.ad-showing` は `#movie_player` に付くクラス（§5） |
| `recordURL` rec.swift:204-254 | `com.google.Chrome` 前方一致で **開始時の PID 列挙**を固定 | `bundleIDs` + `isProcessRestoreEnabled` に置換（macOS 26） |
| `recordURL` 頭出し rec.swift:225-227 | 本編が流れていたら `currentTime=0` | 残す。ただしタイトル取得と live 判定はこの前に入れる |
| `installSigint` rec.swift:264-270 | SIGINT のみ。ハンドラ内で `exit(0)` | SIGTERM / SIGHUP 未対応。stop の多重呼び出し防止は `stopped` フラグがあるが、IOProc 中の `queue.sync {}` 待ちと競合しうる |
| 引数解析 rec.swift:274-296 | `--app` / `--url` / `-o` / `--list` | `-o` の既存ファイル保護なし。`--url` の既定名はタイトルではない |
| 最上位 catch rec.swift:310-313 | `print("error:")` + `exit(1)` | stderr ではなく stdout。終了コードが 1 のみで原因を区別できない |

`writing` フラグ（rec.swift:67, 123）は IO キュー上で切り替える設計なので、遅延バッファを入れるときも
同じキューで ring buffer を操作すれば排他は不要（IOProc は同一キューにシリアライズされる）。

## 2. 公式ドキュメント（official_docs）

ヘッダは Web ミラー https://github.com/alexey-lysiuk/macos-sdk （`MacOSX26.5.sdk/.../CoreAudio.framework/Versions/A/Headers/`）
で読んだ。impl ターンでローカル SDK を読む場合は allowlist の制約（§0）に注意。

### 2.1 CATapDescription（macOS 26 の新 API）

- `bundleIDs: [String]`（26.0+）: 公式文は「tap または除外する各プロセスのバンドル ID の配列」だけ
  （https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids.md ）。
  同 SDK で `processes` の説明が「tap **または除外**するプロセスオブジェクト」に変わった
  （dotnet/macios の Xcode26 差分）。`isExclusive` は「`processes` 以外を全部 tap」のまま
- `isProcessRestoreEnabled`（26.0+）: 「tap 対象プロセスが終了したときにバンドル ID で記憶し、再起動時に
  tap へ戻す」（https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled.md ）。
  catap の記録では **26 で既定 true**（§5.1）
- **未確認（Apple が書いていない）**: `bundleIDs` と `processes` の和集合か、`isExclusive` が `bundleIDs` にも効くか、
  `bundleIDs` だけで作った tap が「後から起動したプロセス」の音を拾うか、tap 対象プロセスが終了したときに
  `processes` から落ちるか。→ **plan の最初の実機タスクで小さなプローブを書いて確定する**
  （`--list` の隣に隠しサブコマンドは作らず、`Tests/` 配下の手動プローブ実行ファイルにする）。
  失敗時の退避策: 従来どおり `processes`（PID 列挙）+ `isProcessRestoreEnabled = true`
- 26 で CATapDescription に増えたのはこの 2 つだけ。AudioHardware.h の追加は無関係
- 公式ガイド（capturing-system-audio-with-core-audio-taps）の流れは rec.swift と同じ。tap の付け方は
  作成辞書の `kAudioAggregateDeviceTapListKey`（rec.swift 方式）でも、作成後に
  `kAudioAggregateDevicePropertyTapList` を set でもよい。`kAudioAggregateDeviceTapAutoStartKey` は
  「非ゼロなら AudioDeviceStart が、tap 対象プロセスが音を受け取り始めるまで待つ」
- `NSAudioCaptureUsageDescription` は必須。「tap を含む aggregate から最初に録音を始めたときに許可を求める」。
  `kAudioTapPropertyFormat` は「tap の現在のデータ形式。これが aggregate 経由で得られる形式」

### 2.2 録音中の変化を観測する（長時間追従）

AudioHardware.h の原文（要点）:

| セレクタ | 意味 | 使い方 |
|---|---|---|
| `kAudioHardwarePropertyDefaultOutputDevice` | 既定の出力デバイス（アプリ音声がここに出る） | **これを listen する**（ユーザーが聞いている側） |
| `kAudioHardwarePropertyDefaultSystemOutputDevice` | 警告音など「システム音」用の出力 | rec.swift:89 は aggregate の主デバイスにこれを使っている → **`DefaultOutputDevice` に変える**（Chrome の音はこちらに出る） |
| `kAudioDevicePropertyDeviceIsAlive` | 0 なら「使えず、まもなく消える」 | aggregate のサブデバイスに listener |
| `kAudioDevicePropertyIOStoppedAbnormally` | AudioDeviceStart 成功後、通常でない形で IO が止まった | aggregate に listener。停止・確定の引き金 |
| `kAudioDeviceProcessorOverload` | IO サイクルが締切を超えた（値に意味なし） | ログのみ |
| `kAudioHardwarePropertyServiceRestarted` | coreaudiod がリセットされた。「キャッシュや追加済み listener を含む全状態を作り直せ」 | 停止・確定の引き金（D13 の範囲では作り直さない） |
| `kAudioProcessPropertyIsRunningOutput` | プロセスが出力中か | listener は macOS 15.0.1 で発火しない報告（forums 770348, 未回答）。**依存しない** |
| `kAudioHardwarePropertyProcessObjectList` | 接続中の全クライアントプロセス | Chrome 再起動の検知に listen できる（任意） |

- 既定出力が変わった後に aggregate が配信を続けるかは**非公開**。コミュニティ（§5.2）は「全部作り直し」以外不安定と報告。
  要件は「停止して確定」なので、listener 発火 → 停止でよい
- **スリープ検知**: `NSWorkspace.willSleepNotification` は `NSWorkspace.shared.notificationCenter` に登録しないと届かず、
  NSApplication なしの Foundation CLI で届くかは Apple 文書に記載なし。QA1340 の **IOKit
  `IORegisterForSystemPower`** は plain `main()` の C プログラムとして示されており CLI で確実
  （https://developer.apple.com/library/archive/qa/qa1340/_index.html ）。
  `kIOMessageSystemWillSleep` を受けたら **`IOAllowPowerChange` を必ず呼ぶ**（呼ばないとスリープが 30 秒遅れる）。
  通知ポートの run loop source を main の `CFRunLoop` に追加し、main を `RunLoop.main.run()` / `dispatchMain()` で回す。
  → 推奨: IOKit。`willSleep` で停止・確定、終了コード「スリープ」

### 2.3 シグナル（dispatch_source_create(3)）

- 「dispatch source はシグナルハンドラを設置しない。既定で終了するシグナルは `signal(SIGTERM, SIG_IGN)` のように
  main の冒頭で無視しておく必要がある」→ INT / TERM / HUP の 3 つを `SIG_IGN` にしてから
  `DispatchSource.makeSignalSource(signal:queue:)` + `activate()`。GCD のループが動いている必要がある
- SIGHUP は「端末のハングアップで終了」。扱わないと端末を閉じた瞬間に m4a が未確定のまま落ちる
- ハンドラ内は短い後処理のみ（停止要求フラグを立ててメインループに任せる）

### 2.4 AVAudioFile / CAF（§2.5 に集約）

### 2.5 TCC の付与先（tmux）

- CLI の「責任プロセス」は起動元のターミナルアプリ。launchd 起動のプロセスは自分自身が責任プロセス
- tmux: 「TCC は tmux サーバの責任プロセスで判断する」。デーモン化したサーバは起動したアプリを指し続け、
  そのアプリが終了すると tccd が "Failed to create Attribution Chain" を出して拒否する（ghostty issue 9263、
  h0x91b/dev-3.0 PR 2067。**コミュニティ観測で Apple 文書ではない**）
- → README: 「許可はターミナルアプリに付く。tmux 内でダイアログが出ない／無音なら、tmux の外で 1 回実行して許可し、
  `tmux kill-server` 後にターミナルから再度 tmux を起動する」。verify は最初に 2 秒のシステム全体録音で全ゼロ判定（§7.4 B5）

### 2.6 Chrome の JS 許可の鍵

- Chromium の pref 名は `browser.allow_javascript_apple_events`（`pref_names.h`, mac のみ）。`Preferences` JSON では
  `"browser": {"allow_javascript_apple_events": true}`。**Chrome 終了中に JSON を書き換えて効くかは未確認**
  （Apple Event 経由の切替はコードで拒否されている）。→ 自動化せず、README とエラーメッセージでメニュー操作を案内する
  （D8: 起動前にユーザーが許可を済ませる）
- 未許可時のエラー文は "Executing JavaScript through AppleScript is turned off"（英語）。rec.swift:151 の
  `turned off` / `オフ` 判定は維持
- `osascript` の `--` は man に記載なし（getopt の慣習で動く）。`on run argv` の引数が `-` で始まらない限り `--` なしでも動く。
  URL は `http`/`file` で始まるので実害なし。念のため `--` を付け、ユニットテストで argv の組み立てを固定する

## 3. Google Chrome AppleScript（sdef）

一次資料: Chromium の `chrome/browser/ui/cocoa/applescript/scripting.sdef`
（https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/ui/cocoa/applescript/scripting.sdef ）。
`sdef` コマンドは今回実行できなかったが、同梱 sdef はこのファイルから生成されるので同等。

- `tab` の属性: `id`（text, 読み取り専用, "Unique ID of the tab."）、`title`（text, r）、`URL`（text, rw）、
  `loading`（boolean, r）。`index` や `window` 属性はない。応答コマンドに `execute`, `close`, `reload`, `stop` 等
- `window` の属性: `id`, `index`, `active tab`, `active tab index`, `mode`（normal / incognito, 作成時のみ設定可）など
- `execute` コマンド: 直接パラメータは tab の specifier、名前付き `javascript`（text, 必須）、戻り値は `any`
- tab の `id` は「一意」とだけ書かれ、セッションをまたぐ安定性は記載なし → 実行中の識別子として扱う（現行実装どおり）
- 盗める点: `title` は Chrome 側の属性で取れるので、JS 許可の有無に関係なく**タイトル取得は `title of t` で可能**。
  ただし YouTube のタブタイトルは「<動画名> - YouTube」で、再生リスト時など末尾が変わる。
  `document.title` と同じ値なので、JS 側で `ytInitialPlayerResponse.videoDetails.title` を優先し、
  取れなければ `title of t` から末尾 " - YouTube" を落とす二段構えが安全（§5）
- `loading` はページ遷移の検知に使える（広告判定とは無関係）。`URL of t` で「次の動画に遷移」を JS なしでも拾える

### 3.1 エスケープの方針（rec.swift:161-171 の修正）

AppleScript の文字列リテラルで意味を持つのは `\\` と `\"`（それ以外の `\x` は未定義で、改行は `\n`
として解釈されず実リテラル改行がそのまま文字列終端扱いになり構文エラー）。URL と JS は
**`osascript` の引数（`on run argv`）で渡し、スクリプト本文に埋め込まない**のが堅い:

```
osascript -e 'on run argv
  tell application "Google Chrome"
    set w to make new window
    set URL of active tab of w to (item 1 of argv)
    return (id of active tab of w) as text
  end tell
end run' -- 'https://...'
```

- `execute t javascript (item 2 of argv)` も同様に引数渡しにすれば、JS 側で `'` と `"` の両方を自由に使える
- 検証方法: `"`、`\`、`'`、改行、`%` を含む URL/文字列をユニットテストで `ScriptRunner` に渡し、
  組み立てたスクリプト本文が不変で、argv に生の値が入ることを確認する（osascript 本体は起動しない）。
  実機では `https://www.youtube.com/watch?v=xxx&t=1s"\` 相当の不正 URL で「URL 不正」の非ゼロ終了を見る

### 3.2 JS 許可（allow_javascript_apple_events）

- 許可オフ時のエラー文は英語ロケールで "Executing JavaScript through AppleScript is turned off"、
  日本語ロケールで「オフ」を含む（rec.swift:151 の判定は維持）。判定は `osascript` の stderr から行い、
  `exit(1)` ではなく **専用エラー型を throw** して上位で録音を確定させる
- Automation 許可（ターミナル → Chrome）がないと `-1743`（errAEEventNotPermitted）。
  起動前の事前チェックとして `tell application "Google Chrome" to get version` を 1 回投げ、
  -1743 なら「システム設定 > プライバシーとセキュリティ > オートメーション」の案内を出して非ゼロ終了（§6 PermissionManager の流用）

## 2.5 録音ファイルの確定（m4a のクラッシュ耐性）— 確定した一次資料

- `AVAudioFile.close()` は **macOS 15.0+** に存在する（https://developer.apple.com/documentation/avfaudio/avaudiofile/close().md ）。
  「書き込み用に開いたファイルで、ヘッダ更新のタイミングを制御できる」。閉じた後の read/write は
  `kAudio_FileNotFoundError`。`isOpen` もある。→ `stop()` は `file = nil` に頼らず **`close()` を明示的に呼ぶ**。
  二重 close を避けるため `isOpen` を見る
- m4a は moov atom をヘッダ更新（close）で書くため、**close なしに落ちると再生不可**（Apple Forums thread/720691 で
  AVAudioFile 書きの m4a が crash で moov 欠落と報告）。`AVAssetWriter.movieFragmentInterval` は
  公式ドキュメント上「QuickTime ムービーなど一部のコンテナ」で、MPEG-4/m4a での保証は記載なし
  （https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval.md ）。
  `initialMovieFragmentInterval` は「最初のフラグメント前に落ちると再生不可なので 1 秒などを推奨」。
  → **採用しない**（m4a で動く保証がなく、検証コストが高い）
- 方針（受け入れ基準の範囲 = SIGINT / SIGTERM / 途中エラー）: 「すべての終了経路で `Recorder.stop()` が
  ちょうど 1 回走る」ことを構造で保証する。具体的には
  1. `exit()` を `main` 以外から呼ばない（rec.swift:153, 267 を除去）。エラーは throw、シグナルは
     「停止要求フラグ + メインループ脱出」に変える
  2. `Recorder` は `deinit` でも `stop()` を呼ぶ（冪等）。`stop()` は `AudioDeviceStop` → IOProc 破棄 →
     `file.close()` → aggregate/tap 破棄の順
  3. 最上位は `defer { rec.stop() }` で囲み、catch 後に終了コードを決める
- SIGKILL / 電源断は範囲外。補強したければ「中間ファイルを CAF（`.caf`、AAC 入り）で書き、終了時に
  m4a へパススルー remux」が唯一の確実策（CAF はデータチャンク長 -1 のまま追記され、途中切断でも読める）。
  今回は**任意**。README の既知の制約に「強制終了時は m4a が壊れる」と書く
- 検証方法:
  - ユニット: `Recorder` を「tap なしのファイルライタ」に分離し、`stop()` 2 回呼び出しで例外なし・
    close は 1 回、を確認する。IOProc からの write エラー（ディスクフル模擬: 書き込み不可の
    ディレクトリ）が `stop()` 後にエラーとして上がること
  - 統合（verify）: 録音中に `kill -INT` / `kill -TERM` を送り、`afinfo <m4a>` が duration を返す
    （moov あり）こと。`AVAudioFile(forReading:)` が開けて `length > 0` でもよい
  - 境界: 録音開始直後（0.5 秒未満）の SIGINT でも空ではない再生可能な m4a か、
    または「データなし」として明示的に削除してメッセージを出すか、どちらかに決める（提案: 後者）

## 4. SwiftPM / テスト構成

- Info.plist の埋め込みは `linkerSettings: [.unsafeFlags(["-Xlinker","-sectcreate","-Xlinker","__TEXT",
  "-Xlinker","__info_plist","-Xlinker","Sources/rec/Info.plist"])]`。`-Xlinker` を各語に付けないと
  `swift build` で `-sectcreate` が unknown argument になる（Swift Forums thread 6532）。パスは
  **パッケージルートからの相対**で、`swift build` はパッケージルートで実行する前提（絶対パスにしたければ
  `Package.swift` 内で `Context.packageDirectory` を使う）。Info.plist を `resources` に入れると
  「target 直下の Info.plist は不可」でビルドが落ちるので **`exclude: ["Info.plist"]`** にする
- `unsafeFlags` はルートパッケージでは問題なし（依存として取り込めなくなるだけ）
- 検証方法: ビルド後 `otool -s __TEXT __info_plist .build/debug/rec | head` にセクションがあること、
  `otool -P .build/debug/rec`（plist 表示）で `NSAudioCaptureUsageDescription` が読めること。
  release ビルドでも同じ確認（strip されない）。この 2 つを README のビルド手順に載せ、plan のタスクの完了基準にする
- `swift test` は CLT では XCTest / Testing が import できない（DECISIONS 確認済み）。
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` で実行する。
  impl/verify の allowlist に `Bash(swift:*)` と `Bash(DEVELOPER_DIR=*)`（または `env`）が要る（§0）
- tools-version は 6.0 以上、`platforms: [.macOS(.v26)]`（`.v26` が SwiftPM 6.2+ で使えるか要確認。
  使えなければ `.macOS("26.0")` の文字列指定）。`swiftLanguageModes: [.v6]` にすると IOProc ブロックの
  `self` 捕捉で Sendable 警告が出るので、`Recorder` を `@unchecked Sendable` の final class にするか
  言語モードを v5 に落とす。推奨: v6 + `@unchecked Sendable` + キュー内でのみ状態を触る規約

## 5. 類似 OSS と盗める設計（similar_oss）

### 5.1 Process Tap の実装（作らなくてよいもの / 盗める設計）

| プロジェクト | 言語・方式 | 盗める点 / 記録された落とし穴 |
|---|---|---|
| insidegui/AudioCap https://github.com/insidegui/AudioCap | Swift, 14.4+ | rec.swift とほぼ同構成（tap → private aggregate → IOProc → AVAudioFile）。プロセス終了・デバイス変更・スリープの処理は**なし**。「`Audio...Stop` と `Audio...Destroy` を全部呼べ」 |
| makeusabrew/AudioTee https://github.com/makeusabrew/audiotee | Swift CLI, PCM を stdout | 「既定出力デバイスのみ対応」「再生中でない PID を含めると失敗して終了」「iTerm など一部ターミナルは許可ダイアログを出さないことがある」 |
| sbetko/catap https://github.com/sbetko/catap （`docs/core-audio-notes.md`） | Python+ObjC, 26+ で bundleID | **最も落とし穴が整理されている**。「bundle-ID tap はアプリ再起動を越えて生き残る（restore）」「`processRestoreEnabled` は macOS 26 で既定 true」「同一フォーマットの出力切替は透過的に継続したが、障害が出た場合は再接続しない」「sleep/wake・フォーマット変化・aggregate/IOProc 喪失からの復旧は未実装」「成功したのに無音なら許可なし」「許可変更はホストアプリ再起動後に反映」「満たせない description では tap ID 0 が返る」「走行中 aggregate の tap リスト変更は非対応」「PID 走査でなく `kAudioHardwarePropertyTranslatePIDToProcessObject` を使え」 |
| obsfx/audiograb https://github.com/obsfx/audiograb | Swift CLI, WAV | ロックフリー ring buffer を 10 ms ごとに書き出しスレッドで drain。**終了コードを 権限 / デバイス / IO で分ける**。「動いたのに WAV が無音なら権限」 |
| ThalesBMC/Mimir https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp | Swift | 唯一デバイス変更戦略を書いている: `kAudioHardwarePropertyDefaultOutputDevice` を listen → 状態保存 → tap を無効化 → 全部作り直し。「作り直さないと音が黙って止まる」「`AudioHardwareCreateAggregateDevice` 直後はデバイスがまだ準備できていないことがある」 |
| Rust coreaudio 0.3.1 `tap.rs` | Rust | 「許可なしでも tap は作れるが無音を配る」「stereo mixdown はワイドなデバイスでは実際より小さい音になる」 |

調査した Swift 実装で `bundleIDs` / `isProcessRestoreEnabled` を使うものは**なし**（catap のみ）。
→ この 2 つは自前で検証が必要（§7 に検証方法）。

### 5.2 重大な落とし穴: 「tap が全ゼロを吐き続ける」故障

Apple Developer Forums thread/825780（2026-05、Apple 回答なし）: tap は所定のペースで IOProc を呼び続けるが
**全サンプルが 0.0f** になり、実際には音が鳴っている状態が数分続く。既定デバイスの listener は
**発火しない**。Bluetooth のスリープ/復帰や 44.1↔48 kHz 再交渉が疑われる。「IOProc だけ、aggregate だけの再起動は
不安定。Stop → DestroyIOProcID → DestroyAggregate → DestroyTap → 全部作り直し、で直る」。
「壊れた tap の全ゼロと本物の無音は区別できない」。

→ 要件（D13: デバイス切替・スリープは**停止して確定**、自動復旧しない）との整合: 復旧はしないが、
**検知**にはデバイス listener だけでは足りない。「Chrome 側が playing かつ本編、なのに N 秒連続で
全ゼロ」を「tap 故障」とみなして停止・確定・非ゼロ終了する経路が要る（§8 提案 1）。

### 5.3 YouTube の DOM（広告・ライブ・タイトル）

- 広告の主マーカーは今も **`#movie_player.ad-showing`**（youtube-adb は `movie_player` の class を
  MutationObserver で監視、YT Ads Skipper 2026-03 は 700 ms ポーリング）。`.ad-interrupting` も併記する
  スクリプトあり（Instant YouTube Ad Skipper v9）。オーバーレイ広告は `.video-ads.ytp-ad-module`
  配下（音声には影響しないので無視してよい）
- スキップボタンは `.ytp-ad-skip-button` → `.ytp-ad-skip-button-modern` → `.ytp-skip-ad-button` と改名を重ねた。
  自動クリックするなら 3 つを OR する（**今回は任意**。クリックしなくても境界は正しく切れる）
- **SSAI（サーバー側広告挿入）**: 2024-06 から実験が確認されている（SponsorBlock FAQ、iter.ca 2025-06）。
  主流経路では広告と本編は別ストリームのまま。広く展開されたという一次資料は 2026 時点でなし。
  SSAI に当たると `video.currentTime` が本編長を超えてずれるので、**`video.duration` が
  `ytInitialPlayerResponse.videoDetails.lengthSeconds` を大きく超える**ことを警告のトリガにできる（未検証の経験則）。
  README の既知の制約に書く
- **ライブ判定**: `ytInitialPlayerResponse.videoDetails.isLive` / `isLiveContent`（yt-dlp も両方を見る）。
  DOM では `.ytp-time-display.ytp-live` / `.ytp-live-badge` だが、ミニプレイヤー出現後は `#movie_player` に
  **更新されない隠しコピー**が残るので DOM は補助扱い。`video.duration === Infinity` は DVR なしライブで有効。
  `ytInitialPlayerResponse` はコールドロード時のみ存在（今回は毎回新規タブで開くので問題なし）
- **タイトル**: `ytInitialPlayerResponse.videoDetails.title` が最安定（非公開動画では `videoDetails` がない）。
  フォールバック `document.title.replace(/ - YouTube$/,'')`。`h1.ytd-watch-metadata` は描画待ちが要る
- `#movie_player.getPlayerState()` / `getVideoData()` はページワールドで呼べる（`execute javascript` はページワールド）。
  `video.paused` とあわせて再生状態の二重確認に使える

### 5.4 無音検知と「権限なし＝無音」

- RMS: `vDSP_rmsqv` → `20*log10(max(rms,1e-8))`。閾値の相場は -60 dBFS / 1 秒以上（oximedia-metering）、
  -50 dBFS / 0.3 秒 / ヒステリシス 3 dB（oximedia-audio-analysis）
- **許可なしの症状は「すべて noErr で全ゼロ」**（dev.to "2000 buffers of nothing"）。エラーコードもログもない。
  許可ダイアログは `AudioDeviceStart` 時に出る。`INFOPLIST_KEY_NSAudioCaptureUsageDescription` が
  静かに落ちる事例あり → `plutil -p` / `otool -P` で埋め込みを確認する
- 設計: **「完全ゼロ（`all == 0`）」と「低 RMS」を区別する**。前者は権限/tap 故障、後者はコンテンツの静寂。
  要件の「録音中は警告だけ、終了時に全編無音なら非ゼロ終了」は後者の閾値で判定し、前者は §5.2 と合わせて別メッセージにする

### 5.5 遅延バッファ（広告境界）

既存録音ツールに「広告開始で直前 N 秒を捨て、広告明けに少し戻って再開」を実装したものはない。
近い概念は OBS のリプレイバッファ。ライブラリは TPCircularBuffer（C, SPSC）、sbooth/CXXAudioRingBuffer、
audiograb の自前 ring。**今回は依存を足さず自前の遅延線で足りる**:
IO キュー上で「約 1 秒分のフレームを保持し、それより古いフレームだけファイルへ書く」。広告開始 →
保持分を破棄して書き込み停止。広告明け → 書き込み再開（保持分は広告明け直後の音なので、そのまま
1 秒遅れて流れ出すことで「巻き戻し」相当になる）。ホスト時刻付きで持てば JS ポーリングの時刻と
フレームを合わせられる。

### 5.6 代替品（作らなくてよいか）

URL → Chrome → tap → 広告なし m4a を一気通貫で行う OSS は**見つからなかった**。
近いのはブラウザ側スキッパ + 汎用レコーダ（audiograb / AudioTee）の組み合わせ。yt-dlp は元ストリームを
広告なしで取得でき SSAI の影響も受けないが「再生した音を録る」ものではなく、PO token / cookie の
対処が要る。→ **D1（既存 rec.swift の改善）を覆す発見ではない**。BLOCKED にしない。
補足: `youtube.com/embed/ID?autoplay=1` は広告が出ないという報告あり（2026 年の状況は未検証。今回は不採用）。

### 5.7 SwiftPM の雛形

steipete/Peekaboo `Apps/CLI/Package.swift`（https://raw.githubusercontent.com/steipete/Peekaboo/main/Apps/CLI/Package.swift ）:
library target + executableTarget + Swift Testing の testTarget、`linkerSettings` の `-Xlinker -sectcreate` 6 語。
テストは executable ではなく **library に依存**させる（§4 と一致）。

## 6. ローカル過去プロジェクト（local_projects）

`~/workspaces` 配下を走査した。**自作の Swift / Core Audio / Chrome AppleScript 実装は存在しない**。
Swift のファイルはすべて clone した上流（openclaw）か vendored llama.cpp のもの。以下は
「雛形として読める上流コード」と「考え方だけ流用できる自作コード」。

| 用途 | パス | 流用できる点 |
|---|---|---|
| Package.swift の形 | `~/workspaces/openclaw/sample1/upstream/openclaw/Swabble/Package.swift` | tools 6.2、`platforms: [.macOS(.v15)]`、library 2 + executableTarget 1 + testTarget 2（swift-testing）。`swiftLanguageModes: [.v6]` |
| SIGINT/SIGTERM | `.../openclaw/apps/macos/Sources/OpenClaw/TerminationSignalWatcher.swift` | `DispatchSource.makeSignalSource(signal:queue:)` で両シグナルを扱う。ほぼそのまま使える |
| デバイス変化の監視 | `.../openclaw/apps/macos/Sources/OpenClaw/AudioInputDeviceObserver.swift` | `AudioObjectAddPropertyListenerBlock` の登録と**解除**の対。入力→出力（`kAudioHardwarePropertyDefaultOutputDevice`）に読み替える |
| システム音声の代替経路 | `.../openclaw/apps/macos/Sources/OpenClaw/ScreenRecordService.swift` | ScreenCaptureKit + `AVAssetWriter` で音声を書く例。AVAssetWriter の使い方の参考（§2 C-2） |
| Automation 許可の事前確認 | `.../openclaw/apps/macos/Sources/OpenClaw/PermissionManager.swift` 380-395 付近 | NSAppleScript を投げて **-1743** を「許可なし」と判定する。Chrome 制御の起動前チェックに流用 |
| TCC のリセット手順 | `.../openclaw/docs/platforms/mac/permissions.md`, `dev-setup.md:87` | `tccutil reset ScreenCapture|AppleEvents <bundle>`。README の「許可の確認方法」に転記 |
| osascript ラッパのテスト | `~/workspaces/dev/Strata/apps/host/server/folder-dialog.mjs` + `tests/folder-dialog.test.mjs` | 実行コマンドを注入して osascript なしでテストする形。Swift では `ScriptRunner` プロトコルに置き換える |
| CDP 接続メモ | `~/workspaces/dev/agent-console/.gsd-lite/RESEARCH.md` 51 行付近 | `--remote-debugging-port` + `--user-data-dir`。**今回は不採用**（D5: 別プロファイル起動はログインし直しになる） |
| `<video>` のローカル検証ページ | `~/workspaces/claude-apps/video-editor/test-audio-capture.html` | 構造だけ参考。音源生成（sine/afplay/ffmpeg）の自作コードはない |

- 「該当なし」: NSWorkspace のスリープ通知、`-sectcreate __TEXT __info_plist`、`DEVELOPER_DIR` / `swift test` の運用メモ、
  YouTube DOM の判定コード、音源生成。これらは §2〜§5 の外部資料に依る。
- kindle-capture は Python（pyautogui + PyObjC）。構造は流用不可。単機能のプローブスクリプトを `test/` に置く運用だけ参考。

## 7. 落とし穴と検証方法（plan が完了基準に写す）

各項目は「落とし穴 → 回避策 → どう検証すれば踏んでいないと分かるか」。タスク単体テストで拾いにくい
種類（並行性、境界値、権限、契約外エラー）を優先して挙げる。

### 7.1 データ保全（改善 1）

| # | 落とし穴 | 回避策 | 検証方法 |
|---|---|---|---|
| P1 | `exit()` が Recorder を素通りして m4a が未確定（rec.swift:153, 267, 287, 290, 312） | `exit` は main の最後だけ。他は throw / 停止フラグ | ユニット: osascript の stderr に "turned off" を返す偽 `ScriptRunner` で、`RecError.jsDisabled` が throw され、Recorder の `stop()` が呼ばれた（スパイで記録）ことを確認。統合: JS 許可をオフにした状態で `--url` を実行し、終了コードが非ゼロかつ出力ファイルが存在しない（録音前の失敗）こと |
| P2 | SIGTERM / SIGHUP 未処理（SIGINT のみ） | `DispatchSource.makeSignalSource` を INT / TERM / HUP の 3 つに。`signal(sig, SIG_IGN)` を先に | 統合: 録音 3 秒後に `kill -TERM <pid>`、`kill -HUP <pid>` をそれぞれ送り、`afinfo out.m4a` が duration ≥ 2 秒を返す。終了コードは「中断」用の固定値 |
| P3 | シグナルハンドラと IOProc の競合（`stop()` がグローバルキューで走り、IOProc が rec.io キューで走る） | `stop()` は呼び出し側に関係なく内部で専用の直列キューに `sync` して 1 回だけ実行。`stopped` を `OSAllocatedUnfairLock` か同キューで保護 | ユニット: 10 スレッドから同時に `stop()` を呼んで、close が 1 回・クラッシュなし（Thread Sanitizer 付き `swift test -Xswiftc -sanitize=thread` を 1 回は回す） |
| P4 | 短時間（<0.5 秒）で中断すると空の m4a | 書き込みフレーム数が 0 なら close 後にファイルを削除し「データなし」を表示 | ユニット: フレーム 0 で stop → ファイルが存在しない。境界: 1 フレーム書いた後の stop → 存在し再生可能 |
| P5 | 既存ファイルの上書き（`-o` 含む） | `FileManager.fileExists` で `name-2.m4a`, `name-3.m4a` と連番。**作成は `O_EXCL` 相当**（`FileManager.createFile(atPath:contents:nil)` の戻り値で原子性を取る、または `open(O_CREAT|O_EXCL)`） | ユニット: 一時ディレクトリに `a.m4a`, `a-2.m4a` を置いて `a-3.m4a` が選ばれる。並行: 2 プロセス同時起動を模して同名要求が別名になる（`O_EXCL` の失敗→次の連番） |
| P6 | タイトル由来のファイル名: `/`, `:`, NUL、先頭 `.`、255 バイト超、空文字、絵文字・結合文字（NFD/NFC） | 置換して `_`、先頭 `.` を落とす、**UTF-8 バイト長**で 200 バイトに切る（拡張子分を残す）、空なら `rec-日時` | ユニット: `"a/b:c"`, `".hidden"`, `""`, `"🎵"*100`, 結合文字（"ガ" の NFD）、`"CON"` 相当は不要（macOS）、末尾空白・ピリオド |
| P7 | 無音判定の閾値と「全ゼロ」の混同（§5.4） | IOProc で `rms` と `allZero` を別々に集計。警告は 1 回/区間でレート制限（毎 0.3 秒出さない） | ユニット: 合成バッファ（全ゼロ / -70 dBFS ノイズ / -20 dBFS 正弦）で分類が正しい。境界: 閾値ちょうど（-60.0 dBFS）の扱いを決めて固定。統合: Chrome をミュートして録音 → 警告が出て続行し、終了時に非ゼロ + 許可確認の案内 |
| P8 | ディスクフル・書き込み不可を `try?` で握り潰す（rec.swift:118） | 最初の write エラーを保持して停止要求、終了時に報告 | ユニット: 読み取り専用ディレクトリで `Recorder` の open が失敗して理由付きエラー。write 失敗はモック `AudioFileWriter` で注入 |

### 7.2 広告境界（改善 2）

| # | 落とし穴 | 回避策 | 検証方法 |
|---|---|---|---|
| A1 | ポーリング遅延（0.3〜1 秒）の分だけ広告の頭が混入 | §5.5 の遅延線（既定 1.0 秒、`--ad-guard <秒>` で調整可能にすると verify が楽） | ユニット: 遅延線に 48 kHz で 3 秒流し、1.0 秒時点で「広告開始」→ 書かれたフレームが 0〜(1.0−guard) 秒分のみ。境界: guard=0、guard がバッファ長を超える、フレーム数が割り切れない（512 で 48000 を割る） |
| A2 | 広告明けの欠落 | 広告明けは即時書き込み再開（遅延線の保持分がそのまま出るので欠落しない）。本編再開 → 巻き戻しは JS 側で `currentTime -= 0.5` を**任意**で | ローカル検証ページ（§7.5）で A/B 音の境界をスペクトルで測り、欠落・重複 < 1 秒 |
| A3 | 本編判定の取りこぼし: 広告中に `v.paused` を `play()` すると広告が進む（意図どおり）、本編で `paused` なら再生させる（現行）。ただし**ユーザーが手で止めた**場合も強制再生してしまう | 現行動作を維持し README に書く（スコープ外） | — |
| A4 | `ad-showing` が `#movie_player` 以外に付く / 付かない（DOM 変更） | セレクタを `#movie_player.ad-showing, .ad-interrupting` の OR にし、JS を 1 ファイルに分離してテスト可能に | 統合（YouTube 実機）: 短い動画で開始〜保存まで。広告が出なかった場合は「広告なしで完走」として合格扱い（広告の有無は制御できない） |
| A5 | SSAI で `currentTime` がずれる（§5.3） | `duration > lengthSeconds * 1.2` で警告 | ユニット: 偽の probe 文字列で警告分岐を通す |
| A6 | probe の戻り値が `missing value` / 空（ページ遷移中、`document.querySelector('video')` が null） | `'none'` と `nil` を区別し、連続 N 回（例 20 秒）で「ページが応答しない」エラー | ユニット: 連続 nil を返す偽 runner でタイムアウトエラー。境界: N-1 回 nil の後に正常値で復帰 |
| A7 | 次の動画への自動遷移（autoplay）で止まるが、**同じ videoId のループ再生**は検出できない | `ended` を先に見ているので問題なし（rec.swift:242） | ユニット: `main ended` → 停止、`main playing <別 id>` → 停止、`ad playing <別 id>` → 継続（広告中は id が広告のものになり得るので無視する現行動作を固定） |

### 7.3 長時間録音（改善 3）

| # | 落とし穴 | 回避策 | 検証方法 |
|---|---|---|---|
| L1 | ヘルパー再起動で tap の対象が消える。`bundleIDs` の正確な意味は Apple 未記載（§2.1） | 第 1 候補: `bundleIDs = ["com.google.Chrome.helper", "com.google.Chrome"]` + `isProcessRestoreEnabled = true`、`processes` は空。プローブで音が取れなければ第 2 候補: 従来の `processes`（PID 列挙）+ `isProcessRestoreEnabled = true`。**plan の最初の実機タスクでプローブ**（`Tests/Probe/` の手動実行ファイル）を書いて、どちらを採るか決める | プローブ: (a) Chrome 再生中に bundleIDs-only tap を作り 3 秒録って全ゼロでないこと、(b) tap 作成後に Chrome を再生開始しても拾えること、(c) 録音中に Chrome の「タスクマネージャ」で音声サービス（Audio Service）を終了して再生が復帰した後も RMS が戻ること。(c) は verify の手順にも入れる |
| L2 | 既定出力デバイスの切替（§2.2, §5.2） | aggregate の主デバイスとサブデバイスを **`kAudioHardwarePropertyDefaultOutputDevice`** に変え（rec.swift:89 は System 側）、同セレクタ + `kAudioDevicePropertyIOStoppedAbnormally` + サブデバイスの `DeviceIsAlive` に listener。発火したら停止・確定・終了コード「デバイス変更」 | 統合: 録音中に出力デバイスを変える（システム設定 or `SwitchAudioSource`）→ 2 秒以内に終了し m4a が再生可能。ユニット: listener の登録/解除（`AudioObjectRemovePropertyListenerBlock`）の対を数える（`Recorder` を protocol で抽象化し偽の HAL で検証） |
| L3 | スリープ（`NSWorkspace` 通知は GUI なし CLI で届く保証なし。§2.2） | **IOKit `IORegisterForSystemPower`**（QA1340）。`kIOMessageSystemWillSleep` で停止要求 + **`IOAllowPowerChange` を必ず呼ぶ**。main を `RunLoop.main.run()` で回し、Chrome ポーリングは別スレッド/キューへ | ユニット: `IOAllowPowerChange` 相当を呼ばない経路がないこと（コールバックを偽物で呼び、ack スパイが 1 回）。統合: `pmset sleepnow`（sudo 不要かを確認）→ 復帰後に m4a が再生可能、終了コード「スリープ」。verify で実施できなければ「手動確認」として VERIFICATION に残す |
| L4 | 全ゼロ故障（§5.2）: listener が発火しないまま無音が続く | Chrome が `main playing` を報告しているのに全ゼロが **10 秒**連続 → 「tap 故障」で停止・確定・非ゼロ終了（§8 提案 1） | ユニット: 状態機械に「playing + allZero × N」を入れて停止判定。統合は再現困難なので手順のみ |
| L5 | `coreaudiod` 再起動（`kAudioHardwarePropertyServiceRestarted`） | listener を張り、発火したら L2 と同じ扱い | 統合: `sudo killall coreaudiod` は sudo が要るので verify では行わない。ユニットで分岐のみ |
| L6 | 長時間でメモリ増加（遅延線 / ログ） | 遅延線は固定長。進捗表示は `\r` 上書きで stdout に溜めない | 統合: 10 分録音で RSS が増えない（`ps -o rss` を開始 1 分と 10 分で比較、差 < 10 MB） |
| L7 | `Thread.sleep` ベースのポーリングと osascript 起動コスト（0.3 秒ごと） | 間隔を 0.5 秒に、遅延線 1.0 秒で吸収 | 統合: 10 分録音で osascript の累積 CPU が無視できる（`time`） |

### 7.4 ビルド・テスト（改善 4）

| # | 落とし穴 | 回避策 | 検証方法 |
|---|---|---|---|
| B1 | `-sectcreate` の `-Xlinker` 抜け、パスの相対基準 | §4 の 6 語形。パスはパッケージルート相対 | `otool -s __TEXT __info_plist` でセクション確認。release も |
| B2 | Info.plist を resources に入れてビルド失敗 | `exclude: ["Info.plist"]` | `swift build` 成功 |
| B3 | テストが executable に依存できない | ロジックは library（`RecCore`）、CLI は薄い `main.swift` | `swift test` 成功 |
| B4 | CLT では `import Testing` 不可 | README に `DEVELOPER_DIR=... swift test`。Makefile か `scripts/test.sh` で固定 | verify が同コマンドで成功 |
| B5 | TCC の付与先がターミナル（tmux 経由はさらに不明） | README に「許可はターミナルアプリに付く。tmux 内で初回実行して出ない場合は tmux の外で 1 回実行」と書く。失敗時は「システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音」を案内 | 統合: verify の最初に `--list` ではなく **2 秒のシステム全体録音**を行い、全ゼロなら許可の案内を出して停止（以降の実機検証を無駄にしない） |

### 7.5 ローカル検証ページ（D11）の設計案

- `Tests/Fixtures/adtest.html`: `<div id="movie_player"><video id="v" src="main.wav"></video></div>` と
  `<button>` 群。JS で 3 秒ごとに「本編（440 Hz）→ 広告（1 kHz, `#movie_player` に `ad-showing` を付与し
  `src` を ad.wav に切替）→ 本編」を自動で進め、最後に `ended` にする。`?v=` 相当の videoId は
  `location.search` で固定（`adtest.html?v=local1`）
- `main.wav` / `ad.wav` は Swift のテストヘルパで生成（`AVAudioFile` に正弦波を書く。ffmpeg 不要）
- 録音結果の判定: m4a を `AVAudioFile(forReading:)` で読み、100 ms 窓ごとに 440 Hz と 1 kHz の
  Goertzel エネルギーを比較。「1 kHz 優勢の窓が 0 個」= 広告混入なし、「440 Hz 優勢区間の合計長」と
  期待本編長の差 < 1 秒 = 欠落・重複 < 1 秒。この判定器自体はユニットテスト（合成信号）で先に固める
- `file://` で開くと Chrome の `execute javascript` は動くが、`autoplay` はユーザー操作なしだと
  ミュート以外では拒否される可能性がある → probe が `paused` なら `play()` する現行動作で解消される見込み。
  だめなら `python3 -m http.server` で `http://localhost` から配信（Chrome の自動再生ポリシーは
  「過去に再生したサイト」で緩む）。**verify の最初の実機項目**にしてここで止まるなら早期に分かるようにする

## 8. 要件への影響（提案。REQUIREMENTS.md は変更しない）

1. **tap 故障の検知を受け入れ基準に追加（提案）**: 「Chrome が本編再生中と報告しているのに全ゼロが 10 秒以上続いたら、
   録音を確定して『システム音声の取得が止まりました』の案内とともに非ゼロ終了する」。根拠 §5.2。
   D13（自動復旧しない）と矛盾せず、無音検知（D16）の「全ゼロ」側の扱いを明確にする
2. **終了コードの割り当てを固定（提案）**: 0 正常 / 1 引数・URL 不正 / 2 Chrome 制御不可（JS 許可・Automation）/
   3 ライブ配信 / 4 権限なし（全編無音）/ 5 デバイス変更・スリープ・tap 故障で中断 / 130 SIGINT / 143 SIGTERM。
   根拠: audiograb が区別しており、verify のスクリプトが原因を判別できる
3. **短時間中断時の空ファイル（提案）**: フレーム 0 で停止したときは m4a を残さず「データなし」を表示する
   （受け入れ基準「録音済みの m4a が再生できる状態で残る」の「録音済み」を「1 フレーム以上」と解釈）
4. **README の既知の制約に追記（提案）**: SSAI 時の精度低下、強制終了（SIGKILL）時の m4a 破損、
   ユーザーの手動一時停止を自動再生してしまう、tmux 内での初回許可ダイアログ
5. **広告ガード秒数の CLI オプション（提案、任意）**: `--ad-guard <秒>`（既定 1.0）。verify が境界を調整して
   再測定しやすくなる。受け入れ基準の「1 秒未満」は既定値で満たすこと
6. **`bundleIDs` の採否は実機プローブで決める（plan への指示）**: D4 は「bundleIDs と isProcessRestoreEnabled を使う」
   だが、`bundleIDs` 単独で動く保証が Apple 文書にない（§2.1）。plan の最初の実機タスクで §7.3 L1 のプローブを
   行い、動かなければ `processes` + `isProcessRestoreEnabled` に退避する。どちらでも D4 の目的
   （ヘルパー再起動への追従、macOS 26 専用）は満たせるので BLOCKED にはしない
7. **aggregate の主デバイス（提案）**: rec.swift:89 の `DefaultSystemOutputDevice` は警告音用で、Chrome の音は
   `DefaultOutputDevice` に出る。両者が別デバイスのとき（例: 警告音は内蔵、音楽は BT）に tap の clock が
   ずれる恐れがあるので `DefaultOutputDevice` に変える（§2.2）

## 9. plan への要約（最初に読む 10 行）

1. 構成: `Package.swift`（tools 6.0+, macOS 26）、`Sources/RecCore`（ロジック）、`Sources/rec`（`main.swift` + `Info.plist`、
   `-Xlinker -sectcreate` 6 語、`exclude: ["Info.plist"]`）、`Tests/RecCoreTests`（Swift Testing）、`Tests/Fixtures/adtest.html`
2. 最初のタスクで `swift build` / `swift test`（`DEVELOPER_DIR` 指定）と `otool -s __TEXT __info_plist` を通す。
   allowlist に `swift` が無い（§0）ので、通らなければ BLOCKED で allowlist 追加を依頼する
3. 2 番目のタスクで `bundleIDs` プローブ（§7.3 L1）。結果で tap の作り方を確定
4. `Recorder` を「HAL 操作」「ファイルライタ」「遅延線」「無音メータ」に分け、後ろ 3 つはユニットテスト可能にする
5. Chrome 制御は `ScriptRunner` protocol（osascript 実行）と `ChromeController`（スクリプト組み立て、`on run argv`）に分け、
   probe JS は 1 つの文字列定数（ライブ・タイトル・広告・状態を 1 回で返す）
6. 終了経路の一本化: throw / 停止フラグ → main の `defer` で `stop()` → 終了コード表（§8-2）
7. シグナルは INT / TERM / HUP、スリープは IOKit、デバイスは `DefaultOutputDevice` + `IOStoppedAbnormally` + `ServiceRestarted`
8. 無音は「全ゼロ」と「低 RMS」を分けて集計。全ゼロ × 10 秒 + Chrome が playing → tap 故障で停止
9. ローカル検証ページと Goertzel 判定器（§7.5）は impl 内で作り、verify はそれを実行する
10. README: ビルド手順、許可 3 種（システム音声 / オートメーション / JS from Apple Events）、tmux の注意、既知の制約（他タブ音、SSAI、SIGKILL、手動一時停止）
