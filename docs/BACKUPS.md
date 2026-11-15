# Copias de seguridad y restauración

## Qué se respalda

`scripts/backup.sh` crea un archivo `gitea-privado-AAAAMMDD-HHMMSS[-etiqueta].tar.gz` con:

| Contenido | Origen | Incluye |
|---|---|---|
| `data/` | `/srv/gitea-privado/data` | Repositorios Git, base de datos SQLite, claves SSH del servidor, adjuntos, avatares, LFS, índices |
| `config/` | `/srv/gitea-privado/config` | `app.ini` (con las claves internas de Gitea) |
| `meta/` | copia de `compose.yaml` y `.env` | Reconstrucción de la configuración |
| `MANIFEST.txt` | generado | Formato, fecha, versión de Gitea, imagen, proyecto |

No es una copia parcial de `repositories`: la base de datos y los repositorios se respaldan **juntos y en frío**
(Gitea detenido), que es la única forma de evitar inconsistencias entre ambos (la propia documentación de Gitea lo indica).

## Cómo funciona `backup.sh`

1. Toma un bloqueo (`flock`) para impedir ejecuciones simultáneas.
2. Comprueba el espacio libre en el destino y que el destino **no** está dentro de `/srv/gitea-privado`.
3. Detiene **solo** el servicio `gitea` de este proyecto (otros contenedores y Docker no se tocan).
4. Empaqueta con `tar` + `gzip` a un archivo `.partial` y lo renombra al terminar.
5. **Reinicia Gitea siempre** (incluso si el respaldo falla o se interrumpe con Ctrl+C), mediante `trap`.
6. Verifica `gzip -t` y `tar -t`, genera y comprueba el `.sha256`, fija permisos `600` (carpeta `700`) y espera a que Gitea responda.

```bash
/srv/gitea-privado/scripts/backup.sh                       # respaldo estándar
/srv/gitea-privado/scripts/backup.sh --label antes-de-x    # con etiqueta
/srv/gitea-privado/scripts/backup.sh --dir /mnt/disco2/gitea-backups   # otro destino (ruta absoluta)
```

Ruta predeterminada: `/srv/backups/gitea-privado/` (`GITEA_BACKUP_DIR` en `.env`). **No hay borrado automático**: usted define la política.

> Un respaldo almacenado en el mismo disco físico que Gitea no protege frente a la falla, pérdida o destrucción de ese disco. Mantenga una copia cifrada en un dispositivo o ubicación independiente.

## Política de retención (manual, a su criterio)

El proyecto no borra nada. Ejemplo para **listar** respaldos de más de 30 días y revisarlos antes de eliminarlos usted mismo:

```bash
find /srv/backups/gitea-privado -name 'gitea-privado-*.tar.gz' -mtime +30 -print
```

Una política razonable: diarios 7 días, semanales 4 semanas, mensuales 6 meses, más el último respaldo **fuera del servidor**.
Los archivos `*-pre-update-*` y `*-pre-restore-*` se conservan hasta que usted decida.

## Programar respaldos (opcional, lo configura usted)

Ejemplo de `cron` del usuario administrador (`crontab -e`), cada noche a las 03:00. Se ejecuta con su usuario (necesita `sudo` sin contraseña
solo si su UID no es 1000; si lo es, no hace falta):

```cron
0 3 * * * /srv/gitea-privado/scripts/backup.sh --label diario >> /srv/backups/gitea-privado/backup.log 2>&1
```

## Copias adicionales cifradas fuera del servidor

El respaldo contiene secretos (`app.ini`, claves SSH del servidor, base de datos). **Cífrelo antes de sacarlo del servidor.**

Con GPG (pide la frase de contraseña de forma interactiva; no la escriba en argumentos):

```bash
cd /srv/backups/gitea-privado
gpg --symmetric --cipher-algo AES256 gitea-privado-AAAAMMDD-HHMMSS.tar.gz     # genera ...tar.gz.gpg
sha256sum gitea-privado-AAAAMMDD-HHMMSS.tar.gz.gpg
sha256sum gitea-privado-AAAAMMDD-HHMMSS.tar.gz.gpg > gitea-privado-AAAAMMDD-HHMMSS.tar.gz.gpg.sha256
```

El checksum del `.tar.gz` y el del `.tar.gz.gpg` corresponden a archivos distintos. Verifique el `.tar.gz` antes del cifrado con su `.sha256` original. Tras copiar, ejecute `sha256sum -c gitea-privado-AAAAMMDD-HHMMSS.tar.gz.gpg.sha256` para validar el cifrado; después de descifrar conservando el nombre original, compruebe el `.tar.gz` con su `.sha256` original antes de restaurarlo.

