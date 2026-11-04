---
name: gsd-lite-impl
description: gsd-lite の実装フェーズ（無人ループから Claude Code / Codex / OpenCode で起動）。PLAN.md の先頭の未完了タスクを 1 つだけ実装し、テストを通してコミットする。
disable-model-invocation: true
---

# gsd-lite-impl — タスクを 1 つだけ進める（無人ターン）

これは無人ターン。**1 ターン = 1 タスク**が鉄則。複数タスクをまとめてやらない
（コンテキストが溢れて品質が落ちる。次のタスクは次のターンの自分がやる）。

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

0. **前のターンの残りを確かめる**: `git -C $TARGET status`（gsd-control 形では制御側の `git status` も）で
   作業ツリーが dirty なら、まず中身を確かめる。先頭の未完了タスクの書きかけなら検証してから
   続きとして取り込み、それ以外（無関係な変更・由来が分からない変更）なら手を付けずに BLOCKED にする
1. `$MS/PLAN.md` の**先頭の未完了タスク（`- [ ]`）を 1 つだけ**選ぶ。
   `$MS/PROGRESS.md` の直近の申し送りを読む。
   未完了タスクが 1 つもなければ実装せず、`phase: "verify"` /
   `next_command: "/gsd-lite-verify"` にして共通手順で終了する
2. タスクの完了基準・対象ファイルに従って `$TARGET` 配下で実装する。必要な範囲のコードだけ読む
   （`$TARGET/CLAUDE.md` / `AGENTS.md` があれば規約に従う）
   - **PLAN と実物が食い違ったら**（引数名・件数・期待するエラーコードなど）: 要件・決定に
     反しない範囲なら**実物と実測を正とし**、PLAN.md の該当箇所を直して PROGRESS に
     `PLAN 訂正: <旧> → <新>（根拠）` と残す。要件・決定に触れる食い違いなら BLOCKED にする
   - PLAN の「追従先チェックリスト」に該当する変更をしたら、全項目を確かめる
   - **サブエージェントによる並行実装**（任意）: `state.json` の `subagents` が `auto`
     （未指定も `auto` 扱い）で、実行エンジンがサブエージェント（Claude Code の Agent ツール、
     OpenCode の task ツール等）を使え、タスクの `並列サブ作業` が 2 つ以上あるときは、
     サブ作業ごとにサブエージェントを起動して並行実装する。守ること:
     - 各サブエージェントに渡す: 担当サブ作業の内容と完了基準 / 対象ファイル / **触ってはいけない
       ファイル**（他のサブ作業の対象）/ PLAN.md のメモ / PROGRESS.md の直近の申し送り /
       検証コマンド。対象ファイルは互いに重ねない
     - 依頼文には、担当サブ作業が満たすべき仕様（PLAN のコマンド仕様表・API 契約の該当行）を
       **「必ず満たす 1 行の断言」として抜き書きする**（例: 「`clear` は完了済み**だけ**を消す。未完了は残る」）。
       テストを別のサブエージェントに仕様表から独立に書かせる構成は仕様違反の検出に効くので維持する
     - 依頼文に**必ず次の固定文言を含める**: 「PLAN.md のメモにある API 契約・完了基準に無い挙動
       （型の継承、フォールバック、環境変数の優先順位などの"保険"）は実装しない。必要だと
       思ったら実装せず、報告に『契約外の提案』として書く。契約に無いテストケースも同様に
       報告だけにする」（並列実装で契約外の追加が統合時の衝突を起こすのを防ぐ）
     - サブエージェントは **git commit・state.json・PLAN.md・PROGRESS.md に触らない**。
       実装と担当範囲の単体確認だけ行い、変更したファイルと懸念点を報告して終わる
     - 全員の報告後、親（このターン）が統合して手順 3 の検証コマンドを実行し、手順 4 以降を行う。
       結果が矛盾・失敗していれば親が修正する（立て直し回数は手順 3 と合算で 2 回まで）
     - `subagents` が `off`、サブ作業が 1 つ以下、またはエンジンがサブエージェントに対応して
       いない（Codex exec 等）場合は、従来通り自分で順に実装する
3. PLAN.md の**検証コマンド**を `$TARGET` のルートで実行し（`cd $TARGET && ...`）、green を確認する
   （PLAN に環境の初期化コマンドがあれば先に走らせる）
   - **既存テストの期待値を変えたら**、その箇所と理由をすべて PROGRESS に列挙する
     （verify はこの一覧で、期待値の変更が意図どおりかを確かめる）
   - 通らない場合、このターン内で最大 2 回まで立て直しを試みる。それでも
     だめなら変更を stash せずそのままコミットはせず、BLOCKED にする
     （何をどう試したかを BLOCKED.md に書く）
4. コードを対象側にコミットし（`git -C $TARGET add ... && git -C $TARGET commit -m "gsd-lite(impl): <タスクID> <要約>"`）、
   `$MS/PLAN.md` のチェックボックスを `- [x]` にする（in-repo 形ではこの変更も同じコミットに含める。
   gsd-control 形では PLAN.md は制御側にあるので、共通手順 3 の制御側コミットに含める）
5. まだ未完了タスクが残っていれば `next_command: "/gsd-lite-impl"`（自分自身・
   phase は "impl" のまま）、全タスク完了なら `phase: "verify"` /
   `next_command: "/gsd-lite-verify"` にする

## ターン終了の共通手順（必須・この順で）

1. `$MS/PROGRESS.md` に追記（**固定項目**。reflect フェーズの材料になるので、想定外と
   やり直しは正直に書く。なければ「なし」「0 回」と書く。`<N>` は**このターンで +1 した後の
   `state.turn`**（= ループが `turn N [...]` と表示する番号、research が turn 1）。
   やり直しの原因が次のターンでも起こり得るなら、**同じ内容を「次への注意」にも書く**）:
   ```markdown
   ## turn <N> — impl — <タスクID> <要約>
   - やったこと: <1〜2 行>
   - 想定外: なし | <想定と違ったこと、ハマったこと>
   - やり直し: 0 回 | <N 回（何を・なぜ）>
   - 次への注意: <次のターンへの申し送り>
   ```
2. `state.json` を更新: `next_command` と `phase` を上記のとおり、`turn` を +1、
   `updated_at` を現在時刻（ISO 8601）に。**時刻は `date -Iseconds` を実行した出力をそのまま書く**（見積もりや丸めた値を書かない。ループはコミット時刻より先の値を警告する）。**turn の +1 を忘れるとループが
   リトライ扱いにするので必ず行う**
3. PROGRESS.md・state.json（gsd-control 形では PLAN.md も）をこのリポジトリにコミットする
   （タスク本体は手順 4 で対象側にコミット済みなので追加コミットでよい。
   `gsd-lite(impl): <タスクID>完了の申し送りと state 更新`）。
   **state 更新 → commit の順序が重要**: 逆にすると最終 state が未コミットで残り、
   git からの復元時に完了済みタスクを再実行してしまう
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
