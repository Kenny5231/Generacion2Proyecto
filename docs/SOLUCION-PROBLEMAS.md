# Solución de problemas

Primero reúna información (🐧 Bash en el servidor):

```bash
/srv/gitea-privado/scripts/status.sh
docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml logs --tail 100 gitea
/srv/gitea-privado/scripts/preflight.sh
```

## Instalación y arranque

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `preflight`: `[ERROR] Sin permisos para usar Docker` | Su usuario no está en el grupo `docker` | `sudo usermod -aG docker $USER`, cierre sesión y vuelva a entrar |
| `[ERROR] Tailscale no está conectado` | Tailscale caído o sin autenticar | `tailscale status`; conéctelo usted con `sudo tailscale up` (el proyecto nunca lo hace) |
| `No se obtuvo un nombre DNS .ts.net` | MagicDNS desactivado | Actívelo en <https://login.tailscale.com/admin/dns> |
| `[ERROR] Puerto web 3090 ocupado` / `Puerto SSH 2222 ocupado` | Otro servicio o contenedor usa ese puerto | `ss -ltnp \| grep -E ':3090\|:2222'`; elija otros: `./scripts/configure.sh --regenerate --web-port 3091 --ssh-port 2223`. No detenga contenedores ajenos |
| `required variable GITEA_VERSION is missing` / `GITEA_TS_DNS is missing` | `.env` ausente o incompleto | `./scripts/configure.sh` (o `--regenerate`) |
| `.env: clave no permitida` / `línea inválida` | `.env` editado con comillas, espacios o `$` | Use `CLAVE=valor` sin comillas; o regenere con `configure.sh --regenerate` |
| El contenedor se reinicia en bucle (`Restarting`) | Permisos de `data`/`config` o configuración inválida | Ver logs; `sudo chown -R 1000:1000 /srv/gitea-privado/data /srv/gitea-privado/config`; luego `install.sh` |
| `mkdir: can't create directory '/var/lib/gitea/git': Permission denied` | `data/` no pertenece al UID 1000 | `sudo chown -R 1000:1000 /srv/gitea-privado/data /srv/gitea-privado/config` |
| El contenedor falla al iniciar o los puertos no responden | Revise el estado, los puertos locales enlazados a `127.0.0.1` y los logs. Docker no depende de la IP Tailscale | `docker port gitea-privado` (esperado: `127.0.0.1:3090` y `127.0.0.1:2222`); revise `status.sh`, `preflight.sh` y los logs. El acceso remoto entra por Tailscale Serve |
| El contenedor falla por `cap_drop: ALL` (error de permisos al iniciar, algo improbable) | Capacidad requerida por la imagen | Quite las 2 líneas `cap_drop` de `compose.yaml`, ejecute `install.sh` y avise (es la única opción no verificada con el servidor real) |
| `bad interpreter` / `^M` al ejecutar scripts | Finales de línea de Windows | `sed -i 's/\r$//' scripts/*.sh` y `chmod +x scripts/*.sh` |
| `Permission denied` al ejecutar `./scripts/preflight.sh` | La transferencia ZIP no conserva permisos Unix | `chmod +x scripts/*.sh` y luego `./scripts/preflight.sh`; también puede invocarlo como `bash scripts/preflight.sh` |
| El asistente de instalación aparece otra vez | No se completó (`INSTALL_LOCK` no es `true`) | Complete el asistente (Fase 7) y compruebe `sudo grep INSTALL_LOCK /srv/gitea-privado/config/app.ini` |

## Tailscale Serve / HTTPS

