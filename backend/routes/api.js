const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { RtcTokenBuilder, RtcRole } = require('agora-access-token');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const { db, run, get, all } = require('../db/database');
const { sendToUser, disconnectUser } = require('../ws_handler');

const router = express.Router();

const JWT_SECRET = process.env.JWT_SECRET || 'fenghuo_dev_secret';
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '7d';

async function loadAuthUser(req) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token) {
    const err = new Error('未登录');
    err.status = 401;
    throw err;
  }
  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET);
  } catch (_) {
    const err = new Error('登录已过期');
    err.status = 401;
    throw err;
  }
  const userId = Number(payload && payload.userId);
  if (!userId) {
    const err = new Error('未登录');
    err.status = 401;
    throw err;
  }
  const row = await get(
    'SELECT id, username, status, role FROM accounts WHERE id = ? LIMIT 1;',
    [userId]
  );
  if (!row) {
    const err = new Error('账号不存在');
    err.status = 401;
    throw err;
  }
  if (String(row.status || '') !== 'active') {
    const err = new Error('账号已被禁用');
    err.status = 403;
    throw err;
  }
  const role = (String(row.username || '') === 'admin' ? 'super' : (row.role || 'user')).toString();
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
  const adminSessionIdFromToken = payload && payload.adminSessionId ? String(payload.adminSessionId) : '';
  const effectiveAdminSessionId = isAdmin
    ? (adminSessionIdFromToken || legacyAdminSessionIdFromToken(token))
    : '';
  if (isAdmin && effectiveAdminSessionId) {
    try {
      await ensureAdminMonitorTables();
      const s = await get('SELECT revoked_at FROM admin_http_sessions WHERE id = ? LIMIT 1;', [
        effectiveAdminSessionId,
      ]);
      if (s && s.revoked_at) {
        const err = new Error('已下线');
        err.status = 401;
        throw err;
      }
      if (!s) {
        const ip = extractClientIp(req);
        const ua = (req.headers['user-agent'] || '').toString().slice(0, 220);
        let geo = await getGeoFromCache(ip);
        if ((!geo || (!geo.country && !geo.province)) && ip && !isPrivateIp(ip)) {
          geo = await resolveGeoForIp(ip);
        }
        try {
          await run(
            `
              INSERT INTO admin_http_sessions (id, admin_id, ip, country, province, user_agent)
              VALUES (?, ?, ?, ?, ?, ?);
            `,
            [
              effectiveAdminSessionId,
              userId,
              ip || null,
              geo?.country || null,
              geo?.province || null,
              ua || null,
            ]
          );
        } catch (_) {}
      }
      const now = Date.now();
      if (!req._adminSessionLastSeenUpdatedAtMs || now - req._adminSessionLastSeenUpdatedAtMs >= 5000) {
        req._adminSessionLastSeenUpdatedAtMs = now;
        run('UPDATE admin_http_sessions SET last_seen_at = datetime(\'now\') WHERE id = ?;', [
          effectiveAdminSessionId,
        ]).catch(() => {});
      }
    } catch (e) {
      if (e && e.status) throw e;
    }
  }
  req.user = {
    userId,
    username: String(row.username || ''),
    isAdmin,
    role,
    adminSessionId: effectiveAdminSessionId || null,
  };
  return req.user;
}

function authRequired(req, res, next) {
  loadAuthUser(req)
    .then(() => next())
    .catch((e) => {
      const status = Number(e && e.status) || 401;
      const message = e && e.message ? String(e.message) : '未登录';
      res.status(status).json({ message });
    });
}

function adminRequired(req, res, next) {
  loadAuthUser(req)
    .then(() => {
      if (req.user && req.user.isAdmin) return next();
      return res.status(403).json({ message: '无权限' });
    })
    .catch((e) => {
      const status = Number(e && e.status) || 401;
      const message = e && e.message ? String(e.message) : '未登录';
      res.status(status).json({ message });
    });
}

function superAdminRequired(req, res, next) {
  loadAuthUser(req)
    .then(() => {
      if (!req.user || !req.user.isAdmin) return res.status(403).json({ message: '无权限' });
      if (req.user.role === 'super' || req.user.username === 'admin') return next();
      return res.status(403).json({ message: '无权限' });
    })
    .catch((e) => {
      const status = Number(e && e.status) || 401;
      const message = e && e.message ? String(e.message) : '未登录';
      res.status(status).json({ message });
    });
}

function boolToInt(v) {
  if (v === true) return 1;
  if (v === false) return 0;
  const s = (v ?? '').toString().trim().toLowerCase();
  if (s === '1' || s === 'true' || s === 'yes' || s === 'y') return 1;
  if (s === '0' || s === 'false' || s === 'no' || s === 'n') return 0;
  return null;
}

function parseCreateAccountLimit(v) {
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return null;
  if (n < -1) return null;
  return n;
}

function parseMaxAdminSessions(v) {
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return null;
  if (n < -1) return null;
  return n;
}

async function getAdminPermissionsRow(adminId) {
  try {
    const row = await get(
      'SELECT manage_accounts, view_audit, view_logs, create_account_limit, max_admin_sessions FROM admin_permissions WHERE admin_id = ? LIMIT 1;',
      [Number(adminId)]
    );
    return row || null;
  } catch (_) {
    return null;
  }
}

async function resolveAdminPermissions(reqUser) {
  const role = (reqUser?.role ?? '').toString();
  if (role === 'super' || reqUser?.username === 'admin') {
    return {
      manage_accounts: 1,
      view_audit: 1,
      view_logs: 1,
      create_account_limit: -1,
      max_admin_sessions: -1,
    };
  }
  if (role !== 'admin') {
    return {
      manage_accounts: 0,
      view_audit: 0,
      view_logs: 0,
      create_account_limit: 0,
      max_admin_sessions: 0,
    };
  }
  const row = await getAdminPermissionsRow(reqUser.userId);
  if (!row) {
    return {
      manage_accounts: 1,
      view_audit: 1,
      view_logs: 1,
      create_account_limit: -1,
      max_admin_sessions: -1,
    };
  }
  return {
    manage_accounts: Number(row.manage_accounts) === 1 ? 1 : 0,
    view_audit: Number(row.view_audit) === 1 ? 1 : 0,
    view_logs: Number(row.view_logs) === 1 ? 1 : 0,
    create_account_limit: Number.isFinite(Number(row.create_account_limit))
      ? Number(row.create_account_limit)
      : -1,
    max_admin_sessions: Number.isFinite(Number(row.max_admin_sessions))
      ? Number(row.max_admin_sessions)
      : -1,
  };
}

function adminPermissionRequired(permissionKey) {
  return (req, res, next) => {
    loadAuthUser(req)
      .then(async () => {
        if (!req.user || !req.user.isAdmin) return res.status(403).json({ message: '无权限' });
        const perms = await resolveAdminPermissions(req.user);
        if (Number(perms[permissionKey]) === 1) return next();
        return res.status(403).json({ message: '无权限' });
      })
      .catch((e) => {
        const status = Number(e && e.status) || 401;
        const message = e && e.message ? String(e.message) : '未登录';
        res.status(status).json({ message });
      });
  };
}

function toConversationId(a, b) {
  const x = Number(a);
  const y = Number(b);
  if (Number.isNaN(x) || Number.isNaN(y)) return null;
  const min = Math.min(x, y);
  const max = Math.max(x, y);
  return `${min}_${max}`;
}

function normalizeAccountStatus(status) {
  const s = (status || '').toString();
  if (s === '1' || s.toLowerCase() === 'active') return 'active';
  if (s === '0' || s.toLowerCase() === 'disabled') return 'disabled';
  return null;
}

function messageTypeFromContent(content) {
  const v = (content || '').toString().trim();
  if (v === '[图片]' || v === '[拍照]') return 'image';
  const lower = v.toLowerCase();
  if (
    lower.endsWith('.png') ||
    lower.endsWith('.jpg') ||
    lower.endsWith('.jpeg') ||
    lower.endsWith('.gif') ||
    lower.endsWith('.webp') ||
    lower.endsWith('.heic')
  ) {
    return 'image';
  }
  return 'text';
}

async function logAdminAction(req, action, target) {
  try {
    const operatorId = req.user ? Number(req.user.userId) : null;
    const operatorUsername = req.user ? String(req.user.username || '') : '';
    await run(
      'INSERT INTO admin_logs (operator_id, operator_username, action, target) VALUES (?, ?, ?, ?);',
      [operatorId, operatorUsername, String(action), target == null ? null : String(target)]
    );
  } catch (_) {}
}

async function getCreatedAccountCountByAdmin(adminId) {
  try {
    const row = await get(
      "SELECT COUNT(1) AS cnt FROM accounts WHERE created_by_admin_id = ? AND (role IS NULL OR role = 'user');",
      [Number(adminId)]
    );
    return Number(row && row.cnt) || 0;
  } catch (_) {
    return 0;
  }
}

let _adminMonitorTablesReady = false;
async function ensureAdminMonitorTables() {
  if (_adminMonitorTablesReady) return;
  try {
    await run(`ALTER TABLE admin_permissions ADD COLUMN max_admin_sessions INTEGER NOT NULL DEFAULT -1;`);
  } catch (_) {}

  try {
    await run(`
      CREATE TABLE IF NOT EXISTS ip_geo_cache (
        ip TEXT PRIMARY KEY,
        country TEXT,
        province TEXT,
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    `);
  } catch (_) {}

  try {
    await run(`
      CREATE TABLE IF NOT EXISTS admin_login_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        admin_id INTEGER NOT NULL,
        ip TEXT,
        country TEXT,
        province TEXT,
        user_agent TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY(admin_id) REFERENCES accounts(id) ON DELETE CASCADE
      );
    `);
  } catch (_) {}

  try {
    await run(`
      CREATE TABLE IF NOT EXISTS admin_ws_sessions (
        id TEXT PRIMARY KEY,
        admin_id INTEGER NOT NULL,
        ip TEXT,
        country TEXT,
        province TEXT,
        user_agent TEXT,
        connected_at TEXT NOT NULL DEFAULT (datetime('now')),
        last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
        disconnected_at TEXT,
        close_code INTEGER,
        close_reason TEXT,
        FOREIGN KEY(admin_id) REFERENCES accounts(id) ON DELETE CASCADE
      );
    `);
  } catch (_) {}

  try {
    await run(`
      CREATE TABLE IF NOT EXISTS admin_http_sessions (
        id TEXT PRIMARY KEY,
        admin_id INTEGER NOT NULL,
        ip TEXT,
        country TEXT,
        province TEXT,
        user_agent TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
        revoked_at TEXT,
        revoke_reason TEXT,
        FOREIGN KEY(admin_id) REFERENCES accounts(id) ON DELETE CASCADE
      );
    `);
  } catch (_) {}

  try {
    await run('CREATE INDEX IF NOT EXISTS idx_ip_geo_cache_updated_at ON ip_geo_cache(updated_at, ip);');
  } catch (_) {}
  try {
    await run('CREATE INDEX IF NOT EXISTS idx_admin_login_logs_admin_created ON admin_login_logs(admin_id, created_at, id);');
  } catch (_) {}
  try {
    await run('CREATE INDEX IF NOT EXISTS idx_admin_ws_sessions_admin_active ON admin_ws_sessions(admin_id, disconnected_at, last_seen_at);');
  } catch (_) {}
  try {
    await run('CREATE INDEX IF NOT EXISTS idx_admin_http_sessions_admin_active ON admin_http_sessions(admin_id, revoked_at, last_seen_at);');
  } catch (_) {}

  _adminMonitorTablesReady = true;
}

