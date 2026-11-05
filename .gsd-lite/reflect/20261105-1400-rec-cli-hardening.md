# 振り返り — rec-cli-hardening（2026-11-05 14:00）

- 種別: ループ（verify 合格後）
- 対象範囲: e3eeab7...ef707de（コミット 55 件。コードは 63 ファイル +12,181 行）/ ターン 1〜21
- 前回の振り返り: なし（初回マイルストーン）

## 計測（turns.jsonl から）

| フェーズ | ターン数 | 試行数 | 所要（分） | リトライ | 出力トークン | キャッシュ読み | コスト（USD） | エンジン / モデル |
|---|---|---|---|---|---|---|---|---|
| research | 1 | 1 | 11 | 0 | 45,125 | 2,301,047 | 12.08 | claude / claude-fable-5-1 |
| plan | 1 | 1 | 17 | 0 | 74,043 | 1,129,218 | 7.09 | claude / claude-fable-5-1 |
| impl | 15 | 16 | 255 | 1 | 410,605 | 105,781,644 | 149.98 | claude / claude-opus-5 |
| verify | 3 | 3 | 43 | 0 | 105,355 | 9,162,840 | 41.42 | claude / claude-fable-5-1 |
| 合計 | 20 | 21 | 326 | 1 | 635,128 | 118,374,749 | 210.57 | |

- turn 21（verify round 4。対話セッションで実施）は turns.jsonl に行が無い。**記録なし**（所要・コストとも不明）
- この reflect ターン（ループ表示は turn 22）は書いている時点では未記録
- 権限拒否（permission_denials）: 合計 94 件（Bash ×91 / Read ×2 / Edit ×1）。
  ターン別: turn 1 ×23、turn 2 ×2、turn 3 ×6、turn 4 ×3、turn 6 ×1、turn 7 ×5、turn 10 ×1、turn 12 ×2、
  turn 13 ×5、turn 14 ×31、turn 15 ×9、turn 17 ×5、turn 19 ×1
- 計画タスク数 / impl ターン数: 11（T1〜T11）/ 15（T に 11 ＋ 差し戻しの F1〜F4 に 4）。T は 1 タスク 1 ターンで分割・追加なし
- verify 差し戻し: 2 回（round 1 = 指摘約 20 件を F1〜F3 に、round 2 = 指摘 2 件を F4 に）。
  round 3 は指摘 0 で BLOCKED、round 4（対話セッション）で合格。`verify_round` は 2 のまま
- BLOCKED: 2 回。(1) turn 2（plan）= allowlist の追加待ち。18:27 → 19:24 に解除（57 分）。
  (2) turn 20（verify round 3）= システム音声の取得の許可が無く実機録音ができない。00:23 → 13:58 に合格コミット（約 13.5 時間）
- 前回の提案の反映: 対象なし（初回）

## Plus（うまくいったこと）

- 「共有型と test double は親が先に確定し、テストは仕様表から独立に書かせる」並列構成が 7 ターン連続で統合時の修正 0〜1 件だった
  （根拠: PROGRESS turn 7〜13 の「やり直し」欄。turn 9 は B の 25 本、turn 10 は B の 48 本、turn 11 は A' の 15 本が実装に手を入れず green）
- その構成が実際に不具合を 2 件拾った。T5 で watchdog 打ち切り時の破棄順が逆順にならない仕様違反、T8 で `len == 0` のとき SSAI 警告が
  毎回出る仕様の不備（根拠: PROGRESS turn 7 想定外 (1)、turn 10 想定外 (2)）
- 実機プローブを最初の実機タスク（T2）に置いたので、「許可が無いと `AudioDeviceCreateIOProcIDWithBlock` が無期限に固まる」を turn 4 で掴み、
  10 秒 watchdog（exit 8 ＋ 許可の案内）を製品の仕様にできた（根拠: PROGRESS turn 4 想定外 (1)、PLAN T5 の追記）
