'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { createServer } = require('../src/server');

function client(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const inbox = [];
  const waiters = [];
  ws.on('message', (d) => {
    const m = JSON.parse(d.toString());
    const i = waiters.findIndex((w) => w.pred(m));
    if (i >= 0) waiters.splice(i, 1)[0].resolve(m); else inbox.push(m);
  });
  return {
    ws,
    open: () => new Promise((r) => ws.on('open', r)),
    send: (o) => ws.send(JSON.stringify(o)),
    next: (pred = () => true) => {
      const i = inbox.findIndex(pred);
      if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('timeout')), 2000);
        waiters.push({ pred, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
    close: () => ws.close(),
  };
}

const PUB = 'A'.repeat(44);

async function signup(port, username) {
  const c = client(port); await c.open();
  c.send({ t: 'register', username, pubkey: PUB });
  const r = await c.next();
  assert.equal(r.t, 'registered');
  c.send({ t: 'auth', username, token: r.token });
  assert.equal((await c.next()).t, 'ready');
  return { c, token: r.token };
}

test('relay', async (t) => {
  const srv = await createServer({ port: 0, host: '127.0.0.1', registrationsPerHourPerIp: 1000 });
  t.after(() => srv.close());

  await t.test('rejects bad and duplicate usernames', async () => {
    const c = client(srv.port); await c.open();
    c.send({ t: 'register', username: 'Bad Name!', pubkey: PUB });
    assert.equal((await c.next()).code, 'invalid_username');
    c.send({ t: 'register', username: 'alice', pubkey: PUB });
    assert.equal((await c.next()).t, 'registered');
    c.send({ t: 'register', username: 'alice', pubkey: PUB });
    assert.equal((await c.next()).code, 'username_taken');
    c.close();
  });

  await t.test('auth fails with wrong token; commands need auth', async () => {
    const c = client(srv.port); await c.open();
    c.send({ t: 'msg', to: 'alice', id: '1', body: 'x' });
    assert.equal((await c.next()).code, 'not_authenticated');
    c.send({ t: 'auth', username: 'alice', token: 'nope' });
    assert.equal((await c.next()).code, 'auth_failed');
    c.close();
  });

  await t.test('lookup', async () => {
    const { c } = await signup(srv.port, 'bob');
    c.send({ t: 'lookup', username: 'alice' });
    const r = await c.next();
    assert.deepEqual([r.found, r.pubkey], [true, PUB]);
    c.send({ t: 'lookup', username: 'ghost' });
    assert.equal((await c.next()).found, false);
    c.close();
  });

  await t.test('live delivery and ack', async () => {
    const a = await signup(srv.port, 'carol');
    const b = await signup(srv.port, 'dave');
    a.c.send({ t: 'msg', to: 'dave', id: 'm1', body: 'Y2lwaGVy' });
    assert.equal((await a.c.next()).t, 'sent');
    const m = await b.c.next((x) => x.t === 'msg');
    assert.deepEqual([m.from, m.id, m.body], ['carol', 'm1', 'Y2lwaGVy']);
    b.c.send({ t: 'recv', sid: m.sid });
    a.c.close(); b.c.close();
  });

  await t.test('offline queue is delivered on login and re-delivered until acked', async () => {
    const a = await signup(srv.port, 'erin');
    const b = await signup(srv.port, 'frank');
    const frankToken = b.token;
    b.c.close();
    await new Promise((r) => setTimeout(r, 50));
    a.c.send({ t: 'msg', to: 'frank', id: 'q1', body: 'aGk=' });
    await a.c.next((x) => x.t === 'sent');

    const b2 = client(srv.port); await b2.open();
    b2.send({ t: 'auth', username: 'frank', token: frankToken });
    const m = await b2.next((x) => x.t === 'msg');
    assert.equal(m.id, 'q1');
    b2.close(); // never acked
    await new Promise((r) => setTimeout(r, 50));

    const b3 = client(srv.port); await b3.open();
    b3.send({ t: 'auth', username: 'frank', token: frankToken });
    const again = await b3.next((x) => x.t === 'msg');
    assert.equal(again.id, 'q1');
    b3.send({ t: 'recv', sid: again.sid });
    await new Promise((r) => setTimeout(r, 50));
    b3.close();

    const b4 = client(srv.port); await b4.open();
    b4.send({ t: 'auth', username: 'frank', token: frankToken });
    await b4.next((x) => x.t === 'ready');
    await assert.rejects(b4.next((x) => x.t === 'msg'), /timeout/);
    b4.close(); a.c.close();
  });

  await t.test('call signaling relays, and reports unavailable', async () => {
    const a = await signup(srv.port, 'gina');
    const b = await signup(srv.port, 'hank');
    a.c.send({ t: 'call', to: 'hank', callId: 'c1', kind: 'invite', data: { sdp: 'offer' } });
    const inv = await b.c.next((x) => x.t === 'call');
    assert.deepEqual([inv.from, inv.kind, inv.data.sdp], ['gina', 'invite', 'offer']);
    b.c.close();
    await new Promise((r) => setTimeout(r, 50));
    a.c.send({ t: 'call', to: 'hank', callId: 'c2', kind: 'invite' });
    assert.equal((await a.c.next((x) => x.t === 'call')).kind, 'unavailable');
    a.c.close();
  });

  await t.test('second login kicks the first', async () => {
    const a = await signup(srv.port, 'ivan');
    const second = client(srv.port); await second.open();
    second.send({ t: 'auth', username: 'ivan', token: a.token });
    assert.equal((await second.next()).t, 'ready');
    assert.equal((await a.c.next()).code, 'signed_in_elsewhere');
    second.close();
  });

  await t.test('rejects oversized bodies and unknown recipients', async () => {
    const a = await signup(srv.port, 'judy');
    a.c.send({ t: 'msg', to: 'judy', id: 'big', body: 'A'.repeat(20000) });
    assert.equal((await a.c.next()).code, 'too_large');
    a.c.send({ t: 'msg', to: 'nobody_here', id: 'x', body: 'aa' });
    assert.equal((await a.c.next()).code, 'no_such_user');
    a.c.close();
  });
});

test('registration is rate limited per IP', async (t) => {
  const srv = await createServer({ port: 0, host: '127.0.0.1', registrationsPerHourPerIp: 3 });
  t.after(() => srv.close());
  const c = client(srv.port); await c.open();
  for (const n of ['user_a', 'user_b', 'user_c']) {
    c.send({ t: 'register', username: n, pubkey: PUB });
    assert.equal((await c.next()).t, 'registered');
  }
  c.send({ t: 'register', username: 'user_d', pubkey: PUB });
  assert.equal((await c.next()).code, 'rate_limited');
  c.close();
});