function normalizeIp(raw) {
  const s = (raw || '').toString().trim();
  if (!s) return '';
  if (s.includes(',')) return normalizeIp(s.split(',')[0]);
  if (s.startsWith('::ffff:')) return s.slice('::ffff:'.length);
  return s;
}

function toChinaTimeString(v) {
  const s = (v ?? '').toString().trim();
  if (!s) return s;
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/.exec(s);
  if (!m) return s;
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const hour = Number(m[4]);
  const minute = Number(m[5]);
  const second = Number(m[6]);
  if (
    !Number.isFinite(year) ||
    !Number.isFinite(month) ||
    !Number.isFinite(day) ||
    !Number.isFinite(hour) ||
    !Number.isFinite(minute) ||
    !Number.isFinite(second)
  ) {
    return s;
  }
  const ms = Date.UTC(year, month - 1, day, hour, minute, second) + 8 * 60 * 60 * 1000;
  const d = new Date(ms);
  const yy = d.getUTCFullYear().toString().padStart(4, '0');
  const mm = (d.getUTCMonth() + 1).toString().padStart(2, '0');
  const dd = d.getUTCDate().toString().padStart(2, '0');
  const hh = d.getUTCHours().toString().padStart(2, '0');
  const mi = d.getUTCMinutes().toString().padStart(2, '0');
  const ss = d.getUTCSeconds().toString().padStart(2, '0');
  return `${yy}-${mm}-${dd} ${hh}:${mi}:${ss}`;
}

function extractClientIp(req) {
  const ip =
    req.headers['cf-connecting-ip'] ||
    req.headers['x-real-ip'] ||
    req.headers['x-forwarded-for'] ||
    req.ip ||
    '';
  return normalizeIp(ip);
}

function legacyAdminSessionIdFromToken(token) {
  try {
    const h = crypto.createHash('sha256').update(String(token || '')).digest('hex');
    return `legacy_${h}`;
  } catch (_) {
    return '';
  }
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

async function getGeoFromCache(ip) {
  try {
    await ensureAdminMonitorTables();
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
    await ensureAdminMonitorTables();
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

async function fetchJsonWithTimeout(url, timeoutMs) {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), Math.max(200, Number(timeoutMs) || 1200));
  try {
    const res = await fetch(url, { method: 'GET', signal: controller.signal });
    if (!res.ok) return null;
    return await res.json();
  } catch (_) {
    return null;
  } finally {
    clearTimeout(t);
  }
}

async function resolveGeoForIp(ip) {
  const n = normalizeIp(ip);
  if (!n || isPrivateIp(n)) return null;
  await ensureAdminMonitorTables();
  const cached = await getGeoFromCache(n);
  if (cached) return cached;
  try {
    const j1 = await fetchJsonWithTimeout(`https://ipapi.co/${encodeURIComponent(n)}/json/`, 1200);
    const country1 = j1 && (j1.country_name || j1.country) ? String(j1.country_name || j1.country).trim() : '';
    const province1 = j1 && (j1.region || j1.region_code || j1.region_name) ? String(j1.region || j1.region_name || j1.region_code).trim() : '';
    if (country1 || province1) {
      const geo = { country: country1 || null, province: province1 || null };
      await saveGeoToCache(n, geo);
      return geo;
    }

    const j2 = await fetchJsonWithTimeout(
      `http://ip-api.com/json/${encodeURIComponent(n)}?fields=status,country,regionName`,
      1200
    );
    if (j2 && String(j2.status || '') === 'success') {
      const country2 = j2.country ? String(j2.country).trim() : '';
      const province2 = j2.regionName ? String(j2.regionName).trim() : '';
      if (country2 || province2) {
        const geo = { country: country2 || null, province: province2 || null };
        await saveGeoToCache(n, geo);
        return geo;
      }
    }

    return null;
  } catch (_) {
    return null;
  }
}

async function isBlocked(a, b) {
  try {
    const row = await get(
      'SELECT id FROM user_blocks WHERE user_id = ? AND blocked_user_id = ? LIMIT 1;',
      [Number(a), Number(b)]
    );
    return !!row;
  } catch (_) {
    return false;
  }
}

async function isEitherBlocked(a, b) {
  const x = Number(a);
  const y = Number(b);
  if (!x || !y) return false;
  const ab = await isBlocked(x, y);
  if (ab) return true;
  const ba = await isBlocked(y, x);
  return ba;
}

function safeExtFromMime(mime) {
  const m = (mime || '').toString().trim().toLowerCase();
  if (m === 'image/jpeg' || m === 'image/jpg') return '.jpg';
  if (m === 'image/png') return '.png';
  if (m === 'image/webp') return '.webp';
  if (m === 'image/gif') return '.gif';
  if (m === 'image/heic') return '.heic';
  return null;
}

function parseDataImage(dataUrl) {
  const s = (dataUrl || '').toString().trim();
  if (!s.startsWith('data:image/')) return null;
  const marker = ';base64,';
  const idx = s.indexOf(marker);
  if (idx < 0) return null;
  const header = s.slice(0, idx);
  const b64 = s.slice(idx + marker.length);
  const mime = header.slice('data:'.length);
  if (!mime.startsWith('image/')) return null;
  return { mime, b64 };
}

router.post('/api/auth/login', async (req, res) => {
  try {
    const username = (req.body.username || req.body.account || '').toString().trim();
    const password = (req.body.password || '').toString();
    if (!username || !password) {
      return res.status(400).json({ message: '账号或密码不能为空' });
    }

    const account = await get(
      'SELECT id, username, password, status, role FROM accounts WHERE username = ? LIMIT 1;',
      [username]
    );
    if (!account) return res.status(401).json({ message: '账号或密码错误' });
    if (account.status !== 'active') {
      return res.status(403).json({ message: '账号已被禁用' });
    }

    const ok = await bcrypt.compare(password, account.password);
    if (!ok) return res.status(401).json({ message: '账号或密码错误' });

    await run("UPDATE accounts SET last_login = datetime('now') WHERE id = ?;", [
      account.id,
    ]);

    const role = (account.username === 'admin' ? 'super' : (account.role || 'user')).toString();
    const isAdmin = role === 'admin' || role === 'super';

    let adminSessionId = '';
    let ip = '';
    let ua = '';
    let geo = null;
    if (isAdmin) {
      try {
        await ensureAdminMonitorTables();
      } catch (_) {}

      if (role === 'admin' && account.username !== 'admin') {
        let maxSessions = -1;
        try {
          const p = await get(
            'SELECT max_admin_sessions FROM admin_permissions WHERE admin_id = ? LIMIT 1;',
            [Number(account.id)]
          );
          const v = Number(p && p.max_admin_sessions);
          if (Number.isFinite(v)) maxSessions = v;
        } catch (_) {}
        if (Number.isFinite(maxSessions) && maxSessions === 0) {
          return res.status(403).json({ message: '该账号已被限制登录' });
        }
        if (Number.isFinite(maxSessions) && maxSessions > 0) {
          try {
            const cntRow = await get(
              `
                SELECT
                  (SELECT COUNT(1) FROM admin_ws_sessions WHERE admin_id = ? AND disconnected_at IS NULL) +
                  (SELECT COUNT(1) FROM admin_http_sessions WHERE admin_id = ? AND revoked_at IS NULL AND last_seen_at >= datetime('now', '-5 minutes'))
                AS cnt;
              `,
              [Number(account.id), Number(account.id)]
            );
            const cnt = Number(cntRow && cntRow.cnt) || 0;
            if (cnt >= maxSessions) {
              return res.status(403).json({ message: '该账号在线设备数已达上限' });
            }
          } catch (_) {}
        }
      }

      adminSessionId = crypto.randomBytes(16).toString('hex');
      ip = extractClientIp(req);
      ua = (req.headers['user-agent'] || '').toString().slice(0, 220);
      geo = await getGeoFromCache(ip);
      if ((!geo || (!geo.country && !geo.province)) && ip && !isPrivateIp(ip)) {
        geo = await resolveGeoForIp(ip);
      }
      const country = geo?.country || null;
      const province = geo?.province || null;

      let loginLogId = null;
      try {
        const r = await run(
          'INSERT INTO admin_login_logs (admin_id, ip, country, province, user_agent) VALUES (?, ?, ?, ?, ?);',
          [Number(account.id), ip || null, country, province, ua || null]
        );
        loginLogId = r && r.lastID ? Number(r.lastID) : null;
      } catch (_) {}

      try {
        await run(
          `
            INSERT INTO admin_http_sessions (id, admin_id, ip, country, province, user_agent)
            VALUES (?, ?, ?, ?, ?, ?);
          `,
          [adminSessionId, Number(account.id), ip || null, country, province, ua || null]
        );
      } catch (_) {}

      if ((!country && !province) && ip && !isPrivateIp(ip)) {
        Promise.resolve()
          .then(() => resolveGeoForIp(ip))
          .then(async (g) => {
            if (!g) return;
            try {
              if (loginLogId) {
                await run(
                  'UPDATE admin_login_logs SET country = COALESCE(country, ?), province = COALESCE(province, ?) WHERE id = ?;',
                  [g.country || null, g.province || null, loginLogId]
                );
              }
            } catch (_) {}
            try {
              if (adminSessionId) {
                await run(
                  'UPDATE admin_http_sessions SET country = COALESCE(country, ?), province = COALESCE(province, ?) WHERE id = ?;',
                  [g.country || null, g.province || null, adminSessionId]
                );
              }
            } catch (_) {}
          })
          .catch(() => {});
      }
    }

    const tokenPayload = { userId: account.id, username: account.username, isAdmin, role };
    if (adminSessionId) tokenPayload.adminSessionId = adminSessionId;
    const token = jwt.sign(tokenPayload, JWT_SECRET, { expiresIn: JWT_EXPIRES_IN });

    return res.json({ token, userId: account.id });
  } catch (e) {
    return res.status(500).json({ message: '登录失败' });
  }
});

router.post('/api/upload/image', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });

    const data = (req.body.data ?? req.body.dataUrl ?? req.body.image ?? '').toString();
    const parsed = parseDataImage(data);
    if (!parsed) return res.status(400).json({ message: '图片格式不正确' });

    const ext = safeExtFromMime(parsed.mime);
    if (!ext) return res.status(400).json({ message: '不支持的图片类型' });

    let buf;
    try {
      buf = Buffer.from(parsed.b64, 'base64');
    } catch (_) {
      return res.status(400).json({ message: '图片解析失败' });
    }
    if (!buf || !buf.length) return res.status(400).json({ message: '图片为空' });
    if (buf.length > 6 * 1024 * 1024) return res.status(400).json({ message: '图片太大' });

    const uploadsDir = path.join(__dirname, '..', 'uploads');
    try {
      if (!fs.existsSync(uploadsDir)) fs.mkdirSync(uploadsDir, { recursive: true });
    } catch (_) {}

    const filename = `${Date.now()}_${userId}_${crypto.randomBytes(8).toString('hex')}${ext}`;
    const fullPath = path.join(uploadsDir, filename);
    fs.writeFileSync(fullPath, buf);

    const proto = (req.headers['x-forwarded-proto'] || req.protocol)
      .toString()
      .split(',')[0]
      .trim();
    const host = req.get('host');
    const url = `${proto}://${host}/uploads/${encodeURIComponent(filename)}`;

    return res.json({ url });
  } catch (_) {
    return res.status(500).json({ message: '上传失败' });
  }
});

