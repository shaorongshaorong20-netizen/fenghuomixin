const jwt = require('jsonwebtoken');
const WebSocket = require('ws');
const crypto = require('crypto');

const { get, run } = require('./db/database');

let _wss = null;
let _jwtSecret = 'fenghuo_dev_secret';

const _clients = new Map();
const _calls = new Map();

function normalizeIp(raw) {
  const s = (raw || '').toString().trim();
  if (!s) return '';
  if (s.includes(',')) return normalizeIp(s.split(',')[0]);
  if (s.startsWith('::ffff:')) return s.slice('::ffff:'.length);
  return s;
}

function isPrivateIp(ip) {
  const s = normalizeIp(ip);
  if (!s) return true;
  if (s === '127.0.0.1' || s === '::1') return true;
  if (s.startsWith('10.')) return true;
  if (s.startsWith('192.168.')) return true;
  if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(s)) return true;
  if (s.startsWith('fc') || s.startsWith('fd')) return true;
  return false;
}

function extractIpFromReq(req) {
  if (!req) return '';
  const ip =
    req.headers['cf-connecting-ip'] ||
    req.headers['x-real-ip'] ||
    req.headers['x-forwarded-for'] ||
    (req.socket && req.socket.remoteAddress) ||
    '';
  return normalizeIp(ip);
}

async function getGeoFromCache(ip) {
  try {
    const row = await get('SELECT country, province FROM ip_geo_cache WHERE ip = ? LIMIT 1;', [
      normalizeIp(ip),
    ]);
    if (!row) return null;
    const country = (row.country || '').toString().trim();
    const province = (row.province || '').toString().trim();
    if (!country && !province) return null;
    return { country: country || null, province: province || null };
  } catch (_) {
    return null;
  }
}

async function saveGeoToCache(ip, geo) {
  try {
    await run(
      `
        INSERT INTO ip_geo_cache (ip, country, province, updated_at)
        VALUES (?, ?, ?, datetime('now'))
        ON CONFLICT(ip) DO UPDATE SET
          country = excluded.country,
          province = excluded.province,
          updated_at = datetime('now');
      `,
      [normalizeIp(ip), geo?.country || null, geo?.province || null]
    );
  } catch (_) {}
}

async function resolveGeoForIp(ip) {
  const n = normalizeIp(ip);
  if (!n || isPrivateIp(n)) return null;
  const cached = await getGeoFromCache(n);
  if (cached) return cached;
  try {
    const url = `https://ipapi.co/${encodeURIComponent(n)}/json/`;
    const res = await fetch(url, { method: 'GET' });
    if (!res.ok) return null;
    const j = await res.json();
    const country = (j && (j.country_name || j.country)) ? String(j.country_name || j.country).trim() : '';
    const province = (j && (j.region || j.region_code || j.region_name)) ? String(j.region || j.region_name || j.region_code).trim() : '';
    const geo = { country: country || null, province: province || null };
    if (!geo.country && !geo.province) return null;
    await saveGeoToCache(n, geo);
    return geo;
  } catch (_) {
    return null;
  }
}

function _safeSend(ws, data) {
  try {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(typeof data === 'string' ? data : JSON.stringify(data));
      return true;
    }
  } catch (_) {}
  return false;
}

function sendToUser(userId, message) {
  const set = _clients.get(Number(userId));
  if (!set) return 0;
  let count = 0;
  for (const ws of set) {
    if (_safeSend(ws, message)) count += 1;
  }
  return count;
}

function disconnectUser(userId, reason = 'account_disabled') {
  const uid = Number(userId);
  const set = _clients.get(uid);
  if (!set) return 0;
  let count = 0;
  for (const ws of set) {
    try {
      _safeSend(ws, { type: 'force_logout', reason });
      ws.close(4001, String(reason || 'force_logout').slice(0, 50));
    } catch (_) {}
    try {
      if (ws.sessionId) {
        run(
          `
            UPDATE admin_ws_sessions
            SET disconnected_at = COALESCE(disconnected_at, datetime('now')),
                close_code = COALESCE(close_code, 4001),
                close_reason = COALESCE(close_reason, ?)
            WHERE id = ?;
          `,
          [String(reason || 'force_logout'), String(ws.sessionId)]
        ).catch(() => {});
      }
    } catch (_) {}
    count += 1;
  }
  _clients.delete(uid);
  return count;
}

