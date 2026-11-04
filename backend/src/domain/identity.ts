/** 手机号和密码规则（设计文档第 9 节）。 */

/** 规范成 E.164。第一版只支持中国大陆 11 位手机号。 */
export function normalizePhone(input: string): string | null {
  const digits = input.replace(/[\s-]/g, '');
  const m = /^(?:\+?86)?(1[3-9]\d{9})$/.exec(digits);
  return m ? `+86${m[1]}` : null;
}

/** 至少 8 位，含字母和数字。 */
export function passwordProblem(pw: string): string | null {
  if (pw.length < 8) return '密码至少 8 位';
  if (pw.length > 128) return '密码太长';
  if (!/[A-Za-z]/.test(pw) || !/\d/.test(pw)) return '密码要同时包含字母和数字';
  return null;
}

export function maskPhone(e164: string): string {
  const local = e164.replace(/^\+86/, '');
  return `${local.slice(0, 3)}****${local.slice(7)}`;
}