router.get('/api/admin/me', adminRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    const row = await get(
      'SELECT id, username, status, role, nickname, avatar, created_at, last_login FROM accounts WHERE id = ? LIMIT 1;',
      [userId]
    );
    if (!row) return res.status(404).json({ message: '账号不存在' });
    const perms = await resolveAdminPermissions(req.user);
    const isSuper = req.user && (req.user.role === 'super' || req.user.username === 'admin');
    const limit = Number(perms.create_account_limit);
    const used = isSuper ? 0 : await getCreatedAccountCountByAdmin(userId);
    const remaining = isSuper || limit < 0 ? -1 : Math.max(0, limit - used);
    return res.json({
      user: row,
      permissions: {
        manageAccounts: Number(perms.manage_accounts) === 1,
        viewAudit: Number(perms.view_audit) === 1,
        viewLogs: Number(perms.view_logs) === 1,
        createAccountLimit: isSuper ? -1 : limit,
        createAccountUsed: isSuper ? 0 : used,
        createAccountRemaining: remaining,
      },
    });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.get('/api/user/profile', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    const row = await get(
      'SELECT id, username, nickname, avatar, status, created_at, last_login, role FROM accounts WHERE id = ? LIMIT 1;',
      [userId]
    );
    return res.json({ data: row || null });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.get('/api/user/public', authRequired, async (req, res) => {
  try {
    const userId = Number(req.query.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    const row = await get(
      'SELECT id, username, nickname, avatar, status FROM accounts WHERE id = ? LIMIT 1;',
      [userId]
    );
    if (!row) return res.status(404).json({ message: '用户不存在' });
    return res.json({ data: row });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/user/profile/update', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    const nickname = (req.body.nickname ?? '').toString().trim();
    const avatar = (req.body.avatar ?? '').toString().trim();

    if (nickname.length > 30) return res.status(400).json({ message: '昵称最多 30 个字' });
    if (avatar.length > 600000) return res.status(400).json({ message: '头像太大' });
    if (avatar && !avatar.startsWith('data:image/')) {
      return res.status(400).json({ message: '头像格式不正确' });
    }

    await run(
      'UPDATE accounts SET nickname = ?, avatar = ? WHERE id = ?;',
      [nickname ? nickname : null, avatar ? avatar : null, userId]
    );

    const row = await get(
      'SELECT id, username, nickname, avatar, status, created_at, last_login, role FROM accounts WHERE id = ? LIMIT 1;',
      [userId]
    );

    try {
      const friends = await all(
        "SELECT friend_id FROM friends WHERE user_id = ? AND status = 'accepted' LIMIT 5000;",
        [userId]
      );
      for (const f of friends) {
        const fid = Number(f && f.friend_id);
        if (!fid) continue;
        sendToUser(fid, {
          type: 'profile_update',
          userId,
          username: row ? row.username : null,
          nickname: row ? row.nickname : null,
          avatar: row ? row.avatar : null,
        });
      }
    } catch (_) {}

    return res.json({ ok: true, data: row || null });
  } catch (_) {
    return res.status(500).json({ message: '保存失败' });
  }
});

router.get('/api/user/remarks', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    const rows = await all(
      'SELECT peer_id AS peerId, remark, updated_at AS updatedAt FROM user_remarks WHERE user_id = ? ORDER BY peer_id ASC LIMIT 5000;',
      [userId]
    );
    return res.json({ remarks: rows || [] });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.get('/api/user/remark', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const peerId = Number(req.query.peerId);
    if (!userId || !peerId) return res.status(400).json({ message: '参数错误' });
    const row = await get(
      'SELECT remark, updated_at AS updatedAt FROM user_remarks WHERE user_id = ? AND peer_id = ? LIMIT 1;',
      [userId, peerId]
    );
    return res.json({ remark: row ? row.remark : '' });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/user/remark', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const peerId = Number(req.body.peerId);
    const remark = (req.body.remark ?? '').toString().trim();
    if (!userId || !peerId) return res.status(400).json({ message: '参数错误' });
    if (remark.length > 30) return res.status(400).json({ message: '备注最多 30 个字' });

    if (!remark) {
      await run('DELETE FROM user_remarks WHERE user_id = ? AND peer_id = ?;', [
        userId,
        peerId,
      ]);
      return res.json({ ok: true });
    }

    await run(
      `
        INSERT INTO user_remarks (user_id, peer_id, remark, updated_at)
        VALUES (?, ?, ?, datetime('now'))
        ON CONFLICT(user_id, peer_id) DO UPDATE SET
          remark = excluded.remark,
          updated_at = datetime('now');
      `,
      [userId, peerId, remark]
    );
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '保存失败' });
  }
});

router.post('/api/user/change-password', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const oldPassword = (req.body.oldPassword || '').toString();
    const newPassword = (req.body.newPassword || '').toString();
    if (!userId || !oldPassword || !newPassword) {
      return res.status(400).json({ message: '参数错误' });
    }
    if (newPassword.length < 6) {
      return res.status(400).json({ message: '新密码至少 6 位' });
    }

    const account = await get('SELECT id, password FROM accounts WHERE id = ? LIMIT 1;', [
      userId,
    ]);
    if (!account) return res.status(404).json({ message: '账号不存在' });

    const ok = await bcrypt.compare(oldPassword, account.password);
    if (!ok) return res.status(400).json({ message: '旧密码错误' });

    const passwordHash = await bcrypt.hash(newPassword, 10);
    await run('UPDATE accounts SET password = ? WHERE id = ?;', [passwordHash, userId]);
    await logAdminAction(req, 'change_password', `account:${userId}`);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '修改失败' });
  }
});

router.get('/api/user/search', authRequired, async (req, res) => {
  try {
    const username = (req.query.username || '').toString().trim();
    if (!username) return res.json({ users: [] });

    const users = await all(
      "SELECT id, username, nickname, avatar, status, created_at, last_login FROM accounts WHERE username LIKE ? LIMIT 50;",
      [`%${username}%`]
    );
    return res.json({ users });
  } catch (_) {
    return res.status(500).json({ message: '搜索失败' });
  }
});

router.post('/api/friend/add', authRequired, async (req, res) => {
  try {
    const authUserId = Number(req.user && req.user.userId);
    const bodyUserId = Number(req.body.userId ?? req.body.fromId ?? req.body.fromUserId ?? 0);
    const userId = authUserId;
    const friendId = Number(req.body.friendId ?? req.body.toId ?? req.body.peerId);
    if (!userId || !friendId || userId === friendId) {
      return res.status(400).json({ message: '参数错误' });
    }
    if (bodyUserId && bodyUserId !== userId) {
      return res.status(403).json({ message: '无权限' });
    }

    const friend = await get('SELECT id, status FROM accounts WHERE id = ?;', [
      friendId,
    ]);
    if (!friend) return res.status(404).json({ message: '用户不存在' });
    if (friend.status !== 'active') return res.status(403).json({ message: '用户不可用' });

    const existing = await get(
      'SELECT id, status FROM friends WHERE user_id = ? AND friend_id = ? LIMIT 1;',
      [userId, friendId]
    );
    if (existing) {
      if (existing.status === 'pending') return res.json({ ok: true });
      if (existing.status === 'accepted') return res.status(409).json({ message: '已是好友' });
    }

    const reverse = await get(
      'SELECT id, status FROM friends WHERE user_id = ? AND friend_id = ? LIMIT 1;',
      [friendId, userId]
    );
    if (reverse && reverse.status === 'accepted') {
      await run(
        "INSERT OR REPLACE INTO friends (user_id, friend_id, status, created_at) VALUES (?, ?, 'accepted', datetime('now'));",
        [userId, friendId]
      );
      try {
        const me = await get(
          'SELECT id, username, nickname, avatar FROM accounts WHERE id = ? LIMIT 1;',
          [userId]
        );
        const peer = await get(
          'SELECT id, username, nickname, avatar FROM accounts WHERE id = ? LIMIT 1;',
          [friendId]
        );
        sendToUser(friendId, {
          type: 'friend_accepted',
          fromId: userId,
          fromUsername: me ? me.username : null,
          fromNickname: me ? me.nickname : null,
          fromAvatar: me ? me.avatar : null,
        });
        sendToUser(userId, {
          type: 'friend_accepted',
          fromId: friendId,
          fromUsername: peer ? peer.username : null,
          fromNickname: peer ? peer.nickname : null,
          fromAvatar: peer ? peer.avatar : null,
        });
      } catch (_) {}
      return res.json({ ok: true });
    }

    await run(
      "INSERT INTO friends (user_id, friend_id, status) VALUES (?, ?, 'pending');",
      [userId, friendId]
    );
    try {
      const me = await get(
        'SELECT id, username, nickname, avatar FROM accounts WHERE id = ? LIMIT 1;',
        [userId]
      );
      sendToUser(friendId, {
        type: 'friend_request',
        fromId: userId,
        fromUsername: me ? me.username : null,
        fromNickname: me ? me.nickname : null,
        fromAvatar: me ? me.avatar : null,
      });
    } catch (_) {}
    return res.json({ ok: true });
  } catch (e) {
    if (String(e && e.message || '').includes('UNIQUE')) {
      return res.json({ ok: true });
    }
    return res.status(500).json({ message: '发送失败' });
  }
});

