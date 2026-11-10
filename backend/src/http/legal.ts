/**
 * 用户协议和隐私政策的网页版：/legal/terms、/legal/privacy。
 * App Store Connect 和 TestFlight 外部测试要填隐私政策网址；App 里显示的是同一份文字（backend/legal/*.md 打进 App 包）。
 */
import { readFileSync } from 'node:fs';
import type { FastifyInstance } from 'fastify';

const DOCS = { terms: 'terms.md', privacy: 'privacy.md' } as const;

/** 源码在 src/http、编译后在 dist/http，往上两级都是 backend/，legal/ 在它下面 */
function load(name: string): string {
  return readFileSync(new URL(`../../legal/${name}`, import.meta.url), 'utf8');
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
const inline = (s: string) => esc(s).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');

/** 只认这两份文档用到的写法：# 标题、## 小标题、- 列表（可缩进一级）、**加粗**、空行分段 */
export function markdownToHtml(md: string): { title: string; html: string } {
  let title = '';
  const out: string[] = [];
  let list = 0;
  const closeLists = (to = 0) => {
    while (list > to) {
      out.push('</ul>');
      list--;
    }
  };
  for (const raw of md.split('\n')) {
    const line = raw.trimEnd();
    const item = /^(\s*)- (.*)$/.exec(line);
    if (item) {
      const depth = item[1]!.length >= 2 ? 2 : 1;
      while (list < depth) {
        out.push('<ul>');
        list++;
      }
      closeLists(depth);
      out.push(`<li>${inline(item[2]!)}</li>`);
      continue;
    }
    closeLists();
    if (line.startsWith('# ')) title = line.slice(2);
    else if (line.startsWith('## ')) out.push(`<h2>${inline(line.slice(3))}</h2>`);
    else if (line.trim()) out.push(`<p>${inline(line)}</p>`);
  }
  closeLists();
  return { title, html: out.join('\n') };
}

function page(title: string, body: string) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>
  body { margin: 0; background: #fff; color: #000; font: 16px/1.65 -apple-system, "PingFang SC", sans-serif; }
  main { max-width: 680px; margin: 0 auto; padding: 24px 20px 48px; }
  h1 { font-size: 26px; margin: 8px 0 4px; }
  h2 { font-size: 18px; margin: 28px 0 8px; }
  p, li { color: #1c1c1e; }
  ul { padding-left: 22px; }
  strong { font-weight: 600; }
  @media (prefers-color-scheme: dark) { body { background: #000; color: #fff; } p, li { color: #e5e5ea; } }
</style></head><body><main><h1>${esc(title)}</h1>
${body}
</main></body></html>`;
}

export function registerLegal(app: FastifyInstance) {
  for (const [slug, file] of Object.entries(DOCS)) {
    app.get(`/legal/${slug}`, async (_req, reply) => {
      const { title, html } = markdownToHtml(load(file));
      return reply.header('content-type', 'text/html; charset=utf-8').header('cache-control', 'public, max-age=300').send(page(title, html));
    });
  }
}
