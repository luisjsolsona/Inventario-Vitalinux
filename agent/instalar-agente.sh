#!/bin/bash
# ============================================================
# instalar-agente.sh
# Instala el agente de inventario en el equipo cliente
# Ejecutar con: sudo ./instalar-agente.sh
# ============================================================

set -e

AGENT_SRC="./inventario-agente.sh"
AGENT_DEST="/usr/local/bin/inventario-agente.sh"
CRON_FILE="/etc/cron.d/inventario-vitalinux"

echo "=== Instalador Agente Inventario Vitalinux ==="

if [[ $EUID -ne 0 ]]; then
  echo "Error: ejecutar con sudo" >&2
  exit 1
fi

if [[ ! -f "$AGENT_SRC" ]]; then
  echo "Error: no se encuentra inventario-agente.sh en el directorio actual" >&2
  exit 1
fi

# Copiar agente
cp "$AGENT_SRC" "$AGENT_DEST"
chmod +x "$AGENT_DEST"
echo "✓ Agente instalado en $AGENT_DEST"

# Crear cron: ejecutar al arranque + cada 24h
cat > "$CRON_FILE" <<'CRON'
# Inventario Vitalinux
# Envía inventario al servidor al arranque y cada día a las 08:05
@reboot root /usr/local/bin/inventario-agente.sh >> /var/log/inventario-agente.log 2>&1
5 8 * * * root /usr/local/bin/inventario-agente.sh >> /var/log/inventario-agente.log 2>&1
CRON

chmod 644 "$CRON_FILE"
echo "✓ Cron instalado en $CRON_FILE"

# Primera ejecución inmediata
echo "Ejecutando inventario inicial..."
bash "$AGENT_DEST" && echo "✓ Inventario inicial enviado" || echo "⚠ Error en envío inicial (revisar logs)"

echo ""
echo "=== Instalación completada ==="
echo "Log: /var/log/inventario-agente.log"
echo "Para forzar envío manual: sudo $AGENT_DEST"
