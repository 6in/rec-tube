# VERIFICATION — rec-cli-hardening

## round 2（turn 18 / 2026-11-04）— 判定: **差し戻し**（F4 を PLAN に追記。verify_round 1 → 2）。実機は許可なしで未実施（5 回目）

対象: round 1 の差し戻し F1〜F3 の修正差分 `git diff 6d162e2...HEAD`（Sources / Tests / scripts / README、34 ファイル、+1790 / -164）と、
マイルストーン全体 `git diff main...HEAD` の最終判定。round 1 の方針どおり**新しいクラスの探索はせず**、round 1 の格子（E19）の
再確認と F1〜F3 の差分の回帰だけを行った。並列レビュー: コードレビューとセキュリティチェックを読み取り専用のサブエージェント 2 本、
親が機械検証・格子の回帰・実機の到達範囲・指摘の裏取り（ソースを読んで確認）を行った。

### 1. 機械検証（`scripts/final-check.sh` 相当。すべて green）

| 段 | 結果 |
|---|---|
| `rm -rf .build` → `swift build` / `swift build -c release` | 成功、warning 0（両ログで `warning` 0 件） |
| `otool -P` に `NSAudioCaptureUsageDescription` / `__TEXT,__info_plist` セクション（debug / release） | 両方あり |
| `swift test`（テストビルドの warning も 0） | **220 本 / 14 suite すべて green**（round 1 の 195 + F1 13 + F2 12） |
| 追従チェック（`turn-017-followup-check.sh` = final-check の写し） | ExitCode 12 / README 12、許可 7 行、verify スクリプト 6 / 6、調整値リテラル自己テスト 5 行・外部 0 件、`standardError.write` 0、`rec.swift:NN` 0、直下の `rec.swift` 無し → ALL OK |
| `bash -n scripts/*.sh`（9 本） | すべて exit 0 |
| `rg '^[^/]*\bexit\(' Sources/RecCore` | 0 件 |
| `.build/debug/rec --list` / `--bogus`（格子の 1・2 行目） | exit 0 / exit 1 |

### 2. 格子の回帰（E19。driver `turn-014-probe.swift`、44 行、約 2.6 分）

- **round 1 で落ちた 2 行が直っている**: `bogus-stderr-closed` SIGABRT → **exit=1**、`list-stdout-closedpipe` SIGPIPE → **exit=0**。`TRACEBACK!` 0 件
- 他の行は round 1 と同じ exit（argv エラーはすべて exit 1 + 個別の説明、`-0` は 0 として通って録音へ、`url-space` / `url-newline` は 60 秒後 exit 6）。
  違いは **E2 が効いて stderr に理由が出るようになった**こと: 「60 秒以内に動画の再生が始まらなかったので録音を中止しました（最後に見たページの状態: 欠測）」（round 1 は stderr 空）
- `list-stdout-full` / `list-cwd-root` は driver 側の `posix_spawn` 失敗（`/dev/full` が macOS に無い・chdir 後の相対パス）で round 1 と同じ。対象の挙動ではない
- 格子が開いた Chrome のタブ（`example.com` × 2。turn 16 の回帰で残っていた 4 つも含めて計 6 つ）は osascript で閉じて、Chrome を格子の前の状態に戻した。0 バイトの m4a は残っていない（E15 / P4）

### 3. 実機（受け入れ基準「verify がループ内で実機録音を行う」）

- **システム音声の取得の許可は依然として降りていない**（このターンで **5 回目**の実測）。`swift run rec-probe tap system 2` が
  `aggregate created: 102` の次で 10 秒の watchdog に当たり **exit 8**。格子の `system-noperm` / `app-emptyprefix-noperm` / `adguard-negzero` も同じ
- → **ローカル検証ページの広告境界と YouTube の完走は未実施**。verify スクリプト 6 本も回していない（`verify-permission.sh` の段 1 で落ちる）
- round 1 の方針では「round 2 で許可が無ければ BLOCKED」だったが、今回はレビューで**修正が要る指摘が 2 件**出たので、人の操作を待つ間に
  進められる差し戻し（F4）を選んだ。**round 3 は、許可が降りていなければ受け入れ基準の実機 2 項目を満たせないので BLOCKED にする**
  （F4 の確認は許可と独立）。人の操作: **システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で iTerm2 を許可 → iTerm2 を再起動**

