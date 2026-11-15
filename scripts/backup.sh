#!/usr/bin/env bash
# backup.sh - Respaldo consistente y completo de Gitea (SQLite + repositorios + configuracion).
#
# Metodo: copia en frio. Se detiene SOLO el servicio gitea de este proyecto, se empaquetan
# data/ y config/ (base de datos SQLite, repositorios, claves SSH del servidor, adjuntos,
# LFS, app.ini con sus claves internas) junto con metadatos, y se vuelve a iniciar Gitea
# incluso si algo falla. No toca otros contenedores ni Docker.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/backup.sh [--label ETIQUETA] [--dir DIRECTORIO] [--allow-corrupt-db]
  --label ETIQUETA   Texto corto (letras, numeros, guion) agregado al nombre del archivo.
  --dir DIRECTORIO   Carpeta de destino (por defecto GITEA_BACKUP_DIR: /srv/backups/gitea-privado).
  --allow-corrupt-db Solo para el respaldo de seguridad previo a una restauracion: si la base SQLite actual esta
                     danada se respalda igualmente (con advertencia) en vez de abortar. No lo use en respaldos normales.

Genera: gitea-privado-AAAAMMDD-HHMMSS[-etiqueta].tar.gz y su .sha256 (permisos 600).
El respaldo contiene secretos (app.ini, claves SSH del servidor): protejalo y cifre las
copias que saque del servidor (vea docs/BACKUPS.md). No se borran respaldos antiguos.
EOF
}

LABEL=""
DEST_OVERRIDE=""
ALLOW_CORRUPT_DB=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --label) [[ $# -ge 2 ]] || die "--label requiere un valor."; LABEL=$2; shift 2 ;;
    --dir) [[ $# -ge 2 ]] || die "--dir requiere un valor."; DEST_OVERRIDE=$2; shift 2 ;;
    --allow-corrupt-db) ALLOW_CORRUPT_DB=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Opcion desconocida: $1" ;;
  esac
done

[[ -z $LABEL || $LABEL =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,40}$ ]] || die "Etiqueta invalida: use letras, numeros, punto o guion."

init_context
[[ -z $DEST_OVERRIDE ]] || { is_abs_path "$DEST_OVERRIDE" || die "--dir debe ser una ruta absoluta."; BACKUP_DIR=$DEST_OVERRIDE; }

WAS_RUNNING=0
STOPPED_BY_US=0
STAGE_DIR=""
TMP_ARCHIVE=""
OUT_FILE=""
STAGE_NAME="inicio"
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ $STOPPED_BY_US -eq 1 ]]; then
    printf '[INFO] Reiniciando Gitea...\n'
    if dc start gitea >/dev/null 2>&1; then
      STOPPED_BY_US=0
      printf '[ OK ] Gitea iniciado de nuevo.\n'
    else
      printf '[ERROR] No se pudo reiniciar Gitea. Ejecute: docker compose -p %s -f %s/compose.yaml start gitea\n' "$PROJECT_NAME" "$INSTALL_DIR" >&2
      [[ $rc -ne 0 ]] || rc=1
    fi
  fi
  if [[ $rc -ne 0 ]]; then
    [[ -z $TMP_ARCHIVE ]] || rm -f -- "$TMP_ARCHIVE" # seguro: archivo temporal propio
    if [[ -n $OUT_FILE ]]; then
      rm -f -- "$OUT_FILE" "$OUT_FILE.sha256" "$OUT_FILE.sha256.partial" # seguro: respaldo incompleto propio
    fi
    printf '[ERROR] El respaldo NO se completo (codigo %s; etapa: %s). No se dejaron archivos parciales y Gitea se dejo como estaba.\n' "$rc" "$STAGE_NAME" >&2
  fi
  if [[ -n $STAGE_DIR && -d $STAGE_DIR ]]; then
    rm -rf -- "$STAGE_DIR" # seguro: directorio temporal propio creado con mktemp
  fi
  exit "$rc"
}

