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

<!-- T9 の下書き。許可・終了コード・既知の制約との相互参照は T11 で仕上げる。 -->

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

## 許可（事前設定）

<!-- TODO(T11): 3 種（システム音声の録音 / オートメーション / Apple Events からの JavaScript）の
     設定場所と、許可されていないときに rec が出すメッセージを書く -->

## 終了コード

<!-- TODO(T11): PLAN「決めた事項」#3 の表をそのまま載せる -->

## 検証

<!-- TODO(T11): scripts/verify-*.sh の一覧と前提条件を書く -->

## 既知の制約

<!-- TODO(T11): SIGKILL / 強制終了時のファイル、SSAI、ライブ配信非対応などを書く -->
