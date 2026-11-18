#!/bin/bash
# 在模拟器里把 iPhone 和 Apple Watch 的主要页面各截一遍。用调试包的演示模式（-demoScene），不连后端。
#
# 用法：ios/scripts/screenshots.sh [输出目录，默认 /tmp/ne-shots/shots]
# 可选环境变量：
#   DD=/tmp/ne-shots/dd    编译产物目录，留着下次增量编译
#   PHONE_SCALE=603        iPhone 截图缩到这么宽（像素），0 = 不缩
#   WAIT=5                 每个页面启动后等几秒再截（机器慢就调大）
#   KEEP_SIM=1             跑完不关模拟器（下次更快）
# 截图放在 <输出目录>/iphone-<场景>.png 和 watch-<场景>.png。
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# 跑的时候别让 Mac 睡着（笔记本合盖仍然会睡，要开着盖）
if [ -z "${NE_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null; then
  export NE_CAFFEINATED=1
  exec caffeinate -dims "$SELF" "$@"
fi
OUT="${1:-/tmp/ne-shots/shots}"
DD="${DD:-/tmp/ne-shots/dd}"
PHONE_SCALE="${PHONE_SCALE:-603}"
WAIT="${WAIT:-5}"
LOGS="$(dirname "$DD")/logs"
mkdir -p "$OUT" "$LOGS"
OUT="$(cd "$OUT" && pwd)"
cd "$(dirname "$SELF")/.."

latest_runtime() { # $1 = iOS | watchOS
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin)["runtimes"] if x["platform"] == sys.argv[1] and x["isAvailable"]]
r.sort(key=lambda x: [int(p) for p in x["version"].split(".")])
print(r[-1]["identifier"])' "$1"
}

device_type() { # $1 = 运行时，其余 = 按优先顺序的机型名；都没有就挑名字里带 $2 的第一个
  local rt="$1" kind="$2"; shift 2
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rt, kind, wants = sys.argv[1], sys.argv[2], sys.argv[3:]
for x in json.load(sys.stdin)["runtimes"]:
    if x["identifier"] != rt: continue
    types = x.get("supportedDeviceTypes", [])
    names = {d["name"]: d["identifier"] for d in types}
    for w in wants:
        if w in names:
            print(names[w]); sys.exit(0)
    for d in reversed(types):
        if kind in d["name"]:
            print(d["identifier"]); sys.exit(0)
sys.exit(1)' "$rt" "$kind" "$@"
}

ensure_sim() { # 名字 机型 运行时 → UDID（已有就复用）
  local id
  id=$(xcrun simctl list devices -j | python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == sys.argv[1] and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)' "$1")
  [ -n "$id" ] || id=$(xcrun simctl create "$1" "$2" "$3")
  echo "$id"
}

SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
build() { # scheme 模拟器
  local log="$LOGS/build-$1.log" status=0
  xcodebuild build -project NightEscort.xcodeproj -scheme "$1" -destination "id=$2" \
    -derivedDataPath "$DD" "${SIGN[@]}" > "$log" 2>&1 || status=$?
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$log" | sort -u | tail -40 || true
  [ "$status" = 0 ] || { echo "$1 编译失败，完整日志在 $log"; exit 1; }
}

shot() { # 模拟器 包名 文件 等几秒 其余 = 启动参数
  local sim="$1" bundle="$2" file="$3" wait="$4" tries=0; shift 4
  xcrun simctl terminate "$sim" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$sim" "$bundle" "$@" -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN >/dev/null
  sleep "$wait"
  xcrun simctl io "$sim" screenshot "$file" >/dev/null 2>&1
  # 截到的还是纯色启动屏（文件特别小）就再等等重截。手表页面本来就大片黑，只查手机
  while [ "$bundle" = app.nightescort.ios ] && [ "$(stat -f%z "$file" 2>/dev/null || echo 0)" -lt 200000 ] && [ $tries -lt 4 ]; do
    tries=$((tries + 1)); sleep 5
    xcrun simctl io "$sim" screenshot "$file" >/dev/null 2>&1
  done
}

