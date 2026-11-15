#!/usr/bin/env bash
# restore.sh - Restaura Gitea desde un respaldo creado por backup.sh.
#
# Seguridad: verifica SHA-256, integridad y contenido del archivo ANTES de tocar nada; comprueba que la imagen
# necesaria existe ANTES de detener el servicio; exige confirmacion escrita; crea un respaldo de los datos actuales;
# y NUNCA borra los datos existentes: los renombra a data.pre-restore-<fecha> y config.pre-restore-<fecha>.
#
# Si la extraccion, el arranque o la verificacion fallan, devuelve los datos anteriores a su lugar (solo renombra:
# los datos originales no se modifican durante la restauracion, por lo que esa reversion es exacta) y comprueba que
# la instalacion anterior vuelve a funcionar. Si no puede garantizarlo, se detiene, conserva AMBOS conjuntos de datos
# y muestra las instrucciones exactas de recuperacion manual. Nunca da por buena una restauracion solo porque el
# contenedor este encendido.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/restore.sh [--use-backup-version] RUTA/gitea-privado-AAAAMMDD-HHMMSS.tar.gz
  --use-backup-version   Si la version de Gitea del respaldo difiere de la de .env, ajusta .env
                         a la del respaldo (necesario para volver a una version anterior).
Requisitos: instalacion previa (compose.yaml y .env en el directorio de instalacion) y el
archivo .sha256 junto al respaldo. Para una prueba en un entorno separado vea docs/BACKUPS.md.
EOF
}

USE_BACKUP_VERSION=0
BACKUP_FILE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --use-backup-version) USE_BACKUP_VERSION=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; die "Opcion desconocida: $1" ;;
    *) [[ -z $BACKUP_FILE ]] || die "Solo se admite un archivo de respaldo."; BACKUP_FILE=$1; shift ;;
  esac
done
[[ -n $BACKUP_FILE ]] || { usage; exit 2; }

init_context

RESTORE_TS=$(timestamp)
# Los nombres *.pre-restore-<fecha> y *.failed-<fecha> deben ser nuevos: nunca se mueve un directorio "dentro" de otro existente.
restore_n=1
while compgen -G "$INSTALL_DIR/*-restore-$RESTORE_TS*" >/dev/null || compgen -G "$INSTALL_DIR/*.failed-$RESTORE_TS*" >/dev/null; do
  restore_n=$((restore_n + 1))
  RESTORE_TS="$(timestamp)-$restore_n"
done
MOVED_DATA=0
MOVED_CONFIG=0
EXTRACT_STARTED=0
STOPPED_BY_US=0
WAS_RUNNING=0
ENV_CHANGED=0
OLD_VERSION=""
TARGET_VERSION=""
IN_PROGRESS=0      # 1 mientras se modifican los datos; vuelve a 0 solo cuando todo se verifico o se revirtio
PRE_BACKUP=""

# ---------------------------------------------------------------- recuperacion
print_manual_recovery() {
  cat >&2 <<EOF

=== RECUPERACION MANUAL (conserve TODO hasta terminar) ===
Estado: no se pudo garantizar la reversion automatica. Ningun dato fue borrado.
  Datos anteriores:      $INSTALL_DIR/data.pre-restore-$RESTORE_TS  y  $INSTALL_DIR/config.pre-restore-$RESTORE_TS
  Datos restaurados:     $INSTALL_DIR/data  y  $INSTALL_DIR/config  (o *.failed-$RESTORE_TS si ya se apartaron)
  Respaldo de seguridad: ${PRE_BACKUP:-(no se creo: no habia datos previos)}
  Version anterior en .env: ${OLD_VERSION:-desconocida}
Pasos para volver al estado anterior (ejecute en este orden):
  docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml stop gitea
  sudo mv $INSTALL_DIR/data $INSTALL_DIR/data.failed-$RESTORE_TS
  sudo mv $INSTALL_DIR/config $INSTALL_DIR/config.failed-$RESTORE_TS
  sudo mv $INSTALL_DIR/data.pre-restore-$RESTORE_TS $INSTALL_DIR/data
  sudo mv $INSTALL_DIR/config.pre-restore-$RESTORE_TS $INSTALL_DIR/config
  # Solo si .env cambio de version: vuelva a poner GITEA_VERSION=${OLD_VERSION:-<version anterior>} en $INSTALL_DIR/.env
  docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml up -d gitea
Si algun 'mv' indica que el destino ya existe, apartelo antes con otro nombre (nunca con rm). Si indica que el ORIGEN
no existe, ese paso ya se hizo: omitalo. Luego verifique con
  $COMMON_DIR/status.sh
EOF
}

