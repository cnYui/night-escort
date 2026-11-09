#!/bin/sh
# 在 backup 容器里循环运行：每天 04:00 导出一次，只留最近 14 份。
set -u
while true; do
  if [ "$(date +%H%M)" = "0400" ]; then
    f="/backups/night_escort-$(date +%Y%m%d).sql.gz"
    if pg_dump -h postgres -U escort night_escort | gzip > "$f"; then
      echo "备份完成 $f"
    else
      echo "备份失败 $f"
    fi
    ls -1t /backups/night_escort-*.sql.gz 2>/dev/null | tail -n +15 | while read -r old; do rm -f -- "$old"; done
    sleep 60
  fi
  sleep 30
done
