// node --test server/   (no network: Race Tracker and Strava are a fake fetch)
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');
const svc = require('./spotify-token-service');
const routes = require('./strava-routes');

const key = crypto.randomBytes(32);
const config = {
  clientId: 'id', clientSecret: 'secret', redirectUri: 'bikedash://spotify-login-callback', key, port: 0,
  raceTrackerUrl: 'http://rt.test/race-tracker/api/strava/token', raceTrackerSecret: 'rt-secret', routesKeyId: 'kid-1',
};
const appKey = routes.mintAppKey(config);
const GPX = '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="StravaGPX"><trk><trkseg>' +
  '<trkpt lat="10.65" lon="-61.51"><ele>12</ele></trkpt></trkseg></trk></gpx>';

function reply(status, body) {
  return {
    status,
    json: async () => (typeof body === 'string' ? JSON.parse(body) : body),
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

/** A fake Race Tracker + Strava. `opts` changes what they answer. */
function world(opts = {}) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url, init });
    if (url === config.raceTrackerUrl) {
      if (opts.raceTracker instanceof Error) throw opts.raceTracker;
      if (opts.raceTracker) return reply(...opts.raceTracker);
      assert.equal(init.headers['x-bike-dash-secret'], 'rt-secret');
      return reply(200, {
        access_token: 'AT' + calls.filter((c) => c.url === config.raceTrackerUrl).length,
        expires_at: opts.expiresAt ?? 2_000_000_000,
        scopes: opts.scopes ?? ['read', 'read_all', 'activity:read_all', 'profile:read_all'],
      });
    }
    assert.match(init.headers.Authorization, /^Bearer AT\d+$/);
    const path = url.replace('https://www.strava.com/api/v3', '');
    if (opts.strava) {
      const answer = opts.strava(path);
      if (answer) return answer;
    }
    if (path === '/athlete') return reply(200, { id: 1234567 });
    const page = /^\/athletes\/1234567\/routes\?page=(\d+)&per_page=200$/.exec(path);
    if (page) {
      const pages = opts.pages ?? [[
        { id: 3344550000000000000, id_str: '3344550000000000123', name: 'Old loop', type: 1, sub_type: 1,
          distance: 42195.5, elevation_gain: 310.2, updated_at: '2026-10-01T10:00:00Z', private: true,
          map: { summary_polyline: 'abc' } },
        { id_str: '3344550000000000999', name: 'Run route', type: 2, distance: 5000, elevation_gain: 20,
          updated_at: '2026-11-10T10:00:00Z' },
      ]];
      return reply(200, pages[Number(page[1]) - 1] ?? []);
    }
    const gpx = /^\/routes\/(\d+)\/export_gpx$/.exec(path);
    if (gpx) return gpx[1] === '404' ? reply(404, { message: 'Record Not Found' }) : reply(200, GPX);
    return reply(404, { message: 'Not found' });
  };
  return { calls, fetchImpl };
}

async function start(opts = {}, cfg = config, now) {
  const w = world(opts);
  const server = svc.createServer(cfg, { fetchImpl: w.fetchImpl, quiet: true, now });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    calls: w.calls,
    close: () => new Promise((r) => server.close(r)),
    async get(path, { auth = appKey, method = 'GET' } = {}) {
      const res = await fetch(base + path, { method, headers: auth ? { Authorization: `Bearer ${auth}` } : {} });
      const type = res.headers.get('content-type') || '';
      return { status: res.status, type, body: type.startsWith('application/json') ? await res.json() : await res.text() };
    },
  };
}

