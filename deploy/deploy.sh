#!/bin/bash
# 在服务器上运行：拉最新代码、重新构建并启动。数据库迁移在后端启动时自动执行。
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "先 cp .env.example .env 并填好"; exit 1; }
for k in DOMAIN POSTGRES_PASSWORD JWT_SECRET PHONE_PEPPER PHONE_KEY_HEX; do
  grep -Eq "^$k=.+" .env || { echo ".env 里的 $k 还没填"; exit 1; }
done
grep -Eq "^APPLE_TEAM_ID=.+" .env || echo "提醒：APPLE_TEAM_ID 没填，邀请链接点开不会直接进 App"
git pull --ff-only
mkdir -p backups
docker compose up -d --build
domain=$(grep -E '^DOMAIN=' .env | cut -d= -f2)
echo "等后端起来…"
for _ in $(seq 1 60); do
  if curl -fsS "https://$domain/healthz" >/dev/null 2>&1; then
    echo "部署完成：https://$domain/healthz 正常"
    exit 0
  fi
  sleep 2
done
echo "两分钟内健康检查没通过，看日志：docker compose logs --tail 100 backend caddy"
exit 1