### 4. 指摘（差し戻し。PLAN の F4 に完了基準、期待結果は表 E20 / E21）

- (中・**F1 で入った回帰**) スリープ経路で `IOAllowPowerChange` が呼ばれない。F1 で `PowerWatcher` のハンドラが `claim(.sleep)` → その場で同期に `finish(.sleep)`
  を通す形にしたため、`finish` → `teardown()` → `powerWatcher?.stop()` → `IOKitPowerSource.unregister()` が `rootPort` を 0 にして port を壊した**後**に
  `PowerWatcher.receive` の `defer { source.acknowledge }` が走り、`acknowledge` の `guard connect != 0 else { return }` で ack が捨てられる
  （`RecordingSession.swift:226-229` / `:578-586`、`PowerWatcher.swift:170-176` / `:242`。ソースを読んで確認）。`writer.close()` は ack より前に終わるので
  **m4a は壊れない**（要件「スリープを検知したら止めて確定」は満たす）が、`PowerWatcher.swift` 冒頭の不変条件「どちらでも必ず `IOAllowPowerChange`」が
  実経路で偽になり、`IODeregisterForSystemPower` / `IONotificationPortDestroy` をその port のコールバックの中から呼ぶ形にもなっている。
  **E11 のテストが green なのは `FakePowerSource.acknowledge` が `unregister` 後でも記録するから**で、本物の挙動との差がテストに映っていない。
  round 1 の時点ではこの経路が無かった（ack → 非同期 finish → unregister の順）ので round 1 では拾えない指摘
- (中・セキュリティ) `playErr` はページの JS が自由に決められる文字列（`HTMLMediaElement.play` を上書きして `Promise.reject({name: "…"})` を返せば任意）で、
  F1 の E10 がそれを**無害化せずに stderr の 1 行へ埋め込む**（`SessionPolicy.swift:276-282` → `Messages.swift:140-145`）。改行で偽の「保存先:」行、
  ESC でターミナルのタイトル変更や OSC を注入できる。round 1 の残留リスク「敵対的なページは probe 結果を偽装できる」は録音の開始・停止の操作までで、
  **端末への制御文字の注入は別のクラス**。F1 で新しく生えた出力経路なので round 1 では拾えない指摘

### 5. 確認して問題なしとした点（F1〜F3 の差分）

- `emitOutcome` の行順（停止理由 → `firstWriteError` → close エラー → noData / silent → liveStream → 保存先）は 1 箇所で固定され、`finish` / `fail` の両方が通る。
  `fail()` も 0 バイトの m4a を消して `noData` を出す（E15）。削除するのは `reserveUniquePath` が返した URL そのもの（`O_EXCL` なので既存ファイルを消せない）
- `StopCoordinator.claim` / `request` の先勝ちは 1 つのロックで共有（`request` = `claim` + ロック外 `queue.async`）。`onFirstRequest` は高々 1 回
- E9 の無音警告タイマーはセッションキュー上、メータは `ioQueue.sync` で読み、`teardown` で cancel。`finish` / `completion` の二重呼び出しは `claimFinish()` で防ぐ。
  IO / イベントキューからセッションキューへの新しい `sync` は無い（自己デッドロックなし）
- `SessionPolicy`: `pendingAdResume` は `.ad` で立ち `rewindThenOpenGate` でだけ下りる（`main loading` / `main paused` では下りない）。b1〜b3 の `[.stop]` 短絡は維持。
  警告列は 自動再生拒否 → SSAI → 無音。`autoplayRejected` は 1 セッション 1 回
- `Console.writeStderr`: `write(2)` の部分書き込みを正しく進め、0 で抜け、`EINTR` だけ再試行、他は捨てる。読み越しなし。`signal(SIGPIPE, SIG_IGN)` は両 main の最初の実行文
- `splitOutputPath`: E16 / E17 / E18 どおり。ディレクトリは作らない。ファイルを作る場所は `reserveUniquePath` の `open(O_CREAT|O_EXCL)` だけのまま
- `ScriptRunner`: `DataBox` の読み書きとも `NSLock`、`kill` は自分が spawn した pid だけ。`SilenceMeter` の interleaved は `buf.stride` をポインタと vDSP の両方に掛け、読み越しなし。
  `sanitizeFileName` の再トリムは同じ述語