| Síntoma | Qué hacer |
|---|---|
| `configure-tailscale.sh`: el puerto 443 ya está en uso | El script no cambia nada. Use `--https-port 8443` (o 10000) o libere el puerto manualmente si ya no lo necesita (`sudo tailscale serve --https=443 off`; el script nunca ejecuta `off` ni `reset`) |
| Pide habilitar HTTPS o certificados | Active **HTTPS Certificates** en <https://login.tailscale.com/admin/dns> y repita |
| `tailscale serve` pide permisos | Use `sudo`, o una vez: `sudo tailscale set --operator=$USER` |
| SSH Git remoto no conecta | Docker publica SSH solo en `127.0.0.1`; debe existir el reenvío TCP de Tailscale Serve | Revise `tailscale serve status`, `scripts/status.sh` y que SSH local responda en `127.0.0.1:2222`. No publique el puerto Docker en la IP Tailscale |
| El navegador no abre `https://<equipo>.<tailnet>.ts.net/` | Tailscale activo en ese equipo; MagicDNS activo; `tailscale serve status` en el servidor; revise las ACL de la tailnet |
| Gitea redirige a una URL incorrecta o los enlaces de clonado son erróneos | `GITEA_ROOT_URL` de `.env` no coincide con la URL real (incluye puerto si no es 443). Corrija con `configure.sh --regenerate` y `docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml up -d gitea` |
| Ver o quitar la publicación | `tailscale serve status` · `sudo tailscale serve --https=443 off` (solo esa entrada) |

## SSH y Git

| Síntoma | Qué hacer |
|---|---|
| `Permission denied (publickey)` | La clave pública no está registrada en **su usuario** de Gitea; o SSH ofrece otra clave. Pruebe `ssh -vT git-privado` y confirme `IdentityFile` en `~/.ssh/config` |
| `Connection timed out` / `refused` | Tailscale desconectado en Windows o en el servidor; puerto/IP distintos. Pruebe `Test-NetConnection <equipo>.<tailnet>.ts.net -Port 2222` y `smoke-test.sh` (banner SSH) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | No lo ignore: verifique la huella (ver [COMANDOS-GIT.md](COMANDOS-GIT.md)) antes de `ssh-keygen -R "[<host>]:2222"` |
| `Could not resolve hostname` | MagicDNS no activo en Windows (Tailscale conectado y "Use Tailscale DNS settings") |
| Pide la frase de contraseña en cada operación | Cargue la clave en `ssh-agent` (ver [COMANDOS-GIT.md](COMANDOS-GIT.md)) |
| El `push` falla con `src refspec main does not match any` | Aún no hay commits; haga `git add` y `git commit` antes, o use `git push -u origin HEAD` |
| `fatal: Could not read from remote repository` tras mover el servidor | La IP/DNS/puerto cambiaron: `ssh-keygen -R`, actualice `HostName`/`Port` en `~/.ssh/config` (re-ejecute `setup-git.ps1`) |
| `setup-git.ps1`: "alias ya definido fuera del bloque" | Use otro `-Alias` o elimine su definición manual en `~/.ssh/config` |

## Respaldos y actualizaciones

| Síntoma | Qué hacer |
|---|---|
| `backup.sh`: `Espacio insuficiente` | Libere espacio o use `--dir` hacia otro disco |
| `Hay otro respaldo o restauración en curso` | Espere; si el proceso ya no existe, el bloqueo se libera solo (es un `flock`) |
| Tras un fallo de `backup.sh` Gitea no vuelve a responder | `docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml start gitea` (el script ya lo intenta siempre) |
| `restore.sh`: `El SHA-256 NO coincide` | El archivo está dañado o se alteró: no lo use; recupere otra copia |
| `restore.sh`: versiones difieren | Lea el mensaje; use `--use-backup-version` si quiere fijar la versión del respaldo |
| `update.sh` falla o Gitea no responde tras actualizar | Siga el "Procedimiento de recuperación" que imprime: `restore.sh --use-backup-version <respaldo previo>`. No cambie la versión hacia atrás sin restaurar |
| Olvidó la contraseña de administrador | Con acceso al servidor: `docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml exec gitea gitea -c /etc/gitea/app.ini admin user change-password --username <usuario> --password '<TEMPORAL>'` (consulte `... admin user change-password --help` en su versión). **Aviso:** la contraseña temporal queda visible un instante en la lista de procesos del servidor; cámbiela de inmediato en la web |

## Comprobaciones útiles

```bash
docker ps --filter name=gitea-privado
docker inspect -f '{{.State.Health.Status}}' gitea-privado
docker stats --no-stream gitea-privado
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3090/api/healthz
sudo ls -l /srv/gitea-privado/data /srv/gitea-privado/config
```

## Qué NO hacer

`docker compose down -v`, `docker volume prune`, `docker system prune`, borrar `data/` o `config/`, ejecutar `chmod 777`, desactivar
la verificación de huellas SSH o abrir los puertos en el router/firewall. Ante la duda, haga primero `scripts/backup.sh`.
