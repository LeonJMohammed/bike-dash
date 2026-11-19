#!/usr/bin/env node
// Bike Dash's Spotify token service: the token swap and refresh for the app, on the home PC
// behind the Cloudflare Tunnel (jlmoh.com/bike-dash/spotify/...). Spotify's client secret is
// needed to turn a sign-in code into tokens and to refresh them, so it stays here, in .env.
//
//   POST /bike-dash/spotify/swap     code=...           -> access_token, expires_in, refresh_token
//   POST /bike-dash/spotify/refresh  refresh_token=...  -> access_token, expires_in (+ refresh_token
//                                                          when Spotify rotates it)
//   GET  /bike-dash/spotify/health                      -> {"ok":true,"configured":true}
//
// The refresh token the app keeps is encrypted here (AES-256-GCM, TOKEN_KEY in .env): on its own
// it's useless, and only this service can use it. Codes and tokens are never logged.
//
// The same service (same port, same launcher) also serves Strava routes for the Routes screen,
// under /bike-dash/routes/...: see strava-routes.js.
//
//   node server/spotify-token-service.js                    run the service
//   node server/spotify-token-service.js mint-routes-key    print a new app key for the routes
//                                                           (adds ROUTES_KEY_ID to .env if missing)
//
// No dependencies; Node 18+ (fetch). See README.md, "PC service".
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { seal, open } = require('./seal');
const routesApi = require('./strava-routes');

const BASE = '/bike-dash/spotify';
const SPOTIFY_TOKEN_URL = 'https://accounts.spotify.com/api/token';
const MAX_BODY = 4096;
const RATE_LIMIT = { windowMs: 60_000, max: 30 };

/** KEY=value lines; # comments; surrounding quotes dropped. Doesn't override the environment. */
function loadEnv(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return {}; }
  const out = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 1) continue;
    let value = line.slice(eq + 1).trim();
    if (/^(['"]).*\1$/.test(value)) value = value.slice(1, -1);
    out[line.slice(0, eq).trim()] = value;
  }
  return out;
}

function configFrom(env) {
  const key = env.TOKEN_KEY ? Buffer.from(env.TOKEN_KEY, 'base64') : null;
  return {
    clientId: env.SPOTIFY_CLIENT_ID || '',
    clientSecret: env.SPOTIFY_CLIENT_SECRET || '',
    redirectUri: env.SPOTIFY_REDIRECT_URI || 'bikedash://spotify-login-callback',
    key: key && key.length === 32 ? key : null,
    port: Number(env.PORT) || 3010,
    // Routes (strava-routes.js)
    raceTrackerUrl: env.RACE_TRACKER_TOKEN_URL || 'http://127.0.0.1:3003/race-tracker/api/strava/token',
    raceTrackerSecret: env.RACE_TRACKER_SECRET || '',
    routesKeyId: env.ROUTES_KEY_ID || '',
  };
}

function isConfigured(config) {
  return Boolean(config.clientId && config.clientSecret && config.key);
}

// The refresh token the app holds is sealed with TOKEN_KEY: seal.js.

// ---- Spotify ----

/** POSTs to Spotify's token endpoint. {status, json}; status 0 when Spotify couldn't be reached. */
async function spotifyToken(config, params, fetchImpl) {
  const auth = Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64');
  try {
    const res = await fetchImpl(SPOTIFY_TOKEN_URL, {
      method: 'POST',
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(params).toString(),
      signal: AbortSignal.timeout(10_000),
    });
    let json = {};
    try { json = await res.json(); } catch { /* not JSON */ }
    return { status: res.status, json };
  } catch {
    return { status: 0, json: {} };
  }
}

/**
 * What the app gets back for a failed Spotify call. Spotify's own "invalid_grant" (an old or
 * revoked code or refresh token) stays 400 invalid_grant, which tells the app to sign in again;
 * anything else is "try later" (502 / 503), so the app keeps its refresh token.
 */
function failure(result) {
  if (result.status === 0) return [503, { error: 'spotify_unreachable' }];
  if (result.status === 400 && result.json.error === 'invalid_grant') return [400, { error: 'invalid_grant' }];
  if (result.status === 429) return [503, { error: 'spotify_busy' }];
  return [502, { error: 'spotify_error', status: result.status, spotify_error: String(result.json.error || '') }];
}

async function swap(config, form, fetchImpl) {
  const code = form.get('code');
  if (!code) return [400, { error: 'missing_code' }];
  const result = await spotifyToken(config, {
    grant_type: 'authorization_code',
    code,
    redirect_uri: config.redirectUri,
  }, fetchImpl);
  const { access_token, expires_in, refresh_token, scope } = result.json;
  if (result.status !== 200 || !access_token || !refresh_token) return failure(result);
  return [200, { access_token, expires_in, refresh_token: seal(refresh_token, config.key), scope }];
}

async function refresh(config, form, fetchImpl) {
  const sealed = form.get('refresh_token');
  if (!sealed) return [400, { error: 'missing_refresh_token' }];
  const token = open(sealed, config.key);
  if (!token) return [400, { error: 'invalid_grant' }];
  const result = await spotifyToken(config, { grant_type: 'refresh_token', refresh_token: token }, fetchImpl);
  const { access_token, expires_in, refresh_token, scope } = result.json;
  if (result.status !== 200 || !access_token) return failure(result);
  const body = { access_token, expires_in, scope };
  if (refresh_token) body.refresh_token = seal(refresh_token, config.key);   // Spotify rotated it
  return [200, body];
}

// ---- HTTP ----

function rateLimiter({ windowMs, max }) {
  const hits = new Map();
  return (who, now = Date.now()) => {
    const entry = hits.get(who);
    if (!entry || now - entry.start >= windowMs) {
      hits.set(who, { start: now, count: 1 });
      if (hits.size > 1000) for (const [k, v] of hits) if (now - v.start >= windowMs) hits.delete(k);
      return true;
    }
    entry.count += 1;
    return entry.count <= max;
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size <= MAX_BODY) chunks.push(chunk);   // past the limit: drain the rest, then refuse
      if (size > 64 * MAX_BODY) req.destroy();
    });
    req.on('end', () => (size > MAX_BODY ? reject(new Error('too_large')) : resolve(Buffer.concat(chunks).toString('utf8'))));
    req.on('error', reject);
  });
}

