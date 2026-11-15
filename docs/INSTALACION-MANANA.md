# Instalación en el servidor Ubuntu — guía paso a paso

Siga las fases **en orden**. Cada fase indica dónde ejecutar (🪟 PowerShell en Windows, 🐧 Bash en Ubuntu), los comandos exactos,
lo que debe ver y qué hacer si falla. Los valores entre `<...>` son suyos: **no se inventan** (usuario, host, IP, tailnet).

| Dato que necesitará | Cómo obtenerlo |
|---|---|
| `<USUARIO>` | Su usuario de Ubuntu (el que ya usa para administrar el servidor) |
| `<HOST>` | Nombre o IP con la que ya se conecta por SSH al servidor (red local o Tailscale) |
| `<PUERTO_SSH_ADMIN>` | Puerto del SSH de **administración** del servidor (normalmente 22). **No** es el 2222 de Git |

Reglas de oro: no ejecute `docker system prune`, `docker volume prune` ni `docker compose down -v`; no detenga contenedores ajenos.

---

## Fase 1: Inspección del servidor (solo lectura)

**Dónde ejecutar:** 🪟 PowerShell en Windows (para conectar) y 🐧 Bash en el servidor (para inspeccionar).

🪟 PowerShell — entre al servidor:

```powershell
ssh -p <PUERTO_SSH_ADMIN> <USUARIO>@<HOST>
```

Si es la primera vez, SSH muestra una huella (`SHA256:...`). Acéptela solo si coincide con la del servidor
(compárela en la consola física o con `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` ejecutado en el servidor).

🐧 Bash (ya dentro del servidor):

```bash
cat /etc/os-release | head -n 3          # distribución
uname -m                                  # arquitectura
docker --version && docker compose version
docker ps --format 'table {{.Names}}\t{{.Ports}}'   # contenedores actuales (NO se tocarán)
docker network ls
df -h /srv /                              # espacio disponible
free -h                                   # memoria
ss -ltn                                   # puertos en escucha: anote si 3090 o 2222 ya se usan
tailscale status                          # ¿conectado?
tailscale ip -4                           # IP 100.x del servidor
tailscale serve status                    # ¿ya hay servicios publicados? (no se reemplazarán)
```

**Resultado esperado:** Docker y Compose responden; `tailscale status` lista su equipo; `tailscale ip -4` muestra una IP `100.x.y.z`.

**Si falla:**
- *Tailscale no está instalado/conectado:* instálelo con las instrucciones oficiales de <https://tailscale.com/download/linux>
  (revise cualquier script antes de ejecutarlo) y conéctelo usted: `sudo tailscale up`. Este proyecto nunca lo hace automáticamente.
- *MagicDNS / HTTPS:* en <https://login.tailscale.com/admin/dns> active **MagicDNS** y **HTTPS Certificates**
  (necesarios para `https://<equipo>.<tailnet>.ts.net`). Verifique con `tailscale status --json` (campo `Self.DNSName`).
- *`permission denied` con Docker:* su usuario no está en el grupo `docker` (`sudo usermod -aG docker $USER` y vuelva a entrar).
- *Puerto 3090 o 2222 ocupado:* anótelo; en la Fase 4 podrá elegir otros (`--web-port`, `--ssh-port`).

**Qué modifica:** nada — solo lectura del estado del servidor.

Salga del servidor (`exit`) para continuar.

---

## Fase 2: Transferencia (Windows → Ubuntu)

