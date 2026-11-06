#!/bin/bash
# 本地一键启动后端：装 Node / PostgreSQL（如果没有）、建库、装依赖、建表、启动。
set -e
cd "$(dirname "$0")"

echo "== 1/5 检查 Homebrew"
if ! command -v brew >/dev/null; then
  echo "没找到 Homebrew。先打开 https://brew.sh 按首页那一行命令安装，装完再运行本脚本。"
  exit 1
fi

echo "== 2/5 检查 Node.js（需要 20 以上）"
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  brew install node@22
  brew link --overwrite --force node@22
fi
echo "Node 版本：$(node -v)"

echo "== 3/5 安装并启动数据库 PostgreSQL"
brew list postgresql@16 >/dev/null 2>&1 || brew install postgresql@16
brew services start postgresql@16
PG="$(brew --prefix postgresql@16)/bin"
for i in $(seq 1 30); do "$PG/pg_isready" -h 127.0.0.1 -q && break; sleep 1; done
"$PG/psql" -h 127.0.0.1 -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='postgres'" | grep -q 1 \
  || "$PG/createuser" -h 127.0.0.1 -s postgres
"$PG/psql" -h 127.0.0.1 -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='night_escort'" | grep -q 1 \
  || "$PG/createdb" -h 127.0.0.1 -O postgres night_escort
echo "数据库就绪"

echo "== 4/5 安装依赖、建表"
npm install
npm run migrate

echo ""
echo "== 5/5 启动后端：看到 8080 就成功了。这个窗口别关，验证码会打印在这里。"
npm run dev
