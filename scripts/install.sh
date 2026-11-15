#!/usr/bin/env bash
# install.sh - Instalacion (o repeticion segura) de Gitea privado en Ubuntu.
# No ejecuta nada destructivo. No modifica otros contenedores ni Tailscale.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/install.sh [--yes] [-h]
  --yes   Acepta las confirmaciones NO destructivas (por ejemplo, copiar archivos del proyecto).
Variables opcionales: GITEA_INSTALL_DIR (por defecto /srv/gitea-privado).

Pasos: preflight -> carpetas -> copia del proyecto -> .env -> permisos -> validar Compose
       -> descargar imagen -> iniciar Gitea -> verificar -> instrucciones.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Opcion desconocida: $1" ;;
  esac
done

PROJECT_ITEMS=(compose.yaml .env.example .gitignore .gitattributes README.md ENTREGA.md REVISION-SEGURIDAD.md scripts windows docs tests)

reload_context() {
  local keep=$INSTALL_DIR k
  for k in "${ENV_ALLOWED_KEYS[@]}"; do
    unset "$k"
  done
  GITEA_INSTALL_DIR=$keep
  PREFERRED_ENV_FILE=""
  init_context
}

ensure_dirs() {
  section "Directorios"
  local dir
  for dir in "$INSTALL_DIR" "$BACKUP_DIR"; do
    if [[ ! -d $dir ]]; then
      as_root mkdir -p -- "$dir"
      as_root chown "$(id -u):$(id -g)" -- "$dir"
      ok "Creado: $dir (propietario: $(id -un))"
    elif [[ ! -w $dir ]]; then
      die "$dir existe pero no es escribible por $(id -un). Ajuste su propietario (sudo chown $(id -un): $dir)."
    else
      ok "Ya existe: $dir"
    fi
  done
  chmod 750 -- "$INSTALL_DIR" 2>/dev/null || true
  chmod 700 -- "$BACKUP_DIR" 2>/dev/null || true
}

sync_project() {
  section "Archivos del proyecto"
  local real_src real_dst item
  real_src=$(realpath -- "$PROJECT_DIR")
  real_dst=$(realpath -- "$INSTALL_DIR")
  if [[ $real_src == "$real_dst" ]]; then
    ok "Se ejecuta desde el directorio de instalacion: no hace falta copiar."
    return 0
  fi
  local present=()
  for item in "${PROJECT_ITEMS[@]}"; do
    [[ -e $PROJECT_DIR/$item ]] && present+=("$item")
  done
  local differs=0
  if [[ -f $INSTALL_DIR/compose.yaml ]]; then
    for item in "${present[@]}"; do
      if [[ -e $INSTALL_DIR/$item ]] && ! diff -rq -- "$PROJECT_DIR/$item" "$INSTALL_DIR/$item" >/dev/null 2>&1; then
        differs=1
      fi
    done
    if [[ $differs -eq 0 ]]; then
      ok "Los archivos instalados ya coinciden con los del proyecto."
      return 0
    fi
    warn "Los archivos del proyecto difieren de los instalados en $INSTALL_DIR."
    if ! confirm "Actualizar scripts/compose/documentacion en $INSTALL_DIR (no toca .env, data ni config)?"; then
      info "Se conservan los archivos instalados."
      return 0
    fi
  fi
  tar -C "$PROJECT_DIR" -cf - "${present[@]}" | tar -C "$INSTALL_DIR" -xf - --no-same-owner
  chmod +x "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true
  ok "Proyecto copiado a $INSTALL_DIR (sin .env, data ni config)."
}

ensure_env() {
  section "Configuracion (.env)"
  if [[ -f $INSTALL_DIR/.env ]]; then
    ok ".env existente conservado: $INSTALL_DIR/.env"
  elif [[ -f $PROJECT_DIR/.env && $(realpath -- "$PROJECT_DIR") != "$(realpath -- "$INSTALL_DIR")" ]]; then
    install -m 600 -- "$PROJECT_DIR/.env" "$INSTALL_DIR/.env"
    ok ".env copiado desde $PROJECT_DIR (permisos 600)."
  else
    info "No existe .env: se ejecuta configure.sh."
    local args=(--target "$INSTALL_DIR")
    [[ $ASSUME_YES -eq 1 ]] && args+=(--yes)
    GITEA_INSTALL_DIR="$INSTALL_DIR" "$COMMON_DIR/configure.sh" "${args[@]}"
  fi
  reload_context
  CHECK_ERRORS=0
  validate_config || die "El .env no es valido. Ejecute scripts/configure.sh --regenerate --target $INSTALL_DIR"
  local perms
  perms=$(stat -c '%a' "$INSTALL_DIR/.env")
  if [[ $perms != "600" ]]; then
    chmod 600 "$INSTALL_DIR/.env"
    ok "Permisos de .env ajustados a 600."
  fi
  ok "Configuracion valida (version Gitea $GITEA_VERSION, DNS $GITEA_TS_DNS)."
}

