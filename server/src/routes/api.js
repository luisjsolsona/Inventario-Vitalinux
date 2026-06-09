const express = require('express');
const { getDB } = require('../db');
const { apiTokenMiddleware } = require('../middleware/auth');
const { sendChangeNotification } = require('../utils/mailer');

const router = express.Router();

const MAX_CID   = 128;
const MAX_FIELD = 512;
const trim = (v, max = MAX_FIELD) => (v == null ? null : String(v).trim().slice(0, max));

const HW_FIELDS = ['cpu','memoria_mb','slots_memoria','disco_gb','tipo_disco','modelo','serial','grafica','arch','dualizado','secure_boot'];
// Campos que se guardan en historial pero no disparan notificaciones ni marcan como REVISAR
const HISTORIAL_ONLY = new Set(['ultima_act']);

// ── POST /api/inventario  (llamado por el script bash) ────────
router.post('/inventario', apiTokenMiddleware, (req, res) => {
  const d = req.body;
  if (!d.cid || typeof d.cid !== 'string' || !d.cid.trim()) {
    return res.status(400).json({ error: 'CID requerido' });
  }
  d.cid = d.cid.trim().slice(0, MAX_CID);

  // Sanitizar todos los campos de texto
  for (const key of ['estado','version','arch','name','serial','ultima_act','etiquetas',
      'cpu','slots_memoria','disco_gb','tipo_disco','modelo',
      'ip','mac_ethernet','mac_wifi','grafica','dualizado','secure_boot','ip_publica']) {
    d[key] = trim(d[key]);
  }
  // Normalizar CPU: colapsar espacios múltiples
  if (d.cpu) d.cpu = d.cpu.replace(/\s+/g, ' ').trim();
  // Normalizar serial: eliminar formato DMI path (/SERIAL/ruta/) → SERIAL
  if (d.serial) d.serial = d.serial.replace(/^\/+/, '').replace(/\/.*$/, '').trim();

  const db = getDB();
  const existing = db.prepare('SELECT * FROM equipos WHERE cid = ?').get(d.cid);

  const campos = [
    'estado','version','arch','name','serial','ultima_act','etiquetas',
    'cpu','memoria_mb','slots_memoria','disco_gb','tipo_disco','modelo',
    'ip','mac_ethernet','mac_wifi','grafica','dualizado','secure_boot','ip_publica'
  ];

  if (existing) {
    // Campos que se actualizan silenciosamente (sin historial ni notificación)
    const SILENT = new Set(['ip', 'ip_publica']);

    // Si el agente no pudo recuperar las etiquetas, conservar el valor existente
    if (d.etiquetas === 'N/A') d.etiquetas = existing.etiquetas;

    const cambios = [];
    let hwChanged = false;
    for (const campo of campos) {
      if (campo === 'estado') continue; // estado lo gestiona nuevoEstado, no d.estado
      let vAnt = String(existing[campo] ?? '');
      let vNew = String(d[campo] ?? '');
      // Normalizar para comparación (evita falsos positivos por formato)
      if (campo === 'cpu')    { vAnt = vAnt.replace(/\s+/g, ' ').trim(); vNew = vNew.replace(/\s+/g, ' ').trim(); }
      if (campo === 'serial') { vAnt = vAnt.replace(/^\/+/, '').replace(/\/.*$/, '').trim(); }
      if (vAnt !== vNew) {
        if (!SILENT.has(campo)) {
          db.prepare('INSERT INTO historial (cid, campo, valor_ant, valor_new) VALUES (?,?,?,?)')
            .run(d.cid, campo, vAnt, vNew);
          if (!HISTORIAL_ONLY.has(campo)) {
            cambios.push({ campo, valor_ant: vAnt, valor_new: vNew });
          }
        }
        // secure_boot: no marcar REVISAR si el cambio es desde/hacia 'unknown' (problema de detección)
        const esHW = HW_FIELDS.includes(campo);
        const sbFalsoPositivo = campo === 'secure_boot' && (vAnt === 'unknown' || vNew === 'unknown');
        if (esHW && !sbFalsoPositivo) hwChanged = true;
      }
    }
    // Estado: REVISAR si cambió HW; si no, conservar REVISAR pendiente o confirmar OK
    const nuevoEstado = hwChanged ? 'REVISAR' : (existing.estado === 'REVISAR' ? 'REVISAR' : 'OK');
    // Actualizar
    db.prepare(`UPDATE equipos SET
      estado=?, version=?, arch=?, name=?, serial=?, ultima_act=?, etiquetas=?,
      cpu=?, memoria_mb=?, slots_memoria=?, disco_gb=?, tipo_disco=?, modelo=?,
      ip=?, mac_ethernet=?, mac_wifi=?, grafica=?, dualizado=?, secure_boot=?,
      ip_publica=?, updated_at=datetime('now')
      WHERE cid=?
    `).run(
      nuevoEstado, d.version, d.arch, d.name, d.serial, d.ultima_act, d.etiquetas,
      d.cpu, d.memoria_mb, d.slots_memoria, d.disco_gb, d.tipo_disco, d.modelo,
      d.ip, d.mac_ethernet, d.mac_wifi, d.grafica, d.dualizado, d.secure_boot,
      d.ip_publica, d.cid
    );
    if (cambios.length > 0) {
      sendChangeNotification(d, cambios).catch(e => console.error('[Email]', e.message));
    }
    return res.json({ ok: true, accion: 'actualizado' });
  } else {
    // Insertar nuevo
    db.prepare(`INSERT INTO equipos
      (cid, estado, version, arch, name, serial, ultima_act, etiquetas,
       cpu, memoria_mb, slots_memoria, disco_gb, tipo_disco, modelo,
       ip, mac_ethernet, mac_wifi, grafica, dualizado, secure_boot, ip_publica)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `).run(
      d.cid, 'OK', d.version, d.arch, d.name, d.serial,
      d.ultima_act, d.etiquetas, d.cpu, d.memoria_mb, d.slots_memoria,
      d.disco_gb, d.tipo_disco, d.modelo, d.ip, d.mac_ethernet, d.mac_wifi,
      d.grafica, d.dualizado, d.secure_boot, d.ip_publica
    );
    return res.json({ ok: true, accion: 'registrado' });
  }
});

// ── GET /api/export/csv  (descarga CSV) ───────────────────────
router.get('/export/csv', apiTokenMiddleware, (req, res) => {
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

module.exports = router;
