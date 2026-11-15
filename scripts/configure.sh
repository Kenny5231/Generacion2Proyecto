#!/usr/bin/env bash
# configure.sh - Genera (o valida) el archivo .env con los datos reales del servidor.
# - Obtiene IP y DNS de Tailscale automaticamente (solo lectura; no modifica Tailscale).
# - Es repetible: si .env ya existe solo lo valida, salvo que se use --regenerate
#   (en ese caso guarda una copia .env.bak-<fecha> y conserva los valores personalizados).
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/configure.sh [opciones]
  --target DIR        Carpeta donde escribir .env (por defecto la carpeta del proyecto).
  --regenerate        Regenera .env (guarda copia de seguridad del anterior).
  --ts-ip IP          (obsoleta, se ignora) Docker ya no usa la IP de Tailscale.
  --ts-dns NOMBRE     Nombre DNS .ts.net (por defecto se detecta con 'tailscale status').
  --https-port N      Puerto HTTPS de Tailscale Serve: 443, 8443 o 10000 (defecto 443).
  --web-port N        Puerto HTTP local en 127.0.0.1 (defecto 3090).
  --ssh-local-port N  Puerto SSH local en 127.0.0.1 (defecto 2222).
  --ssh-port N        Puerto SSH visible en la tailnet por Tailscale Serve (defecto 2222).
  --install-dir DIR   Ruta de instalacion (defecto /srv/gitea-privado).
  --backup-dir DIR    Ruta de respaldos (defecto /srv/backups/gitea-privado).
  --yes               No preguntar (usa valores por defecto o los indicados).
  -h, --help          Muestra esta ayuda.
EOF
}

TARGET="$PROJECT_DIR"
REGENERATE=0
ARG_TS_IP=""; ARG_TS_DNS=""; ARG_HTTPS=""; ARG_WEB=""; ARG_SSH=""; ARG_SSH_LOCAL=""; ARG_INSTALL=""; ARG_BACKUP=""

need_value() { [[ $# -ge 2 && -n ${2:-} ]] || die "La opcion $1 requiere un valor."; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --target) need_value "$@"; TARGET=$2; shift 2 ;;
    --regenerate) REGENERATE=1; shift ;;
    --ts-ip) need_value "$@"; ARG_TS_IP=$2; shift 2 ;;
    --ts-dns) need_value "$@"; ARG_TS_DNS=$2; shift 2 ;;
    --https-port) need_value "$@"; ARG_HTTPS=$2; shift 2 ;;
    --web-port) need_value "$@"; ARG_WEB=$2; shift 2 ;;
    --ssh-port) need_value "$@"; ARG_SSH=$2; shift 2 ;;
    --ssh-local-port) need_value "$@"; ARG_SSH_LOCAL=$2; shift 2 ;;
    --install-dir) need_value "$@"; ARG_INSTALL=$2; shift 2 ;;
    --backup-dir) need_value "$@"; ARG_BACKUP=$2; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Opcion desconocida: $1" ;;
  esac
done

[[ -d $TARGET ]] || die "No existe la carpeta de destino: $TARGET"
TARGET=$(cd -- "$TARGET" && pwd -P)
TARGET_ENV="$TARGET/.env"
[[ -f $TARGET/compose.yaml ]] || die "No se encontro $TARGET/compose.yaml"

[[ -z $ARG_INSTALL ]] || GITEA_INSTALL_DIR=$ARG_INSTALL
[[ -z $ARG_BACKUP ]] || GITEA_BACKUP_DIR=$ARG_BACKUP
PREFERRED_ENV_FILE="$TARGET_ENV"
init_context
COMPOSE_DIR="$TARGET"

check_compose() {
  if ! have docker; then
    warn "Docker no esta disponible: no se pudo validar compose.yaml."
    return 0
  fi
  local out
  if out=$(dc config -q 2>&1); then
    ok "Docker Compose valida la configuracion."
  else
    fail "Docker Compose rechazo la configuracion: $out"
  fi
}

