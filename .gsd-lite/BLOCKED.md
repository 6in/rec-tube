# BLOCKED — rec-cli-hardening（turn 20 / verify round 3）

## 状況

コードは verify round 3 で**合格相当**（round 2 の差し戻し F4 は閉じた。VERIFICATION.md round 3 §1〜§2）。
機械検証は全段 green（クリーンビルド 2 種 warning 0 / Info.plist 埋め込み / `swift test` 225 本 / 追従チェック / CLI の exit）。

止まっている理由は 1 つだけ: **受け入れ基準「verify がループ内で実機録音を行い、ローカル検証ページの広告境界と
短い YouTube 動画の完走を確認する」**（REQUIREMENTS.md / D8 / D11）が、**システム音声の取得の許可が無いので実行できない**。
turn 4 / 11 / 12 / 14 / 18 / 20 の **6 回連続**で同じ症状:

```
$ timeout --preserve-status 40 swift run rec-probe tap system 2
rec-probe: step tap created: 101
rec-probe: step tap format: 48000Hz/2ch
rec-probe: step aggregate created: 102
rec-probe: tap の作成・開始が 10 秒で戻らなかった（システム音声の取得の許可ダイアログ待ちの可能性）
→ exit 8
```

tap と aggregate は作れるが `AudioDeviceCreateIOProcIDWithBlock` が戻らず、許可ダイアログも出ない（RESEARCH §2.5、PLAN メモ）。
round 2 の VERIFICATION で「round 3 で許可が無ければ BLOCKED」と決めていた。無人ループでは解決できない（人の操作が必要）。

## 依頼（推奨: 選択肢 A）

### A. 許可を付与して、verify を再開する（推奨）

1. **システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音**（macOS 26 では「システムオーディオの録音のみ」の
   項目でもよい）で、**ループを動かしているターミナルアプリ（iTerm2）** をオンにする。一覧に無ければ、tmux の外のターミナルで
   `.build/debug/rec -o /tmp/x.m4a` を 1 回実行して項目を出させる（Ctrl-C で止めてよい）
2. **iTerm2 を終了して起動し直す**（許可はホストアプリの再起動後に反映。tmux を使っているなら `tmux kill-server` の後にターミナルから tmux を起動し直す）
3. 手動で 1 回確かめる: `scripts/verify-permission.sh`（音を鳴らしながら）が段 1 を通れば許可は降りている
4. **無人ターンから `scripts/verify-*.sh` を回せるように allowlist を足す**（任意だが推奨）。`.claude/settings.json` の `permissions.allow` に
   **完全なファイル名で**追加する（prefix ルールは「完全一致」か「prefix + 空白」でしか当たらないので `Bash(scripts/:*)` では当たらない。PLAN turn 3 の訂正）:

   ```json
   "Bash(scripts/final-check.sh:*)",
   "Bash(scripts/verify-permission.sh:*)",
   "Bash(scripts/verify-signals.sh:*)",
   "Bash(scripts/verify-adtest.sh:*)",
   "Bash(scripts/verify-youtube.sh:*)",
   "Bash(scripts/verify-helper-restart.sh:*)",
   "Bash(scripts/verify-longrun.sh:*)"
   ```

   足さない場合、verify は各スクリプトの中身を allow 済みのコマンド（`timeout` / `.build/debug/rec` / `osascript` / `swift run rec-probe` / `afinfo`）で
   1 段ずつ手で再現する（時間がかかり、途中で承認待ちになりやすい）
5. `.gsd-lite/state.json` を `"phase": "verify"`, `"next_command": "/gsd-lite-verify"` に戻す（`turn` と `verify_round` はそのまま）
6. このファイルを削除してコミットし、ループを再開する。次の verify は F4 の再検証をせず、実機 6 本（permission → signals → adtest → youtube →
   helper-restart → longrun）と決めた事項 #2 の宿題だけを行い、合格ならベースブランチへ自動マージ（リモート無し）→ reflect へ進む

### B. 実機 2 項目を受け入れ基準から外して、このまま完了にする

REQUIREMENTS.md の「verify がループ内で実機録音を行い…」の 2 項目を「手動確認（VERIFICATION §6）」に格下げし、D8 を「実機はユーザーが
`scripts/verify-*.sh` で確認する」に改める。その上で A の 5〜6 と同じ手順で verify を再開すると、次の verify は合格 → マージ → reflect になる。
コードは round 3 で合格相当なので手戻りは無いが、**広告境界（混入ゼロ・欠落と重複 < 1 秒）と YouTube の完走は誰も実測していない状態で main に入る**。
許可をすぐ付与できない事情があるときの選択肢

### C. 許可を待つ間に、残留リスクの手直し（F5）を入れる

VERIFICATION round 3 §5 の 1 つ目（E11 のテストに `completion(ack=1)` の順序断言を足す）は 1 ターンで終わる軽い作業。
やるなら PLAN の Tasks 末尾に `- [ ] F5: E11 に completion が ack より後であることの断言を足す（Tests/RecCoreTests/RecordingSessionTests.swift のみ）` を
追記し、state を `"phase": "impl"`, `"next_command": "/gsd-lite-impl"`, `"verify_round": 3` にして再開する。impl 完了後の verify で再び許可を見る。
**コードの欠陥ではない**（検出力の欠け）ので、A だけで進めてもよい。

## 解除後に verify が行うこと（A の場合）

- `scripts/verify-permission.sh` → `verify-signals.sh` → `verify-adtest.sh` → `verify-youtube.sh` → `verify-helper-restart.sh` → `verify-longrun.sh` の順
- 決めた事項 #2 の宿題: `swift run rec-probe tap bundleids 3` / `hybrid` / `processes` で (a)〜(e) を測り、seed なしに落とせるか判定
- 合格: VERIFICATION に round 4 を追記 → `git checkout main` → `git merge --no-ff gsd-lite/rec-cli-hardening` → `phase: "reflect"`
- 広告境界が許容（欠落・重複 < 1 秒、混入 0 窓）を外れたら `--ad-guard` / `Tuning.adResumeRewindSeconds` の調整タスクを F5 として差し戻し（verify_round 3 = 上限）
