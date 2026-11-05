#!/bin/bash
# `rec --url` の実機検証（PLAN T11 / 決めた事項 #13）。
#
#   使い方: scripts/verify-youtube.sh [URL]
#   既定 URL = https://www.youtube.com/watch?v=jNQXAC9IVRw（19 秒。YouTube 最初の動画）
#
# `-o` は付けない。出力名が「タイトル由来」になることを確かめるため
# （-o なしの保存先はカレントディレクトリなので、scratch に cd してから rec を呼ぶ）。
#
# 期待:
#   - rec が exit 0 で完走する
#   - scratch に新しい .m4a がちょうど 1 つ増える
#   - その名前が既定名 rec-<日時>.m4a の形**ではない**（= タイトルから作られている）
#   - afinfo の estimated duration が 0 より大きい（比較は awk で行う）
#
# 上限は 180 秒（超えたら kill -TERM）。timeout(1) には依存しない。
# 出力は .gsd-lite/logs/rec-cli-hardening/scratch/ 配下（日時スタンプ付きで使い回さない）。
#
# 前提（人の操作が必要。このスクリプトからは設定しない）:
#   1. システム音声の取得の許可
#      システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 で
#      ターミナルアプリ（iTerm2 / Terminal.app など）を許可し、ターミナルアプリを再起動する。
#      許可が無いとダイアログも出ないまま録音開始が 10 秒ブロックして exit 8 になる。
#   2. Chrome のオートメーション許可
#      システム設定 > プライバシーとセキュリティ > オートメーション でターミナルアプリに
#      Google Chrome の操作を許可する（無いと AppleScript エラー -1743 → exit 2）。
#   3. Chrome の「表示 > 開発/管理 > Apple Events からの JavaScript を許可」（無いと exit 2）
#
# 終了コード: 0 = 期待どおり / rec が非ゼロならその値をそのまま返す / 1 = 検査で落ちた
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools だけだと import Testing が無く、macOS 26 SDK も見えない。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

REPO="$PWD"
SCRATCH="$REPO/.gsd-lite/logs/rec-cli-hardening/scratch"
STAMP="$(date +%Y%m%d-%H%M%S)"
URL="${1:-https://www.youtube.com/watch?v=jNQXAC9IVRw}"
REC_ERR="$SCRATCH/youtube-$STAMP.rec-stderr.log"
BEFORE="$SCRATCH/youtube-$STAMP.before.txt"
AFTER="$SCRATCH/youtube-$STAMP.after.txt"
NEW_LIST="$SCRATCH/youtube-$STAMP.new.txt"
TIMEOUT_MARKER="$SCRATCH/youtube-$STAMP.timeout"
REC_LIMIT=180

mkdir -p "$SCRATCH"

trap 'printf "\n== 使ったファイル ==\n  scratch     : %s\n  rec stderr  : %s\n  増えた .m4a : %s\n" "$SCRATCH" "$REC_ERR" "$NEW_LIST"' EXIT

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

cat <<-'EOS'
	== 前提（人の操作が必要。このスクリプトからは設定しない）==
	  1. システム音声の取得の許可（画面とシステムオーディオの録音でターミナルアプリを許可 → 再起動）
	  2. Chrome のオートメーション許可（システム設定 > プライバシーとセキュリティ > オートメーション）
	  3. Chrome の「表示 > 開発/管理 > Apple Events からの JavaScript を許可」
EOS

echo "== build =="
swift build

if [ ! -x .build/debug/rec ]; then
	fail ".build/debug/rec が無い（swift build が成功していない）"
fi

# 録音前の .m4a 一覧（増えた 1 本を後で comm で取り出す）。
ls -1 "$SCRATCH" | grep '\.m4a$' | sort >"$BEFORE" || true

echo "== rec（-o なし / カレント = scratch）=="
echo "  url : $URL"
echo "  cwd : $SCRATCH"
echo "  上限: $REC_LIMIT 秒（超えたら SIGTERM）"

cd "$SCRATCH"

"$REPO/.build/debug/rec" --url "$URL" 2>"$REC_ERR" &
rec_pid=$!

# 見張り: REC_LIMIT 秒たってもまだ動いていたら TERM を送り、印をファイルで残す。
(
	sleep "$REC_LIMIT"
	if kill -TERM "$rec_pid" 2>/dev/null; then
		: >"$TIMEOUT_MARKER"
	fi
) &
killer_pid=$!

rec_code=0
wait "$rec_pid" || rec_code=$?

# 見張りを片付ける（まだ sleep 中なら殺す。すでに終わっていれば何もしない）。
kill -TERM "$killer_pid" 2>/dev/null || true
wait "$killer_pid" 2>/dev/null || true

cd "$REPO"

echo "  rec exit: ${rec_code}（期待 0）"
if [ -f "$TIMEOUT_MARKER" ]; then
	echo "  （$REC_LIMIT 秒で打ち切った）"
fi

ls -1 "$SCRATCH" | grep '\.m4a$' | sort >"$AFTER" || true
comm -13 "$BEFORE" "$AFTER" >"$NEW_LIST"
new_count="$(wc -l <"$NEW_LIST" | tr -d '[:space:]')"

if [ "$rec_code" -ne 0 ]; then
	echo "FAIL: rec が exit $rec_code で終わった（期待 0。stderr: ${REC_ERR}）" >&2
	echo "      2 = Chrome 制御不可 / 3 = ライブ配信 / 6 = ページ喪失 / 8 = tap を作れない（許可なしの疑い）" >&2
	echo "      増えた .m4a: $new_count 個（一覧: ${NEW_LIST}）" >&2
	exit "$rec_code"
fi

echo "== 出力の検査 =="
echo "  増えた .m4a: $new_count 個（期待 1。一覧: ${NEW_LIST}）"
if [ "$new_count" -ne 1 ]; then
	fail "scratch に増えた .m4a が $new_count 個（期待 1）"
fi

name="$(head -n 1 "$NEW_LIST")"
echo "  出力名: $name"

# 既定名は rec-yyyyMMdd-HHmmss（連番は -2 / -3 …）。この形だとタイトルが取れていない。
if [[ "$name" =~ ^rec-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.m4a$ ]]; then
	fail "出力名が既定名（rec-<日時>.m4a）のまま: ${name}（= タイトルが取れていない）"
fi

dur="$(afinfo "$SCRATCH/$name" 2>/dev/null | awk '/estimated duration/ { print $3; exit }')" || dur=""
echo "  duration: ${dur:-(不明)} 秒（期待 > 0）"
if [ -z "$dur" ]; then
	fail "afinfo が estimated duration を返さなかった: $SCRATCH/$name"
fi
if ! awk -v d="$dur" 'BEGIN { exit (d > 0) ? 0 : 1 }'; then
	fail "duration が $dur 秒（期待 > 0）: $SCRATCH/$name"
fi

echo "== result =="
echo "  url      : $URL"
echo "  出力名   : ${name}（既定名 rec-<日時>.m4a の形ではない）"
echo "  rec exit : $rec_code"
echo "  duration : $dur 秒"
echo "ALL OK"
