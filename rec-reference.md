# rec.swift 関連リファレンス

対象: Core Audio Process Tap / Google Chrome AppleScript
作成: 2026-11-04

---

## 1. Core Audio Process Tap

### 概要

- プロセス（または複数プロセス）の出力音声を、マイクと同じように「入力」として扱える仕組み。
- 手順は「tap を作る → tap を入れた aggregate device を作る → その device から IOProc で読む」。
- tap は public（全ユーザーから見える）か private（作成したプロセスからのみ見える）を選べる。
- 元の出力をミュートして、音を tap にだけ流すこともできる（`muteBehavior`）。
- 対応 OS: `AudioHardwareCreateProcessTap` は macOS 14.2 以降。
  - サードパーティ実装（flexaudio）は 14.4 未満を弾いている。14.2〜14.3 は挙動が不安定な可能性あり。

### 権限

- Info.plist に `NSAudioCaptureUsageDescription` が必須。
- tap を含む aggregate device から最初に録音を始めたときに、システムが許可ダイアログを出す。
- 設定画面では「画面とシステムオーディオ録音」→「システムオーディオ録音のみ」に表示される。
- Sandbox アプリでも、tap 専用の entitlement は不要。

### 主要 API

| API | 用途 |
|---|---|
| `AudioHardwareCreateProcessTap(_:_:)` | `CATapDescription` から tap を作り、`AudioObjectID` を返す（14.2+） |
| `AudioHardwareDestroyProcessTap(_:)` | tap を破棄する |
| `AudioHardwareCreateAggregateDevice(_:_:)` | CFDictionary から aggregate device を作る |
| `AudioHardwareDestroyAggregateDevice(_:)` | aggregate device を破棄する |
| `AudioDeviceCreateIOProcIDWithBlock` | 指定したキューで入力バッファを受け取る |
| `AudioObjectGetPropertyData` / `SetPropertyData` | 各種プロパティの取得・設定 |

### CATapDescription

**イニシャライザ**

| init | 意味 |
|---|---|
| `init(stereoMixdownOfProcesses:)` | 指定プロセスだけをステレオにミックス |
| `init(monoMixdownOfProcesses:)` | 指定プロセスだけをモノラルにミックス |
| `init(stereoGlobalTapButExcludeProcesses:)` | 全プロセス（指定分を除く）をステレオで |
| `init(monoGlobalTapButExcludeProcesses:)` | 同上、モノラル |
| `init(processes:deviceUID:stream:)` | 特定デバイス・ストリームに限定して指定プロセスを |
| `init(excludingProcesses:deviceUID:stream:)` | 同上の除外版 |
| `init()` | 空で作り、プロパティで組み立てる |

**主なプロパティ**

| プロパティ | 内容 |
|---|---|
| `name` | 人が読む名前 |
| `uuid` | tap の UID。aggregate device の tap リストで参照する |
| `processes` | 対象（または除外）のプロセスオブジェクト ID |
| `isExclusive` | true なら `processes` 以外を全部 tap する |
| `isMixdown` / `isMono` | ミックスダウンの有無とモノラル化 |
| `isPrivate` | 作成プロセス専用にする |
| `muteBehavior` | 元の出力をミュートするか（`CATapMuteBehavior`） |
| `deviceUID` / `stream` | 特定のハードウェアデバイスやストリームに限定する |
| `bundleIDs` | バンドル ID で対象・除外を指定する |
| `isProcessRestoreEnabled` | 対象プロセスが終了・再起動しても、バンドル ID で自動的に再接続する（**macOS 26+**） |

> rec.swift への改善余地: macOS 26 以降なら、`bundleIDs` と `isProcessRestoreEnabled` を使えば、
> プロセス ID を列挙して前方一致させる処理が不要になる。Chrome のヘルパープロセスが
> 再起動したときにも追従できる。

### プロパティセレクタ（rec.swift で使用）