Traerlo a Windows (PowerShell; puerto de administración, no el 2222):

```powershell
scp -P <PUERTO_SSH_ADMIN> <USUARIO>@<HOST>:/srv/backups/gitea-privado/gitea-privado-AAAAMMDD-HHMMSS.tar.gz.gpg .
scp -P <PUERTO_SSH_ADMIN> <USUARIO>@<HOST>:/srv/backups/gitea-privado/gitea-privado-AAAAMMDD-HHMMSS.tar.gz.sha256 .
scp -P <PUERTO_SSH_ADMIN> <USUARIO>@<HOST>:/srv/backups/gitea-privado/gitea-privado-AAAAMMDD-HHMMSS.tar.gz.gpg.sha256 .
```

Guárdelo en un disco externo o servicio de almacenamiento **cifrado** y pruebe a descifrarlo (`gpg --decrypt ... > archivo.tar.gz`).
Guarde la frase de contraseña en un gestor de contraseñas (no junto al respaldo). Sin ella, el respaldo cifrado es irrecuperable.
Alternativa: `age -p` (si lo tiene instalado).

## Restauración (`restore.sh`)

```bash
/srv/gitea-privado/scripts/restore.sh /srv/backups/gitea-privado/gitea-privado-AAAAMMDD-HHMMSS.tar.gz
```

Antes de modificar nada, el script:

1. Exige que existan `compose.yaml` y `.env` (instalación previa) y el archivo `.sha256` junto al respaldo.
2. Verifica **SHA-256**, integridad `gzip`, la estructura (solo `MANIFEST.txt`, `meta/`, `data/`, `config/`), que no haya rutas absolutas, `..`,
   enlaces simbólicos peligrosos ni archivos especiales, y el formato/versión del `MANIFEST.txt`.
3. Compara la versión de Gitea del respaldo con la de `.env`. Si difieren, se detiene y exige `--use-backup-version` (que fija
   `GITEA_VERSION` a la del respaldo). Una versión de Gitea no abre con seguridad datos de una versión **posterior**.
4. Muestra si hay una instalación activa y pide escribir **`RESTAURAR`**.
5. Crea un respaldo de seguridad de los datos actuales (`--label pre-restore`).

Después: detiene Gitea, **renombra** (no borra) `data` y `config` a `data.pre-restore-<fecha>` y `config.pre-restore-<fecha>`, extrae el respaldo,
fija propietario `1000:1000`, inicia Gitea, espera la respuesta web y regenera los hooks de Git. Si la extracción falla, devuelve automáticamente lo anterior.
Cuando haya verificado todo, elimine usted mismo las carpetas `*.pre-restore-*` (el script nunca lo hace).

**Verificar tras restaurar:**

```bash
docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml exec gitea gitea -c /etc/gitea/app.ini admin user list
/srv/gitea-privado/scripts/status.sh
```
y entre a la web, abra sus repositorios y haga `git clone` de uno desde Windows.

### Recuperación en un servidor nuevo

1. Instale Docker, Tailscale y copie el proyecto (Fases 1–4 de [INSTALACION-MANANA.md](INSTALACION-MANANA.md)); ejecute `install.sh`.
   No complete el asistente web (los usuarios vendrán del respaldo).
2. Copie el `.tar.gz` y su `.sha256` al servidor y ejecute `restore.sh` (con `--use-backup-version` si la versión difiere).
3. Si el nuevo servidor tiene otro nombre de Tailscale, `configure.sh --regenerate` actualiza `.env`; `app.ini` se corrige en el siguiente arranque
   porque las variables `GITEA__server__...` prevalecen. Registre de nuevo el HTTPS con `configure-tailscale.sh`.
4. Los clientes verán una **huella SSH distinta** si no se restauró `data/data/ssh` (sí se restaura con este respaldo; el volumen `./data:/var/lib/gitea` contiene esa ruta interna); verifíquela como en la Fase 9.

### Procedimiento manual (si prefiere no usar el script)

