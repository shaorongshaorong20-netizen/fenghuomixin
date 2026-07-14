const path = require('path');
const sqlite3 = require('sqlite3').verbose();
const bcrypt = require('bcryptjs');

const dbPath = path.join(__dirname, '..', '1949.db');

const db = new sqlite3.Database(dbPath);

function run(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.run(sql, params, function (err) {
      if (err) return reject(err);
      resolve({ lastID: this.lastID, changes: this.changes });
    });
  });
}

function get(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.get(sql, params, (err, row) => {
      if (err) return reject(err);
      resolve(row);
    });
  });
}

function all(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.all(sql, params, (err, rows) => {
      if (err) return reject(err);
      resolve(rows);
    });
  });
}

async function initDb() {
  await run('PRAGMA foreign_keys = ON;');
  await run('PRAGMA journal_mode = WAL;');

  await run(`
    CREATE TABLE IF NOT EXISTS accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      password TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_login TEXT
    );
  `);

  try {
    await run(`ALTER TABLE accounts ADD COLUMN role TEXT NOT NULL DEFAULT 'user';`);
  } catch (_) {}
  try {
    await run(`ALTER TABLE accounts ADD COLUMN nickname TEXT;`);
  } catch (_) {}
  try {
    await run(`ALTER TABLE accounts ADD COLUMN avatar TEXT;`);
  } catch (_) {}
  try {
    await run(`ALTER TABLE accounts ADD COLUMN created_by_admin_id INTEGER;`);
  } catch (_) {}

  await run(`
    CREATE TABLE IF NOT EXISTS friends (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      friend_id INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(user_id, friend_id)
    );
  `);

  await run(`
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id TEXT NOT NULL,
      sender_id INTEGER NOT NULL,
      content TEXT,
      reply_to_id INTEGER,
      read_at TEXT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      is_revoked INTEGER NOT NULL DEFAULT 0,
      timestamp TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

  try {
    await run(`ALTER TABLE messages ADD COLUMN reply_to_id INTEGER;`);
  } catch (_) {}
  try {
    await run(`ALTER TABLE messages ADD COLUMN read_at TEXT NULL;`);
  } catch (_) {}

  await run(`
    CREATE TABLE IF NOT EXISTS conversation_reads (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      conversation_id TEXT NOT NULL,
      last_read_id INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(user_id, conversation_id)
    );
  `);

  await run(`
    CREATE TABLE IF NOT EXISTS message_audit (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sender_id INTEGER NOT NULL,
      receiver_id INTEGER NOT NULL,
      message_type TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

  await run(`
    CREATE TABLE IF NOT EXISTS admin_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      operator_id INTEGER,
      operator_username TEXT,
      action TEXT NOT NULL,
      target TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

  await run(`
    CREATE TABLE IF NOT EXISTS admin_permissions (
      admin_id INTEGER PRIMARY KEY,
      manage_accounts INTEGER NOT NULL DEFAULT 0,
      view_audit INTEGER NOT NULL DEFAULT 0,
      view_logs INTEGER NOT NULL DEFAULT 0,
      create_account_limit INTEGER NOT NULL DEFAULT -1,
      max_admin_sessions INTEGER NOT NULL DEFAULT -1,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY(admin_id) REFERENCES accounts(id) ON DELETE CASCADE
    );
  `);

  try {
    await run(`ALTER TABLE admin_permissions ADD COLUMN create_account_limit INTEGER NOT NULL DEFAULT -1;`);
  } catch (_) {}
  try {
    await run(`ALTER TABLE admin_permissions ADD COLUMN max_admin_sessions INTEGER NOT NULL DEFAULT -1;`);
  } catch (_) {}

  await run(`
    CREATE TABLE IF NOT EXISTS ip_geo_cache (
      ip TEXT PRIMARY KEY,
      country TEXT,
      province TEXT,
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

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

  await run(`
    CREATE TABLE IF NOT EXISTS user_remarks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      peer_id INTEGER NOT NULL,
      remark TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(user_id, peer_id)
    );
  `);

  await run(`
    CREATE TABLE IF NOT EXISTS scheduled_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_id INTEGER NOT NULL,
      to_id INTEGER NOT NULL,
      conversation_id TEXT NOT NULL,
      content TEXT NOT NULL,
      send_at_ms INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      sent_at_ms INTEGER,
      error TEXT
    );
  `);

  await run(`
    CREATE TABLE IF NOT EXISTS user_blocks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      blocked_user_id INTEGER NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(user_id, blocked_user_id)
    );
  `);

  await run(`
    CREATE TABLE IF NOT EXISTS ugc_reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      reporter_id INTEGER NOT NULL,
      reported_user_id INTEGER,
      message_id INTEGER,
      conversation_id TEXT,
      reason TEXT NOT NULL,
      detail TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      action TEXT,
      handled_by INTEGER,
      handled_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);

  await run('CREATE INDEX IF NOT EXISTS idx_accounts_username ON accounts(username);');
  await run('CREATE INDEX IF NOT EXISTS idx_accounts_created_by_admin_id ON accounts(created_by_admin_id);');
  await run('CREATE INDEX IF NOT EXISTS idx_friends_user ON friends(user_id, status);');
  await run('CREATE INDEX IF NOT EXISTS idx_friends_friend ON friends(friend_id, status);');
  await run('CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, id);');
  await run('CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON messages(reply_to_id);');
  await run('CREATE INDEX IF NOT EXISTS idx_reads_user_conv ON conversation_reads(user_id, conversation_id);');
  await run('CREATE INDEX IF NOT EXISTS idx_audit_created_at ON message_audit(created_at, id);');
  await run('CREATE INDEX IF NOT EXISTS idx_admin_logs_created_at ON admin_logs(created_at, id);');
  await run('CREATE INDEX IF NOT EXISTS idx_admin_permissions_admin ON admin_permissions(admin_id);');
  await run('CREATE INDEX IF NOT EXISTS idx_ip_geo_cache_updated_at ON ip_geo_cache(updated_at, ip);');
  await run('CREATE INDEX IF NOT EXISTS idx_admin_login_logs_admin_created ON admin_login_logs(admin_id, created_at, id);');
  await run('CREATE INDEX IF NOT EXISTS idx_admin_ws_sessions_admin_active ON admin_ws_sessions(admin_id, disconnected_at, last_seen_at);');
  await run('CREATE INDEX IF NOT EXISTS idx_admin_http_sessions_admin_active ON admin_http_sessions(admin_id, revoked_at, last_seen_at);');
  await run('CREATE INDEX IF NOT EXISTS idx_user_remarks_user_peer ON user_remarks(user_id, peer_id);');
  await run('CREATE INDEX IF NOT EXISTS idx_scheduled_messages_due ON scheduled_messages(status, send_at_ms, id);');
  await run('CREATE INDEX IF NOT EXISTS idx_user_blocks_user_blocked ON user_blocks(user_id, blocked_user_id);');
  await run('CREATE INDEX IF NOT EXISTS idx_ugc_reports_status_created ON ugc_reports(status, created_at, id);');
}

async function ensureDefaultAdmin() {
  const existing = await get('SELECT id FROM accounts WHERE username = ? LIMIT 1;', [
    'admin',
  ]);
  if (existing) {
    try {
      await run("UPDATE accounts SET role = 'super' WHERE username = 'admin';");
    } catch (_) {}
    return;
  }

  const passwordHash = await bcrypt.hash('admin123', 10);
  await run(
    "INSERT INTO accounts (username, password, status, role) VALUES (?, ?, 'active', 'super');",
    ['admin', passwordHash]
  );
}

module.exports = {
  db,
  run,
  get,
  all,
  initDb,
  ensureDefaultAdmin,
};
