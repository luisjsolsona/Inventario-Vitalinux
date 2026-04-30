# Inventario Vitalinux · MistikEdu

Sistema de inventario de equipos tipo OCS para institutos con Vitalinux.
Los equipos cliente envían sus datos automáticamente al servidor Docker.

---

## Estructura del proyecto

```
inventario-vitalinux/
├── docker-compose.yml          ← Desplegar en CasaOS
├── server/
│   ├── Dockerfile
│   ├── package.json
│   ├── src/
│   │   ├── index.js            ← Servidor Express
│   │   ├── db.js               ← SQLite + init
│   │   ├── middleware/auth.js  ← JWT
│   │   └── routes/
│   │       ├── auth.js         ← Login/logout
│   │       ├── equipos.js      ← CRUD web
│   │       └── api.js          ← Endpoint agente + export
│   └── public/
│       ├── login.html          ← Página de acceso
│       └── index.html          ← Dashboard principal
└── agent/
    ├── inventario-agente.sh    ← Script cliente
    └── instalar-agente.sh      ← Instalador con cron
```

---

## 1. Desplegar el servidor (en tu NUC/CasaOS)

### Opción A — CasaOS (recomendado)
1. En CasaOS → "App Store" → "Custom Install" → subir `docker-compose.yml`
2. Editar las variables de entorno antes de instalar:
   - `JWT_SECRET` → clave secreta fuerte (mínimo 32 caracteres)
   - `ADMIN_USER` → nombre del admin
   - `ADMIN_PASS` → contraseña del admin

### Opción B — Terminal
```bash
cd inventario-vitalinux
# Editar JWT_SECRET en docker-compose.yml primero
docker compose up -d --build
```

Acceder en: `http://192.168.0.100:3900`

---

## 2. Configurar el agente en cada equipo

### Paso 1 — Editar variables en inventario-agente.sh
```bash
SERVER_URL="http://192.168.0.100:3900"         # IP de tu servidor
API_TOKEN="cambia_esto_por_un_secreto_seguro"  # Mismo JWT_SECRET del docker-compose
```

### Paso 2 — Distribuir e instalar
```bash
# En cada equipo Vitalinux:
sudo ./instalar-agente.sh
```

Esto:
- Copia el agente a `/usr/local/bin/inventario-agente.sh`
- Crea un cron que ejecuta el inventario al arranque + cada día a las 08:05
- Ejecuta el primer inventario inmediatamente

### Envío manual
```bash
sudo /usr/local/bin/inventario-agente.sh
```

---

## 3. Distribución masiva con Migasfree

Si usas Migasfree para gestión centralizada, puedes distribuir el agente
como un paquete o script post-install:

```bash
# En el servidor Migasfree, crear fórmula:
# 1. Subir inventario-agente.sh a /usr/local/bin/ con permisos 755
# 2. Instalar el cron en /etc/cron.d/inventario-vitalinux
```

---

## Variables de entorno (docker-compose.yml)

| Variable     | Descripción                              | Por defecto   |
|-------------|------------------------------------------|---------------|
| PORT        | Puerto del servidor                       | 3900          |
| JWT_SECRET  | Clave para firmar tokens JWT (cambiar)    | —             |
| ADMIN_USER  | Usuario administrador inicial             | admin         |
| ADMIN_PASS  | Contraseña administrador inicial          | admin1234     |

> ⚠️ **Cambiar JWT_SECRET y ADMIN_PASS antes de producción.**
> El JWT_SECRET debe ser igual en `docker-compose.yml` y en el agente bash.

---

## API del agente

### POST /api/inventario
Recibe datos del equipo. Requiere header `X-Api-Token`.

```bash
curl -X POST http://IP:3900/api/inventario \
  -H "Content-Type: application/json" \
  -H "X-Api-Token: TU_TOKEN" \
  -d '{"cid":"12345","name":"fpb1-01",...}'
```

### GET /api/export/csv
Descarga el inventario completo en TSV (para Calc/Excel).

---

## Campos registrados

| Campo             | Fuente en el cliente          |
|-------------------|-------------------------------|
| CID               | `migasfree-cid`               |
| Estado            | Siempre "Activo" al reportar  |
| Versión           | `/etc/vitalinux-release`      |
| Arquitectura      | `uname` + `/proc/cpuinfo`     |
| Nombre equipo     | `hostname`                    |
| Número de serie   | `dmidecode`                   |
| Última actualiz.  | `/var/log/dpkg.log`           |
| Etiquetas         | Cache Migasfree               |
| CPU               | `/proc/cpuinfo`               |
| RAM (MB)          | `/proc/meminfo`               |
| Slots RAM         | `dmidecode -t memory`         |
| Disco (bytes)     | `lsblk`                       |
| Tipo disco        | `/sys/block/*/rotational`     |
| Modelo            | `dmidecode`                   |
| IP local          | `ip route`                    |
| MACs Ethernet     | `/sys/class/net`              |
| MAC WiFi          | `/sys/class/net/*/wireless`   |
| Gráfica           | `lspci`                       |
| Dualizado         | `lsblk -f` (busca NTFS)      |
| Secure Boot       | `mokutil` / EFI vars          |
| IP pública        | `api.ipify.org`               |

---

## Historial de cambios

Cada vez que un equipo reporta datos, el servidor detecta qué campos
han cambiado y los registra en la tabla `historial`. Visible en el
modal de detalle de cada equipo.
