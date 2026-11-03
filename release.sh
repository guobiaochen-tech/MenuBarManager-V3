#!/bin/bash
# 打包发布版：Developer ID 签名 + 苹果公证，生成 dist/MenuBarManager-V3-<版本>.dmg
# 首次使用前先存公证凭据（只需一次）:
#   xcrun notarytool store-credentials notary --team-id VD4WTMGZJ6
# 用法: bash release.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MenuBarManager-V3"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
DIST="dist"

DEV_ID="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | awk '{print $2}' || true)"
if [ -z "$DEV_ID" ]; then
    echo "错误: 没找到 Developer ID Application 证书"
    exit 1
fi
# 先检查公证凭据，免得编译完才发现交不了
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
    echo "错误: 没有公证凭据 ${NOTARY_PROFILE}，先运行:"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --team-id VD4WTMGZJ6"
    exit 1
fi

bash build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_NAME.app/Contents/Info.plist")"

# 公证要求：加固运行模式(--options runtime) + 苹果时间戳(--timestamp)
codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP_NAME.app"
codesign --verify --strict --verbose=2 "$APP_NAME.app"

# 安装包里放软件本体和「应用程序」文件夹的快捷方式，用户拖进去即可
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --force --timestamp --sign "$DEV_ID" "$DMG"

# 交给苹果公证并等结果；通过后把公证结果附到安装包上，离线也能验证
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "完成: $DMG"