- verify round 1 の堅牢性の格子（約 40 ケース）が、stderr 閉鎖で SIGABRT・パイプ閉鎖で SIGPIPE というデータ損失につながる 2 件を見つけた。
  driver はそのまま F2 と round 2 の回帰確認に再利用された（根拠: VERIFICATION round 1 §2、PROGRESS turn 16・18、コミット ca12322）
- 「round 2 以降は新しいクラスを探さない」方針で verify のコストが回ごとに下がった: 20.57 → 12.37 → 8.48 USD、1364 → 685 → 550 秒
  （根拠: turns.jsonl turn 14 / 18 / 20）
- 各 impl ターンが「既存テストの期待値を変えた箇所」を申し送りに書き、verify が `git diff` で突き合わせた。テストは 0 → 225 本で、
  期待値の変更は T3 の 1 件（設計どおり）だけ（根拠: PROGRESS turn 5〜19 の該当欄、VERIFICATION round 2 §5）
- F4 は「先に fake を本物と同じ制約にして、既存テストが落ちるのを確認してから直す」手順で進み、テストだけ green になる直し方を避けた
  （根拠: PROGRESS turn 19、コミット 9f1b4fa）
- 実機 6 本はスクリプト修正後にすべて rc=0。adtest は広告混入 0 窓・本編 11.8 秒（期待 12、許容差 1.0 未満）
  （根拠: VERIFICATION round 4 §2）

## Minus（問題・無駄・やり直し）

- **受け入れ基準「verify がループ内で実機録音を行う」は、このループの動かし方では最初から満たせなかった**。許可は iTerm2 に付き、
  tmux 配下のプロセスには継承されない。許可なしの実測が turn 4 / 11 / 12 / 14 / 18 / 20 の 6 回続き、最後は人が tmux の外で手動実行して代えた
  （根拠: PROGRESS turn 21 想定外 (2)(3)、VERIFICATION round 4 §5、BLOCKED.md a5ff06c）—
  原因の見立て: 材料は早い段階から揃っていた。discuss の時点で DECISIONS に「シェルは tmux 上。システム音声の許可の付与先は要確認」とあり、
  RESEARCH §2.5 が tmux の挙動を書き、turn 2 の BLOCKED.md も人に確認を頼んでいる。それでも**ループの実行環境で 1 回録ってみる**確認が
  どこにも入らなかった。解除コミット 0228418 は allowlist と state だけで、許可を確かめた記録は無い
- **turn 4 で許可なしと分かってから 16 ターン、人に届く形で止めなかった**。PLAN T2 が「許可が無くても BLOCKED にせず記録して続行」と指示し、
  以後は毎ターンの「次への注意」に同じ依頼が並んだだけだった（根拠: PLAN 119 行、PROGRESS turn 4〜19 の次への注意）—
  原因の見立て: 「次への注意」は次のターンのエージェントしか読まない。人に届く経路は BLOCKED.md だけなのに、PLAN がそれを使わせなかった。
  推測: turn 4 で止めていれば、許可と独立な T3〜T9 を先に進める利点は失うが、verify-*.sh 6 本と bundleIDs の宿題を
  impl の途中で実機に当てられた
- **実機でしか出ない不具合が最後の人の手動実行まで残った**。`scripts/*.sh` 7 本 32 箇所が macOS の `/bin/bash` 3.2 で `$var）` を
  変数名として読み `unbound variable` で落ちた。スクリプトは turn 12〜13 で書かれてから turn 21 まで一度も実行されていない
  （根拠: VERIFICATION round 4 §4、コミット 3310320、PROGRESS turn 13「実機検証 6 本すべて未実施」）—
  原因の見立て: 上の 2 件の帰結。加えて `bash -n` は構文しか見ないので、この種の実行時エラーは検出できない
