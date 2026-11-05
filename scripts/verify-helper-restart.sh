#!/bin/bash
# 落とし穴 L1(c) の検証（PLAN T11）: Chrome の音声サービスを録音中に落としても録り続けられるか。
#
#   使い方: scripts/verify-helper-restart.sh [URL]
#   既定 URL = https://www.youtube.com/watch?v=jNQXAC9IVRw（19 秒。verify-youtube.sh と同じ）
#
# 手順:
#   1. .build/debug/rec --url <URL> -o <scratch>/helper-restart-<日時>.m4a を起動
#   2. 10 秒後に pkill -f 'Google Chrome Helper.*audio\.mojom\.AudioService'
#      （Chrome の音声サービスだけ再起動させる）
#      1 件も殺せなかった（pkill が exit 1）場合は「音声サービスが見つからない = 再生していない」
#      として失敗にする
#      **パターンは「Google Chrome Helper の、かつ audio.mojom.AudioService」まで絞る**:
#      裸の `audio.mojom.AudioService` は `-f`（コマンドラインの全文照合）なので、この文字列を
#      コマンドラインに含む無関係なプロセス（別のブラウザのユーティリティ、ログを引数に持つ
#      ツールなど）にも当たりうる。Chrome の音声ヘルパー以外を落とさないように縛る。
#   3. 上限 180 秒で kill -TERM。完走（exit 0）を期待
#   4. swift run rec-probe analyze <出力> --main 440 --ad 1000 の verdict（JSON）を取り、
#      silentSeconds < totalSeconds × 0.25 であることを確かめる
#
# **判定基準 0.25 の根拠**: PLAN T11 の『後半にも可聴窓がある』を機械で見るための代理指標。
# PLAN に比率の数値は無いので、この 0.25 はこのスクリプトの補い。
# 「無音の窓（dBFS < Tuning.silenceDBFS）の合計がファイル全体の 1/4 未満」なら、
# 音声サービスを落とした後（= 録音の後半）が丸ごと無音になってはいないと言える。
# 既定の寸法（10 秒で落として 19 秒の動画を録る）では落とした後の方が長いので代理として足りる。
#
# timeout(1) には依存しない。上限は sleep + kill + wait で作る。
# JSON からの値の取り出しも awk で行う（jq に依存しない）。
# 出力は .gsd-lite/logs/rec-cli-hardening/scratch/ 配下（日時スタンプ付きで使い回さない）。
#
# 前提（人の操作が必要。このスクリプトからは設定しない）:
#   1. システム音声の取得の許可（画面とシステムオーディオの録音でターミナルアプリを許可 → 再起動）
#   2. Chrome のオートメーション許可（システム設定 > プライバシーとセキュリティ > オートメーション）
#   3. Chrome の「表示 > 開発/管理 > Apple Events からの JavaScript を許可」
#
# 終了コード: 0 = 期待どおり / rec が非ゼロならその値をそのまま返す / 1 = 検査で落ちた
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools だけだと import Testing が無く、macOS 26 SDK も見えない。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCRATCH=".gsd-lite/logs/rec-cli-hardening/scratch"
STAMP="$(date +%Y%m%d-%H%M%S)"
URL="${1:-https://www.youtube.com/watch?v=jNQXAC9IVRw}"
OUT="$SCRATCH/helper-restart-$STAMP.m4a"
REC_ERR="$SCRATCH/helper-restart-$STAMP.rec-stderr.log"
ANALYZE_ERR="$SCRATCH/helper-restart-$STAMP.analyze-stderr.log"
TIMEOUT_MARKER="$SCRATCH/helper-restart-$STAMP.timeout"
KILL_AFTER=10
REC_LIMIT=180
# 代理指標の上限（上のコメントの根拠）。
SILENT_RATIO_MAX=0.25

mkdir -p "$SCRATCH"

