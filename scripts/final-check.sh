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
	fail "rec.swift:NN の参照が残っている（履歴参照は git show 45301d8:rec.swift を使う）"
fi
# ExitCode の case 数と README「終了コード」表の行数が一致する（**数は直書きしない**）。
exit_cases="$(rg -c '^    case .* = [0-9]+$' Sources/RecCore/ExitCode.swift || echo 0)"
readme_codes="$(rg -c '^\| [0-9]' README.md || echo 0)"
echo "  ExitCode の case: $exit_cases 個 / README「終了コード」表: $readme_codes 行"
# 正規表現が壊れて両方 0 になったときに「一致」で通ってしまわないようにする。
[ "$exit_cases" -gt 0 ] || fail "ExitCode の case を 1 つも拾えていない（検査の正規表現が壊れている）"
[ "$exit_cases" -eq "$readme_codes" ] ||
	fail "ExitCode の case 数 ($exit_cases) と README「終了コード」表の行数 ($readme_codes) が違う"

# CLI オプション（--ad-guard）が CLI.swift と README の両方にある。
rg -q -- '--ad-guard' Sources/RecCore/CLI.swift || fail "Sources/RecCore/CLI.swift に --ad-guard が無い"
rg -q -- '--ad-guard' README.md || fail "README.md に --ad-guard が無い（使い方の節）"

# README に許可 3 種（システム音声 / オートメーション / Apple Events からの JavaScript）の記述がある。
readme_perms="$(rg -c 'NSAudioCaptureUsageDescription|オートメーション|Apple Events' README.md || echo 0)"
echo "  README の許可 3 種の記述: $readme_perms 行（3 以上）"
[ "$readme_perms" -ge 3 ] || fail "README の許可の記述が $readme_perms 行しかない（3 以上が必要）"

# 検証スクリプトの本数と README「検証」節の一覧行数が一致する（**数は直書きしない**）。
verify_count="$(ls -1 scripts/verify-*.sh 2>/dev/null | wc -l | tr -d '[:space:]')" || verify_count=0
readme_verify="$(rg -c '^- `scripts/verify-' README.md || echo 0)"
echo "  scripts/verify-*.sh: $verify_count 本 / README の一覧: $readme_verify 行"
[ "$verify_count" -gt 0 ] || fail "scripts/verify-*.sh が 1 本も無い"
[ "$verify_count" -eq "$readme_verify" ] ||
	fail "検証スクリプトの本数 ($verify_count) と README の一覧行数 ($readme_verify) が違う"

# 調整値（秒数・dBFS・比率）が Sources/RecCore/Tuning.swift の外に直書きされていない。
#
# 検査するリテラルは、実際に rg を回して「今は Tuning.swift にしか無い」と確認できたものだけ:
#   -60.0     … Tuning.silenceDBFS
#   -50.0     … Tuning.toneAudibleDBFS
#   0.7       … Tuning.adResumeRewindSeconds
#   3.0       … Tuning.toneAdDominanceRatio
#   ad-showing… Tuning.adShowingSelector
# 1.2（Tuning.ssaiDurationRatio）は外した: SessionPolicy.swift のコメントに
# 「#8 の条件は `dur > len × 1.2`」として出てくる。rg はコメントと数値リテラルを区別できないので
# 入れると永久に落ちる（値そのものは Tuning.ssaiDurationRatio を経由している）。
#
# 数値は前後を縛る（`(^|[^0-9.])…([^0-9]|$)`）。裸の `0\.7` / `3\.0` だと `10.7` や `13.0`、
# `0.75` のような別の数の一部にも当たって偽陽性になる（F3 turn 17 で縛りを足した）。
#
# Sources/rec-probe は対象外: 440 / 1000 Hz・12 / 4 秒は検証素材の寸法で、
# Tuning（製品コード RecCore の調整値置き場）の管轄外（PLAN T10 の訂正欄）。
# 除外グロブは **パス全体**に当てる: `-g '!rec-probe/**'` では Sources/rec-probe/ を除外できない
# （スラッシュを含むグロブはパス先頭からの照合になる。実測。スラッシュの無い `!Tuning.swift` は
# ベース名に当たるのでこれは効く）。
TUNING_LITERALS=(
	-e '(^|[^0-9.])-60\.0([^0-9]|$)'
	-e '(^|[^0-9.])-50\.0([^0-9]|$)'
	-e '(^|[^0-9.])0\.7([^0-9]|$)'
	-e '(^|[^0-9.])3\.0([^0-9]|$)'
	-e 'ad-showing'
)
# 先に「正規表現が生きている」ことを本家（Tuning.swift）で確かめる。
# これが無いと、正規表現が壊れて 0 件になったときに「違反なし」として通ってしまう。
literal_self_test="$(rg -c "${TUNING_LITERALS[@]}" Sources/RecCore/Tuning.swift || echo 0)"
echo "  調整値リテラルの自己テスト: Tuning.swift で $literal_self_test 行（5 以上）"
[ "$literal_self_test" -ge 5 ] ||
	fail "調整値リテラルの正規表現が Tuning.swift で $literal_self_test 行しか拾えない（検査が壊れている）"
if rg -n "${TUNING_LITERALS[@]}" Sources \
	-g '!Tuning.swift' -g '!Sources/rec-probe/**'; then
	fail "調整値が Tuning.swift の外に直書きされている（Tuning.<名前> を経由すること）"
fi

# 人向けの stderr の出口は Sources/RecCore/Console.swift の writeStderr(_:) だけ（F2）。
# FileHandle.standardError.write(_:) は fd 2 が閉じていると Objective-C 例外で SIGABRT になる。
if rg -n 'standardError\.write' Sources; then
	fail "FileHandle.standardError.write が残っている（RecCore.writeStderr を使う。F2 の E19）"
fi

# 単一ファイル版 rec.swift はリポジトリ直下から移動済み（T1 の git mv）。
if ls rec.swift >/dev/null 2>&1; then
	fail "リポジトリ直下に rec.swift がある（T1 で Sources へ移動したはず）"
fi

echo "== cli =="
.build/debug/rec --list >/dev/null || fail "--list が exit 0 にならない"
code=0
.build/debug/rec --bogus 2>/dev/null || code=$?
[ "$code" -eq 1 ] || fail "--bogus の終了コードが ${code}（期待 1）"

echo "ALL OK"
