#!/bin/bash
# SIGINT(130) / SIGTERM(143) / SIGHUP(129) の 3 本を順に回す（PLAN T11 / 落とし穴 P2）。
#
# 各本の手順:
#   1. .build/debug/rec -o <scratch>/signals-<シグナル名>-<日時>.m4a をバックグラウンドで起動
#   2. 3 秒待って kill -<SIG> <pid>、wait で終了コードを取る
#   3. 終了コードが期待値（128 + シグナル番号 = 130 / 143 / 129）であること
#   4. afinfo の estimated duration が 2 秒以上であること
#      （小数の比較は awk で行う。bash の [ は小数を比較できない）
#
# 3 本すべて回してから結果をまとめる（どこが壊れているか 1 回で分かるように）。
# timeout(1) には依存しない。上限は sleep + kill + wait で作る。
# 出力は .gsd-lite/logs/rec-cli-hardening/scratch/ 配下（日時スタンプ付きで使い回さない）。
#
# 許可が無い場合: 録音開始が 10 秒ブロックするので 3 秒時点の signal が効かず、
# 10 秒の watchdog（Tuning.tapStartTimeoutSeconds）で exit 8 になる（T9 turn 11 の実測）。
# 終了コード 8 を見たら許可の案内を出す。
#
# 終了コード: 0 = 3 本すべて期待どおり / 1 = 1 本以上が期待外れ
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools だけだと import Testing が無く、macOS 26 SDK も見えない。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCRATCH=".gsd-lite/logs/rec-cli-hardening/scratch"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILURES="$SCRATCH/signals-$STAMP.failures.txt"
REC_SECONDS=3
MIN_SECONDS=2
# signal がまったく効かなかったときの上限。ここでは SIGTERM ではなく SIGKILL を送る
# （TERM を送ると終了コードが 143 になって「SIGINT の検査結果」と区別できなくなる）。
REC_LIMIT=30
PERMISSION_SUSPECTED=0

mkdir -p "$SCRATCH"
: >"$FAILURES"

trap 'printf "\n== 使ったファイル ==\n  scratch   : %s\n  失敗の一覧: %s\n" "$SCRATCH" "$FAILURES"' EXIT

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

note_fail() {
	printf '  SIG%s: %s\n' "$1" "$2" >>"$FAILURES"
}

# 許可が無いときの案内（終了コード 8 を見たときだけ出す）。
permission_help() {
	cat >&2 <<-'EOS'

		終了コード 8（.coreAudio）が出ています。システム音声の取得の許可が降りていない可能性が高い。
		許可が無いと録音開始（AudioDeviceCreateIOProcIDWithBlock）が無期限にブロックし、
		3 秒時点の signal は同じセッションキューの処理待ちになるため効きません。
		10 秒の watchdog（Tuning.tapStartTimeoutSeconds）が先に落ちて exit 8 になります（T9 の実測）。

		  1. システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 を開く
		  2. このスクリプトを起動したターミナルアプリ（iTerm2 / Terminal.app など）を許可する
		     許可は rec 自身ではなく「責任プロセス」= ターミナルアプリに付く。
		  3. ターミナルアプリ自体を再起動する
		  4. scripts/verify-permission.sh で許可を確かめてから、もう一度これを回す

		やり直したいとき（人が実行する。このスクリプトからは実行しない）:
		  tccutil reset ScreenCapture
	EOS
}

# $1 = シグナル名（INT / TERM / HUP）, $2 = 期待する終了コード
run_one() {
	sig="$1"
	expected="$2"
	out="$SCRATCH/signals-$sig-$STAMP.m4a"
	err="$SCRATCH/signals-$sig-$STAMP.rec-stderr.log"
	marker="$SCRATCH/signals-$sig-$STAMP.timeout"

	echo "== SIG${sig}（期待 ${expected}）=="
	echo "  out: $out"

	.build/debug/rec -o "$out" 2>"$err" &
	rec_pid=$!

	# 見張り: REC_LIMIT 秒たってもまだ動いていたら KILL を送り、印をファイルで残す。
	(
		sleep "$REC_LIMIT"
		if kill -KILL "$rec_pid" 2>/dev/null; then
			: >"$marker"
		fi
	) &
	killer_pid=$!

	sleep "$REC_SECONDS"
	kill -"$sig" "$rec_pid" 2>/dev/null || true

	code=0
	wait "$rec_pid" || code=$?

	# 見張りを片付ける（まだ sleep 中なら殺す。すでに終わっていれば何もしない）。
	kill -TERM "$killer_pid" 2>/dev/null || true
	wait "$killer_pid" 2>/dev/null || true

	echo "  exit: ${code}（期待 ${expected}）"
	if [ -f "$marker" ]; then
		echo "  （SIG$sig が効かず $REC_LIMIT 秒で SIGKILL に落とした）"
		note_fail "$sig" "$REC_LIMIT 秒で SIGKILL に落とした（SIG$sig が効かなかった）"
	fi
	if [ "$code" -ne "$expected" ]; then
		note_fail "$sig" "終了コードが ${code}（期待 ${expected}）。stderr: $err"
		if [ "$code" -eq 8 ]; then
			PERMISSION_SUSPECTED=1
		fi
	fi

	if [ ! -f "$out" ]; then
		echo "  duration: (出力ファイルが無い)"
		note_fail "$sig" "出力ファイルが無い: $out"
		return 0
	fi

	dur="$(afinfo "$out" 2>/dev/null | awk '/estimated duration/ { print $3; exit }')" || dur=""
	echo "  duration: ${dur:-(不明)} 秒（期待 >= $MIN_SECONDS 秒）"
	if [ -z "$dur" ]; then
		note_fail "$sig" "afinfo が estimated duration を返さなかった: $out"
	elif ! awk -v d="$dur" -v min="$MIN_SECONDS" 'BEGIN { exit (d >= min) ? 0 : 1 }'; then
		note_fail "$sig" "duration が $dur 秒（期待 >= $MIN_SECONDS 秒）: $out"
	fi
}

echo "== build =="
swift build

if [ ! -x .build/debug/rec ]; then
	fail ".build/debug/rec が無い（swift build が成功していない）"
fi

run_one INT 130
run_one TERM 143
run_one HUP 129

echo "== result =="
if [ -s "$FAILURES" ]; then
	echo "期待どおりでなかった本:" >&2
	cat "$FAILURES" >&2
	if [ "$PERMISSION_SUSPECTED" -eq 1 ]; then
		permission_help
	fi
	exit 1
fi
echo "  SIGINT=130 / SIGTERM=143 / SIGHUP=129 すべて期待どおり、duration も >= $MIN_SECONDS 秒"
echo "ALL OK"
