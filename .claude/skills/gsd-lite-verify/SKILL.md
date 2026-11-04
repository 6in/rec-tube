---
name: gsd-lite-verify
description: gsd-lite の検証フェーズ（無人ループから Claude Code / Codex / OpenCode で起動）。マイルストーンの diff 全体をレビュー + セキュリティチェックし、合格ならベースブランチへ自動マージする。
disable-model-invocation: true
---

# gsd-lite-verify — レビュー + セキュリティ + マージ（無人ターン）

これは無人ターン。マイルストーンの成果全体を検証し、合格なら自動マージまで行う。

## 作業場所の解決（最初に 1 回。全エンジン共通）

最初の Bash で **`gsd-lite-loop.sh --where` を 1 回だけ実行**し、出力を読む:

```
mode=control            # in-repo | control
milestone_dir=.gsd-lite/milestones/<slug>   # 以下「$MS」と書く場所。in-repo 形では .gsd-lite
state=.gsd-lite/milestones/<slug>/state.json
target=work/<name>      # 以下「$TARGET」と書く場所。in-repo 形では .
slug=<slug>
```

**以降のコマンドでは、この出力の値をそのままリテラルで書く**（例: `cat .gsd-lite/milestones/todo-mvp/PLAN.md`、
`git -C work/todo-cli status`）。本文の `$MS` / `$TARGET` は「ここに --where の値を書く」という印であり、
シェル変数として使わない。Bash ツールはコール間でシェル変数を保持せず、環境によってはコマンド書き換えの
フックが `$VAR` を空にするため、`MS=...; ...` と変数に入れてから使う書き方は失敗する。

- `$MS` = マイルストーンディレクトリ。state.json と成果物（REQUIREMENTS / DECISIONS / RESEARCH / PLAN /
  PROGRESS / VERIFICATION / BLOCKED）はここ。従来の in-repo 形では `.gsd-lite/` そのもの。
  制御リポジトリ（gsd-control）形では `.gsd-lite/milestones/<slug>/`（slug は今いる制御ブランチ `gsd-lite/<slug>`）
- `$TARGET` = コードを書く対象リポジトリ。`.` なら今いるリポジトリ（従来どおり）。`work/<name>` なら
  gsd-control 形で、**コードの読み書き・テスト・コミット・ブランチ・マージ・push は `git -C <target>` /
  `cd <target>` で対象側に**、**`$MS/` の成果物と state.json はこのリポジトリ（制御側）に**コミットする。
  対象側の `CLAUDE.md` / `AGENTS.md` / README は自動では読み込まれないので、`<target>/CLAUDE.md` 等が
  あれば最初に読んで規約に従う。`<target>` の中身を制御側に `git add` しない（gitignore 済み）
- `.gsd-lite/logs/` と `.gsd-lite/reflect/` はどちらの形でも共通の場所（マイルストーンをまたいで蓄積）。
  一時ファイル（プローブ用スクリプト等）が必要なら `/tmp` ではなく `.gsd-lite/logs/<slug>/scratch/` に置く
  （`/tmp` への書き込みは allowlist 外で権限拒否になる。logs/ は gitignore 済み）
- 環境メモ: lean-ctx 等の MCP ツールが未接続でも通常のツールで進めてよい。未接続であることは
  PROGRESS の「想定外」に書かなくてよい（毎ターン同じ行が並ぶだけで振り返りの材料にならない）

## 手順

1. `$MS/state.json` から `branch.base` / `verify_round` / `verify_round_max` を
   読み、`git -C $TARGET diff <branch.base>...HEAD` でマイルストーン全体の差分（対象リポジトリのコード）を
   対象にする。`$TARGET/CLAUDE.md` / `AGENTS.md` があれば規約もレビュー観点に含める
