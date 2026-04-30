const express = require('express');
const bcrypt = require('bcryptjs');
const { getDB } = require('../db');
const { authMiddleware } = require('../middleware/auth');

const router = express.Router();

const soloAdmin = (req, res, next) => {
  if (req.user.rol !== 'admin') return res.status(403).json({ error: 'Sin permisos' });
  next();
};

// Listar usuarios (admin)
router.get('/', authMiddleware, soloAdmin, (req, res) => {
  const usuarios = getDB()
    .prepare('SELECT id, username, rol, created_at FROM usuarios ORDER BY created_at')
    .all();
  res.json(usuarios);
});

// Crear usuario (admin)
router.post('/', authMiddleware, soloAdmin, (req, res) => {
  const { username, password, rol } = req.body;
  if (!username || !password || !rol) return res.status(400).json({ error: 'Faltan campos' });
  if (!['admin', 'tecnico', 'viewer'].includes(rol)) return res.status(400).json({ error: 'Rol inválido' });
  try {
    const hash = bcrypt.hashSync(password, 10);
    const { lastInsertRowid } = getDB()
      .prepare('INSERT INTO usuarios (username, password, rol) VALUES (?, ?, ?)')
      .run(username.trim().slice(0, 64), hash, rol);
    res.json({ ok: true, id: lastInsertRowid });
  } catch {
    res.status(409).json({ error: 'El usuario ya existe' });
  }
});

// Editar usuario (admin): rol y/o contraseña
router.put('/:id', authMiddleware, soloAdmin, (req, res) => {
  const { password, rol } = req.body;
  const db = getDB();
  const u = db.prepare('SELECT id, rol FROM usuarios WHERE id = ?').get(req.params.id);
  if (!u) return res.status(404).json({ error: 'Usuario no encontrado' });

  if (rol && !['admin', 'tecnico', 'viewer'].includes(rol)) return res.status(400).json({ error: 'Rol inválido' });

  // Evitar dejar el sistema sin admin
  if (u.rol === 'admin' && rol && rol !== 'admin') {
    const admins = db.prepare("SELECT COUNT(*) as n FROM usuarios WHERE rol = 'admin'").get().n;
    if (admins <= 1) return res.status(409).json({ error: 'No puedes quitar el último administrador' });
  }

  if (password) {
    const hash = bcrypt.hashSync(password, 10);
    db.prepare('UPDATE usuarios SET password = ? WHERE id = ?').run(hash, req.params.id);
  }
  if (rol) {
    db.prepare('UPDATE usuarios SET rol = ? WHERE id = ?').run(rol, req.params.id);
  }
  res.json({ ok: true });
});

// Eliminar usuario (admin)
router.delete('/:id', authMiddleware, soloAdmin, (req, res) => {
  const db = getDB();
  const u = db.prepare('SELECT rol FROM usuarios WHERE id = ?').get(req.params.id);
  if (!u) return res.status(404).json({ error: 'No encontrado' });
  if (u.rol === 'admin') {
    const admins = db.prepare("SELECT COUNT(*) as n FROM usuarios WHERE rol = 'admin'").get().n;
    if (admins <= 1) return res.status(409).json({ error: 'No puedes eliminar el último administrador' });
  }
  db.prepare('DELETE FROM usuarios WHERE id = ?').run(req.params.id);
  res.json({ ok: true });
});

// Cambiar contraseña propia (cualquier usuario autenticado)
router.post('/mi-password', authMiddleware, (req, res) => {
  const { actual, nueva } = req.body;
  if (!actual || !nueva) return res.status(400).json({ error: 'Faltan campos' });
  if (nueva.length < 6) return res.status(400).json({ error: 'La nueva contraseña debe tener al menos 6 caracteres' });
  const db = getDB();
  const u = db.prepare('SELECT password FROM usuarios WHERE id = ?').get(req.user.id);
  if (!u || !bcrypt.compareSync(actual, u.password)) {
    return res.status(401).json({ error: 'Contraseña actual incorrecta' });
  }
  db.prepare('UPDATE usuarios SET password = ? WHERE id = ?').run(bcrypt.hashSync(nueva, 10), req.user.id);
  res.json({ ok: true });
});

module.exports = router;