```bash
cd /srv/backups/gitea-privado
sha256sum -c gitea-privado-AAAAMMDD-HHMMSS.tar.gz.sha256
tar -tzf gitea-privado-AAAAMMDD-HHMMSS.tar.gz | head -n 30          # revise que solo hay MANIFEST.txt, meta/, data/, config/
docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml stop gitea
cd /srv/gitea-privado
sudo mv data data.pre-restore-manual && sudo mv config config.pre-restore-manual
sudo tar --numeric-owner -xzpf /srv/backups/gitea-privado/gitea-privado-AAAAMMDD-HHMMSS.tar.gz data config
sudo chown -R 1000:1000 data config
docker compose -p gitea-privado -f /srv/gitea-privado/compose.yaml up -d gitea
```

## Probar la restauración en un entorno separado

Hágalo antes de depender de los respaldos. Usa otra carpeta, otro nombre de proyecto, otro contenedor y otros puertos, de modo que no toca la instalación real.
Todo en 🐧 Bash:

```bash
sudo mkdir -p /srv/gitea-prueba && sudo chown "$USER": /srv/gitea-prueba
cd /srv/gitea-prueba
cp -r /srv/gitea-privado/compose.yaml /srv/gitea-privado/scripts .
sed -i 's/^name: gitea-privado$/name: gitea-prueba/' compose.yaml
sed -i 's#GITEA__server__ROOT_URL: .*#GITEA__server__ROOT_URL: http://127.0.0.1:3190/#; s#GITEA__server__SSH_DOMAIN: .*#GITEA__server__SSH_DOMAIN: 127.0.0.1#' compose.yaml
cp /srv/gitea-privado/.env .env && chmod 600 .env
sed -i -e 's#^GITEA_INSTALL_DIR=.*#GITEA_INSTALL_DIR=/srv/gitea-prueba#' \
       -e 's#^GITEA_BACKUP_DIR=.*#GITEA_BACKUP_DIR=/srv/backups/gitea-prueba#' \
       -e 's#^GITEA_WEB_PORT=.*#GITEA_WEB_PORT=3190#' \
       -e 's#^GITEA_SSH_LOCAL_PORT=.*#GITEA_SSH_LOCAL_PORT=2322#' \
       -e 's#^GITEA_SSH_PORT=.*#GITEA_SSH_PORT=2322#' .env
sed -i '/^COMPOSE_PROJECT_NAME=/d' .env
sed -i '/^GITEA_CONTAINER_NAME=/d' .env
printf 'COMPOSE_PROJECT_NAME=gitea-prueba\nGITEA_CONTAINER_NAME=gitea-prueba\n' >> .env
sudo install -d -o 1000 -g 1000 -m 750 data config
sudo mkdir -p /srv/backups/gitea-prueba && sudo chown "$USER": /srv/backups/gitea-prueba
if ss -ltn | grep -Eq ':(3190|2322)[[:space:]]'; then echo '3190 o 2322 esta ocupado; elija otros puertos y actualice .env'; exit 1; fi

GITEA_INSTALL_DIR=/srv/gitea-prueba ./scripts/restore.sh /srv/backups/gitea-privado/gitea-privado-AAAAMMDD-HHMMSS.tar.gz
```

Compruebe `http://127.0.0.1:3190` por un túnel SSH (`ssh -L 3190:127.0.0.1:3190 ...`), que los usuarios y repositorios existen, y
**no** ejecute `configure-tailscale.sh` en la copia de prueba. Para terminar (sin tocar la instalación real):

```bash
docker compose -p gitea-prueba -f /srv/gitea-prueba/compose.yaml down      # SIN -v
# Cuando esté seguro, elimine usted mismo /srv/gitea-prueba y /srv/backups/gitea-prueba.
```

Antes de continuar, compruebe que los puertos 3190 y 2322 estén libres (`ss -ltn`); si alguno está ocupado, elija puertos libres y actualice las variables correspondientes. La restauración debe usar el proyecto Compose `gitea-prueba` y un contenedor llamado `gitea-prueba` (ajuste `container_name` solo en esta copia de `compose.yaml`).

La prueba usa una copia del `.env` productivo modificada solo en `/srv/gitea-prueba/.env`; no edite el `.env` productivo. Los datos viven en `/srv/gitea-prueba/data` y `config`, los respaldos en `/srv/backups/gitea-prueba`. Acceda por túnel a `http://127.0.0.1:3190`, no a la URL pública productiva. No ejecute `configure-tailscale.sh` para esta copia.

Invoque explícitamente `docker compose -p gitea-prueba -f /srv/gitea-prueba/compose.yaml ...`; nunca use el nombre de proyecto o contenedor productivo. Los scripts de la prueba usan `GITEA_INSTALL_DIR`, así que `backup.sh`/`status.sh` de esa carpeta también apuntan a la copia de prueba.