2. `REQUIREMENTS.md` の受け入れ基準・PLAN.md の完了基準と突き合わせて検証する:
   - **コードレビュー**: バグ / 設計の歪み / テストの妥当性（テストが完了基準を
     実際に検証しているか）/ 要件の取りこぼし
   - **セキュリティチェック**: 入力検証 / 認可 / 秘密情報のハードコード /
     インジェクション / 依存の危険な使い方
   - **round 1 で堅牢性の格子を一括プローブし、round 2 以降は回帰確認だけにする**: round 1 で
     入力経路（argv の各引数 / 環境変数 / ファイル内容 / 標準入力）× 出力経路（stdout / stderr の fd:
     パイプ閉鎖・fd 閉鎖・満杯・読み取り専用・エンコード不能）× 例外の親クラス（`OSError` / `ValueError` /
     `RecursionError` / `None` オブジェクト）の格子を立て、該当する面を全部その回で試す。round 2 以降は
     「round 1 の格子の再確認 + 前ラウンドの修正差分の回帰」だけを行い、新しいクラスの探索はしない
     （探索の深さが毎ラウンド 1 段ずつ増えると、指摘が小出しになって修正ラウンドと BLOCKED を生む）
   - **堅牢性の指摘は要件と区別する**: REQUIREMENTS / DECISIONS に堅牢性の受け入れ基準（例「どの入力・出力
     状態でもトレースバックを出さず、既存データを失わない」）が**ない**場合、受け入れ基準を満たしている成果に
     対する堅牢性の指摘は、データ損失や誤動作を伴うものだけを差し戻し、それ以外は VERIFICATION.md の
     「残留リスク」に書いて合格にする（verify が事実上の要件追加をしない）
   - **入力クラスの境界は一括で洗う**（同型の指摘をラウンドをまたいで小出しにしない）:
     1 つの入力経路（引数 / 環境変数 / データファイル / 標準入力）に問題を見つけたら、
     同じ経路の**クラス全体**を同じラウンドで試す。例: 制御文字なら C0 / DEL / C1 /
     孤立サロゲート / 書式文字（U+2028 等）をまとめて、例外漏れなら `RecursionError` /
     `UnicodeError` / `ValueError` / `OSError` / 巨大入力をまとめて。修正タスクの完了基準も
     「C0 を拒否する」ではなく「制御文字クラス全体を拒否し、どの入力でもトレースバックを
     出さない」のようにクラス単位で書く。ラウンド 2 以降で前ラウンドと同型の指摘を出す場合は、
     VERIFICATION.md に「なぜ前ラウンドで拾えなかったか」を 1 行書く
   - **文書の主張**: 文書が実態より広く言い切っていないか（「すべて」「全段流した」など）、
     冒頭の要約と本文が一致しているか、件数・本数・識別子の古い値が残っていないか
     （PLAN の「追従先チェックリスト」の照合を再実行する）
   - **期待値の変更**: impl が PROGRESS に列挙した「既存テストの期待値の変更」が意図どおりか
   - PLAN.md の検証コマンドでテストがすべて green なことも再確認する
     （PLAN に最終判定コマンドがあれば、クリーンな状態からそれを回す）
   - **並列レビュー**（任意）: `state.json` の `subagents` が `auto`（未指定も `auto`）で
     実行エンジンがサブエージェントを使える場合、「コードレビュー」と「セキュリティチェック」を
     別々のサブエージェントに**読み取り専用**で並行させ（対象 diff の範囲・受け入れ基準・観点を
     渡す）、報告を親が統合して判定する。サブエージェントはファイルを変更しない。
     テスト実行・マージ・push・state 更新は親だけが行う。`off` や非対応エンジンでは自分で順に行う