- **既存テストの期待値の変更は 0 件**（`git diff` で消えた `#expect` 3 行を確認: 2 行は失敗メッセージの文言だけ、1 行は `ProbeResultTests` の部分文字列照合を集合比較に強めたもの）。
  新しいテストは表の行を具体的に断言している（行順のインデックス比較、ack 回数、exit コード、ファイルの有無）
- 文書: README の終了コード表と `Messages.stopReason` の文言が一致、`-o` の説明は E18 どおり、「既知の制約」に 3 行あり。
  `main:rec\.swift` / `rec\.swift:[0-9]` / `workspaces/|/Users/ohya` はいずれも 0 件。`Messages.stopReason` は 15 case を `default` なしで網羅
- スクリプト: `set -euo pipefail` あり、`eval` なし、`--bind 127.0.0.1` あり、`pkill` は `Google Chrome Helper.*audio\.mojom\.AudioService` に絞られている

### 6. 残留リスク（差し戻さない。round 1 の §6 に追加）

- `-o .m4a` は `.m4a.m4a`、`-o foo.` は `foo..m4a` になる（`explicitBaseName` に `sanitizeFileName` を通していない。契約の行に無い）。`-o x.M4A` は usage エラー（厳密一致、PLAN F2 に記載）
- `savedTo` が出す絶対パスはタイトル由来で、`sanitizeFileName` が `Cf`（RLO 等）を残すので表示が双方向制御で偽装されうる（連結絵文字を壊さないための T3 の決定）
- `scripts/verify-permission.sh` の `pkill -f "afplay $TONE"` は相対パスのパターンで、同じユーザーが同時に 2 つの checkout で回すと互いの `afplay` を殺す
- `scripts/verify-helper-restart.sh` の `pkill` に `-u` が無く、共有 Mac では他ユーザーの Chrome 音声ヘルパーに当たって（EPERM でも exit 0）検査が空振りしうる
- `SIG_IGN` にした SIGPIPE は `osascript` に継承される（`ScriptRunner` が両パイプを EOF まで読み、timeout / kill があるので実害なし）
- E2（`.pageUnavailable` の probe 要約）と E3 / E4 は実装のみで専用テストが無い（E2 は格子の `url-space` 行で実測）
- `ScriptRunner` の打ち切り経路（SIGTERM → SIGKILL）は単体テストが無い（turn 16 から変わらず）

### 7. 手動確認として残すもの（round 1 §7 と同じ。許可が降りた後）

1. 実機検証 6 本（verify-permission → signals → adtest → youtube → helper-restart → longrun）
2. 決めた事項 #2 の宿題（seed なし bundleIDs で音が入るか）
3. スリープ → exit 5 と m4a の再生可否（F4 の後。`pmset sleepnow` は allowlist に入れない決定）
4. 出力デバイスの切り替え → exit 5

## round 1（turn 14 / 2026-11-04）— 判定: **差し戻し**（F1〜F3 を PLAN に追記。verify_round 0 → 1）

対象: `git diff main...HEAD`（71 ファイル、+12673 行。コードは `Package.swift` / `Sources/**` / `Tests/**` / `scripts/**` / `README.md`）。
`CLAUDE.md` / `AGENTS.md` は無い。並列レビュー: コードレビューとセキュリティチェックを読み取り専用のサブエージェント 2 本で行い、
親が final-check 相当・堅牢性の格子・実機の到達範囲・指摘の裏取りを行った。

### 1. 機械検証（`scripts/final-check.sh` の中身を素のコマンドで 1 段ずつ。すべて green）

| 段 | 結果 |
|---|---|
| `rm -rf .build` → `swift build` / `swift build -c release` | 成功、warning 0 |
| `otool -P` に `NSAudioCaptureUsageDescription`（debug / release） | 両方あり。`__TEXT,__info_plist` セクションあり |
| `swift test` | **195 本 / 14 suite すべて green** |
| `rg 'rec\.swift:[0-9]' Sources README.md` | 0 件 |
| `ExitCode` の case 数 / README「終了コード」表 | 12 / 12 |
| `--ad-guard` が CLI.swift と README の両方 | あり |
| README の許可 3 種の記述 | 7 行（≥ 3） |
| `ls scripts/verify-*.sh` / README の一覧 | 6 / 6 |
| 調整値の直書き（Tuning 外） | 0 件 |
| `rg '^[^/]*\bexit\(' Sources` | `rec/main.swift` 4 件 + `rec-probe/main.swift` 7 件のみ（RecCore は 0） |
| `rg Legacy Sources Tests` / 直下の `rec.swift` | 0 件 / 無し |
| `.build/debug/rec --list` / `--bogus` | exit 0 / exit 1 |
| `bash -n scripts/*.sh`（9 本。Swift の driver から `/bin/bash -n` を起動） | すべて exit 0 |

