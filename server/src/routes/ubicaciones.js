const express = require('express');
const { getDB } = require('../db');
const { authMiddleware } = require('../middleware/auth');

const router = express.Router();

router.get('/', authMiddleware, (req, res) => {
  res.json(getDB().prepare('SELECT * FROM ubicaciones ORDER BY orden, nombre').all());
});

router.post('/', authMiddleware, (req, res) => {
  if (req.user.rol !== 'admin') return res.status(403).json({ error: 'Sin permisos' });
  const nombre = (req.body.nombre || '').trim();
  if (!nombre) return res.status(400).json({ error: 'Nombre requerido' });
  const db = getDB();
  try {
    const maxOrden = db.prepare('SELECT MAX(orden) as m FROM ubicaciones').get().m ?? 0;
    db.prepare('INSERT INTO ubicaciones (nombre, orden) VALUES (?, ?)').run(nombre, maxOrden + 1);
    res.json({ ok: true });
  } catch {
    res.status(400).json({ error: 'Ya existe una ubicación con ese nombre' });
  }
});

router.put('/:id', authMiddleware, (req, res) => {
  if (req.user.rol !== 'admin') return res.status(403).json({ error: 'Sin permisos' });
  const nombre = (req.body.nombre || '').trim();
  if (!nombre) return res.status(400).json({ error: 'Nombre requerido' });
  const db = getDB();
  const ubic = db.prepare('SELECT nombre FROM ubicaciones WHERE id = ?').get(req.params.id);
  if (!ubic) return res.status(404).json({ error: 'No encontrada' });
  try {
    db.prepare('UPDATE equipos SET ubicacion = ? WHERE ubicacion = ?').run(nombre, ubic.nombre);
    db.prepare('UPDATE ubicaciones SET nombre = ? WHERE id = ?').run(nombre, req.params.id);
    res.json({ ok: true });
  } catch {
    res.status(400).json({ error: 'Ya existe una ubicación con ese nombre' });
  }
});

router.delete('/:id', authMiddleware, (req, res) => {
  if (req.user.rol !== 'admin') return res.status(403).json({ error: 'Sin permisos' });
  const db = getDB();
  const ubic = db.prepare('SELECT nombre FROM ubicaciones WHERE id = ?').get(req.params.id);
  if (!ubic) return res.status(404).json({ error: 'No encontrada' });
  db.prepare('UPDATE equipos SET ubicacion = NULL WHERE ubicacion = ?').run(ubic.nombre);
  db.prepare('DELETE FROM ubicaciones WHERE id = ?').run(req.params.id);
  res.json({ ok: true });
});

module.exports = router;
