const express = require('express');
const cookieParser = require('cookie-parser');
const path = require('path');
const fs = require('fs');
const { initDB } = require('./db');
const authRouter = require('./routes/auth');
const equiposRouter = require('./routes/equipos');
const apiRouter = require('./routes/api');

const app = express();
const PORT = process.env.PORT || 3900;

// ── Middleware ────────────────────────────────────────────────
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, '../public')));

// ── Descarga pública del agente (sin login) ───────────────────
app.get('/agente.sh', (req, res) => {
  const scriptPath = path.join(__dirname, '../agent/inventario-agente.sh');
  let script;
  try {
    script = fs.readFileSync(scriptPath, 'utf8');
  } catch {
    return res.status(404).send('# Agente no encontrado en el servidor\n');
  }
  const serverUrl = `${req.protocol}://${req.headers.host}`;
  const apiToken = process.env.API_TOKEN || process.env.JWT_SECRET || 'dev_secret_change_me';
  script = script.replace(/^SERVER_URL=.*$/m, `SERVER_URL="${serverUrl}"`);
  script = script.replace(/^API_TOKEN=.*$/m,  `API_TOKEN="${apiToken}"`);
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Content-Disposition', 'attachment; filename="inventario-agente.sh"');
  res.send(script);
});

// ── Rutas ─────────────────────────────────────────────────────
app.use('/auth', authRouter);
app.use('/equipos', equiposRouter);
app.use('/api', apiRouter);

// ── Arranque ──────────────────────────────────────────────────
initDB();
app.listen(PORT, '0.0.0.0', () => {
  console.log(`[Inventario Vitalinux] Servidor en puerto ${PORT}`);
});
