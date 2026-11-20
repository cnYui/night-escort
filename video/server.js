// 静态文件服务：渲染页面和素材。截图、App 图标直接用仓库里的原文件，不另存副本。
const http = require('http'), fs = require('fs'), path = require('path');
const root = __dirname;
const repo = path.resolve(root, '..');
const alias = [
  ['/assets/screens/', path.join(repo, 'design/screens/app/')],
  ['/assets/AppIcon-1024.png', path.join(repo, 'ios/NightEscort/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')],
];
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg', '.json': 'application/json', '.glb': 'model/gltf-binary', '.woff2': 'font/woff2', '.woff': 'font/woff', '.bin': 'application/octet-stream', '.webp': 'image/webp' };

function resolve(url) {
  const u = decodeURIComponent(url.split('?')[0]);
  for (const [from, to] of alias) {
    if (from.endsWith('/') ? u.startsWith(from) : u === from) return from.endsWith('/') ? path.join(to, u.slice(from.length)) : to;
  }
  const p = path.join(root, u);
  return p.startsWith(root) ? p : null;
}

function start(port = +(process.env.PORT || 8777)) {
  return new Promise((ok) => {
    const srv = http.createServer((req, res) => {
      const p = resolve(req.url);
      if (!p) { res.writeHead(403); return res.end(); }
      fs.readFile(p, (err, data) => {
        if (err) { res.writeHead(404); return res.end('not found'); }
        res.writeHead(200, { 'Content-Type': types[path.extname(p).toLowerCase()] || 'application/octet-stream' });
        res.end(data);
      });
    });
    srv.listen(port, '127.0.0.1', () => ok(srv));
  });
}

module.exports = { start };
if (require.main === module) start().then((s) => console.log('http://127.0.0.1:' + s.address().port));