3. 結果で分岐:

   **合格の場合**
   - `$MS/VERIFICATION.md` に検証結果（観点・確認したこと・残留リスク）を書いてコミット
   - `git -C $TARGET remote get-url origin` で**対象リポジトリのリモートの有無を判定**して分岐
     （以下の git / gh / glab はすべて対象側で実行する: `git -C $TARGET ...`、`cd $TARGET && gh ...`）:

   **(a) リモートなし（ローカルのみ）→ ベースブランチへ自動マージ**
   - `git checkout <branch.base>` → `git merge --no-ff gsd-lite/<slug>`
   - 衝突したら `git merge --abort` → `git checkout gsd-lite/<slug>` でブランチに戻り、
     衝突内容を BLOCKED.md に書いて BLOCKED にする（人間が解決）
   - マージ成功: ブランチは削除せず残す。**完了遷移**（下記）へ

   **(b) リモートあり → push + MR/PR 作成（ローカルマージはしない）**
   - **修正ラウンド**（state の `fix_round` ≥ 1）で MR/PR が既にある場合は、新規作成せず
     `git push origin gsd-lite/<slug>` だけ行う（既存 MR/PR に修正コミットが載る）。
     MR/PR の URL は前回の VERIFICATION.md / PROGRESS.md から引き継いで記録する
   - origin の URL からホストを判別し、ホスト別の手順で作成する:
     - **github.com**: `git push -u origin gsd-lite/<slug>` →
       `gh pr create --base <branch.base> --title "<milestone の要約>" --body "..."`
       （`gh` が必須。不在・未認証なら push まで行って BLOCKED）
     - **gitlab を含む**: `glab` が使えるなら `git push -u origin gsd-lite/<slug>` →
       `glab mr create --target-branch <branch.base> --title "..." --description "..."`。
       **`glab` が不在なら push オプションでフォールバック**（GitLab サーバー側機能。
       追加ツール・API トークン不要）:
       `git push -u origin gsd-lite/<slug> -o merge_request.create
        -o merge_request.target=<branch.base> -o merge_request.title="<要約>"`
       — push 出力に MR の URL が表示されるのでそれを記録する
   - MR/PR の本文には受け入れ基準の達成状況と VERIFICATION.md の要約を書き、
     末尾に実際の実行エンジン名（Claude Code / Codex / OpenCode）を記載する。
     gsd-control 形では成果物が対象 MR に含まれないので、制御リポジトリの `$MS/` の場所も本文に書く
   - 作成成功: MR/PR の URL を VERIFICATION.md と PROGRESS.md に記録。
     ブランチはそのまま。**完了遷移**（下記）へ（マージは人間 / CI）
   - **push の成否を必ず確認する**（MR 用 push・最終 state コミット後の再 push とも）。
     失敗したら 1 回だけリトライし、それでも失敗なら DONE のまま終わらせず、
     `next_command: "BLOCKED"` / `phase: "blocked"` に更新して失敗内容を BLOCKED.md に
     書き**追加コミット**して終了する（ローカルが DONE 相当でも、リモートに最終 state が
     届いていない状態を成功にしない）
   - push はできたが MR/PR 作成に失敗（CLI 不在・未認証・ホスト不明など）:
     push 済みであることと失敗理由・手動作成の手順を BLOCKED.md に書いて BLOCKED にする
   - push 自体が失敗: 理由を BLOCKED.md に書いて BLOCKED にする

   **完了遷移（(a)(b) 共通）**
   - state の `reflect` が `false` でなければ（未指定は `true`）`phase: "reflect"` /
     `next_command: "/gsd-lite-reflect"` にする。次のターンが記録に基づく振り返りを
     `.gsd-lite/reflect/` に書いてから DONE にする
   - `reflect: false` なら従来通り `phase: "done"` / `next_command: "DONE"`

   **指摘ありの場合**
   - 修正タスクを `$MS/PLAN.md` の Tasks 末尾に `- [ ] F1: ...` 形式で追記
     （完了基準・対象ファイル付き）。**期待結果は 1 つの表にまとめる**（条件 → exit / stdout / stderr を
     1 行ずつ）。完了基準の本文とテストの記述はその表を参照するだけにし、exit コード等を 2 か所に書かない
     （2 か所に書くと矛盾して impl が判断を迫られる）。例外処理は親クラスで書く（plan と同じ規則）
   - F タスクの粒度は impl と同じく「1 ターンで完結する範囲で同種をまとめる」:
     文書だけの軽微な指摘（字句・件数・古い識別子など）は 1 つの F タスクにまとめる
     （指摘 1 件ごとに F タスクを分けるとその数だけターンが増える）
   - `verify_round` を +1 する
   - `verify_round <= verify_round_max` なら `phase: "impl"` /
     `next_command: "/gsd-lite-impl"`（差し戻し）
   - 上限超過なら指摘一覧を BLOCKED.md に書いて BLOCKED にする（無限修正ループ防止）

