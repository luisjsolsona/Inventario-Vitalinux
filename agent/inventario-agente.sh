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
    printf '%s' "$val" | jq -Rrs .  | sed 's/^"//;s/"$//'
  else
    printf '%s' "$val" \
      | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g' \
      | tr -d '\000-\031'
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
VERSION="N/A"
if [[ -f /etc/vitalinux-release ]]; then
  VERSION=$(grep -oP 'VX-\S+' /etc/vitalinux-release 2>/dev/null | head -1 || true)
  [[ -z "$VERSION" ]] && VERSION=$(head -1 /etc/vitalinux-release 2>/dev/null || true)
elif [[ -f /etc/os-release ]]; then
  VERSION=$(. /etc/os-release; echo "${PRETTY_NAME:-N/A}")
fi
[[ -z "$VERSION" ]] && VERSION="N/A"

# ── 4. Arquitectura ───────────────────────────────────────────
# Se reporta la arquitectura del SO (64 o 32 bits)
ARCH=$(uname -m | grep -q 'x86_64' && echo "64" || echo "32")

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
ETIQUETAS="N/A"
if command -v migasfree-tags &>/dev/null; then
  ETIQUETAS=$(migasfree-tags -g 2>/dev/null | grep -v '^$' | tr '\n' ',' | sed 's/,$//' || true)
  [[ -z "$ETIQUETAS" ]] && ETIQUETAS="N/A"
fi

# ── 9. CPU ───────────────────────────────────────────────────
# dmidecode lee del BIOS (estable entre actualizaciones de kernel)
CPU="N/A"
if command -v dmidecode &>/dev/null; then
  _cpu=$(dmidecode -s processor-version 2>/dev/null | grep -v '^#' | head -1 | trim || true)
  [[ -n "$_cpu" && "$_cpu" != "To Be Filled By O.E.M." ]] && CPU="$_cpu"
fi
if [[ "$CPU" == "N/A" ]]; then
  CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
    | sed 's/.*: //; s/  */ /g' | trim || echo "N/A")
fi
[[ -z "$CPU" ]] && CPU="N/A"

# ── 10. RAM (MB como float) ───────────────────────────────────
MEMORIA_MB=$(awk '/MemTotal/{printf "%.1f", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")

# ── 11. Slots RAM ─────────────────────────────────────────────
SLOTS_MEMORIA="N/A"
if command -v dmidecode &>/dev/null; then
  SLOTS_OUTPUT=$(dmidecode -t memory 2>/dev/null | grep -E "Memory Device|Size")
  SLOTS_TOTAL=$(echo "$SLOTS_OUTPUT" | grep -c "^Memory Device$" || true)
  SLOTS_LIBRES=$(echo "$SLOTS_OUTPUT" | grep -c "No Module Installed" || true)
  [[ "${SLOTS_TOTAL:-0}" -gt 0 ]] && SLOTS_MEMORIA="${SLOTS_TOTAL} (${SLOTS_LIBRES} libres)"
fi

# ── 12. Disco (bytes brutos) ──────────────────────────────────
# El frontend convierte a GB/TB con fmtBytes(); se envía como string
DISCO_GB="0"
if command -v lsblk &>/dev/null; then
  DISCO_BYTES=$(lsblk -bdno SIZE,TYPE 2>/dev/null | awk '$2=="disk"{sum+=$1} END{print sum+0}')
  [[ -n "$DISCO_BYTES" && "$DISCO_BYTES" != "0" ]] && DISCO_GB="$DISCO_BYTES"
fi

# ── 13. Tipo disco ────────────────────────────────────────────
TIPO_DISCO="N/A"
HAS_SSD=false; HAS_HDD=false; HAS_NVME=false
for dev in /sys/block/*/queue/rotational; do
  [[ -f "$dev" ]] || continue
  devname=$(echo "$dev" | awk -F'/' '{print $4}')
  # Excluir ópticas, loop, device-mapper, zram, floppy, RAM disk, etc.
  [[ "$devname" =~ ^(sr|loop|dm|zram|fd|ram|nbd|md) ]] && continue
  [[ "$devname" == nvme* ]] && HAS_NVME=true && continue
  rot=$(cat "$dev" 2>/dev/null)
  [[ "$rot" == "0" ]] && HAS_SSD=true
  [[ "$rot" == "1" ]] && HAS_HDD=true
done
if $HAS_NVME; then TIPO_DISCO="nvme"
elif $HAS_SSD && $HAS_HDD; then TIPO_DISCO="ssd+hdd"
elif $HAS_SSD; then TIPO_DISCO="ssd"
elif $HAS_HDD; then TIPO_DISCO="hdd"
fi

# ── 14. Modelo ───────────────────────────────────────────────
MODELO="N/A"
if command -v dmidecode &>/dev/null; then
  MP=$(dmidecode -s system-product-name 2>/dev/null | trim || true)
  MS=$(dmidecode -s system-sku-number 2>/dev/null | trim || true)
  [[ "$MP" == "To Be Filled By O.E.M." ]] && MP=""
  [[ "$MS" == "To Be Filled By O.E.M." ]] && MS=""
  MODELO="${MP}${MS:+ ($MS)}"
  [[ -z "$MODELO" ]] && MODELO="N/A"
fi

# ── 15. IP local ─────────────────────────────────────────────
IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1 \
  || hostname -I 2>/dev/null | awk '{print $1}' \
  || echo "N/A")

# ── 16. MACs ─────────────────────────────────────────────────
# Nota: si hay varias interfaces ethernet, se separan con " | "
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
  GRAFICA=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' \
    | sed 's/^[^ ]* [^:]*: //' | head -1 | trim || echo "N/A")
fi

# ── 18. Dualizado ─────────────────────────────────────────────
# Se detecta por presencia de partición NTFS (método más fiable en Linux)
DUALIZADO="NO"
# Método 1: efibootmgr lista una entrada Windows
if command -v efibootmgr &>/dev/null && efibootmgr 2>/dev/null | grep -qi "windows"; then
  DUALIZADO="SI"
fi
# Método 2: directorio EFI/Microsoft en la partición EFI montada
if [[ "$DUALIZADO" == "NO" ]]; then
  for _efi in /boot/efi /efi /boot; do
    [[ -d "$_efi/EFI/Microsoft" ]] && DUALIZADO="SI" && break
  done
fi
# Método 3: partición NTFS en disco interno (no extraíble)
if [[ "$DUALIZADO" == "NO" ]] && command -v lsblk &>/dev/null; then
  if lsblk -lo FSTYPE,RM,TYPE 2>/dev/null | awk 'NR>1 && /ntfs|NTFS/ && $2=="0" && $3=="part"{found=1} END{exit !found}'; then
    DUALIZADO="SI"
  fi
fi

# ── 19. Secure Boot ───────────────────────────────────────────
SECURE_BOOT="N/A"
if command -v mokutil &>/dev/null; then
  SB=$(mokutil --sb-state 2>/dev/null || true)
  echo "$SB" | grep -qi "enabled"  && SECURE_BOOT="enabled"
  echo "$SB" | grep -qi "disabled" && SECURE_BOOT="disabled"
elif [[ -f "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" ]]; then
  SBB=$(od -An -tu1 "/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" \
    2>/dev/null | awk '{print $NF}')
  [[ "$SBB" == "1" ]] && SECURE_BOOT="enabled" || SECURE_BOOT="disabled"
elif [[ ! -d /sys/firmware/efi ]]; then
  SECURE_BOOT="no-efi"
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