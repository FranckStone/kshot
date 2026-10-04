#!/bin/bash
# 编译、打包并启动
set -euo pipefail
cd "$(dirname "$0")"
./build.sh "${1:-release}"
pkill -x KShot 2>/dev/null || true
open build/KShot.app
