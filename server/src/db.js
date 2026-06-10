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
      estado        TEXT DEFAULT 'OK',
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

    CREATE TABLE IF NOT EXISTS ubicaciones (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      nombre     TEXT UNIQUE NOT NULL,
      orden      INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE INDEX IF NOT EXISTS idx_historial_cid   ON historial(cid);
    CREATE INDEX IF NOT EXISTS idx_historial_fecha  ON historial(fecha DESC);
    CREATE INDEX IF NOT EXISTS idx_equipos_updated  ON equipos(updated_at DESC);
  `);

  // Añadir columna ubicacion si no existe (migración segura)
  try { db.exec("ALTER TABLE equipos ADD COLUMN ubicacion TEXT"); } catch {}

  // Seed ubicaciones iniciales
  const UBICACIONES_INICIALES = [
    'Edificio A - Aula 01 (1ºA)', 'Edificio A - Aula 02 (1ºB)', 'Edificio A - Aula 03 (4ºA)',
    'Edificio A - Aula 05 (4ºDIV)', 'Edificio A - Aula 06 (AMPA)', 'Edificio A - Aula 07 (1ºPAI)',
    'Edificio A - Aula 08 (PT)', 'Edificio A - Aula 09 (PT)', 'Edificio A - Aula 11 (FPB1 COM)',
    'Edificio A - Aula 12 (3ºA)', 'Edificio A - Aula 13 (3ºB)', 'Edificio A - Aula 14 (3ºDIV)',
    'Edificio A - Aula 15 (INFORMATICA)', 'Edificio A - Aula 16 (FPB2 COM)',
    'Edificio A - Aula 17 (DESDOBLES)', 'Edificio A - Aula 21 (2ºPAI)',
    'Edificio A - Aula 22 (2ºA)', 'Edificio A - Aula 23 (2ºB)', 'Edificio A - Aula 24 (DESDOBLE)',
    'Edificio A - Aula 25 (FPB2 INF)', 'Edificio A - Aula 2ºFPB INFORMATICA',
    'Edificio A - Aula 26 (1ºFPB INF)', 'Edificio A - Aula 27 (EMPRENDIMIENTO)',
    'Edificio B - Aula 01', 'Edificio B - Aula 02', 'Edificio B - Aula 03', 'Edificio B - Aula 04',
    'Edificio B - Aula 05 (B1A)', 'Edificio B - Aula 06 (B1B)',
    'Edificio B - Aula Desdoble 1', 'Edificio B - Aula Desdoble 2',
    'Edificio B - Aula Desdoble 3', 'Edificio B - Aula Desdoble 4',
    'Edificio B - Aula INFORMATICA BACH', 'Edificio B - Aula Dibujo Volumen',
    'Edificio B - Aula Dibujo Arte', 'Edificio B - Aula 07', 'Edificio B - Aula 08',
    'Edificio B - Aula 09 (B2B)', 'Edificio B - Aula 10 (B2A)', 'Edificio B - Aula 11',
    'Edificio B - Aula 12 (2CFGM INF)', 'Edificio B - Aula 13 (1CFGM INF)',
    'Edificio A - Sala de Profesores', 'Edificio B - Sala de Profesores',
    'Departamento Ciencias Naturales', 'Departamento Economia', 'Departamento Educación Física',
    'Departamento Artes Plásticas', 'Departamento Filosofia', 'Departamento Física y Química',
    'Departamento Geografía e Historía', 'Departamento Latín y Griego',
    'Departamento Lengua y Literatura', 'Departamento Matemáticas', 'Departamento Música',
    'Departamento Religión', 'Departamento Tecnología', 'Departamento Francés',
    'Departamento Inglés', 'Departamento FP Informática', 'Departamento FP Comercio',
    'Departamento Orientación', 'Conserjería',
  ];
  const insUbic = db.prepare('INSERT OR IGNORE INTO ubicaciones (nombre, orden) VALUES (?, ?)');
  UBICACIONES_INICIALES.forEach((n, i) => insUbic.run(n, i));

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
