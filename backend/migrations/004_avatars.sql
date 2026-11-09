-- 头像（2026-11-09 用户要求「我的」页能换头像）。
-- App 先裁成正方形、缩到 512px 以内的 JPEG 再传，这里只存这一张。
-- 公开地址带随机串（/avatars/<token>.jpg），换一次头像换一个地址，旧地址立刻失效；删账号时一起删。
CREATE TABLE avatars (
  token        text PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  content_type text NOT NULL,
  data         bytea NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX avatars_user ON avatars (user_id);
