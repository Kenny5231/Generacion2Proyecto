# Seguridad

## Qué se implementó

| # | Medida | Dónde |
|---|---|---|
| 1 | Gitea rootless (usuario 1000:1000), `no-new-privileges`, `cap_drop: ALL` | `compose.yaml` |
| 2 | Web y SSH de Git de Docker publicados solo en `127.0.0.1`; ningún puerto en interfaces externas | `compose.yaml` |
| 3 | HTTPS y SSH de Git llegan a la tailnet solo por Tailscale Serve (nunca Funnel); no se pisan servicios ajenos ni se ejecuta `serve reset`/`off` | `configure-tailscale.sh`, `tsjson.py` |
| 4 | Repositorios privados obligatorios (`FORCE_PRIVATE`), usuarios/organizaciones privados por defecto | `compose.yaml` |
| 5 | Registro abierto deshabilitado; inicio de sesión obligatorio para ver cualquier cosa | `compose.yaml` |
| 6 | Sin Actions ni runners; hooks de Git personalizados deshabilitados (`DISABLE_GIT_HOOKS`) | `compose.yaml` |
| 7 | Sin contraseñas en archivos: el administrador se crea en el navegador, por túnel SSH administrativo, antes de publicar en la tailnet | asistente de Gitea, `configure-tailscale.sh` (se niega si falta `INSTALL_LOCK`) |
| 8 | Acceso Git por claves Ed25519; clave nueva y exclusiva en Windows | `windows/setup-git.ps1` |
| 9 | `.env` con permisos 600, parser estricto (nunca `source`), fuera de Git | `common.sh`, `.gitignore` |
| 10 | Sin socket Docker, sin `privileged`, sin `network_mode: host`, red propia | `compose.yaml` |
| 11 | Verificación de huella SSH siempre activa (nada de `StrictHostKeyChecking no`); `-ExpectedFingerprint` para comprobarla automáticamente | `windows/*.ps1` |
| 12 | Respaldos 600/700, SHA-256, comprobación de integridad de SQLite, bloqueo anti-concurrencia, restauración verificada con reversión automática y confirmación escrita | `backup.sh`, `restore.sh` |
| 13 | Registros a consola (rotados 10 MB × 5), sin registro de accesos ni de rutas HTTP | `compose.yaml` |
| 14 | Sin cambios globales: no se toca el firewall, Docker, las ACL ni la configuración de Tailscale existente | todos los scripts |
| 15 | Actualizaciones solo con versión fija `X.Y.Z` (sin `latest`), respaldo previo y verificación posterior | `update.sh` |

Las pruebas `tests/test-static.sh` y `tests/test-lifecycle.sh` comprueban varias de estas propiedades automáticamente (puertos, secretos, comandos peligrosos),
**con comandos simulados en un entorno local**. Nada de esto se ha ejecutado todavía contra el servidor Ubuntu real: la verificación allí es manual
(`scripts/status.sh`, `scripts/smoke-test.sh` y las comprobaciones de este documento).

## Quién puede llegar a Gitea: Tailscale no equivale a «solo yo»

Estar conectado a Tailscale **no** significa que solo el propietario pueda acceder. Quién llega al servidor (HTTPS `GITEA_TS_HTTPS_PORT` y SSH `GITEA_SSH_PORT`)
lo decide la **política de la tailnet** (ACL/grants), que se edita en la consola de administración de Tailscale. Si la política es la predeterminada
(todos con todos), cualquier dispositivo de la tailnet, o compartido con ella, puede intentar conectarse. Los scripts de este proyecto **nunca modifican la política**: se
la deja a usted. Dentro de Gitea sigue haciendo falta iniciar sesión (no hay registro abierto ni repositorios públicos), pero conviene restringir también la red.

Ejemplo **genérico** (sustituya los marcadores; compruébelo con el editor y las pruebas de la política en la consola antes de guardar, porque una política
más restrictiva también puede cortar el acceso a otros servicios de su tailnet). Los puertos deben coincidir con `GITEA_TS_HTTPS_PORT` y `GITEA_SSH_PORT`.

Opción A: cada usuario solo llega a **sus propios** dispositivos (el servidor debe pertenecer a su cuenta):

```json
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["autogroup:self"],
      "ip":  ["tcp:443", "tcp:2222"]
    }
  ]
}
```

Opción B: solo `<TU_USUARIO>` llega al servidor etiquetado (`tag:gitea-servidor`, definida por usted en `tagOwners`); sus dispositivos concretos son los de esa
cuenta (`<TU_DISPOSITIVO>` se distingue por la etiqueta o por el usuario que lo posee):