trap 'printf "\n== 使ったファイル ==\n  録音          : %s\n  rec stderr    : %s\n  analyze stderr: %s\n" "$OUT" "$REC_ERR" "$ANALYZE_ERR"' EXIT

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# JSON 1 行から "<key>": の数値を取り出す（jq に依存しない）。
json_number() {
	awk -v j="$1" -v key="$2" 'BEGIN {
		n = index(j, "\"" key "\":")
		if (n == 0) { exit 1 }
		rest = substr(j, n + length(key) + 3)
		sub(/[,}].*$/, "", rest)
		print rest
		exit 0
	}'
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

echo "== rec =="
echo "  url : $URL"
echo "  out : $OUT"
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

sleep "$KILL_AFTER"

echo "== pkill -f 'Google Chrome Helper.*audio\.mojom\.AudioService'（$KILL_AFTER 秒後）=="
pkill_code=0
pkill -f 'Google Chrome Helper.*audio\.mojom\.AudioService' || pkill_code=$?
echo "  pkill exit: ${pkill_code}（0 = 1 件以上殺した / 1 = 一致なし）"

if [ "$pkill_code" -ne 0 ]; then
	# 後片付け（録音と見張りを落としてから失敗にする）。
	kill -TERM "$rec_pid" 2>/dev/null || true
	wait "$rec_pid" 2>/dev/null || true
	kill -TERM "$killer_pid" 2>/dev/null || true
	wait "$killer_pid" 2>/dev/null || true
	fail "Chrome の音声サービス（Google Chrome Helper … audio.mojom.AudioService）が見つからない（pkill exit ${pkill_code}）= Chrome が音を鳴らしていない。再生が始まっているか、許可 3 種が揃っているかを確かめる（stderr: ${REC_ERR}）"
fi

rec_code=0
wait "$rec_pid" || rec_code=$?

# 見張りを片付ける（まだ sleep 中なら殺す。すでに終わっていれば何もしない）。
kill -TERM "$killer_pid" 2>/dev/null || true
wait "$killer_pid" 2>/dev/null || true

echo "  rec exit: ${rec_code}（期待 0）"
if [ -f "$TIMEOUT_MARKER" ]; then
	echo "  （$REC_LIMIT 秒で打ち切った）"
fi

if [ "$rec_code" -ne 0 ]; then
	echo "FAIL: rec が exit $rec_code で終わった（期待 0。stderr: ${REC_ERR}）" >&2
	echo "      5 = 中断（tap 故障・デバイス変更など）/ 6 = ページ喪失 / 8 = tap を作れない" >&2
	exit "$rec_code"
fi
if [ ! -f "$OUT" ]; then
	fail "rec が出力ファイルを作らなかった: $OUT"
fi

echo "== analyze =="
analyze_code=0
verdict="$(swift run rec-probe analyze "$OUT" --main 440 --ad 1000 2>"$ANALYZE_ERR")" || analyze_code=$?
echo "  verdict: ${verdict:-(なし)}"
echo "  analyze exit: $analyze_code"
if [ "$analyze_code" -ne 0 ]; then
	fail "analyze が exit ${analyze_code}（stderr: ${ANALYZE_ERR}）"
fi

silent="$(json_number "$verdict" silentSeconds)" || fail "verdict から silentSeconds を取れない: $verdict"
total="$(json_number "$verdict" totalSeconds)" || fail "verdict から totalSeconds を取れない: $verdict"

echo "== result =="
echo "  url           : $URL"
echo "  rec exit      : $rec_code"
echo "  silentSeconds : $silent"
echo "  totalSeconds  : $total"
echo "  判定          : silentSeconds < totalSeconds × $SILENT_RATIO_MAX"

if ! awk -v s="$silent" -v t="$total" -v r="$SILENT_RATIO_MAX" \
	'BEGIN { exit (t > 0 && s < t * r) ? 0 : 1 }'; then
	fail "無音が多すぎる（silentSeconds=$silent totalSeconds=$total 上限比 ${SILENT_RATIO_MAX}）= 音声サービスを落とした後が無音になっている疑い"
fi

echo "ALL OK"
