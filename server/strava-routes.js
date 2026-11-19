// Strava routes for Bike Dash's Routes screen, served by the same PC service as the Spotify token
// swap (spotify-token-service.js), behind the Cloudflare Tunnel at jlmoh.com/bike-dash/routes/...
//
//   GET /bike-dash/routes/list        Authorization: Bearer <app key>
//       -> { routes: [{ id, name, kind, distance_m, elevation_gain_m, ... }], private_hidden }
//   GET /bike-dash/routes/<id>/gpx    Authorization: Bearer <app key>   -> the route as GPX
//   GET /bike-dash/routes/health      -> { ok, configured, read_all[, error] }   (System Monitor)
//
// Strava access: Race Tracker holds the one Strava connection (Strava allows one API app per
// account, and it can swap the refresh token at any refresh). This service borrows a short-lived
// access token from Race Tracker over localhost (POST /race-tracker/api/strava/token with
// RACE_TRACKER_SECRET), so there is never a second copy of the refresh token. Private routes
// need the read_all scope on that connection.
//
// The app key is sealed with TOKEN_KEY like Spotify's refresh token: {"use":"routes","id":…},
// where id is ROUTES_KEY_ID in .env. Mint it with `node server/spotify-token-service.js
// mint-routes-key`; a new ROUTES_KEY_ID (or TOKEN_KEY) retires the old one.
'use strict';

const crypto = require('crypto');
const { seal, open } = require('./seal');

const ROUTES_BASE = '/bike-dash/routes';
const STRAVA_API = 'https://www.strava.com/api/v3';
const PER_PAGE = 200;
const MAX_PAGES = 10;
const MAX_GPX_BYTES = 15 * 1024 * 1024;
const ROUTE_ID = /^[0-9]{1,30}$/;

