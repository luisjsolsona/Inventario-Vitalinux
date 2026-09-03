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

# ── Detección de valores placeholder del firmware ──────────────
# Muchos fabricantes dejan estos campos sin programar y el firmware
# devuelve el propio nombre del campo o un texto genérico en su lugar.
is_placeholder() {
  local v
  v=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$v" in
    ""|"to be filled by o.e.m."|"system serial number"|"base board serial number"|\
    "baseboard serial number"|"chassis serial number"|"default string"|\
    "not specified"|"none"|"n/a"|"unknown"|"0"|"0000000000"|"123456789"|"1234567890")
      return 0 ;;
    *) return 1 ;;
  esac
}

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
# No todos los fabricantes programan los mismos campos DMI: en portátiles
# de marca (Lenovo, Dell...) el fiable suele ser system-serial-number; en
# PCs de sobremesa genéricos ese campo a veces no está programado y el
# firmware devuelve un texto placeholder ("System Serial Number", "To Be
# Filled By O.E.M."...), mientras que baseboard-serial-number sí tiene un
# valor real. Se prueban en orden y se usa el primero que no sea un
# placeholder.
SERIAL="N/A"
if command -v dmidecode &>/dev/null; then
  for _campo in system-serial-number baseboard-serial-number chassis-serial-number; do
    _val=$(dmidecode -s "$_campo" 2>/dev/null | trim || true)
    # Eliminar formato DMI path: /SERIAL/ruta/extra/ → SERIAL
    _val=$(echo "$_val" | sed 's|^/||; s|/.*||' | trim)
    if ! is_placeholder "$_val"; then
      SERIAL="$_val"
      break
    fi
  done
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
  _etq_wait=0; _etq_empty=0
  while [[ $_etq_wait -lt 60 ]]; do
    _tags_raw=$(migasfree-tags -g 2>/dev/null || true)
    if echo "$_tags_raw" | grep -qi 'instancia'; then
      sleep 5; _etq_wait=$((_etq_wait + 5)); continue
    fi
    if [[ -z "$_tags_raw" && $_etq_empty -lt 3 ]]; then
      _etq_empty=$((_etq_empty + 1))
      sleep 5; _etq_wait=$((_etq_wait + 5)); continue
    fi
    ETIQUETAS=$(printf '%s' "$_tags_raw" \
      | tr -d '"' | sed 's/[A-Za-z]*-//g' \
      | tr ',' '\n' | grep -v '^$' \
      | tr '\n' ',' | sed 's/,/, /g; s/, $//' || true)
    break
  done
fi
[[ -z "$ETIQUETAS" ]] && ETIQUETAS="N/A"

# ── 9. CPU ───────────────────────────────────────────────────
CPU=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //; s/(R)//g; s/(TM)//g; s/  */ /g; s/ CPU @ / /; s/ @ / /; s/ GHz/GHz/')
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
# Se excluyen zram, loop, dm-, sr, fd, ram, nbd y md: lsblk los reporta como
# TYPE="disk" pero no son discos físicos. zram en concreto puede cambiar de
# tamaño según la RAM libre en cada arranque, dando lecturas distintas cada
# día sin que el disco real haya cambiado (mismo filtro que usa TIPO_DISCO).
DISCO_GB=$(lsblk -bdno NAME,SIZE,TYPE 2>/dev/null | awk '
  $3=="disk" && $1 !~ /^(zram|loop|dm-|sr|fd|ram|nbd|md)/ { sum += $2 }
  END { if (sum>0) printf "%.9f", sum/1000000000 }')
[[ -z "$DISCO_GB" ]] && DISCO_GB="N/A"

# ── 13. Tipo disco ────────────────────────────────────────────
# NVMe tiene rotational=0, se trata como ssd para compatibilidad con datos históricos
TIPO_DISCO="N/A"
HAS_SSD=false; HAS_HDD=false
for _dev in /sys/block/*/queue/rotational; do
  [[ -f "$_dev" ]] || continue
  _dname=$(echo "$_dev" | awk -F'/' '{print $4}')
  [[ "$_dname" =~ ^(sr|loop|dm|zram|fd|ram|nbd|md) ]] && continue
  [[ "$(cat /sys/block/${_dname}/removable 2>/dev/null)" == "1" ]] && continue
  _rot=$(cat "$_dev" 2>/dev/null)
  [[ "$_rot" == "0" ]] && HAS_SSD=true
  [[ "$_rot" == "1" ]] && HAS_HDD=true
done
if $HAS_SSD && $HAS_HDD; then TIPO_DISCO="ssd+hdd"
elif $HAS_SSD; then TIPO_DISCO="ssd"
elif $HAS_HDD; then TIPO_DISCO="hdd"
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
MAC_ETHERNET=$(cat /sys/class/net/${_main_iface}/address 2>/dev/null | tr -d ':' | tr '[:lower:]' '[:upper:]' || true)
[[ -z "$MAC_ETHERNET" ]] && MAC_ETHERNET="N/A"

_wifi_mac=$(for _w in /sys/class/net/*/wireless; do cat "${_w}/../address" 2>/dev/null; done)
MAC_WIFI="${_wifi_mac:-"----"}"

# ── 17. Gráfica ──────────────────────────────────────────────
GRAFICA=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' \
  | sed 's/.*: //' | sed 's/^[A-Za-z]* Corporation //; s/ (rev [0-9a-f]*)$//' \
  | head -1 || true)
[[ -z "$GRAFICA" ]] && GRAFICA="N/A"

# ── 18. Dualizado ─────────────────────────────────────────────
DUALIZADO="NO"
if command -v lsblk &>/dev/null && lsblk -f 2>/dev/null | grep -qi 'ntfs'; then
  DUALIZADO="SI"
fi

# ── 19. Secure Boot ───────────────────────────────────────────
SECURE_BOOT="N/A"
_sb_efivar="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"

# Método 1: mokutil
if command -v mokutil &>/dev/null; then
  _sb_out=$(mokutil --sb-state 2>/dev/null || true)
  echo "$_sb_out" | grep -qi "enabled"  && SECURE_BOOT="enabled"
  echo "$_sb_out" | grep -qi "disabled" && SECURE_BOOT="disabled"
fi

# Método 2: variable EFI (byte de estado, saltando 4 bytes de atributos)
if [[ "$SECURE_BOOT" == "N/A" ]]; then
  if [[ -f "$_sb_efivar" ]]; then
    _sb_byte=$(od -An -j4 -N1 -tu1 "$_sb_efivar" 2>/dev/null | tr -d ' \n')
    [[ "$_sb_byte" == "1" ]] && SECURE_BOOT="enabled"
    [[ "$_sb_byte" == "0" ]] && SECURE_BOOT="disabled"
  elif [[ ! -d /sys/firmware/efi ]]; then
    SECURE_BOOT="no-efi"
  fi
fi

# Si ambos métodos fallan, intentar /sys/firmware/efi/vars (interfaz antigua)
if [[ "$SECURE_BOOT" == "N/A" ]]; then
  _sb_efivar2="/sys/firmware/efi/vars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c/data"
  if [[ -f "$_sb_efivar2" ]]; then
    _sb_byte=$(od -An -N1 -tu1 "$_sb_efivar2" 2>/dev/null | tr -d ' \n')
    [[ "$_sb_byte" == "1" ]] && SECURE_BOOT="enabled"
    [[ "$_sb_byte" == "0" ]] && SECURE_BOOT="disabled"
  fi
fi

[[ "$SECURE_BOOT" == "N/A" ]] && SECURE_BOOT="unknown"

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