| セレクタ | 対象 | 内容 |
|---|---|---|
| `kAudioHardwarePropertyProcessObjectList` (`'prs#'`) | System | 音声クライアントのプロセスオブジェクト一覧 |
| `kAudioHardwarePropertyTranslatePIDToProcessObject` (`'id2p'`) | System | PID からプロセスオブジェクトへの変換 |
| `kAudioHardwarePropertyTapList` (`'tps#'`) | System | tap の一覧 |
| `kAudioProcessPropertyPID` | Process | PID |
| `kAudioProcessPropertyBundleID` (`'pbid'`) | Process | バンドル ID（CFString） |
| `kAudioProcessPropertyIsRunningOutput` / `Input` | Process | 出力中・入力中か |
| `kAudioTapPropertyUID` | Tap | tap の UID（CFString） |
| `kAudioTapPropertyFormat` | Tap | `AudioStreamBasicDescription` |
| `kAudioAggregateDevicePropertyTapList` | Aggregate | 後から tap を追加・削除する |

### aggregate device 作成時の辞書キー

| キー | 用途 |
|---|---|
| `kAudioAggregateDeviceNameKey` / `UIDKey` | 名前と一意 ID |
| `kAudioAggregateDeviceMainSubDeviceKey` | クロックの基準にするサブデバイス（通常は既定の出力） |
| `kAudioAggregateDeviceIsPrivateKey` | 作成プロセス専用にする |
| `kAudioAggregateDeviceIsStackedKey` | false にする |
| `kAudioAggregateDeviceTapAutoStartKey` | tap を自動で開始する |
| `kAudioAggregateDeviceSubDeviceListKey` | `[kAudioSubDeviceUIDKey: uid]` の配列 |
| `kAudioAggregateDeviceTapListKey` | `[kAudioSubTapUIDKey: tap.uuid, kAudioSubTapDriftCompensationKey: true]` の配列 |

tap は作成時の辞書で渡す方法（rec.swift の方式）のほかに、作成後に
`kAudioAggregateDevicePropertyTapList` で CFArray<CFString> を Set する方法もある（Apple サンプルの方式）。

### ハマりどころ

- CFString 型のプロパティは、`var s: CFString = "" as CFString` で受け、size に `MemoryLayout<CFString>.stride` を渡す。
- ブラウザの音は、本体ではなくヘルパープロセス（Chrome なら `com.google.Chrome.helper`）から出ている。
- IOProc が単一スレッドで非再入に呼ばれることは、Apple のドキュメントで保証されていない。
- 長時間の録音中のスリープ・復帰、出力デバイスの切り替え、対象プロセスの再起動は自前で対処する必要がある。
  - 例: `kAudioHardwarePropertyDefaultSystemOutputDevice` を監視して作り直す。
- ターミナルから CLI を実行した場合、許可は「責任プロセス」であるターミナルアプリに付く。

---

## 2. Google Chrome AppleScript

### 辞書の入手

公式の Web ドキュメントはありません。**アプリに同梱の sdef が一次資料**です。

```sh
sdef "/Applications/Google Chrome.app" > chrome.sdef
# GUI で見る場合: スクリプトエディタ → ファイル → 用語説明を開く → Google Chrome
```

### 主要な要素

| 要素 | 内容 |
|---|---|
| `window` | `tabs`, `active tab`, `active tab index`, `mode`（normal / incognito） |
| `tab` | `id`, `URL`, `title`, `loading` |
| `execute <tab> javascript <text>` | タブ内で JS を実行し、結果を返す |
| `make new window` / `make new tab` | ウィンドウやタブを作る |
| `close` | ウィンドウやタブを閉じる |
| `reload` / `go back` / `go forward` / `stop` | タブの操作 |

### execute javascript の前提

- 既定では無効です。「表示」→「開発 / 管理」→「Apple Events からの JavaScript を許可」をオンにします。
- 無効のままだと「turned off」を含むエラーが返ります。
- 初回は、macOS の「オートメーション」許可（ターミナル → Google Chrome）が求められます。
- 戻り値には、JS の最後の式の値が返ります（文字列で返すのが確実）。古い Chrome や設定が無効のときは `missing value` になるという報告があります。
- AppleScript の文字列リテラルに埋め込む場合、JS 側はシングルクォートだけを使うと安全です。

