#!/bin/bash
# swift test のラッパ。引数はそのまま swift test に渡す（例: scripts/test.sh --filter DelayLine）。
set -euo pipefail
cd "$(dirname "$0")/.."

# import Testing は Xcode のツールチェインにしか無い（CLT では解決できない）。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

exec swift test "$@"
