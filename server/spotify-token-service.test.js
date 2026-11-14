// node --test server/   (no network: Spotify is a fake fetch)
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');
const svc = require('./spotify-token-service');

const key = crypto.randomBytes(32);
const config = { clientId: 'id', clientSecret: 'secret', redirectUri: 'bikedash://spotify-login-callback', key, port: 0 };

/** Starts the service with a fake Spotify; returns { call(path, body, method), calls, close }. */
async function start(spotify, cfg = config) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init, params: new URLSearchParams(init.body) });
    const reply = typeof spotify === 'function' ? spotify(calls.at(-1)) : spotify;
    if (reply instanceof Error) throw reply;
    return { status: reply.status, json: async () => reply.json };
  };
  const server = svc.createServer(cfg, { fetchImpl, quiet: true });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    calls,
    close: () => new Promise((r) => server.close(r)),
    async call(path, body, method = 'POST') {
      const res = await fetch(base + path, {
        method,
        headers: body ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {},
        body: body ? new URLSearchParams(body).toString() : undefined,
      });
      return { status: res.status, json: await res.json() };
    },
  };
}

test('seal and open round trip; tampering and other keys are refused', () => {
  const sealed = svc.seal('refresh-123', key);
  assert.match(sealed, /^v1\./);
  assert.notEqual(sealed, svc.seal('refresh-123', key), 'a fresh IV every time');
  assert.equal(svc.open(sealed, key), 'refresh-123');
  assert.equal(svc.open(sealed, crypto.randomBytes(32)), null);
  const raw = Buffer.from(sealed.slice(3), 'base64url');
  raw[raw.length - 1] ^= 1;
  assert.equal(svc.open('v1.' + raw.toString('base64url'), key), null);
  assert.equal(svc.open('refresh-123', key), null);
  assert.equal(svc.open('v1.short', key), null);
});

test('loadEnv reads KEY=value lines and configFrom wants a 32-byte key', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bd-')), '.env');
  fs.writeFileSync(file, '# comment\nSPOTIFY_CLIENT_ID=abc\nSPOTIFY_CLIENT_SECRET="s e"\r\nTOKEN_KEY=' + key.toString('base64') + '\n\nBAD\n');
  const env = svc.loadEnv(file);
  assert.deepEqual(env, { SPOTIFY_CLIENT_ID: 'abc', SPOTIFY_CLIENT_SECRET: 's e', TOKEN_KEY: key.toString('base64') });
  assert.equal(svc.isConfigured(svc.configFrom(env)), true);
  assert.equal(svc.isConfigured(svc.configFrom({ ...env, TOKEN_KEY: 'c2hvcnQ=' })), false);
  assert.equal(svc.isConfigured(svc.configFrom({ ...env, SPOTIFY_CLIENT_SECRET: '' })), false);
  assert.equal(svc.configFrom({}).port, 3010);
  assert.deepEqual(svc.loadEnv(file + '.missing'), {});
});

test('swap: sends the code with the secret and seals the refresh token', async () => {
  const s = await start({ status: 200, json: { access_token: 'A1', expires_in: 3600, refresh_token: 'R1', scope: 'app-remote-control' } });
  try {
    const res = await s.call('/bike-dash/spotify/swap', { code: 'C1' });
    assert.equal(res.status, 200);
    assert.equal(res.json.access_token, 'A1');
    assert.equal(res.json.expires_in, 3600);
    assert.equal(svc.open(res.json.refresh_token, key), 'R1');
    const sent = s.calls[0];
    assert.equal(sent.url, 'https://accounts.spotify.com/api/token');
    assert.equal(sent.init.headers.Authorization, 'Basic ' + Buffer.from('id:secret').toString('base64'));
    assert.equal(sent.params.get('grant_type'), 'authorization_code');
    assert.equal(sent.params.get('code'), 'C1');
    assert.equal(sent.params.get('redirect_uri'), 'bikedash://spotify-login-callback');
  } finally { await s.close(); }
});

