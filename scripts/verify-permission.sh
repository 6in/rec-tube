#!/bin/bash
# システム音声の取得の許可が降りているかを 2 段で見る（PLAN T11 / 落とし穴 B5）。
#
#   段 1（開始できるか）: swift run rec-probe tap system 2
#       許可が無いとダイアログも出ないまま `AudioDeviceCreateIOProcIDWithBlock` が
#       無期限にブロックし、10 秒の watchdog（Tuning.tapStartTimeoutSeconds）で exit 8 になる
#       （T2 turn 4 / T9 turn 11 / T10 turn 12 の実測）。
#       **exit 4（全編ゼロ）と exit 8（許可なし）は読み分ける**: 段 1 の時点ではまだ何も鳴らして
#       いないので、exit 4 は「開始はできた（= 許可はある）が音が無かった」で**正常**。
#       許可なしと断定するのは exit 8 だけ。
#   段 2（全ゼロでないか）: **このスクリプトが自分でトーンを鳴らす**。
#       Tests/Fixtures/main.wav（440 Hz・12 秒。無ければ `swift run rec-probe tones Tests/Fixtures`
#       で作る）を afplay でバックグラウンド再生し続けながら
#       .build/debug/rec -o <scratch>/permission-<日時>.m4a を 2 秒だけ回して
#       kill -INT（期待 130）→ swift run rec-probe analyze <出力> --silence
#       （--silence は全ゼロなら exit 1 / 音が入っていれば exit 0）。
#       鳴っているはずの音が入らなければ tap が機能していないと言える（人が再生を用意しなくてよい）。
#
# timeout(1) には依存しない。上限は sleep + kill + wait で作る（verify-adtest.sh と同じ形）。
# 出力は .gsd-lite/logs/rec-cli-hardening/scratch/ 配下（日時スタンプ付きで使い回さない）。
#
# 人の操作が要る設定（tccutil / defaults write / sudo）はこのスクリプトからは実行しない。案内するだけ。
#
# 終了コード: 0 = 許可あり / 1 = 許可なし・その他の失敗
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools だけだと import Testing が無く、macOS 26 SDK も見えない。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCRATCH=".gsd-lite/logs/rec-cli-hardening/scratch"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$SCRATCH/permission-$STAMP.m4a"
PROBE_LOG="$SCRATCH/permission-$STAMP.probe.log"
REC_ERR="$SCRATCH/permission-$STAMP.rec-stderr.log"
ANALYZE_ERR="$SCRATCH/permission-$STAMP.analyze-stderr.log"
TIMEOUT_MARKER="$SCRATCH/permission-$STAMP.timeout"
TONE="Tests/Fixtures/main.wav"
REC_SECONDS=2
# SIGINT が効かなかったときの上限（段 1 を通っていれば 2 秒で止まるはずの録音）。
REC_LIMIT=20

mkdir -p "$SCRATCH"

# 鳴らしているトーンのループの PID。cleanup が落とす（録音が何秒かかっても鳴り続けるように
# afplay を while で回すので、ループ本体とその子の afplay の両方を止める）。
tone_pid=""

