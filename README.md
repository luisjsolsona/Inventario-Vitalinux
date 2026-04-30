# Inventario Vitalinux

Sistema de inventario hardware centralizado para institutos con equipos Vitalinux. Los equipos cliente recopilan sus datos automáticamente al arranque y los envían al servidor. El administrador visualiza y gestiona el inventario completo desde un dashboard web.

## Funcionalidad principal

La plataforma permite a los técnicos de sistemas llevar un inventario actualizado de todos los equipos del centro sin intervención manual. Un agente Bash ligero, instalado una vez en cada equipo, recoge 21 campos de hardware —CPU, RAM, disco, red, Secure Boot, etiquetas Migasfree, etc.— y los envía al servidor en cada arranque y diariamente a las 08:05. El servidor registra el historial de cambios campo a campo, permitiendo detectar cuándo cambió cualquier dato de un equipo.

## Características principales

**Para el técnico / administrador:**
- Dashboard web con búsqueda, filtros por versión y tipo de disco, y modal de detalle por equipo
- Historial de cambios por equipo — detecta automáticamente qué campos han variado y cuándo
- Exportación del inventario completo en TSV compatible con LibreOffice Calc y Excel
- Eliminación de equipos con borrado en cascada del historial
- Estadísticas globales: total de equipos, distribución de versiones y tipos de disco

**Para el agente en los equipos:**
- Instalación en un solo comando, sin dependencias adicionales en el cliente
- Recogida automática de serial, modelo, CPU, RAM, slots de memoria, disco, tipo de disco, MACs ethernet y WiFi, gráfica, IP local, IP pública, Secure Boot y estado de dualizado
- Integración nativa con Migasfree — usa `migasfree-cid` como identificador y recoge etiquetas del cliente
- Fallback automático al hash de MAC si Migasfree no está disponible

## Implementación técnica

La aplicación usa un diseño cliente-servidor: agente Bash en los equipos Vitalinux, servidor Express con base de datos SQLite y frontend HTML/CSS/JS vanilla. La autenticación se gestiona con JWT almacenado en cookie httpOnly con flag sameSite. El token de los agentes se compara con comparación timing-safe para evitar ataques de temporización. El login web incluye rate limiting de 5 intentos por IP cada 10 minutos. El sistema corre en Docker y es compatible con CasaOS, Linux, Windows y macOS.

## Quick Start

Requiere Docker y Docker Compose. Antes de levantar el servicio, editar `JWT_SECRET`, `API_TOKEN` y `ADMIN_PASS` en `docker-compose.yml`:

```bash
git clone https://github.com/luisjsolsona/Inventario-Vitalinux.git
cd Inventario-Vitalinux
docker compose up -d --build
```

Acceder en `http://localhost:3900` con las credenciales configuradas en `docker-compose.yml`.

Para instalar el agente en un equipo Vitalinux, editar `SERVER_URL` y `API_TOKEN` en `agent/inventario-agente.sh` y ejecutar:

```bash
sudo ./instalar-agente.sh
```
