#!/bin/bash
# 准备安装包和签名更新源；不执行远程发布。
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release
KSHOT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
KSHOT_RELEASE="build/releases/$KSHOT_VERSION"
KSHOT_NAME="KShot-$KSHOT_VERSION-macos-arm64"
KSHOT_TOOLS=".build/artifacts/sparkle/Sparkle/bin"
KSHOT_PUBLIC_KEY="$("$KSHOT_TOOLS/generate_keys" --account com.frank.kshot -p)"
KSHOT_EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
if [ "$KSHOT_PUBLIC_KEY" != "$KSHOT_EXPECTED_KEY" ]; then
  echo "错误：钥匙串中的更新签名公钥与应用不一致，不能发布。" >&2
  exit 1
fi
# 只对新目录生成 feed，避免版本号相同时重用旧签名。
if [ -e "$KSHOT_RELEASE" ]; then
  echo "错误：$KSHOT_RELEASE 已存在，请提升版本号或将旧产物移走。" >&2
  exit 1
fi
mkdir -p "$KSHOT_RELEASE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent build/KShot.app "$KSHOT_RELEASE/$KSHOT_NAME.zip"
cp "docs/releases/$KSHOT_VERSION.md" "$KSHOT_RELEASE/$KSHOT_NAME.md"
"$KSHOT_TOOLS/generate_appcast" --account com.frank.kshot \
  --download-url-prefix "https://github.com/FranckStone/kshot/releases/download/v$KSHOT_VERSION/" \
  --embed-release-notes --maximum-deltas 0 "$KSHOT_RELEASE"

KSHOT_DMG_STAGE="$(mktemp -d /tmp/kshot-dmg.XXXXXX)"
trap 'rm -rf "$KSHOT_DMG_STAGE"' EXIT
/usr/bin/ditto build/KShot.app "$KSHOT_DMG_STAGE/KShot.app"
ln -s /Applications "$KSHOT_DMG_STAGE/Applications"
hdiutil create -volname "KShot $KSHOT_VERSION" -srcfolder "$KSHOT_DMG_STAGE" \
  -format UDZO "$KSHOT_RELEASE/$KSHOT_NAME.dmg"
(cd "$KSHOT_RELEASE" && shasum -a 256 "$KSHOT_NAME.zip" "$KSHOT_NAME.dmg" appcast.xml > SHA256SUMS.txt)
echo "已生成 ${KSHOT_RELEASE}，发布时必须同时上传 appcast.xml、ZIP、DMG 和 SHA256SUMS.txt。"
