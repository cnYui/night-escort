-- 夜归护航 · 初始数据库结构
-- 对应设计文档第 5 节、6.5 节和 9.4 节。
-- 三层关系：connections（连接，对称）→ guardian_grants（担保授权，有向）→ escort_guardians（本次名单）。
-- 家的坐标不在服务端，没有对应的表。

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- UUID v7：按时间有序，主键统一用它
CREATE OR REPLACE FUNCTION uuid_v7() RETURNS uuid AS $$
DECLARE
  ts_ms bigint := floor(extract(epoch FROM clock_timestamp()) * 1000);
  b bytea := gen_random_bytes(16);
BEGIN
  b := set_byte(b, 0, ((ts_ms >> 40) & 255)::int);
  b := set_byte(b, 1, ((ts_ms >> 32) & 255)::int);
  b := set_byte(b, 2, ((ts_ms >> 24) & 255)::int);
  b := set_byte(b, 3, ((ts_ms >> 16) & 255)::int);
  b := set_byte(b, 4, ((ts_ms >> 8) & 255)::int);
  b := set_byte(b, 5, (ts_ms & 255)::int);
  b := set_byte(b, 6, ((get_byte(b, 6) & 15) | 112));  -- version 7
  b := set_byte(b, 8, ((get_byte(b, 8) & 63) | 128));  -- variant
  RETURN encode(b, 'hex')::uuid;
END $$ LANGUAGE plpgsql VOLATILE;

-- ───────────── 5.1 账号与设备 ─────────────

CREATE TABLE users (
  id                  uuid PRIMARY KEY DEFAULT uuid_v7(),
  display_name        text NOT NULL,
  avatar_url          text,
  phone_enc           text NOT NULL,          -- 加密存储（AES-256-GCM）
  phone_hash          text NOT NULL UNIQUE,   -- 一号一账号；不建搜索
  password_hash       text NOT NULL,          -- Argon2id，每个账号必须有密码
  password_updated_at timestamptz NOT NULL DEFAULT now(),
  time_zone           text NOT NULL DEFAULT 'Asia/Shanghai',
  created_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz
);

CREATE TABLE user_identities (
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider     text NOT NULL CHECK (provider IN ('wechat', 'apple')),
  provider_uid text NOT NULL,                 -- 微信用 unionid，Apple 用 sub
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, provider),
  UNIQUE (provider, provider_uid)
);

