#!/bin/bash
# ============================================================
# backup-db.sh — copia de seguridad de la base de datos SQLite
# Se ejecuta en el servidor Docker (no en los clientes).
#   Uso:  ./scripts/backup-db.sh
#   Cron: 30 2 * * * /ruta/Inventario-Vitalinux/scripts/backup-db.sh >> ~/backups/inventario/backup.log 2>&1
# Variables opcionales: CONT (contenedor), DEST (carpeta), KEEP (días a conservar)
# ============================================================
set -euo pipefail

CONT="${CONT:-inventario-vitalinux}"
DEST="${DEST:-$HOME/backups/inventario}"
KEEP="${KEEP:-30}"
FILE="inventario-$(date +%F_%H%M).db"

mkdir -p "$DEST"

# Copia consistente en caliente con la API de backup de SQLite (better-sqlite3),
# sin parar el servidor ni arriesgar una copia a medio escribir.
docker exec "$CONT" node -e "
  require('better-sqlite3')('/app/data/inventario.db', { readonly: true })
    .backup('/app/data/_backup.db')
    .then(() => process.exit(0))
    .catch(e => { console.error(e.message); process.exit(1); });"

docker cp "$CONT:/app/data/_backup.db" "$DEST/$FILE" >/dev/null
docker exec "$CONT" rm -f /app/data/_backup.db
gzip -f "$DEST/$FILE"

# Rotación: borrar copias de más de KEEP días
find "$DEST" -name 'inventario-*.db.gz' -mtime +"$KEEP" -delete

echo "$(date '+%F %T') OK $DEST/$FILE.gz ($(du -h "$DEST/$FILE.gz" | cut -f1))"
