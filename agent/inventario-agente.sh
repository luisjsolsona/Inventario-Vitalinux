#!/bin/bash
# ============================================================
# inventario-agente.sh
# Agente de inventario para equipos Vitalinux
# Recoge datos de hardware y los envía al servidor Docker
#
# Uso: sudo ./inventario-agente.sh
# Configuración: editar las variables SERVER_URL y API_TOKEN
# Luis J. Solsona
# ============================================================

set -uo pipefail

# ═══════════════════════════════════════════════════════════
# CONFIGURACIÓN — EDITAR ANTES DE DESPLEGAR
# ═══════════════════════════════════════════════════════════
SERVER_URL="http://192.168.0.100:3900"   # IP del servidor Docker
API_TOKEN="cambia_esto_por_un_secreto_seguro"  # Mismo valor que JWT_SECRET en docker-compose
LOG_FILE="/var/log/inventario-agente.log"
# ═══════════════════════════════════════════════════════════

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }

log "=== Inicio inventario-agente ==="

# ── Requiere root ─────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log "ERROR: Ejecutar con sudo"
  echo "Uso: sudo $0" >&2
  exit 1
fi

# ── 1. CID ────────────────────────────────────────────────────
if command -v migasfree-cid &>/dev/null; then
  CID=$(migasfree-cid 2>/dev/null || echo "")
fi
if [[ -z "${CID:-}" ]]; then
  # Fallback: usar MAC de la interfaz principal
  CID="mac-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1 | xargs -I{} cat /sys/class/net/{}/address 2>/dev/null | tr -d ':' | head -1)"
fi
if [[ -z "${CID:-}" ]]; then
  log "ERROR: No se pudo obtener CID"
  exit 1
fi
log "CID: $CID"

# ── 2. Estado ─────────────────────────────────────────────────
ESTADO="Activo"

# ── 3. Versión ────────────────────────────────────────────────
VERSION="N/A"
if [[ -f /etc/vitalinux-release ]]; then
  VERSION=$(grep -oP 'VX-\S+' /etc/vitalinux-release 2>/dev/null | head -1 || echo "N/A")
  [[ -z "$VERSION" ]] && VERSION=$(head -1 /etc/vitalinux-release 2>/dev/null || echo "N/A")
elif [[ -f /etc/os-release ]]; then
  VERSION=$(. /etc/os-release; echo "${PRETTY_NAME:-N/A}")
fi

# ── 4. Arquitectura ───────────────────────────────────────────
ARCH_SO=$(uname -m | grep -q 'x86_64' && echo "64" || echo "32")
ARCH_HW=$(grep -m1 'flags' /proc/cpuinfo 2>/dev/null | grep -q '\blm\b' && echo "64" || echo "32")
ARCH="${ARCH_SO}-${ARCH_HW}"

# ── 5. Nombre del equipo ──────────────────────────────────────
NAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null | tr -d '\n' || echo "N/A")

# ── 6. Serial ─────────────────────────────────────────────────
SERIAL="N/A"
if command -v dmidecode &>/dev/null; then
  SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | tr -d '\n' | xargs || echo "N/A")
  [[ "$SERIAL" == "To Be Filled By O.E.M." || -z "$SERIAL" ]] && SERIAL="N/A"
fi

# ── 7. Última actualización ───────────────────────────────────
ULTIMA_ACT="N/A"
if [[ -f /var/log/dpkg.log ]]; then
  ULTIMA_ACT=$(grep -E "upgrade|install" /var/log/dpkg.log 2>/dev/null | tail -1 | awk '{print $1"T"$2}' || echo "N/A")
fi
if [[ "$ULTIMA_ACT" == "N/A" && -f /var/cache/apt/pkgcache.bin ]]; then
  ULTIMA_ACT=$(stat -c '%y' /var/cache/apt/pkgcache.bin 2>/dev/null | awk '{print $1"T"$2}' | head -1 || echo "N/A")
fi

