#!/bin/bash
# m4a を mp3 に変換する（ffmpeg / libmp3lame）。元の m4a は残す。
#
#   使い方: scripts/m4a-to-mp3.sh [-q 品質] [-d 出力先] <m4a ファイルかディレクトリ>...
#     -q 品質   libmp3lame の -q:a（0 が最高、9 が最低。既定 2 = 190 kbps 前後の可変ビットレート）
#     -d 出力先 mp3 を置くディレクトリ（既定: 元の m4a と同じ場所）
#   ディレクトリを渡すと、その直下の *.m4a をすべて変換する（サブディレクトリは見ない）。
#
# 同名の mp3 があれば上書きせず、-2 / -3 … を付ける（rec と同じ規則）。
# 終了コード: 0 = すべて成功 / 1 = 失敗あり / 2 = 引数エラー・ffmpeg が無い
set -uo pipefail

QUALITY=2
OUT_DIR=""

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "q:d:h" opt; do
	case "$opt" in
	q) QUALITY="$OPTARG" ;;
	d) OUT_DIR="$OPTARG" ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ "$#" -ge 1 ] || usage

case "$QUALITY" in
[0-9]) ;;
*) echo "error: -q は 0〜9: ${QUALITY}" >&2; exit 2 ;;
esac

FFMPEG=$(command -v ffmpeg || true)
[ -n "$FFMPEG" ] || { [ -x /opt/homebrew/bin/ffmpeg ] && FFMPEG=/opt/homebrew/bin/ffmpeg; }
[ -n "$FFMPEG" ] || { [ -x /usr/local/bin/ffmpeg ] && FFMPEG=/usr/local/bin/ffmpeg; }
[ -n "$FFMPEG" ] || { echo "error: ffmpeg がありません。brew install ffmpeg で入れてください。" >&2; exit 2; }

if [ -n "$OUT_DIR" ]; then
	mkdir -p "$OUT_DIR" || { echo "error: 出力先を作れません: ${OUT_DIR}" >&2; exit 2; }
fi

# 上書きしない出力先を決める（name.mp3 → name-2.mp3 → …）。
unique_path() {
	local base="$1" n=2 path="$1.mp3"
	while [ -e "$path" ]; do
		path="${base}-${n}.mp3"
		n=$((n + 1))
	done
	printf '%s' "$path"
}

ok=0
failed=0

convert() {
	local src="$1" dir name dst
	dir=$(dirname "$src")
	[ -n "$OUT_DIR" ] && dir="$OUT_DIR"
	name=$(basename "$src")
	name="${name%.*}"
	dst=$(unique_path "${dir}/${name}")

	echo "変換: ${src}"
	if "$FFMPEG" -hide_banner -nostdin -loglevel error -n -i "$src" \
		-map_metadata 0 -codec:a libmp3lame -q:a "$QUALITY" "$dst"; then
		echo "  → ${dst}"
		ok=$((ok + 1))
	else
		echo "  失敗: ${src}" >&2
		rm -f "$dst"
		failed=$((failed + 1))
	fi
}

for arg in "$@"; do
	if [ -d "$arg" ]; then
		found=0
		for f in "$arg"/*.m4a "$arg"/*.M4A; do
			[ -f "$f" ] || continue
			found=1
			convert "$f"
		done
		[ "$found" = 1 ] || echo "m4a がありません: ${arg}" >&2
	elif [ -f "$arg" ]; then
		convert "$arg"
	else
		echo "見つかりません: ${arg}" >&2
		failed=$((failed + 1))
	fi
done

echo "完了: 成功 ${ok} 件 / 失敗 ${failed} 件"
[ "$failed" -eq 0 ]