detect_tailscale() {
  DET_IP=""; DET_DNS=""
  if ! have tailscale; then
    return 0
  fi
  if [[ $(ts_state) != "Running" ]]; then
    return 0
  fi
  DET_IP=$(ts_ip4)
  DET_DNS=$(ts_self_dns)
}

write_env() {
  local tmp
  tmp=$(mktemp "$TARGET/.env.XXXXXX")
  chmod 600 "$tmp"
  {
    printf '# Generado por scripts/configure.sh el %s. No lo suba a Git.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# No contiene contrasenas ni claves. Vuelva a ejecutar configure.sh --regenerate para actualizarlo.\n\n'
    printf 'GITEA_VERSION=%s\n' "$GITEA_VERSION"
    printf 'GITEA_INSTALL_DIR=%s\n' "$INSTALL_DIR"
    printf 'GITEA_BACKUP_DIR=%s\n' "$BACKUP_DIR"
    printf 'GITEA_TS_DNS=%s\n' "$GITEA_TS_DNS"
    printf 'GITEA_TS_HTTPS_PORT=%s\n' "$GITEA_TS_HTTPS_PORT"
    printf 'GITEA_ROOT_URL=%s\n' "$GITEA_ROOT_URL"
    printf 'GITEA_SSH_DOMAIN=%s\n' "$GITEA_SSH_DOMAIN"
    printf 'GITEA_WEB_PORT=%s\n' "$GITEA_WEB_PORT"
    printf 'GITEA_SSH_LOCAL_PORT=%s\n' "$GITEA_SSH_LOCAL_PORT"
    printf 'GITEA_SSH_PORT=%s\n' "$GITEA_SSH_PORT"
    printf 'TZ=%s\n' "$TZ"
    if [[ $PROJECT_NAME != "$DEFAULT_PROJECT_NAME" ]]; then
      printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJECT_NAME"
    fi
    if [[ -n ${GITEA_CONTAINER_NAME:-} ]]; then
      printf 'GITEA_CONTAINER_NAME=%s\n' "$GITEA_CONTAINER_NAME"
    fi
  } >"$tmp"
  mv -f -- "$tmp" "$TARGET_ENV"
}

detect_timezone() {
  local tz=""
  if have timedatectl; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [[ -z $tz && -r /etc/timezone ]]; then
    tz=$(sed -n '1p' /etc/timezone)
  fi
  [[ $tz =~ ^[A-Za-z0-9_+/-]+$ ]] || tz="UTC"
  printf '%s' "$tz"
}

