# Inventario Vitalinux

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Node.js](https://img.shields.io/badge/Node.js-20-green.svg)](https://nodejs.org)
[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://docs.docker.com/compose/)

Sistema de inventario hardware centralizado para institutos con equipos **Vitalinux** (Debian educativo).  
Los equipos cliente recopilan sus datos automáticamente y los envían al servidor. El administrador visualiza y gestiona el inventario desde un dashboard web.

> Desarrollado por **MistikEdu · Luis J. Solsona**

---

## Características

- **Agente Bash** ligero — sin dependencias extra en los clientes
- **20 campos de hardware** recogidos automáticamente (CPU, RAM, disco, red, Secure Boot…)
- **Dashboard web** con búsqueda, filtros y modal de detalle por equipo
- **Historial de cambios** por equipo (detecta qué campos cambiaron y cuándo)
- **Exportación TSV** compatible con LibreOffice Calc / Excel
- **Integración Migasfree** — usa `migasfree-cid` y etiquetas del cliente
- **Despliegue Docker** con soporte nativo para CasaOS
- **Autenticación JWT** con roles (admin / viewer)

---

## Estructura del proyecto

```
inventario-vitalinux/
├── docker-compose.yml          ← Desplegar en CasaOS / Docker
├── server/
│   ├── Dockerfile
│   ├── package.json
│   └── src/
│       ├── index.js            ← Servidor Express (puerto 3900)
│       ├── db.js               ← SQLite + inicialización
│       ├── middleware/
│       │   └── auth.js         ← JWT + API token
│       └── routes/
│           ├── auth.js         ← Login / logout
│           ├── equipos.js      ← CRUD equipos + estadísticas
│           └── api.js          ← Endpoint agente + exportación CSV
│   └── public/
│       ├── login.html          ← Página de acceso
│       └── index.html          ← Dashboard principal
└── agent/
    ├── inventario-agente.sh    ← Script cliente (ejecutar en cada equipo)
    └── instalar-agente.sh      ← Instalador automático con cron
```

---

## 1. Desplegar el servidor

### Opción A — CasaOS (recomendado)

1. En CasaOS → **App Store** → **Custom Install** → subir `docker-compose.yml`
2. Antes de instalar, editar las variables de entorno:
   - `JWT_SECRET` → clave secreta larga (mínimo 32 caracteres)
   - `API_TOKEN` → token para los agentes (puede ser igual a `JWT_SECRET`)
   - `ADMIN_USER` → nombre del administrador
   - `ADMIN_PASS` → contraseña del administrador

### Opción B — Terminal

```bash
# 1. Editar JWT_SECRET, API_TOKEN y ADMIN_PASS en docker-compose.yml
# 2. Levantar el servicio
docker compose up -d --build
```

Acceder en: `http://<IP_SERVIDOR>:3900`

---

## 2. Configurar el agente en cada equipo

### Paso 1 — Editar variables en `inventario-agente.sh`

```bash
SERVER_URL="http://192.168.0.100:3900"         # IP de tu servidor
API_TOKEN="cambia_esto_por_un_secreto_seguro"  # Valor de API_TOKEN en docker-compose
```

### Paso 2 — Instalar en el equipo

```bash
sudo ./instalar-agente.sh
```

Esto:
- Copia el agente a `/usr/local/bin/inventario-agente.sh`
- Registra un cron que ejecuta el inventario **al arranque** + **cada día a las 08:05**
- Lanza el primer inventario de forma inmediata

### Envío manual

```bash
sudo /usr/local/bin/inventario-agente.sh
```

Log en: `/var/log/inventario-agente.log`

---

## 3. Distribución masiva con Migasfree

Si gestionas los equipos con Migasfree, puedes distribuir el agente como fórmula o paquete:

```bash
# Copiar el agente con permisos de ejecución
install -m 755 inventario-agente.sh /usr/local/bin/

# Instalar el cron
echo "5 8 * * * root /usr/local/bin/inventario-agente.sh" \
  > /etc/cron.d/inventario-vitalinux
```

---

## Variables de entorno

| Variable     | Descripción                                          | Por defecto          |
|-------------|------------------------------------------------------|----------------------|
| `PORT`      | Puerto del servidor                                  | `3900`               |
| `JWT_SECRET`| Clave para firmar tokens JWT — **CAMBIAR**           | —                    |
| `API_TOKEN` | Token de autenticación para los agentes — **CAMBIAR**| valor de JWT_SECRET  |
| `ADMIN_USER`| Usuario administrador inicial                        | `admin`              |
| `ADMIN_PASS`| Contraseña administrador inicial — **CAMBIAR**       | `admin1234`          |

> **Importante:** `JWT_SECRET` y `ADMIN_PASS` deben cambiarse antes de cualquier despliegue en producción.  
> `API_TOKEN` debe coincidir con el valor configurado en cada agente bash.

---

## API

### `POST /api/inventario`

Recibe el inventario de un equipo. Requiere header `X-Api-Token`.

```bash
curl -X POST http://IP:3900/api/inventario \
  -H "Content-Type: application/json" \
  -H "X-Api-Token: TU_API_TOKEN" \
  -d '{"cid":"abc123","name":"fpb1-01", ...}'
```

### `GET /api/export/csv`

Descarga el inventario completo en formato TSV (Tab-Separated Values), compatible con LibreOffice Calc y Excel.

```bash
curl -H "X-Api-Token: TU_API_TOKEN" \
  http://IP:3900/api/export/csv -o inventario.tsv
```

---

## Campos registrados por el agente

| Campo            | Fuente                              |
|------------------|-------------------------------------|
| CID              | `migasfree-cid` o hash de MAC       |
| Estado           | `Activo` al reportar                |
| Versión SO       | `/etc/vitalinux-release`            |
| Arquitectura     | `uname` + `/proc/cpuinfo`           |
| Nombre equipo    | `hostname`                          |
| Número de serie  | `dmidecode`                         |
| Última actualiz. | `/var/log/dpkg.log`                 |
| Etiquetas        | Cache Migasfree (`jq` / `python3`)  |
| CPU              | `/proc/cpuinfo`                     |
| RAM (MB)         | `/proc/meminfo`                     |
| Slots RAM        | `dmidecode -t memory`               |
| Disco            | `lsblk` (bytes totales)             |
| Tipo disco       | `/sys/block/*/rotational` + nvme    |
| Modelo           | `dmidecode`                         |
| IP local         | `ip route`                          |
| MACs Ethernet    | `/sys/class/net`                    |
| MAC WiFi         | `/sys/class/net/*/wireless`         |
| Gráfica          | `lspci`                             |
| Dualizado        | `lsblk -f` (detecta NTFS)          |
| Secure Boot      | `mokutil` / EFI vars                |
| IP pública       | `api.ipify.org`                     |

---

## Seguridad

- Autenticación de agentes mediante `X-Api-Token` con comparación **timing-safe** (resistente a ataques de temporización)
- Login web protegido con **rate limiting**: máximo 5 intentos por IP cada 10 minutos
- Cookie de sesión con flags `httpOnly` y `sameSite=strict` (protección CSRF)
- Contraseñas almacenadas con **bcrypt** (10 rondas)
- Tokens JWT firmados con `HS256`, expiración 8 horas
- Validación y sanitización de todos los campos recibidos por la API
- Índices en base de datos para consultas eficientes

---

## Historial de cambios

Cada vez que un equipo reporta datos, el servidor compara el estado anterior y registra en la tabla `historial` qué campos cambiaron y cuándo. El historial (últimas 200 entradas por equipo) es visible en el modal de detalle de cada equipo en el dashboard.

---

## Licencia

MIT — libre para uso educativo y adaptación.