test('refresh: opens the sealed token, and passes on a rotated one sealed', async () => {
  const s = await start((call) => call.params.get('refresh_token') === 'R1'
    ? { status: 200, json: { access_token: 'A2', expires_in: 3600, refresh_token: 'R2' } }
    : { status: 400, json: { error: 'invalid_grant' } });
  try {
    const res = await s.call('/bike-dash/spotify/refresh', { refresh_token: svc.seal('R1', key) });
    assert.equal(res.status, 200);
    assert.equal(res.json.access_token, 'A2');
    assert.equal(s.calls[0].params.get('grant_type'), 'refresh_token');
    assert.equal(svc.open(res.json.refresh_token, key), 'R2');
  } finally { await s.close(); }
});

test('refresh without rotation returns no refresh token', async () => {
  const s = await start({ status: 200, json: { access_token: 'A3', expires_in: 3600 } });
  try {
    const res = await s.call('/bike-dash/spotify/refresh', { refresh_token: svc.seal('R1', key) });
    assert.equal(res.status, 200);
    assert.equal('refresh_token' in res.json, false);
  } finally { await s.close(); }
});

test('a revoked or foreign refresh token is invalid_grant (sign in again)', async () => {
  const s = await start({ status: 400, json: { error: 'invalid_grant', error_description: 'Refresh token revoked' } });
  try {
    assert.deepEqual(await s.call('/bike-dash/spotify/refresh', { refresh_token: svc.seal('R1', key) }),
      { status: 400, json: { error: 'invalid_grant' } });
    assert.deepEqual(await s.call('/bike-dash/spotify/refresh', { refresh_token: 'not-ours' }),
      { status: 400, json: { error: 'invalid_grant' } });
    assert.equal(s.calls.length, 1, 'a token that is not ours never reaches Spotify');
  } finally { await s.close(); }
});

test('Spotify down, busy or unhappy is "try later", never invalid_grant', async () => {
  assert.deepEqual(svc.failure({ status: 0, json: {} }), [503, { error: 'spotify_unreachable' }]);
  assert.deepEqual(svc.failure({ status: 429, json: {} }), [503, { error: 'spotify_busy' }]);
  assert.equal(svc.failure({ status: 500, json: {} })[0], 502);
  assert.equal(svc.failure({ status: 400, json: { error: 'invalid_client' } })[0], 502);
  const s = await start(new Error('ECONNRESET'));
  try {
    const res = await s.call('/bike-dash/spotify/refresh', { refresh_token: svc.seal('R1', key) });
    assert.deepEqual(res, { status: 503, json: { error: 'spotify_unreachable' } });
  } finally { await s.close(); }
});

test('health, missing fields, wrong method and unknown paths', async () => {
  const s = await start({ status: 200, json: {} });
  try {
    assert.deepEqual(await s.call('/bike-dash/spotify/health', null, 'GET'), { status: 200, json: { ok: true, configured: true } });
    assert.deepEqual(await s.call('/bike-dash/spotify/swap', { other: 'x' }), { status: 400, json: { error: 'missing_code' } });
    assert.equal((await s.call('/bike-dash/spotify/refresh', null, 'GET')).status, 405);
    assert.equal((await s.call('/bike-dash/spotify', null, 'GET')).status, 404);
    assert.equal((await s.call('/elsewhere/swap', { code: 'C' })).status, 404);
    assert.equal(s.calls.length, 0);
  } finally { await s.close(); }
});

test('not configured: health says so and token calls are 503', async () => {
  const s = await start({ status: 200, json: {} }, { ...config, clientSecret: '' });
  try {
    assert.deepEqual(await s.call('/bike-dash/spotify/health', null, 'GET'), { status: 200, json: { ok: false, configured: false } });
    assert.deepEqual(await s.call('/bike-dash/spotify/swap', { code: 'C' }), { status: 503, json: { error: 'not_configured' } });
  } finally { await s.close(); }
});

test('rate limit: 30 a minute per caller', () => {
  const allow = svc.rateLimiter({ windowMs: 60_000, max: 30 });
  for (let i = 0; i < 30; i++) assert.equal(allow('a', 1000), true);
  assert.equal(allow('a', 1000), false);
  assert.equal(allow('b', 1000), true);
  assert.equal(allow('a', 61_000), true);
});

test('a body over 4 KB is refused', async () => {
  const s = await start({ status: 200, json: {} });
  try {
    assert.equal((await s.call('/bike-dash/spotify/swap', { code: 'x'.repeat(5000) })).status, 413);
  } finally { await s.close(); }
});