```json
{
  "tagOwners": { "tag:gitea-servidor": ["<TU_USUARIO>"] },
  "grants": [
    {
      "src": ["<TU_USUARIO>"],
      "dst": ["tag:gitea-servidor"],
      "ip":  ["tcp:443", "tcp:2222"]
    }
  ]
}
```

Equivalente con la sintaxis clásica de ACL: `{"action": "accept", "src": ["<TU_USUARIO>"], "dst": ["tag:gitea-servidor:443,2222"]}` dentro de `"acls"`.
Para limitar a dispositivos concretos, agregue etiquetas (`tag:mis-equipos`) a `<TU_DISPOSITIVO>` y úselas como `src`. Etiquetar el servidor es un cambio
que usted hace en Tailscale (los scripts no lo hacen) y tiene efectos propios (por ejemplo, el vencimiento de claves del dispositivo); revise la documentación de Tailscale antes.
No comparta el servidor con otras tailnets (*node sharing*) si no quiere que lleguen a él.

### Si pierde un dispositivo

1. Consola de administración de Tailscale → **Machines**: *Disable key expiry* no; use **Expire key** y luego deshabilite o elimine el dispositivo perdido.
2. En Gitea (avatar → Configuración → **Claves SSH / GPG**): elimine la clave SSH de ese equipo; en **Aplicaciones** revoque tokens y en **Seguridad** cierre las sesiones activas.
   Un administrador puede hacerlo por otro usuario desde Administración del sitio.
3. Cambie la contraseña de Gitea, regenere los códigos de recuperación de 2FA y, si había otras credenciales en ese equipo, rótelas.
4. Si la clave privada no tenía frase de contraseña, trate como comprometido todo lo que esa clave podía leer y revise el historial de los repositorios.

### Deshabilitar Gitea temporalmente

```bash
# Detener solo Gitea (la web y el SSH dejan de responder; los datos no se tocan):
docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml stop gitea
# Y/o retirar de la tailnet solo los dos servicios de Gitea (con los puertos por defecto):
sudo tailscale serve --https=443 off
sudo tailscale serve --tcp=2222 off
# Volver a activarlo:
docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml start gitea
/srv/gitea-privado/scripts/configure-tailscale.sh
```

## Verificar que no hay puertos públicos

Desde una red **externa**, sin Tailscale (por ejemplo, datos móviles) y contra la IP **pública** del servidor, estos puertos deben estar cerrados o filtrados:
3090 (`GITEA_WEB_PORT`), 2222 (`GITEA_SSH_PORT`/`GITEA_SSH_LOCAL_PORT`) y 443 (`GITEA_TS_HTTPS_PORT`). Ajuste la lista si cambió los puertos.

```powershell
# Windows
Test-NetConnection <IP_PUBLICA_DEL_SERVIDOR> -Port 3090
Test-NetConnection <IP_PUBLICA_DEL_SERVIDOR> -Port 2222
Test-NetConnection <IP_PUBLICA_DEL_SERVIDOR> -Port 443
```

```bash
# Linux/macOS (si tiene nmap)
nmap -Pn -p 443,2222,3090 <IP_PUBLICA_DEL_SERVIDOR>
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://<IP_PUBLICA_DEL_SERVIDOR>:3090/     # debe fallar o agotar el tiempo
```

En el servidor:

```bash
docker port gitea-privado       # esperado: 3000/tcp -> 127.0.0.1:3090 y 2222/tcp -> 127.0.0.1:2222
ss -ltn                         # 3090 y 2222 solo en 127.0.0.1; nada en 0.0.0.0 ni en [::]
sudo tailscale serve status     # solo HTTPS y TCP de Gitea; sin Funnel
```

`scripts/status.sh` y `scripts/smoke-test.sh` repiten las comprobaciones locales («Puertos Docker solo en 127.0.0.1», «Sin Funnel»), pero **no** sustituyen la prueba desde fuera.
**Funnel** (la publicación abierta a internet de Tailscale) no se usa nunca; si `tailscale serve status` o `status.sh` lo muestran activo sobre un puerto de Gitea, desactívelo.

## Verificar la huella del servidor Git

Al conectar por primera vez, SSH muestra la huella (`SHA256:...`) del servidor Git de Gitea. Acéptela solo si coincide con la real. Los *host keys* están en
`/srv/gitea-privado/data/data/ssh/` (propiedad del UID 1000: use `sudo`). Obtenga la huella real por el SSH de administración de Ubuntu y compárela con la que anuncia el servicio:

```bash
# En el servidor
sudo ssh-keygen -lf /srv/gitea-privado/data/data/ssh/gitea.ed25519.pub
# Desde otro equipo de la tailnet (o el mismo servidor): lo que anuncia el servicio
ssh-keyscan -p 2222 -t ed25519 <DNS>.ts.net | ssh-keygen -lf -
```

