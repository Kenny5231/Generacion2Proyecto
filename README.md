# Gitea privado autogestionado

Servidor Git privado (tipo "GitHub privado") para Ubuntu Server con Docker, accesible solo por VPN
(Tailscale). Todo el proyecto se prepara en Windows y se instala después en el servidor con pocos comandos.

> **Primera vez:** abra [docs/INSTALACION-MANANA.md](docs/INSTALACION-MANANA.md) y siga las fases en orden.
> El resumen de lo entregado está en [ENTREGA.md](ENTREGA.md).

## Descripción

Despliega **Gitea oficial (imagen rootless, versión fija)** con **SQLite**, datos persistentes en el disco del servidor,
interfaz web por **HTTPS privado (Tailscale Serve)** y operaciones Git por **SSH con claves Ed25519**.
No depende de GitHub ni de servicios en la nube y no interfiere con otros proyectos Docker del servidor.

## Características

- Repositorios privados obligatorios; no se permiten repositorios públicos; registro abierto deshabilitado; inicio de sesión obligatorio.
- `git clone`, `git push` y `git pull` desde Windows por SSH (alias `git-privado`).
- Administración web, usuarios adicionales, ramas, etiquetas e historial.
- Datos en `./data` y `./config` (bind mounts): sobreviven a reinicios y a reemplazos del contenedor.
- Copias de seguridad consistentes con verificación SHA-256 y restauración controlada.
- Actualizaciones manuales y explícitas (sin versión `latest`, sin saltos automáticos).
- Scripts idempotentes con comprobaciones previas (`preflight`) y pruebas (`smoke-test`, `test-static`).
- Aislamiento: proyecto Compose propio (`gitea-privado`), red propia, sin socket Docker, sin modo privilegiado.

## Requisitos

| Componente | Requisito |
|---|---|
| Servidor | Ubuntu Server con Docker Engine y Docker Compose V2 (`docker compose`) |
| Red privada | Tailscale instalado y conectado, con **MagicDNS** y **certificados HTTPS** habilitados |
| Usuario | Un usuario con acceso a Docker (grupo `docker`) y `sudo` (solo para crear `/srv/...`) |
| Herramientas | `curl`, `tar`, `gzip`, `sha256sum`, `flock`, `awk`, `sed`, `ss` (el preflight lo verifica) |
| Windows | Git, Cliente OpenSSH, PowerShell |
| Espacio | Recomendado 5 GiB libres como mínimo, más el crecimiento de sus repositorios y los respaldos |

## Arquitectura

```
Windows (Git + OpenSSH) ──VPN Tailscale──►  Ubuntu
                                              ├─ tailscale serve (HTTPS 443) ─► 127.0.0.1:3090 ─► Gitea :3000 (web)
                                             └─ tailscale serve (TCP 2222)  ─► 127.0.0.1:2222 ─► Gitea :2222 (SSH Git)
Contenedor: docker.gitea.com/gitea:<versión>-rootless, usuario 1000:1000, SQLite
Datos:      /srv/gitea-privado/data  →  /var/lib/gitea      /srv/gitea-privado/config  →  /etc/gitea
Respaldos:  /srv/backups/gitea-privado/
```

Detalles y decisiones en [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md).

## Preparación