# ── 8. Etiquetas Migasfree ────────────────────────────────────
ETIQUETAS="N/A"
_parse_migasfree_json() {
  local file="$1"
  if command -v jq &>/dev/null; then
    jq -r '(.tags // .attributes // []) | map(tostring) | join(",")' "$file" 2>/dev/null || echo "N/A"
  elif command -v python3 &>/dev/null; then
    python3 - "$file" 2>/dev/null <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    t = d.get('tags', d.get('attributes', []))
    print(','.join(str(x) for x in t) if t else 'N/A')
except Exception:
    print('N/A')
PYEOF
  else
    echo "N/A"
  fi
}
for f in /var/cache/migasfree-client/computer_info.json /etc/migasfree-client/tags; do
  if [[ -f "$f" ]]; then
    if [[ "$f" == *.json ]]; then
      ETIQUETAS=$(_parse_migasfree_json "$f")
    else
      ETIQUETAS=$(tr '\n' ',' < "$f" 2>/dev/null | sed 's/,$//' || echo "N/A")
    fi
    [[ -n "$ETIQUETAS" && "$ETIQUETAS" != "N/A" ]] && break
  fi
done

# ── 9. CPU ───────────────────────────────────────────────────
CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' | sed 's/  */ /g' | xargs || echo "N/A")

