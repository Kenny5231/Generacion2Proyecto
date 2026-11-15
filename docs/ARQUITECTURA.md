# Arquitectura

## Componentes

| Capa | Elección | Motivo |
|---|---|---|
| Plataforma Git | Gitea oficial, imagen `docker.gitea.com/gitea:28.3.0-rootless` | Ligera, con interfaz web, usuarios y SSH integrado |
| Contenedores | Docker Engine + Compose V2, proyecto `gitea-privado` | Aislado de los demás proyectos del servidor |
| Base de datos | SQLite3 (`/var/lib/gitea/data/gitea.db`) | Suficiente para uso personal/equipo pequeño; simplifica respaldos |
| Acceso remoto | Tailscale (VPN WireGuard) | Sin abrir puertos en el router; identidad por dispositivo |
| Publicación en la tailnet | Tailscale Serve (`scripts/configure-tailscale.sh`): HTTPS y TCP | Certificado válido sin Nginx/Traefik; sin Funnel |
| Web | Serve HTTPS (`GITEA_TS_HTTPS_PORT`) → `http://127.0.0.1:3090` → contenedor `:3000` | Docker solo publica en `127.0.0.1` |
| Git | Serve TCP (`GITEA_SSH_PORT`) → `tcp://127.0.0.1:2222` → SSH integrado del contenedor `:2222` | No toca el SSH del sistema operativo (puerto 22) |
| Persistencia | Bind mounts `./data` y `./config` bajo `/srv/gitea-privado` | Visibles en disco y fáciles de respaldar |
| Automatización | Bash (`scripts/`), Python 3 (`scripts/tsjson.py`) y PowerShell (`windows/`) | Sin dependencias adicionales |

## Diagrama

```
 Windows ── Tailscale (tailnet) ──► [ Ubuntu ]
   │                                  │
   │ HTTPS 443  (GITEA_TS_HTTPS_PORT) ├─ tailscaled (Serve) ─ HTTPS 443 ─► http://127.0.0.1:3090 ──┐
   │ SSH   2222 (GITEA_SSH_PORT)      │                     └ TCP   2222 ─► tcp://127.0.0.1:2222 ─┤
   └──────────────────────────────────┘                                                           ▼
                                                      Docker: 127.0.0.1:3090->3000 y 127.0.0.1:2222->2222
                                                      contenedor gitea-privado
                                                      ├─ :3000 web
                                                      ├─ :2222 SSH Git (siempre 2222 dentro del contenedor)
                                                      ├─ /var/lib/gitea ◄── /srv/gitea-privado/data
                                                      └─ /etc/gitea     ◄── /srv/gitea-privado/config
```

Ningún puerto de Docker queda en una interfaz externa. La tailnet solo llega a Gitea a través de Tailscale Serve,
y quién puede llegar a Serve lo decide la política (ACL/grants) de su tailnet (ver [SEGURIDAD.md](SEGURIDAD.md)).

## Redes y puertos

Hay **cuatro puertos**, todos configurables en `.env` (valores por defecto entre paréntesis) para evitar choques con otros servicios:

| Variable | Dónde escucha | Uso |
|---|---|---|
| `GITEA_WEB_PORT` (3090) | `127.0.0.1` del servidor (Docker `->3000`) | Web de Gitea; solo local y a través de Tailscale Serve |
| `GITEA_SSH_LOCAL_PORT` (2222) | `127.0.0.1` del servidor (Docker `->2222`) | SSH de Git local (no es el SSH de administración) |
| `GITEA_SSH_PORT` (2222) | Tailnet, por Tailscale Serve (TCP) | Puerto SSH que ven los clientes; es el que Gitea anuncia en las URL de clonado: `ssh://git@<DNS>.ts.net:<GITEA_SSH_PORT>/<usuario>/<repo>.git` |
| `GITEA_TS_HTTPS_PORT` (443) | Tailnet, por Tailscale Serve (HTTPS) | HTTPS privado; solo 443, 8443 o 10000 (límite de Tailscale Serve) |

El contenedor usa una red `bridge` propia (`gitea-privado_gitea-net`); no comparte redes con otros proyectos.

**Arranque independiente de Tailscale.** Docker ya no usa la IP de Tailscale (la variable `GITEA_TAILSCALE_IP` es obsoleta: los `.env`
heredados la aceptan pero se ignora, y `configure.sh --regenerate` la elimina como parte de la migración). Por eso el contenedor arranca tras un
reinicio de Ubuntu aunque Tailscale todavía no tenga IP; la configuración de Serve la conserva `tailscaled` (verifique con
`tailscale serve status` tras reiniciar el servidor).

## Tailscale Serve (`configure-tailscale.sh`)

Publica dos servicios, solo dentro de la tailnet:

```
HTTPS  <DNS>.ts.net:<GITEA_TS_HTTPS_PORT>  →  http://127.0.0.1:<GITEA_WEB_PORT>
TCP    <DNS>.ts.net:<GITEA_SSH_PORT>       →  tcp://127.0.0.1:<GITEA_SSH_LOCAL_PORT>     (p. ej. tailscale serve --bg --tcp=2222 tcp://127.0.0.1:2222)
```

- Exige Tailscale 1.52 o posterior (`serve --tcp`) y Python 3.
- Lee `tailscale serve status --json` con `scripts/tsjson.py` y clasifica cada servicio como `free` (libre), `ours` (ya es de Gitea) o `foreign`
  (de otro uso). Nunca ejecuta `serve reset` ni `off`, nunca usa Funnel y no pisa servicios ajenos.
