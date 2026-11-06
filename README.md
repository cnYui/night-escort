# 到家没

夜里一个人回家时，按间隔签到；没按时签到，App 先叫醒你选的担保人去联系你。遇到危险可以在手机或手表上长按 2 秒「一键求救」，所有担保人立刻响铃，担保人可以在提醒框里直接打电话给她。v1 不发短信、不打电话、不报警，提醒全部走 App 推送和 App 内持续响铃。

设计稿、配色和图标源文件在 [`design/`](design/README.md)。

仓库分三块：`backend/` 是 Node.js + PostgreSQL 后端（心跳引擎、担保授权、位置转发、推送），`ios/Packages/EscortKit/` 是手机、手表、小组件共用的 Swift 包（接口模型、到家判断、位置采样和上传队列，可以单独跑测试），`ios/` 里是 SwiftUI 的 iPhone App、Apple Watch App 和实时活动小组件，工程用 XcodeGen 生成。

## 后端

需要 Node 20 和 PostgreSQL 16（Redis 可选，不配就用内存）。

Mac 上最省事的办法是一键脚本：没有 Node / PostgreSQL 会用 Homebrew 装上，然后建库、建表、启动（验证码打印在这个终端里）：

```bash
bash backend/setup-local.sh
```

拉了新代码后如果有新的数据库迁移（`backend/migrations/`），再跑一次 `npm run migrate`。

也可以用 Docker：

```bash
cd backend
docker compose up -d          # 起 postgres 和 redis
cp .env.example .env
npm install
npm run migrate
npm run dev                   # http://localhost:8080
```

测试会连 `TEST_DATABASE_URL`（默认 `postgres://postgres@127.0.0.1:5433/escort_test`），每个测试文件都会清库，别指向正式库：

```bash
TEST_DATABASE_URL=postgres://postgres@127.0.0.1:5432/escort_test npm test
```

开发环境下验证码打印在日志里，推送只记录不发送。生产需要配好 `.env.example` 里的 JWT、手机号加密密钥、阿里云短信（只用于登录验证码）、APNs key 和微信开放平台参数。

接口都在 `/v1` 下，见 `backend/src/http/routes.ts`。实时位置走 WebSocket `/v1/ws`。邀请落地页是 `/i/:token`，没装 App 时显示 TestFlight 链接和 6 位邀请码；`/.well-known/apple-app-site-association` 用于通用链接。

## iOS 和 Apple Watch

需要 Xcode 16、iOS 17 / watchOS 10。

```bash
brew install xcodegen
cd ios
xcodegen generate
open NightEscort.xcodeproj
```

后端地址和邀请域名在 `ios/project.yml` 的 `API_BASE_URL`、`INVITE_HOST` 里改。真机运行要在工程里填自己的开发者团队。紧急提醒（critical alerts）需要先向 Apple 申请权限，拿到后在 entitlements 里加 `com.apple.developer.usernotifications.critical-alerts`；没申请到时自动降级为“时效性通知 + 闹铃声”。

共享包测试：

```bash
cd ios/Packages/EscortKit && swift test
```

## CI

`.github/workflows/backend.yml` 在 Ubuntu 上起 Postgres 跑后端类型检查和全部测试。`.github/workflows/ios.yml` 在 macOS 上跑 EscortKit 测试，再用 XcodeGen 生成工程，分别编译 iPhone App（含小组件）和手表 App，不签名。

## 还没做的

App 图标、微信登录 SDK 接入（现在是占位）、运营后台。
