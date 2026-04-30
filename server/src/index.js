const express = require('express');
const cookieParser = require('cookie-parser');
const path = require('path');
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

// ── Rutas ─────────────────────────────────────────────────────
app.use('/auth', authRouter);
app.use('/equipos', equiposRouter);
app.use('/api', apiRouter);

// ── Arranque ──────────────────────────────────────────────────
initDB();
app.listen(PORT, '0.0.0.0', () => {
  console.log(`[Inventario Vitalinux] Servidor en puerto ${PORT}`);
});
