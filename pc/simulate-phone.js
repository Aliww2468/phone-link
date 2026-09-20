#!/usr/bin/env node
/*
 * PhoneLink - fake phone.
 * Verifies the PC side without a real device: LAN discovery, heartbeat and a push.
 *   node pc/simulate-phone.js
 */

'use strict';

const dgram = require('node:dgram');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');

const ROOT = path.join(__dirname, '..');
const cfgPath = path.join(__dirname, 'config.json');
let cfg = { port: 8787, discoveryPort: 8788, token: '' };
if (fs.existsSync(cfgPath)) {
  cfg = { ...cfg, ...JSON.parse(fs.readFileSync(cfgPath, 'utf8')) };
}

function discover() {
  return new Promise((resolve) => {
    const s = dgram.createSocket('udp4');
    let done = false;
    const finish = (v) => { if (!done) { done = true; try { s.close(); } catch {} resolve(v); } };
    s.on('message', (msg, rinfo) => {
      const t = msg.toString('utf8').trim();
      if (t.startsWith('PHONELINK|')) finish({ ip: rinfo.address, port: Number(t.split('|')[1]), name: t.split('|')[2] });
    });
    s.on('error', () => finish(null));
    s.bind(() => {
      try { s.setBroadcast(true); } catch {}
      const probe = Buffer.from('PHONELINK_DISCOVER_V1', 'utf8');
      s.send(probe, cfg.discoveryPort, '255.255.255.255');
      setTimeout(() => finish(null), 2500);
    });
  });
}

async function post(p, body) {
  const res = await fetch(`http://127.0.0.1:${cfg.port}${p}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Token': cfg.token },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.text() };
}

(async () => {
  console.log('--- PhoneLink 模拟手机 ---');
  console.log('本机配置端口 :', cfg.port, ' 令牌:', cfg.token);

  const d = await discover();
  if (d) {
    console.log(`UDP 自动发现  : OK -> ${d.ip}:${d.port} (${d.name})`);
  } else {
    console.log('UDP 自动发现  : 失败（防火墙可能挡了 UDP，或服务没在跑）');
  }

  const hb = await post('/api/heartbeat', { device: 'HDY-SIM', battery: 86, queued: 0, sent: 0 });
  console.log('心跳          :', hb.status, hb.body);

  const now = Date.now();
  const msgs = [
    { id: crypto.randomUUID(), ts: now, kind: 'sms', pkg: 'sms', app: '短信',
      title: '10086', text: '【中国移动】您本月已使用流量 3.2GB，剩余 16.8GB。', sender: '10086', slot: 0 },
    { id: crypto.randomUUID(), ts: now + 1, kind: 'notif', pkg: 'com.tencent.mm', app: '微信',
      title: '张三', text: '晚上一起吃饭吗？老地方见。', sender: '', slot: -1 },
    { id: crypto.randomUUID(), ts: now + 2, kind: 'notif', pkg: 'com.tencent.mobileqq', app: 'QQ',
      title: '技术交流群', text: '李四: 那个脚本我改好了，你拉一下', sender: '', slot: -1 },
  ];
  const push = await post('/api/messages', { device: 'HDY-SIM', messages: msgs });
  console.log('推送 3 条消息 :', push.status, push.body);
  console.log('--- 完成，打开 http://127.0.0.1:' + cfg.port + '/ 查看 ---');
})().catch((e) => {
  console.error('失败:', e.message);
  process.exit(1);
});