cleanup() {
	if [ -n "$tone_pid" ]; then
		kill -TERM "$tone_pid" 2>/dev/null || true
		wait "$tone_pid" 2>/dev/null || true
		# ループが起動済みの afplay は親を殺しても残るので名指しで落とす。
		pkill -f "afplay $TONE" 2>/dev/null || true
		tone_pid=""
	fi
	printf "\n== 使ったファイル ==\n  録音          : %s\n  probe ログ    : %s\n  rec stderr    : %s\n  analyze stderr: %s\n" \
		"$OUT" "$PROBE_LOG" "$REC_ERR" "$ANALYZE_ERR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

# 許可が無いときの案内。許可は rec 自身ではなく「責任プロセス」= ターミナルアプリに付く。
permission_help() {
	cat >&2 <<-'EOS'

		システム音声の取得の許可が降りていません。次の順で人が操作してください。
		  1. システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの録音 を開く
		  2. このスクリプトを起動したターミナルアプリ（iTerm2 / Terminal.app など）を許可する
		     許可は rec 自身ではなく「責任プロセス」= ターミナルアプリに付くので、rec の欄は出ない。
		     tmux / screen 越しだと許可を求めるダイアログが出ないことがある。その場合は
		     tmux の外で 1 回実行し、tmux kill-server の後にターミナルアプリを起動し直す。
		  3. ターミナルアプリ自体を再起動する（許可はホストアプリの再起動後に反映される）
		  4. もう一度 scripts/verify-permission.sh を実行する

		許可の状態をやり直したいとき（人が実行する。このスクリプトからは実行しない）:
		  tccutil reset ScreenCapture
	EOS
}

echo "== build =="
swift build

echo "== 段 1: 録音を開始できるか（swift run rec-probe tap system 2）=="
probe_code=0
swift run rec-probe tap system 2 2>&1 | tee "$PROBE_LOG" || probe_code=$?
echo "  rec-probe tap exit: $probe_code"

if [ "$probe_code" -eq 8 ]; then
	echo "FAIL: tap を作れない・開始できない（exit 8）。10 秒の watchdog に当たった形 =" >&2
	echo "      システム音声の取得の許可が降りていない。" >&2
	permission_help
	exit 1
fi
if [ "$probe_code" -eq 4 ]; then
	# 段 1 ではまだトーンを鳴らしていないので、全編ゼロは想定どおり。
	# 「tap を作って回せた」= 許可はある、という段 1 の目的は達している（音の有無は段 2 で見る）。
	echo "  段 1 OK: tap を作れて 2 秒回せた（exit 4 = この時点では無音。音の有無は段 2 で見る）"
elif [ "$probe_code" -ne 0 ]; then
	fail "rec-probe tap が exit $probe_code で終わった（1 = 引数不正。ログ: $PROBE_LOG）"
else
	echo "  段 1 OK: tap を作れて音が入った"
fi

echo "== 段 2: 全ゼロでないか（トーンを鳴らしながら $REC_SECONDS 秒録って analyze --silence）=="
echo "  out: $OUT"

# 素材を用意する（*.wav は .gitignore 済みなので clone 直後には無い）。
if [ ! -f "$TONE" ]; then
	echo "  $TONE が無いので作る（swift run rec-probe tones Tests/Fixtures）"
	swift run rec-probe tones Tests/Fixtures || fail "rec-probe tones が失敗した（$TONE を作れない）"
fi
[ -f "$TONE" ] || fail "rec-probe tones の後も $TONE が無い"

# 録音が何秒かかってもトーンが途切れないように afplay を回し続ける（main.wav は 12 秒）。
echo "  トーン: afplay $TONE をバックグラウンドで繰り返し再生する"
(
	while :; do
		afplay "$TONE" || exit 0
	done
) &
tone_pid=$!
# 最初の afplay が実際に鳴り出すまで少し待つ（録音の先頭が無音にならないように）。
sleep 1
# afplay 自体が動かない環境（出力デバイスが無いなど）だとループが即終わる。
# これを見ずに進むと「鳴らしていたのに全ゼロ」と誤診するので、ここで切り分ける。
if ! kill -0 "$tone_pid" 2>/dev/null; then
	tone_pid=""
	fail "afplay $TONE が鳴らせなかった（出力デバイス・音量を確かめる）。段 2 の判定ができない"
fi

.build/debug/rec -o "$OUT" 2>"$REC_ERR" &
rec_pid=$!

# 見張り: SIGINT が効かなかったときに REC_LIMIT 秒で TERM を送り、印をファイルで残す。
(
	sleep "$REC_LIMIT"
	if kill -TERM "$rec_pid" 2>/dev/null; then
		: >"$TIMEOUT_MARKER"
	fi
) &
killer_pid=$!

sleep "$REC_SECONDS"
kill -INT "$rec_pid" 2>/dev/null || true

rec_code=0
wait "$rec_pid" || rec_code=$?

# 見張りを片付ける（まだ sleep 中なら殺す。すでに終わっていれば何もしない）。
kill -TERM "$killer_pid" 2>/dev/null || true
wait "$killer_pid" 2>/dev/null || true

# 録音が終わったらトーンも止める（analyze の間に鳴らし続ける必要はない）。
if [ -n "$tone_pid" ]; then
	kill -TERM "$tone_pid" 2>/dev/null || true
	wait "$tone_pid" 2>/dev/null || true
	pkill -f "afplay $TONE" 2>/dev/null || true
	tone_pid=""
fi

echo "  rec exit: $rec_code（期待 130 = 128 + SIGINT）"
if [ -f "$TIMEOUT_MARKER" ]; then
	echo "  （SIGINT が効かず $REC_LIMIT 秒で SIGTERM に落とした）"
fi

if [ "$rec_code" -eq 8 ]; then
	echo "FAIL: rec が exit 8（.coreAudio）で終わった。段 1 は通ったのに tap が作れていない。" >&2
	permission_help
	exit 1
fi
if [ "$rec_code" -ne 130 ]; then
	fail "rec の終了コードが $rec_code（期待 130。stderr: $REC_ERR）"
fi
if [ ! -f "$OUT" ]; then
	fail "rec が出力ファイルを作らなかった: $OUT"
fi

analyze_code=0
swift run rec-probe analyze "$OUT" --silence 2>"$ANALYZE_ERR" || analyze_code=$?
echo "  analyze --silence exit: $analyze_code（0 = 音が入っている / 1 = 全ゼロ）"

if [ "$analyze_code" -eq 1 ]; then
	echo "FAIL: 440 Hz のトーン（$TONE）を鳴らしていたのに録音が全ゼロだった（$OUT）。" >&2
	echo "      鳴っている音が tap に入らないので、許可が降りていないか tap が機能していない。" >&2
	echo "      ファイルが読めなかった場合も exit 1 になる（stderr: $ANALYZE_ERR）。" >&2
	echo "      出力デバイスの音量が 0 / ミュートでないかも確かめる（afplay は既定の出力に鳴らす）。" >&2
	permission_help
	exit 1
fi
if [ "$analyze_code" -ne 0 ]; then
	fail "analyze が exit $analyze_code（stderr: $ANALYZE_ERR）"
fi

echo "== result =="
echo "  段 1（録音を開始できる）  : OK"
echo "  段 2（鳴らした音が入る）  : OK"
echo "許可あり"
