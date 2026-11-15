# Entrega: Gitea privado autogestionado

Proyecto preparado **solo localmente** (no se ejecutó nada contra el servidor Ubuntu). Listo para transferir e instalar siguiendo
[docs/INSTALACION-MANANA.md](docs/INSTALACION-MANANA.md).

## 1. Árbol real de archivos

```
gitea-privado/
├── compose.yaml
├── .env.example
├── .gitignore
├── .gitattributes
├── README.md
├── ENTREGA.md
├── scripts/
│   ├── common.sh
│   ├── preflight.sh
│   ├── configure.sh
│   ├── install.sh
│   ├── configure-tailscale.sh
│   ├── status.sh
│   ├── backup.sh
│   ├── restore.sh
│   ├── update.sh
│   └── smoke-test.sh
├── windows/
│   ├── setup-git.ps1
│   └── upload-project.ps1
├── docs/
│   ├── INSTALACION-MANANA.md
│   ├── ARQUITECTURA.md
│   ├── SEGURIDAD.md
│   ├── BACKUPS.md
│   ├── COMANDOS-GIT.md
│   └── SOLUCION-PROBLEMAS.md
└── tests/
    ├── test-static.sh
    └── test-lifecycle.sh        (adicional: prueba local con docker/tailscale simulados)
```

## 2. Arquitectura implementada

- **Gitea oficial rootless** `docker.gitea.com/gitea:28.3.0-rootless` (versión fija en `.env`; sufijo `-rootless` fijo en `compose.yaml`), usuario 1000:1000,
  **SQLite3**, datos en `./data` → `/var/lib/gitea` y `./config` → `/etc/gitea` (bind mounts en `/srv/gitea-privado`).
- Proyecto Compose exclusivo `gitea-privado` con red propia; `restart: unless-stopped`; `no-new-privileges`; `cap_drop: ALL`; sin privileged, sin socket Docker, sin `network_mode: host`.
- **Web** interna `:3000` publicada solo en `127.0.0.1:3090`; **HTTPS privado** con Tailscale Serve (sin Funnel).
- **SSH Git** interno `:2222` publicado solo en `127.0.0.1:2222` y expuesto en la tailnet a través de Tailscale Serve TCP; Docker nunca publica en `0.0.0.0`.
- Gitea configurado por variables `GITEA__seccion__CLAVE`: repos privados forzados, registro deshabilitado, login obligatorio, Actions desactivado,
  URL pública `https://<equipo>.<tailnet>.ts.net/`, dominio y puerto SSH configurables.
- Cuenta de administrador creada por el usuario en el **asistente web** (sin contraseñas en archivos ni argumentos); `INSTALL_LOCK` no se fuerza.
- Respaldo **en frío** consistente (detiene solo Gitea, siempre lo reinicia), SHA-256, restauración con validación y rollback, actualización controlada.

## 3. Scripts y responsabilidades

| Script | Responsabilidad |
|---|---|
| `scripts/common.sh` | Funciones compartidas: mensajes, validadores (IP Tailscale, DNS `.ts.net`, puertos, versiones), parser estricto de `.env`, wrapper `dc` (siempre con `-p gitea-privado`), detección de Tailscale |
| `scripts/preflight.sh` | Análisis de solo lectura del servidor (sistema, dependencias, Docker, Tailscale, puertos, disco, instalación previa, conflictos). OK / ADVERTENCIA / ERROR |
| `scripts/configure.sh` | Genera/valida `.env` (600) con IP y DNS reales de Tailscale; repetible; no modifica Tailscale |
| `scripts/install.sh` | Instalación o repetición segura: carpetas, copia del proyecto, permisos 1000:1000, validación Compose, descarga de imagen, inicio y verificación |
| `scripts/configure-tailscale.sh` | Publica Gitea con `tailscale serve --bg --https=… http://127.0.0.1:…`; detecta conflictos y nunca reemplaza configuraciones existentes |
| `scripts/status.sh` | Estado: contenedor, imagen/versión, puertos, datos, disco, Tailscale, URL, HTTP, huellas SSH, comandos de logs |
| `scripts/backup.sh` | Respaldo consistente `data/`+`config/`+metadatos, `.tar.gz`+`.sha256`, bloqueo, espacio, reinicio garantizado |
| `scripts/restore.sh` | Restauración validada (SHA-256, rutas, versión), confirmación escrita, respaldo previo, datos anteriores renombrados, rollback |
| `scripts/update.sh` | Actualización explícita de versión, backup previo, solo recrea Gitea, instrucciones de recuperación |
| `scripts/smoke-test.sh` | Pruebas en el servidor: Compose, contenedor, web, puertos, montajes, Tailscale, HTTPS, SSH, autenticación (opcional), recreación (opcional) |
| `windows/setup-git.ps1` | Clave Ed25519 exclusiva, bloque `git-privado` en `~/.ssh/config`, prueba de conexión con verificación manual de huella |
| `windows/upload-project.ps1` | Transferencia segura por SCP a `~/gitea-privado-staging` (solo archivos de despliegue, finales de línea LF) |
| `tests/test-static.sh` | Pruebas estáticas locales (sintaxis, ShellCheck, PowerShell, Compose, secretos, comandos peligrosos, validadores) |
| `tests/test-lifecycle.sh` | Prueba local de `configure/install/backup/restore/update` con comandos simulados |

