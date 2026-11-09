# 部署后端

这里是给真机测试和 TestFlight 用的生产部署：一台 Linux 服务器上用 Docker 跑后端、PostgreSQL、Redis，Caddy 负责 https 证书，backup 容器每天凌晨 4 点导出一份数据库。任何能装 Docker、开放 80 和 443 端口的服务器都能用。

第一次部署：

```bash
# 服务器上（Ubuntu 举例）
curl -fsSL https://get.docker.com | sh
git clone https://github.com/cnYui/night-escort.git && cd night-escort/deploy
cp .env.example .env
for i in 1 2 3 4; do openssl rand -hex 32; done   # 填 POSTGRES_PASSWORD、JWT_SECRET、PHONE_PEPPER、PHONE_KEY_HEX
vi .env                                          # 填 DOMAIN，其余按注释填
./deploy.sh
```

域名的 A 记录要先指向服务器，否则 Caddy 申请不到证书。部署完 `https://<DOMAIN>/healthz` 返回 `{"ok":true}` 就说明后端、数据库和定时任务都正常；`https://<DOMAIN>/.well-known/apple-app-site-association` 能打开，邀请链接才能直接拉起 App。

以后更新只要在服务器上再跑一次 `./deploy.sh`，数据库迁移在后端启动时自动执行。看日志用 `docker compose logs -f backend`，没配阿里云短信时登录验证码也打在这里。

恢复备份：

```bash
gunzip -c backups/night_escort-20261109.sql.gz | docker compose exec -T postgres psql -U escort night_escort
```

`.env` 和 `backups/` 不进 git，里面有密钥和用户数据，别发给别人。手机号在库里是加密的，丢了 `PHONE_KEY_HEX` 就解不开，要单独存好。
