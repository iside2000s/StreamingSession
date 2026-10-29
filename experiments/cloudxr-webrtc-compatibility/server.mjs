import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const [site, state] = process.argv.slice(2);
if (!site || !state) throw new Error('Supply the site and state directories');
const files = new Map([['/', ['index.html', 'text/html; charset=utf-8']], ['/bundle.js', ['bundle.js', 'text/javascript']]]);
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (req.method === 'POST' && url.pathname === '/telemetry') {
    let body = '';
    req.on('data', bytes => { body += bytes; if (body.length > 32768) req.destroy(); });
    req.on('end', () => {
      try {
        const value = JSON.parse(body);
        if (value.seat !== 'a' && value.seat !== 'b') throw new Error('Invalid seat');
        fs.writeFileSync(path.join(state, `${value.seat}.json`), JSON.stringify({...value, receivedUtc: new Date().toISOString()}));
        res.writeHead(204).end();
      } catch { res.writeHead(400).end(); }
    });
    return;
  }
  const entry = files.get(url.pathname);
  if (!entry || req.method !== 'GET') { res.writeHead(404).end(); return; }
  res.writeHead(200, {'Content-Type': entry[1], 'Cache-Control': 'no-store'});
  fs.createReadStream(path.join(site, entry[0])).pipe(res);
});
server.listen(55300, '127.0.0.1', () => console.log('READY http://127.0.0.1:55300/?seat=a'));
setTimeout(() => server.close(), 15 * 60 * 1000);
