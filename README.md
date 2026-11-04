# rec-tube

macOS の音声を録音する CLI。Core Audio の Process Tap で指定したプロセス（または全体）の
出力をそのまま掴み、`--url` では Chrome で YouTube を開いて**本編だけ**を m4a に残す。

> 現在 `rec-cli-hardening` マイルストーンの実装中。単一ファイル版から移した暫定コードは
> すべて `Sources/RecCore` の各型に置き換わった（単一ファイル版は `git show main:rec.swift`）。

## 必要なもの

- macOS 26.0 以降（`LSMinimumSystemVersion` = 26.0）
- **Xcode**（Command Line Tools だけでは不足。理由は下の「テスト」）
- Google Chrome（`--url` モードのみ）

## ビルド

```bash
scripts/build.sh                 # debug
scripts/build.sh -c release      # release
```

`scripts/build.sh` は `DEVELOPER_DIR` を Xcode に向けてから `swift build` を呼ぶだけの
ラッパで、引数はそのまま `swift build` に渡る。素のコマンドで叩くなら:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift build -c release
```

成果物は `.build/debug/rec` / `.build/release/rec`。

### Info.plist の埋め込み

Core Audio の tap はバイナリに `NSAudioCaptureUsageDescription` が無いと許可を求められない。
SwiftPM のビルドではバンドルを作らないので、`Sources/rec/Info.plist` を
`-sectcreate __TEXT __info_plist` でバイナリへ直接埋め込んでいる（`Package.swift` の
`linkerSettings`）。埋まっているかは `otool` で確かめる:

```bash
otool -s __TEXT __info_plist .build/debug/rec   # セクションがあるか
otool -P .build/debug/rec                       # plist の中身を読む
```

## テスト

```bash
scripts/test.sh                      # 全部
scripts/test.sh --filter DelayLine   # 絞る（引数は swift test に素通し）
```

テストは Swift Testing（`import Testing`）を使う。これは **Xcode のツールチェインにしか
入っていない**ため、Command Line Tools だけの環境では解決できない。そのため scripts は
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を export してから `swift` を呼ぶ。

クリーンな状態からの最終判定（ビルド 2 種・plist 埋め込み・テスト・文書の追従・終了コード）:

```bash
scripts/final-check.sh
```

## 使い方

```bash
rec                                      # システム全体の音を録音（Ctrl-C で停止）
rec --app com.google.Chrome              # バンドル ID 前方一致のプロセスだけ録音
rec --url 'https://www.youtube.com/watch?v=XXXX'   # Chrome で開いて本編だけ録音
rec --list                               # 音声を扱っているプロセスの一覧（録音しない）
```

| オプション | 既定 | 意味 |
|---|---|---|
| `-o <パス>` | `rec-<日時>.m4a`（`--url` はページのタイトル由来） | 出力先。拡張子が無ければ `.m4a` を付ける |
| `--ad-guard <秒>` | `1.0`（範囲 `0`〜`10`） | 広告ガードの遅延。`--url` のときだけ効く |

- **出力ファイル名**: `-o` 省略時は `--url` ならページのタイトル（使えない文字は `_`、UTF-8 で 200 バイトに切る）、
  それ以外は `rec-yyyyMMdd-HHmmss.m4a`。**同名のファイルがあれば `-2` / `-3` … を拡張子の手前に付ける**
  （`-o` を指定した場合も同じ。既存ファイルを上書きしない）。
- **`--url` の停止条件**: 再生が最後まで終わる / 次の動画へ遷移する / タブが閉じられる。
  広告は録音に含めず、広告明けは `0.7` 秒だけ巻き戻してから録り直す。
- **`--url` 以外**は広告判定をしないので遅延線を使わない（`--ad-guard` は無視される）。
- 1 フレームも録れなかったときは出力ファイルを残さない。全編無音のときはファイルを残して警告する。
- **`--help` / `-h` は未実装**。引数エラーとして扱い、使い方の全文を stderr に出して exit 1 で終わる。
- 録音の前に要る設定は「許可（事前設定）」、終了の見分け方は「終了コード」、録れない / 混ざるケースは「既知の制約」。

## 許可（事前設定）

3 種ある。`--url` 以外のモードで要るのは 1 つめだけ。

### 1. システム音声の録音

「システム設定 > プライバシーとセキュリティ > **画面とシステムオーディオの録音**」でターミナルアプリを許可する。
バイナリに `NSAudioCaptureUsageDescription` を埋め込んでいるのは、この許可を要求できるようにするため（上の「Info.plist の埋め込み」）。

- **責任プロセスはターミナルアプリ**: CLI は自分では許可を要求できない。許可は `rec` ではなく、
  `rec` を起動したターミナルアプリ（iTerm2 / Terminal.app など）に付く。一覧に並ぶのもターミナルアプリの名前。
- **tmux / screen の注意**: tmux 越しに起動すると許可ダイアログが出ないことがある。**tmux の外で 1 回実行**し、
  `tmux kill-server` のあと端末を再起動する。
- **許可を与えたらターミナルアプリ自体を再起動する**。再起動するまで反映されない。
- やり直しは `tccutil reset ScreenCapture`。
- **許可が無いときの症状（実測）**: ダイアログが出ないまま `AudioDeviceCreateIOProcIDWithBlock` が無期限にブロックする。
  **10 秒の watchdog（`Tuning.tapStartTimeoutSeconds`）で exit 8** になり、`Messages.systemAudioPermission`
  の案内（許可の場所・tmux の注意・`tccutil reset ScreenCapture`）が stderr に出る。

### 2. オートメーション（`--url` のみ）

「システム設定 > プライバシーとセキュリティ > **オートメーション**」で、ターミナルアプリに Google Chrome の操作を許可する。
未許可だと AppleScript エラー **-1743** になり、`Messages.chromeAutomationPermission` を出して **exit 2**。

### 3. Apple Events からの JavaScript（`--url` のみ）

Chrome のメニュー「表示 > 開発/管理 > **Apple Events からの JavaScript を許可**」をオンにする。
未許可だとページの状態を取れないので、`Messages.chromeJavaScriptPermission` を出して **exit 2**。

## 終了コード

`Sources/RecCore/ExitCode.swift` の enum と同一。

| code | `ExitCode` | 意味 | 主な `StopReason` / 発生箇所 |
|---|---|---|---|
| 0 | `.ok` | 正常終了（再生終了・次の動画への遷移） | `.ended`, `.nextVideo` |
| 1 | `.usage` | 引数・URL 不正、`--app` に一致なし | `parseArguments` |
| 2 | `.chromeUnavailable` | Chrome 制御不可（起動不可・オートメーション未許可 -1743・JS 許可オフ・ウィンドウ作成失敗） | `ChromeController` |
| 3 | `.liveStream` | ライブ配信 / プレミア公開 | `.liveStream`（録音開始前。開いたタブは閉じる） |
| 4 | `.silent` | 全編無音（権限なしの疑い）。ファイルは残す | `.permissionSuspected`, 終了時の無音判定 |
| 5 | `.interrupted` | 出力デバイス変更・スリープ・coreaudiod 再起動・IO 異常停止・デバイス消失・tap 故障 | `.deviceChanged`, `.sleep`, `.serviceRestarted`, `.ioStopped`, `.deviceDied`, `.tapStalled` |
| 6 | `.pageLost` | タブ閉鎖・60 秒以内に動画が見つからない / 再生開始しない・20 秒応答なし | `.tabClosed`, `.pageUnavailable`, `.pageUnresponsive` |
| 7 | `.outputUnavailable` | 出力ファイルを作れない・書き込みエラー | `.writeFailed`, `OutputPath`, `AVAudioFileWriter` |
| 8 | `.coreAudio` | tap / aggregate / IOProc の作成・開始失敗、`--list` 取得失敗、その他の予期しないエラー | `TapRecorder.start`, main の catch-all |
| 129 | `.signalHUP` | SIGHUP で中断（128 + 1） | `.signal(1)` |
| 130 | `.signalINT` | SIGINT で中断（128 + 2）。`Ctrl-C` がこれ | `.signal(2)` |
| 143 | `.signalTERM` | SIGTERM で中断（128 + 15） | `.signal(15)` |

優先順位は停止理由の code が先。非ゼロならその code で終わる。ゼロ（`.ended` / `.nextVideo`）のときだけ、
終了時の無音判定で 4 になりうる。シグナルは 128 + シグナル番号。

## 検証

- `scripts/final-check.sh` — 録音せずに通る機械検証。クリーンビルド 2 種（debug / release）→ plist 埋め込み → `swift test` → 文書の追従 → CLI の終了コード。

実機検証のスクリプトは **6 本**。出力は `.gsd-lite/logs/rec-cli-hardening/scratch/` 配下に置かれる。
いずれも `timeout` に依存せず bash の `sleep` + `kill` で制御する。

- `scripts/verify-permission.sh` — 録音を開始できるか（`rec-probe tap system 2`）と 2 秒のシステム全体録音が全ゼロでないかを見る。前提: システム音声の録音。
- `scripts/verify-signals.sh` — 3 秒録音して SIGINT / SIGTERM / SIGHUP を送り、exit 130 / 143 / 129 と 2 秒以上の m4a が残ることを見る。前提: システム音声の録音。
- `scripts/verify-adtest.sh` — ローカル検証ページを `--url` で録り、広告混入 0 窓・本編 12 秒 ± 1 秒を見る。前提: 許可 3 種すべて。
- `scripts/verify-youtube.sh` — 実際の YouTube（既定 `https://www.youtube.com/watch?v=jNQXAC9IVRw`）を完走させ、exit 0・duration > 0・出力名がタイトル由来を見る。前提: 許可 3 種すべて。
- `scripts/verify-helper-restart.sh` — 録音中に `pkill -f audio.mojom.AudioService` で Chrome の音声ヘルパーを落とし、完走後の後半にも可聴窓があるかを見る。前提: 許可 3 種すべて。
- `scripts/verify-longrun.sh` — システム全体録音を N 分（既定 10 分）続け、`ps -o rss=` の差が 10 MB 未満かを見る。前提: システム音声の録音。

