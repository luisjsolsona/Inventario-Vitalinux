const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');
const path = require('path');

const DB_PATH = path.join('/app/data', 'inventario.db');

let db;

function getDB() {
  if (!db) db = new Database(DB_PATH);
  return db;
}

function initDB() {
  const db = getDB();

  db.exec(`
    CREATE TABLE IF NOT EXISTS equipos (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      cid           TEXT UNIQUE NOT NULL,
      estado        TEXT DEFAULT 'Activo',
      version       TEXT,
      arch          TEXT,
      name          TEXT,
      serial        TEXT,
      ultima_act    TEXT,
      etiquetas     TEXT,
      cpu           TEXT,
      memoria_mb    REAL,
      slots_memoria TEXT,
      disco_gb      TEXT,
      tipo_disco    TEXT,
      modelo        TEXT,
      ip            TEXT,
      mac_ethernet  TEXT,
      mac_wifi      TEXT,
      grafica       TEXT,
      dualizado     TEXT,
      secure_boot   TEXT,
      ip_publica    TEXT,
      created_at    TEXT DEFAULT (datetime('now')),
      updated_at    TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS usuarios (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      username   TEXT UNIQUE NOT NULL,
      password   TEXT NOT NULL,
      rol        TEXT DEFAULT 'viewer',
      created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS historial (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      cid        TEXT NOT NULL,
      campo      TEXT NOT NULL,
      valor_ant  TEXT,
      valor_new  TEXT,
      fecha      TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS config (
      key   TEXT PRIMARY KEY,
      value TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_historial_cid   ON historial(cid);
    CREATE INDEX IF NOT EXISTS idx_historial_fecha  ON historial(fecha DESC);
    CREATE INDEX IF NOT EXISTS idx_equipos_updated  ON equipos(updated_at DESC);
  `);

  // Crear usuario admin si no existe
  const adminUser = process.env.ADMIN_USER || 'admin';
  const adminPass = process.env.ADMIN_PASS || 'admin1234';
  const existing = db.prepare('SELECT id FROM usuarios WHERE username = ?').get(adminUser);
  if (!existing) {
    const hash = bcrypt.hashSync(adminPass, 10);
    db.prepare('INSERT INTO usuarios (username, password, rol) VALUES (?, ?, ?)').run(adminUser, hash, 'admin');
    console.log(`[DB] Usuario admin creado: ${adminUser}`);
  }

  console.log('[DB] Base de datos inicializada en', DB_PATH);
}

module.exports = { getDB, initDB };