main() {
  section "Configuracion de Gitea privado"
  info "Destino: $TARGET_ENV"

  if [[ -f $TARGET_ENV && $REGENERATE -eq 0 ]]; then
    info ".env ya existe: se valida sin modificarlo (use --regenerate para recrearlo)."
    GITEA_SSH_DOMAIN=${GITEA_SSH_DOMAIN:-}
    GITEA_ROOT_URL=${GITEA_ROOT_URL:-}
    validate_config || true
    check_compose
    if have tailscale && [[ $(ts_state) == "Running" ]]; then
      detect_tailscale
      if [[ -n $DET_DNS && $DET_DNS != "${GITEA_TS_DNS:-}" ]]; then
        warn "El DNS actual de Tailscale ($DET_DNS) difiere del de .env (${GITEA_TS_DNS:-vacio})."
      fi
    fi
    if [[ ${LEGACY_ENV:-0} -eq 1 ]]; then
      info "Migracion: este .env es de la version anterior (publicaba el SSH en la IP de Tailscale)."
      info "  GITEA_SSH_PORT=$GITEA_SSH_PORT se conserva como puerto de la tailnet y GITEA_SSH_LOCAL_PORT=$GITEA_SSH_LOCAL_PORT se usa en 127.0.0.1."
      info "  Para escribir el .env nuevo (con copia del anterior): scripts/configure.sh --regenerate"
    fi
    local perms
    perms=$(stat -c '%a' "$TARGET_ENV")
    if [[ $perms != "600" ]]; then
      chmod 600 "$TARGET_ENV"
      ok "Permisos de .env corregidos a 600 (eran $perms)."
    fi
    if (( CHECK_ERRORS > 0 )); then
      die "La configuracion existente tiene $CHECK_ERRORS error(es). Corrija .env o use --regenerate."
    fi
    ok "Configuracion valida. Sin cambios."
    return 0
  fi

  detect_tailscale
  local ts_dns=${ARG_TS_DNS:-${DET_DNS:-${GITEA_TS_DNS:-}}}
  if [[ -n $ARG_TS_IP ]]; then
    warn "--ts-ip esta obsoleta y se ignora: Docker ya no publica puertos en la IP de Tailscale."
  fi
  if [[ -z $ts_dns ]]; then
    fail "No se pudo obtener el nombre DNS de Tailscale."
    ts_help
    die "Configure Tailscale y vuelva a ejecutar este script (o indique --ts-dns)."
  fi
  ts_dns=$(normalize_dns "$ts_dns")
  ok "Tailscale: DNS $ts_dns${DET_IP:+ (IP $DET_IP, informativa)}"

  local example_version old_ssh_domain=${GITEA_SSH_DOMAIN:-} old_ts_dns=${GITEA_TS_DNS:-}
  example_version=$(read_env_value "$PROJECT_DIR/.env.example" GITEA_VERSION)
  GITEA_VERSION=${GITEA_VERSION:-$example_version}
  GITEA_TS_DNS=$ts_dns
  GITEA_TS_HTTPS_PORT=${ARG_HTTPS:-$GITEA_TS_HTTPS_PORT}
  GITEA_WEB_PORT=${ARG_WEB:-$(ask_value "Puerto HTTP local (127.0.0.1)" "$GITEA_WEB_PORT")}
  GITEA_SSH_LOCAL_PORT=${ARG_SSH_LOCAL:-$(ask_value "Puerto SSH local (127.0.0.1)" "$GITEA_SSH_LOCAL_PORT")}
  GITEA_SSH_PORT=${ARG_SSH:-$(ask_value "Puerto SSH de Git visible en la tailnet (Tailscale Serve)" "$GITEA_SSH_PORT")}
  unset GITEA_TAILSCALE_IP
  LEGACY_ENV=0
  if [[ -z $old_ssh_domain || $old_ssh_domain == "$old_ts_dns" ]]; then
    GITEA_SSH_DOMAIN=$ts_dns
  else
    GITEA_SSH_DOMAIN=$old_ssh_domain
  fi
  GITEA_ROOT_URL=$(build_root_url "$ts_dns" "$GITEA_TS_HTTPS_PORT")
  if [[ ! ${TZ:-} =~ ^[A-Za-z0-9_+/-]+$ ]]; then
    TZ=$(detect_timezone)
  fi

  validate_config || die "Configuracion invalida; no se escribio .env."

  if [[ -f $TARGET_ENV ]]; then
    local backup
    backup="$TARGET_ENV.bak-$(timestamp)"
    cp -p -- "$TARGET_ENV" "$backup"
    chmod 600 "$backup"
    info "Copia del .env anterior: $backup"
  fi
  write_env
  ok ".env escrito con permisos 600: $TARGET_ENV"
  check_compose
  (( CHECK_ERRORS == 0 )) || die "Compose no valido con la configuracion generada."

  cat <<EOF

URL privada prevista:  $GITEA_ROOT_URL
SSH de Git:            ssh://git@$GITEA_SSH_DOMAIN:$GITEA_SSH_PORT/<usuario>/<repo>.git
Puertos:               web 127.0.0.1:$GITEA_WEB_PORT | ssh 127.0.0.1:$GITEA_SSH_LOCAL_PORT | tailnet https $GITEA_TS_HTTPS_PORT, ssh $GITEA_SSH_PORT
Siguiente paso:        scripts/install.sh   (Tailscale Serve se activa despues, con scripts/configure-tailscale.sh)
EOF
}

main