router.get('/api/friend/requests/:userId', authRequired, async (req, res) => {
  try {
    const authUserId = Number(req.user && req.user.userId);
    const userId = Number(req.params.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    if (!authUserId || authUserId !== userId) {
      return res.status(403).json({ message: '无权限' });
    }

    const requests = await all(
      `
      SELECT
        f.id,
        f.user_id as from_user_id,
        a.username as from_username,
        a.nickname as from_nickname,
        a.avatar as from_avatar,
        f.created_at
      FROM friends f
      JOIN accounts a ON a.id = f.user_id
      WHERE f.friend_id = ? AND f.status = 'pending'
      ORDER BY f.id DESC
      LIMIT 200;
      `,
      [userId]
    );
    return res.json({ requests });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/friend/accept', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const requesterId = Number(req.body.requesterId || req.body.fromUserId);
    if (!userId || !requesterId) return res.status(400).json({ message: '参数错误' });

    const pending = await get(
      "SELECT id FROM friends WHERE user_id = ? AND friend_id = ? AND status = 'pending' LIMIT 1;",
      [requesterId, userId]
    );
    if (!pending) return res.status(404).json({ message: '申请不存在' });

    await run("UPDATE friends SET status = 'accepted' WHERE id = ?;", [pending.id]);
    await run(
      "INSERT OR REPLACE INTO friends (user_id, friend_id, status, created_at) VALUES (?, ?, 'accepted', datetime('now'));",
      [userId, requesterId]
    );
    try {
      const me = await get(
        'SELECT id, username, nickname, avatar FROM accounts WHERE id = ? LIMIT 1;',
        [userId]
      );
      const peer = await get(
        'SELECT id, username, nickname, avatar FROM accounts WHERE id = ? LIMIT 1;',
        [requesterId]
      );
      sendToUser(requesterId, {
        type: 'friend_accepted',
        fromId: userId,
        fromUsername: me ? me.username : null,
        fromNickname: me ? me.nickname : null,
        fromAvatar: me ? me.avatar : null,
      });
      sendToUser(userId, {
        type: 'friend_accepted',
        fromId: requesterId,
        fromUsername: peer ? peer.username : null,
        fromNickname: peer ? peer.nickname : null,
        fromAvatar: peer ? peer.avatar : null,
      });
    } catch (_) {}
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '操作失败' });
  }
});

router.get('/api/friend/list/:userId', authRequired, async (req, res) => {
  try {
    const authUserId = Number(req.user && req.user.userId);
    const userId = Number(req.params.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    if (!authUserId || authUserId !== userId) {
      return res.status(403).json({ message: '无权限' });
    }

    const friends = await all(
      `
      SELECT a.id, a.username, a.nickname, a.avatar, a.status, f.created_at
      FROM friends f
      JOIN accounts a ON a.id = f.friend_id
      WHERE f.user_id = ? AND f.status = 'accepted'
      ORDER BY a.username ASC
      LIMIT 1000;
      `,
      [userId]
    );
    return res.json({ friends });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/messages/send', authRequired, async (req, res) => {
  try {
    const fromId = Number(req.body.fromId);
    const toId = Number(req.body.toId);
    const content = (req.body.content || '').toString();
    const replyToId = Number(req.body.replyToId ?? req.body.reply_to_id ?? 0);
    if (!fromId || !toId) return res.status(400).json({ message: '参数错误' });
    if (!req.user || Number(req.user.userId) !== fromId) {
      return res.status(403).json({ message: '无权限' });
    }
    if (await isEitherBlocked(fromId, toId)) {
      return res.status(403).json({ message: '对方不可接收消息' });
    }

    const conversationId = toConversationId(fromId, toId);
    if (!conversationId) return res.status(400).json({ message: '参数错误' });

    let replyId = null;
    let replyPreview = null;
    if (Number.isFinite(replyToId) && replyToId > 0) {
      const ref = await get(
        `
        SELECT
          id,
          is_deleted,
          is_revoked,
          CASE
            WHEN is_deleted = 1 THEN '已删除'
            WHEN is_revoked = 1 THEN '已撤回'
            WHEN lower(content) LIKE 'data:image/%' THEN '[图片]'
            WHEN lower(content) LIKE 'http%' AND (
              lower(content) LIKE '%.png' OR
              lower(content) LIKE '%.jpg' OR
              lower(content) LIKE '%.jpeg' OR
              lower(content) LIKE '%.gif' OR
              lower(content) LIKE '%.webp' OR
              lower(content) LIKE '%.heic'
            ) THEN '[图片]'
            ELSE (
              CASE
                WHEN length(content) > 80 THEN substr(replace(replace(content, char(10), ' '), char(13), ' '), 1, 80) || '…'
                ELSE replace(replace(content, char(10), ' '), char(13), ' ')
              END
            )
          END AS preview
        FROM messages
        WHERE id = ? AND conversation_id = ?
        LIMIT 1;
        `,
        [replyToId, conversationId]
      );
      if (!ref) return res.status(400).json({ message: '引用消息不存在' });
      replyId = Number(ref.id);
      replyPreview = (ref.preview ?? '').toString();
    }

    const result = await run(
      'INSERT INTO messages (conversation_id, sender_id, content, reply_to_id) VALUES (?, ?, ?, ?);',
      [conversationId, fromId, content, replyId]
    );

    const row = await get('SELECT * FROM messages WHERE id = ?;', [result.lastID]);
    if (row && row.timestamp) {
      row.timestamp = toChinaTimeString(row.timestamp);
    }
    try {
      const sender = await get(
        'SELECT id, username, nickname, avatar FROM accounts WHERE id = ? LIMIT 1;',
        [fromId]
      );
      const pushContent = content.trim().startsWith('data:image/') ? '[图片]' : content;
      sendToUser(toId, {
        type: 'new_message',
        fromId,
        toId,
        conversationId,
        messageId: row ? row.id : result.lastID,
        content: pushContent,
        timestamp: row ? row.timestamp : null,
        replyToId: replyId,
        replyPreview,
        fromUsername: sender ? sender.username : null,
        fromNickname: sender ? sender.nickname : null,
        fromAvatar: sender ? sender.avatar : null,
      });
    } catch (_) {}
    try {
      const messageType = messageTypeFromContent(content);
      await run(
        'INSERT INTO message_audit (sender_id, receiver_id, message_type) VALUES (?, ?, ?);',
        [fromId, toId, messageType]
      );
    } catch (_) {}
    return res.json({ message: row });
  } catch (_) {
    return res.status(500).json({ message: '发送失败' });
  }
});

router.post('/api/block', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const blockedId = Number(req.body.blockedId ?? req.body.peerId ?? req.body.userId);
    if (!userId || !blockedId || userId === blockedId) {
      return res.status(400).json({ message: '参数错误' });
    }
    await run(
      'INSERT OR REPLACE INTO user_blocks (user_id, blocked_user_id, created_at) VALUES (?, ?, datetime(\'now\'));',
      [userId, blockedId]
    );
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '操作失败' });
  }
});

router.post('/api/unblock', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const blockedId = Number(req.body.blockedId ?? req.body.peerId ?? req.body.userId);
    if (!userId || !blockedId || userId === blockedId) {
      return res.status(400).json({ message: '参数错误' });
    }
    await run('DELETE FROM user_blocks WHERE user_id = ? AND blocked_user_id = ?;', [
      userId,
      blockedId,
    ]);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '操作失败' });
  }
});

router.get('/api/block/status', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const peerId = Number(req.query.peerId ?? req.query.userId);
    if (!userId || !peerId || userId === peerId) {
      return res.status(400).json({ message: '参数错误' });
    }
    const iBlocked = await isBlocked(userId, peerId);
    const blockedMe = await isBlocked(peerId, userId);
    return res.json({ iBlocked, blockedMe });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/reports/message', authRequired, async (req, res) => {
  try {
    const reporterId = Number(req.user && req.user.userId);
    const messageId = Number(req.body.messageId ?? req.body.id);
    const reason = (req.body.reason ?? '').toString().trim();
    const detail = (req.body.detail ?? '').toString().trim().slice(0, 500);
    if (!reporterId || !messageId || !reason) {
      return res.status(400).json({ message: '参数错误' });
    }

    const msg = await get(
      'SELECT id, conversation_id, sender_id, content, is_deleted, is_revoked FROM messages WHERE id = ? LIMIT 1;',
      [messageId]
    );
    if (!msg) return res.status(404).json({ message: '消息不存在' });
    const conversationId = (msg.conversation_id ?? '').toString();
    const parts = conversationId.split('_').map((v) => Number(v));
    const a = parts.length >= 2 ? parts[0] : 0;
    const b = parts.length >= 2 ? parts[1] : 0;
    if (!a || !b) return res.status(400).json({ message: '参数错误' });
    if (reporterId !== a && reporterId !== b) return res.status(403).json({ message: '无权限' });

    const reportedUserId = Number(msg.sender_id || 0) || null;
    const contentText = (msg.content ?? '').toString();
    await run(
      `
      INSERT INTO ugc_reports (reporter_id, reported_user_id, message_id, conversation_id, reason, detail, status, created_at)
      VALUES (?, ?, ?, ?, ?, ?, 'pending', datetime('now'));
      `,
      [reporterId, reportedUserId, messageId, conversationId, reason, detail || null]
    );

    try {
      await logAdminAction(
        { user: { userId: reporterId, username: req.user ? req.user.username : '' } },
        'ugc_report',
        `msg:${messageId}:reported:${reportedUserId || 0}:reason:${reason}:${contentText.slice(0, 60)}`
      );
    } catch (_) {}

    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '举报失败' });
  }
});

router.get('/api/admin/reports', adminPermissionRequired('view_logs'), async (req, res) => {
  try {
    const status = (req.query.status || '').toString().trim();
    const where = [];
    const params = [];
    if (status) {
      where.push('r.status = ?');
      params.push(status);
    }
    const sql = `
      SELECT
        r.id,
        r.reporter_id AS reporterId,
        ra.username AS reporter,
        r.reported_user_id AS reportedUserId,
        ua.username AS reportedUser,
        r.message_id AS messageId,
        r.conversation_id AS conversationId,
        r.reason,
        r.detail,
        r.status,
        r.action,
        r.handled_by AS handledBy,
        r.handled_at AS handledAt,
        r.created_at AS createdAt
      FROM ugc_reports r
      LEFT JOIN accounts ra ON ra.id = r.reporter_id
      LEFT JOIN accounts ua ON ua.id = r.reported_user_id
      ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
      ORDER BY r.id DESC
      LIMIT 2000;
    `;
    const rows = await all(sql, params);
    return res.json({ reports: rows || [] });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/admin/reports/resolve', adminPermissionRequired('view_logs'), async (req, res) => {
  try {
    const operatorId = Number(req.user && req.user.userId);
    const id = Number(req.body.id ?? req.body.reportId);
    const action = (req.body.action ?? 'none').toString().trim();
    const note = (req.body.note ?? '').toString().trim().slice(0, 500);
    if (!operatorId || !id) return res.status(400).json({ message: '参数错误' });

    const report = await get('SELECT * FROM ugc_reports WHERE id = ? LIMIT 1;', [id]);
    if (!report) return res.status(404).json({ message: '记录不存在' });

    const messageId = Number(report.message_id || 0);
    const reportedUserId = Number(report.reported_user_id || 0);

    if (action === 'delete_message' && messageId) {
      await run('UPDATE messages SET is_deleted = 1 WHERE id = ?;', [messageId]);
    } else if (action === 'disable_user' && reportedUserId) {
      await run("UPDATE accounts SET status = 'disabled' WHERE id = ?;", [reportedUserId]);
    }

    await run(
      "UPDATE ugc_reports SET status = 'handled', action = ?, handled_by = ?, handled_at = datetime('now'), detail = COALESCE(detail, NULL) WHERE id = ?;",
      [action, operatorId, id]
    );

    if (note) {
      await logAdminAction(req, 'ugc_report_resolve', `report:${id}:${action}:${note}`);
    } else {
      await logAdminAction(req, 'ugc_report_resolve', `report:${id}:${action}`);
    }

    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '处理失败' });
  }
});

