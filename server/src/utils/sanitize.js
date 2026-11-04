// ── Saneado de entrada ─────────────────────────────────────────
// Los datos de los equipos llegan del agente (autenticado con un API_TOKEN
// que se distribuye en /agente.sh) o de una importación TSV, y el dashboard
// los pinta con innerHTML. Para que ningún valor pueda inyectar HTML/JS se
// eliminan en la entrada los caracteres que permiten romper el marcado o un
// atributo onclick='…'. Ningún dato de hardware legítimo los contiene.
const UNSAFE = /[<>"'`\\\u0000-\u001f\u007f]/g;

const cleanText = (v, max = 512) =>
  v == null ? null : String(v).replace(UNSAFE, '').trim().slice(0, max);

// CID (migasfree-cid) y nombres de usuario: juego de caracteres cerrado
const SAFE_ID = /^[A-Za-z0-9._:@-]+$/;
const isSafeId = v => typeof v === 'string' && SAFE_ID.test(v);

module.exports = { cleanText, isSafeId, UNSAFE };