test('app key: only keys minted under the current ROUTES_KEY_ID and TOKEN_KEY open', () => {
  assert.match(appKey, /^v1\.[A-Za-z0-9_-]+$/, 'base64url: safe in an xcconfig (no //)');
  assert.equal(routes.isAppKey(`Bearer ${appKey}`, config), true);
  assert.equal(routes.isAppKey(appKey, config), false, 'needs the Bearer prefix');
  assert.equal(routes.isAppKey(`Bearer ${appKey}`, { ...config, routesKeyId: 'kid-2' }), false, 'retired by a new id');
  assert.equal(routes.isAppKey(`Bearer ${appKey}`, { ...config, key: crypto.randomBytes(32) }), false);
  assert.equal(routes.isAppKey(`Bearer ${svc.seal('spotify-refresh-token', key)}`, config), false, 'a sealed Spotify token is not a key');
  assert.equal(routes.isAppKey(`Bearer ${svc.seal('{"use":"spotify","id":"kid-1"}', key)}`, config), false);
  assert.equal(routes.isAppKey(undefined, config), false);
  assert.equal(routes.isAppKey(`Bearer ${appKey}`, { ...config, raceTrackerSecret: '' }), false, 'not configured');
});

test('list: borrows the token from Race Tracker, keeps big ids as text, newest first', async () => {
  const s = await start();
  try {
    const res = await s.get('/bike-dash/routes/list');
    assert.equal(res.status, 200);
    assert.equal(res.body.private_hidden, false);
    assert.deepEqual(res.body.routes.map((r) => r.id), ['3344550000000000999', '3344550000000000123']);
    assert.deepEqual(res.body.routes[1], {
      id: '3344550000000000123', name: 'Old loop', kind: 'ride', sub_type: 1, distance_m: 42195.5,
      elevation_gain_m: 310.2, estimated_moving_time_s: null, updated_at: '2026-10-01T10:00:00Z',
      private: true, starred: false, summary_polyline: 'abc',
    });
    assert.equal(res.body.routes[0].kind, 'run');
    assert.equal(s.calls[0].url, config.raceTrackerUrl);
    assert.equal(s.calls[0].init.method, 'POST');

    await s.get('/bike-dash/routes/list');
    assert.equal(s.calls.filter((c) => c.url === config.raceTrackerUrl).length, 1, 'token reused until near expiry');
    assert.equal(s.calls.filter((c) => c.url.endsWith('/athlete')).length, 1, 'athlete id remembered');
  } finally { await s.close(); }
});

test('list: follows pages until a short one', async () => {
  const full = Array.from({ length: 200 }, (_, i) => ({ id_str: String(1000 + i), name: `R${i}`, type: 1 }));
  const s = await start({ pages: [full, [{ id_str: '9', name: 'Last', type: 1 }]] });
  try {
    const res = await s.get('/bike-dash/routes/list');
    assert.equal(res.body.routes.length, 201);
    assert.equal(s.calls.filter((c) => c.url.includes('/routes?page=')).length, 2);
  } finally { await s.close(); }
});

test('list: without read_all the app is told private routes are hidden', async () => {
  const s = await start({ scopes: ['read', 'activity:read_all'] });
  try {
    assert.equal((await s.get('/bike-dash/routes/list')).body.private_hidden, true);
  } finally { await s.close(); }
});

test('gpx: the route as GPX; bad, unknown and non-GPX routes', async () => {
  const s = await start({ strava: (path) => (path === '/routes/777/export_gpx' ? reply(200, '<html>nope</html>') : null) });
  try {
    const res = await s.get('/bike-dash/routes/3344550000000000123/gpx');
    assert.equal(res.status, 200);
    assert.match(res.type, /^application\/gpx\+xml/);
    assert.equal(res.body, GPX);
    assert.equal((await s.get('/bike-dash/routes/12ab/gpx')).status, 400);
    assert.deepEqual((await s.get('/bike-dash/routes/404/gpx')).body, { error: 'not_found' });
    assert.deepEqual((await s.get('/bike-dash/routes/777/gpx')).body, { error: 'not_gpx' });
  } finally { await s.close(); }
});

