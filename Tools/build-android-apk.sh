#!/bin/bash
# 编译 Android 正式版 APK（按 CPU 架构各一个，调试证书签名，可直接安装），并跑核心库单测
# 用法：Tools/build-android-apk.sh     → dist/Mi-Dama-<版本>-arm64-v8a.apk、dist/Mi-Dama-<版本>-armeabi-v7a.apk
# 需要 JDK 17+ 和 Android SDK（ANDROID_HOME，或 android/local.properties 里的 sdk.dir）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIST="$ROOT/dist"
mkdir -p "$DIST"

(cd android && ./gradlew --console=plain -q :core:test :app:assembleRelease)

OUT="$ROOT/android/app/build/outputs/apk/release"
VERSION=$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' android/app/build.gradle.kts)
for abi in arm64-v8a armeabi-v7a; do
  APK="$OUT/app-$abi-release.apk"
  [ -f "$APK" ] || { echo "编译失败：找不到 $APK"; exit 1; }
  cp "$APK" "$DIST/Mi-Dama-$VERSION-$abi.apk"
  echo "已生成：$DIST/Mi-Dama-$VERSION-$abi.apk（$(du -h "$APK" | cut -f1)）"
done