## ターン終了の共通手順（必須・この順で）

1. `$MS/PROGRESS.md` に追記（**固定項目**。reflect フェーズの材料になるので、想定外と
   やり直しは正直に書く。なければ「なし」「0 回」と書く。`<N>` は**このターンで +1 した後の
   `state.turn`**（= ループが `turn N [...]` と表示する番号、research が turn 1）。
   やり直しの原因が次のターンでも起こり得るなら、**同じ内容を「次への注意」にも書く**）:
   ```markdown
   ## turn <N> — verify — <判定 / 指摘数 / マージ・MR 結果>
   - やったこと: <1〜2 行>
   - 想定外: なし | <想定と違ったこと、ハマったこと>
   - やり直し: 0 回 | <N 回（何を・なぜ）>
   - 次への注意: <次のターンへの申し送り>
   ```
2. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**時刻は `date -Iseconds` を実行した出力をそのまま書く**（見積もりや丸めた値を書かない。ループはコミット時刻より先の値を警告する）。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. 成果物・PROGRESS.md・state.json を**まとめて git commit**（`gsd-lite(verify): <要約>`。
   in-repo 形: (a) ローカルマージ後はベースブランチ上でコミット。(b) リモート運用ではマイルストーン
   ブランチ上でコミットして再 push する — MR に最終 state が含まれる。
   **push 後もマイルストーンブランチに残ったまま終了すること**。checkout でベースに
   移ると作業ツリーの state.json がベースの古い内容に置き換わり、ループが誤動作する。
   ベースへの復帰は次のマイルストーンの discuss 冒頭が行う。
   gsd-control 形: state と成果物は制御リポジトリ（今いる場所、制御ブランチ `gsd-lite/<slug>`）に
   コミットするだけ。対象側の再 push は不要で、(b) では対象をマイルストーンブランチに残す）。
   **state 更新 → commit の順序が重要**: 逆にすると最終 state が未コミットで残り、
   git からの復元時に完了済みフェーズを再実行してしまう
4. 判断に迷ったら推測しない: `$MS/BLOCKED.md` に状況・質問・選択肢+推奨を書き、
   `next_command: "BLOCKED"` / `phase: "blocked"`（turn は +1）にしたうえで
   同様にコミットして終了する

## 無人ターンのシェルの作法（承認待ちで止まらないために）

無人ターンは承認プロンプトに応答できない。allowlist に当たらない形のコマンドは止まり、
ターンが無進捗で終わる。次の形を守る:

- 1 回の Bash 呼び出しに 1 コマンドだけ書く。`;` / `&&` の連結、サブシェル、`$(...)`、
  先頭の変数代入（`FOO=1 make ...`）を使わない（パイプ `|` は両側が allowlist にあるときだけ）。
  環境変数が要るなら `--env-file` など引数で渡す
- コミットメッセージは一時ファイルに書いて `git commit -F <file>` で渡す（`-m "$(...)"` は使わない）
- 一時ファイルは `.gsd-lite/logs/<slug>/scratch/` に置き、名前に turn 番号を入れる
  （例 `turn-012-commit-msg.txt`。前のターンや前のマイルストーンのファイルを使い回さない）。
  `mktemp -d` で作ったディレクトリはそのターン内で消す
- 作業ディレクトリの外へは書かない（証跡は `.gsd-lite/` 配下に置く）
