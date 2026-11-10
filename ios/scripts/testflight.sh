#!/bin/bash
# 在 Mac 上归档 iPhone App（手表 App 和小组件一起嵌在里面）并上传到 App Store Connect / TestFlight。
#
# 必填环境变量：
#   TEAM_ID        开发者账号的团队 ID（开发者后台右上角 Membership 里）
#   API_HOST       后端域名，例如 api.example.com，同时用作邀请链接域名
# 可选：
#   BUILD_NUMBER   构建号，每次上传必须比上一次大，默认用当前时间 yyyyMMddHHmm
#   ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
#                  App Store Connect API 密钥（.p8）。不填就用 Xcode 里登录的 Apple ID，
#                  这时必须在 Mac 前面运行（SSH 进来读不了登录钥匙串）。
#   KEYCHAIN_PATH / KEYCHAIN_PASSWORD
#                  SSH 远程打包时，放签名证书的单独钥匙串，脚本会先解锁它。
#   UPLOAD=0       只导出 .ipa 到 build/export，不上传
#
# 用法：TEAM_ID=ABCDE12345 API_HOST=api.example.com ios/scripts/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TEAM_ID:?请设置 TEAM_ID}"
: "${API_HOST:?请设置 API_HOST}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
UPLOAD="${UPLOAD:-1}"
ARCHIVE=build/NightEscort.xcarchive
EXPORT_DIR=build/export

auth=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  : "${ASC_KEY_ID:?设置了 ASC_KEY_PATH 也要设置 ASC_KEY_ID}"
  : "${ASC_ISSUER_ID:?设置了 ASC_KEY_PATH 也要设置 ASC_ISSUER_ID}"
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

if [ -n "${KEYCHAIN_PATH:-}" ]; then
  security unlock-keychain -p "${KEYCHAIN_PASSWORD:?设置了 KEYCHAIN_PATH 也要设置 KEYCHAIN_PASSWORD}" "$KEYCHAIN_PATH"
  security set-keychain-settings -t 3600 "$KEYCHAIN_PATH"
  security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')
fi

echo "== 生成工程"
xcodegen generate

echo "== 归档（构建号 ${BUILD_NUMBER}，后端 https://${API_HOST}）"
xcodebuild archive \
  -project NightEscort.xcodeproj \
  -scheme NightEscort \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${auth[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  API_BASE_URL="https://$API_HOST" \
  INVITE_HOST="$API_HOST"

destination=upload
[ "$UPLOAD" = "1" ] || destination=export
mkdir -p build
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "== 导出$([ "$UPLOAD" = "1" ] && echo '并上传')"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates "${auth[@]}"

if [ "$UPLOAD" = "1" ]; then
  echo "上传完成。App Store Connect 处理大约 5 到 30 分钟后，构建 $BUILD_NUMBER 会出现在 TestFlight 里。"
else
  echo "已导出到 ios/$EXPORT_DIR"
fi