function initWebSocketServer(server, options = {}) {
  if (_wss) return _wss;

  _jwtSecret = options.jwtSecret || _jwtSecret;
  const path = options.path || '/ws';

  const wss = new WebSocket.Server({ server, path });
  _wss = wss;

  wss.on('connection', (ws, req) => {
    ws.userId = null;
    ws.sessionId = null;
    ws._ip = extractIpFromReq(req);
    ws._ua = ((req && req.headers && req.headers['user-agent']) || '').toString().slice(0, 220);
    ws._lastSeenUpdatedAtMs = 0;

    ws.on('message', async (buf) => {
      let msg = null;
      try {
        msg = JSON.parse(buf.toString());
      } catch (_) {
        return;
      }
      if (!msg || typeof msg !== 'object') return;

      const type = String(msg.type || '');
      if (!type) return;

      if (type === 'ping') {
        try {
          if (ws.sessionId) {
            const now = Date.now();
            if (!ws._lastSeenUpdatedAtMs || now - ws._lastSeenUpdatedAtMs >= 5000) {
              ws._lastSeenUpdatedAtMs = now;
              run(
                'UPDATE admin_ws_sessions SET last_seen_at = datetime(\'now\') WHERE id = ?;',
                [String(ws.sessionId)]
              ).catch(() => {});
            }
          }
        } catch (_) {}
        _safeSend(ws, { type: 'pong' });
        return;
      }

      if (type === 'auth') {
        const userId = Number(msg.userId);
        const token = String(msg.token || '');
        if (!userId || !token) {
          _safeSend(ws, { type: 'error', message: 'auth_failed' });
          return;
        }
        try {
          const payload = jwt.verify(token, _jwtSecret);
          if (!payload || Number(payload.userId) !== userId) {
            _safeSend(ws, { type: 'error', message: 'auth_failed' });
            return;
          }

          const row = await get(
            'SELECT id, username, status, role FROM accounts WHERE id = ? LIMIT 1;',
            [userId]
          );
          if (!row || String(row.status || '') !== 'active') {
            _safeSend(ws, { type: 'error', message: 'auth_failed' });
            try {
              ws.close(4001, 'account_inactive');
            } catch (_) {}
            return;
          }

          const username = String(row.username || '');
          const role = (username === 'admin' ? 'super' : (row.role || 'user')).toString();
          const isAdmin = role === 'admin' || role === 'super';
          if (!isAdmin) {
            try {
              await run(
                `
                  UPDATE accounts
                  SET last_login = datetime('now')
                  WHERE id = ?
                    AND (role IS NULL OR role = 'user')
                    AND (last_login IS NULL OR last_login < datetime('now', '-10 minutes'));
                `,
                [userId]
              );
            } catch (_) {}
          }

          if (isAdmin && role === 'admin' && username !== 'admin') {
            let maxSessions = -1;
            try {
              const p = await get(
                'SELECT max_admin_sessions FROM admin_permissions WHERE admin_id = ? LIMIT 1;',
                [userId]
              );
              const v = Number(p && p.max_admin_sessions);
              if (Number.isFinite(v)) maxSessions = v;
            } catch (_) {}
            if (Number.isFinite(maxSessions) && maxSessions >= 0) {
              try {
                const cntRow = await get(
                  'SELECT COUNT(1) AS cnt FROM admin_ws_sessions WHERE admin_id = ? AND disconnected_at IS NULL;',
                  [userId]
                );
                const cnt = Number(cntRow && cntRow.cnt) || 0;
                if (cnt >= maxSessions) {
                  _safeSend(ws, { type: 'error', message: 'too_many_devices' });
                  try {
                    ws.close(4003, 'too_many_devices');
                  } catch (_) {}
                  return;
                }
              } catch (_) {}
            }
          }

          ws.userId = userId;
          let set = _clients.get(userId);
          if (!set) {
            set = new Set();
            _clients.set(userId, set);
          }
          set.add(ws);

          if (isAdmin) {
            const sessionId = crypto.randomBytes(16).toString('hex');
            ws.sessionId = sessionId;
            const ip = ws._ip || '';
            const ua = ws._ua || '';
            const cached = await getGeoFromCache(ip);
            const country = cached?.country || null;
            const province = cached?.province || null;
            try {
              await run(
                `
                  INSERT INTO admin_ws_sessions (id, admin_id, ip, country, province, user_agent)
                  VALUES (?, ?, ?, ?, ?, ?);
                `,
                [sessionId, userId, ip || null, country, province, ua || null]
              );
            } catch (_) {}
            if (!country && !province && ip && !isPrivateIp(ip)) {
              Promise.resolve()
                .then(() => resolveGeoForIp(ip))
                .then(async (geo) => {
                  if (!geo) return;
                  try {
                    await run(
                      'UPDATE admin_ws_sessions SET country = COALESCE(country, ?), province = COALESCE(province, ?) WHERE id = ?;',
                      [geo.country || null, geo.province || null, sessionId]
                    );
                  } catch (_) {}
                })
                .catch(() => {});
            }
          }

          _safeSend(ws, { type: 'authed', userId });
        } catch (_) {
          _safeSend(ws, { type: 'error', message: 'auth_failed' });
        }
        return;
      }

      if (!ws.userId) {
        _safeSend(ws, { type: 'error', message: 'unauthorized' });
        return;
      }

      try {
        if (ws.sessionId) {
          const now = Date.now();
          if (!ws._lastSeenUpdatedAtMs || now - ws._lastSeenUpdatedAtMs >= 5000) {
            ws._lastSeenUpdatedAtMs = now;
            run(
              'UPDATE admin_ws_sessions SET last_seen_at = datetime(\'now\') WHERE id = ?;',
              [String(ws.sessionId)]
            ).catch(() => {});
          }
        }
      } catch (_) {}

      if (type === 'call') {
        const fromId = Number(msg.fromId);
        const toId = Number(msg.toId);
        const channelId = String(msg.channelId || '');
        const callId = String(msg.callId || '');
        if (!fromId || !toId || !channelId || !callId) return;
        if (fromId !== Number(ws.userId)) return;

        _calls.set(callId, { fromId, toId, channelId });
        const sent = sendToUser(toId, { type: 'call', fromId, toId, channelId, callId });
        if (!sent) {
          _calls.delete(callId);
          _safeSend(ws, {
            type: 'call_failed',
            callId,
            fromId,
            toId,
            reason: 'offline',
            message: '用户不在线',
          });
        }
        return;
      }

      if (type === 'accept' || type === 'reject' || type === 'hangup') {
        const callId = String(msg.callId || '');
        if (!callId) return;
        const info = _calls.get(callId);
        if (!info) return;

        const uid = Number(ws.userId);
        if (uid !== Number(info.fromId) && uid !== Number(info.toId)) return;

        const otherId = uid === Number(info.fromId) ? Number(info.toId) : Number(info.fromId);
        sendToUser(otherId, { type, callId, fromId: info.fromId, toId: info.toId });

        if (type === 'reject' || type === 'hangup') {
          _calls.delete(callId);
        }
        return;
      }
    });

    ws.on('close', (code, reason) => {
      const uid = ws.userId ? Number(ws.userId) : null;
      if (uid != null) {
        const set = _clients.get(uid);
        if (set) {
          set.delete(ws);
          if (set.size === 0) {
            _clients.delete(uid);
          }
        }
      }
      try {
        if (ws.sessionId) {
          run(
            `
              UPDATE admin_ws_sessions
              SET disconnected_at = COALESCE(disconnected_at, datetime('now')),
                  close_code = COALESCE(close_code, ?),
                  close_reason = COALESCE(close_reason, ?)
              WHERE id = ?;
            `,
            [
              Number(code) || null,
              reason ? String(reason).slice(0, 80) : null,
              String(ws.sessionId),
            ]
          ).catch(() => {});
        }
      } catch (_) {}
    });
  });

  return wss;
}

module.exports = {
  initWebSocketServer,
  sendToUser,
  disconnectUser,
};
