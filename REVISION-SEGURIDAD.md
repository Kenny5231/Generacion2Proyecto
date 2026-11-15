# Revisión de seguridad

Revisión interna de las medidas de seguridad implementadas en el proyecto **Gitea privado autogestionado**.
No es una auditoría externa. Las comprobaciones estáticas y de ciclo de vida se ejecutan con `tests/test-static.sh`
y `tests/test-lifecycle.sh`; la verificación real contra el servidor Ubuntu es manual (ver `docs/SEGURIDAD.md`).

## Tabla de riesgos y medidas implementadas

| Riesgo | Archivo afectado | Medida implementada | Método de verificación | Riesgo residual |
|---|---|---|---|---|
| Proceso Gitea con privilegios de root | `compose.yaml` | Imagen rootless (usuario 1000:1000), `no-new-privileges`, `cap_drop: ALL`, sin `privileged` | `docker inspect gitea-privado` → `User: 1000:1000`; `CapDrop: ALL` | Bajo; demonio Docker sigue siendo root |
| Puertos de Gitea expuestos en interfaces públicas | `compose.yaml` | Web y SSH publicados solo en `127.0.0.1`; nunca en `0.0.0.0` ni en la IP pública | `docker port gitea-privado`; `ss -ltn` → solo `127.0.0.1` | Bajo; requiere que Docker no tenga reglas iptables externas |
| Acceso a Gitea desde Internet | `configure-tailscale.sh`, `tsjson.py` | HTTPS y SSH Git expuestos solo en la tailnet por Tailscale Serve (sin Funnel); sin apertura de puertos en el router | `tailscale serve status` → sin Funnel; `Test-NetConnection` desde red externa | Medio; depende de la ACL/política de la tailnet y de Tailscale Inc. |
| Repositorios o datos públicos | `compose.yaml` | `FORCE_PRIVATE=true`, registro abierto deshabilitado, inicio de sesión obligatorio | Acceso web sin sesión → redirige a login | Bajo |
| Ejecución de código arbitrario en el servidor vía hooks o Actions | `compose.yaml` | Actions desactivado (`DISABLE_REGISTRATION` y `DISABLE_GIT_HOOKS`), sin runners | `docker inspect` → variables de entorno sin runners; prueba estática | Bajo |
| Administrador creado antes de publicar (asistente expuesto) | `configure-tailscale.sh` | El script se niega a publicar si `INSTALL_LOCK` no es `true` en `config/app.ini`; el asistente se completa por túnel SSH | `configure-tailscale.sh` verifica `INSTALL_LOCK`; `smoke-test.sh` | Bajo si se sigue el procedimiento |
| Claves SSH débiles o compartidas entre equipos | `windows/setup-git.ps1` | Acceso Git solo con claves Ed25519; clave exclusiva por equipo Windows | `ssh-keygen -l -f ~/.ssh/gitea_ed25519` → tipo Ed25519 | Bajo; depende de que el usuario use frase de contraseña |
| Secretos en el repositorio o en variables de entorno visibles | `common.sh`, `.gitignore` | `.env` con permisos 600, parser estricto sin `source`, excluido de Git | `git ls-files .env` → vacío; `stat -c %a .env` → `600` | Bajo |
| Socket Docker o red de host expuesta al contenedor | `compose.yaml` | Sin socket Docker, sin `privileged`, sin `network_mode: host`, red propia del proyecto | `docker inspect` → `HostConfig.Binds` sin socket; red `gitea-privado_default` | Bajo |
| Aceptación silenciosa de huella SSH falsa | `windows/*.ps1` | Verificación de huella activa; nunca `StrictHostKeyChecking no`; `-ExpectedFingerprint` para comparación automática | Revisión de `~/.ssh/config`; `ssh -vT git-privado` | Bajo si el usuario verifica la huella la primera vez |
| Respaldo corrupto, inconsistente o manipulado | `backup.sh`, `restore.sh` | Respaldo en frío, SHA-256, comprobación `gzip -t` y `tar -t`, bloqueo `flock`, permisos 600/700, restauración con rollback automático | `sha256sum -c *.sha256`; `test-lifecycle.sh` | Bajo para corrupción accidental; medio si el atacante controla el disco |
| Rutas maliciosas (*path traversal*) en un respaldo | `restore.sh` | Verificación de rutas del `tar` contra `..`, rutas absolutas, enlaces simbólicos y archivos especiales antes de extraer | `test-lifecycle.sh` prueba rutas maliciosas | Bajo |
| Logs con datos sensibles o rutas HTTP | `compose.yaml` | Logs solo a consola (`LOG_MODE=console`), sin registro de accesos HTTP (`ENABLE_ACCESS_LOG=false`) | `docker logs gitea-privado` → sin URLs ni datos de sesión | Bajo |
| Cambios globales al sistema (firewall, Docker, Tailscale) | Todos los scripts | Ningún script modifica iptables, el demonio Docker ni la ACL/configuración de Tailscale existente | Revisión de código; `test-static.sh` | Bajo |
| Actualización accidental a versión desconocida o `latest` | `update.sh` | Solo versión fija `X.Y.Z`; sin `latest`; backup previo obligatorio | `test-static.sh` comprueba que `compose.yaml` no use `latest` | Bajo |
| Claves SSH del servidor Git cambiadas sin aviso | `data/data/ssh/` | Host keys almacenadas en `data/data/ssh/` (ruta de la imagen rootless); se respaldan y restauran juntas | `sudo ssh-keygen -lf /srv/gitea-privado/data/data/ssh/gitea.ed25519.pub` | Bajo si se restaura el respaldo completo |
| Respaldo en el mismo disco que los datos | `backup.sh` | `backup.sh` advierte y comprueba que el destino no esté dentro de `/srv/gitea-privado`; política de retención documentada | `backup.sh` → mensaje de advertencia si el destino está en el mismo sistema de archivos | **Alto** si no se copian los respaldos a un disco o servicio externo |
| Dependencia de servicios externos (Tailscale) | `configure-tailscale.sh` | Tailscale Serve gestiona el transporte; los datos y el contenedor son locales | Documentado en `docs/SEGURIDAD.md` como limitación real | Medio; Tailscale Inc. debe estar operativo para autenticar dispositivos |
| Datos en claro en disco | `/srv/gitea-privado/` | La VPN protege el tránsito, no el almacenamiento; documentado como limitación real | Revisión manual; no hay cifrado de disco en este proyecto | **Medio-Alto** si el servidor es físicamente accesible; se recomienda LUKS |
