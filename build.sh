#!/usr/bin/env bash
# Build d-jsonpatch with LDC (the LLVM D compiler).
set -euo pipefail
cd "$(dirname "$0")"
export TC="$HOME/.local/toolchains"
export PATH="$TC/ldc/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
mkdir -p bin
ldc2 src/main.d -of=bin/d-jsonpatch -O
echo "built bin/d-jsonpatch"