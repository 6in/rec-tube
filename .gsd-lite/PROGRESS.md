# PROGRESS — rec-cli-hardening

## turn 1 — research — Core Audio tap / Chrome AppleScript / SwiftPM の事実固め
- やったこと: rec.swift の行番号付き読解、Apple 公式 docs と SDK ヘッダ（Web ミラー）、Chromium の scripting.sdef、
  類似 OSS（AudioCap / AudioTee / catap / audiograb / Mimir）と YouTube userscript の DOM、~/workspaces の過去実装を調査し
  RESEARCH.md（§0〜§9）に集約。BLOCKED に値する発見（代替 OSS）はなし
- 想定外: Bash allowlist が `cat/grep/find/ls/...` でも Claude Code の作業ディレクトリ制限でリポジトリ外
  （Xcode SDK ヘッダ、Chrome の sdef、Chrome Preferences）を読めなかった。`swift` / `sdef` / `xcrun` は承認待ち。
  ヘッダは GitHub ミラー（alexey-lysiuk/macos-sdk）、sdef は Chromium ソースから取得して代替した。
  `CATapDescription.bundleIDs` の正確な意味は Apple 文書になく、実機プローブが必要と判明
- やり直し: 0 回
- 次への注意: (1) impl/verify で `swift build` / `swift test` を回すには `.claude/settings.json` の allow に
  `Bash(swift:*)` と `DEVELOPER_DIR=...` を含む形が要る。plan の最初のタスクで通らなければ BLOCKED にして allowlist 追加を依頼する。
  (2) リポジトリ外のファイルは Bash/Read とも読めないので、SDK ヘッダが要るときは Web ミラーを使う。
  (3) plan は RESEARCH.md §9 を先に読み、§7 の検証方法を完了基準に写す。§8-6 の bundleIDs プローブを最初の実機タスクにする