- **`scripts/final-check.sh` が最後まで無人ターンから実行できなかった**。PLAN が「最終判定」に指定したコマンドなのに、
  turn 3 / 13 / 14 / 17 / 18 / 20 は中身を素のコマンドで 1 段ずつ再現し、turn 17 は追従チェック節の写しを scratch に作った
  （根拠: PROGRESS turn 3 想定外 (1)、turn 17 次への注意 (6)、VERIFICATION round 2 §1）—
  原因の見立て: turn 2 の依頼は `Bash(scripts/:*)` で、記録によると prefix ルールは `scripts/build.sh` に当たらない。
  完全なファイル名が要ると turn 3 で分かったが、その依頼は PROGRESS に書かれただけで人に届かず、現在の allowlist にも入っていない
- **turn 13 の attempt 1 が 1021 秒・8.42 USD を使ってコミットなしで終わった**。ログは「サブエージェント T11-B が最後のターンから
  10 分たっても動いていたので停止」。親はサブエージェントの完了通知を待つと書いてターンを終えていた
  （根拠: turns.jsonl turn 13 attempt 1 = 出力 78 トークン / num_turns 1 / progressed false、turn-013-attempt1.log）—
  原因の見立て: 無人実行ではターンを終えると待ち時間の上限で打ち切られる。作業ツリーに成果が残ったので attempt 2 が取り込めたのは偶然の救い。
  turn 14 でも完了待ちに `tail -f /dev/null` や `swift -e 'Thread.sleep…'` を使っており、待ち方が定まっていない
- **verify round 1 で受け入れ基準の取りこぼしが（高）で見つかった**。タブ閉鎖・書き込みエラー・デバイス変更・スリープが stderr 空で終わり、
  「原因が分かるメッセージを出して非ゼロ終了」に反していた。11 タスクの impl を通り抜けている
  （根拠: VERIFICATION round 1 §4、PLAN 1037 行「表の行動には書いていなかったが、受け入れ基準…の対象」）—
  原因の見立て: PLAN メモには RESEARCH の落とし穴 → タスクの対応表はあるが、REQUIREMENTS の受け入れ基準 → タスクの完了基準の対応表が無い。
  停止理由の出力はどのタスクの完了基準にも入っていなかった
- **F1 の修正がスリープ経路に回帰を入れ、テストは green のままだった**。`FakePowerSource` が `unregister` 後の ack も記録していたため
  （根拠: VERIFICATION round 2 §4、PROGRESS turn 18 想定外 (1)）—
  原因の見立て: fake が本物の「解除後の呼び出しは無効」という制約を持っていなかった。差し戻し 1 回分（F4）の原因
- **`gsd-lite-loop.sh --where` の承認待ちが 7 ターンで起きた**（turn 3 / 4 / 7 / 13 / 15 / 17 / 19）。パスを付けたり `2>/dev/null ||` で
  つないだりした形で、turn 17 は `find / -name gsd-lite-loop.sh` まで試している（根拠: turns.jsonl の permission_denial_inputs）—
  原因の見立て: allowlist は素の `gsd-lite-loop.sh --where` にしか当たらない。7 件とも impl のターン
- **exit コードを見るための `; echo "exit=$?"` / `${PIPESTATUS[0]}` が 30 件近く拒否された**。turn 14 だけで 22 件あり、
  約 20 コマンド分を Swift の driver に作り直した（根拠: turns.jsonl turn 3 / 4 / 6 / 10 / 13 / 14 / 15 の inputs、PROGRESS turn 14 やり直し）
- **`git -C <path> …` の承認待ちが turn 1 / 2 / 7 / 15 / 17 で繰り返された**。turn 2 で PLAN に「素の形で呼ぶ」と書いた後も 3 回
  （根拠: turns.jsonl の inputs、PLAN 43 行）
- **格子が開いた Chrome のタブが片付けられずに残った**。turn 16 の 4 つは申し送りに「閉じること」とあったのに残り、turn 18 が 6 つまとめて閉じた
  （根拠: PROGRESS turn 14 想定外 (1)、turn 18 想定外 (2)）— 原因の見立て: 後始末が driver ではなく申し送りの文章に任されていた
