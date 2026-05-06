const express = require('express');
const { getDB } = require('../db');
const { authMiddleware } = require('../middleware/auth');

const router = express.Router();

const HW_FIELDS = ['cpu','memoria_mb','slots_memoria','disco_gb','tipo_disco','modelo','serial','grafica','arch','dualizado','secure_boot'];

// Estadísticas resumen — debe ir ANTES de /:cid
router.get('/_stats', authMiddleware, (req, res) => {
  const db = getDB();
  const total = db.prepare('SELECT COUNT(*) as n FROM equipos').get().n;
  const activos = db.prepare("SELECT COUNT(*) as n FROM equipos WHERE estado='OK'").get().n;
  const revisar = db.prepare("SELECT COUNT(*) as n FROM equipos WHERE estado='REVISAR'").get().n;
  const porVersion = db.prepare('SELECT version, COUNT(*) as n FROM equipos GROUP BY version ORDER BY n DESC').all();
  const porTipoDisco = db.prepare('SELECT tipo_disco, COUNT(*) as n FROM equipos GROUP BY tipo_disco ORDER BY n DESC').all();
  const ultimaActualizacion = db.prepare('SELECT MAX(updated_at) as fecha FROM equipos').get().fecha;
  res.json({ total, activos, revisar, porVersion, porTipoDisco, ultimaActualizacion });
});

// Exportar TSV (autenticación por cookie)
router.get('/export', authMiddleware, (req, res) => {
  const equipos = getDB().prepare('SELECT * FROM equipos ORDER BY name').all();
  const header = [
    'CID','ESTADO','VERSION','ARCH SO-HW','NAME','SERIAL','ÚLTIMA ACTUALIZACIÓN',
    'ETIQUETAS','CPU','MEMORIA – MB','SLOTS MEMORIA','DISCO – GB','TIPO DISCO',
    'MODELO','IP','DIRECCIONES MAC','WIFI MAC','GRAFICA','DUALIZADO','SECURE BOOT','IP PUBLICA'
  ].join('\t');
  const rows = equipos.map(e => [
    e.cid, e.estado, e.version, e.arch, e.name, e.serial, e.ultima_act,
    e.etiquetas, e.cpu, e.memoria_mb, e.slots_memoria, e.disco_gb, e.tipo_disco,
    e.modelo, e.ip, e.mac_ethernet, e.mac_wifi, e.grafica, e.dualizado,
    e.secure_boot, e.ip_publica
  ].join('\t')).join('\n');
  res.setHeader('Content-Type', 'text/tab-separated-values; charset=utf-8');
  res.setHeader('Content-Disposition', 'attachment; filename="inventario.tsv"');
  res.send(header + '\n' + rows);
});

// Importar TSV (autenticación por cookie)
router.post('/import', authMiddleware, (req, res) => {
  const { tsv } = req.body;
  if (!tsv || typeof tsv !== 'string') return res.status(400).json({ error: 'Sin datos TSV' });

  const lines = tsv.split('\n').filter(l => l.trim());
  if (lines.length < 2) return res.status(400).json({ error: 'El fichero no contiene datos' });

  const headers = lines[0].split('\t').map(h => h.trim());

  const headerMap = {
    'CID': 'cid', 'ESTADO': 'estado', 'VERSION': 'version', 'ARCH SO-HW': 'arch',
    'NAME': 'name', 'SERIAL': 'serial', 'ÚLTIMA ACTUALIZACIÓN': 'ultima_act',
    'ETIQUETAS': 'etiquetas', 'CPU': 'cpu', 'MEMORIA – MB': 'memoria_mb',
    'SLOTS MEMORIA': 'slots_memoria', 'SLOTS MEMORIA TOTAL(LIBRES)': 'slots_memoria',
    'DISCO – GB': 'disco_gb', 'TIPO DE DISCO': 'tipo_disco', 'TIPO DISCO': 'tipo_disco',
    'MODELO': 'modelo', 'IP': 'ip', 'DIRECCIONES MAC': 'mac_ethernet',
    'WIFI MAC': 'mac_wifi', 'GRAFICA': 'grafica', 'DUALIZADO': 'dualizado',
    'SECURE BOOT': 'secure_boot', 'IP PUBLICA': 'ip_publica'
  };

  const db = getDB();
  let imported = 0, updated = 0, errors = 0;

  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split('\t');
    const row = {};
    headers.forEach((h, idx) => {
      const field = headerMap[h];
      if (field) row[field] = (cols[idx] ?? '').trim();
    });
    if (!row.cid) continue;

    // Normalizar estado: "Activo" heredado → "OK"
    if (!row.estado || row.estado === 'Activo') row.estado = 'OK';

    // disco_gb puede venir con puntos de miles (ej: 480.103.981.056) → eliminar puntos
    if (row.disco_gb && /^\d+(\.\d{3})+$/.test(row.disco_gb))
      row.disco_gb = row.disco_gb.replace(/\./g, '');

    try {
      const existing = db.prepare('SELECT * FROM equipos WHERE cid = ?').get(row.cid);
      if (existing) {
        let hwChanged = false;
        for (const f of HW_FIELDS) {
          if (row[f] !== undefined && String(existing[f] ?? '') !== String(row[f])) {
            hwChanged = true;
            db.prepare('INSERT INTO historial (cid, campo, valor_ant, valor_new) VALUES (?,?,?,?)')
              .run(row.cid, f, existing[f] ?? '', row[f]);
          }
        }
        const nuevoEstado = hwChanged ? 'REVISAR' : (existing.estado === 'REVISAR' ? 'REVISAR' : 'OK');
        db.prepare(`UPDATE equipos SET estado=?,version=?,arch=?,name=?,serial=?,ultima_act=?,etiquetas=?,
          cpu=?,memoria_mb=?,slots_memoria=?,disco_gb=?,tipo_disco=?,modelo=?,ip=?,mac_ethernet=?,
          mac_wifi=?,grafica=?,dualizado=?,secure_boot=?,ip_publica=?,updated_at=datetime('now')
          WHERE cid=?`).run(
            nuevoEstado,row.version,row.arch,row.name,row.serial,row.ultima_act,row.etiquetas,
            row.cpu,row.memoria_mb,row.slots_memoria,row.disco_gb,row.tipo_disco,row.modelo,
            row.ip,row.mac_ethernet,row.mac_wifi,row.grafica,row.dualizado,row.secure_boot,
            row.ip_publica,row.cid);
        updated++;
      } else {
        db.prepare(`INSERT INTO equipos (cid,estado,version,arch,name,serial,ultima_act,etiquetas,
          cpu,memoria_mb,slots_memoria,disco_gb,tipo_disco,modelo,ip,mac_ethernet,mac_wifi,grafica,
          dualizado,secure_boot,ip_publica) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
          .run(row.cid,row.estado,row.version,row.arch,row.name,row.serial,row.ultima_act,
            row.etiquetas,row.cpu,row.memoria_mb,row.slots_memoria,row.disco_gb,row.tipo_disco,
            row.modelo,row.ip,row.mac_ethernet,row.mac_wifi,row.grafica,row.dualizado,
            row.secure_boot,row.ip_publica);
        imported++;
      }
    } catch { errors++; }
  }

  res.json({ ok: true, imported, updated, errors });
});

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

module.exports = router;
