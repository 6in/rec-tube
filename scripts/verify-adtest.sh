#!/bin/bash
# adtest.html（広告の割り込みを file:// で再現するローカル素材）を実機で録って判定する。
#   1. swift build
#   2. swift run rec-probe tones Tests/Fixtures      … main.wav / ad.wav を作る
#   3. .build/debug/rec --url file://.../adtest.html?v=local1 -o <scratch>/adtest-<日時>.m4a
#      （180 秒で諦めて kill。timeout(1) に依存せず sleep + kill + wait で制御する）
#   4. swift run rec-probe analyze <出力> --main 440 --ad 1000 --expect-main 12
#   5. verdict の JSON と各段の終了コードを出す
# 終了コード: 0 = 全部通った / 2 = Chrome が自動再生を拒否した（rec が 6 かつ stderr に playErr）/
#             1 = それ以外の失敗
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools だけだと import Testing が無く、macOS 26 SDK も見えない。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

REPO="$PWD"
SCRATCH=".gsd-lite/logs/rec-cli-hardening/scratch"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$SCRATCH/adtest-$STAMP.m4a"
REC_ERR="$SCRATCH/adtest-$STAMP.rec-stderr.log"
ANALYZE_ERR="$SCRATCH/adtest-$STAMP.analyze-stderr.log"
TIMEOUT_MARKER="$SCRATCH/adtest-$STAMP.timeout"
URL="file://$REPO/Tests/Fixtures/adtest.html?v=local1"
REC_LIMIT=180

mkdir -p "$SCRATCH"

trap 'printf "\n== 使ったファイル ==\n  録音          : %s\n  rec stderr    : %s\n  analyze stderr: %s\n" "$OUT" "$REC_ERR" "$ANALYZE_ERR"' EXIT

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

echo "== build =="
swift build

echo "== tones =="
swift run rec-probe tones Tests/Fixtures || fail "rec-probe tones が失敗した"

echo "== rec =="
echo "  url: $URL"
echo "  out: $OUT"
echo "  上限: $REC_LIMIT 秒（超えたら SIGTERM）"

.build/debug/rec --url "$URL" -o "$OUT" 2>"$REC_ERR" &
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

echo "  rec exit: $rec_code"
if [ -f "$TIMEOUT_MARKER" ]; then
	echo "  （$REC_LIMIT 秒で打ち切った）"
fi

if [ "$rec_code" -eq 6 ] && grep -q 'playErr' "$REC_ERR"; then
	cat >&2 <<-'EOS'
		FAIL: Chrome が自動再生を拒否した（rec exit 6 / stderr に playErr）。
		file:// のページには Chrome が音声つき自動再生を許さないことがある。次の 2 段で回避する:
		  1. ローカル HTTP で配る（http:// なら自動再生の扱いが変わる）
		       python3 -m http.server 8765 --directory Tests/Fixtures
		       .build/debug/rec --url "http://localhost:8765/adtest.html?v=local1" -o <出力>
		  2. それでも拒否されるなら Chrome の自動再生の許可を人が入れる
		       AutoplayAllowlist ポリシー（または chrome://settings/content/sound）に
		       対象のオリジンを足してから、もう一度このスクリプトを回す。
	EOS
	exit 2
fi

if [ "$rec_code" -ne 0 ]; then
	fail "rec が exit $rec_code で終わった（stderr: $REC_ERR）"
fi
if [ ! -f "$OUT" ]; then
	fail "rec が出力ファイルを作らなかった: $OUT"
fi

echo "== analyze =="
analyze_code=0
verdict="$(swift run rec-probe analyze "$OUT" --main 440 --ad 1000 --expect-main 12 2>"$ANALYZE_ERR")" || analyze_code=$?

echo "== result =="
echo "  verdict: ${verdict:-(なし)}"
echo "  rec exit     : $rec_code"
echo "  analyze exit : $analyze_code"
echo "  期待: adWindows == 0 かつ |mainSeconds - 12| < 1.0"

if [ "$analyze_code" -ne 0 ]; then
	fail "analyze が exit $analyze_code（stderr: $ANALYZE_ERR）"
fi

echo "ALL OK"