router.post('/api/messages/schedule', authRequired, async (req, res) => {
  try {
    const fromId = Number(req.user && req.user.userId);
    const toId = Number(req.body.toId);
    const content = (req.body.content ?? '').toString();
    const sendAtMs = Number(req.body.sendAtMs ?? req.body.send_at_ms);
    if (!fromId || !toId || !Number.isFinite(sendAtMs)) {
      return res.status(400).json({ message: '参数错误' });
    }
    if (await isEitherBlocked(fromId, toId)) {
      return res.status(403).json({ message: '对方不可接收消息' });
    }
    if (!content.trim()) return res.status(400).json({ message: '内容不能为空' });
    if (content.length > 600000) return res.status(400).json({ message: '内容太大' });

    const now = Date.now();
    if (sendAtMs < now + 5000) return res.status(400).json({ message: '发送时间过近' });

    const conversationId = toConversationId(fromId, toId);
    if (!conversationId) return res.status(400).json({ message: '参数错误' });

    const result = await run(
      `
      INSERT INTO scheduled_messages (from_id, to_id, conversation_id, content, send_at_ms, status)
      VALUES (?, ?, ?, ?, ?, 'pending');
      `,
      [fromId, toId, conversationId, content, Math.floor(sendAtMs)]
    );

    const row = await get('SELECT * FROM scheduled_messages WHERE id = ? LIMIT 1;', [
      result.lastID,
    ]);
    return res.json({ ok: true, task: row });
  } catch (_) {
    return res.status(500).json({ message: '创建失败' });
  }
});

router.get('/api/messages/scheduled', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const peerId = Number(req.query.peerId);
    if (!userId) return res.status(400).json({ message: '参数错误' });

    const where = ['from_id = ?'];
    const params = [userId];
    if (peerId) {
      where.push('to_id = ?');
      params.push(peerId);
    }

    const rows = await all(
      `
      SELECT id, from_id AS fromId, to_id AS toId, content, send_at_ms AS sendAtMs, status, created_at AS createdAt, sent_at_ms AS sentAtMs
      FROM scheduled_messages
      WHERE ${where.join(' AND ')}
      ORDER BY id DESC
      LIMIT 200;
      `,
      params
    );
    return res.json({ tasks: rows || [] });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/messages/scheduled/cancel', authRequired, async (req, res) => {
  try {
    const userId = Number(req.user && req.user.userId);
    const id = Number(req.body.id);
    if (!userId || !id) return res.status(400).json({ message: '参数错误' });

    const row = await get(
      'SELECT id, status FROM scheduled_messages WHERE id = ? AND from_id = ? LIMIT 1;',
      [id, userId]
    );
    if (!row) return res.status(404).json({ message: '任务不存在' });
    if (String(row.status) !== 'pending') {
      return res.status(400).json({ message: '不可取消' });
    }
    await run("UPDATE scheduled_messages SET status = 'cancelled' WHERE id = ? AND from_id = ?;", [
      id,
      userId,
    ]);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '取消失败' });
  }
});

router.post('/api/messages/read', authRequired, async (req, res) => {
  try {
    const userId = Number(req.body.userId);
    const peerId = Number(req.body.peerId);
    if (!userId || !peerId) return res.status(400).json({ message: '参数错误' });
    if (!req.user || Number(req.user.userId) !== userId) {
      return res.status(403).json({ message: '无权限' });
    }

    const conversationId = toConversationId(userId, peerId);
    if (!conversationId) return res.status(400).json({ message: '参数错误' });

    const row = await get(
      'SELECT MAX(id) AS maxId FROM messages WHERE conversation_id = ? AND is_deleted = 0;',
      [conversationId]
    );
    const maxId = Number(row && row.maxId ? row.maxId : 0);

    await run(
      `
      INSERT OR REPLACE INTO conversation_reads (user_id, conversation_id, last_read_id, updated_at)
      VALUES (?, ?, ?, datetime('now'));
      `,
      [userId, conversationId, maxId]
    );
    return res.json({ ok: true, lastReadId: maxId });
  } catch (_) {
    return res.status(500).json({ message: '操作失败' });
  }
});