## 4. Cambios finales y verificaciones de esta corrección

| Verificación | Resultado |
|---|---|
| Cambios de esta corrección | `windows/upload-project.ps1`, `tests/test-static.sh`, `docs/INSTALACION-MANANA.md`, `ENTREGA.md` |
| Causas corregidas | Script inexistente en el ejemplo; ruta SSH rootless incorrecta; advertencia ambigua del mismo disco; puerto SSH local duplicado en restauración; docs desactualizados sobre IP Tailscale y fase del asistente; transferencia sin verificar permisos |
| `bash -n scripts/*.sh tests/*.sh` | Pasó; código 0. |
| `tests/test-static.sh` | 205 aprobadas, 0 fallidas, 1 omitida (ShellCheck no disponible); código 0. La verificación precisa de la ruta SSH pasó. |
| `tests/test-lifecycle.sh` | 158 aprobadas, 0 fallidas, 0 omitidas; código 0. Pruebas con Docker/Tailscale simulados. |
| PowerShell | Windows PowerShell analizó ambos `.ps1` sin errores; ambos son ASCII. La cadena remota expandida ejecuta `chmod +x` en ambas carpetas, verifica los archivos requeridos y propaga fallos. El fixture del patrón SSH acepta la ruta rootless y rechaza la ruta antigua. |
| Herramientas | ShellCheck no está disponible. El `docker compose config` dentro de la suite estática y una comprobación directa pasaron; no arrancaron contenedores. No se instalaron herramientas globales. |
| Otros cambios | Mensajes de `upload-project.ps1` en ASCII; recuperación/verificación de `scripts/*.sh` y `tests/*.sh`; fase del túnel corregida y referencias ZIP duplicadas retiradas. |
| Restauración aislada | `docs/BACKUPS.md` usa `GITEA_WEB_PORT=3190`, `GITEA_SSH_LOCAL_PORT=2322`, `GITEA_SSH_PORT=2322`, valida puertos, cambia proyecto/contenedor y rutas, y no habilita Tailscale Serve. |
| ZIP de entrega | `gitea-privado-final.zip`: 28 entradas; contiene los archivos requeridos, sin ZIP anidados ni `.env`, datos, bases de datos, logs, respaldos o claves privadas. |

## 5. Limitaciones pendientes (no verificables sin el servidor)

No se accedió al servidor Ubuntu ni se ejecutaron contenedores Docker reales. El éxito de las pruebas simuladas no sustituye la validación de instalación en Ubuntu.
El primer arranque con `user: 1000:1000`, `cap_drop: ALL` y el healthcheck sigue pendiente de validar en Docker real.
Se verificará en el servidor:

1. Que la imagen arranca con `cap_drop: ALL` y `user: 1000:1000` con los bind mounts (si no, ver SOLUCION-PROBLEMAS.md).
2. Flujo real del asistente de instalación y que `INSTALL_LOCK = true` quede en `config/app.ini`.
3. `tailscale serve --bg --https=443 …` (permisos, HTTPS habilitado en la tailnet) y detección de conflictos con `serve status --json`.
4. Verificación de Tailscale Serve y autenticación SSH real.
5. Rutas de las claves de host SSH de Gitea (`data/data/ssh/*.pub`) mostradas por `status.sh`, y el comando `gitea admin regenerate hooks` tras restaurar. El volumen `./data:/var/lib/gitea` incluye el directorio interno `data/` configurado por Gitea.
6. Respaldo/restauración con datos reales (la lógica se probó con `tar`/SHA-256 reales y Docker simulado).
7. Las pruebas de `smoke-test.sh`, `setup-git.ps1` y `upload-project.ps1` completas (los `.ps1` solo se analizaron sintácticamente; no se ejecutaron para no modificar `~/.ssh` ni conectar a ningún servidor).
8. El healthcheck del contenedor usa `curl` de la imagen; si no estuviera, el contenedor figuraría `unhealthy` sin afectar al servicio (`install.sh` no depende de él).

### Pruebas para cerrar en Ubuntu/WSL

```bash
bash -n scripts/*.sh tests/*.sh
bash tests/test-static.sh
bash tests/test-lifecycle.sh
GITEA_TS_DNS=trial.tail1234.ts.net GITEA_SSH_DOMAIN=trial.tail1234.ts.net GITEA_ROOT_URL=https://trial.tail1234.ts.net/ docker compose --env-file .env.example -f compose.yaml config -q
shellcheck -x -S warning scripts/*.sh tests/*.sh
```

