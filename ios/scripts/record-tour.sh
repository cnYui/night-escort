#!/bin/bash
# 录「使用视频」素材：两台 iPhone 模拟器同时连真实后端，一台是小林（回家的人，配一只手表），
# 一台是阿珂（守护她的人）。界面测试 TourTests 按人看得清的节奏操作，simctl 全程录屏。
# 最后再把手表演示模式的几个页面各录几秒（手表和手机同步不上时也有手表画面可剪）。
#
# 用法：ios/scripts/record-tour.sh
# 可选环境变量：
#   PORT=8091            后端端口
#   DB=night_escort_tour 专用库，每次清空重建，别指向真实数据
#   OUT=/tmp/ne-tour     录像、日志放这里：xiaolin.mp4 ake.mp4 watch.mp4 watch-scenes/*.mp4 times.txt
#   CLOCK=23:47          两台手机状态栏显示的时间
#   PACE=1               节奏倍数（0.3 = 快速试跑）
#   WATCH=1              给小林配手表并录屏（0 = 不要手表）
#   KEEP_SIM=1           跑完不关模拟器
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if [ -z "${NE_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null; then
  export NE_CAFFEINATED=1
  exec caffeinate -dims "$SELF" "$@"
fi
cd "$(dirname "$SELF")/../.."
ROOT=$(pwd)
PORT="${PORT:-8091}"
DB="${DB:-night_escort_tour}"
OUT="${OUT:-/tmp/ne-tour}"
CLOCK="${CLOCK:-23:47}"
PACE="${PACE:-1}"
WATCH="${WATCH:-1}"
DD="$OUT/dd"
CODE=246810
RUN=$(printf "%04d" $(( $(date +%s) % 10000 )))
mkdir -p "$OUT"
rm -rf "$OUT"/*.xcresult "$OUT"/*.mp4 "$OUT/watch-scenes" "$OUT/times.txt"
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

BACKEND_PID=""
RECS=()
SIMS=()
cleanup() {
  for p in ${RECS[@]+"${RECS[@]}"}; do kill -INT "$p" 2>/dev/null || true; done
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true
  if [ "${KEEP_SIM:-0}" != "1" ]; then
    for s in ${SIMS[@]+"${SIMS[@]}"}; do xcrun simctl shutdown "$s" 2>/dev/null || true; done
  fi
}
trap cleanup EXIT

latest_runtime() { # iOS | watchOS
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin)["runtimes"] if x["platform"] == sys.argv[1] and x["isAvailable"]]
r.sort(key=lambda x: [int(p) for p in x["version"].split(".")])
print(r[-1]["identifier"])' "$1"
}
device_type() { # 运行时 关键字 优先机型...
  local rt="$1" kind="$2"; shift 2
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rt, kind, wants = sys.argv[1], sys.argv[2], sys.argv[3:]
for x in json.load(sys.stdin)["runtimes"]:
    if x["identifier"] != rt: continue
    types = x.get("supportedDeviceTypes", [])
    names = {d["name"]: d["identifier"] for d in types}
    for w in wants:
        if w in names: print(names[w]); sys.exit(0)
    for d in reversed(types):
        if kind in d["name"]: print(d["identifier"]); sys.exit(0)
sys.exit(1)' "$rt" "$kind" "$@"
}
fresh_sim() { # 名字 机型 运行时：同名的先删掉，保证干净
  xcrun simctl list devices -j | python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == sys.argv[1]: print(d["udid"])' "$1" | while read -r old; do
    xcrun simctl shutdown "$old" >/dev/null 2>&1 || true
    xcrun simctl delete "$old" >/dev/null 2>&1 || true
  done
  xcrun simctl create "$1" "$2" "$3"
}
dress_phone() { # 模拟器：深色、状态栏、定位权限
  xcrun simctl ui "$1" appearance dark || true
  xcrun simctl status_bar "$1" override --time "$CLOCK" --batteryState discharging --batteryLevel 64 \
    --wifiBars 2 --cellularMode active --cellularBars 3 || true
  xcrun simctl privacy "$1" grant location app.nightescort.ios || true
}
rec() { # 模拟器 文件 → 后台录屏
  xcrun simctl io "$1" recordVideo --codec=h264 --force "$2" > "$2.log" 2>&1 &
  RECS+=($!)
  echo "$(basename "$2") $(now)" >> "$OUT/times.txt"
}

echo "== 1/6 数据库和后端（端口 ${PORT}，测试号码 +86199000*，可拨时钟）"
PG="$(brew --prefix postgresql@16 2>/dev/null)/bin"
[ -x "$PG/psql" ] || PG="$(dirname "$(command -v psql)")"
"$PG/pg_isready" -h 127.0.0.1 -q || { echo "PostgreSQL 没在跑：brew services start postgresql@16"; exit 1; }
"$PG/dropdb" -h 127.0.0.1 -U postgres --if-exists "$DB"
"$PG/createdb" -h 127.0.0.1 -U postgres "$DB"
export DATABASE_URL="postgres://postgres@127.0.0.1:5432/$DB"
cd "$ROOT/backend"
[ -d node_modules ] || npm ci --silent
npm run migrate --silent
SMS_TEST_NUMBERS='+86199000*' SMS_TEST_CODE=$CODE DEV_TOOLS=true PORT=$PORT \
  npx tsx src/main.ts > "$OUT/backend.log" 2>&1 &
BACKEND_PID=$!
for _ in $(seq 1 40); do curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null || { echo "后端没起来，看 $OUT/backend.log"; exit 1; }

echo "== 2/6 模拟器：小林、阿珂两台 iPhone$([ "$WATCH" = 1 ] && echo "，小林配手表")"
cd "$ROOT/ios"
IOS_RT=$(latest_runtime iOS)
PHONE_TYPE=$(device_type "$IOS_RT" "iPhone" "iPhone 17" "iPhone 17 Pro" "iPhone 16")
A=$(fresh_sim ne-tour-xiaolin "$PHONE_TYPE" "$IOS_RT"); SIMS+=("$A")
B=$(fresh_sim ne-tour-ake "$PHONE_TYPE" "$IOS_RT"); SIMS+=("$B")
W=""
if [ "$WATCH" = 1 ]; then
  WATCH_RT=$(latest_runtime watchOS)
  WATCH_TYPE=$(device_type "$WATCH_RT" "46mm" "Apple Watch Series 12 (46mm)" "Apple Watch Series 11 (46mm)" "Apple Watch Series 10 (46mm)")
  W=$(fresh_sim ne-tour-watch "$WATCH_TYPE" "$WATCH_RT"); SIMS+=("$W")
  xcrun simctl pair "$W" "$A" >/dev/null || { echo "手表配对失败，不用手表继续"; W=""; }
fi
for s in "$A" "$B" ${W:+"$W"}; do xcrun simctl boot "$s" 2>/dev/null || true; done
for s in "$A" "$B" ${W:+"$W"}; do xcrun simctl bootstatus "$s" -b >/dev/null; done
dress_phone "$A"; dress_phone "$B"
# 小林走在上海的夜路上，阿珂在另一个区
xcrun simctl location "$A" start --speed=1.4 \
  31.22990,121.44520 31.22870,121.44690 31.22750,121.44850 31.22610,121.45010 31.22480,121.45170 >/dev/null 2>&1 || \
  xcrun simctl location "$A" set 31.22990,121.44520 || true
xcrun simctl location "$B" set 31.20480,121.43020 || true

echo "== 3/6 编译"
xcodegen generate >/dev/null
SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
xcodebuild build-for-testing -project NightEscort.xcodeproj -scheme NightEscortUITests -destination "id=$A" \
  -derivedDataPath "$DD" "${SIGN[@]}" > "$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | sort -u | tail -30; echo "编译失败，看 $OUT/build.log"; exit 1; }
if [ -n "$W" ]; then
  if xcodebuild build -project NightEscort.xcodeproj -scheme NightEscortWatch -destination "id=$W" \
      -derivedDataPath "$DD" "${SIGN[@]}" > "$OUT/build-watch.log" 2>&1; then
    xcrun simctl install "$W" "$DD/Build/Products/Debug-watchsimulator/NightEscortWatch.app"
    xcrun simctl launch "$W" app.nightescort.ios.watchkitapp -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN >/dev/null || true
  else
    echo "手表编译失败（看 $OUT/build-watch.log），这次不录手表"; W=""
  fi
fi

echo "== 4/6 开始录屏，两台手机同时跑演示（约 5 分钟）"
rec "$A" "$OUT/xiaolin.mp4"
rec "$B" "$OUT/ake.mp4"
[ -n "$W" ] && rec "$W" "$OUT/watch.mp4"
sleep 1
export TEST_RUNNER_NE_API_BASE_URL="http://127.0.0.1:$PORT" TEST_RUNNER_NE_SMS_TEST_CODE=$CODE \
  TEST_RUNNER_NE_TOUR_RUN=$RUN TEST_RUNNER_NE_TOUR_PACE=$PACE
set +e
xcodebuild test-without-building -project NightEscort.xcodeproj -scheme NightEscortUITests -destination "id=$B" \
  -derivedDataPath "$DD" -only-testing:NightEscortUITests/TourTests/testAke \
  -resultBundlePath "$OUT/ake.xcresult" > "$OUT/test-ake.log" 2>&1 &
AKE=$!
sleep 2
xcodebuild test-without-building -project NightEscort.xcodeproj -scheme NightEscortUITests -destination "id=$A" \
  -derivedDataPath "$DD" -only-testing:NightEscortUITests/TourTests/testXiaolin \
  -resultBundlePath "$OUT/xiaolin.xcresult" > "$OUT/test-xiaolin.log" 2>&1
S1=$?
wait $AKE
S2=$?
set -e
sleep 2
for p in "${RECS[@]}"; do kill -INT "$p" 2>/dev/null || true; done
for p in "${RECS[@]}"; do wait "$p" 2>/dev/null || true; done
RECS=()
echo "end $(now)" >> "$OUT/times.txt"
grep -hE "error:|failed|passed|Executed|TEST (SUCCEEDED|FAILED)|XCTAssert|等了" "$OUT/test-xiaolin.log" "$OUT/test-ake.log" | tail -20
grep -h "TOURMARK|" "$OUT/test-xiaolin.log" "$OUT/test-ake.log" | sed "s/.*TOURMARK|/TOURMARK|/" | sort -t"|" -k3 > "$OUT/marks.txt" || true

echo "== 5/6 手表演示页面各录几秒"
if [ "$WATCH" = 1 ]; then
  [ -n "$W" ] || { W=$(fresh_sim ne-tour-watch "$WATCH_TYPE" "$WATCH_RT"); SIMS+=("$W"); xcrun simctl boot "$W"; xcrun simctl bootstatus "$W" -b >/dev/null; }
  if [ -d "$DD/Build/Products/Debug-watchsimulator/NightEscortWatch.app" ]; then
    xcrun simctl install "$W" "$DD/Build/Products/Debug-watchsimulator/NightEscortWatch.app"
    mkdir -p "$OUT/watch-scenes"
    for scene in signin idle running alerting sos home; do
      xcrun simctl terminate "$W" app.nightescort.ios.watchkitapp >/dev/null 2>&1 || true
      xcrun simctl launch "$W" app.nightescort.ios.watchkitapp -demoScene "$scene" -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN >/dev/null
      sleep 3
      xcrun simctl io "$W" recordVideo --codec=h264 --force "$OUT/watch-scenes/$scene.mp4" > /dev/null 2>&1 &
      R=$!; sleep 6; kill -INT $R; wait $R 2>/dev/null || true
      echo "  watch-$scene"
    done
  fi
fi

echo "== 6/6 完成"
ls -la "$OUT"/*.mp4 "$OUT"/watch-scenes 2>/dev/null || true
cat "$OUT/times.txt"
[ $S1 -eq 0 ] && [ $S2 -eq 0 ] && echo "两台手机的演示都跑通了，录像在 $OUT" || { echo "有一边没跑通：看 $OUT/test-xiaolin.log、$OUT/test-ake.log、$OUT/backend.log"; exit 1; }
