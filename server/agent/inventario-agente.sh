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
SERVER_URL="http://172.16.1.250:3900"
API_TOKEN="cambia_esto_por_un_secreto_seguro"
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

# ── Helper: escape JSON seguro ────────────────────────────────
# Usa jq si está disponible; si no, escapa manualmente los caracteres problemáticos
json_esc() {
  local val="$1"
  if command -v jq &>/dev/null; then
    printf '%s' "$val" | jq -Rs .    | sed 's/^"//;s/"$//'
  else
    printf '%s' "$val" \
      | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g' \
      | tr -d '\000-\037'
  fi
}

# ── Trim (sin xargs) ──────────────────────────────────────────
trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# ── 1. CID ────────────────────────────────────────────────────
CID=""
if command -v migasfree-cid &>/dev/null; then
  CID=$(migasfree-cid 2>/dev/null || true)
fi
if [[ -z "$CID" ]]; then
  # Fallback: usar MAC de la interfaz de salida principal
  _iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
  if [[ -n "$_iface" && -f "/sys/class/net/${_iface}/address" ]]; then
    CID="mac-$(cat "/sys/class/net/${_iface}/address" 2>/dev/null | tr -d ':' | tr '[:upper:]' '[:lower:]')"
  fi
fi
if [[ -z "$CID" ]]; then
  log "ERROR: No se pudo obtener CID"
  exit 1
fi
log "CID: $CID"

# ── 2. Estado ─────────────────────────────────────────────────
ESTADO="OK"

# ── 3. Versión ────────────────────────────────────────────────
VERSION=$(dpkg -l vx-dga-l-conky 2>/dev/null | awk '/^ii/{split($3,v,"."); print "VX-" v[1] ".x"}')
[[ -z "$VERSION" ]] && VERSION="N/A"

# ── 4. Arquitectura ───────────────────────────────────────────
# Formato SO-HW (ej: 64-64) para consistencia con datos históricos
ARCH_SO=$(uname -m | grep -q 'x86_64' && echo "64" || echo "32")
ARCH_HW=$(grep -m1 'flags' /proc/cpuinfo 2>/dev/null | grep -q '\blm\b' && echo "64" || echo "32")
ARCH="${ARCH_SO}-${ARCH_HW}"

# ── 5. Nombre del equipo ──────────────────────────────────────
NAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null | tr -d '\n' || echo "N/A")

# ── 6. SN Placa ───────────────────────────────────────────────
SERIAL="N/A"
if command -v dmidecode &>/dev/null; then
  SERIAL=$(dmidecode -s baseboard-serial-number 2>/dev/null | trim || true)
  [[ "$SERIAL" == "To Be Filled By O.E.M." || -z "$SERIAL" ]] && SERIAL="N/A"
fi

# ── 7. Última actualización (normalizada a segundos, sin nanosegundos) ──
ULTIMA_ACT="N/A"
if [[ -f /var/log/dpkg.log ]]; then
  ULTIMA_ACT=$(grep -E "upgrade|install" /var/log/dpkg.log 2>/dev/null \
    | tail -1 | awk '{print $1"T"$2}' | cut -c1-19 || true)
fi
if [[ "$ULTIMA_ACT" == "N/A" || -z "$ULTIMA_ACT" ]] && [[ -f /var/cache/apt/pkgcache.bin ]]; then
  ULTIMA_ACT=$(stat -c '%y' /var/cache/apt/pkgcache.bin 2>/dev/null \
    | awk '{print $1"T"$2}' | cut -c1-19 | head -1 || true)
fi
[[ -z "$ULTIMA_ACT" ]] && ULTIMA_ACT="N/A"

# ── 8. Etiquetas Migasfree ────────────────────────────────────
ETIQUETAS=$(migasfree-tags -g 2>/dev/null \
  | tr -d '"' | sed 's/[A-Za-z]*-//g' \
  | tr ',' '\n' | grep -v '^$' \
  | tr '\n' ',' | sed 's/,/, /g; s/, $//' \
  || true)
[[ -z "$ETIQUETAS" ]] && ETIQUETAS="N/A"

# ── 9. CPU ───────────────────────────────────────────────────
CPU=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //; s/(R)//g; s/(TM)//g; s/  */ /g; s/ CPU @ /   /; s/ GHz/GHz/')
[[ -z "$CPU" ]] && CPU="N/A"

# ── 10. RAM (MB redondeada a potencia de 2) ───────────────────
MEMORIA_MB=$(awk '/MemTotal/{mb=$2/1024; p=1; while(p<mb) p*=2; print (mb-p/2 < p-mb) ? p/2 : p}' /proc/meminfo)
[[ -z "$MEMORIA_MB" ]] && MEMORIA_MB="0"

# ── 11. Slots RAM ─────────────────────────────────────────────
SLOTS_MEMORIA="N/A"
if command -v dmidecode &>/dev/null; then
  SLOTS_OUTPUT=$(dmidecode -t memory 2>/dev/null | grep -E "Memory Device|Size")
  SLOTS_TOTAL=$(echo "$SLOTS_OUTPUT" | grep -c "^Memory Device$" || true)
  SLOTS_LIBRES=$(echo "$SLOTS_OUTPUT" | grep -c "No Module Installed" || true)
  [[ "${SLOTS_TOTAL:-0}" -gt 0 ]] && SLOTS_MEMORIA="${SLOTS_TOTAL} (${SLOTS_LIBRES} libres)"
fi