- Es repetible: lo ya configurado no se vuelve a tocar. `scripts/configure-tailscale.sh --dry-run` solo muestra qué haría.
- Si el primer servicio queda configurado y el segundo falla, informa **ESTADO PARCIAL** (código de salida 2) y no elimina nada; repetirlo completa lo que falte.
- Se niega a publicar si el asistente de instalación de Gitea no está completado (`INSTALL_LOCK`), salvo `--allow-unfinished-installer` (no recomendado).
- Para revertir **solo** lo de Gitea (con los puertos por defecto): `sudo tailscale serve --https=443 off` y `sudo tailscale serve --tcp=2222 off`.

## Estructura en el servidor

```
/srv/gitea-privado/        compose.yaml  .env (600)  scripts/  docs/  windows/  tests/
├── data/                  → /var/lib/gitea   (repositorios, SQLite, adjuntos, LFS; claves SSH del servidor Git en data/data/ssh/)
└── config/                → /etc/gitea       (app.ini con claves internas)
/srv/backups/gitea-privado/  *.tar.gz  *.tar.gz.sha256  (permisos 600/700)
```

Propiedad: `data/` y `config/` pertenecen al UID/GID 1000 (usuario `git` del contenedor rootless); el resto, a su usuario.
Las claves del servidor Git están en `/srv/gitea-privado/data/data/ssh/` (por ejemplo `gitea.ed25519.pub`), no en `data/ssh/`.

## Decisiones técnicas y compatibilidad

- **Versión fija en `.env` (`GITEA_VERSION`)**; el sufijo `-rootless` está fijo en `compose.yaml`. Las imágenes rootless y rootful no son intercambiables.
  La etiqueta `28.3.0-rootless` existe en Docker Hub (verificada al preparar el proyecto).
- **SSH integrado** (`START_SSH_SERVER=true`): obligatorio en rootless; escucha siempre en `:2222` dentro del contenedor (`SSH_LISTEN_PORT=2222`);
  `SSH_PORT` = `GITEA_SSH_PORT` es solo el puerto que Gitea anuncia en las URL de clonado (el que ofrece Tailscale Serve).
- **Variables `GITEA__seccion__CLAVE`**: la imagen las aplica a `app.ini` en cada arranque. Por eso **no** se define `INSTALL_LOCK`:
  el asistente de primera instalación lo escribe como `true` en `app.ini` y una variable lo revertiría en cada reinicio.
- **Zona horaria con `TZ`** (no se montan `/etc/timezone` ni `/etc/localtime`: pueden no existir y Docker crearía carpetas).
- **`cap_drop: ALL`** y `no-new-privileges`: el proceso no necesita capacidades (usuario no root, puertos > 1024).
  *Verificar en el servidor en la primera ejecución* (ver [SOLUCION-PROBLEMAS.md](SOLUCION-PROBLEMAS.md)).
- **Respaldo en frío** de `data/` + `config/` con Gitea detenido: es el método que Gitea recomienda para consistencia (SQLite + repositorios)
  y evita depender del comando `gitea dump`. `backup.sh` comprueba `PRAGMA integrity_check` antes de empaquetar; `restore.sh` verifica el archivo,
  renombra (nunca borra) lo anterior, comprueba el resultado y revierte si algo falla (ver [BACKUPS.md](BACKUPS.md)).
- **Actualizaciones controladas**: `update.sh` solo acepta versiones `X.Y.Z` de la imagen rootless (nunca `latest`), hace un respaldo previo y comprueba
  healthcheck, versión en ejecución, integridad de SQLite y esquema de la base de datos.
- **Sin dependencias extra**: nada de Nginx/Traefik/PostgreSQL/Kubernetes; Tailscale Serve termina el TLS.

## Flujo de scripts

`preflight.sh` (lee) → `configure.sh` (genera `.env`) → `install.sh` (prepara y arranca; solo `127.0.0.1`) →
**asistente de Gitea por túnel SSH administrativo** → `configure-tailscale.sh` (publica HTTPS y SSH en la tailnet) → `smoke-test.sh` / `status.sh`.
Operación: `backup.sh`, `restore.sh`, `update.sh`. Todo comparte `common.sh` y actúa siempre con
`docker compose -p gitea-privado -f <instalación>/compose.yaml`.

### Primer arranque seguro

El asistente de instalación se completa **antes** de publicar en la tailnet, por un túnel SSH administrativo (el SSH de Ubuntu, distinto del SSH de Gitea):

```bash
ssh -L 3090:127.0.0.1:3090 <USUARIO_ADMIN>@<HOST_ADMIN_DEL_SERVIDOR>     # y abra http://localhost:3090
```

Así nadie más de la tailnet puede crear la cuenta administradora. Al terminar, el navegador puede redirigir a la URL `https://` (aún no publicada): es normal.
Después se ejecuta `scripts/configure-tailscale.sh`.

### Estados que informan `status.sh` y `smoke-test.sh`

Por etapas: contenedor, healthcheck de Docker, web local, puertos solo en `127.0.0.1`, SSH local, asistente/administrador, HTTPS y SSH de Serve,
ausencia de Funnel, backup verificado. Dos etapas **no se pueden comprobar automáticamente** y se muestran como NO VERIFICADO: la operación Git
(clone/push/pull desde Windows) y la restauración probada en un entorno separado; son pruebas manuales.
