#!/bin/bash
# 编译并打包 MenuBarManager-V3.app
# 用法: bash build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MenuBarManager-V3"
BUNDLE_ID="com.paul.menubar-manager-v3"
VERSION="3.0.0"                                   # 版本号只在这里定义，app 运行时从 Info.plist 读
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DIR=".build"
mkdir -p "$BUILD_DIR"

echo "编译 $APP_NAME $VERSION ($BUILD_NUMBER)..."
swiftc \
    -O \
    -swift-version 5 \
    -sdk "$(xcrun --show-sdk-path)" \
    -target arm64-apple-macosx14.0 \
    -emit-executable \
    -o "$BUILD_DIR/$APP_NAME" \
    Sources/*.swift \
    -framework AppKit \
    -framework ScreenCaptureKit

CONTENTS="$APP_NAME.app/Contents"
rm -rf "$APP_NAME.app"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
cp Resources/statusbar-icon.png "$CONTENTS/Resources/statusbar-icon.png"

cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# 用固定的开发证书签名：系统隐私权限认的是签名身份，临时签名(-)每次编译身份都变，
# 会导致辅助功能/屏幕录制权限失效要重新授权。找不到证书时才退回临时签名。
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | awk '{print $2}' || true)}"
if [ -z "$SIGN_ID" ]; then
    echo "警告: 没找到 Apple Development 证书，使用临时签名（每次编译后可能要重新授权）"
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" "$APP_NAME.app"
echo "完成: $APP_NAME.app"
echo "启动: open $APP_NAME.app"
