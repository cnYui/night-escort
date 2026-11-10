/**
 * 对着真正跑起来的后端走一遍第一版 MVP：两个人互加好友、开始回家、报平安、漏报后通知守护人、
 * 守护人接手并确认安全、一键求救、结束。顺带检查守护人的 WebSocket 能收到 refresh。
 *
 * 后端要用这两个环境变量启动：
 *   SMS_TEST_NUMBERS=+86199000*  SMS_TEST_CODE=246810  DEV_TOOLS=true
 * 运行：BASE_URL=http://127.0.0.1:8090 npx tsx scripts/mvp-smoke.ts
 */
import WebSocket from 'ws';

const BASE = process.env.BASE_URL ?? 'http://127.0.0.1:8090';
const CODE = process.env.SMS_TEST_CODE ?? '246810';
const run = Date.now().toString().slice(-4);

type User = { id: string; name: string; token: string; refresh: string };

async function api(u: User | null, method: string, path: string, body?: unknown, expect = 200): Promise<any> {
  const res = await fetch(BASE + path, {
    method,
    headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...(u ? { authorization: `Bearer ${u.token}` } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  // 拨了时钟以后访问令牌会过期，和 App 一样用刷新令牌换一个再试
  if (res.status === 401 && u && expect !== 401) {
    const t = await api(null, 'POST', '/v1/auth/refresh', { refresh_token: u.refresh });
    u.token = t.access_token;
    u.refresh = t.refresh_token;
    return api(u, method, path, body, expect);
  }
  if (res.status !== expect) throw new Error(`${method} ${path} → ${res.status}（期望 ${expect}）：${text}`);
  return text ? JSON.parse(text) : null;
}

function check(cond: unknown, what: string) {
  if (!cond) throw new Error(`没通过：${what}`);
  console.log(`  ✓ ${what}`);
}

async function signup(name: string, n: number): Promise<User> {
  const phone = `199000${run}${n}`;
  await api(null, 'POST', '/v1/auth/sms/send', { phone });
  const r1 = await api(null, 'POST', '/v1/auth/sms/login', { phone, code: CODE, device: { kind: 'iphone' } });
  const r2 = await api(null, 'POST', '/v1/auth/signup', { signup_ticket: r1.signup_ticket, password: 'night2026', display_name: name, device: { kind: 'iphone' } });
  const u = { id: r2.user.id, name, token: r2.tokens.access_token, refresh: r2.tokens.refresh_token };
  await api(u, 'PUT', '/v1/devices/current', { notif_allowed: true, opened: true });
  return u;
}

/** 守护人一直开着的事件通道，记下收到的 refresh */
function events(u: User): { got: { what: string; owner_id: string }[]; close: () => void; ready: Promise<void> } {
  const got: { what: string; owner_id: string }[] = [];
  const ws = new WebSocket(`${BASE.replace(/^http/, 'ws')}/v1/ws?access_token=${u.token}`);
  ws.on('message', (raw) => {
    const m = JSON.parse(String(raw));
    if (m.type === 'refresh') got.push(m);
  });
  const ready = new Promise<void>((resolve, reject) => {
    ws.on('open', () => resolve());
    ws.on('error', reject);
  });
  return { got, close: () => ws.close(), ready };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  console.log(`后端 ${BASE}`);
  const health = await api(null, 'GET', '/healthz');
  check(health.ok, '健康检查正常');

  console.log('注册和加好友');
  const lin = await signup(`小林${run}`, 1);
  const ke = await signup(`阿珂${run}`, 2);
  check(lin.id && ke.id, '两个人用测试号码注册成功');
  const inv = await api(lin, 'POST', '/v1/invites', { kind: 'standing' });
  const pv = await api(ke, 'GET', `/v1/invites/preview?token=${inv.token}`);
  check(pv.state === 'ok' || pv.headline, `阿珂扫码看到“${pv.headline}”`);
  await api(ke, 'POST', '/v1/invites/accept', { token: inv.token, relation: '室友', tier: 'standing', mutual: true });
  const linConns = await api(lin, 'GET', '/v1/connections');
  const row = linConns.find((c: any) => c.peer.id === ke.id);
  check(row?.guards_me && row?.i_guard, '互相守护：两边都能选对方');

  console.log('开始回家');
  const ev = events(ke);
  await ev.ready;
  const opts = await api(lin, 'GET', '/v1/escorts/start-options');
  check(opts.candidates.some((c: any) => c.guardian.id === ke.id), '开始页能选到阿珂');
  let e = await api(lin, 'POST', '/v1/escorts', { guardian_ids: [ke.id], interval_min: 15, started_from: 'phone', destination_label: '家' });
  check(e.status === 'active', '出发成功');
  await sleep(300);
  check(ev.got.some((m) => m.owner_id === lin.id), '阿珂的实时通道收到“小林出发了”');
  let cards = (await api(ke, 'GET', '/v1/guarding')).cards;
  check(cards.some((c: any) => c.owner.id === lin.id && c.status === 'active'), '阿珂的“我守护的人”里有小林');
  // 用服务器的时间：之前跑过的话服务器时钟可能已经拨过
  const serverNow = (await api(null, 'GET', '/v1/dev/clock')).now;
  await api(lin, 'POST', `/v1/escorts/${e.id}/points`, {
    idempotency_key: `smoke-${run}`,
    points: [{ recorded_at: serverNow, lat: 31.2304, lng: 121.4737, h_acc_m: 20, battery_pct: 60, source: 'phone' }],
  });
  const loc = await api(ke, 'GET', `/v1/people/${lin.id}/location`);
  check(Math.abs(loc.point.lat - 31.2304) < 1e-6, '阿珂看得到小林的位置');

  console.log('报平安和漏报');
  e = await api(lin, 'POST', `/v1/escorts/${e.id}/checkin`, { action: 'ok', channel: 'app' });
  check(e.status === 'active', '报平安后倒计时重新开始');
  ev.got.length = 0;
  await api(null, 'POST', '/v1/dev/clock/advance', { minutes: 26 });
  e = (await api(lin, 'GET', '/v1/escorts/current')).escort;
  check(e.status === 'alerting', '漏报 10 分钟后进入“联系不上”');
  cards = (await api(ke, 'GET', '/v1/guarding')).cards;
  const card = cards.find((c: any) => c.owner.id === lin.id);
  check(card?.status === 'alerting' && card.incident?.id, '阿珂这边出现联系不上的提醒');
  await sleep(300);
  check(ev.got.some((m) => m.what === 'incident_changed'), '阿珂的实时通道收到 incident_changed');
  const seen = await api(ke, 'POST', `/v1/incidents/${card.incident.id}/seen`);
  check(seen.contacting_by_me, '阿珂点开后由她接手');
  await api(ke, 'POST', `/v1/incidents/${card.incident.id}/confirm-safe`, { via: 'phone' });
  e = (await api(lin, 'GET', '/v1/escorts/current')).escort;
  check(e.status === 'active', '阿珂确认安全后小林回到回家路上');

  console.log('一键求救');
  e = await api(lin, 'POST', '/v1/sos', { from: 'phone' });
  check(e.status === 'alerting' && e.incident?.kind === 'sos', '求救发出');
  cards = (await api(ke, 'GET', '/v1/guarding')).cards;
  check(cards.find((c: any) => c.owner.id === lin.id)?.incident?.kind === 'sos', '阿珂这边显示求救');
  const inc = cards.find((c: any) => c.owner.id === lin.id).incident;
  await api(ke, 'POST', `/v1/incidents/${inc.id}/seen`);
  await api(ke, 'POST', `/v1/incidents/${inc.id}/confirm-safe`, { via: 'phone' });

  console.log('结束');
  e = await api(lin, 'POST', `/v1/escorts/${e.id}/end`, { reason: 'manual' });
  check(e.status === 'ended', '小林结束这次回家');
  check((await api(lin, 'GET', '/v1/escorts/current')).escort === null, '没有进行中的回家了');
  ev.close();
  console.log('全部通过');
}

main().catch((err) => {
  console.error(String(err));
  process.exit(1);
});