### 2. 堅牢性の格子（round 1 で一括。driver: `.gsd-lite/logs/rec-cli-hardening/scratch/turn-014-probe.swift`）

入力経路 × 出力経路を実バイナリで試した。**トレースバック（Fatal error / stack dump）は 0 件**。見つかった問題は 2 つ。

| 面 | 試したこと | 結果 |
|---|---|---|
| argv | `--bogus` / `--` / 裸の引数 / 値なし（`--url` `--app` `-o` `--ad-guard`） | すべて exit 1 + 個別の説明 + usage |
| argv `--url` | 空 / `not a url` / `javascript:` / `ftp:` / host なし / C0 制御文字 / 200 KB | すべて exit 1（scheme・host・解釈不能を区別） |
| argv `--url` | 空白を含む `https://example.com/a b`、改行を含む URL | **検証を通る**（macOS 26 の `URL(string:)` が寛容）→ Chrome で開いて 60 秒後 **exit 6、stderr は空**（→ F1 E2） |
| argv `--ad-guard` | `nan` `inf` `1e400` `''` `' 1'` `1,5` 全角 / `-1` `11` `10.0001` `0x10` / `-0` | 非数は exit 1、範囲外は exit 1、`-0` は 0 として通る（問題なし） |
| argv `--app` | 不一致 / 200 KB / 不正 UTF-8 バイト / DEL 入り / 空文字列 | 不一致は exit 1、空文字列は全プロセスに一致して録音に進む（許可なしで exit 8） |
| 環境変数 | 空の環境で `--list` / `--bogus` | exit 0 / exit 1 |
| stdin | 常に閉じて起動 | 影響なし |
| stdout | 閉じている / パイプの読み手が先に閉じる | `--list` は exit 0 / **SIGPIPE（signal 13）で死ぬ**（`--list` では無害。録音中に stderr のパイプが閉じても同じ経路 → F2 E14） |
| stderr | 閉じている（`2>&-`）で `--bogus` | **SIGABRT（signal 6）**。`FileHandle.write(_:)` が EBADF で ObjC 例外（→ F2 E13。録音中に警告を出す経路で同じことが起きると `finish` に届かず m4a を失う） |
| stderr | 閉じている で `--list` | exit 0 |
| データファイル | `rec-probe analyze` に非音声 / 存在しない / ディレクトリ、`--main abc`、`tones` を書けない場所 | すべて非 0 で理由を出す（exit 1 / 8 が混在するが道具側なので残留リスク） |
| 例外の親クラス | errno 全般（`EROFS` 含む）/ 壊れた JSON / 未知の enum / `nil` | ユニットテストで担保（`OutputPathTests` / `ProbeResultTests` / `ChromeControllerTests`）。深い入れ子 JSON は未検証（残留リスク） |

### 3. 実機（受け入れ基準「verify がループ内で実機録音を行う」）

- **システム音声の取得の許可は依然として降りていない**（このターンで 4 回目の実測）。`swift run rec-probe tap system 2` と
  `.build/debug/rec -o …` のどちらも `AudioDeviceCreateIOProcIDWithBlock` で 10 秒の watchdog に当たり **exit 8**。
  → **ローカル検証ページの広告境界と YouTube の完走は未実施**。verify スクリプト 6 本も同じ理由で回していない。
- 許可に依存しない範囲は実機で確認した:
  - **Chrome のオートメーション許可と「Apple Events からの JavaScript」はどちらも有効**
    （`osascript -e 'tell application "Google Chrome" to execute (active tab of front window) javascript "1+1"'` が `2` を返した。turn 9 以来の未確認が解消）
  - **`adtest.html` と probe JS の噛み合わせ**: `.build/debug/rec --url 'file://…/adtest.html?v=local1'` が最初の poll で完全な状態を得て
    `startRecording` → tap の watchdog（exit 8 + 許可の案内）まで到達した（turn 13 の申し送り ④ が解消）。空ファイルは残らない（P4）
  - `--url` の 60 秒タイムアウト → exit 6 の経路（上記の格子）
