#!/bin/bash
# 把几套配色在模拟器里各截一遍（iPhone + Apple Watch）。用调试包的演示模式，不连后端。
# 配色见 ios/Shared/Palette.swift，启动参数 -palette a|b|c|system 切换。
#
# 用法：ios/scripts/palette-shots.sh [输出目录，默认 /tmp/ne-palette/shots]
# 可选环境变量：
#   PALETTES="a b c"       截哪几套
#   DD=/tmp/ne-palette/dd  编译产物目录，留着下次增量编译
#   PHONE_SCALE=603        iPhone 截图缩到这么宽（像素），0 = 不缩
#   WAIT=5                 每个页面启动后等几秒再截（机器慢就调大）
#   KEEP_SIM=1             跑完不关模拟器（下次更快）
# 截图放在 <输出目录>/<配色>/iphone-<场景>.png 和 watch-<场景>.png。
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# 跑的时候别让 Mac 睡着（笔记本合盖仍然会睡，要开着盖）
if [ -z "${NE_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null; then
  export NE_CAFFEINATED=1
  exec caffeinate -dims "$SELF" "$@"
fi
OUT="${1:-/tmp/ne-palette/shots}"
DD="${DD:-/tmp/ne-palette/dd}"
PALETTES="${PALETTES:-a b c}"
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

echo "== 1/4 模拟器"
IOS_RT=$(latest_runtime iOS)
WATCH_RT=$(latest_runtime watchOS)
PHONE_TYPE=$(device_type "$IOS_RT" "iPhone" "iPhone 17" "iPhone 17 Pro" "iPhone 16")
WATCH_TYPE=$(device_type "$WATCH_RT" "46mm" "Apple Watch Series 12 (46mm)" "Apple Watch Series 11 (46mm)" "Apple Watch Series 10 (46mm)")
PHONE=$(ensure_sim ne-palette-phone "$PHONE_TYPE" "$IOS_RT")
WATCH=$(ensure_sim ne-palette-watch "$WATCH_TYPE" "$WATCH_RT")
echo "iPhone $PHONE（$PHONE_TYPE，$IOS_RT）"
echo "手表   $WATCH（$WATCH_TYPE，$WATCH_RT）"
xcrun simctl boot "$PHONE" 2>/dev/null || true
xcrun simctl boot "$WATCH" 2>/dev/null || true
xcrun simctl bootstatus "$PHONE" -b >/dev/null
xcrun simctl bootstatus "$WATCH" -b >/dev/null

echo "== 2/4 编译"
xcodegen generate >/dev/null
SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
build() { # scheme 模拟器
  local log="$LOGS/build-$1.log" status=0
  xcodebuild build -project NightEscort.xcodeproj -scheme "$1" -destination "id=$2" \
    -derivedDataPath "$DD" "${SIGN[@]}" > "$log" 2>&1 || status=$?
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$log" | sort -u | tail -40 || true
  [ "$status" = 0 ] || { echo "$1 编译失败，完整日志在 $log"; exit 1; }
}
build NightEscort "$PHONE"
build NightEscortWatch "$WATCH"
xcrun simctl install "$PHONE" "$DD/Build/Products/Debug-iphonesimulator/NightEscort.app"
xcrun simctl install "$WATCH" "$DD/Build/Products/Debug-watchsimulator/NightEscortWatch.app"
xcrun simctl privacy "$PHONE" grant location app.nightescort.ios || true
xcrun simctl status_bar "$PHONE" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true

shot() { # 模拟器 包名 文件 等几秒 其余 = 启动参数
  local sim="$1" bundle="$2" file="$3" wait="$4"; shift 4
  xcrun simctl terminate "$sim" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$sim" "$bundle" "$@" -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN >/dev/null
  sleep "$wait"
  xcrun simctl io "$sim" screenshot "$file" >/dev/null 2>&1
}

echo "== 3/4 iPhone 截图"
# 每台模拟器第一次启动 App 比较慢，先空跑一次
shot "$PHONE" app.nightescort.ios "$OUT/.warmup.png" 12 -demoScene home -locationNoteShown YES
for p in $PALETTES; do
  mkdir -p "$OUT/$p"
  # C 配色自己固定深色，这里顺手把系统也切过去；其它按浅色截
  xcrun simctl ui "$PHONE" appearance "$([ "$p" = c ] && echo dark || echo light)" || true
  for scene in login home start active sos guarding incident me; do
    wait=$WAIT; extra=()
    case "$scene" in
      login|incident) wait=$((WAIT + 5)) ;;
      home|start) extra=(-homePick p-ak,p-mm) ;;
    esac
    shot "$PHONE" app.nightescort.ios "$OUT/$p/iphone-$scene.png" "$wait" \
      -demoScene "$scene" -palette "$p" -locationNoteShown YES ${extra[@]+"${extra[@]}"}
    if [ "$PHONE_SCALE" != 0 ]; then
      sips --resampleWidth "$PHONE_SCALE" "$OUT/$p/iphone-$scene.png" >/dev/null 2>&1 || true
    fi
    echo "  $p iphone-$scene"
  done
done
xcrun simctl ui "$PHONE" appearance light || true

echo "== 4/4 手表截图"
shot "$WATCH" app.nightescort.ios.watchkitapp "$OUT/.warmup.png" 12 -demoScene idle
for p in $PALETTES; do
  for scene in signin idle running paused alerting sos home message; do
    shot "$WATCH" app.nightescort.ios.watchkitapp "$OUT/$p/watch-$scene.png" "$WAIT" -demoScene "$scene" -palette "$p"
    echo "  $p watch-$scene"
  done
done
rm -f "$OUT/.warmup.png"

if [ "${KEEP_SIM:-0}" != "1" ]; then
  xcrun simctl shutdown "$PHONE" 2>/dev/null || true
  xcrun simctl shutdown "$WATCH" 2>/dev/null || true
fi
echo "截图在 $OUT"
