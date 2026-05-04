const express = require('express');
const { getDB } = require('../db');
const { authMiddleware } = require('../middleware/auth');
const { sendTestEmail } = require('../utils/mailer');

const router = express.Router();

const soloAdmin = (req, res, next) => {
  if (req.user.rol !== 'admin') return res.status(403).json({ error: 'Sin permisos' });
  next();
};

const ALLOWED_KEYS = ['email_from', 'email_to', 'email_pass', 'email_enabled'];

router.get('/email', authMiddleware, soloAdmin, (req, res) => {
  const db = getDB();
  const rows = db.prepare(`SELECT key, value FROM config WHERE key IN ('email_from','email_to','email_pass','email_enabled')`).all();
  const cfg = {};
  for (const r of rows) cfg[r.key] = r.value;
  if (cfg.email_pass) cfg.email_pass = '••••••••';
  res.json(cfg);
});

router.put('/email', authMiddleware, soloAdmin, (req, res) => {
  const db = getDB();
  const upsert = db.prepare('INSERT INTO config (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value');
  const { email_from, email_to, email_pass, email_enabled } = req.body;

  if (email_from !== undefined)
    upsert.run('email_from', String(email_from).trim().slice(0, 256));
  if (email_to !== undefined)
    upsert.run('email_to', String(email_to).trim().slice(0, 256));
  if (email_pass !== undefined && email_pass && !email_pass.startsWith('•'))
    upsert.run('email_pass', String(email_pass).trim().slice(0, 128));
  if (email_enabled !== undefined)
    upsert.run('email_enabled', email_enabled ? '1' : '0');

  res.json({ ok: true });
});

router.post('/test-email', authMiddleware, soloAdmin, async (req, res) => {
  try {
    await sendTestEmail();
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
