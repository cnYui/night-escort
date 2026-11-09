#!/bin/bash
# 在 Mac 上把第一版 MVP 从头到尾跑一遍：本地 PostgreSQL + 后端 + 模拟器里的 App，
# 测试进程扮演好友。每一步的截图导出到 $OUT/shots。
#
# 用法：ios/scripts/mvp-e2e.sh
# 可选环境变量：
#   PORT=8090          后端端口（别和正在用的 8080 撞上）
#   DB=night_escort_mvp 专用测试库，每次运行会清空重建，别指向存真实数据的库
#   OUT=/tmp/ne-mvp     日志、测试结果和截图放这里
#   DEVICE="iPhone 17"  模拟器机型
#   KEEP_SIM=1          跑完不删模拟器（方便手动再点点看）
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
PORT="${PORT:-8090}"
DB="${DB:-night_escort_mvp}"
OUT="${OUT:-/tmp/ne-mvp}"
DEVICE="${DEVICE:-iPhone 17}"
CODE=246810
mkdir -p "$OUT"
rm -rf "$OUT/result.xcresult" "$OUT/shots"

BACKEND_PID=""
SIM=""
cleanup() {
  [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true
  if [ -n "$SIM" ] && [ "${KEEP_SIM:-0}" != "1" ]; then
    xcrun simctl shutdown "$SIM" 2>/dev/null || true
    xcrun simctl delete "$SIM" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "== 1/6 数据库：清空重建 $DB"
PG="$(brew --prefix postgresql@16 2>/dev/null)/bin"
[ -x "$PG/psql" ] || PG="$(dirname "$(command -v psql)")"
"$PG/pg_isready" -h 127.0.0.1 -q || { echo "PostgreSQL 没在跑：brew services start postgresql@16"; exit 1; }
"$PG/dropdb" -h 127.0.0.1 -U postgres --if-exists "$DB"
"$PG/createdb" -h 127.0.0.1 -U postgres "$DB"
export DATABASE_URL="postgres://postgres@127.0.0.1:5432/$DB"

echo "== 2/6 启动后端（端口 $PORT，测试号码 +86199000*，可拨时钟）"
cd "$ROOT/backend"
[ -d node_modules ] || npm ci --silent
npm run migrate --silent
SMS_TEST_NUMBERS='+86199000*' SMS_TEST_CODE=$CODE DEV_TOOLS=true PORT=$PORT \
  npx tsx src/main.ts > "$OUT/backend.log" 2>&1 &
BACKEND_PID=$!
for _ in $(seq 1 40); do curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null || { echo "后端没起来，看 $OUT/backend.log"; exit 1; }

echo "== 3/6 只用接口先走一遍"
BASE_URL="http://127.0.0.1:$PORT" SMS_TEST_CODE=$CODE npx tsx scripts/mvp-smoke.ts | tee "$OUT/smoke.log"

echo "== 4/6 新建模拟器 $DEVICE"
cd "$ROOT/ios"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(sorted(r,key=lambda x:[int(p) for p in x["version"].split(".")])[-1]["identifier"])')
SIM=$(xcrun simctl create "ne-mvp-e2e" "$DEVICE" "$RUNTIME")
xcrun simctl boot "$SIM"
# 定位权限先给好，测试里只剩通知权限的弹窗
xcrun simctl privacy "$SIM" grant location app.nightescort.ios || true

echo "== 5/6 编译并跑界面测试"
xcodegen generate >/dev/null
set +e
TEST_RUNNER_NE_API_BASE_URL="http://localhost:$PORT" TEST_RUNNER_NE_SMS_TEST_CODE=$CODE \
  xcodebuild test -project NightEscort.xcodeproj -scheme NightEscortUITests \
  -destination "id=$SIM" -resultBundlePath "$OUT/result.xcresult" \
  CODE_SIGNING_ALLOWED=NO > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
set -e
grep -E "error:|failed|passed|Executed|TEST (SUCCEEDED|FAILED)" "$OUT/xcodebuild.log" | tail -20

echo "== 6/6 导出截图到 $OUT/shots"
mkdir -p "$OUT/shots"
if xcrun xcresulttool export attachments --path "$OUT/result.xcresult" --output-path "$OUT/shots/raw" >/dev/null 2>&1; then
  python3 - "$OUT/shots" <<'PY'
import json, os, shutil, sys
out = sys.argv[1]; raw = os.path.join(out, "raw")
for test in json.load(open(os.path.join(raw, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        base = name.split("_0_")[0] if "_0_" in name else os.path.splitext(name)[0]
        shutil.copy(os.path.join(raw, a["exportedFileName"]), os.path.join(out, base + ".png"))
shutil.rmtree(raw)
PY
  ls "$OUT/shots"
else
  echo "这个 Xcode 的 xcresulttool 不支持导出附件，截图在 $OUT/result.xcresult 里，用 Xcode 打开看"
fi

[ $STATUS -eq 0 ] && echo "MVP 端到端全部通过" || echo "界面测试没通过，看 $OUT/xcodebuild.log 和 $OUT/backend.log"
exit $STATUS
