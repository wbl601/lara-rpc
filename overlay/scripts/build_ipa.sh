#!/bin/bash
# 替换上游同名脚本。改动只有三处，都是为了让 CI 里"为什么失败"可诊断：
#   1. 不再把 xcodebuild 输出直接管道给 xcpretty —— 那样一旦失败，完整日志就丢了，
#      而 Actions 的网页日志在我这边取不到，会变成盲改。
#   2. 完整日志同时写进 build/xcodebuild.log，失败时由工作流提交回仓库。
#   3. xcpretty 不存在时自动降级成纯 tee，不让一个美化工具把整个构建卡死。
set -euo pipefail

rm -rf build/
mkdir -p build

echo "Build Started!"
echo

LOG="$PWD/build/xcodebuild.log"

xcodebuild \
  -project lara.xcodeproj \
  -scheme lara \
  -configuration Debug \
  -sdk iphoneos \
  -arch arm64e \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="Config/lara.entitlements" \
  archive \
  -archivePath "$PWD/build/lara.xcarchive" 2>&1 | tee "$LOG" | { command -v xcpretty >/dev/null 2>&1 && xcpretty || cat; }

APP_PATH="$PWD/build/lara.xcarchive/Products/Applications/lara.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Missing app at $APP_PATH"
  exit 1
fi
rm -rf "$PWD/build/Payload"
mkdir -p "$PWD/build/Payload"
cp -R "$APP_PATH" "$PWD/build/Payload/"

plutil -replace UIFileSharingEnabled -bool YES "$PWD/build/Payload/lara.app/Info.plist"

# 本地网络权限描述：iOS 14+ 起，接受局域网连接会触发隐私提示，
# 没有这个键时连接会被静默拒绝，表现为"端口在监听但 PC 连不上"。
if ! /usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" \
      "$PWD/build/Payload/lara.app/Info.plist" >/dev/null 2>&1; then
  echo "WARN: NSLocalNetworkUsageDescription missing from built Info.plist"
fi

if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid not installed. Install with: brew install ldid" >&2
  exit 1
fi
ldid -SConfig/lara.entitlements "$PWD/build/Payload/lara.app/lara"
(cd "$PWD/build" && /usr/bin/zip -qry lara.ipa Payload)

# 产出校验信息，方便装机前核对是不是这次编出来的包
echo
echo "build successful!"
ls -l "$PWD/build/lara.ipa"
shasum -a 256 "$PWD/build/lara.ipa" || true
