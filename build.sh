#!/bin/bash
# 编译并打包成 build/KShot.app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/KShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/KShot" "$APP/Contents/MacOS/KShot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# 优先使用稳定的开发证书签名，这样“屏幕录制”权限在重新编译后不会失效
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --identifier com.frank.kshot "$APP"
else
  codesign --force --sign - --identifier com.frank.kshot "$APP"
fi
echo "✅ 已生成 $APP"
