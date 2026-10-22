#!/bin/bash
# 编译不签名的真机版 IPA（arm64，Release），供用户用 Sideloadly / AltStore / TrollStore 等工具自行签名安装
# 用法：Tools/build-unsigned-ipa.sh            → dist/Mi-Dama-<版本>-unsigned.ipa
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
BUILD="$ROOT/build/unsigned"
DIST="$ROOT/dist"
rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

xcodebuild \
  -project App/Redact.xcodeproj \
  -scheme Redact \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build | grep -E "error:|warning:|BUILD" || true

APP="$BUILD/DerivedData/Build/Products/Release-iphoneos/Redact.app"
[ -d "$APP" ] || { echo "编译失败：找不到 $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
IPA="$DIST/Mi-Dama-$VERSION-unsigned.ipa"

# IPA 就是把 .app 放进 Payload/ 再 zip；ditto 保留权限和符号链接。
# 不打包资源分支和扩展属性：macOS 会给新文件加 com.apple.provenance 等属性，带上的话包里会多出 __MACOSX/ 目录
mkdir -p "$BUILD/Payload"
cp -R "$APP" "$BUILD/Payload/"
rm -f "$IPA"
(cd "$BUILD" && ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent Payload "$IPA")

echo "已生成：$IPA（$(du -h "$IPA" | cut -f1)）"