function log(line) {
  console.log(`${new Date().toISOString()}  ${line}`);
}

function createServer(config, { fetchImpl = fetch, quiet = false, now } = {}) {
  const allow = rateLimiter(RATE_LIMIT);
  const note = quiet ? () => {} : log;
  const routes = routesApi.createRoutes(config, { fetchImpl, now });

  return http.createServer(async (req, res) => {
    const send = (status, body) => {
      res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(body));
    };
    const url = new URL(req.url, 'http://localhost');

    if (url.pathname.startsWith(routesApi.ROUTES_BASE + '/')) {
      const sub = url.pathname.slice(routesApi.ROUTES_BASE.length);
      const who = req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '?';
      if (sub !== '/health' && !allow(who)) { note(`routes${sub} 429 (rate limit)`); return send(429, { error: 'too_many_requests' }); }
      let out;
      try {
        out = await routes.handle(req, url);
      } catch (e) {
        note(`routes${sub} 500 (${e && e.message})`);
        return send(500, { error: 'internal' });
      }
      if (sub !== '/health' || out.json.ok === false) {
        // Route ids are fine to log; the app key and Strava tokens never are.
        note(`routes${sub} ${out.status}${out.json && out.json.error ? ` (${out.json.error})` : ''}`);
      }
      if (out.text !== undefined) {
        res.writeHead(out.status, { 'Content-Type': out.type, 'Cache-Control': 'no-store' });
        return res.end(out.text);
      }
      return send(out.status, out.json);
    }

    const route = url.pathname.startsWith(BASE + '/') ? url.pathname.slice(BASE.length) : null;

    if (route === '/health' && req.method === 'GET') {
      return send(200, { ok: isConfigured(config), configured: isConfigured(config) });
    }
    if (route !== '/swap' && route !== '/refresh') return send(404, { error: 'not_found' });
    if (req.method !== 'POST') return send(405, { error: 'method_not_allowed' });

    const who = req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '?';
    if (!allow(who)) { note(`${route} 429 (rate limit)`); return send(429, { error: 'too_many_requests' }); }
    if (!isConfigured(config)) { note(`${route} 503 (not configured)`); return send(503, { error: 'not_configured' }); }

    let form;
    try { form = new URLSearchParams(await readBody(req)); } catch { return send(413, { error: 'too_large' }); }
    const [status, body] = route === '/swap'
      ? await swap(config, form, fetchImpl)
      : await refresh(config, form, fetchImpl);
    note(`${route} ${status}${body.error ? ` (${body.error}${body.status ? ` ${body.status}` : ''})` : ''}`);
    send(status, body);
  });
}

module.exports = { loadEnv, configFrom, isConfigured, seal, open, failure, rateLimiter, createServer };

/** Prints a new routes app key to stdout (nothing else), adding ROUTES_KEY_ID to .env first if missing. */
function mintRoutesKey(envFile) {
  let env = { ...loadEnv(envFile), ...process.env };
  if (!env.ROUTES_KEY_ID) {
    const text = fs.existsSync(envFile) ? fs.readFileSync(envFile, 'utf8') : '';
    fs.writeFileSync(envFile, text.trimEnd() +
      '\n\n# Routes: the app key\'s id. A new value retires every app key minted before it.\n' +
      `ROUTES_KEY_ID=${routesApi.newRoutesKeyId()}\n`);
    env = { ...loadEnv(envFile), ...process.env };
  }
  const config = configFrom(env);
  if (!config.key) {
    console.error('TOKEN_KEY is missing or not 32 bytes in server/.env');
    process.exit(1);
  }
  process.stdout.write(routesApi.mintAppKey(config) + '\n');
}

if (require.main === module && process.argv[2] === 'mint-routes-key') {
  mintRoutesKey(path.join(__dirname, '.env'));
} else if (require.main === module) {
  const env = { ...loadEnv(path.join(__dirname, '.env')), ...process.env };
  const config = configFrom(env);
  const server = createServer(config);
  server.listen(config.port, '127.0.0.1', () => {
    log(`Bike Dash Spotify token service on http://127.0.0.1:${config.port}${BASE}` +
      (isConfigured(config) ? '' : ' -- NOT CONFIGURED: fill in .env (see .env.example)'));
    log(`Strava routes on http://127.0.0.1:${config.port}${routesApi.ROUTES_BASE}` +
      (routesApi.isRoutesConfigured(config) ? '' : ' -- NOT CONFIGURED: RACE_TRACKER_SECRET and ROUTES_KEY_ID in .env'));
  });
}
