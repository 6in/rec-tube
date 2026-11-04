# rec-tube

macOS の音声を録音する CLI。Core Audio の Process Tap で指定したプロセス（または全体）の
出力をそのまま掴み、`--url` では Chrome で YouTube を開いて**本編だけ**を m4a に残す。

> 現在 `rec-cli-hardening` マイルストーンの実装中。`Sources/RecCore/Legacy.swift` は
> 単一ファイル版から移した暫定コードで、T3〜T9 で置き換わる。

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

<!-- TODO(T11): 3 モード・オプション一覧・出力ファイル名の規則を書く -->

## 許可（事前設定）

<!-- TODO(T11): 3 種（システム音声の録音 / オートメーション / Apple Events からの JavaScript）の
     設定場所と、許可されていないときに rec が出すメッセージを書く -->

## 終了コード

<!-- TODO(T11): PLAN「決めた事項」#3 の表をそのまま載せる -->

## 検証

<!-- TODO(T11): scripts/verify-*.sh の一覧と前提条件を書く -->

## 既知の制約

<!-- TODO(T11): SIGKILL / 強制終了時のファイル、SSAI、ライブ配信非対応などを書く -->