# Devuelve 0 solo si TODO el procedimiento de reversion se completo y la instalacion anterior volvio a funcionar.
rollback_to_previous() {
  local d moved
  set +e
  printf '[ERROR] Se intenta volver al estado anterior (solo renombrados; nada se borra)...\n' >&2
  if [[ $STOPPED_BY_US -eq 1 || $EXTRACT_STARTED -eq 1 ]] || container_running; then
    dc stop -t 60 gitea >/dev/null 2>&1 || { printf '[ERROR] No se pudo detener Gitea.\n' >&2; return 1; }
  fi
  for d in data config; do
    if [[ $EXTRACT_STARTED -eq 1 && -e $INSTALL_DIR/$d ]]; then
      as_data_owner mv -- "$INSTALL_DIR/$d" "$INSTALL_DIR/$d.failed-$RESTORE_TS" || { printf '[ERROR] No se pudo apartar %s.\n' "$d" >&2; return 1; }
    fi
    moved=$MOVED_DATA
    [[ $d == "config" ]] && moved=$MOVED_CONFIG
    if [[ $moved -eq 1 ]]; then
      as_data_owner mv -- "$INSTALL_DIR/$d.pre-restore-$RESTORE_TS" "$INSTALL_DIR/$d" || { printf '[ERROR] No se pudo devolver %s a su lugar.\n' "$d" >&2; return 1; }
    elif [[ ! -e $INSTALL_DIR/$d ]]; then
      as_root install -d -m 750 -o "$GITEA_UID" -g "$GITEA_GID" -- "$INSTALL_DIR/$d" || return 1
    fi
  done
  MOVED_DATA=0; MOVED_CONFIG=0; EXTRACT_STARTED=0
  if [[ $ENV_CHANGED -eq 1 ]]; then
    env_set "$INSTALL_DIR/.env" GITEA_VERSION "$OLD_VERSION" || return 1
    GITEA_VERSION=$OLD_VERSION
    ENV_CHANGED=0
  fi
  if [[ $WAS_RUNNING -eq 1 ]]; then
    dc up -d gitea >/dev/null 2>&1 || { printf '[ERROR] No se pudo iniciar Gitea con los datos anteriores.\n' >&2; return 1; }
    wait_for_healthy 180 || { printf '[ERROR] Gitea con los datos anteriores no llego a estar saludable.\n' >&2; return 1; }
    [[ $(running_gitea_version) == "$OLD_VERSION" ]] || { printf '[ERROR] La version en ejecucion no es la anterior (%s).\n' "$OLD_VERSION" >&2; return 1; }
  fi
  return 0
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [[ $rc -ne 0 && $IN_PROGRESS -eq 1 ]]; then
    if rollback_to_previous; then
      IN_PROGRESS=0
      cat >&2 <<EOF

[ERROR] LA RESTAURACION FALLO y se volvio al estado anterior (verificado: Gitea ${OLD_VERSION} saludable).
  Lo restaurado a medias se conservo en $INSTALL_DIR/data.failed-$RESTORE_TS y config.failed-$RESTORE_TS (revise y borre a mano si quiere).
  El respaldo de seguridad previo es: ${PRE_BACKUP:-(no hacia falta)}
EOF
    else
      print_manual_recovery
      rc=2
    fi
  elif [[ $rc -ne 0 && $STOPPED_BY_US -eq 1 ]] && ! container_running; then
    dc start gitea >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

# ---------------------------------------------------------------- validacion del archivo
# Rechaza rutas absolutas, "..", enlaces peligrosos, dispositivos y entradas fuera de data/config/meta.
validate_archive_entries() {
  local list bad
  list=$(tar -tzf "$BACKUP_FILE")
  bad=$(awk '
    $0 ~ /^\// || $0 ~ /(^|\/)\.\.(\/|$)/ { print "ruta insegura: " $0; next }
    $0 !~ /^(MANIFEST\.txt|meta(\/.*)?|data(\/.*)?|config(\/.*)?)$/ { print "entrada inesperada: " $0 }
  ' <<<"$list")
  [[ -z $bad ]] || { printf '%s\n' "$bad" | head -n 10 >&2; return 1; }
  grep -qx 'MANIFEST.txt' <<<"$list" || { echo "Falta MANIFEST.txt" >&2; return 1; }
  grep -qx 'config/app.ini' <<<"$list" || { echo "Falta config/app.ini" >&2; return 1; }
  grep -Eq '^data/?$' <<<"$list" || { echo "Falta data/" >&2; return 1; }
  if ! grep -qx 'data/data/gitea.db' <<<"$list"; then
    warn "El respaldo no contiene data/data/gitea.db (base de datos SQLite): se hizo antes de completar el asistente de Gitea."
    HAS_DB=0
  else
    HAS_DB=1
  fi
  bad=$(tar -tvzf "$BACKUP_FILE" | awk '
    substr($0, 1, 1) ~ /[cbp]/ { print "archivo especial: " $0; next }
    substr($0, 1, 1) == "l" {
      t = $0; sub(/^.* -> /, "", t)
      if (t ~ /^\// || t ~ /(^|\/)\.\.(\/|$)/) print "enlace simbolico inseguro: " $0
    }
    substr($0, 1, 1) == "h" {
      t = $0; sub(/^.* link to /, "", t)
      if (t !~ /^(data|config|meta)(\/|$)/) print "enlace duro inseguro: " $0
    }
  ')
  [[ -z $bad ]] || { printf '%s\n' "$bad" | head -n 10 >&2; return 1; }
}

manifest_value() {
  sed -n "s/^$1=//p" <<<"$MANIFEST" | sed -n '1p'
}

# ---------------------------------------------------------------- verificacion posterior
# Devuelve 0 solo si la aplicacion, la base de datos y los repositorios restaurados estan bien.
verify_restored() {
  local count_db count_disk users rc=0
  if wait_for_healthy 180; then
    ok "Healthcheck de Docker: healthy."
  else
    fail "El healthcheck de Docker no llego a 'healthy' (estado: $(container_health))."
    return 1
  fi
  wait_for_gitea 60 && ok "La web responde en $(local_url)." || { fail "La web no responde en $(local_url)."; return 1; }
  if [[ $(running_gitea_version) == "$TARGET_VERSION" ]]; then
    ok "Version en ejecucion: $TARGET_VERSION"
  else
    fail "La version en ejecucion ('$(running_gitea_version)') no es la esperada ($TARGET_VERSION)."
    return 1
  fi
  if [[ $HAS_DB -eq 1 ]]; then
    if sqlite_integrity_ok "$(gitea_db_path)"; then
      ok "Base de datos SQLite: integrity_check correcto."
    else
      fail "La base de datos restaurada NO supera integrity_check."
      return 1
    fi
    if users=$(dc exec -T gitea gitea -c /etc/gitea/app.ini admin user list 2>&1); then
      ok "Gitea abre la base de datos y lista usuarios ($(awk 'NR > 1 && NF { n++ } END { print n + 0 }' <<<"$users") usuario(s))."
    else
      fail "Gitea no pudo listar usuarios con la base restaurada: $(head -n 2 <<<"$users")"
      return 1
    fi
    count_db=$(db_repo_count)
    count_disk=$(disk_repo_count)
    if [[ -z $count_db ]]; then
      warn "No se pudo contar los repositorios de la base de datos."
    elif [[ $count_db == "$count_disk" ]]; then
      ok "Repositorios: $count_db en la base de datos y $count_disk en disco."
    elif [[ $count_db -gt 0 && $count_disk -eq 0 ]]; then
      fail "La base de datos declara $count_db repositorio(s) pero no hay ninguno en disco."
      return 1
    else
      warn "Repositorios: $count_db en la base de datos y $count_disk en disco (revise: puede haber repositorios vacios o huerfanos)."
    fi
  else
    info "Sin base de datos en el respaldo: se omite la verificacion de usuarios y repositorios."
  fi
  if dc exec -T gitea gitea -c /etc/gitea/app.ini admin regenerate hooks >/dev/null 2>&1; then
    ok "Hooks de Git regenerados."
  else
    warn "No se pudieron regenerar los hooks. Ejecute: docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml exec gitea gitea -c /etc/gitea/app.ini admin regenerate hooks"
  fi
  return $rc
}

HAS_DB=0

main() {
  need_cmd docker; need_cmd tar; need_cmd gzip; need_cmd sha256sum; need_cmd flock
  [[ -f $INSTALL_DIR/compose.yaml && -f $INSTALL_DIR/.env ]] || die "Primero instale (scripts/install.sh): falta compose.yaml o .env en $INSTALL_DIR."
  validate_config || die "El .env actual no es valido; corrijalo antes de restaurar."
  OLD_VERSION=$GITEA_VERSION

  section "Validacion del respaldo"
  [[ -f $BACKUP_FILE ]] || die "No existe el archivo: $BACKUP_FILE"
  BACKUP_FILE=$(realpath -- "$BACKUP_FILE")
  [[ -f $BACKUP_FILE.sha256 ]] || die "Falta $BACKUP_FILE.sha256. No se restaura sin verificar el SHA-256."
  (cd -- "$(dirname -- "$BACKUP_FILE")" && sha256sum -c --quiet -- "$(basename -- "$BACKUP_FILE").sha256") || die "El SHA-256 NO coincide. El respaldo esta danado o fue alterado."
  ok "SHA-256 correcto (detecta dano accidental; no prueba autenticidad: use solo respaldos de origen confiable)."
  gzip -t -- "$BACKUP_FILE" || die "El archivo comprimido esta danado."
  tar -tzf "$BACKUP_FILE" >/dev/null || die "El archivo tar esta danado."
  ok "Integridad gzip y tar correcta."
  validate_archive_entries || die "El contenido del respaldo no es seguro o no tiene la estructura esperada."
  ok "Estructura y rutas del respaldo validadas (sin rutas peligrosas, enlaces inseguros ni entradas especiales)."

  MANIFEST=$(tar -xzOf "$BACKUP_FILE" MANIFEST.txt)
  local fmt bversion created
  fmt=$(manifest_value BACKUP_FORMAT)
  bversion=$(manifest_value GITEA_VERSION)
  created=$(manifest_value CREATED_AT)
  [[ $fmt == "$BACKUP_FORMAT_VERSION" ]] || die "Formato de respaldo no compatible ('$fmt'; se esperaba $BACKUP_FORMAT_VERSION)."
  is_version "$bversion" || die "El respaldo no declara una version de Gitea valida ('$bversion')."
  info "Respaldo creado: $created | Gitea $bversion | Version configurada ahora: $GITEA_VERSION"

  TARGET_VERSION=$GITEA_VERSION
  if [[ $bversion != "$GITEA_VERSION" ]]; then
    if version_gt "$bversion" "$GITEA_VERSION"; then
      warn "El respaldo es de una version MAS NUEVA ($bversion) que la configurada ($GITEA_VERSION): su base de datos ya fue migrada y una version anterior de Gitea NO debe abrirla."
    else
      warn "El respaldo es de una version ANTERIOR ($bversion) a la configurada ($GITEA_VERSION)."
    fi
    if [[ $USE_BACKUP_VERSION -ne 1 ]]; then
      die "Las versiones difieren. Repita con --use-backup-version para fijar GITEA_VERSION=$bversion en .env (la restauracion usara esa imagen), o cambie .env usted mismo."
    fi
    TARGET_VERSION=$bversion
    info "Se usara la imagen $(image_ref "$bversion") (GITEA_VERSION=$bversion en .env tras restaurar los datos)."
  else
    ok "La version del respaldo coincide con la configurada."
  fi

  section "Imagenes Docker (se comprueban antes de detener nada)"
  ensure_image_available "$(image_ref "$TARGET_VERSION")" || die "La imagen $(image_ref "$TARGET_VERSION") no esta disponible ni se pudo descargar. No se modifico nada."
  ok "Imagen necesaria disponible: $(image_ref "$TARGET_VERSION")"
  if [[ $TARGET_VERSION != "$OLD_VERSION" ]]; then
    ensure_image_available "$(image_ref "$OLD_VERSION")" || die "No esta disponible la imagen actual $(image_ref "$OLD_VERSION"), necesaria para revertir si algo falla. No se modifico nada."
    ok "Imagen actual disponible para una eventual reversion: $(image_ref "$OLD_VERSION")"
  fi

  section "Espacio y estado actual"
  local need_kb avail has_data=0
  need_kb=$(tar -tvzf "$BACKUP_FILE" | awk '$1 ~ /^-/ { s += $3 } END { printf "%d", s / 1024 }')
  avail=$(avail_kb "$INSTALL_DIR")
  info "Tamano a extraer: $(human_kb "$need_kb") | Espacio libre en $INSTALL_DIR: $(human_kb "$avail")"
  (( avail > need_kb + need_kb / 10 + 10240 )) || die "Espacio insuficiente para extraer el respaldo en $INSTALL_DIR."
  if [[ -n $(as_data_owner ls -A -- "$INSTALL_DIR/data" 2>/dev/null || true) || -n $(as_data_owner ls -A -- "$INSTALL_DIR/config" 2>/dev/null || true) ]]; then
    has_data=1
  fi
  if container_running; then
    WAS_RUNNING=1
    warn "Gitea esta en ejecucion: se detendra durante la restauracion (solo este servicio)."
  fi
  if [[ $has_data -eq 1 ]]; then
    warn "Existen datos actuales en $INSTALL_DIR/data y config. NO se borraran: se renombraran a *.pre-restore-$RESTORE_TS."
  else
    info "No hay datos actuales; se restaura sobre una instalacion vacia."
  fi

  mkdir -p -- "$BACKUP_DIR"
  exec 9>"$BACKUP_DIR/.backup.lock"
  flock -n 9 || die "Hay otro respaldo o restauracion en curso (bloqueo: $BACKUP_DIR/.backup.lock)."
  export GITEA_LOCK_INHERITED=1

  cat <<EOF

Se va a restaurar:   $BACKUP_FILE
Destino:             $INSTALL_DIR (data/ y config/)
Imagen que se usara: $(image_ref "$TARGET_VERSION")
Respaldo previo:     $( [[ $has_data -eq 1 ]] && echo "si, automatico (--label pre-restore)" || echo "no hace falta" )
Si algo falla:       se intenta volver al estado anterior; si no es seguro, se conserva todo y se indican los pasos manuales.
EOF
  confirm_phrase "RESTAURAR" "Escriba RESTAURAR (en mayusculas) para continuar: " || die "Cancelado: no se modifico nada."

  if [[ $has_data -eq 1 ]]; then
    section "Respaldo de seguridad previo"
    local before after
    before=$(ls -1 -- "$BACKUP_DIR"/*-pre-restore.tar.gz 2>/dev/null || true)
    env GITEA_INSTALL_DIR="$INSTALL_DIR" GITEA_LOCK_INHERITED=1 "$COMMON_DIR/backup.sh" --label pre-restore --dir "$BACKUP_DIR" --allow-corrupt-db \
      || die "No se pudo crear el respaldo previo; se aborta sin cambios."
    after=$(ls -1t -- "$BACKUP_DIR"/*-pre-restore.tar.gz 2>/dev/null || true)
    PRE_BACKUP=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | sed -n '1p')
    [[ -n $PRE_BACKUP && -f $PRE_BACKUP ]] || die "No se localizo el respaldo previo recien creado; se aborta sin cambios."
    ok "Respaldo de seguridad: $PRE_BACKUP"
  fi

  trap on_exit EXIT
  trap 'exit 130' INT TERM

  section "Restauracion"
  IN_PROGRESS=1
  if [[ $WAS_RUNNING -eq 1 ]]; then
    STOPPED_BY_US=1
    dc stop -t 60 gitea >/dev/null
    ok "Gitea detenido (solo este servicio)."
  fi

  if [[ -e $INSTALL_DIR/data ]]; then
    as_data_owner mv -- "$INSTALL_DIR/data" "$INSTALL_DIR/data.pre-restore-$RESTORE_TS"
    MOVED_DATA=1
  fi
  if [[ -e $INSTALL_DIR/config ]]; then
    as_data_owner mv -- "$INSTALL_DIR/config" "$INSTALL_DIR/config.pre-restore-$RESTORE_TS"
    MOVED_CONFIG=1
  fi
  ok "Datos anteriores conservados como *.pre-restore-$RESTORE_TS"

  EXTRACT_STARTED=1
  as_data_owner tar --numeric-owner -xzpf "$BACKUP_FILE" -C "$INSTALL_DIR" data config
  [[ -d $INSTALL_DIR/data && -d $INSTALL_DIR/config ]] || die "La extraccion no produjo data/ y config/."
  as_root chown -R "$GITEA_UID:$GITEA_GID" -- "$INSTALL_DIR/data" "$INSTALL_DIR/config"
  as_root chmod 750 -- "$INSTALL_DIR/data" "$INSTALL_DIR/config"
  as_root find "$INSTALL_DIR/data" "$INSTALL_DIR/config" -xdev -type f -perm /6000 -exec chmod ug-s {} +
  ok "Datos restaurados con permisos para UID $GITEA_UID (sin bits setuid/setgid)."

  if [[ $TARGET_VERSION != "$OLD_VERSION" ]]; then
    env_set "$INSTALL_DIR/.env" GITEA_VERSION "$TARGET_VERSION"
    ENV_CHANGED=1
    GITEA_VERSION=$TARGET_VERSION
    ok ".env actualizado: GITEA_VERSION=$TARGET_VERSION"
  fi

  section "Inicio y verificacion (aplicacion, base de datos y repositorios)"
  dc up -d gitea
  if ! verify_restored; then
    dc logs --tail 60 gitea || true
    die "La verificacion posterior a la restauracion fallo."
  fi
  IN_PROGRESS=0
  trap - EXIT

  cat <<EOF

RESTAURACION VERIFICADA: aplicacion saludable (version $TARGET_VERSION), base de datos integra y repositorios presentes.
Verifique ademas usted mismo:
  Usuarios:      docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml exec gitea gitea -c /etc/gitea/app.ini admin user list
  Repositorios:  entre a la web y abra sus repositorios; haga 'git clone' de uno desde Windows.
  Estado:        $COMMON_DIR/status.sh
Los datos anteriores siguen en $INSTALL_DIR/data.pre-restore-$RESTORE_TS y $INSTALL_DIR/config.pre-restore-$RESTORE_TS
(y el respaldo de seguridad ${PRE_BACKUP:-no creado}). Este script NUNCA los borra: cuando confirme que todo esta bien,
puede eliminarlos usted manualmente.
EOF
}

main