# ── 10. RAM (MB como float) ───────────────────────────────────
MEMORIA_MB=$(awk '/MemTotal/{printf "%.1f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")

# ── 11. Slots RAM ─────────────────────────────────────────────
SLOTS_MEMORIA="N/A"
if command -v dmidecode &>/dev/null; then
  SLOTS_TOTAL=$(dmidecode -t memory 2>/dev/null | grep -c "Memory Device$" || echo "0")
  SLOTS_LIBRES=$(dmidecode -t memory 2>/dev/null | grep -A5 "Memory Device$" | grep -c "No Module Installed" || echo "0")
  SLOTS_MEMORIA="${SLOTS_TOTAL} (${SLOTS_LIBRES} libres)"
fi

# ── 12. Disco (bytes brutos, como Migasfree) ──────────────────
DISCO_GB="0"
if command -v lsblk &>/dev/null; then
  DISCO_BYTES=$(lsblk -bdno SIZE,TYPE 2>/dev/null | awk '$2=="disk"{sum+=$1} END{print sum+0}')
  [[ -n "$DISCO_BYTES" ]] && DISCO_GB="$DISCO_BYTES"
fi

# ── 13. Tipo disco ────────────────────────────────────────────
TIPO_DISCO="N/A"
HAS_SSD=false; HAS_HDD=false; HAS_NVME=false
for dev in /sys/block/*/queue/rotational; do
  [[ -f "$dev" ]] || continue
  rot=$(cat "$dev" 2>/dev/null)
  devname=$(echo "$dev" | awk -F'/' '{print $4}')
  [[ "$devname" == nvme* ]] && HAS_NVME=true && continue
  [[ "$rot" == "0" ]] && HAS_SSD=true
  [[ "$rot" == "1" ]] && HAS_HDD=true
done
ls /sys/block/nvme* &>/dev/null 2>&1 && HAS_NVME=true
if $HAS_NVME; then TIPO_DISCO="nvme"
elif $HAS_SSD && $HAS_HDD; then TIPO_DISCO="ssd+hdd"
elif $HAS_SSD; then TIPO_DISCO="ssd"
elif $HAS_HDD; then TIPO_DISCO="hdd"
fi

# ── 14. Modelo ───────────────────────────────────────────────
MODELO="N/A"
if command -v dmidecode &>/dev/null; then
  MP=$(dmidecode -s system-product-name 2>/dev/null | xargs || echo "")
  MS=$(dmidecode -s system-sku-number 2>/dev/null | xargs || echo "")
  MODELO="${MP}${MS:+ ($MS)}"
  [[ -z "$MODELO" || "$MODELO" == "To Be Filled By O.E.M." ]] && MODELO="N/A"
fi

# ── 15. IP local ─────────────────────────────────────────────
IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1 || hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")

# ── 16. MACs ─────────────────────────────────────────────────
MAC_ETHERNET=""
MAC_WIFI="----"
while IFS= read -r iface; do
  n=$(basename "$iface")
  [[ "$n" == "lo" ]] && continue
  [[ ! -f "${iface}/address" ]] && continue
  mac=$(cat "${iface}/address" 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d ':')
  [[ -z "$mac" || "$mac" == "000000000000" ]] && continue
  if [[ -d "${iface}/wireless" ]]; then
    MAC_WIFI="$mac"
  else
    [[ -n "$MAC_ETHERNET" ]] && MAC_ETHERNET="${MAC_ETHERNET} | "
    MAC_ETHERNET="${MAC_ETHERNET}${mac}"
  fi
done < <(find /sys/class/net -mindepth 1 -maxdepth 1)
[[ -z "$MAC_ETHERNET" ]] && MAC_ETHERNET="N/A"

# ── 17. Gráfica ──────────────────────────────────────────────
GRAFICA="N/A"
if command -v lspci &>/dev/null; then
  GRAFICA=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | sed 's/.*: //' | head -1 | xargs || echo "N/A")
fi

# ── 18. Dualizado ─────────────────────────────────────────────
DUALIZADO="NO"
if command -v lsblk &>/dev/null && lsblk -f 2>/dev/null | grep -qi 'ntfs'; then
  DUALIZADO="SI"
fi
if [[ -d /sys/firmware/efi/efivars ]] && ls /sys/firmware/efi/efivars/ 2>/dev/null | grep -qi 'windows'; then
  DUALIZADO="SI"
fi

# ── 19. Secure Boot ───────────────────────────────────────────
SECURE_BOOT="N/A"
if command -v mokutil &>/dev/null; then
  SB=$(mokutil --sb-state 2>/dev/null || echo "")
  echo "$SB" | grep -qi "enabled" && SECURE_BOOT="enabled"
  echo "$SB" | grep -qi "disabled" && SECURE_BOOT="disabled"
elif [[ -f "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" ]]; then
  SBB=$(od -An -tu1 "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" 2>/dev/null | awk '{print $NF}')
  [[ "$SBB" == "1" ]] && SECURE_BOOT="enabled" || SECURE_BOOT="disabled"
elif [[ ! -d /sys/firmware/efi ]]; then
  SECURE_BOOT="no-efi"
fi

# ── 20. IP pública ────────────────────────────────────────────
IP_PUBLICA="N/A"
if command -v curl &>/dev/null; then
  IP_PUBLICA=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")
elif command -v wget &>/dev/null; then
  IP_PUBLICA=$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || echo "N/A")
fi

# ═══════════════════════════════════════════════════════════
# CONSTRUIR JSON Y ENVIAR
# ═══════════════════════════════════════════════════════════
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//'; }

PAYLOAD=$(cat <<EOF
{
  "cid":          "$(json_esc "$CID")",
  "estado":       "$(json_esc "$ESTADO")",
  "version":      "$(json_esc "$VERSION")",
  "arch":         "$(json_esc "$ARCH")",
  "name":         "$(json_esc "$NAME")",
  "serial":       "$(json_esc "$SERIAL")",
  "ultima_act":   "$(json_esc "$ULTIMA_ACT")",
  "etiquetas":    "$(json_esc "$ETIQUETAS")",
  "cpu":          "$(json_esc "$CPU")",
  "memoria_mb":   $MEMORIA_MB,
  "slots_memoria":"$(json_esc "$SLOTS_MEMORIA")",
  "disco_gb":     "$DISCO_GB",
  "tipo_disco":   "$(json_esc "$TIPO_DISCO")",
  "modelo":       "$(json_esc "$MODELO")",
  "ip":           "$(json_esc "$IP")",
  "mac_ethernet": "$(json_esc "$MAC_ETHERNET")",
  "mac_wifi":     "$(json_esc "$MAC_WIFI")",
  "grafica":      "$(json_esc "$GRAFICA")",
  "dualizado":    "$(json_esc "$DUALIZADO")",
  "secure_boot":  "$(json_esc "$SECURE_BOOT")",
  "ip_publica":   "$(json_esc "$IP_PUBLICA")"
}
EOF
)

log "Enviando a $SERVER_URL/api/inventario ..."

if command -v curl &>/dev/null; then
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "${SERVER_URL}/api/inventario" \
    -H "Content-Type: application/json" \
    -H "X-Api-Token: ${API_TOKEN}" \
    --max-time 15 \
    -d "$PAYLOAD" 2>/dev/null)
  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -1)
else
  log "ERROR: curl no está instalado. Instalar con: sudo apt install curl"
  exit 1
fi

if [[ "$HTTP_CODE" == "200" ]]; then
  log "OK: $BODY"
  echo "✓ Inventario enviado correctamente (CID: $CID)"
else
  log "ERROR HTTP $HTTP_CODE: $BODY"
  echo "✗ Error al enviar inventario (HTTP $HTTP_CODE)" >&2
  exit 1
fi
