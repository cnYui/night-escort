-- 邀请只保留二维码和链接（2026-11-09 用户定），去掉 6 位邀请码
DROP INDEX IF EXISTS invites_live_code;
ALTER TABLE invites DROP COLUMN IF EXISTS code;