1. **Windows (PowerShell):** transfiera el proyecto al servidor (pide host, usuario y puerto SSH de administración):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\windows\upload-project.ps1
   ```

2. **Ubuntu (Bash):** revise el servidor y genere la configuración:

   ```bash
   cd ~/gitea-privado-staging
   ./scripts/preflight.sh      # solo lectura: informa OK / ADVERTENCIA / ERROR
   ./scripts/configure.sh      # crea .env (permisos 600) con la IP y el DNS reales de Tailscale
   ```

   Si Tailscale no está configurado, `configure.sh` muestra el procedimiento oficial; nunca lo conecta por usted.

   Las variables clave que genera `configure.sh` en `.env` y que controlan los puertos son:

   | Variable | Descripción | Valor predeterminado |
   |---|---|---|
   | `GITEA_WEB_PORT` | Puerto local del proxy web (127.0.0.1) hacia Gitea :3000 | `3090` |
   | `GITEA_SSH_LOCAL_PORT` | Puerto local (127.0.0.1) donde Docker expone el SSH de Gitea | `2222` |
   | `GITEA_SSH_PORT` | Puerto Tailscale Serve TCP que anuncia el SSH Git en la tailnet | `2222` |
   | `GITEA_TS_HTTPS_PORT` | Puerto HTTPS que Tailscale Serve publica en la tailnet | `443` |

   > **`GITEA_TAILSCALE_IP` está obsoleta.** Versiones anteriores requerían fijar la IP de Tailscale en `.env`
   > para publicar el puerto SSH. La arquitectura actual usa Tailscale Serve TCP (`127.0.0.1`) y no depende de esa variable.
   > Si su `.env` la contiene, puede ignorarla; los scripts no la usan.

## Instalación

```bash
./scripts/install.sh                      # crea /srv/gitea-privado, descarga la imagen e inicia Gitea
/srv/gitea-privado/scripts/configure-tailscale.sh   # publica el HTTPS privado (Tailscale Serve)
```

Después complete el asistente inicial y cree su cuenta de administrador (una sola vez, por un túnel SSH privado):
vea las Fases 5 y 6 de [docs/INSTALACION-MANANA.md](docs/INSTALACION-MANANA.md).
`install.sh` puede repetirse sin riesgo: no sobrescribe datos, `.env` ni reinicia servicios sin su autorización.

Desde Windows: `windows\setup-git.ps1` crea su clave Ed25519 y el alias SSH `git-privado`
(guía en [docs/COMANDOS-GIT.md](docs/COMANDOS-GIT.md)).

## Uso cotidiano

Todos los comandos actúan **solo** sobre el proyecto Compose `gitea-privado` (`-p gitea-privado`).
Ejecute en el servidor, con `D=/srv/gitea-privado`:

| Acción | Comando |
|---|---|
| Iniciar | `docker compose -p gitea-privado -f $D/compose.yaml up -d gitea` |
| Detener | `docker compose -p gitea-privado -f $D/compose.yaml stop gitea` |
| Reiniciar | `docker compose -p gitea-privado -f $D/compose.yaml restart gitea` |
| Ver logs | `docker compose -p gitea-privado -f $D/compose.yaml logs -f --tail 100 gitea` |
| Recursos | `docker stats --no-stream gitea-privado` |
| Estado completo | `$D/scripts/status.sh` |
| Verificar conexión | `$D/scripts/smoke-test.sh` (y `ssh -T git-privado` desde Windows) |
| Backup | `$D/scripts/backup.sh` |
| Restaurar | `$D/scripts/restore.sh /srv/backups/gitea-privado/<archivo>.tar.gz` |
| Actualizar con seguridad | `$D/scripts/update.sh --version X.Y.Z` (hace backup previo; vea [docs/BACKUPS.md](docs/BACKUPS.md)) |

Nunca use `docker compose down -v`, `docker volume prune` ni `docker system prune` en este servidor.

## Seguridad

- Gitea rootless, `no-new-privileges`, `cap_drop: ALL`, sin `privileged`, sin socket Docker, sin runners.
- Web solo en `127.0.0.1`; SSH Git publicado solo en `127.0.0.1` y expuesto en la tailnet a través de Tailscale Serve (nunca en `0.0.0.0`).
- HTTPS solo dentro de la tailnet (Tailscale Serve; **no** Funnel). No se abren puertos en el router ni en el firewall.
- Sin contraseñas en el repositorio: la cuenta de administrador se crea en el navegador durante el asistente inicial.
- Active la autenticación de dos factores en Gitea y en Tailscale. Lea [docs/SEGURIDAD.md](docs/SEGURIDAD.md) (amenazas y límites reales).

## Backups

`scripts/backup.sh` detiene solo Gitea, empaqueta `data/` y `config/` (base de datos, repositorios, claves, configuración),
reinicia Gitea aunque falle, y genera `.tar.gz` + `.sha256` en `/srv/backups/gitea-privado/`.
No borra respaldos antiguos: defina su propia política y guarde copias cifradas fuera del servidor.
Detalles, restauración y prueba en un entorno separado en [docs/BACKUPS.md](docs/BACKUPS.md).

## Solución de errores

Consulte [docs/SOLUCION-PROBLEMAS.md](docs/SOLUCION-PROBLEMAS.md). Primeros pasos: `scripts/status.sh`, los registros
(`logs --tail 100 gitea`) y `scripts/preflight.sh`.

## Estructura

```
compose.yaml  .env.example  .gitignore  .gitattributes  README.md  ENTREGA.md  REVISION-SEGURIDAD.md
scripts/   common.sh preflight.sh configure.sh install.sh configure-tailscale.sh status.sh backup.sh restore.sh update.sh smoke-test.sh
windows/   setup-git.ps1 upload-project.ps1
docs/      INSTALACION-MANANA.md ARQUITECTURA.md SEGURIDAD.md BACKUPS.md COMANDOS-GIT.md SOLUCION-PROBLEMAS.md
tests/     test-static.sh test-lifecycle.sh
```

Pruebas locales (sin servidor): `bash tests/test-static.sh`.
