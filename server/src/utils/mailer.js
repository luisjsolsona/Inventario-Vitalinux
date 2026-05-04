const nodemailer = require('nodemailer');
const { getDB } = require('../db');

function getEmailConfig() {
  const db = getDB();
  const rows = db.prepare(
    "SELECT key, value FROM config WHERE key IN ('email_from','email_to','email_pass','email_enabled')"
  ).all();
  const cfg = {};
  for (const r of rows) cfg[r.key] = r.value;
  return cfg;
}

function buildTransport(cfg) {
  return nodemailer.createTransport({
    host: 'smtp.gmail.com',
    port: 587,
    secure: false,
    auth: { user: cfg.email_from, pass: cfg.email_pass }
  });
}

async function sendChangeNotification(equipo, cambios) {
  if (!cambios || cambios.length === 0) return;
  const cfg = getEmailConfig();
  if (cfg.email_enabled !== '1' || !cfg.email_from || !cfg.email_pass) return;

  const to = cfg.email_to || cfg.email_from;
  const nombre = equipo.name || equipo.cid;
  const lineas = cambios.map(c => `  • ${c.campo}: "${c.valor_ant || '∅'}" → "${c.valor_new}"`).join('\n');
  const fecha = new Date().toLocaleString('es-ES', { timeZone: 'Europe/Madrid' });

  await buildTransport(cfg).sendMail({
    from: `"Inventario Vitalinux" <${cfg.email_from}>`,
    to,
    subject: `[Inventario] Cambio detectado en ${nombre}`,
    text: [
      `Se han detectado cambios en un equipo del inventario.`,
      ``,
      `Equipo : ${nombre}`,
      `CID    : ${equipo.cid}`,
      `IP     : ${equipo.ip || 'N/A'}`,
      `Modelo : ${equipo.modelo || 'N/A'}`,
      `Fecha  : ${fecha}`,
      ``,
      `Campos modificados:`,
      lineas,
    ].join('\n')
  });
}

async function sendTestEmail() {
  const cfg = getEmailConfig();
  if (!cfg.email_from || !cfg.email_pass) throw new Error('Configura el email antes de probar');
  const to = cfg.email_to || cfg.email_from;
  await buildTransport(cfg).sendMail({
    from: `"Inventario Vitalinux" <${cfg.email_from}>`,
    to,
    subject: '[Inventario] Prueba de notificación',
    text: 'Si recibes este mensaje, las notificaciones por correo están correctamente configuradas.'
  });
}

module.exports = { sendChangeNotification, sendTestEmail, getEmailConfig };