router.get('/api/conversations', authRequired, async (req, res) => {
  try {
    const userId = Number(req.query.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    if (!req.user || Number(req.user.userId) !== userId) {
      return res.status(403).json({ message: '无权限' });
    }

    const rows = await all(
      `
      SELECT
        a.id,
        a.username,
        a.nickname,
        a.avatar,
        (
          SELECT m.content
          FROM messages m
          WHERE m.conversation_id = (CASE WHEN ? < a.id THEN printf('%d_%d', ?, a.id) ELSE printf('%d_%d', a.id, ?) END)
            AND m.is_deleted = 0
          ORDER BY m.id DESC
          LIMIT 1
        ) AS lastMessage,
        (
          SELECT m.timestamp
          FROM messages m
          WHERE m.conversation_id = (CASE WHEN ? < a.id THEN printf('%d_%d', ?, a.id) ELSE printf('%d_%d', a.id, ?) END)
            AND m.is_deleted = 0
          ORDER BY m.id DESC
          LIMIT 1
        ) AS lastTime,
        (
          SELECT COUNT(1)
          FROM messages m
          WHERE m.conversation_id = (CASE WHEN ? < a.id THEN printf('%d_%d', ?, a.id) ELSE printf('%d_%d', a.id, ?) END)
            AND m.is_deleted = 0
            AND m.is_revoked = 0
            AND m.sender_id != ?
            AND m.id > IFNULL((
              SELECT r.last_read_id
              FROM conversation_reads r
              WHERE r.user_id = ?
                AND r.conversation_id = (CASE WHEN ? < a.id THEN printf('%d_%d', ?, a.id) ELSE printf('%d_%d', a.id, ?) END)
              LIMIT 1
            ), 0)
        ) AS unreadCount
      FROM friends f
      JOIN accounts a ON a.id = f.friend_id
      WHERE f.user_id = ? AND f.status = 'accepted'
      ORDER BY (lastTime IS NULL) ASC, lastTime DESC, a.username ASC
      LIMIT 1000;
      `,
      [
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
        userId,
      ]
    );

    for (const r of rows || []) {
      if (r && r.lastTime) r.lastTime = toChinaTimeString(r.lastTime);
    }
    return res.json({ conversations: rows });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.get('/api/messages', authRequired, async (req, res) => {
  try {
    const fromId = Number(req.query.fromId);
    const toId = Number(req.query.toId);
    if (!fromId || !toId) return res.status(400).json({ message: '参数错误' });

    const conversationId = toConversationId(fromId, toId);
    if (!conversationId) return res.status(400).json({ message: '参数错误' });

    const afterId = Number(req.query.afterId || 0);
    const beforeId = Number(req.query.beforeId || 0);
    let limit = Number(req.query.limit || 0);
    const isIncremental = Number.isFinite(afterId) && afterId > 0;
    const isBefore = !isIncremental && Number.isFinite(beforeId) && beforeId > 0;

    if (!Number.isFinite(limit) || limit <= 0) {
      limit = isIncremental ? 200 : 50;
    }
    limit = Math.max(1, Math.floor(limit));
    limit = Math.min(limit, isIncremental ? 500 : 2000);

    let rows = [];
    if (isIncremental) {
      rows = await all(
        `
        SELECT
          m.id,
          m.conversation_id,
          m.sender_id,
          m.content,
          m.reply_to_id,
          CASE
            WHEN m.reply_to_id IS NULL THEN NULL
            WHEN r.id IS NULL THEN '引用消息不存在'
            WHEN r.is_deleted = 1 THEN '已删除'
            WHEN r.is_revoked = 1 THEN '已撤回'
            WHEN lower(r.content) LIKE 'data:image/%' THEN '[图片]'
            WHEN lower(r.content) LIKE 'http%' AND (
              lower(r.content) LIKE '%.png' OR
              lower(r.content) LIKE '%.jpg' OR
              lower(r.content) LIKE '%.jpeg' OR
              lower(r.content) LIKE '%.gif' OR
              lower(r.content) LIKE '%.webp' OR
              lower(r.content) LIKE '%.heic'
            ) THEN '[图片]'
            ELSE (
              CASE
                WHEN length(r.content) > 80 THEN substr(replace(replace(r.content, char(10), ' '), char(13), ' '), 1, 80) || '…'
                ELSE replace(replace(r.content, char(10), ' '), char(13), ' ')
              END
            )
          END AS reply_preview,
          m.is_deleted,
          m.is_revoked,
          m.timestamp
        FROM messages m
        LEFT JOIN messages r ON r.id = m.reply_to_id AND r.conversation_id = m.conversation_id
        WHERE m.conversation_id = ? AND m.is_deleted = 0 AND m.id > ?
        ORDER BY m.id ASC
        LIMIT ?;
        `,
        [conversationId, afterId, limit]
      );
    } else if (isBefore) {
      rows = await all(
        `
        SELECT
          m.id,
          m.conversation_id,
          m.sender_id,
          m.content,
          m.reply_to_id,
          CASE
            WHEN m.reply_to_id IS NULL THEN NULL
            WHEN r.id IS NULL THEN '引用消息不存在'
            WHEN r.is_deleted = 1 THEN '已删除'
            WHEN r.is_revoked = 1 THEN '已撤回'
            WHEN lower(r.content) LIKE 'data:image/%' THEN '[图片]'
            WHEN lower(r.content) LIKE 'http%' AND (
              lower(r.content) LIKE '%.png' OR
              lower(r.content) LIKE '%.jpg' OR
              lower(r.content) LIKE '%.jpeg' OR
              lower(r.content) LIKE '%.gif' OR
              lower(r.content) LIKE '%.webp' OR
              lower(r.content) LIKE '%.heic'
            ) THEN '[图片]'
            ELSE (
              CASE
                WHEN length(r.content) > 80 THEN substr(replace(replace(r.content, char(10), ' '), char(13), ' '), 1, 80) || '…'
                ELSE replace(replace(r.content, char(10), ' '), char(13), ' ')
              END
            )
          END AS reply_preview,
          m.is_deleted,
          m.is_revoked,
          m.timestamp
        FROM messages m
        LEFT JOIN messages r ON r.id = m.reply_to_id AND r.conversation_id = m.conversation_id
        WHERE m.conversation_id = ? AND m.is_deleted = 0 AND m.id < ?
        ORDER BY m.id DESC
        LIMIT ?;
        `,
        [conversationId, beforeId, limit]
      );
      rows = Array.isArray(rows) ? rows.reverse() : rows;
    } else {
      rows = await all(
        `
        SELECT
          m.id,
          m.conversation_id,
          m.sender_id,
          m.content,
          m.reply_to_id,
          CASE
            WHEN m.reply_to_id IS NULL THEN NULL
            WHEN r.id IS NULL THEN '引用消息不存在'
            WHEN r.is_deleted = 1 THEN '已删除'
            WHEN r.is_revoked = 1 THEN '已撤回'
            WHEN lower(r.content) LIKE 'data:image/%' THEN '[图片]'
            WHEN lower(r.content) LIKE 'http%' AND (
              lower(r.content) LIKE '%.png' OR
              lower(r.content) LIKE '%.jpg' OR
              lower(r.content) LIKE '%.jpeg' OR
              lower(r.content) LIKE '%.gif' OR
              lower(r.content) LIKE '%.webp' OR
              lower(r.content) LIKE '%.heic'
            ) THEN '[图片]'
            ELSE (
              CASE
                WHEN length(r.content) > 80 THEN substr(replace(replace(r.content, char(10), ' '), char(13), ' '), 1, 80) || '…'
                ELSE replace(replace(r.content, char(10), ' '), char(13), ' ')
              END
            )
          END AS reply_preview,
          m.is_deleted,
          m.is_revoked,
          m.timestamp
        FROM messages m
        LEFT JOIN messages r ON r.id = m.reply_to_id AND r.conversation_id = m.conversation_id
        WHERE m.conversation_id = ? AND m.is_deleted = 0
        ORDER BY m.id DESC
        LIMIT ?;
        `,
        [conversationId, limit]
      );
      rows = Array.isArray(rows) ? rows.reverse() : rows;
    }
    for (const r of rows || []) {
      if (r && r.timestamp) r.timestamp = toChinaTimeString(r.timestamp);
    }
    return res.json({ messages: rows });
  } catch (_) {
    return res.status(500).json({ message: '拉取失败' });
  }
});

router.get('/api/messages/unread', authRequired, async (req, res) => {
  try {
    const userId = Number(req.query.userId);
    if (!userId) return res.status(400).json({ message: '参数错误' });
    if (!req.user || Number(req.user.userId) !== userId) {
      return res.status(403).json({ message: '无权限' });
    }

    const likeA = `${userId}_%`;
    const likeB = `%_${userId}`;
    const row = await get(
      `
      SELECT COUNT(1) AS count
      FROM messages
      WHERE is_deleted = 0
        AND is_revoked = 0
        AND sender_id != ?
        AND (conversation_id LIKE ? OR conversation_id LIKE ?)
        AND timestamp >= datetime('now', '-5 seconds');
      `,
      [userId, likeA, likeB]
    );

    const count = Number(row && row.count ? row.count : 0);
    return res.json({ hasUnread: count > 0, count });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/messages/revoke', authRequired, async (req, res) => {
  try {
    const messageId = Number(req.body.messageId);
    const userId = Number(req.user && req.user.userId);
    if (!messageId || !userId) return res.status(400).json({ message: '参数错误' });

    const msg = await get('SELECT id, sender_id FROM messages WHERE id = ?;', [
      messageId,
    ]);
    if (!msg) return res.status(404).json({ message: '消息不存在' });
    if (Number(msg.sender_id) !== userId) return res.status(403).json({ message: '无权限' });

    await run('UPDATE messages SET is_revoked = 1 WHERE id = ?;', [messageId]);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '撤回失败' });
  }
});

router.post('/api/messages/revoke-simple', authRequired, async (req, res) => {
  try {
    const messageId = Number(req.body.messageId);
    const userId = Number(req.user && req.user.userId);
    if (!messageId || !userId) return res.status(400).json({ message: '参数错误' });

    const msg = await get('SELECT id, sender_id FROM messages WHERE id = ? LIMIT 1;', [
      messageId,
    ]);
    if (!msg) return res.status(404).json({ message: '消息不存在' });
    if (Number(msg.sender_id) !== userId) return res.status(403).json({ message: '无权限' });

    await run('UPDATE messages SET is_revoked = 1 WHERE id = ?;', [messageId]);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '撤回失败' });
  }
});

router.post('/api/messages/delete-simple', authRequired, async (req, res) => {
  try {
    const messageId = Number(req.body.messageId);
    const userId = Number(req.user && req.user.userId);
    if (!messageId || !userId) return res.status(400).json({ message: '参数错误' });

    const msg = await get(
      'SELECT id, conversation_id, sender_id FROM messages WHERE id = ? LIMIT 1;',
      [messageId]
    );
    if (!msg) return res.status(404).json({ message: '消息不存在' });
    const conversationId = (msg.conversation_id ?? '').toString();
    const parts = conversationId.split('_').map((v) => Number(v));
    const a = parts.length >= 2 ? parts[0] : 0;
    const b = parts.length >= 2 ? parts[1] : 0;
    if (!a || !b) return res.status(400).json({ message: '参数错误' });
    if (userId !== a && userId !== b) return res.status(403).json({ message: '无权限' });

    await run('UPDATE messages SET is_deleted = 1 WHERE id = ?;', [messageId]);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '删除失败' });
  }
});

router.post('/api/messages/delete', authRequired, async (req, res) => {
  try {
    const fromId = Number(req.body.fromId);
    const toId = Number(req.body.toId);
    if (!fromId || !toId) return res.status(400).json({ message: '参数错误' });

    const conversationId = toConversationId(fromId, toId);
    if (!conversationId) return res.status(400).json({ message: '参数错误' });

    await run('UPDATE messages SET is_deleted = 1 WHERE conversation_id = ?;', [
      conversationId,
    ]);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '删除失败' });
  }
});

router.post('/api/messages/clear', authRequired, async (req, res) => {
  try {
    const fromId = Number(req.body.fromId);
    const toId = Number(req.body.toId);
    if (!fromId || !toId) return res.status(400).json({ message: '参数错误' });

    const conversationId = toConversationId(fromId, toId);
    if (!conversationId) return res.status(400).json({ message: '参数错误' });

    await run('DELETE FROM messages WHERE conversation_id = ?;', [conversationId]);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '清空失败' });
  }
});

function buildAgoraTokenFromQuery(req) {
  const appId = process.env.AGORA_APP_ID || '';
  const appCertificate = process.env.AGORA_APP_CERTIFICATE || '';
  if (!appId || !appCertificate) {
    return { error: { status: 400, message: 'Agora 配置缺失' } };
  }

  const channelName = (req.query.channel || req.query.channelName || '').toString();
  const uid = Number(req.query.uid || 0);
  const expire = Number(req.query.expire || 3600);
  if (!channelName) return { error: { status: 400, message: '缺少 channel' } };

  const expireAt = Math.floor(Date.now() / 1000) + (expire > 0 ? expire : 3600);
  const role =
    String(req.query.role || 'publisher').toLowerCase() === 'subscriber'
      ? RtcRole.SUBSCRIBER
      : RtcRole.PUBLISHER;

  const token = RtcTokenBuilder.buildTokenWithUid(
    appId,
    appCertificate,
    channelName,
    uid,
    role,
    expireAt
  );

  return { token, appId, channelName, uid, expireAt };
}

router.get('/api/agora/token-simple', authRequired, async (req, res) => {
  try {
    const r = buildAgoraTokenFromQuery(req);
    if (r.error) return res.status(r.error.status).json({ message: r.error.message });
    return res.json({
      token: r.token,
      appId: r.appId,
      channel: r.channelName,
      uid: r.uid,
      expireAt: r.expireAt,
    });
  } catch (_) {
    return res.status(500).json({ message: '生成失败' });
  }
});

router.get('/api/agora/token', authRequired, async (req, res) => {
  try {
    const r = buildAgoraTokenFromQuery(req);
    if (r.error) return res.status(r.error.status).json({ message: r.error.message });
    return res.json({
      token: r.token,
      appId: r.appId,
      channel: r.channelName,
      uid: r.uid,
      expireAt: r.expireAt,
    });
  } catch (_) {
    return res.status(500).json({ message: '生成失败' });
  }
});

