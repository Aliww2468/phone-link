#!/usr/bin/env node
/*
 * PhoneLink - PC receiver.
 *
 * Listens for messages pushed by the phone over the LAN, stores them in SQLite,
 * prints them to the console, mirrors them to a plain-text log, serves a small
 * web UI and (optionally) raises a Windows toast.
 *
 * Zero npm dependencies: only Node's standard library.
 */

'use strict';

const http = require('node:http');
const dgram = require('node:dgram');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

// ------------------------------------------------------------------ paths
const ROOT = __dirname;
const DATA_DIR = path.join(ROOT, 'data');
const CONFIG_PATH = path.join(ROOT, 'config.json');
const DB_PATH = path.join(DATA_DIR, 'messages.db');
const LOG_PATH = path.join(DATA_DIR, 'messages.log');
const PUBLIC_DIR = path.join(ROOT, 'public');

fs.mkdirSync(DATA_DIR, { recursive: true });

// ------------------------------------------------------------------ config
const DEFAULTS = {
  port: 8787,
  discoveryPort: 8788,
  token: '',
  toast: true,
  openBrowser: true,
  maxBodyBytes: 5 * 1024 * 1024,
};

function loadConfig() {
  let cfg = { ...DEFAULTS };
  if (fs.existsSync(CONFIG_PATH)) {
    try {
      cfg = { ...cfg, ...JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')) };
    } catch (e) {
      console.error('[warn] config.json is not valid JSON, using defaults:', e.message);
    }
  }
  if (!cfg.token) {
    cfg.token = crypto.randomBytes(3).toString('hex').toUpperCase();
    console.log('[init] generated pairing token: ' + cfg.token);
  }
  try {
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2), 'utf8');
  } catch (e) {
    console.error('[warn] cannot write config.json:', e.message);
  }
  return cfg;
}

const cfg = loadConfig();

// ------------------------------------------------------------------ storage
let db = null;
try {
  const { DatabaseSync } = require('node:sqlite');
  db = new DatabaseSync(DB_PATH);
  db.exec(`
    CREATE TABLE IF NOT EXISTS messages (
      id       TEXT PRIMARY KEY,
      ts       INTEGER NOT NULL,
      received INTEGER NOT NULL,
      device   TEXT,
      kind     TEXT,
      pkg      TEXT,
      app      TEXT,
      title    TEXT,
      text     TEXT,
      sender   TEXT,
      slot     INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts DESC);
    CREATE TABLE IF NOT EXISTS devices (
      name     TEXT PRIMARY KEY,
      lastSeen INTEGER,
      battery  INTEGER,
      queued   INTEGER
    );
  `);
} catch (e) {
  console.error('[fatal] node:sqlite is unavailable: ' + e.message);
  console.error('        This build needs Node.js 22.5 or newer.');
  process.exit(1);
}

const stmtInsert = db.prepare(`
  INSERT OR IGNORE INTO messages (id, ts, received, device, kind, pkg, app, title, text, sender, slot)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
`);
const stmtDevice = db.prepare(`
  INSERT INTO devices (name, lastSeen, battery, queued)
  VALUES (?, ?, ?, ?)
  ON CONFLICT(name) DO UPDATE SET lastSeen=excluded.lastSeen, battery=excluded.battery, queued=excluded.queued
`);

let insertCount = 0;

function saveMessages(device, list) {
  const now = Date.now();
  let added = 0;
  db.exec('BEGIN');
  try {
    for (const m of list) {
      const id = String(m.id || crypto.randomUUID());
      const r = stmtInsert.run(
        id,
        Number(m.ts) || now,
        now,
        String(device || ''),
        String(m.kind || 'notif'),
        String(m.pkg || ''),
        String(m.app || ''),
        String(m.title || ''),
        String(m.text || ''),
        String(m.sender || ''),
        Number.isFinite(m.slot) ? m.slot : -1
      );
      if (r.changes > 0) {
        added++;
        emit(m, device);
        logLine(m, device);
      }
    }
    db.exec('COMMIT');
  } catch (e) {
    try { db.exec('ROLLBACK'); } catch { /* ignore */ }
    throw e;
  }
  insertCount += added;
  return added;
}