- **存在しない参照 `git show main:rec.swift` が 10 箇所に広がった**。turn 2 の PLAN が書き、turn 17 で `45301d8:rec.swift` に訂正
  （根拠: PROGRESS turn 17 想定外 (1)）— 原因の見立て: plan が書いた参照を実行して確かめていなかった
- research の拒否 23 件はリポジトリ外（Xcode SDK ヘッダ、Chrome の sdef）の読み取りと `swift` / `xcrun` / `sdef`。Web ミラーで代替した
  （根拠: turns.jsonl turn 1、RESEARCH §0）

## Interesting（気づき・意外だったこと）

- **`cost_usd` と `usage` は範囲が違うように見える**。turn 13 attempt 1 は出力 78 トークンで 8.42 USD。turn 8 は出力 10,551 で 9.18 USD、
  turn 3 は出力 33,064 で 4.18 USD（根拠: turns.jsonl）。推測: コストはサブエージェント分を含み、トークンは親だけ。
  表の「出力トークン」は並列サブ作業を使ったターンでは実際より小さい
- **記録の食い違い**: PROGRESS turn 13 は「やり直し 0 回」「前のターン（turn 12 の後）の作業ツリーに T11 の実装が残っていた」と書くが、
  turns.jsonl では turn 13 は 2 試行で、残っていたのは同じ turn 13 の attempt 1 の成果（根拠: turns.jsonl、turn-013-attempt1.log）。
  attempt 2 のエージェントには attempt 1 が見えていない
- **ターン番号のずれ**: turn 21 は対話セッションで実施され turns.jsonl に行が無い。loop.log はこの reflect を「turn 22」と表示して始めている
  （根拠: loop.log 末尾、state.json の turn 21）
- **turn 21 の 3 コミット（スクリプト修正 3310320 / マージ e3096d2 / verify ef707de）は同じ 13:58:22**。実機 6 本は 08:10〜08:31、
  宿題は 11:33、final-check は 13:56（根拠: git log、VERIFICATION round 4）。推測: 作業の最後にまとめてコミットした
- 「未確認」のまま数ターン持ち越した前提が、1 コマンドで確かめられるものだった。Chrome のオートメーション許可は turn 9 で
  `osascript … get version` 1 回、JS 許可は turn 14 で `execute … javascript "1+1"` 1 回で解消（根拠: PROGRESS turn 9 想定外 (2)、turn 14 想定外 (4)）
- 人が plan ターンの実行中に 2 回コミットしている（18:11 allowlist 追加 323e946、18:16 README 要件の追加 2715d3d）。
  plan は 18:27 にさらに allowlist を求めて BLOCKED にした（根拠: git log）。追加された README 要件は最終的に満たされている（VERIFICATION round 3 §4）
- 権限チェックの癖がいくつか記録された: `awk -v j='{…}'` は「Brace expansion」、`awk -f` は事前に検査できないとして拒否、
  `grep --include=*.swift` は zsh のグロブ展開で失敗、`diff <(…) <(…)` は不可（根拠: PROGRESS turn 13 想定外 (2)、turn 18・20 の次への注意）
- PLAN.md は 1,113 行・140 KB まで育った（「PLAN 訂正」「PLAN 追記」「実測」の追記による）。impl のキャッシュ読みは 1 ターン平均 約 700 万トークン
  （根拠: PLAN.md のサイズ、turns.jsonl）。推測: 毎ターン読む PLAN の大きさが impl のコストに効いている。因果は記録からは確かめられない
- 決めた事項 #2 の宿題（seed なし bundleIDs）は実機で「無音」と分かり、turn 4 から仮置きだった hybrid がそのまま正解だった。
  コード変更なしで済んだのは結果論（根拠: VERIFICATION round 4 §3）