### rec.swift で使っているパターン

```applescript
-- 新しいウィンドウで開き、タブ ID を返す
tell application "Google Chrome"
  set w to make new window
  set URL of active tab of w to "https://..."
  return (id of active tab of w) as text
end tell

-- タブ ID を指定して JS を実行する（ユーザーがタブを切り替えても対象を見失わない）
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      if (id of t as text) is "123" then return execute t javascript "document.title"
    end repeat
  end repeat
end tell
```

- アクティブなタブを閉じる別の書き方: `delete tab (active tab index of window 1) of window 1`
- JXA の場合: `Application('Google Chrome').execute({javascript: '...'})`

### 代替手段

Chrome を `--remote-debugging-port` 付きで起動し、CDP（Puppeteer / Playwright）で操作する方法もあります。
JS 許可の設定が不要で、戻り値も確実に取れます。ただし普段使いのプロファイルとは分けて起動することになります。

---

## 3. 原文をまとめて取得する

Apple のドキュメントは、URL の末尾に `.md` を付けると Markdown で取得できます。

```sh
mkdir -p docs && cd docs
base=https://developer.apple.com/documentation/coreaudio
for p in \
  'capturing-system-audio-with-core-audio-taps' \
  'catapdescription' \
  'catapdescription/bundleids' \
  'catapdescription/isprocessrestoreenabled' \
  'catapdescription/isexclusive' \
  'catapdescription/deviceuid' \
  'catapmutebehavior' \
  'audiohardwarecreateprocesstap(_:_:)' \
  'audiohardwaredestroyprocesstap(_:)' \
  'audiohardwarecreateaggregatedevice(_:_:)' \
  'audiohardwaredestroyaggregatedevice(_:)' \
  'audiohardwareaggregatedevice' \
  'audiohardwareprocess'
do
  f=$(echo "$p" | tr '/():_' '-----' | tr -s '-' | sed 's/-$//').md
  curl -fsSL "$base/$p.md" -o "$f" && echo "ok  $f" || echo "NG  $p"
done
sdef "/Applications/Google Chrome.app" > chrome.sdef
```

- `NG` になったものは、パスの綴りが違う可能性があります。ブラウザで該当ページを開き、URL を確認してください。
- CoreAudio のヘッダが最も詳しい一次資料です:
  `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/AudioHardware.h`
  （`kAudioProcessProperty*` や `kAudioTapProperty*` の説明コメントがあります）

## 4. 参考実装

- AudioCap（insidegui）: Swift で書かれた最小構成のサンプル。rec.swift の構成もこれに近い。
- AudioTee（makeusabrew）: システム音声の PCM を標準出力に流す CLI。https://github.com/makeusabrew/audiotee
- catap（sbetko）: Python バインディング。Core Audio の注意点メモ（docs/core-audio-notes.md）が参考になる。https://pypi.org/project/catap/

## Sources

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps.md)
- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription.md)
- [AudioHardwareCreateProcessTap(_:_:)](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:).md)
- [CATapDescription.isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled.md)
- [CATapDescription.bundleIDs](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids.md)
- [xamarin-macios: CoreAudio xcode15.1 b2 diff](https://github.com/xamarin/xamarin-macios/wiki/CoreAudio-macOS-xcode15.1-b2)
- [flexaudio-os-macos version.rs](https://docs.rs/crate/flexaudio-os-macos/latest/source/src/version.rs)
- [catap (PyPI)](https://pypi.org/project/catap/0.5.1/)
- [AudioTee](https://github.com/makeusabrew/audiotee)
- [MacScripter: Google Chrome close tab and run javascript](https://macscripter.net/viewtopic.php?id=34505)
- [Keyboard Maestro Forum: Execute JavaScript on Chrome](https://forum.keyboardmaestro.com/t/execute-javascript-on-chrome-fails-no-matter-what/2436)
