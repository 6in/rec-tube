#!/bin/bash
# swift build のラッパ。引数はそのまま swift build に渡す（例: scripts/build.sh -c release）。
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools だけだと import Testing が無く、macOS 26 SDK も見えない。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

exec swift build "$@"