main() {
  need_cmd docker
  need_cmd tar
  need_cmd gzip
  need_cmd sha256sum
  need_cmd flock
  [[ -f $INSTALL_DIR/compose.yaml ]] || die "No hay instalacion en $INSTALL_DIR (falta compose.yaml)."
  [[ -d $INSTALL_DIR/data && -d $INSTALL_DIR/config ]] || die "Faltan $INSTALL_DIR/data o $INSTALL_DIR/config: no hay nada que respaldar."
  if is_under "$BACKUP_DIR" "$INSTALL_DIR" || is_under "$INSTALL_DIR" "$BACKUP_DIR"; then
    die "El directorio de respaldos ($BACKUP_DIR) no puede estar dentro de lo que se respalda ($INSTALL_DIR)."
  fi

  if [[ ! -d $BACKUP_DIR ]]; then
    as_root mkdir -p -- "$BACKUP_DIR"
    as_root chown "$(id -u):$(id -g)" -- "$BACKUP_DIR"
  fi
  [[ -w $BACKUP_DIR ]] || die "No se puede escribir en $BACKUP_DIR."
  chmod 700 -- "$BACKUP_DIR" 2>/dev/null || true
  umask 077

  # Evita ejecuciones simultaneas. restore.sh ya sostiene este bloqueo cuando nos invoca (GITEA_LOCK_INHERITED).
  if [[ -z ${GITEA_LOCK_INHERITED:-} ]]; then
    exec 9>"$BACKUP_DIR/.backup.lock"
    flock -n 9 || die "Hay otro respaldo o restauracion en curso (bloqueo: $BACKUP_DIR/.backup.lock)."
  fi

  trap cleanup EXIT
  trap 'exit 130' INT TERM

  STAGE_NAME="comprobaciones"
  section "Comprobaciones"
  local need_kb avail
  need_kb=$(as_data_owner du -sk -- "$INSTALL_DIR/data" "$INSTALL_DIR/config" | awk '{ s += $1 } END { print s + 0 }')
  avail=$(avail_kb "$BACKUP_DIR")
  info "Datos a respaldar: $(human_kb "$need_kb") | Espacio libre en destino: $(human_kb "$avail")"
  # El archivo comprimido nunca excede el tamano original; se exige ese margen mas un 10 %.
  (( avail > need_kb + need_kb / 10 + 10240 )) || die "Espacio insuficiente en $BACKUP_DIR."
  ok "Espacio suficiente."

  local ts base version_text running_version manifest_version n=1
  ts=$(timestamp)
  base="gitea-privado-$ts${LABEL:+-$LABEL}"
  # Nombre unico: si dos respaldos caen en el mismo segundo se agrega un contador (nunca se sobrescribe).
  while [[ -e $BACKUP_DIR/$base.tar.gz ]]; do
    n=$((n + 1))
    base="gitea-privado-$ts-$n${LABEL:+-$LABEL}"
  done
  OUT_FILE="$BACKUP_DIR/$base.tar.gz"
  TMP_ARCHIVE="$OUT_FILE.partial"

  STAGE_DIR=$(mktemp -d "$BACKUP_DIR/.stage.XXXXXX")
  mkdir -p -- "$STAGE_DIR/meta"
  version_text=""
  running_version=""
  if container_running; then
    WAS_RUNNING=1
    version_text=$(dc exec -T gitea gitea --version 2>/dev/null | sed -n '1p' || true)
    [[ $version_text =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && running_version=${BASH_REMATCH[1]}
  fi
  # La version que realmente migro los datos es la que corre; si no corre, la configurada en .env.
  manifest_version=${running_version:-${GITEA_VERSION:-desconocida}}

  STAGE_NAME="deteniendo Gitea"
  section "Respaldo de Gitea privado"
  if [[ $WAS_RUNNING -eq 1 ]]; then
    info "Deteniendo unicamente el servicio gitea (otros contenedores no se tocan)..."
    STOPPED_BY_US=1
    dc stop -t 60 gitea >/dev/null
    ok "Gitea detenido."
  else
    info "Gitea no esta en ejecucion; se respalda directamente (no se iniciara al terminar)."
  fi

  STAGE_NAME="comprobando la base de datos"
  local db schema="" db_state="ok"
  db=$(gitea_db_path)
  if as_data_owner test -f "$db"; then
    if have python3; then
      if sqlite_integrity_ok "$db"; then
        ok "Base de datos SQLite: integrity_check correcto."
        schema=$(db_schema_version)
      elif [[ $ALLOW_CORRUPT_DB -eq 1 ]]; then
        db_state="danada"
        warn "La base de datos SQLite NO supera integrity_check ($db); se respalda igualmente porque es el respaldo de seguridad previo a una restauracion."
      else
        die "La base de datos SQLite NO supera PRAGMA integrity_check ($db). No se genera un respaldo que parezca valido; investigue antes de continuar."
      fi
    else
      db_state="no-comprobada"
      warn "python3 no esta disponible: no se comprobo la integridad de la base de datos."
    fi
  else
    db_state="ausente"
    warn "No existe $db (el asistente de instalacion de Gitea aun no se completo): se respaldan solo los archivos presentes."
  fi
  {
    printf 'BACKUP_FORMAT=%s\n' "$BACKUP_FORMAT_VERSION"
    printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'GITEA_VERSION=%s\n' "$manifest_version"
    printf 'GITEA_IMAGE=%s\n' "$(image_ref "$manifest_version")"
    printf 'DB_SCHEMA_VERSION=%s\n' "${schema:-desconocida}"
    printf 'DB_INTEGRITY=%s\n' "$db_state"
    printf 'PROJECT_NAME=%s\n' "$PROJECT_NAME"
    printf 'SOURCE_INSTALL_DIR=%s\n' "$INSTALL_DIR"
    printf 'GITEA_BINARY_REPORT=%s\n' "${version_text//[^A-Za-z0-9 ._()+,-]/}"
    printf 'CONTENTS=data config meta\n'
  } >"$STAGE_DIR/MANIFEST.txt"
  cp -p -- "$INSTALL_DIR/compose.yaml" "$STAGE_DIR/meta/compose.yaml"
  [[ ! -f $INSTALL_DIR/.env ]] || cp -p -- "$INSTALL_DIR/.env" "$STAGE_DIR/meta/env"

  STAGE_NAME="creando el archivo comprimido"
  info "Creando archivo comprimido..."
  as_data_owner tar --numeric-owner -czpf - -C "$STAGE_DIR" MANIFEST.txt meta -C "$INSTALL_DIR" data config >"$TMP_ARCHIVE"
  mv -- "$TMP_ARCHIVE" "$OUT_FILE"
  TMP_ARCHIVE=""
  ok "Archivo creado: $OUT_FILE"

  if [[ $STOPPED_BY_US -eq 1 ]]; then
    STAGE_NAME="reiniciando Gitea"
    info "Reiniciando Gitea..."
    dc start gitea >/dev/null
    STOPPED_BY_US=0
    ok "Gitea iniciado de nuevo."
  fi

  STAGE_NAME="verificacion"
  section "Verificacion"
  gzip -t -- "$OUT_FILE"
  tar -tzf "$OUT_FILE" >"$STAGE_DIR/listing.txt"
  ok "Integridad del archivo comprimido verificada (gzip + tar)."
  grep -qx 'MANIFEST.txt' "$STAGE_DIR/listing.txt" && grep -qx 'config/app.ini' "$STAGE_DIR/listing.txt" \
    || die "El archivo generado no contiene MANIFEST.txt y config/app.ini."
  if as_data_owner test -f "$db"; then
    grep -qx 'data/data/gitea.db' "$STAGE_DIR/listing.txt" || die "El archivo generado no contiene la base de datos data/data/gitea.db."
  fi
  ok "Contenido minimo verificado (manifiesto, configuracion${schema:+, base de datos})."
  # Escritura atomica del .sha256: se escribe aparte y se renombra al final.
  (cd -- "$BACKUP_DIR" && sha256sum -- "$base.tar.gz" >"$base.tar.gz.sha256.partial" && sha256sum -c --quiet -- "$base.tar.gz.sha256.partial" \
    && mv -- "$base.tar.gz.sha256.partial" "$base.tar.gz.sha256")
  ok "SHA-256 generado y verificado: $OUT_FILE.sha256"
  chmod 600 -- "$OUT_FILE" "$OUT_FILE.sha256"
  STAGE_NAME="terminado"

  if [[ $WAS_RUNNING -eq 1 ]]; then
    if wait_for_gitea 120; then
      ok "Gitea responde de nuevo en $(local_url)."
    else
      warn "Gitea no respondio todavia en $(local_url); revise: docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml logs --tail 100 gitea"
    fi
  fi

  cat <<EOF

Respaldo listo:
  Archivo: $OUT_FILE ($(du -h -- "$OUT_FILE" | awk '{ print $1 }'))
  SHA-256: $(awk '{ print $1 }' "$OUT_FILE.sha256")
Notas:
  - El SHA-256 detecta alteraciones accidentales; NO prueba autenticidad frente a quien pueda modificar archivo y checksum.
  - Un respaldo en el mismo disco NO protege ante perdida o dano fisico del servidor: copie una version CIFRADA
    a otro medio o equipo (docs/BACKUPS.md). Este script no borra respaldos antiguos ni sube nada a la nube.
EOF
}

main