prepare_persistence() {
  section "Persistencia (permisos para Gitea rootless, UID $GITEA_UID)"
  local d uid
  for d in data config; do
    if [[ ! -d $INSTALL_DIR/$d ]]; then
      as_root install -d -m 750 -o "$GITEA_UID" -g "$GITEA_GID" -- "$INSTALL_DIR/$d"
      ok "Creado $INSTALL_DIR/$d"
    else
      uid=$(as_data_owner stat -c '%u' -- "$INSTALL_DIR/$d")
      if [[ $uid != "$GITEA_UID" ]]; then
        warn "$INSTALL_DIR/$d pertenece al UID $uid; se ajusta a $GITEA_UID:$GITEA_GID."
        as_root chown -R "$GITEA_UID:$GITEA_GID" -- "$INSTALL_DIR/$d"
      else
        ok "$INSTALL_DIR/$d ya tiene el propietario correcto."
      fi
    fi
  done
}

validate_compose() {
  section "Docker Compose"
  local out
  out=$(dc config 2>&1) || die "compose.yaml no es valido: $out"
  ok "compose.yaml valido para el proyecto '$PROJECT_NAME'."
  if grep -Eq 'image: .*:latest' <<<"$out"; then
    die "La imagen no puede usar 'latest'."
  fi
  grep -Fq "image: $(image_ref "$GITEA_VERSION")" <<<"$out" || die "La imagen resuelta no coincide con $(image_ref "$GITEA_VERSION")."
  ok "Imagen fija: $(image_ref "$GITEA_VERSION")"
  # Ningun puerto puede quedar publicado fuera de 127.0.0.1 (se comprueba sobre la configuracion ya resuelta).
  if grep -Eq 'host_ip: *(0\.0\.0\.0|::|"")' <<<"$out" || [[ $(grep -c 'host_ip: *127\.0\.0\.1' <<<"$out" || true) -ne 2 ]]; then
    die "compose.yaml publicaria puertos fuera de 127.0.0.1 (se esperaban exactamente 2, ambos en 127.0.0.1)."
  fi
  ok "Compose publica solo 127.0.0.1:$GITEA_WEB_PORT (HTTP) y 127.0.0.1:$GITEA_SSH_LOCAL_PORT (SSH)."
}

start_gitea() {
  section "Imagen e inicio"
  info "Descargando imagen $(image_ref "$GITEA_VERSION") ..."
  dc pull gitea || die "No se pudo descargar la imagen. Revise la conexion a internet."
  if container_running; then
    info "Gitea ya esta en ejecucion."
    if confirm "Aplicar 'docker compose up -d' (solo recrea el contenedor si cambio la configuracion)?"; then
      dc up -d gitea
    else
      info "No se reinicia nada."
    fi
  else
    dc up -d gitea
  fi
}

verify_gitea() {
  section "Verificacion"
  local id restarts_before restarts_after
  sleep 5
  container_running || { dc logs --tail 50 gitea || true; die "El contenedor no esta en ejecucion."; }
  id=$(container_id)
  restarts_before=$(docker inspect -f '{{.RestartCount}}' "$id")
  sleep 8
  restarts_after=$(docker inspect -f '{{.RestartCount}}' "$id")
  if container_running && [[ $restarts_before == "$restarts_after" ]]; then
    ok "El contenedor permanece en ejecucion (reinicios: $restarts_after)."
  else
    dc logs --tail 50 gitea || true
    die "El contenedor se reinicia en bucle. Revise los registros anteriores."
  fi
  if wait_for_healthy 150; then
    ok "Healthcheck de Docker: healthy."
  else
    dc logs --tail 50 gitea || true
    die "El healthcheck de Docker no llego a 'healthy' (estado: $(container_health)). Revise los registros anteriores."
  fi
  if wait_for_gitea 60; then
    ok "El servicio web responde en $(local_url)"
  else
    dc logs --tail 50 gitea || true
    die "El servicio web no respondio en $(local_url)."
  fi
  local running_version
  running_version=$(running_gitea_version)
  if [[ $running_version == "$GITEA_VERSION" ]]; then
    ok "Version en ejecucion: $running_version"
  else
    die "El contenedor ejecuta la version '${running_version:-desconocida}' y se esperaba $GITEA_VERSION."
  fi
  ports_loopback_only || die "Los puertos publicados no son exactamente 127.0.0.1:$GITEA_WEB_PORT y 127.0.0.1:$GITEA_SSH_LOCAL_PORT: $(container_ports | paste -sd, -)"
  ok "Puertos reales publicados solo en 127.0.0.1 (web $GITEA_WEB_PORT, ssh $GITEA_SSH_LOCAL_PORT)."
  local banner
  banner=$(ssh_banner 127.0.0.1 "$GITEA_SSH_LOCAL_PORT")
  [[ $banner == SSH-* ]] || die "El SSH integrado de Gitea no responde en 127.0.0.1:$GITEA_SSH_LOCAL_PORT."
  ok "SSH de Git responde en 127.0.0.1:$GITEA_SSH_LOCAL_PORT ($banner)."
  verify_persistence
}