class RoutesError extends Error {
  constructor(status, code, extra = {}) {
    super(code);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

function isRoutesConfigured(config) {
  return Boolean(config.key && config.raceTrackerSecret && config.routesKeyId);
}

function newRoutesKeyId() {
  return crypto.randomBytes(12).toString('base64url');
}

function mintAppKey(config) {
  return seal(JSON.stringify({ use: 'routes', id: config.routesKeyId }), config.key);
}

/** True for "Bearer <a key this service minted under the current ROUTES_KEY_ID>". */
function isAppKey(header, config) {
  if (!isRoutesConfigured(config) || typeof header !== 'string') return false;
  const match = /^Bearer\s+(\S+)$/.exec(header);
  const plain = match && open(match[1], config.key);
  if (!plain) return false;
  try {
    const claim = JSON.parse(plain);
    if (!claim || claim.use !== 'routes' || typeof claim.id !== 'string') return false;
    const a = Buffer.from(claim.id);
    const b = Buffer.from(config.routesKeyId);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

/** One Strava route as the app sees it. Route ids are too big for JSON numbers: id_str. */
function routeSummary(r) {
  const kind = r.type === 1 ? 'ride' : r.type === 2 ? 'run' : 'other';
  return {
    id: String(r.id_str || ''),
    name: String(r.name || 'Route'),
    kind,
    sub_type: typeof r.sub_type === 'number' ? r.sub_type : null,
    distance_m: Number(r.distance) || 0,
    elevation_gain_m: Number(r.elevation_gain) || 0,
    estimated_moving_time_s: Number(r.estimated_moving_time) || null,
    updated_at: r.updated_at || r.created_at || null,
    private: Boolean(r.private),
    starred: Boolean(r.starred),
    summary_polyline: (r.map && (r.map.summary_polyline || r.map.polyline)) || '',
  };
}

/**
 * The routes endpoints. `handle(req, url)` resolves to { status, json } or { status, text, type }.
 * `now` is for tests.
 */
function createRoutes(config, { fetchImpl = fetch, now = () => Date.now() } = {}) {
  let token = null;        // { access_token, expires_at, scopes, at } from Race Tracker
  let athleteId = null;

  async function borrowToken() {
    // Kept until a minute before it runs out; without read_all, asked again after a minute, so
    // approving read_all on Strava (Race Tracker's setup-strava) shows here straight away.
    const fresh = token && token.expires_at * 1000 > now() + 60_000 &&
      (token.scopes.includes('read_all') || now() - token.at < 60_000);
    if (fresh) return token;
    let res;
    try {
      res = await fetchImpl(config.raceTrackerUrl, {
        method: 'POST',
        headers: { 'x-bike-dash-secret': config.raceTrackerSecret },
        signal: AbortSignal.timeout(15_000),
      });
    } catch {
      throw new RoutesError(503, 'race_tracker_unreachable');
    }
    let json = {};
    try { json = await res.json(); } catch { /* not JSON */ }
    if (res.status === 200 && json.access_token && json.expires_at) {
      token = {
        access_token: json.access_token,
        expires_at: Number(json.expires_at),
        scopes: Array.isArray(json.scopes) ? json.scopes : [],
        at: now(),
      };
      return token;
    }
    if (res.status === 401) throw new RoutesError(503, 'race_tracker_refused');
    throw new RoutesError(503, json.error === 'strava_not_connected' ? 'strava_not_connected' : 'race_tracker_error');
  }

  /** A Strava API GET. Resolves to the fetch Response (status 200); anything else throws. */
  async function stravaGet(pathAndQuery) {
    const { access_token } = await borrowToken();
    let res;
    try {
      res = await fetchImpl(STRAVA_API + pathAndQuery, {
        headers: { Authorization: `Bearer ${access_token}` },
        signal: AbortSignal.timeout(20_000),
      });
    } catch {
      throw new RoutesError(503, 'strava_unreachable');
    }
    if (res.status === 200) return res;
    if (res.status === 401) { token = null; throw new RoutesError(502, 'strava_auth'); }
    if (res.status === 403 || res.status === 404) throw new RoutesError(404, 'not_found');
    if (res.status === 429) throw new RoutesError(503, 'strava_busy');
    throw new RoutesError(502, 'strava_error', { status: res.status });
  }

  async function myAthleteId() {
    if (athleteId) return athleteId;
    const res = await stravaGet('/athlete');
    const json = await res.json();
    // The athlete id fits a JSON number, unlike route ids.
    if (!json || !json.id) throw new RoutesError(502, 'strava_error', { status: 200 });
    athleteId = String(json.id);
    return athleteId;
  }

  async function list() {
    const id = await myAthleteId();
    const routes = [];
    for (let page = 1; page <= MAX_PAGES; page++) {
      const res = await stravaGet(`/athletes/${id}/routes?page=${page}&per_page=${PER_PAGE}`);
      const batch = await res.json();
      if (!Array.isArray(batch)) throw new RoutesError(502, 'strava_error', { status: 200 });
      for (const r of batch) {
        const summary = routeSummary(r);
        if (summary.id) routes.push(summary);
      }
      if (batch.length < PER_PAGE) break;
    }
    routes.sort((a, b) => String(b.updated_at || '').localeCompare(String(a.updated_at || '')));
    const scopes = token ? token.scopes : [];
    return { status: 200, json: { routes, private_hidden: !scopes.includes('read_all') } };
  }

  async function gpx(routeId) {
    const res = await stravaGet(`/routes/${routeId}/export_gpx`);
    const text = await res.text();
    if (Buffer.byteLength(text) > MAX_GPX_BYTES) throw new RoutesError(502, 'gpx_too_large');
    if (!/<gpx[\s>]/.test(text.slice(0, 2000))) throw new RoutesError(502, 'not_gpx');
    return { status: 200, text, type: 'application/gpx+xml; charset=utf-8' };
  }

  async function health() {
    if (!isRoutesConfigured(config)) {
      return { status: 200, json: { ok: false, configured: false, read_all: false } };
    }
    try {
      const { scopes } = await borrowToken();
      const readAll = scopes.includes('read_all');
      const body = { ok: readAll, configured: true, read_all: readAll };
      if (!readAll) body.error = 'needs_read_all';
      return { status: 200, json: body };
    } catch (e) {
      const code = e instanceof RoutesError ? e.code : 'error';
      return { status: 200, json: { ok: false, configured: true, read_all: false, error: code } };
    }
  }

  /** `url.pathname` starts with ROUTES_BASE + '/'. */
  async function handle(req, url) {
    const route = url.pathname.slice(ROUTES_BASE.length);
    if (req.method !== 'GET') return { status: 405, json: { error: 'method_not_allowed' } };
    if (route === '/health') return health();

    const gpxMatch = /^\/([^/]+)\/gpx$/.exec(route);
    if (route !== '/list' && !gpxMatch) return { status: 404, json: { error: 'not_found' } };
    if (!isRoutesConfigured(config)) return { status: 503, json: { error: 'not_configured' } };
    if (!isAppKey(req.headers.authorization, config)) return { status: 401, json: { error: 'unauthorized' } };
    if (gpxMatch && !ROUTE_ID.test(gpxMatch[1])) return { status: 400, json: { error: 'bad_route_id' } };

    try {
      return route === '/list' ? await list() : await gpx(gpxMatch[1]);
    } catch (e) {
      if (!(e instanceof RoutesError)) throw e;
      return { status: e.status, json: { error: e.code, ...e.extra } };
    }
  }

  return { handle };
}

module.exports = {
  ROUTES_BASE, createRoutes, isRoutesConfigured, isAppKey, mintAppKey, newRoutesKeyId, routeSummary,
};