Las dos líneas deben mostrar el mismo `SHA256:...`. En Windows, `windows/setup-git.ps1 -ExpectedFingerprint "SHA256:..."` solo agrega la huella a `known_hosts` si coincide.
Si luego SSH avisa `REMOTE HOST IDENTIFICATION HAS CHANGED`, no lo ignore (ver [SOLUCION-PROBLEMAS.md](SOLUCION-PROBLEMAS.md)).

## Amenazas y límites reales

Ninguna de estas medidas garantiza seguridad absoluta:

- **Tailscale** protege el *transporte y el acceso* a la red: solo dispositivos de su tailnet llegan al servicio, y **la política (ACL/grants) decide cuáles**
  (ver arriba). No protege contra un dispositivo suyo comprometido, una cuenta de Tailscale tomada o una política demasiado abierta.
- **Docker rootless / usuario no root** reduce el impacto de un fallo en Gitea, pero el contenedor sigue corriendo bajo el demonio Docker (root).
  Una vulnerabilidad de Gitea o del kernel/Docker podría escalar. Mantenga el sistema y Gitea actualizados.
- **Repositorios privados** controlan quién ve qué *dentro de Gitea*; no cifran los archivos.
- **VPN ≠ cifrado en disco.** La VPN protege los datos *en tránsito*. Los datos en `/srv` están **en claro** en el disco: quien tenga acceso físico
  o root en el servidor puede leerlos. Para proteger datos en reposo use cifrado de disco/volumen (LUKS) y proteja el acceso a Ubuntu.
- **El respaldo contiene secretos** (`app.ini` con claves internas, claves SSH del servidor, base de datos con hashes de contraseñas y tokens).
  Trátelo como material sensible y **cífrelo** antes de sacarlo del servidor (ver [BACKUPS.md](BACKUPS.md)).
- **El SHA-256 de un respaldo detecta alteraciones accidentales, no prueba autenticidad**: quien pueda modificar el archivo también puede modificar su `.sha256`.
  Restaure solo respaldos de origen confiable; el cifrado autenticado (`age`, `gpg`) añade esa garantía para las copias fuera del servidor.
- **Cualquiera con acceso a un puerto de la tailnet** puede intentar autenticarse: use contraseñas largas, 2FA y claves SSH con frase de contraseña.
- **El usuario `docker` equivale a root** en Ubuntu. Limite quién pertenece a ese grupo.
- **El asistente de instalación** es accesible hasta que se crea el administrador; por eso se completa por túnel SSH antes de publicar en la tailnet
  y `configure-tailscale.sh` se niega a publicar mientras esté pendiente.
- **Disponibilidad:** un único servidor físico es un único punto de fallo. Los respaldos fuera del servidor son su seguro.

## Autenticación de dos factores (2FA, recomendado)

- **Gitea:** avatar → **Configuración** → **Seguridad** → **Autenticación de dos factores**. Escanee el código con su aplicación de autenticación y guarde
  los códigos de recuperación **fuera del servidor** (y fuera del repositorio).
- **Tailscale:** active 2FA/MFA en el proveedor de identidad con el que inicia sesión (Google, Microsoft, GitHub, etc.),
  y considere la aprobación de dispositivos (*device approval*) y el vencimiento de claves (*key expiry*) en la consola de administración.

## Buenas prácticas operativas

1. Mantenga Ubuntu y Docker con parches de seguridad (`unattended-upgrades` o actualizaciones periódicas).
2. Actualice Gitea con `scripts/update.sh` y lea las notas de versión; el respaldo previo es automático.
3. Revise de vez en cuando: `tailscale status` (dispositivos), la política de la tailnet, `scripts/status.sh`, usuarios en Gitea (Administración del sitio).
4. No exponga Gitea con Funnel ni abra puertos en el router.
5. No guarde en repositorios secretos reales (claves, tokens) aunque sean privados.
6. Considere cifrado de disco (LUKS) si el servidor es físicamente accesible por terceros.
7. Pruebe la restauración periódicamente en un entorno separado (ver [BACKUPS.md](BACKUPS.md)).

## Qué hacer si sospecha de un compromiso

1. Desconecte el servidor de la tailnet (`sudo tailscale down`) o revoque el dispositivo desde la consola de Tailscale.
2. Detenga solo Gitea: `docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml stop gitea`.
3. Haga una copia forense/respaldo, rote todas las claves SSH registradas y las contraseñas, y revise los registros.
4. Restaure desde un respaldo anterior al incidente en un servidor limpio si es necesario.