test('no key, a wrong key, wrong method, unknown paths', async () => {
  const s = await start();
  try {
    assert.deepEqual(await s.get('/bike-dash/routes/list', { auth: null }),
      { status: 401, type: 'application/json', body: { error: 'unauthorized' } });
    assert.equal((await s.get('/bike-dash/routes/list', { auth: svc.seal('x', key) })).status, 401);
    assert.equal((await s.get('/bike-dash/routes/1/gpx', { auth: 'v1.garbage' })).status, 401);
    assert.equal((await s.get('/bike-dash/routes/list', { method: 'POST' })).status, 405);
    assert.equal((await s.get('/bike-dash/routes/other')).status, 404);
    assert.equal((await s.get('/bike-dash/routes/1/gpx/x')).status, 404);
    assert.equal(s.calls.length, 0, 'nothing reached Race Tracker or Strava');
  } finally { await s.close(); }
});

test('health: ok only with read_all; says what is missing', async () => {
  let s = await start();
  try {
    assert.deepEqual((await s.get('/bike-dash/routes/health', { auth: null })).body, { ok: true, configured: true, read_all: true });
  } finally { await s.close(); }

  s = await start({ scopes: ['read', 'activity:read_all', 'profile:read_all'] });
  try {
    assert.deepEqual((await s.get('/bike-dash/routes/health', { auth: null })).body,
      { ok: false, configured: true, read_all: false, error: 'needs_read_all' });
  } finally { await s.close(); }

  s = await start({ raceTracker: new Error('ECONNREFUSED') });
  try {
    assert.equal((await s.get('/bike-dash/routes/health', { auth: null })).body.error, 'race_tracker_unreachable');
    assert.deepEqual((await s.get('/bike-dash/routes/list')).body, { error: 'race_tracker_unreachable' });
  } finally { await s.close(); }

  s = await start({ raceTracker: [401, { error: 'Unauthorized' }] });
  try {
    assert.equal((await s.get('/bike-dash/routes/health', { auth: null })).body.error, 'race_tracker_refused');
  } finally { await s.close(); }

  s = await start({ raceTracker: [503, { error: 'strava_not_connected' }] });
  try {
    assert.equal((await s.get('/bike-dash/routes/health', { auth: null })).body.error, 'strava_not_connected');
  } finally { await s.close(); }

  s = await start({}, { ...config, routesKeyId: '' });
  try {
    assert.deepEqual((await s.get('/bike-dash/routes/health', { auth: null })).body, { ok: false, configured: false, read_all: false });
    assert.deepEqual((await s.get('/bike-dash/routes/list')).body, { error: 'not_configured' });
    assert.equal(s.calls.length, 0);
  } finally { await s.close(); }
});

test('a token near its expiry is borrowed again', async () => {
  let clock = 1_000_000_000_000;
  const s = await start({ expiresAt: 1_000_000_000 + 3600 }, config, () => clock);
  try {
    await s.get('/bike-dash/routes/list');
    clock += 3600 * 1000 - 30_000;   // 30 s left: under the 60 s margin
    await s.get('/bike-dash/routes/list');
    assert.equal(s.calls.filter((c) => c.url === config.raceTrackerUrl).length, 2);
  } finally { await s.close(); }
});

test('Strava busy is try-later; a refused token is dropped', async () => {
  let s = await start({ strava: (path) => (path.startsWith('/athletes/') ? reply(429, {}) : null) });
  try {
    assert.deepEqual(await s.get('/bike-dash/routes/list'), { status: 503, type: 'application/json', body: { error: 'strava_busy' } });
  } finally { await s.close(); }

  s = await start({ strava: (path) => (path === '/athlete' ? reply(401, { message: 'Authorization Error' }) : null) });
  try {
    assert.equal((await s.get('/bike-dash/routes/list')).body.error, 'strava_auth');
    await s.get('/bike-dash/routes/list');
    assert.equal(s.calls.filter((c) => c.url === config.raceTrackerUrl).length, 2, 'borrowed afresh after a 401');
  } finally { await s.close(); }
});

test('Spotify paths are untouched by the routes', async () => {
  const s = await start();
  try {
    assert.deepEqual((await s.get('/bike-dash/spotify/health', { auth: null })).body, { ok: true, configured: true });
  } finally { await s.close(); }
});
