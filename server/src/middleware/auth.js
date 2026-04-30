const jwt = require('jsonwebtoken');
const crypto = require('crypto');

const SECRET = process.env.JWT_SECRET || 'dev_secret_change_me';

// Evita ataques de temporización al comparar tokens
function safeTokenEquals(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const maxLen = 256;
  const bufA = Buffer.alloc(maxLen);
  const bufB = Buffer.alloc(maxLen);
  Buffer.from(a.slice(0, maxLen)).copy(bufA);
  Buffer.from(b.slice(0, maxLen)).copy(bufB);
  return crypto.timingSafeEqual(bufA, bufB) && a.length === b.length;
}

function authMiddleware(req, res, next) {
  const token = req.cookies?.token || req.headers['authorization']?.replace('Bearer ', '');
  if (!token) {
    if (req.headers['content-type'] === 'application/json' || req.path.startsWith('/api/')) {
      return res.status(401).json({ error: 'No autenticado' });
    }
    return res.redirect('/login.html');
  }
  try {
    req.user = jwt.verify(token, SECRET);
    next();
  } catch {
    if (req.path.startsWith('/api/')) {
      return res.status(401).json({ error: 'Token inválido' });
    }
    res.clearCookie('token');
    return res.redirect('/login.html');
  }
}

function apiTokenMiddleware(req, res, next) {
  const token = req.headers['x-api-token'];
  const expected = process.env.API_TOKEN || process.env.JWT_SECRET || 'dev_secret_change_me';
  if (token && safeTokenEquals(token, expected)) return next();
  return authMiddleware(req, res, next);
}

module.exports = { authMiddleware, apiTokenMiddleware, SECRET };
