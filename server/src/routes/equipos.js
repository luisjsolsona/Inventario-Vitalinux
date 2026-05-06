const express = require('express');
const { getDB } = require('../db');
const { authMiddleware } = require('../middleware/auth');

const router = express.Router();

// Listar todos
router.get('/', authMiddleware, (req, res) => {
  const equipos = getDB().prepare(`
    SELECT e.*,
      (SELECT MAX(fecha) FROM historial WHERE cid = e.cid) as last_change_at
    FROM equipos e ORDER BY e.updated_at DESC
  `).all();
  res.json(equipos);
});

// Detalle
router.get('/:cid', authMiddleware, (req, res) => {
  const equipo = getDB().prepare('SELECT * FROM equipos WHERE cid = ?').get(req.params.cid);
  if (!equipo) return res.status(404).json({ error: 'No encontrado' });
  const historial = getDB().prepare('SELECT * FROM historial WHERE cid = ? ORDER BY fecha DESC LIMIT 200').all(req.params.cid);
  res.json({ equipo, historial });
});

// Aceptar cambios de HW (resetea estado a OK)
router.post('/:cid/aceptar', authMiddleware, (req, res) => {
  const equipo = getDB().prepare('SELECT cid FROM equipos WHERE cid = ?').get(req.params.cid);
  if (!equipo) return res.status(404).json({ error: 'No encontrado' });
  getDB().prepare("UPDATE equipos SET estado='OK' WHERE cid = ?").run(req.params.cid);
  res.json({ ok: true });
});

// Eliminar (solo admin)
router.delete('/:cid', authMiddleware, (req, res) => {
  if (req.user.rol !== 'admin') return res.status(403).json({ error: 'Sin permisos' });
  getDB().prepare('DELETE FROM equipos WHERE cid = ?').run(req.params.cid);
  getDB().prepare('DELETE FROM historial WHERE cid = ?').run(req.params.cid);
  res.json({ ok: true });
});

// Estadísticas resumen
router.get('/_stats', authMiddleware, (req, res) => {
  const db = getDB();
  const total = db.prepare('SELECT COUNT(*) as n FROM equipos').get().n;
  const activos = db.prepare("SELECT COUNT(*) as n FROM equipos WHERE estado='OK'").get().n;
  const porVersion = db.prepare('SELECT version, COUNT(*) as n FROM equipos GROUP BY version').all();
  const porTipoDisco = db.prepare('SELECT tipo_disco, COUNT(*) as n FROM equipos GROUP BY tipo_disco').all();
  const ultimaActualizacion = db.prepare('SELECT MAX(updated_at) as fecha FROM equipos').get().fecha;
  res.json({ total, activos, porVersion, porTipoDisco, ultimaActualizacion });
});

module.exports = router;