function logLine(m, device) {
  const d = new Date(Number(m.ts) || Date.now());
  const pad = (n) => String(n).padStart(2, '0');
  const stamp = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
                `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  const src = m.kind === 'sms' ? `短信 ${m.sender || ''}` : (m.app || m.pkg || '通知');
  const body = [m.title, m.text].filter(Boolean).join(' | ').replace(/\s*\n\s*/g, ' ⏎ ');
  const line = `${stamp} [${src}] ${body}${device ? `  <${device}>` : ''}`;
  try { fs.appendFileSync(LOG_PATH, line + os.EOL, 'utf8'); } catch { /* ignore */ }
  return line;
}

// ------------------------------------------------------------------ live feed (SSE)
const sseClients = new Set();

function emit(m, device) {
  const payload = JSON.stringify({ type: 'message', device: device || '', message: m });
  for (const res of sseClients) {
    try { res.write(`data: ${payload}\n\n`); } catch { /* ignore */ }
  }
}

function emitDevice(name, battery, queued) {
  const payload = JSON.stringify({ type: 'heartbeat', name, battery, queued, ts: Date.now() });
  for (const res of sseClients) {
    try { res.write(`data: ${payload}\n\n`); } catch { /* ignore */ }
  }
}

// ------------------------------------------------------------------ console + toast
const C = {
  reset: '\x1b[0m', dim: '\x1b[2m', bold: '\x1b[1m',
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m', cyan: '\x1b[36m', magenta: '\x1b[35m',
};

function consoleShow(m, device) {
  const d = new Date(Number(m.ts) || Date.now());
  const pad = (n) => String(n).padStart(2, '0');
  const stamp = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  const src = m.kind === 'sms' ? `${C.green}SMS${C.reset}` : `${C.magenta}${m.app || m.pkg}${C.reset}`;
  const who = m.kind === 'sms' ? (m.sender || '') : (m.title || '');
  console.log(
    `${C.dim}${stamp}${C.reset} ${src} ${C.bold}${who}${C.reset}  ` +
    `${String(m.text || '').replace(/\n/g, ' ⏎ ')}`
  );
}

let toastBusy = false;
const toastQueue = [];

function toast(title, text) {
  if (!cfg.toast) return;
  toastQueue.push([String(title || ''), String(text || '')]);
  pumpToast();
}

function pumpToast() {
  if (toastBusy || toastQueue.length === 0) return;
  const [title, text] = toastQueue.shift();
  toastBusy = true;
  const script = [
    '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] > $null',
    '[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] > $null',
    '$t = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)',
    "$n = $t.GetElementsByTagName('text')",
    '$n.Item(0).AppendChild($t.CreateTextNode($env:PL_TITLE)) > $null',
    '$n.Item(1).AppendChild($t.CreateTextNode($env:PL_TEXT)) > $null',
    '$toast = [Windows.UI.Notifications.ToastNotification]::new($t)',
    "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('PhoneLink').Show($toast)",
  ].join('; ');

  let child;
  try {
    child = spawn('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', script],
      {
        env: { ...process.env, PL_TITLE: title.slice(0, 120), PL_TEXT: text.slice(0, 400) },
        detached: true, stdio: 'ignore', windowsHide: true,
      });
  } catch {
    toastBusy = false;
    return;
  }
  const done = () => {
    toastBusy = false;
    setTimeout(pumpToast, 250);
  };
  child.on('error', done);
  child.on('exit', done);
}

// ------------------------------------------------------------------ network helpers
function lanAddresses() {
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const a of ifaces[name] || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (a.address.startsWith('169.254.')) continue;
      out.push({ name, address: a.address });
    }
  }
  const score = (ip) =>
    ip.startsWith('192.168.') ? 0 :
    ip.startsWith('10.') ? 1 :
    /^172\.(1[6-9]|2\d|3[01])\./.test(ip) ? 2 : 3;
  out.sort((a, b) => score(a.address) - score(b.address));
  return out;
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

// ------------------------------------------------------------------ HTTP
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function json(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function authorized(req) {
  if (!cfg.token) return true;
  const t = req.headers['x-token'];
  return typeof t === 'string' && safeEqual(t, cfg.token);
}

function serveFile(res, file, type) {
  fs.readFile(file, (err, buf) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': type + '; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(buf);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  try {
    // --- static UI
    if (req.method === 'GET' && (p === '/' || p === '/index.html')) {
      return serveFile(res, path.join(PUBLIC_DIR, 'index.html'), 'text/html');
    }

    // --- ingest
    if (req.method === 'POST' && p === '/api/messages') {
      if (!authorized(req)) {
        console.log(`${C.red}[reject]${C.reset} bad token from ${req.socket.remoteAddress}`);
        return json(res, 401, { ok: false, error: 'bad token' });
      }
      const raw = await readBody(req, cfg.maxBodyBytes);
      let data;
      try {
        data = JSON.parse(raw);
      } catch {
        return json(res, 400, { ok: false, error: 'invalid json' });
      }
      const list = Array.isArray(data.messages) ? data.messages : [];
      const added = saveMessages(data.device, list);
      if (added > 0) {
        for (const m of list) consoleShow(m, data.device);
      }
      return json(res, 200, { ok: true, accepted: list.length, stored: added });
    }

    // --- heartbeat / connection test
    if (req.method === 'POST' && p === '/api/heartbeat') {
      if (!authorized(req)) return json(res, 401, { ok: false, error: 'bad token' });
      const raw = await readBody(req, 64 * 1024);
      let d = {};
      try { d = JSON.parse(raw); } catch { /* ignore */ }
      const name = String(d.device || 'unknown');
      if (d.test) {
        console.log(`${C.green}[test]${C.reset} ${name} connected successfully`);
      } else {
        const battery = Number.isFinite(d.battery) ? d.battery : -1;
        const queued = Number.isFinite(d.queued) ? d.queued : 0;
        stmtDevice.run(name, Date.now(), battery, queued);
        emitDevice(name, battery, queued);
        console.log(`${C.dim}[beat]${C.reset} ${name} battery=${battery < 0 ? '?' : battery + '%'} queued=${queued}`);
      }
      return json(res, 200, { ok: true, server: os.hostname(), token: d.test ? undefined : undefined });
    }

    // --- history
    if (req.method === 'GET' && p === '/api/history') {
      const limit = Math.min(Number(url.searchParams.get('limit')) || 200, 2000);
      const q = (url.searchParams.get('q') || '').trim();
      const kind = url.searchParams.get('kind') || '';
      const app = url.searchParams.get('app') || '';

      const where = [];
      const args = [];
      if (q) {
        where.push('(title LIKE ? OR text LIKE ? OR sender LIKE ? OR app LIKE ?)');
        const like = '%' + q + '%';
        args.push(like, like, like, like);
      }
      if (kind) { where.push('kind = ?'); args.push(kind); }
      if (app) { where.push('app = ?'); args.push(app); }
      const sql = 'SELECT * FROM messages' +
        (where.length ? ' WHERE ' + where.join(' AND ') : '') +
        ' ORDER BY ts DESC LIMIT ?';
      args.push(limit);
      const rows = db.prepare(sql).all(...args);
      return json(res, 200, { ok: true, count: rows.length, messages: rows });
    }

    // --- stats
    if (req.method === 'GET' && p === '/api/status') {
      const total = db.prepare('SELECT COUNT(*) AS n FROM messages').get().n;
      const today = db.prepare('SELECT COUNT(*) AS n FROM messages WHERE ts >= ?')
        .get(new Date().setHours(0, 0, 0, 0)).n;
      const devices = db.prepare('SELECT * FROM devices ORDER BY lastSeen DESC').all();
      const apps = db.prepare('SELECT app, COUNT(*) AS n FROM messages GROUP BY app ORDER BY n DESC LIMIT 30').all();
      return json(res, 200, {
        ok: true, total, today, devices, apps,
        server: os.hostname(), port: cfg.port, addresses: lanAddresses(),
        logPath: LOG_PATH,
      });
    }

    // --- live feed
    if (req.method === 'GET' && p === '/api/stream') {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });
      res.write(': connected\n\n');
      sseClients.add(res);
      const ka = setInterval(() => {
        try { res.write(': ka\n\n'); } catch { /* ignore */ }
      }, 25000);
      req.on('close', () => {
        clearInterval(ka);
        sseClients.delete(res);
      });
      return;
    }

    // --- export
    if (req.method === 'GET' && p === '/api/export') {
      const rows = db.prepare('SELECT * FROM messages ORDER BY ts ASC').all();
      const lines = rows.map((m) => {
        const d = new Date(m.ts);
        const src = m.kind === 'sms' ? `短信 ${m.sender || ''}` : (m.app || m.pkg || '');
        const body = [m.title, m.text].filter(Boolean).join(' | ').replace(/\s*\n\s*/g, ' ⏎ ');
        return `${d.toLocaleString('sv-SE')}\t${src}\t${body}`;
      });
      const buf = Buffer.from('\ufeff' + lines.join('\r\n'), 'utf8');
      res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Disposition': 'attachment; filename="phonelink-history.txt"',
        'Content-Length': buf.length,
      });
      return res.end(buf);
    }

    json(res, 404, { ok: false, error: 'not found' });
  } catch (e) {
    console.error(`${C.red}[error]${C.reset} ${req.method} ${p}: ${e.message}`);
    if (!res.headersSent) json(res, 500, { ok: false, error: e.message });
  }
});

server.on('clientError', (err, socket) => {
  try { socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); } catch { /* ignore */ }
});

// ------------------------------------------------------------------ UDP discovery
const udp = dgram.createSocket({ type: 'udp4', reuseAddr: true });

udp.on('message', (msg, rinfo) => {
  if (msg.toString('utf8').trim() !== 'PHONELINK_DISCOVER_V1') return;
  const reply = Buffer.from(`PHONELINK|${cfg.port}|${os.hostname()}`, 'utf8');
  udp.send(reply, rinfo.port, rinfo.address, (err) => {
    if (!err) console.log(`${C.dim}[discover]${C.reset} answered ${rinfo.address}`);
  });
});

udp.on('error', (err) => {
  console.error(`${C.yellow}[warn]${C.reset} discovery socket: ${err.message}`);
});

// ------------------------------------------------------------------ start
function banner() {
  const addrs = lanAddresses();
  const line = '─'.repeat(58);
  console.log('');
  console.log(`${C.cyan}${line}${C.reset}`);
  console.log(`  ${C.bold}PhoneLink 电脑接收端已启动${C.reset}`);
  console.log(`${C.cyan}${line}${C.reset}`);
  console.log(`  本机名称 : ${os.hostname()}`);
  if (addrs.length === 0) {
    console.log(`  ${C.yellow}未检测到局域网 IP，请确认已连接 WiFi/网线${C.reset}`);
  }
  for (const a of addrs) {
    console.log(`  手机填的 IP : ${C.green}${C.bold}${a.address}${C.reset}   ${C.dim}(${a.name})${C.reset}`);
  }
  console.log(`  端口      : ${C.green}${cfg.port}${C.reset}`);
  console.log(`  配对令牌  : ${C.yellow}${C.bold}${cfg.token}${C.reset}   ${C.dim}(手机端留空也能用)${C.reset}`);
  console.log(`  网页查看  : ${C.cyan}http://127.0.0.1:${cfg.port}/${C.reset}`);
  console.log(`  日志文件  : ${LOG_PATH}`);
  console.log(`${C.cyan}${line}${C.reset}`);
  console.log(`  ${C.dim}等待手机推送消息…（Ctrl+C 退出）${C.reset}`);
  console.log('');
}

