#!/bin/bash
# クリーンな状態からの最終判定。実機録音は含めない（それは scripts/verify-*.sh）。
#   1. .build を消す
#   2. debug / release の両方を build
#   3. 両バイナリに __TEXT,__info_plist があり NSAudioCaptureUsageDescription を含む
#   4. swift test
#   5. 文書とコードの追従チェック（PLAN「追従先チェックリスト」）
#   6. CLI の最低限の終了コード
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

echo "== clean =="
rm -rf .build

echo "== build (debug) =="
swift build

echo "== build (release) =="
swift build -c release

echo "== Info.plist 埋め込み =="
for bin in .build/debug/rec .build/release/rec; do
	otool -s __TEXT __info_plist "$bin" |
		grep -q 'Contents of (__TEXT,__info_plist) section' ||
		fail "$bin に __TEXT,__info_plist セクションが無い"
	otool -P "$bin" |
		grep -q 'NSAudioCaptureUsageDescription' ||
		fail "$bin の Info.plist に NSAudioCaptureUsageDescription が無い"
done

echo "== tests =="
swift test

echo "== 追従チェック =="
# 移動元の行番号参照（rec.swift:NN）を新しいコードや README に持ち込まない。
if rg -n 'rec\.swift:[0-9]' Sources README.md; then
	fail "rec.swift:NN の参照が残っている（履歴参照は git show main:rec.swift を使う）"
fi
# TODO(T11): 下の検査を有効にする（対象ファイルがまだ無いので T1 では入れない）
#   - ExitCode の case 数 == README「終了コード」表の行数
#   - CLI オプション（--ad-guard 等）が CLI.swift と README の両方にある
#   - README に許可 3 種（NSAudioCaptureUsageDescription / オートメーション / Apple Events）の記述
#   - ls scripts/verify-*.sh の本数 == README「検証」節の一覧行数
#   - Tuning. 経由以外の調整値のハードコードが無い

echo "== cli =="
.build/debug/rec --list >/dev/null || fail "--list が exit 0 にならない"
code=0
.build/debug/rec --bogus 2>/dev/null || code=$?
[ "$code" -eq 1 ] || fail "--bogus の終了コードが $code（期待 1）"

echo "ALL OK"
