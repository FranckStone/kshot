#!/bin/bash
# 编译并打包成 build/KShot.app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
KSHOT_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
KSHOT_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
KSHOT_MIN_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
# 显式写入实际 SDK 版本，避免原生控件按最低兼容系统的旧样式绘制。
swift build -c "$CONFIG" --sdk "$KSHOT_SDK_PATH" \
  -Xlinker -platform_version -Xlinker macos \
  -Xlinker "$KSHOT_MIN_VERSION" -Xlinker "$KSHOT_SDK_VERSION"
KSHOT_BIN_DIR="$(swift build -c "$CONFIG" --sdk "$KSHOT_SDK_PATH" --show-bin-path)"
KSHOT_LINKED_SDK="$(xcrun vtool -show-build "$KSHOT_BIN_DIR/KShot" | awk '$1 == "sdk" { print $2; exit }')"
if [ "$KSHOT_LINKED_SDK" != "$KSHOT_SDK_VERSION" ]; then
  echo "错误：构建产物 SDK 为 $KSHOT_LINKED_SDK，预期为 $KSHOT_SDK_VERSION" >&2
  exit 1
fi

APP="build/KShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$KSHOT_BIN_DIR/KShot" "$APP/Contents/MacOS/KShot"
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
