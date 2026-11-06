-- 一键求救：事件分两种，漏签到（missed）和她主动求救（sos）
ALTER TABLE incidents ADD COLUMN kind text NOT NULL DEFAULT 'missed' CHECK (kind IN ('missed', 'sos'));

ALTER TABLE incident_actions DROP CONSTRAINT incident_actions_action_check;
ALTER TABLE incident_actions ADD CONSTRAINT incident_actions_action_check
  CHECK (action IN ('seen', 'contacting', 'confirmed_safe', 'unreachable', 'snoozed', 'self_ok', 'paused', 'ended', 'sos', 'called'));