# Persistencia: los bind mounts apuntan a data/ y config/ del disco, el contenedor corre como UID 1000 y puede escribir.
verify_persistence() {
  local id mounts real
  id=$(container_id)
  real=$(realpath -- "$INSTALL_DIR")
  mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' "$id")
  if grep -Fxq "$real/data /var/lib/gitea" <<<"$mounts" && grep -Fxq "$real/config /etc/gitea" <<<"$mounts"; then
    ok "Persistencia: $real/data -> /var/lib/gitea y $real/config -> /etc/gitea."
  else
    die "Los bind mounts de persistencia no son los esperados: $mounts"
  fi
  if dc exec -T gitea sh -c 'test "$(id -u)" = 1000 && test -w /var/lib/gitea && test -w /etc/gitea' >/dev/null 2>&1; then
    ok "Permisos rootless: el contenedor corre como UID $GITEA_UID y puede escribir en data/ y config/."
  else
    die "El contenedor no puede escribir en data/ o config/ como UID $GITEA_UID. Revise: sudo chown -R $GITEA_UID:$GITEA_GID $INSTALL_DIR/data $INSTALL_DIR/config"
  fi
  if as_data_owner test -d "$INSTALL_DIR/data/git" || as_data_owner test -d "$INSTALL_DIR/data/data"; then
    ok "Gitea ya escribio sus datos en $INSTALL_DIR/data (persistencia en disco confirmada)."
  else
    die "Gitea no creo datos en $INSTALL_DIR/data."
  fi
}

show_next_steps() {
  local locked=0
  installer_locked && locked=1
  report_states
  section "Resultado de la instalacion"
  if (( STATE_FAILS > 0 )); then
    fail "Hay etapas con FALLA: la instalacion NO esta completa. Revise la lista anterior y scripts/status.sh."
  else
    ok "Contenedor, healthcheck, web local, puertos y persistencia verificados. Quedan pasos pendientes (marcados arriba)."
  fi
  cat <<EOF

Servicio local:   $(local_url)   (solo 127.0.0.1)
SSH local:        127.0.0.1:$GITEA_SSH_LOCAL_PORT   (solo 127.0.0.1)
URL privada:      $GITEA_ROOT_URL   (tras activar Tailscale Serve)
SSH de Git:       ssh://git@$GITEA_SSH_DOMAIN:$GITEA_SSH_PORT/<usuario>/<repo>.git   (tras activar Tailscale Serve)
Datos:            $INSTALL_DIR/data  y  $INSTALL_DIR/config
Respaldos:        $BACKUP_DIR
EOF
  if [[ $locked -eq 0 ]]; then
    cat <<EOF

PENDIENTE (hacer ANTES de publicar en la tailnet): asistente de primera instalacion = crear la cuenta administradora.
  Use un tunel SSH administrativo, para que el asistente NO quede visible a otros miembros de la tailnet:
      ssh -L $GITEA_WEB_PORT:127.0.0.1:$GITEA_WEB_PORT <USUARIO_ADMIN>@<HOST_ADMIN_DEL_SERVIDOR>
      y abra http://localhost:$GITEA_WEB_PORT en su navegador.
  En el asistente: deje SQLite3 y las URL precargadas; en "Configuracion opcional > Cuenta de
  administrador" cree su usuario con una contrasena nueva (solo se escribe en el navegador).
  Al terminar puede redirigirle a $GITEA_ROOT_URL (aun no publicada): es normal; compruebe con scripts/status.sh.
  Guia completa: docs/INSTALACION-MANANA.md (Fase 7).
EOF
  else
    info "El asistente de instalacion ya fue completado (INSTALL_LOCK activo)."
  fi
  cat <<EOF

Siguientes pasos:
  1. Publicar HTTPS y SSH en la tailnet:  $INSTALL_DIR/scripts/configure-tailscale.sh --dry-run   y luego sin --dry-run
  2. Ver estado y registros:         $INSTALL_DIR/scripts/status.sh
     docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml logs -f --tail 100 gitea
  3. Pruebas de funcionamiento:      $INSTALL_DIR/scripts/smoke-test.sh
  4. Primer respaldo:                $INSTALL_DIR/scripts/backup.sh
EOF
  (( STATE_FAILS == 0 )) || exit 1
}

main() {
  init_context
  printf '%sInstalacion de Gitea privado%s\n' "$C_BOLD" "$C_RESET"
  info "Instalacion: $INSTALL_DIR | Respaldos: $BACKUP_DIR | Proyecto Compose: $PROJECT_NAME"

  section "Comprobaciones previas"
  "$COMMON_DIR/preflight.sh" || die "El preflight detecto errores criticos. No se instala nada."

  need_cmd docker
  ensure_dirs
  sync_project
  ensure_env
  prepare_persistence
  validate_compose
  start_gitea
  verify_gitea
  show_next_steps
}

main
