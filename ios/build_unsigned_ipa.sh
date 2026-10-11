#!/usr/bin/env bash
#
# 在 macOS 上把本工程编译成「未签名 IPA」。
# 产出的 WorldOL-unsigned.ipa 可直接丢给 ESign / 全能签 / 轻松签 自签名安装。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$SCRIPT_DIR"
ROOT_DIR="$(cd "$IOS_DIR/.." && pwd)"
WEBROOT="${WEBROOT:-$IOS_DIR/webroot}"

echo "==> 检查 webroot"
if [ ! -f "$WEBROOT/client/standalone.html" ]; then
  cat >&2 <<EOF
[错误] 找不到游戏资源：$WEBROOT/client/standalone.html

请先用解包工具生成 webroot：
    python3 "$ROOT_DIR/tools/worldol_archive.py" join "$ROOT_DIR/archive" /tmp/www.bin
    python3 -m pip install pycryptodome
    python3 "$ROOT_DIR/tools/worldol_archive.py" extract /tmp/www.bin "$WEBROOT"
EOF
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[错误] 需要 XcodeGen：brew install xcodegen" >&2
  exit 1
fi

cd "$IOS_DIR"

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 编译（不签名）"
xcodebuild \
  -project WorldOL.xcodeproj \
  -scheme WorldOL \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="build/Build/Products/Release-iphoneos/WorldOL.app"
if [ ! -d "$APP_PATH" ]; then
  echo "[错误] 编译产物不存在：$APP_PATH" >&2
  exit 1
fi

echo "==> 打包未签名 IPA"
rm -rf build/Payload build/WorldOL-unsigned.ipa
mkdir -p build/Payload
ditto "$APP_PATH" "build/Payload/WorldOL.app"
( cd build && zip -qry WorldOL-unsigned.ipa Payload )

echo
echo "完成：$IOS_DIR/build/WorldOL-unsigned.ipa"
ls -lh "$IOS_DIR/build/WorldOL-unsigned.ipa"