router.get('/api/admin/accounts', adminPermissionRequired('manage_accounts'), async (req, res) => {
  try {
    const isSuper = req.user && (req.user.role === 'super' || req.user.username === 'admin');
    const where = ["(a.role IS NULL OR a.role = 'user')"];
    const params = [];
    if (!isSuper) {
      where.push('(a.created_by_admin_id = ?)');
      params.push(Number(req.user.userId));
    }
    const rows = await all(
      `
        SELECT
          a.id,
          a.username,
          a.status,
          a.role,
          a.created_at,
          a.last_login,
          a.created_by_admin_id,
          ca.username AS created_by_admin_username
        FROM accounts a
        LEFT JOIN accounts ca ON ca.id = a.created_by_admin_id
        WHERE ${where.join(' AND ')}
        ORDER BY a.id DESC
        LIMIT 2000;
      `,
      params
    );
    for (const r of rows || []) {
      if (r && r.created_at) r.created_at = toChinaTimeString(r.created_at);
      if (r && r.last_login) r.last_login = toChinaTimeString(r.last_login);
    }
    return res.json({ accounts: rows });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/admin/accounts', adminPermissionRequired('manage_accounts'), async (req, res) => {
  try {
    const username = (req.body.username || '').toString().trim();
    const password = (req.body.password || '').toString();
    if (!username || !password) return res.status(400).json({ message: '参数错误' });

    const exists = await get('SELECT id FROM accounts WHERE username = ? LIMIT 1;', [
      username,
    ]);
    if (exists) return res.status(409).json({ message: '账号已存在' });

    const isSuper = req.user && (req.user.role === 'super' || req.user.username === 'admin');
    if (!isSuper) {
      const perms = await resolveAdminPermissions(req.user);
      const limit = Number(perms.create_account_limit);
      if (Number.isFinite(limit) && limit >= 0) {
        const used = await getCreatedAccountCountByAdmin(req.user.userId);
        if (used >= limit) {
          return res.status(403).json({ message: '新建账号数量已达上限' });
        }
      }
    }

    const passwordHash = await bcrypt.hash(password, 10);
    const result = await run(
      "INSERT INTO accounts (username, password, status, role, created_by_admin_id) VALUES (?, ?, 'active', 'user', ?);",
      [username, passwordHash, Number(req.user.userId)]
    );
    const created = await get(
      `
        SELECT
          a.id,
          a.username,
          a.status,
          a.role,
          a.created_at,
          a.last_login,
          a.created_by_admin_id,
          ca.username AS created_by_admin_username
        FROM accounts a
        LEFT JOIN accounts ca ON ca.id = a.created_by_admin_id
        WHERE a.id = ?;
      `,
      [result.lastID]
    );
    if (created && created.created_at) created.created_at = toChinaTimeString(created.created_at);
    if (created && created.last_login) created.last_login = toChinaTimeString(created.last_login);
    await logAdminAction(req, 'create_account', `account:${result.lastID}`);
    return res.json({ account: created });
  } catch (_) {
    return res.status(500).json({ message: '创建失败' });
  }
});

router.put('/api/admin/accounts/:id/status', adminPermissionRequired('manage_accounts'), async (req, res) => {
  try {
    const id = Number(req.params.id);
    const status = normalizeAccountStatus(req.body.status);
    if (!id || !status) {
      return res.status(400).json({ message: '参数错误' });
    }

    const isSuper = req.user && (req.user.role === 'super' || req.user.username === 'admin');
    if (!isSuper) {
      const owner = await get(
        "SELECT created_by_admin_id FROM accounts WHERE id = ? AND (role IS NULL OR role = 'user') LIMIT 1;",
        [id]
      );
      if (!owner) return res.status(404).json({ message: '账号不存在' });
      if (Number(owner.created_by_admin_id) !== Number(req.user.userId)) {
        return res.status(403).json({ message: '无权限' });
      }
    }

    await run("UPDATE accounts SET status = ? WHERE id = ? AND (role IS NULL OR role = 'user');", [
      status,
      id,
    ]);
    await logAdminAction(req, 'update_account_status', `account:${id}:${status}`);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '更新失败' });
  }
});

router.delete('/api/admin/accounts/:id', adminPermissionRequired('manage_accounts'), async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!id) return res.status(400).json({ message: '参数错误' });
    const isSuper = req.user && (req.user.role === 'super' || req.user.username === 'admin');
    if (!isSuper) {
      const owner = await get(
        "SELECT created_by_admin_id FROM accounts WHERE id = ? AND (role IS NULL OR role = 'user') LIMIT 1;",
        [id]
      );
      if (!owner) return res.status(404).json({ message: '账号不存在' });
      if (Number(owner.created_by_admin_id) !== Number(req.user.userId)) {
        return res.status(403).json({ message: '无权限' });
      }
    }
    await run("DELETE FROM accounts WHERE id = ? AND (role IS NULL OR role = 'user');", [id]);
    await logAdminAction(req, 'delete_account', `account:${id}`);
    try {
      disconnectUser(id, 'account_deleted');
    } catch (_) {}
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '删除失败' });
  }
});

