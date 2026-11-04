#!/bin/bash
# 落とし穴 L6 / L7 の検証（PLAN T11）: 遅延線とポーリングでメモリが増え続けないこと。
#
#   使い方: scripts/verify-longrun.sh [分]
#   既定は 10 分。1 分時点と N 分時点の 2 点を比べるので N は 1 より大きい値であること。
#
# 手順:
#   1. .build/debug/rec -o <scratch>/longrun-<日時>.m4a を起動（システム全体録音）
#   2. 1 分時点と N 分時点で ps -o rss= -p <pid> を取り、差が 10 MB（10240 KB）未満であること
#   3. N 分たったら kill -INT（exit 130 を期待）
#   4. afinfo の estimated duration が N×60 − 5 秒以上であること
#
# 比較は awk で行う（bash の [ は小数を比較できない）。
# timeout(1) には依存しない。上限は sleep + kill + wait で作る。
# 出力は .gsd-lite/logs/rec-cli-hardening/scratch/ 配下（日時スタンプ付きで使い回さない）。
#
# 前提（人の操作が必要。このスクリプトからは設定しない）: システム音声の取得の許可。
# 許可が無いと録音開始が 10 秒ブロックして exit 8 になり、1 分時点で rec が生きていない。
# 先に scripts/verify-permission.sh で確かめること。
# **スリープに入ると rec は停止して保存する**（exit 5）。長時間回す間はスリープさせないこと
# （pmset / caffeinate はこのスクリプトからは実行しない。人が設定する）。
#
# 終了コード: 0 = 期待どおり / 1 = 検査で落ちた
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools だけだと import Testing が無く、macOS 26 SDK も見えない。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCRATCH=".gsd-lite/logs/rec-cli-hardening/scratch"
STAMP="$(date +%Y%m%d-%H%M%S)"
MINUTES="${1:-10}"
OUT="$SCRATCH/longrun-$STAMP.m4a"
REC_ERR="$SCRATCH/longrun-$STAMP.rec-stderr.log"
TIMEOUT_MARKER="$SCRATCH/longrun-$STAMP.timeout"
FIRST_AT=60
RSS_LIMIT_KB=10240

mkdir -p "$SCRATCH"

trap 'printf "\n== 使ったファイル ==\n  録音      : %s\n  rec stderr: %s\n" "$OUT" "$REC_ERR"' EXIT

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# 数値で、かつ 1 より大きいこと（2 点目が 1 分時点より後にならないと比較にならない）。
if ! awk -v m="$MINUTES" 'BEGIN { exit (m + 0 == m && m > 1) ? 0 : 1 }'; then
	fail "分数は 1 より大きい数で指定してください（渡された値: $MINUTES）。1 分時点と N 分時点の 2 点を比べるので N > 1 が必要"
fi

SECOND_AT="$(awk -v m="$MINUTES" 'BEGIN { printf "%.0f", m * 60 - 60 }')"
MIN_DURATION="$(awk -v m="$MINUTES" 'BEGIN { printf "%.3f", m * 60 - 5 }')"
# SIGINT が効かなかったときの上限（N 分 + 60 秒）。TERM ではなく KILL を送る
# （TERM だと終了コードが 143 になって「SIGINT の検査結果」と区別できなくなる）。
REC_LIMIT="$(awk -v m="$MINUTES" 'BEGIN { printf "%.0f", m * 60 + 60 }')"

echo "== build =="
swift build

if [ ! -x .build/debug/rec ]; then
	fail ".build/debug/rec が無い（swift build が成功していない）"
fi

echo "== rec（システム全体録音 $MINUTES 分）=="
echo "  out : $OUT"
echo "  上限: $REC_LIMIT 秒（超えたら SIGKILL）"

.build/debug/rec -o "$OUT" 2>"$REC_ERR" &
rec_pid=$!

# 見張り: REC_LIMIT 秒たってもまだ動いていたら KILL を送り、印をファイルで残す。
(
	sleep "$REC_LIMIT"
	if kill -KILL "$rec_pid" 2>/dev/null; then
		: >"$TIMEOUT_MARKER"
	fi
) &
killer_pid=$!

echo "== 1 分時点の RSS =="
sleep "$FIRST_AT"
rss1="$(ps -o rss= -p "$rec_pid" | tr -d '[:space:]')" || rss1=""
if [ -z "$rss1" ]; then
	kill -TERM "$killer_pid" 2>/dev/null || true
	wait "$killer_pid" 2>/dev/null || true
	fail "1 分時点で rec が生きていない（許可が無いと 10 秒で exit 8 になる。stderr: $REC_ERR）"
fi
echo "  rss1 = $rss1 KB"

echo "== $MINUTES 分時点の RSS（あと $SECOND_AT 秒）=="
sleep "$SECOND_AT"
rss2="$(ps -o rss= -p "$rec_pid" | tr -d '[:space:]')" || rss2=""
if [ -z "$rss2" ]; then
	kill -TERM "$killer_pid" 2>/dev/null || true
	wait "$killer_pid" 2>/dev/null || true
	fail "$MINUTES 分時点で rec が生きていない（途中で止まった。stderr: $REC_ERR）"
fi
echo "  rss2 = $rss2 KB"

kill -INT "$rec_pid" 2>/dev/null || true

rec_code=0
wait "$rec_pid" || rec_code=$?

# 見張りを片付ける（まだ sleep 中なら殺す。すでに終わっていれば何もしない）。
kill -TERM "$killer_pid" 2>/dev/null || true
wait "$killer_pid" 2>/dev/null || true

if [ -f "$TIMEOUT_MARKER" ]; then
	echo "  （SIGINT が効かず $REC_LIMIT 秒で SIGKILL に落とした）"
fi

diff_kb="$(awk -v a="$rss1" -v b="$rss2" 'BEGIN { print b - a }')"
dur="$(afinfo "$OUT" 2>/dev/null | awk '/estimated duration/ { print $3; exit }')" || dur=""

echo "== result =="
echo "  1 分時点の RSS   : $rss1 KB"
echo "  $MINUTES 分時点の RSS : $rss2 KB"
echo "  差               : $diff_kb KB（上限 $RSS_LIMIT_KB KB = 10 MB 未満）"
echo "  rec exit         : $rec_code（期待 130 = 128 + SIGINT）"
echo "  duration         : ${dur:-(不明)} 秒（期待 >= $MIN_DURATION 秒 = $MINUTES×60 − 5）"

if ! awk -v d="$diff_kb" -v lim="$RSS_LIMIT_KB" 'BEGIN { exit (d < lim) ? 0 : 1 }'; then
	fail "RSS が $diff_kb KB 増えた（上限 $RSS_LIMIT_KB KB 未満）"
fi
if [ "$rec_code" -ne 130 ]; then
	fail "rec の終了コードが $rec_code（期待 130。stderr: $REC_ERR）"
fi
if [ ! -f "$OUT" ]; then
	fail "rec が出力ファイルを作らなかった: $OUT"
fi
if [ -z "$dur" ]; then
	fail "afinfo が estimated duration を返さなかった: $OUT"
fi
if ! awk -v d="$dur" -v min="$MIN_DURATION" 'BEGIN { exit (d >= min) ? 0 : 1 }'; then
	fail "duration が $dur 秒（期待 >= $MIN_DURATION 秒）: $OUT"
fi

echo "ALL OK"