CREATE TABLE devices (
  id                  uuid PRIMARY KEY DEFAULT uuid_v7(),
  user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind                text NOT NULL CHECK (kind IN ('iphone', 'watch')),
  apns_token          text,
  apns_env            text NOT NULL DEFAULT 'production' CHECK (apns_env IN ('sandbox', 'production')),
  live_activity_token text,
  app_version         text,
  notif_allowed       boolean NOT NULL DEFAULT false,
  critical_allowed    boolean NOT NULL DEFAULT false,
  last_opened_at      timestamptz,
  last_seen_at        timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_user ON devices(user_id);

-- 每台设备一个可吊销的刷新令牌
CREATE TABLE refresh_tokens (
  id          uuid PRIMARY KEY DEFAULT uuid_v7(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  token_hash  text NOT NULL UNIQUE,
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ───────────── 5.2 关系与授权 ─────────────

CREATE TABLE invites (
  id             uuid PRIMARY KEY DEFAULT uuid_v7(),
  token          text NOT NULL UNIQUE,          -- 链接 /i/<token>，二维码就是这条链接
  code           text NOT NULL,                 -- 6 位数字短形式
  inviter_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind           text NOT NULL CHECK (kind IN ('standing', 'temporary')),
  grant_template jsonb NOT NULL,                -- 临时邀请的权限在这里定好
  expires_at     timestamptz NOT NULL,
  scanned_by     uuid REFERENCES users(id) ON DELETE SET NULL,
  scanned_at     timestamptz,
  consumed_by    uuid REFERENCES users(id) ON DELETE SET NULL,
  consumed_at    timestamptz,
  revoked_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
-- 同一时刻一个 6 位码只对应一条可用邀请
CREATE UNIQUE INDEX invites_live_code ON invites(code) WHERE consumed_at IS NULL AND revoked_at IS NULL;

CREATE TABLE connections (
  id               uuid PRIMARY KEY DEFAULT uuid_v7(),
  user_lo          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_hi          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'removed')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  removed_at       timestamptz,
  removed_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  last_together_at timestamptz,                 -- 驱动图谱淡出
  CHECK (user_lo < user_hi),
  UNIQUE (user_lo, user_hi)
);

CREATE TABLE contact_labels (
  owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  peer_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  relation text,
  nickname text,
  PRIMARY KEY (owner_id, peer_id)
);

CREATE TABLE guardian_grants (
  id               uuid PRIMARY KEY DEFAULT uuid_v7(),
  owner_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- 出行者（被守护的人）
  guardian_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- 担保人
  tier             text NOT NULL CHECK (tier IN ('standing', 'temporary')),
  location_scope   text NOT NULL CHECK (location_scope IN ('live', 'alert_only')),
  notify_start_end boolean NOT NULL DEFAULT true,
  valid_until      timestamptz,                 -- 按时间失效（明早 6:00 / 7 天）
  bind_to_escort   boolean NOT NULL DEFAULT false, -- “这次护航结束时”
  bound_escort_id  uuid,                        -- 绑定到的护航，开始护航时填
  bind_deadline_at timestamptz,                 -- 24 小时内没开始护航就作废
  on_expire        text NOT NULL DEFAULT 'remove' CHECK (on_expire IN ('remove', 'keep')),
  first_used_at    timestamptz,                 -- 临时授权只在第一次默认勾选
  expire_warned_at timestamptz,                 -- 提前 10 分钟提示过
  expired_at       timestamptz,                 -- 清理任务确认过期并处理完的时间
  revoked_at       timestamptz,
  revoked_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (owner_id <> guardian_id),
  CHECK (tier = 'standing' OR valid_until IS NOT NULL OR bind_to_escort)
);
-- 每个方向同一时刻最多一条有效授权
CREATE UNIQUE INDEX grants_one_live ON guardian_grants(owner_id, guardian_id)
  WHERE revoked_at IS NULL AND expired_at IS NULL;
CREATE INDEX grants_guardian ON guardian_grants(guardian_id) WHERE revoked_at IS NULL AND expired_at IS NULL;

-- ───────────── 5.3 护航、签到、事件 ─────────────

CREATE TABLE escorts (
  id                uuid PRIMARY KEY DEFAULT uuid_v7(),
  owner_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status            text NOT NULL CHECK (status IN ('active', 'alerting', 'paused', 'ended')),
  interval_min      int  NOT NULL CHECK (interval_min IN (15, 30, 60)),
  started_at        timestamptz NOT NULL DEFAULT now(),
  started_from      text NOT NULL CHECK (started_from IN ('phone', 'watch')),
  destination_label text,                        -- “今晚回哪”的名字，坐标只存本机
  stage             text NOT NULL DEFAULT 'waiting' CHECK (stage IN ('waiting', 'due', 'reminded', 'escalated')),
  cycle_due_at      timestamptz NOT NULL,        -- 本周期应签到的时间
  last_checkin_at   timestamptz,
  next_deadline_at  timestamptz,                 -- 心跳引擎下一次要处理的时间
  paused_until      timestamptz,
  pause_prompted_at timestamptz,
  cap_prompted_at   timestamptz,                 -- 12 小时上限问过本人
  cap_notified_at   timestamptz,                 -- 12 小时上限通知过常驻担保人
  near_home_at      timestamptz,
  home_prompt_count int NOT NULL DEFAULT 0,
  ended_at          timestamptz,
  end_reason        text CHECK (end_reason IN ('manual', 'home', 'elsewhere', 'by_guardian', 'pause_timeout', 'no_guardian', 'account_deleted')),
  ended_by          uuid REFERENCES users(id) ON DELETE SET NULL,
  version           int NOT NULL DEFAULT 0
);
-- 一个人同时只有一次未结束的护航
CREATE UNIQUE INDEX escorts_one_open ON escorts(owner_id) WHERE status <> 'ended';
CREATE INDEX escorts_deadline ON escorts(next_deadline_at) WHERE next_deadline_at IS NOT NULL;

ALTER TABLE guardian_grants
  ADD CONSTRAINT grants_bound_escort_fk FOREIGN KEY (bound_escort_id) REFERENCES escorts(id) ON DELETE SET NULL;

CREATE TABLE escort_guardians (
  escort_id      uuid NOT NULL REFERENCES escorts(id) ON DELETE CASCADE,
  guardian_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  grant_id       uuid NOT NULL REFERENCES guardian_grants(id) ON DELETE CASCADE,
  scope_snapshot text NOT NULL,                  -- 只用于展示和审计，判定时仍回查 grant
  added_at       timestamptz NOT NULL DEFAULT now(),
  removed_at     timestamptz,
  last_viewed_at timestamptz,
  PRIMARY KEY (escort_id, guardian_id)
);
CREATE INDEX escort_guardians_guardian ON escort_guardians(guardian_id) WHERE removed_at IS NULL;

CREATE TABLE checkins (
  id           uuid PRIMARY KEY DEFAULT uuid_v7(),
  escort_id    uuid NOT NULL REFERENCES escorts(id) ON DELETE CASCADE,
  due_at       timestamptz NOT NULL,
  reminded_at  timestamptz,
  responded_at timestamptz,
  channel      text CHECK (channel IN ('watch', 'phone', 'notification', 'app')),
  result       text CHECK (result IN ('ok', 'missed')),
  UNIQUE (escort_id, due_at)
);

CREATE TABLE incidents (
  id                  uuid PRIMARY KEY DEFAULT uuid_v7(),
  escort_id           uuid NOT NULL REFERENCES escorts(id) ON DELETE CASCADE,
  opened_at           timestamptz NOT NULL DEFAULT now(),
  last_point_id       bigint,
  contacting_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  contacting_since    timestamptz,
  next_ring_at        timestamptz,               -- 下一轮响铃
  ring_round          int NOT NULL DEFAULT 0,
  closed_at           timestamptz,
  closed_by           uuid REFERENCES users(id) ON DELETE SET NULL,
  resolution          text CHECK (resolution IN ('self_ok', 'confirmed_safe', 'ended')),
  trail_visible_until timestamptz
);
-- 一次护航同一时刻最多一个开放事件
CREATE UNIQUE INDEX incidents_one_open ON incidents(escort_id) WHERE closed_at IS NULL;
CREATE INDEX incidents_ring ON incidents(next_ring_at) WHERE closed_at IS NULL;

-- 每位担保人在一次事件里的响铃状态（静音 5 分钟）
CREATE TABLE incident_guardians (
  incident_id   uuid NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  guardian_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  snoozed_until timestamptz,
  last_rung_at  timestamptz,
  seen_at       timestamptz,
  PRIMARY KEY (incident_id, guardian_id)
);

CREATE TABLE incident_actions (
  id          uuid PRIMARY KEY DEFAULT uuid_v7(),
  incident_id uuid NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  actor_id    uuid REFERENCES users(id) ON DELETE SET NULL,
  action      text NOT NULL CHECK (action IN ('seen', 'contacting', 'confirmed_safe', 'unreachable', 'snoozed', 'self_ok', 'paused', 'ended')),
  via         text CHECK (via IN ('wechat', 'phone', 'in_person', 'friend')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX incident_actions_incident ON incident_actions(incident_id);

-- ───────────── 5.4 位置与审计 ─────────────
-- 第一版用经纬度两列；服务端不做空间查询（到家判断在本机），以后要 PostGIS 再加 geography 列。

CREATE TABLE location_points (
  id          bigserial PRIMARY KEY,
  escort_id   uuid NOT NULL REFERENCES escorts(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  recorded_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  lat         double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng         double precision NOT NULL CHECK (lng BETWEEN -180 AND 180),
  h_acc_m     real NOT NULL,
  speed_mps   real,
  source      text NOT NULL CHECK (source IN ('phone', 'watch')),
  battery_pct smallint CHECK (battery_pct BETWEEN 0 AND 100),
  mode        text NOT NULL DEFAULT 'normal' CHECK (mode IN ('normal', 'alert'))
);
CREATE INDEX location_points_escort ON location_points(escort_id, recorded_at);

-- 位置批量上报的幂等键
CREATE TABLE point_batches (
  escort_id       uuid NOT NULL REFERENCES escorts(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL,
  accepted        int NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (escort_id, idempotency_key)
);

CREATE TABLE notifications (
  id              uuid PRIMARY KEY DEFAULT uuid_v7(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  escort_id       uuid REFERENCES escorts(id) ON DELETE CASCADE,
  incident_id     uuid REFERENCES incidents(id) ON DELETE CASCADE,
  kind            text NOT NULL,
  channel         text NOT NULL CHECK (channel IN ('apns', 'critical', 'watch', 'live_activity', 'inapp')),
  round           int NOT NULL DEFAULT 0,
  idempotency_key text NOT NULL UNIQUE,          -- 同一轮响铃不重发
  sent_at         timestamptz NOT NULL DEFAULT now(),
  delivered_at    timestamptz,
  opened_at       timestamptz,
  provider_ref    text,
  error           text
);
CREATE INDEX notifications_user ON notifications(user_id, sent_at DESC);

CREATE TABLE access_log (
  id        bigserial PRIMARY KEY,
  viewer_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  owner_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  escort_id uuid REFERENCES escorts(id) ON DELETE SET NULL,
  what      text NOT NULL CHECK (what IN ('live', 'trail', 'last')),
  at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX access_log_owner ON access_log(owner_id, at DESC);

-- 调度进程的存活心跳，超过 60 秒没跑就告警
CREATE TABLE scheduler_heartbeat (
  name   text PRIMARY KEY,
  ran_at timestamptz NOT NULL
);

CREATE TABLE schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