server.listen(cfg.port, '0.0.0.0', () => {
  banner();
  try {
    udp.bind(cfg.discoveryPort, () => {
      try { udp.setBroadcast(true); } catch { /* ignore */ }
    });
  } catch (e) {
    console.error(`${C.yellow}[warn]${C.reset} cannot bind discovery port ${cfg.discoveryPort}: ${e.message}`);
  }

  if (cfg.openBrowser && process.env.PHONELINK_NO_BROWSER !== '1') {
    const url = `http://127.0.0.1:${cfg.port}/`;
    try {
      spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
    } catch { /* ignore */ }
  }
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error(`${C.red}[fatal]${C.reset} 端口 ${cfg.port} 已被占用。`);
    console.error('        可能是 PhoneLink 已经在运行（看任务栏/托盘）。');
    console.error(`        或者修改 ${CONFIG_PATH} 里的 port 后重试。`);
  } else {
    console.error(`${C.red}[fatal]${C.reset} ${e.message}`);
  }
  process.exit(1);
});

process.on('uncaughtException', (e) => {
  console.error(`${C.red}[uncaught]${C.reset} ${e && e.stack ? e.stack : e}`);
});

process.on('SIGINT', () => {
  console.log('\n[bye] 已停止。');
  process.exit(0);
});