xcodegen generate >/dev/null

# 先把 iPhone 整个做完再做手表：手表那边出问题时，手机的图已经有了
echo "== 1/4 iPhone：模拟器和编译"
IOS_RT=$(latest_runtime iOS)
PHONE_TYPE=$(device_type "$IOS_RT" "iPhone" "iPhone 17" "iPhone 17 Pro" "iPhone 16")
PHONE=$(ensure_sim ne-shots-phone "$PHONE_TYPE" "$IOS_RT")
echo "iPhone ${PHONE}（${PHONE_TYPE}，${IOS_RT}）"
xcrun simctl boot "$PHONE" 2>/dev/null || true
xcrun simctl bootstatus "$PHONE" -b >/dev/null
build NightEscort "$PHONE"
xcrun simctl install "$PHONE" "$DD/Build/Products/Debug-iphonesimulator/NightEscort.app"
xcrun simctl privacy "$PHONE" grant location app.nightescort.ios || true
xcrun simctl status_bar "$PHONE" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true

echo "== 2/4 iPhone 截图"
# 每台模拟器第一次启动 App 比较慢，先空跑一次
# App 固定深色，系统也切到深色，半屏页和系统弹窗才一致
xcrun simctl ui "$PHONE" appearance dark || true
shot "$PHONE" app.nightescort.ios "$OUT/.warmup.png" 12 -demoScene home -locationNoteShown YES
for scene in login home start active sos guarding incident me; do
  wait=$WAIT; extra=()
  case "$scene" in
    login|incident) wait=$((WAIT + 5)) ;;
    home|start) wait=$((WAIT + 5)); extra=(-homePick p-ak,p-mm) ;;
  esac
  shot "$PHONE" app.nightescort.ios "$OUT/iphone-$scene.png" "$wait" \
    -demoScene "$scene" -locationNoteShown YES ${extra[@]+"${extra[@]}"}
  if [ "$PHONE_SCALE" != 0 ]; then
    sips --resampleWidth "$PHONE_SCALE" "$OUT/iphone-$scene.png" >/dev/null 2>&1 || true
  fi
  echo "  iphone-$scene"
done
rm -f "$OUT/.warmup.png"
[ "${KEEP_SIM:-0}" = "1" ] || xcrun simctl shutdown "$PHONE" 2>/dev/null || true

echo "== 3/4 手表：模拟器和编译"
WATCH_RT=$(latest_runtime watchOS)
WATCH_TYPE=$(device_type "$WATCH_RT" "46mm" "Apple Watch Series 12 (46mm)" "Apple Watch Series 11 (46mm)" "Apple Watch Series 10 (46mm)")
WATCH=$(ensure_sim ne-shots-watch "$WATCH_TYPE" "$WATCH_RT")
echo "手表 ${WATCH}（${WATCH_TYPE}，${WATCH_RT}）"
xcrun simctl boot "$WATCH" 2>/dev/null || true
xcrun simctl bootstatus "$WATCH" -b >/dev/null
build NightEscortWatch "$WATCH"
xcrun simctl install "$WATCH" "$DD/Build/Products/Debug-watchsimulator/NightEscortWatch.app"

echo "== 4/4 手表截图"
shot "$WATCH" app.nightescort.ios.watchkitapp "$OUT/.warmup.png" 12 -demoScene idle
for scene in signin idle running paused alerting sos home message; do
  shot "$WATCH" app.nightescort.ios.watchkitapp "$OUT/watch-$scene.png" "$WAIT" -demoScene "$scene"
  echo "  watch-$scene"
done
rm -f "$OUT/.warmup.png"
[ "${KEEP_SIM:-0}" = "1" ] || xcrun simctl shutdown "$WATCH" 2>/dev/null || true
echo "截图在 $OUT"
