const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { getDB } = require('../db');
const { SECRET, authMiddleware } = require('../middleware/auth');

const router = express.Router();

// Rate limiting en memoria: máx 5 intentos por IP cada 10 minutos
const loginAttempts = new Map();
function checkRateLimit(ip) {
  const now = Date.now();
  const window = 10 * 60 * 1000;
  const rec = loginAttempts.get(ip) || { count: 0, resetAt: now + window };
  if (now > rec.resetAt) { rec.count = 1; rec.resetAt = now + window; }
  else rec.count++;
  loginAttempts.set(ip, rec);
  return rec.count <= 5;
}

router.post('/login', (req, res) => {
  const ip = req.ip || req.connection.remoteAddress;
  if (!checkRateLimit(ip)) {
    return res.status(429).json({ error: 'Demasiados intentos. Espera 10 minutos.' });
  }

  const { username, password } = req.body;
  if (!username || !password) return res.status(400).json({ error: 'Faltan campos' });

  const user = getDB().prepare('SELECT * FROM usuarios WHERE username = ?').get(username);
  if (!user || !bcrypt.compareSync(password, user.password)) {
    return res.status(401).json({ error: 'Credenciales incorrectas' });
  }

  loginAttempts.delete(ip); // reset tras login correcto
  const token = jwt.sign({ id: user.id, username: user.username, rol: user.rol }, SECRET, { expiresIn: '8h' });
  res.cookie('token', token, { httpOnly: true, sameSite: 'strict', maxAge: 8 * 3600 * 1000 });
  res.json({ ok: true, rol: user.rol });
});

router.get('/me', authMiddleware, (req, res) => {
  res.json({ username: req.user.username, rol: req.user.rol });
});

router.post('/logout', (req, res) => {
  res.clearCookie('token');
  res.json({ ok: true });
});

module.exports = router;