実行順の推奨は verify-permission.sh → verify-signals.sh → verify-adtest.sh → verify-youtube.sh →
verify-helper-restart.sh → verify-longrun.sh。許可の確認から始めて、録音だけ・ローカルページ・実ネットワーク・
異常系・長時間の順に重くなる。

### ローカル検証ページ

`Tests/Fixtures/adtest.html` は広告の切り替わりを再現するページ。素材を作ってから `--url` で録り、トーンで判定する:

```bash
swift run rec-probe tones Tests/Fixtures   # main.wav (440 Hz 12 秒) / ad.wav (1 kHz 4 秒) を作る
.build/debug/rec --url "file://$PWD/Tests/Fixtures/adtest.html?v=local1" -o /tmp/adtest.m4a
swift run rec-probe analyze /tmp/adtest.m4a --main 440 --ad 1000 --expect-main 12
```

期待は「広告混入 0 窓・本編 12 秒 ± 1 秒」。この一連の流れは `scripts/verify-adtest.sh` が行う。

### 自動再生の段階的対処

`rec` が exit 6 で終わり stderr に `playErr` が出たときは、Chrome が自動再生を拒否している。次の順に試す:

1. `file://` のまま（probe の `play()` で動く見込み）。
2. `python3 -m http.server 8765 --directory Tests/Fixtures` 経由で `http://localhost:8765/adtest.html?v=local1` を録る。
3. Chrome の自動再生を許可する（`AutoplayAllowlist` ポリシー、または `chrome://settings/content/sound`）。