router.get('/api/admin/admins', superAdminRequired, async (req, res) => {
  try {
    await ensureAdminMonitorTables();
    const rows = await all(`
      SELECT
        a.id,
        a.username,
        a.role,
        a.status,
        a.created_at,
        a.last_login,
        COALESCE(p.manage_accounts, 1) AS manage_accounts,
        COALESCE(p.view_audit, 1) AS view_audit,
        COALESCE(p.view_logs, 1) AS view_logs,
        COALESCE(p.create_account_limit, -1) AS create_account_limit,
        COALESCE(p.max_admin_sessions, -1) AS max_admin_sessions,
        (
          SELECT COUNT(1)
          FROM accounts ua
          WHERE ua.created_by_admin_id = a.id
            AND (ua.role IS NULL OR ua.role = 'user')
        ) AS created_account_used,
        (
          (SELECT COUNT(1) FROM admin_ws_sessions s WHERE s.admin_id = a.id AND s.disconnected_at IS NULL) +
          (SELECT COUNT(1) FROM admin_http_sessions hs WHERE hs.admin_id = a.id AND hs.revoked_at IS NULL AND hs.last_seen_at >= datetime('now', '-5 minutes'))
        ) AS online_sessions,
        (
          SELECT ip FROM admin_login_logs l
          WHERE l.admin_id = a.id
          ORDER BY l.id DESC
          LIMIT 1
        ) AS last_login_ip,
        (
          SELECT country FROM admin_login_logs l
          WHERE l.admin_id = a.id
          ORDER BY l.id DESC
          LIMIT 1
        ) AS last_login_country,
        (
          SELECT province FROM admin_login_logs l
          WHERE l.admin_id = a.id
          ORDER BY l.id DESC
          LIMIT 1
        ) AS last_login_province,
        (
          SELECT created_at FROM admin_login_logs l
          WHERE l.admin_id = a.id
          ORDER BY l.id DESC
          LIMIT 1
        ) AS last_login_at
      FROM accounts a
      LEFT JOIN admin_permissions p ON p.admin_id = a.id
      WHERE a.role IN ('admin', 'super')
      ORDER BY a.id DESC
      LIMIT 2000;
    `);
    for (const r of rows || []) {
      if (r && r.created_at) r.created_at = toChinaTimeString(r.created_at);
      if (r && r.last_login) r.last_login = toChinaTimeString(r.last_login);
      if (r && r.last_login_at) r.last_login_at = toChinaTimeString(r.last_login_at);
    }
    return res.json({ admins: rows });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.get('/api/admin/admins/:id/login-logs', superAdminRequired, async (req, res) => {
  try {
    await ensureAdminMonitorTables();
    const id = Number(req.params.id);
    if (!id) return res.status(400).json({ message: '参数错误' });
    const rows = await all(
      `
        SELECT id, admin_id AS adminId, ip, country, province, user_agent AS userAgent, created_at AS createdAt
        FROM admin_login_logs
        WHERE admin_id = ?
        ORDER BY id DESC
        LIMIT 200;
      `,
      [id]
    );
    let filled = 0;
    for (const r of rows || []) {
      if (filled >= 3) break;
      const ip = r && r.ip ? String(r.ip) : '';
      const country = r && r.country ? String(r.country).trim() : '';
      const province = r && r.province ? String(r.province).trim() : '';
      if ((country || province) || !ip || isPrivateIp(ip)) continue;
      const geo = await resolveGeoForIp(ip);
      if (!geo) continue;
      try {
        await run(
          'UPDATE admin_login_logs SET country = COALESCE(country, ?), province = COALESCE(province, ?) WHERE id = ?;',
          [geo.country || null, geo.province || null, Number(r.id)]
        );
      } catch (_) {}
      r.country = geo.country || null;
      r.province = geo.province || null;
      filled += 1;
    }
    for (const r of rows || []) {
      if (r && r.createdAt) r.createdAt = toChinaTimeString(r.createdAt);
    }
    return res.json({ logs: rows || [] });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.get('/api/admin/admins/:id/sessions', superAdminRequired, async (req, res) => {
  try {
    await ensureAdminMonitorTables();
    const id = Number(req.params.id);
    if (!id) return res.status(400).json({ message: '参数错误' });
    const rows = await all(
      `
        SELECT
          type,
          id,
          admin_id AS adminId,
          ip,
          country,
          province,
          user_agent AS userAgent,
          connected_at AS connectedAt,
          last_seen_at AS lastSeenAt,
          disconnected_at AS disconnectedAt,
          close_code AS closeCode,
          close_reason AS closeReason
        FROM (
          SELECT
            'ws' AS type,
            id,
            admin_id,
            ip,
            country,
            province,
            user_agent,
            connected_at,
            last_seen_at,
            disconnected_at,
            close_code,
            close_reason
          FROM admin_ws_sessions
          WHERE admin_id = ?
          UNION ALL
          SELECT
            'http' AS type,
            id,
            admin_id,
            ip,
            country,
            province,
            user_agent,
            created_at AS connected_at,
            last_seen_at,
            revoked_at AS disconnected_at,
            NULL AS close_code,
            revoke_reason AS close_reason
          FROM admin_http_sessions
          WHERE admin_id = ?
        )
        ORDER BY (disconnected_at IS NULL) DESC, last_seen_at DESC
        LIMIT 200;
      `,
      [id, id]
    );
    let filled = 0;
    for (const r of rows || []) {
      if (filled >= 3) break;
      const ip = r && r.ip ? String(r.ip) : '';
      const country = r && r.country ? String(r.country).trim() : '';
      const province = r && r.province ? String(r.province).trim() : '';
      if ((country || province) || !ip || isPrivateIp(ip)) continue;
      const geo = await resolveGeoForIp(ip);
      if (!geo) continue;
      const t = r && r.type ? String(r.type) : '';
      try {
        if (t === 'ws') {
          await run(
            'UPDATE admin_ws_sessions SET country = COALESCE(country, ?), province = COALESCE(province, ?) WHERE id = ?;',
            [geo.country || null, geo.province || null, String(r.id)]
          );
        } else if (t === 'http') {
          await run(
            'UPDATE admin_http_sessions SET country = COALESCE(country, ?), province = COALESCE(province, ?) WHERE id = ?;',
            [geo.country || null, geo.province || null, String(r.id)]
          );
        }
      } catch (_) {}
      r.country = geo.country || null;
      r.province = geo.province || null;
      filled += 1;
    }
    for (const r of rows || []) {
      if (r && r.connectedAt) r.connectedAt = toChinaTimeString(r.connectedAt);
      if (r && r.lastSeenAt) r.lastSeenAt = toChinaTimeString(r.lastSeenAt);
      if (r && r.disconnectedAt) r.disconnectedAt = toChinaTimeString(r.disconnectedAt);
    }
    return res.json({ sessions: rows || [] });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.post('/api/admin/admins/:id/kick', superAdminRequired, async (req, res) => {
  try {
    await ensureAdminMonitorTables();
    const id = Number(req.params.id);
    if (!id) return res.status(400).json({ message: '参数错误' });
    const row = await get(
      "SELECT id, username, role FROM accounts WHERE id = ? AND role IN ('admin', 'super') LIMIT 1;",
      [id]
    );
    if (!row) return res.status(404).json({ message: '账号不存在' });
    if (String(row.username || '') === 'admin' || String(row.role || '') === 'super') {
      return res.status(400).json({ message: '不可操作该账号' });
    }
    let disconnected = 0;
    try {
      disconnected = disconnectUser(id, 'kicked_by_super');
    } catch (_) {}
    try {
      await run(
        `
          UPDATE admin_ws_sessions
          SET disconnected_at = COALESCE(disconnected_at, datetime('now')),
              close_code = COALESCE(close_code, 4002),
              close_reason = COALESCE(close_reason, 'kicked_by_super')
          WHERE admin_id = ? AND disconnected_at IS NULL;
        `,
        [id]
      );
    } catch (_) {}
    try {
      await run(
        `
          UPDATE admin_http_sessions
          SET revoked_at = COALESCE(revoked_at, datetime('now')),
              revoke_reason = COALESCE(revoke_reason, 'kicked_by_super')
          WHERE admin_id = ? AND revoked_at IS NULL;
        `,
        [id]
      );
    } catch (_) {}
    await logAdminAction(req, 'kick_admin', `admin:${id}:disconnected:${disconnected}`);
    return res.json({ ok: true, disconnected });
  } catch (_) {
    return res.status(500).json({ message: '操作失败' });
  }
});

router.get('/api/admin/admins/:id/permissions', superAdminRequired, async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!id) return res.status(400).json({ message: '参数错误' });
    const row = await get(
      "SELECT id, username, role, status FROM accounts WHERE id = ? AND role IN ('admin', 'super') LIMIT 1;",
      [id]
    );
    if (!row) return res.status(404).json({ message: '账号不存在' });
    if (row.role === 'super') {
      return res.json({
        permissions: {
          manageAccounts: true,
          viewAudit: true,
          viewLogs: true,
          createAccountLimit: -1,
          createAccountUsed: 0,
          createAccountRemaining: -1,
          maxAdminSessions: -1,
        },
      });
    }
    const p = await getAdminPermissionsRow(id);
    const used = await getCreatedAccountCountByAdmin(id);
    if (!p) {
      return res.json({
        permissions: {
          manageAccounts: true,
          viewAudit: true,
          viewLogs: true,
          createAccountLimit: -1,
          createAccountUsed: used,
          createAccountRemaining: -1,
          maxAdminSessions: -1,
        },
      });
    }
    const limit = Number.isFinite(Number(p.create_account_limit)) ? Number(p.create_account_limit) : -1;
    const maxSessions = Number.isFinite(Number(p.max_admin_sessions)) ? Number(p.max_admin_sessions) : -1;
    return res.json({
      permissions: {
        manageAccounts: Number(p.manage_accounts) === 1,
        viewAudit: Number(p.view_audit) === 1,
        viewLogs: Number(p.view_logs) === 1,
        createAccountLimit: limit,
        createAccountUsed: used,
        createAccountRemaining: limit < 0 ? -1 : Math.max(0, limit - used),
        maxAdminSessions: maxSessions,
      },
    });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.put('/api/admin/admins/:id/permissions', superAdminRequired, async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!id) return res.status(400).json({ message: '参数错误' });
    const row = await get(
      "SELECT id, username, role, status FROM accounts WHERE id = ? AND role IN ('admin', 'super') LIMIT 1;",
      [id]
    );
    if (!row) return res.status(404).json({ message: '账号不存在' });
    if (row.role === 'super') return res.status(400).json({ message: '不可修改超级管理员权限' });

    const body = req.body || {};
    const cur = (await getAdminPermissionsRow(id)) || {
      manage_accounts: 1,
      view_audit: 1,
      view_logs: 1,
      create_account_limit: -1,
      max_admin_sessions: -1,
    };

    const hasMA = Object.prototype.hasOwnProperty.call(body, 'manageAccounts') ||
      Object.prototype.hasOwnProperty.call(body, 'manage_accounts');
    const hasVA = Object.prototype.hasOwnProperty.call(body, 'viewAudit') ||
      Object.prototype.hasOwnProperty.call(body, 'view_audit');
    const hasVL = Object.prototype.hasOwnProperty.call(body, 'viewLogs') ||
      Object.prototype.hasOwnProperty.call(body, 'view_logs');
    const hasLimit = Object.prototype.hasOwnProperty.call(body, 'createAccountLimit') ||
      Object.prototype.hasOwnProperty.call(body, 'create_account_limit');
    const hasMaxSessions = Object.prototype.hasOwnProperty.call(body, 'maxAdminSessions') ||
      Object.prototype.hasOwnProperty.call(body, 'max_admin_sessions');

    if (!hasMA && !hasVA && !hasVL && !hasLimit && !hasMaxSessions) {
      return res.status(400).json({ message: '参数错误' });
    }

    const ma = hasMA ? boolToInt(body.manageAccounts ?? body.manage_accounts) : Number(cur.manage_accounts) === 1 ? 1 : 0;
    const va = hasVA ? boolToInt(body.viewAudit ?? body.view_audit) : Number(cur.view_audit) === 1 ? 1 : 0;
    const vl = hasVL ? boolToInt(body.viewLogs ?? body.view_logs) : Number(cur.view_logs) === 1 ? 1 : 0;
    const nextLimitRaw = hasLimit ? parseCreateAccountLimit(body.createAccountLimit ?? body.create_account_limit) : Number(cur.create_account_limit);
    const nextMaxRaw = hasMaxSessions
      ? parseMaxAdminSessions(body.maxAdminSessions ?? body.max_admin_sessions)
      : Number(cur.max_admin_sessions);

    if (ma == null || va == null || vl == null || nextLimitRaw == null || nextMaxRaw == null) {
      return res.status(400).json({ message: '参数错误' });
    }
    const nextLimit = Number(nextLimitRaw);
    const nextMax = Number(nextMaxRaw);

    await run(
      `
        INSERT INTO admin_permissions (admin_id, manage_accounts, view_audit, view_logs, create_account_limit, max_admin_sessions, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(admin_id) DO UPDATE SET
          manage_accounts = excluded.manage_accounts,
          view_audit = excluded.view_audit,
          view_logs = excluded.view_logs,
          create_account_limit = excluded.create_account_limit,
          max_admin_sessions = excluded.max_admin_sessions,
          updated_at = datetime('now');
      `,
      [id, ma, va, vl, nextLimit, nextMax]
    );
    await logAdminAction(req, 'update_admin_permissions', `admin:${id}:${ma}:${va}:${vl}:limit:${nextLimit}:max:${nextMax}`);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '更新失败' });
  }
});

router.post('/api/admin/admins', superAdminRequired, async (req, res) => {
  try {
    const username = (req.body.username || '').toString().trim();
    const password = (req.body.password || '').toString();
    if (!username || !password) return res.status(400).json({ message: '参数错误' });
    if (username === 'admin') return res.status(400).json({ message: '不可创建该用户名' });

    const exists = await get('SELECT id FROM accounts WHERE username = ? LIMIT 1;', [
      username,
    ]);
    if (exists) return res.status(409).json({ message: '账号已存在' });

    const passwordHash = await bcrypt.hash(password, 10);
    const result = await run(
      "INSERT INTO accounts (username, password, status, role) VALUES (?, ?, 'active', 'admin');",
      [username, passwordHash]
    );
    await logAdminAction(req, 'create_admin', `admin:${result.lastID}`);
    const created = await get(
      "SELECT id, username, role, status, created_at, last_login FROM accounts WHERE id = ?;",
      [result.lastID]
    );
    return res.json({ admin: created });
  } catch (_) {
    return res.status(500).json({ message: '创建失败' });
  }
});

router.put('/api/admin/admins/:id/status', superAdminRequired, async (req, res) => {
  try {
    const id = Number(req.params.id);
    const status = normalizeAccountStatus(req.body.status);
    if (!id || !status) return res.status(400).json({ message: '参数错误' });
    const row = await get("SELECT username FROM accounts WHERE id = ? AND role IN ('admin', 'super') LIMIT 1;", [id]);
    if (!row) return res.status(404).json({ message: '账号不存在' });
    if (row.username === 'admin') return res.status(400).json({ message: '不可修改该账号' });

    await run("UPDATE accounts SET status = ? WHERE id = ? AND role IN ('admin', 'super');", [
      status,
      id,
    ]);
    await logAdminAction(req, 'update_admin_status', `admin:${id}:${status}`);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '更新失败' });
  }
});

router.delete('/api/admin/admins/:id', superAdminRequired, async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!id) return res.status(400).json({ message: '参数错误' });
    const row = await get("SELECT username FROM accounts WHERE id = ? AND role IN ('admin', 'super') LIMIT 1;", [id]);
    if (!row) return res.status(404).json({ message: '账号不存在' });
    if (row.username === 'admin') return res.status(400).json({ message: '不可删除该账号' });
    await run("DELETE FROM accounts WHERE id = ? AND role IN ('admin', 'super');", [id]);
    await logAdminAction(req, 'delete_admin', `admin:${id}`);
    try {
      disconnectUser(id, 'account_deleted');
    } catch (_) {}
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '删除失败' });
  }
});

router.post('/api/admin/admins/:id/reset-password', superAdminRequired, async (req, res) => {
  try {
    const id = Number(req.params.id);
    const password = (req.body.password || '').toString();
    if (!id || !password) return res.status(400).json({ message: '参数错误' });
    const row = await get("SELECT username FROM accounts WHERE id = ? AND role IN ('admin', 'super') LIMIT 1;", [id]);
    if (!row) return res.status(404).json({ message: '账号不存在' });
    if (row.username === 'admin') return res.status(400).json({ message: '不可操作该账号' });
    const passwordHash = await bcrypt.hash(password, 10);
    await run("UPDATE accounts SET password = ? WHERE id = ? AND role IN ('admin', 'super');", [
      passwordHash,
      id,
    ]);
    await logAdminAction(req, 'reset_admin_password', `admin:${id}`);
    return res.json({ ok: true });
  } catch (_) {
    return res.status(500).json({ message: '重置失败' });
  }
});

router.get('/api/admin/messages', adminPermissionRequired('view_audit'), async (req, res) => {
  try {
    const sender = (req.query.sender || '').toString().trim();
    const receiver = (req.query.receiver || '').toString().trim();

    const where = [];
    const params = [];
    if (sender) {
      where.push('sa.username LIKE ?');
      params.push(`%${sender}%`);
    }
    if (receiver) {
      where.push('ra.username LIKE ?');
      params.push(`%${receiver}%`);
    }

    const sql = `
      SELECT
        ma.id,
        sa.username AS sender,
        ra.username AS receiver,
        ma.message_type,
        ma.created_at
      FROM message_audit ma
      JOIN accounts sa ON sa.id = ma.sender_id
      JOIN accounts ra ON ra.id = ma.receiver_id
      ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
      ORDER BY ma.id DESC
      LIMIT 2000;
    `;

    const rows = await all(sql, params);
    return res.json({ messages: rows });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.get('/api/admin/logs', adminPermissionRequired('view_logs'), async (req, res) => {
  try {
    const rows = await all(
      'SELECT id, operator_username, action, target, created_at FROM admin_logs ORDER BY id DESC LIMIT 2000;'
    );
    return res.json({ logs: rows });
  } catch (_) {
    return res.status(500).json({ message: '获取失败' });
  }
});

router.use((req, res) => {
  res.status(404).json({ message: 'Not Found' });
});

module.exports = router;