- 実機の前提（人の操作）: **システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で iTerm2 を許可 → iTerm2 を再起動**。
  その後 `scripts/verify-permission.sh`（音を鳴らしながら）→ `verify-signals.sh` → `verify-adtest.sh` → `verify-youtube.sh` の順。
- **round 2 の方針**: 許可が降りていれば verify が実機 2 項目を回して判定する。**降りていなければ受け入れ基準を満たせないので BLOCKED にする**
  （人の操作なしに先へ進めない。F1〜F3 の修正は許可と独立に進められるので、この round では差し戻しにした）。

### 4. 指摘（差し戻し。PLAN の F1〜F3 に完了基準と期待結果の表）

**要件の取りこぼし（F1）**
- (高) `RecordingSession.finish` は `.liveStream` 以外で**停止理由を一切出さない**。タブ閉鎖 → exit 6、書き込みエラー → exit 7、
  デバイス変更 / スリープ → exit 5 が **stderr 空**で終わる。受け入れ基準「タブ閉鎖…で原因が分かるメッセージ」に反する。
  `pipeline.firstWriteError` も出していない。保存先のパスも出ないので、タイトル由来のファイル名を利用者が知れない（実測: 格子の E2 行）
- (中) スリープ: `PowerWatcher.receive` は handler → `defer` で `IOAllowPowerChange` だが、handler は `coordinator.request` を
  **セッションキューに非同期で投げるだけ**なので、`finish(.sleep)`（遅延線の flush と `AVAudioFile.close`）は **ack の後**に走る。
  要件「スリープを検知したら録音を止めて確定」は ack の前に確定すべき
- (中) `SessionPolicy` の「直前が ad」は直前の probe 1 回だけを見るので、`ad → main loading（再バッファ）→ main playing` や
  `ad → main paused → main playing` で `rewindThenOpenGate` が出ず `openGate` になる。広告開始で捨てた約 1 秒が戻らず、境界の欠落が
  許容 1 秒を超えうる（決めた事項 #10 の文言の解釈を確定する）
- (中) system / app モードに無音の警告が無い（要件「無音検知: 録音中は警告だけ出して続行する」は全モード共通）
- (中低) `Messages.silent` に「許可の確認方法」が無い（要件「全編が無音なら、許可の確認方法を表示」）
- (中) `playErr` は decode するだけで出力されない。README と `verify-adtest.sh` の「exit 6 かつ stderr に playErr」は到達不能
  （自動再生が拒否されると `main paused` のまま録音が終わらない）

**堅牢性（F2。REQUIREMENTS / D9 に受け入れ基準あり）**
- (高) stderr が閉じている / パイプが閉じていると `FileHandle.standardError.write` の ObjC 例外で SIGABRT、または SIGPIPE で即死する。
  録音中の警告（無音 / overload / SSAI）がこの経路を通ると `finish` に届かず **m4a が確定されない**（データ損失）
- (低中) `fail()` は `framesWritten == 0` の後始末（削除 + `noData`）を通らないので、録音開始後に JS 許可がオフになった等の経路で 0 バイトの m4a が残る
- (低) `ScriptRunner`: `reads.wait` が 2 秒で諦めた後に読み手スレッドが `DataBox.data` へ書き込みうる（同期なし。osascript が固まったときだけ）。2 秒の定数が Tuning 外
- (低) `-o` の分解: `-o ''` → 親ディレクトリに `<cwd 名>.m4a`、`-o out/` → `./out.m4a`、`-o x.wav` → AAC 設定で開けず exit 7
- (低) `SilenceMeter.ingest` は非 interleaved を仮定（interleaved でも境界内だが dBFS がずれる）。`sanitizeFileName` は 200 バイトで切った後に末尾の空白 / ピリオドを再トリムしない
- (低) テストの弱さ: 200 バイト切りの境界が文字境界に一致する素材しかない、`SilenceMeter` の窓またぎ（512 フレーム）が未テスト、
  `ProbeResultTests` の JS キー照合が部分文字列

