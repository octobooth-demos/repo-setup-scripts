// Tiny static server for the booth: npm start [-- --open]   |   npm run stop
// Only one Booth Bingo server runs at a time: starting a new one stops the previous
// one (from any booth-bingo-xxxx clone), so the game is always at http://localhost:8080.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { spawn } from 'node:child_process';

const PORT = Number(process.env.PORT) || 8080;
const BASE = `http://localhost:${PORT}`;
const WHO = '/__booth-bingo-pid';
const ROOT = resolve('.');
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

// Ask whatever is on the port who it is; only a Booth Bingo server answers WHO.
async function stopPrevious() {
  let pid;
  try {
    const res = await fetch(BASE + WHO, { signal: AbortSignal.timeout(1000) });
    pid = res.ok ? Number(await res.text()) : 0;
  } catch {
    return false;
  }
  if (!pid || pid === process.pid) return false;
  try {
    process.kill(pid);
  } catch {
    return false;
  }
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 100));
    try { process.kill(pid, 0); } catch { return true; }
  }
  return true;
}

if (process.argv.includes('--stop')) {
  console.log((await stopPrevious()) ? 'Stopped the Booth Bingo server.' : 'No Booth Bingo server was running.');
  process.exit(0);
}

if (await stopPrevious()) console.log('Stopped the previous Booth Bingo server.');

const server = createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, BASE).pathname));
  if (path === WHO) {
    res.writeHead(200, { 'Content-Type': 'text/plain' }).end(String(process.pid));
    return;
  }
  const file = join(ROOT, path.endsWith(sep) || path.endsWith('/') ? join(path, 'index.html') : path);
  if (file !== ROOT && !file.startsWith(ROOT + sep)) {
    res.writeHead(403).end();
    return;
  }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(body);
  } catch {
    res.writeHead(404).end('Not found');
  }
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already used by another program (not a Booth Bingo server).`);
    console.error(process.platform === 'win32'
      ? `Find it with: netstat -ano | findstr :${PORT}`
      : `Find it with: lsof -i :${PORT}   (then close that terminal or kill the PID)`);
  } else {
    console.error(err.message);
  }
  process.exit(1);
});

server.listen(PORT, () => {
  console.log(`Booth Bingo (${ROOT}) is running at ${BASE}`);
  console.log('Stop it with Ctrl+C or "npm run stop".');
  if (process.argv.includes('--open')) {
    const [cmd, args] = process.platform === 'darwin' ? ['open', [BASE]]
      : process.platform === 'win32' ? ['cmd', ['/c', 'start', '', BASE]]
      : ['xdg-open', [BASE]];
    spawn(cmd, args, { stdio: 'ignore', detached: true }).on('error', () => {}).unref();
  }
});