# ── 12. Disco ────────────────────────────────────────────────
DISCO_GB=$(lsblk -bdno SIZE,TYPE 2>/dev/null | awk '$2=="disk"{sum+=$1} END{printf "%.9f", sum/1000000000}')
[[ -z "$DISCO_GB" ]] && DISCO_GB="N/A"

# ── 13. Tipo disco ────────────────────────────────────────────
TIPO_DISCO="N/A"
_root_dev=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || true)
if [[ -n "$_root_dev" ]]; then
  _rot=$(cat /sys/block/${_root_dev}/queue/rotational 2>/dev/null || true)
  if [[ "$_root_dev" == nvme* ]]; then
    TIPO_DISCO="nvme"
  elif [[ "$_rot" == "0" ]]; then
    TIPO_DISCO="ssd"
  else
    TIPO_DISCO="hdd"
  fi
fi

# ── 14. Modelo ───────────────────────────────────────────────
MODELO="N/A"
if command -v dmidecode &>/dev/null; then
  MP=$(dmidecode -s system-product-name 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  MS=$(dmidecode -s system-sku-number 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$MP" || -n "$MS" ]] && MODELO="${MP} (${MS})"
fi

# ── 15. IP local ─────────────────────────────────────────────
IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1 \
  || hostname -I 2>/dev/null | awk '{print $1}' \
  || echo "N/A")

# ── 16. MACs ─────────────────────────────────────────────────
_main_iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || true)
MAC_ETHERNET=$(cat /sys/class/net/${_main_iface}/address 2>/dev/null || true)
[[ -z "$MAC_ETHERNET" ]] && MAC_ETHERNET="N/A"

_wifi_mac=$(for _w in /sys/class/net/*/wireless; do cat "${_w}/../address" 2>/dev/null; done)
MAC_WIFI="${_wifi_mac:-"-----"}"

# ── 17. Gráfica ──────────────────────────────────────────────
GRAFICA=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' \
  | sed 's/.*: //' | sed 's/^[A-Za-z]* Corporation //; s/ (rev [0-9a-f]*)$//' \
  | head -1 || true)
[[ -z "$GRAFICA" ]] && GRAFICA="N/A"

# ── 18. Dualizado ─────────────────────────────────────────────
DUALIZADO=$(efibootmgr 2>/dev/null | grep -qi "windows" && echo "SI" || echo "NO")

# ── 19. Secure Boot ───────────────────────────────────────────
SECURE_BOOT="---"
if command -v mokutil &>/dev/null; then
  SB=$(mokutil --sb-state 2>/dev/null || true)
  if echo "$SB" | grep -qi "enabled"; then
    SECURE_BOOT="enabled"
  elif echo "$SB" | grep -qi "disabled"; then
    SECURE_BOOT="disabled"
  else
    SECURE_BOOT="unknown"
  fi
elif [[ -d /sys/firmware/efi ]]; then
  SECURE_BOOT="unknown"
fi

# ── 20. IP pública ────────────────────────────────────────────
IP_PUBLICA="N/A"
if command -v dig &>/dev/null; then
  IP_PUBLICA=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -1 || true)
elif command -v curl &>/dev/null; then
  IP_PUBLICA=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
elif command -v wget &>/dev/null; then
  IP_PUBLICA=$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)
fi
[[ -z "$IP_PUBLICA" ]] && IP_PUBLICA="N/A"

# ═══════════════════════════════════════════════════════════
# CONSTRUIR JSON Y ENVIAR
# ═══════════════════════════════════════════════════════════
PAYLOAD=$(cat <<EOF
{
  "cid":           "$(json_esc "$CID")",
  "estado":        "$(json_esc "$ESTADO")",
  "version":       "$(json_esc "$VERSION")",
  "arch":          "$(json_esc "$ARCH")",
  "name":          "$(json_esc "$NAME")",
  "serial":        "$(json_esc "$SERIAL")",
  "ultima_act":    "$(json_esc "$ULTIMA_ACT")",
  "etiquetas":     "$(json_esc "$ETIQUETAS")",
  "cpu":           "$(json_esc "$CPU")",
  "memoria_mb":    $MEMORIA_MB,
  "slots_memoria": "$(json_esc "$SLOTS_MEMORIA")",
  "disco_gb":      "$(json_esc "$DISCO_GB")",
  "tipo_disco":    "$(json_esc "$TIPO_DISCO")",
  "modelo":        "$(json_esc "$MODELO")",
  "ip":            "$(json_esc "$IP")",
  "mac_ethernet":  "$(json_esc "$MAC_ETHERNET")",
  "mac_wifi":      "$(json_esc "$MAC_WIFI")",
  "grafica":       "$(json_esc "$GRAFICA")",
  "dualizado":     "$(json_esc "$DUALIZADO")",
  "secure_boot":   "$(json_esc "$SECURE_BOOT")",
  "ip_publica":    "$(json_esc "$IP_PUBLICA")"
}
EOF
)

log "Enviando a $SERVER_URL/api/inventario ..."

if ! command -v curl &>/dev/null; then
  log "ERROR: curl no está instalado. Instalar con: sudo apt install curl"
  exit 1
fi

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${SERVER_URL}/api/inventario" \
  -H "Content-Type: application/json" \
  -H "X-Api-Token: ${API_TOKEN}" \
  --max-time 15 \
  -d "$PAYLOAD" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)

if [[ "$HTTP_CODE" == "200" ]]; then
  log "OK: $BODY"
  echo "✓ Inventario enviado correctamente (CID: $CID)"
else
  log "ERROR HTTP $HTTP_CODE: $BODY"
  echo "✗ Error al enviar inventario (HTTP $HTTP_CODE)" >&2
  exit 1
fi