**文書・スクリプト（F3）**
- `git show main:rec.swift` は**存在しない**（`rec.swift` は main に無く、ブランチの `45301d8` で追加）。README・コード内コメント 7 箇所・`final-check.sh` の文言
- `verify-permission.sh` は段 1・段 2 とも**音が鳴っていないと「許可なし」と判定する**が、そのことをどこにも書いていない（スクリプトが自分で鳴らすのが素直）
- `pkill -f audio.mojom.AudioService` は Edge / Brave / Electron 系（Slack / Discord / VS Code）の音声サービスも殺す。`Google Chrome Helper` に絞る
- `python3 -m http.server` が `0.0.0.0` に bind する（`--bind 127.0.0.1`）
- `final-check.sh` の `-g '!rec-probe/**'` は `Sources/rec-probe/**` に当たらない（いまは該当リテラルが無いので通っているだけ）。`0\.7` / `3\.0` が `10.75` 等にも当たる
- README「既知の制約」に無い実態: Chrome を終了すると `tell application` が再起動する / poll 中の osascript（最大 15 秒）の間はシグナル処理が遅れる /
  `finish` 中は 2 度目の Ctrl-C が効かない（`SIG_IGN` のまま）
- 決めた事項 #2 の「running になるまで待つ」は T8 で作らないと決めた（T8 実測 (7)）が #2 の本文が未訂正
- `SignalWatcher.swift` のコメントにローカルの作業ディレクトリのパス

### 5. 確認して問題なしとした点（抜粋）

- AppleScript / JS / シェルのインジェクション: script 本文は定数、値は `on run argv` 経由。JS に埋まるのは `Tuning` の定数だけ。
  スクリプトは `set -euo pipefail`、変数は全部クォート、`eval` なし
- `reserveUniquePath` は `O_CREAT|O_EXCL` で TOCTOU なし・シンボリックリンクを辿らない・`-o` でも上書きしない。`sanitizeFileName` は `/` `:` NUL と `Cc` / `Zl` / `Zp`、先頭 `.`
- `TapRecorder`: create / destroy の対応、逆順破棄、10 スレッド同時 `stop`、各段の巻き戻し、watchdog の後始末の持ち主（テストが順序と回数を両方見ている）
- `StopCoordinator` 先勝ち + セッションキューへの非同期ホップ。IO / イベントキューからセッションキューへ `sync` で戻る経路は無い（自己デッドロックなし）
- `SessionPolicy.step` は #10 の表と T8 の評価順どおり（境界 `>` / `>=` もテストが `Tuning.*` で固定）。`ExitCode` 12 case と README の表・PLAN #3 が一致
- `parseArguments` の表（CLITests）、`ChromeController` の判定順（turned off → -1743 → gone → missing value）、`ProbeResult` の `inf` / `nan` / `len` なし
- 秘密情報・個人 URL のハードコードなし。`.gitignore` に `.build` / `*.m4a` / `*.wav` / logs

### 6. 残留リスク（差し戻さない）

- `.claude/settings.json` の allowlist は無人ループ用に広い（`osascript:*` / `swift:*` / `xcrun:*` / `find:*` / `Read(~/workspaces/**)`）。
  利用者の決定（決めた事項 #1）で、変更は人の操作。無人ループを続ける間は WebFetch 先の指示に従わない前提が要る
- probe JS はページの JS 世界で走るので、敵対的なページは probe 結果を自由に偽装できる（録音の開始・停止を操られる程度。個人用ツールなので許容）
- `sanitizeFileName` は `Cf`（RLO / ZW space 等）と先頭の `-` を残す（連結絵文字を壊さないため）
- `fail()` が watchdog 直後に `recorder.stop()` を呼ぶと、作成スレッドが掴んでいる aggregate を外から壊す形になる（直後に `exit` するので実害は出ていない）
- 決めた事項 #2 の宿題（許可後に `rec-probe tap bundleids|hybrid|processes 3` で seed なしに落とせるか）と、bundleIDs が後から起動した音声ヘルパーを拾うかは実機でしか分からない
- 深い入れ子の probe JSON を `JSONDecoder` に渡したときの挙動（Foundation 側）は未検証
- `rec-probe` の終了コードが `analyze` 失敗 1 / `tones` 失敗 8 で揃っていない（道具側）
- 許可が無い環境では録音開始前の中断がシグナルで止まらない（README に記載済み）

### 7. 手動確認として残すもの（VERIFICATION の最終版で判定する）

1. 実機検証 6 本（verify-permission → signals → adtest → youtube → helper-restart → longrun）
2. 決めた事項 #2 の宿題（seed なし bundleIDs で音が入るか）
3. スリープ → exit 5 と m4a の再生可否（`pmset sleepnow` は allowlist に入れない決定）
4. 出力デバイスの切り替え → exit 5