Las 12 fases están en [docs/INSTALACION-MANANA.md](docs/INSTALACION-MANANA.md): diagnóstico, transferencia, preflight, configuración, instalación, túnel SSH administrativo, creación del administrador, Tailscale Serve, configuración Windows, Git extremo a extremo, verificación y backup/restauración aislada. El primer arranque con `user: 1000:1000`, `cap_drop: ALL` y healthcheck sigue pendiente de validar con Docker real.

Si Docker Compose, ShellCheck o PowerShell no están instalados, no instale herramientas globales para esta entrega: valide en un equipo que ya las tenga.

## 6. Cómo transferir el proyecto mañana

🪟 PowerShell, en la carpeta del proyecto (`gitea-privado`):

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\upload-project.ps1
```

Pide host, usuario y puerto SSH **de administración** (no asuma 2222). Verifique la huella SSH la primera vez.
Alternativa manual: `scp -P <PUERTO_SSH_ADMIN> -r .\gitea-privado <USUARIO>@<HOST>:gitea-privado-staging`.

## 7. Primeros comandos en Ubuntu

```bash
cd ~/gitea-privado-staging
chmod +x scripts/*.sh tests/*.sh  # restaura permisos que ZIP/SCP pudo perder
./scripts/preflight.sh         # solo lectura
./scripts/configure.sh         # crea .env con IP/DNS reales de Tailscale
./scripts/install.sh           # instala e inicia Gitea
# Abra el tunel SSH administrativo (Fase 6), cree el administrador (Fase 7)
# y configure Tailscale Serve despues (Fase 8)
/srv/gitea-privado/scripts/configure-tailscale.sh   # solo después del administrador (Fase 8)
```

## 8. Acceso desde Windows

1. Complete primero el asistente por el túnel SSH administrativo de la Fase 6; cree el administrador en la Fase 7 y active 2FA.
2. Configure Tailscale Serve después de crear el administrador (Fase 8) y conecte Windows al mismo tailnet.
3. Abra `https://<equipo>.<tailnet>.ts.net/` e inicie sesión.
4. `powershell -ExecutionPolicy Bypass -File .\windows\setup-git.ps1 -ServerName <equipo>.<tailnet>.ts.net`
5. Registre la clave pública en Gitea, verifique la huella SSH y pruebe `ssh -T git-privado`.

## 9. Crear el primer repositorio privado

En Gitea: **+ → Nuevo repositorio** (siempre privado). Luego:

```powershell
git clone git-privado:<usuario>/prueba-inicial.git
cd prueba-inicial
"Hola" | Out-File -Encoding utf8 prueba.txt
git add prueba.txt ; git commit -m "Primer commit" ; git push -u origin HEAD
```

Compruebe el archivo en la web y clone otra vez en otra carpeta (detalle en [docs/COMANDOS-GIT.md](docs/COMANDOS-GIT.md)).

## 10. Riesgos y decisiones que requieren revisión antes de producción

1. **Versión de Gitea:** se fijó `28.3.0` por indicación del encargo (etiqueta verificada en Docker Hub y presente en la documentación oficial de Docker rootless).
   Revise las notas de la versión antes de actualizar; `update.sh` no cambia de versión mayor sin confirmación escrita.
2. **Datos en claro en disco:** la VPN protege el tránsito, no el almacenamiento. Considere cifrado de disco (LUKS). Los respaldos contienen secretos: cífrelos antes de sacarlos del servidor.
3. **Respaldos en el mismo servidor/disco** no protegen ante pérdida del equipo: configure copias cifradas externas y una política de retención (el proyecto no borra nada).
4. **Respaldo en frío** implica unos segundos de indisponibilidad de Gitea mientras se empaqueta.
5. **Asistente de instalación** accesible hasta crear el administrador: hágalo apenas termine la instalación (o por túnel SSH).
6. **Orden de arranque:** ambos puertos publicados por Docker están enlazados a localhost; Tailscale Serve proporciona el acceso remoto y debe verificarse tras un reinicio real.
7. **UID 1000 y `sudo`:** `data/` y `config/` pertenecen al UID 1000 (usuario del contenedor); si su usuario no es 1000, los scripts piden `sudo` para leerlos. `install.sh` usa `sudo` solo para crear `/srv/...`.
8. **Tailnet compartida:** Tailscale Serve expone Gitea a todos los dispositivos de su tailnet; use ACL si no es solo suya.
9. **SQLite** es adecuada para uso personal/equipo pequeño; si crece mucho, migrar a PostgreSQL es una tarea aparte.
10. **`cap_drop: ALL` y endurecimientos** no se probaron contra el contenedor real (ver sección 5).