**Dónde ejecutar:** 🪟 PowerShell en Windows.

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\upload-project.ps1
```

Le pedirá host, usuario y puerto SSH de administración. Comprueba la conexión (con verificación de huella activa), crea
`~/gitea-privado-staging` en el HOME remoto, copia solo los archivos de despliegue (sin `.git`, `.env`, datos ni respaldos)
y restaura y verifica permisos de ejecución en los scripts y las pruebas.

**Resultado esperado:** `[ OK ] Permisos ejecutables recuperados y verificados; transferencia completada a ~/gitea-privado-staging`.

**Si falla / alternativa manual** (PowerShell, desde la carpeta que contiene `gitea-privado`):

```powershell
scp -P <PUERTO_SSH_ADMIN> -r .\gitea-privado <USUARIO>@<HOST>:gitea-privado-staging
```

Luego, en el servidor, restaure los permisos de ejecución:

```bash
chmod +x ~/gitea-privado-staging/scripts/*.sh ~/gitea-privado-staging/tests/*.sh
```

También puede transferir el archivo `gitea-privado-final.zip` y descomprimirlo en la carpeta de preparación; los ZIP no conservan permisos POSIX, así que aplique `chmod +x` igualmente.
Si aparece `bad interpreter` o `^M`, los finales de línea son de Windows:
`sed -i 's/\r$//' ~/gitea-privado-staging/scripts/*.sh`.

**Qué modifica:** crea `~/gitea-privado-staging/` en el servidor; no toca `/srv` ni ninguna instalación existente.

---

## Fase 3: Preflight (comprobaciones previas)

**Dónde ejecutar:** 🐧 Bash en el servidor (desde la carpeta de preparación).

```bash
cd ~/gitea-privado-staging
./scripts/preflight.sh
```

**Resultado esperado:** lista de comprobaciones `[ OK ]`; al final `Preflight superado`. Las `[ADVERTENCIA]` se leen, pero no detienen.
Un `[ERROR]` detiene el proceso: corrija lo indicado (Docker, Tailscale, puertos, espacio) y repita.

**Si falla:**
- `[ERROR] Sin permisos para usar Docker` → `sudo usermod -aG docker $USER`, cierre sesión y vuelva a entrar.
- `[ERROR] Tailscale no está conectado` → `tailscale status`; conéctelo con `sudo tailscale up`.
- `[ERROR] Puerto web 3090 ocupado` → elija otro en la Fase 4 con `--web-port`.
- `permission denied` al ejecutar `./scripts/preflight.sh` → `chmod +x scripts/*.sh tests/*.sh`.

**Qué modifica:** nada — solo lectura.

---

## Fase 4: Configuración (genera .env)

**Dónde ejecutar:** 🐧 Bash en el servidor (desde la carpeta de preparación).

```bash
cd ~/gitea-privado-staging
./scripts/configure.sh
```

Detecta la IP y el DNS de Tailscale automáticamente y genera `.env` con permisos 600.
Con otros puertos: `./scripts/configure.sh --web-port 3091 --ssh-port 2223 --ssh-local-port 2223`.

**Resultado esperado:** `.env escrito con permisos 600`, `Docker Compose valida la configuración` y la URL privada prevista
(`https://<equipo>.<tailnet>.ts.net/`).

**Si falla:** si Tailscale no está conectado el script muestra el procedimiento oficial y se detiene. Si el DNS no termina en
`.ts.net`, active MagicDNS (Fase 1). Para recrear el `.env`: `./scripts/configure.sh --regenerate` (guarda una copia `.env.bak-<fecha>`).

**Qué modifica:** crea/actualiza `~/gitea-privado-staging/.env` (permisos 600); no toca Tailscale ni Docker.

---

## Fase 5: Instalación (Docker y Gitea)

**Dónde ejecutar:** 🐧 Bash en el servidor (desde la carpeta de preparación).

```bash
cd ~/gitea-privado-staging
./scripts/install.sh
```

Hace: preflight → crea `/srv/gitea-privado` y `/srv/backups/gitea-privado` (pide `sudo` solo para esto) → copia el proyecto →
valida `compose.yaml` → descarga `docker.gitea.com/gitea:28.3.0-rootless` → inicia **solo** Gitea → verifica el contenedor y la web local.

**Resultado esperado:** `El contenedor permanece en ejecución`, `El servicio web responde en http://127.0.0.1:3090` y el bloque
"Instalación completada" con la URL, el SSH de Git y los siguientes pasos.

**Si falla:** el script imprime los últimos registros. Consulte también:

```bash
docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml logs --tail 100 gitea
```

Repetir `./scripts/install.sh` es seguro (no pisa datos, `.env` ni reinicia sin preguntar). Ver [SOLUCION-PROBLEMAS.md](SOLUCION-PROBLEMAS.md).

**Qué modifica:** crea `/srv/gitea-privado/` (con la copia del proyecto) y `/srv/backups/gitea-privado/`; inicia el contenedor `gitea-privado`; no toca otros contenedores.

---

## Fase 6: Acceso inicial por túnel SSH administrativo

**Dónde ejecutar:** 🪟 PowerShell en Windows (para abrir el túnel), 🌐 navegador en Windows (para el asistente).

> **Por qué el túnel:** el asistente de instalación de Gitea se completa **antes** de publicar en la tailnet.
> Si se publicara primero con Tailscale Serve, cualquier dispositivo de la tailnet podría completarlo antes que usted.
> `configure-tailscale.sh` detecta esta situación y se niega a publicar mientras el asistente esté pendiente.

🪟 PowerShell — abra el túnel SSH (manténgalo abierto mientras usa el asistente):

```powershell
ssh -p <PUERTO_SSH_ADMIN> -L 3090:127.0.0.1:3090 <USUARIO>@<HOST>
```

Esto reenvía el puerto local 3090 de su Windows al puerto 3090 del servidor Ubuntu (donde Gitea escucha internamente).
Abra su navegador en Windows y vaya a: **`http://localhost:3090`**

**Resultado esperado:** aparece el **asistente de instalación de Gitea**. Si en su lugar ve una página de inicio de sesión, el asistente ya fue completado (pase a Fase 7).

**Si falla:**
- *`Connection refused` en localhost:3090* → Gitea no está corriendo; vuelva a ejecutar `install.sh` (Fase 5).
- *SSH pide contraseña repetidamente* → use autenticación por clave; confirme host, usuario y puerto (`-p <PUERTO_SSH_ADMIN>`).
- *El navegador redirige a `https://...ts.net/`* → es normal (Gitea conoce su URL pública); como Tailscale Serve aún no está configurado, la conexión fallará. Use `http://localhost:3090` directamente.

**Qué modifica:** no modifica el servidor; solo crea un túnel temporal.

---

## Fase 7: Configuración inicial (cuenta de administrador y INSTALL_LOCK)

**Dónde ejecutar:** 🌐 navegador en Windows (con el túnel de la Fase 6 abierto).

Se hace **una sola vez**. La contraseña se escribe únicamente en el navegador; no pasa por comandos, scripts ni archivos del proyecto.

1. En `http://localhost:3090` verá el **asistente de instalación** de Gitea.
2. Deje **Tipo de base de datos = SQLite3** y las rutas/URL que ya aparecen rellenadas (vienen de `.env`; no las cambie).
3. Despliegue **Configuración opcional → Configuración de la cuenta de administrador** y cree su usuario con una contraseña larga y única.
   (Todas las opciones de registro abierto ya están desactivadas por configuración.)
4. Pulse **Instalar Gitea**. Al terminar, la página puede redirigir a `https://<equipo>.<tailnet>.ts.net/` (aún sin Tailscale Serve activo); es normal.
   Vuelva a `http://localhost:3090` para comprobar que puede iniciar sesión.
5. Asegure la cuenta: avatar → **Configuración → Seguridad → Autenticación de dos factores** → active 2FA (app TOTP) → guarde los códigos de recuperación fuera del servidor.

🐧 Verifique desde el servidor que el asistente quedó bloqueado (impide que otro lo repita):

```bash
sudo grep -n '^INSTALL_LOCK' /srv/gitea-privado/config/app.ini
```

**Resultado esperado:** `INSTALL_LOCK = true`. Esta verificación es **obligatoria** antes de la Fase 8: `configure-tailscale.sh` rechazará publicar si falta.

**Si falla:**
- *Error de escritura de app.ini / permisos* → `sudo chown -R 1000:1000 /srv/gitea-privado/config /srv/gitea-privado/data` y recargue.
- *El asistente reaparece tras un reinicio* → no se completó; repita el paso 4.
- *El navegador redirige a HTTPS antes de completar el asistente* → use `http://localhost:3090` directamente (el túnel ignora la redirección).
- *Olvidó la contraseña del administrador* → ver [SOLUCION-PROBLEMAS.md](SOLUCION-PROBLEMAS.md).

**Qué modifica:** Gitea escribe `INSTALL_LOCK = true` en `/srv/gitea-privado/config/app.ini`; crea los directorios de datos en `/srv/gitea-privado/data/`.

---

## Fase 8: Publicación privada (Tailscale Serve)

**Dónde ejecutar:** 🐧 Bash en el servidor (desde la copia instalada).

```bash
cd /srv/gitea-privado
./scripts/configure-tailscale.sh --dry-run     # muestra el comando sin ejecutarlo
./scripts/configure-tailscale.sh               # lo aplica (exige INSTALL_LOCK=true)
```

El script lee `tailscale serve status` primero y **no reemplaza ni elimina** configuraciones existentes. Ejecuta el equivalente de:

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:3090
sudo tailscale serve --bg --tcp=2222 tcp://127.0.0.1:2222
```

La arquitectura de red resultante es:

```
Windows
   ↓ Tailscale VPN
Tailscale Serve TCP (:2222)
   ↓
Ubuntu 127.0.0.1:2222
   ↓
Docker Gitea SSH :2222

Windows
   ↓ Tailscale HTTPS (:443)
Tailscale Serve
   ↓
Ubuntu 127.0.0.1:3090
   ↓
Docker Gitea HTTP :3000
```

**Resultado esperado:** `Tailscale Serve configurado` y confirmación de que `https://<equipo>.<tailnet>.ts.net/` responde (puede tardar un momento en obtener el certificado).

**Si falla:**
- *`INSTALL_LOCK` no es `true`:* complete el asistente (Fase 7) antes de continuar. Esta protección no se puede desactivar sin `--allow-unfinished-installer`.
- *Puerto 443 ya usado por otro Serve:* el script explica el conflicto y no cambia nada. Alternativa: `./scripts/configure-tailscale.sh --https-port 8443`.
- *Pide habilitar HTTPS/certificados:* actívelos en <https://login.tailscale.com/admin/dns> y repita.

**Qué modifica:** configura Tailscale Serve (HTTPS y TCP) en el demonio `tailscaled`; no toca Docker ni el firewall del sistema.

---

## Fase 9: Configuración SSH de Windows (clave Ed25519 y alias Git)

**Dónde ejecutar:** 🪟 PowerShell en Windows (con Tailscale conectado al mismo tailnet).

Requisitos: Tailscale instalado y conectado en Windows (mismo tailnet), Git y Cliente OpenSSH.

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\setup-git.ps1 -ServerName <equipo>.<tailnet>.ts.net
```

Si cambió el puerto SSH de Git, agregue `-SshPort <puerto>`. El script: crea una clave Ed25519 **nueva y exclusiva** (sin tocar las existentes),
pide su frase de contraseña (la pide `ssh-keygen`, el script no la ve), muestra y copia la clave **pública**, y agrega el bloque `git-privado`
a `~/.ssh/config` sin modificar lo demás (con copia de seguridad).

1. Registre la clave pública: en Gitea → avatar → **Configuración → Claves SSH / GPG → Agregar clave** → pegar → guardar.
2. **Verifique la huella del servidor** antes de aceptarla. 🐧 En Ubuntu:
   ```bash
   /srv/gitea-privado/scripts/status.sh        # sección "Huellas SSH del servidor Git"
   # o directamente:
   sudo ssh-keygen -lf /srv/gitea-privado/data/data/ssh/gitea.ed25519.pub
   ```
   🪟 En Windows (huella que anuncia el servidor):
   ```powershell
   ssh-keyscan -p 2222 <equipo>.<tailnet>.ts.net | ssh-keygen -lf -
   ```
   Deben coincidir. Luego conéctese y acepte (`yes`) solo si coincide:
   ```powershell
   ssh -T git-privado
   ```

**Resultado esperado:** un mensaje de Gitea similar a "You've successfully authenticated ... but Gitea does not provide shell access".

**Si falla:** `Permission denied (publickey)` → la clave pública no está registrada en su usuario, o SSH usa otra clave
(`ssh -vT git-privado`). `Connection timed out` → Tailscale desconectado en Windows o el puerto/IP no coinciden
(`ssh -T -p <puerto> git@<equipo>.<tailnet>.ts.net`). Más en [SOLUCION-PROBLEMAS.md](SOLUCION-PROBLEMAS.md).

**Qué modifica:** crea `~/.ssh/id_ed25519_gitea_privado` (y `.pub`) en Windows; actualiza `~/.ssh/config` (con copia de seguridad).

---

## Fase 10: Primer repositorio y pruebas extremo a extremo

**Dónde ejecutar:** 🐧 Bash en el servidor (pruebas automáticas) y 🪟 PowerShell en Windows (prueba manual Git).

🐧 Pruebas automáticas del servidor:

```bash
/srv/gitea-privado/scripts/smoke-test.sh
/srv/gitea-privado/scripts/smoke-test.sh --recreate-test   # recrea el contenedor y comprueba que los datos persisten
```

**Resultado esperado:** `Todas las pruebas ejecutadas pasaron` (la prueba de autenticación SSH se omite en el servidor; se hace desde Windows).

🪟 PowerShell — prueba manual extremo a extremo (sustituya `<usuario>` por su usuario de Gitea):

1. En Gitea: **+ → Nuevo repositorio** → nombre `prueba-inicial` (queda privado: es obligatorio) → Crear.
2. Clonar:
   ```powershell
   git clone git-privado:<usuario>/prueba-inicial.git
   cd prueba-inicial
   ```
3. Crear archivo, commit y push:
   ```powershell
   "Hola desde Windows" | Out-File -Encoding utf8 prueba.txt
   git add prueba.txt
   git commit -m "Primer commit de prueba"
   git push -u origin HEAD
   ```
4. Compruebe en el navegador que `prueba.txt` aparece en el repositorio.
5. Clone de nuevo en otra carpeta y confirme el archivo:
   ```powershell
   cd ..
   git clone git-privado:<usuario>/prueba-inicial.git prueba-inicial-2
   Get-Content .\prueba-inicial-2\prueba.txt
   ```

Si el repositorio recién creado está vacío y el primer `push` falla por nombre de rama, use `git push -u origin HEAD`
(como arriba) o `git branch -M main` antes de subir. Puede borrar el repositorio de prueba desde Gitea cuando termine.

**Si falla:** `git clone` pide contraseña o falla → revise la Fase 9. `push` rechazado → verifique que su usuario tiene permiso de escritura.

**Qué modifica:** crea el repositorio `prueba-inicial` en Gitea; archivos locales en Windows.

---

## Fase 11: Comprobaciones operativas

**Dónde ejecutar:** 🐧 Bash en el servidor.

```bash
/srv/gitea-privado/scripts/status.sh
```

Revise la salida completa: estado del contenedor, healthcheck de Docker, puertos en `127.0.0.1`, huellas SSH, Tailscale Serve,
URL HTTPS y advertencias. No debe haber ningún `[ERROR]` ni Funnel activo.

Compruebe que los puertos de Gitea no son accesibles desde Internet (sin Tailscale):

```bash
docker port gitea-privado       # esperado: 3000/tcp -> 127.0.0.1:3090 y 2222/tcp -> 127.0.0.1:2222
ss -ltn                         # 3090 y 2222 solo en 127.0.0.1; nada en 0.0.0.0
sudo tailscale serve status     # solo HTTPS y TCP de Gitea; sin Funnel
```

**Resultado esperado:** `status.sh` termina sin errores; `docker port` muestra solo `127.0.0.1`; `tailscale serve status` sin Funnel.

**Si falla:**
- *Funnel activo sobre un puerto de Gitea* → desactívelo: `sudo tailscale serve --https=443 off`; luego repita `configure-tailscale.sh`.
- *Contenedor `unhealthy`* → `docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml logs --tail 50 gitea`; compruebe permisos de `data/`.
- *Puerto visible en `0.0.0.0`* → revise `compose.yaml`; no debe haberse modificado.

**Qué modifica:** nada — solo lectura del estado del sistema.

---

## Fase 12: Backup inicial y prueba de restauración

**Dónde ejecutar:** 🐧 Bash en el servidor.

```bash
/srv/gitea-privado/scripts/backup.sh
```

Detiene **solo** Gitea unos segundos, empaqueta `data/` y `config/`, vuelve a iniciar y verifica. El script reinicia Gitea
incluso si el respaldo falla (mediante `trap`).

**Resultado esperado:** `Respaldo listo` con la ruta del `.tar.gz`, su SHA-256 y `Gitea responde de nuevo`.

Verifique el respaldo manualmente:

```bash
cd /srv/backups/gitea-privado
ls -lh
sha256sum -c gitea-privado-*.tar.gz.sha256      # debe decir: OK
tar -tzf "$(ls -1t gitea-privado-*.tar.gz | head -n 1)" | head -n 20
```

> **Aviso:** un respaldo en el mismo disco físico que `/srv/gitea-privado` **no protege frente al fallo de ese disco**.
> Copie los respaldos cifrados a un disco externo o servicio de almacenamiento seguro antes de depender de ellos.
> Consulte [BACKUPS.md](BACKUPS.md) para el procedimiento de cifrado y la prueba de restauración en entorno separado.

Programe sus respaldos periódicos y haga una prueba de restauración en un entorno separado antes de depender de ellos.

**Si falla:** `Espacio insuficiente` → libere espacio o use `--dir` con otro disco. `Hay otro respaldo en curso` → espere o revise `ps`.
Gitea se reinicia siempre, incluso si el respaldo falla; confirme con `scripts/status.sh`.

**Qué modifica:** crea `gitea-privado-<fecha>.tar.gz` y `.sha256` en `/srv/backups/gitea-privado/`; detiene y reinicia solo el contenedor `gitea-privado`.

---

## Resumen de comandos del día

| Dónde | Comando |
|---|---|
| 🪟 | `.\windows\upload-project.ps1` |
| 🐧 | `./scripts/preflight.sh` → `./scripts/configure.sh` → `./scripts/install.sh` |
| 🪟 | `ssh -p <PUERTO_SSH_ADMIN> -L 3090:127.0.0.1:3090 <USUARIO>@<HOST>` (túnel para el asistente) |
| 🌐 | Asistente en `http://localhost:3090` → crear administrador → verificar `INSTALL_LOCK=true` → 2FA |
| 🐧 | `/srv/gitea-privado/scripts/configure-tailscale.sh` (solo después de INSTALL_LOCK=true) |
| 🪟 | `.\windows\setup-git.ps1 -ServerName <equipo>.<tailnet>.ts.net` |
| 🐧 | `/srv/gitea-privado/scripts/smoke-test.sh` |
| 🐧 | `/srv/gitea-privado/scripts/status.sh` |
| 🐧 | `/srv/gitea-privado/scripts/backup.sh` |