**(3) は人の操作。スクリプトは実行しない。**

## 既知の制約

- **他タブ・他プロセスの音が混ざる**: `--url` / `--app` は Chrome のプロセス単位で音を掴むので、
  同じ Chrome の別タブが鳴っていれば混ざる。録音中は対象以外のタブをミュートする。
- **SSAI（サーバ側広告挿入）には効かない**: DOM に広告のクラスが付かないので広告ガードが働かない。
  `dur > len × 1.2` を検出したときに 1 回だけ警告する。それ以上のことはしない。
- **SIGKILL / 電源断で m4a が壊れる**: `.m4a` は終了時に `moov` アトムを書くので、`kill -9` や電源断では
  ファイルが再生不能になる。`SIGINT` / `SIGTERM` / `SIGHUP` なら正しく閉じる（exit 130 / 143 / 129）。
- **手動の一時停止を自動再生してしまう**: `--url` の監視は「本編が止まっていたら再生を促す」ので、
  人が一時停止しても録音を続けるために再生が再開される。止めるときは `Ctrl-C`。
- **ライブ配信・プレミア公開は非対応**: 検出したら録音を始めずに exit 3（自分で開いたタブは閉じる）。
- **出力デバイスの切替・スリープでは停止して保存する（自動復旧しない）**: 既定の出力デバイスが変わる・
  スリープに入る・coreaudiod が再起動する・IO が異常停止する・デバイスが消える、のいずれでも
  そこまでを保存して exit 5 で終わる。
- **`--url` は YouTube 向け**: `<video>` のあるページはベストエフォートで録れるが、
  **広告判定（`#movie_player.ad-showing` / `.ad-interrupting`）は YouTube の DOM に依存する**。
- **macOS 26 以上が必要**（`LSMinimumSystemVersion` = 26.0）。Core Audio の Process Tap と bundle-ID tap に依存する。
- **許可が無い環境では「録音開始前の中断」をシグナルで止められない**（実測）: 録音開始はセッションキュー上で
  同期に走るので、`AudioDeviceCreateIOProcIDWithBlock` がブロックしている 10 秒間は `SIGINT` のハンドラが
  走れず `Ctrl-C` が効かない。10 秒後に watchdog が exit 8 で終わる。
- **引数の一部は仕様として約束していない**: `--help` / `-h` は未実装で、未知の引数として引数エラーに落ちる
  （使い方を出して exit 1）。オプション名で始まらない裸の位置引数も同じく「不明な引数」で exit 1。
  同じオプション（モード・`-o`・`--ad-guard`）を重複指定すると**現状は最後が勝つ**が、
  約束しているのはモードの重複だけで、`-o` / `--ad-guard` の勝敗は将来変わりうる。
