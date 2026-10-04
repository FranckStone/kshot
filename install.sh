#!/bin/bash
# 编译打包并安装到 /Applications，然后启动
set -euo pipefail
cd "$(dirname "$0")"
./build.sh release
pkill -x KShot 2>/dev/null || true
rm -rf /Applications/KShot.app
cp -R build/KShot.app /Applications/KShot.app
open /Applications/KShot.app
echo "✅ 已安装并启动 /Applications/KShot.app"
