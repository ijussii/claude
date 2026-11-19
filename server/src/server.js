'use strict';
// Anonymous messenger relay.
//  - Identity is a username + a random secret token (no email / phone).
//  - Message bodies are end-to-end encrypted by clients; the server only sees ciphertext.
//  - Call media is peer-to-peer WebRTC; this server only relays signaling.

const http = require('node:http');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { WebSocketServer } = require('ws');

const USERNAME_RE = /^[a-z0-9_]{3,20}$/;
const MAX_BODY = 16 * 1024; // ciphertext, base64
const MAX_SIGNAL = 32 * 1024;
const QUEUE_TTL_MS = 30 * 24 * 3600 * 1000;
const MSGS_PER_MIN = 120;
const DEFAULT_REGISTRATIONS_PER_HOUR_PER_IP = 10;

const sha256 = (s) => crypto.createHash('sha256').update(s).digest();

function createServer({
  port = 8080,
  dbPath = ':memory:',
  host = '0.0.0.0',
  registrationsPerHourPerIp = DEFAULT_REGISTRATIONS_PER_HOUR_PER_IP,
} = {}) {
  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      username   TEXT PRIMARY KEY,
      pubkey     TEXT NOT NULL,
      token_hash BLOB NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS queue (
      sid       INTEGER PRIMARY KEY AUTOINCREMENT,
      to_user   TEXT NOT NULL,
      from_user TEXT NOT NULL,
      msg_id    TEXT NOT NULL,
      body      TEXT NOT NULL,
      ts        INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS queue_to ON queue(to_user);
  `);
  const q = {
    getUser: db.prepare('SELECT * FROM users WHERE username = ?'),
    addUser: db.prepare('INSERT INTO users (username, pubkey, token_hash, created_at) VALUES (?,?,?,?)'),
    enqueue: db.prepare('INSERT INTO queue (to_user, from_user, msg_id, body, ts) VALUES (?,?,?,?,?)'),
    pending: db.prepare('SELECT * FROM queue WHERE to_user = ? ORDER BY sid'),
    ack: db.prepare('DELETE FROM queue WHERE sid = ? AND to_user = ?'),
    purge: db.prepare('DELETE FROM queue WHERE ts < ?'),
  };

  const online = new Map(); // username -> ws
  const regLog = new Map(); // ip -> [timestamps]

  const server = http.createServer((req, res) => {
    if (req.url === '/health') { res.writeHead(200); res.end('ok'); return; }
    res.writeHead(404); res.end();
  });
  const wss = new WebSocketServer({ server, maxPayload: 64 * 1024 });

  const send = (ws, obj) => { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); };
  const err = (ws, code, extra = {}) => send(ws, { t: 'error', code, ...extra });

  function registrationAllowed(ip) {
    const now = Date.now();
    const list = (regLog.get(ip) || []).filter((t) => now - t < 3600e3);
    if (list.length >= registrationsPerHourPerIp) { regLog.set(ip, list); return false; }
    list.push(now); regLog.set(ip, list); return true;
  }

  function deliver(username, row) {
    const ws = online.get(username);
    if (ws) send(ws, { t: 'msg', sid: row.sid, from: row.from_user, id: row.msg_id, body: row.body, ts: row.ts });
  }

  wss.on('connection', (ws, req) => {
    const ip = req.socket.remoteAddress || 'unknown';
    let me = null;
    let bucket = { start: Date.now(), n: 0 };
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', (raw) => {
      let m;
      try { m = JSON.parse(raw.toString()); } catch { return err(ws, 'bad_json'); }
      if (!m || typeof m.t !== 'string') return err(ws, 'bad_request');

      const now = Date.now();
      if (now - bucket.start > 60e3) bucket = { start: now, n: 0 };
      if (++bucket.n > MSGS_PER_MIN) return err(ws, 'rate_limited');

      switch (m.t) {
        case 'register': {
          if (typeof m.username !== 'string' || !USERNAME_RE.test(m.username)) return err(ws, 'invalid_username');
          if (typeof m.pubkey !== 'string' || m.pubkey.length < 20 || m.pubkey.length > 200) return err(ws, 'invalid_pubkey');
          if (!registrationAllowed(ip)) return err(ws, 'rate_limited');
          if (q.getUser.get(m.username)) return err(ws, 'username_taken');
          const token = crypto.randomBytes(32).toString('base64url');
          try {
            q.addUser.run(m.username, m.pubkey, sha256(token), now);
          } catch { return err(ws, 'username_taken'); }
          return send(ws, { t: 'registered', username: m.username, token });
        }

        case 'auth': {
          if (typeof m.username !== 'string' || typeof m.token !== 'string') return err(ws, 'bad_request');
          const u = q.getUser.get(m.username);
          const ok = u && crypto.timingSafeEqual(Buffer.from(u.token_hash), sha256(m.token));
          if (!ok) return err(ws, 'auth_failed');
          const prev = online.get(m.username);
          if (prev && prev !== ws) { send(prev, { t: 'error', code: 'signed_in_elsewhere' }); prev.close(); }
          me = m.username;
          online.set(me, ws);
          send(ws, { t: 'ready' });
          q.purge.run(now - QUEUE_TTL_MS);
          for (const row of q.pending.all(me)) deliver(me, row);
          return;
        }

        default:
          break;
      }

      // Everything below requires authentication.
      if (!me) return err(ws, 'not_authenticated');

      switch (m.t) {
        case 'lookup': {
          if (typeof m.username !== 'string') return err(ws, 'bad_request');
          const u = q.getUser.get(m.username);
          if (!u) return send(ws, { t: 'user', username: m.username, found: false });
          return send(ws, { t: 'user', username: u.username, found: true, pubkey: u.pubkey });
        }

        case 'msg': {
          if (typeof m.to !== 'string' || typeof m.id !== 'string' || typeof m.body !== 'string') return err(ws, 'bad_request', { id: m.id });
          if (m.id.length > 64 || m.body.length > MAX_BODY) return err(ws, 'too_large', { id: m.id });
          if (!q.getUser.get(m.to)) return err(ws, 'no_such_user', { id: m.id });
          const info = q.enqueue.run(m.to, me, m.id, m.body, now);
          send(ws, { t: 'sent', id: m.id });
          return deliver(m.to, { sid: Number(info.lastInsertRowid), from_user: me, msg_id: m.id, body: m.body, ts: now });
        }

        case 'recv': {
          if (Number.isInteger(m.sid)) q.ack.run(m.sid, me);
          return;
        }

        case 'call': {
          // kinds: invite | accept | reject | ice | end | sdp
          const kinds = ['invite', 'accept', 'reject', 'ice', 'end', 'sdp'];
          if (typeof m.to !== 'string' || typeof m.callId !== 'string' || !kinds.includes(m.kind)) return err(ws, 'bad_request');
          if (m.callId.length > 64 || JSON.stringify(m.data || '').length > MAX_SIGNAL) return err(ws, 'too_large');
          const target = online.get(m.to);
          if (!target) return send(ws, { t: 'call', from: m.to, callId: m.callId, kind: 'unavailable' });
          return send(target, { t: 'call', from: me, callId: m.callId, kind: m.kind, data: m.data });
        }

        default:
          return err(ws, 'unknown_type');
      }
    });

    ws.on('close', () => { if (me && online.get(me) === ws) online.delete(me); });
    ws.on('error', () => {});
  });

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.isAlive) { ws.terminate(); continue; }
      ws.isAlive = false; ws.ping();
    }
  }, 30e3);
  heartbeat.unref();

  return new Promise((resolve) => {
    server.listen(port, host, () => resolve({
      port: server.address().port,
      close: () => new Promise((r) => {
        clearInterval(heartbeat);
        for (const ws of wss.clients) ws.terminate();
        wss.close(() => server.close(() => { db.close(); r(); }));
      }),
    }));
  });
}

module.exports = { createServer, USERNAME_RE };

if (require.main === module) {
  const port = Number(process.env.PORT || 8080);
  const dbPath = process.env.DB_PATH || './messenger.db';
  createServer({ port, dbPath }).then(({ port: p }) => console.log(`relay listening on :${p} (db: ${dbPath})`));
}
