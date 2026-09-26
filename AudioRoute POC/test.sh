#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
TEST_DIR="${TMPDIR:-/tmp}/audioroute-poc-tests"
mkdir -p "$TEST_DIR"
xcrun clang -O2 -Wall -Wextra -Wno-unused-parameter Source/Render.c Source/RenderTests.c -framework CoreAudio -o "$TEST_DIR/render-tests"
"$TEST_DIR/render-tests"