- 7 日枠の使用率は 2% → 16%（根拠: turns.jsonl の rate_limit）

## 次回への提案（実行可能な形で）

- [ ] **discuss: 受け入れ基準が OS の許可（TCC など）に依存するなら、ループを動かすのと同じ環境（tmux の中）で確認コマンドを 1 回実行し、
  結果を DECISIONS に書いてからループを始める**。通らなければ「実機検証は人が tmux の外で実行する」を最初から受け入れ基準にする。
  「要確認」のまま始めない（Minus 1）
- [ ] **plan: 受け入れ基準が依存する前提の確認を最初のタスク（T0）にし、失敗したら BLOCKED にする**。「記録して続行」を選ぶのは、
  その前提が受け入れ基準に関係しないときだけにする。BLOCKED 解除後の最初のターンは同じ確認コマンドを再実行する（Minus 2・3）
- [ ] **plan: allowlist の依頼は、PLAN が作らせるスクリプトを完全なファイル名で 1 本ずつ書く**
  （`Bash(scripts/final-check.sh:*)` の形。`Bash(scripts/:*)` は当たらなかった）。構文検査用の `Bash(bash -n:*)` も一緒に頼む（Minus 4）
- [ ] **impl / verify スキル: 人の操作が要る依頼を「次への注意」に 2 ターン続けて書くことになったら、BLOCKED.md に書いて止める**。
  「次への注意」は人に届かない（Minus 2・4）
- [ ] **plan: REQUIREMENTS の受け入れ基準を 1 行ずつ、どのタスクのどの完了基準が担うかの対応表にして PLAN メモに置く**。
  担い手の無い行があれば PLAN を完成扱いにしない（Minus 6）
- [ ] **plan: OS 資源の fake を作るタスクの完了基準に「解除・破棄の後の呼び出しを fake が無効として数える」を入れる**（Minus 7）
- [ ] **plan / impl: シェルスクリプトを作るタスクの完了基準に「許可が要らない経路で 1 回実行する」を入れる**（`bash -n` だけにしない）。
  macOS の `/bin/bash` 向けには「全角文字の直前の変数は `${var}`」を PLAN の作法に書く（Minus 3）
- [ ] **impl スキル: 無人ターンではサブエージェントを `run_in_background: false` で出し、完了を待つためにターンを終えない**。
  あわせてリトライ時は `turn-NNN-attempt1.log` を先に読む手順を入れる（Minus 5、Interesting 2）
- [ ] **スキル本文: `gsd-lite-loop.sh --where` は「パスを付けず、`||` や `2>/dev/null` を足さず、この形のまま」と明記する**。
  または allowlist に `Bash(./gsd-lite-loop.sh --where:*)` を足す（Minus 8）
- [ ] **スキルの「シェルの作法」に exit コードの取り方を 1 つ決めて書く**。今回通った形は
  `timeout --preserve-status <秒> <コマンド>` と、`swift <driver>.swift` から `posix_spawn` する形。
  `; echo $?` と `${PIPESTATUS}` は使わないと明記する。`git -C` も同じ欄で禁止する（Minus 9・10）
- [ ] **verify: 実バイナリでブラウザのウィンドウを開く検査は、開いたものを driver 自身が閉じるように作る**（申し送りに任せない）（Minus 11）
- [ ] **plan: PLAN に書く git 参照（`<rev>:<path>`）は `git cat-file -e` で実在を確かめてから書く**（Minus 12）
- [ ] **ループ: 対話セッションで進めたターンも turns.jsonl に 1 行残す**（phase / turn / 実施形態だけでよい）。
  いまは turn 21 の所要とコストが分からない（Interesting 3）
- [ ] **次のマイルストーンの候補（VERIFICATION round 4 §6 の未実測）**: 出力デバイス切り替え → exit 5、スリープ → exit 5 と m4a の再生可否、
  実 YouTube 広告の境界、E11 の `completion(ack=1)` の順序断言。discuss で扱うか決める
