#!/usr/bin/env bash
# shellcheck disable=SC2034  # constantes usadas por los scripts que cargan este archivo
# common.sh - funciones compartidas por todos los scripts del proyecto.
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# Este archivo no ejecuta nada por si mismo.

if [[ -n "${GITEA_COMMON_LOADED:-}" ]]; then
  return 0
fi
GITEA_COMMON_LOADED=1

set -Eeuo pipefail

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(dirname -- "$COMMON_DIR")"

readonly IMAGE_REPO="docker.gitea.com/gitea"
readonly IMAGE_SUFFIX="-rootless"
readonly DEFAULT_INSTALL_DIR="/srv/gitea-privado"
readonly DEFAULT_BACKUP_DIR="/srv/backups/gitea-privado"
readonly DEFAULT_PROJECT_NAME="gitea-privado"
readonly GITEA_UID=1000
readonly GITEA_GID=1000
readonly BACKUP_FORMAT_VERSION=1

# Unicas claves aceptadas en .env (el archivo se lee con un parser estricto, nunca con "source").
readonly ENV_ALLOWED_KEYS=(
  GITEA_VERSION GITEA_INSTALL_DIR GITEA_BACKUP_DIR GITEA_TS_DNS
  GITEA_TS_HTTPS_PORT GITEA_ROOT_URL GITEA_SSH_DOMAIN GITEA_WEB_PORT GITEA_SSH_LOCAL_PORT GITEA_SSH_PORT
  GITEA_CONTAINER_NAME TZ COMPOSE_PROJECT_NAME
  GITEA_TAILSCALE_IP
)
# Claves de versiones anteriores: se aceptan en .env pero ya no se usan (vea migrate_legacy_env).
readonly ENV_DEPRECATED_KEYS=(GITEA_TAILSCALE_IP)

CHECK_ERRORS=0
CHECK_WARNINGS=0
ASSUME_YES=0

# ---------------------------------------------------------------- mensajes
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log()     { printf '%s\n' "$*"; }
info()    { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { CHECK_WARNINGS=$((CHECK_WARNINGS + 1)); printf '%s[ADVERTENCIA]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail()    { CHECK_ERRORS=$((CHECK_ERRORS + 1)); printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
die()     { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- utilidades
have() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
  have "$1" || die "Falta el comando requerido: $1"
}

timestamp() { date +%Y%m%d-%H%M%S; }

# Ejecuta con privilegios solo cuando hace falta para tocar los datos de Gitea (UID 1000).
# Con SUDO_NONINTERACTIVE=1 (scripts de solo lectura) usa 'sudo -n': nunca pide contrasena.
as_data_owner() {
  if [[ $EUID -eq 0 || $EUID -eq $GITEA_UID ]]; then
    "$@"
  else
    need_cmd sudo
    if [[ ${SUDO_NONINTERACTIVE:-0} -eq 1 ]]; then
      sudo -n "$@"
    else
      sudo "$@"
    fi
  fi
}

# 0 si se puede leer data/ y config/ (propiedad de UID 1000) sin pedir nada al usuario.
can_access_data() {
  [[ $EUID -eq 0 || $EUID -eq $GITEA_UID ]] && return 0
  have sudo || return 1
  if [[ ${SUDO_NONINTERACTIVE:-0} -eq 1 ]]; then
    sudo -n true 2>/dev/null
  fi
}

# Ejecuta siempre como root (crear carpetas bajo /srv, por ejemplo).
as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    need_cmd sudo
    sudo "$@"
  fi
}

confirm() {
  local prompt=$1 answer
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    warn "Entrada no interactiva; se asume 'no' para: $prompt"
    return 1
  fi
  read -r -p "$prompt [s/N] " answer || return 1
  [[ $answer =~ ^([sS]|[sS][iI]|[yY]|[yY][eE][sS])$ ]]
}

# Confirmacion fuerte: nunca se omite con --yes.
confirm_phrase() {
  local phrase=$1 prompt=$2 answer
  [[ -t 0 ]] || die "Esta operacion requiere una terminal interactiva para confirmar."
  read -r -p "$prompt" answer || return 1
  [[ $answer == "$phrase" ]]
}

ask_value() {
  local prompt=$1 default=${2:-} answer
  if [[ ! -t 0 ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " answer || true
  else
    read -r -p "$prompt: " answer || true
  fi
  printf '%s' "${answer:-$default}"
}

# ---------------------------------------------------------------- validaciones
is_port() {
  [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_ipv4() {
  local ip=${1:-} o
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for o in $ip; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

# IP de Tailscale: rango CGNAT 100.64.0.0/10. Se rechazan direcciones reservadas o de ejemplo.
is_tailscale_ip() {
  local ip=${1:-} a b _
  is_ipv4 "$ip" || return 1
  IFS=. read -r a b _ _ <<<"$ip"
  (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 )) || return 1
  [[ $ip == "100.64.0.0" || $ip == "100.100.100.100" || $ip == "100.127.255.255" ]] && return 1
  return 0
}

is_placeholder() {
  [[ ${1:-} =~ (example|ejemplo|nombre-tailnet|tu-tailnet|your-|tailnet-name|servidor\.nombre|changeme|cambiar) ]]
}

is_ts_dns() {
  local dns=${1:-}
  [[ $dns =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\.ts\.net$ ]] || return 1
  is_placeholder "$dns" && return 1
  return 0
}

normalize_dns() {
  local dns=${1:-}
  dns=${dns%.}
  printf '%s' "${dns,,}"
}

is_version() {
  [[ ${1:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_abs_path() {
  [[ ${1:-} =~ ^/[A-Za-z0-9._/-]*$ && ${1:-} != "/" && ${1:-} != *..* ]]
}

# true si $1 es estrictamente mayor que $2 (comparacion de versiones)
version_gt() {
  [[ $1 != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

major_of() { printf '%s' "${1%%.*}"; }

build_root_url() {
  local dns=$1 port=$2
  if [[ $port == 443 ]]; then
    printf 'https://%s/' "$dns"
  else
    printf 'https://%s:%s/' "$dns" "$port"
  fi
}

is_under() {
  local child parent
  child=$(realpath -m -- "$1")
  parent=$(realpath -m -- "$2")
  [[ $child == "$parent" || $child == "$parent"/* ]]
}

# ---------------------------------------------------------------- archivo .env
read_env_value() {
  local file=$1 key=$2
  [[ -r $file ]] || return 0
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit }' "$file"
}

# Carga .env con un parser estricto. Las variables ya definidas en el entorno tienen prioridad.
load_env_file() {
  local file=$1 line key val lineno=0 k allowed
  [[ -r $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ $line =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._:/@+-]*)$ ]]; then
      key=${BASH_REMATCH[1]}
      val=${BASH_REMATCH[2]}
      allowed=0
      for k in "${ENV_ALLOWED_KEYS[@]}"; do
        [[ $k == "$key" ]] && allowed=1
      done
      (( allowed == 1 )) || die "$file:$lineno: clave no permitida: $key"
      if [[ -z ${!key+x} ]]; then
        printf -v "$key" '%s' "$val"
      fi
    else
      die "$file:$lineno: linea invalida (use CLAVE=valor sin comillas, espacios ni \$)."
    fi
  done <"$file"
}

# Actualiza o agrega CLAVE=valor de forma atomica, conservando el resto del archivo.
env_set() {
  local file=$1 key=$2 val=$3 tmp
  [[ $val =~ ^[A-Za-z0-9._:/@+-]*$ ]] || die "Valor no permitido para $key"
  tmp=$(mktemp "${file}.XXXXXX")
  chmod 600 "$tmp"
  if grep -q "^${key}=" "$file"; then
    awk -v k="$key" -v v="$val" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$file" >"$tmp"
  else
    cat -- "$file" >"$tmp"
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
  fi
  mv -f -- "$tmp" "$file"
}

# Determina INSTALL_DIR, carga .env y aplica valores por defecto.
init_context() {
  local pref=${PREFERRED_ENV_FILE:-}
  if [[ -z ${GITEA_INSTALL_DIR:-} ]]; then
    if [[ -n $pref && -r $pref ]]; then
      GITEA_INSTALL_DIR=$(read_env_value "$pref" GITEA_INSTALL_DIR)
    elif [[ -r $PROJECT_DIR/.env ]]; then
      GITEA_INSTALL_DIR=$(read_env_value "$PROJECT_DIR/.env" GITEA_INSTALL_DIR)
    fi
  fi
  INSTALL_DIR=${GITEA_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}
  is_abs_path "$INSTALL_DIR" || die "Ruta de instalacion invalida: $INSTALL_DIR"

  ENV_FILE=""
  if [[ -n $pref && -r $pref ]]; then
    ENV_FILE=$pref
  elif [[ -r $INSTALL_DIR/.env ]]; then
    ENV_FILE=$INSTALL_DIR/.env
  elif [[ -r $PROJECT_DIR/.env ]]; then
    ENV_FILE=$PROJECT_DIR/.env
  fi
  if [[ -n $ENV_FILE ]]; then
    load_env_file "$ENV_FILE"
  fi

  GITEA_WEB_PORT=${GITEA_WEB_PORT:-3090}
  GITEA_SSH_PORT=${GITEA_SSH_PORT:-2222}
  # Migracion: un .env anterior (con GITEA_TAILSCALE_IP) publicaba el SSH en GITEA_SSH_PORT; ese puerto
  # sigue siendo el visible en la tailnet y tambien se usa como puerto local para no cambiar nada mas.
  LEGACY_ENV=0
  if [[ -n ${GITEA_TAILSCALE_IP:-} ]]; then
    LEGACY_ENV=1
    GITEA_SSH_LOCAL_PORT=${GITEA_SSH_LOCAL_PORT:-$GITEA_SSH_PORT}
  fi
  GITEA_SSH_LOCAL_PORT=${GITEA_SSH_LOCAL_PORT:-2222}
  GITEA_TS_HTTPS_PORT=${GITEA_TS_HTTPS_PORT:-443}
  GITEA_BACKUP_DIR=${GITEA_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}
  GITEA_VERSION=${GITEA_VERSION:-}
  GITEA_TS_DNS=${GITEA_TS_DNS:-}
  PROJECT_NAME=${COMPOSE_PROJECT_NAME:-$DEFAULT_PROJECT_NAME}
  CONTAINER_NAME=${GITEA_CONTAINER_NAME:-$DEFAULT_PROJECT_NAME}
  COMPOSE_DIR=$INSTALL_DIR
  BACKUP_DIR=$GITEA_BACKUP_DIR
  is_abs_path "$BACKUP_DIR" || die "Ruta de respaldos invalida: $BACKUP_DIR"
}

# Valida solo la parte de puertos y rutas (usable antes de que exista .env).
validate_ports() {
  local before=$CHECK_ERRORS
  is_port "$GITEA_WEB_PORT" || fail "GITEA_WEB_PORT invalido: $GITEA_WEB_PORT"
  is_port "$GITEA_SSH_LOCAL_PORT" || fail "GITEA_SSH_LOCAL_PORT invalido: $GITEA_SSH_LOCAL_PORT"
  is_port "$GITEA_SSH_PORT" || fail "GITEA_SSH_PORT invalido: $GITEA_SSH_PORT"
  if is_port "$GITEA_WEB_PORT" && is_port "$GITEA_SSH_LOCAL_PORT" && (( 10#$GITEA_WEB_PORT == 10#$GITEA_SSH_LOCAL_PORT )); then
    fail "GITEA_WEB_PORT y GITEA_SSH_LOCAL_PORT no pueden ser el mismo ($GITEA_WEB_PORT)."
  fi
  case $GITEA_TS_HTTPS_PORT in
    443|8443|10000) ;;
    *) fail "GITEA_TS_HTTPS_PORT debe ser 443, 8443 o 10000 (puertos HTTPS admitidos por Tailscale Serve)." ;;
  esac
  if is_port "$GITEA_SSH_PORT" && [[ $GITEA_TS_HTTPS_PORT =~ ^[0-9]+$ ]] && (( 10#$GITEA_SSH_PORT == 10#$GITEA_TS_HTTPS_PORT )); then
    fail "GITEA_SSH_PORT y GITEA_TS_HTTPS_PORT no pueden coincidir: Tailscale Serve no admite dos servicios en un mismo puerto."
  fi
  if is_port "$GITEA_SSH_PORT" && (( 10#$GITEA_SSH_PORT == 22 )); then
    warn "GITEA_SSH_PORT=22: puede chocar con Tailscale SSH u otros servicios en la tailnet de este equipo."
  fi
  [[ $CHECK_ERRORS -eq $before ]]
}

# Valida los valores de configuracion cargados. Devuelve 1 si hay errores.
validate_config() {
  local before=$CHECK_ERRORS expected_url
  if ! is_version "${GITEA_VERSION:-}"; then
    fail "GITEA_VERSION invalida o vacia ('${GITEA_VERSION:-}'). Use X.Y.Z, p. ej. 28.3.0."
  fi
  if ! is_ts_dns "${GITEA_TS_DNS:-}"; then
    fail "GITEA_TS_DNS invalido o de ejemplo ('${GITEA_TS_DNS:-}'). Debe terminar en .ts.net."
  fi
  validate_ports || true
  if [[ -n ${GITEA_TS_DNS:-} ]] && is_ts_dns "$GITEA_TS_DNS" && [[ $GITEA_TS_HTTPS_PORT =~ ^[0-9]+$ ]]; then
    expected_url=$(build_root_url "$GITEA_TS_DNS" "$GITEA_TS_HTTPS_PORT")
    if [[ ${GITEA_ROOT_URL:-} != "$expected_url" ]]; then
      fail "GITEA_ROOT_URL ('${GITEA_ROOT_URL:-}') no coincide con la esperada: $expected_url"
    fi
  fi
  local ssh_domain=${GITEA_SSH_DOMAIN:-}
  if [[ -z $ssh_domain ]] || { ! is_ts_dns "$ssh_domain" && ! is_tailscale_ip "$ssh_domain"; }; then
    fail "GITEA_SSH_DOMAIN debe ser el DNS de Tailscale o la IP de Tailscale ('$ssh_domain')."
  fi
  if [[ -n ${GITEA_CONTAINER_NAME:-} && ! ${GITEA_CONTAINER_NAME} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    fail "GITEA_CONTAINER_NAME invalido: ${GITEA_CONTAINER_NAME}"
  fi
  if [[ -n ${COMPOSE_PROJECT_NAME:-} && ! ${COMPOSE_PROJECT_NAME} =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    fail "COMPOSE_PROJECT_NAME invalido (minusculas, numeros, guion): ${COMPOSE_PROJECT_NAME}"
  fi
  if is_under "$BACKUP_DIR" "$INSTALL_DIR" || is_under "$INSTALL_DIR" "$BACKUP_DIR"; then
    fail "El directorio de respaldos no puede estar dentro del directorio de instalacion (ni al reves)."
  fi
  if [[ ${LEGACY_ENV:-0} -eq 1 ]]; then
    warn "GITEA_TAILSCALE_IP es una clave obsoleta y se ignora (Docker ya no publica en la IP de Tailscale). configure.sh --regenerate la elimina."
  fi
  [[ $CHECK_ERRORS -eq $before ]]
}


# ---------------------------------------------------------------- Docker Compose
# Siempre actua sobre este proyecto Compose y ningun otro.
dc() {
  docker compose --project-directory "$COMPOSE_DIR" --project-name "$PROJECT_NAME" -f "$COMPOSE_DIR/compose.yaml" "$@"
}

container_id() {
  { dc ps -a -q gitea 2>/dev/null || true; } | head -n 1
}

container_running() {
  local id
  id=$(container_id)
  [[ -n $id ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" == "true" ]]
}

image_ref() {
  printf '%s:%s%s' "$IMAGE_REPO" "$1" "$IMAGE_SUFFIX"
}

local_url() {
  printf 'http://127.0.0.1:%s' "$GITEA_WEB_PORT"
}

http_ok() {
  local code
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || true)
  [[ $code =~ ^[23][0-9][0-9]$ ]]
}

wait_for_gitea() {
  local timeout=${1:-90} elapsed=0 base
  base=$(local_url)
  while (( elapsed < timeout )); do
    if http_ok "$base/api/healthz" || http_ok "$base/"; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# Estado del healthcheck de Docker: healthy | unhealthy | starting | none | missing
container_health() {
  local id st
  id=$(container_id)
  [[ -n $id ]] || { printf 'missing'; return 0; }
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)
  printf '%s' "${st:-missing}"
}

# Espera a que el healthcheck de Docker diga 'healthy' (no basta con que haya una pagina HTTP).
wait_for_healthy() {
  local timeout=${1:-120} elapsed=0
  while (( elapsed < timeout )); do
    [[ $(container_health) == healthy ]] && return 0
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# Version de Gitea que ejecuta realmente el contenedor (por ejemplo 28.3.0); vacio si no se pudo leer.
running_gitea_version() {
  local out
  out=$(dc exec -T gitea gitea --version 2>/dev/null | sed -n '1p' || true)
  [[ $out =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# Imagen con la que fue creado el contenedor.
container_image() {
  local id
  id=$(container_id)
  [[ -n $id ]] && docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true
}

# Puertos publicados por el contenedor propio: lineas "2222/tcp -> 127.0.0.1:2222".
container_ports() {
  local id
  id=$(container_id)
  [[ -n $id ]] && { docker port "$id" 2>/dev/null || true; }
}

# Devuelve 0 solo si el contenedor propio publica exactamente web y SSH local, ambos en 127.0.0.1.
ports_loopback_only() {
  local ports bad
  ports=$(container_ports)
  [[ -n $ports ]] || return 1
  bad=$(grep -Ev -- "-> 127\.0\.0\.1:(${GITEA_WEB_PORT}|${GITEA_SSH_LOCAL_PORT})$" <<<"$ports" || true)
  [[ -z $bad ]] && grep -Eq -- "^3000/tcp -> 127\.0\.0\.1:${GITEA_WEB_PORT}$" <<<"$ports" \
    && grep -Eq -- "^2222/tcp -> 127\.0\.0\.1:${GITEA_SSH_LOCAL_PORT}$" <<<"$ports"
}

# Banner SSH ("SSH-2.0-...") en host:puerto, sin autenticar. Vacio si no responde.
ssh_banner() {
  local host=$1 port=$2
  is_port "$port" || return 0
  [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || return 0
  timeout 8 bash -c 'exec 3<>"/dev/tcp/$1/$2" && read -r -t 5 line <&3 && printf "%s" "$line"' _ "$host" "$port" 2>/dev/null || true
}

# El asistente de instalacion de Gitea termina escribiendo INSTALL_LOCK=true en app.ini.
# Devuelve 0 = completado, 1 = pendiente, 2 = no se pudo comprobar (sin permisos).
installer_locked() {
  can_access_data || return 2
  as_data_owner test -f "$INSTALL_DIR/config/app.ini" 2>/dev/null || return 1
  as_data_owner grep -Eq '^INSTALL_LOCK[[:space:]]*=[[:space:]]*true' "$INSTALL_DIR/config/app.ini" 2>/dev/null
}

# Comprueba que existe la imagen (local o descargable) ANTES de detener nada.
ensure_image_available() {
  local ref=$1
  if docker image inspect "$ref" >/dev/null 2>&1; then
    return 0
  fi
  docker pull "$ref" >/dev/null 2>&1
}

# ---------------------------------------------------------------- SQLite (solo lectura, con Python 3)
# Integridad de una base SQLite. $1 = archivo. Se abre en modo solo lectura.
sqlite_integrity_ok() {
  have python3 || return 2
  as_data_owner python3 - "$1" <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    ok = con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    con.close()
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
}

# Ejecuta una consulta escalar de solo lectura: $1 = archivo, $2 = SQL. Imprime el valor o nada.
sqlite_scalar() {
  have python3 || return 0
  as_data_owner python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import sqlite3, sys
try:
    con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    row = con.execute(sys.argv[2]).fetchone()
    con.close()
    print(row[0] if row else "")
except Exception:
    pass
PY
}

gitea_db_path() { printf '%s/data/data/gitea.db' "$INSTALL_DIR"; }

# Version del esquema de la base de datos de Gitea (tabla 'version'); vacio si no se pudo leer.
db_schema_version() {
  local v
  v=$(sqlite_scalar "$(gitea_db_path)" "SELECT version FROM version LIMIT 1")
  [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

# Cantidad de repositorios segun la base de datos y segun el disco.
db_repo_count() {
  local v
  v=$(sqlite_scalar "$(gitea_db_path)" "SELECT COUNT(*) FROM repository")
  [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

disk_repo_count() {
  as_data_owner find "$INSTALL_DIR/data/git/repositories" -mindepth 2 -maxdepth 2 -type d -name '*.git' 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------- sistema
nearest_existing() {
  local p=$1
  while [[ ! -e $p && $p != "/" ]]; do
    p=$(dirname -- "$p")
  done
  printf '%s' "$p"
}

avail_kb() {
  df -Pk -- "$(nearest_existing "$1")" | awk 'NR == 2 { print $4 }'
}

human_kb() {
  awk -v kb="$1" 'BEGIN { if (kb >= 1048576) printf "%.1f GiB", kb / 1048576; else printf "%.0f MiB", kb / 1024 }'
}

# Muestra los oyentes TCP que chocarian con $1 (puerto) en la direccion $2.
port_conflicts() {
  local port=$1 addr=$2 listener found=1
  have ss || return 2
  while IFS= read -r listener; do
    case $listener in
      "*:$port"|"0.0.0.0:$port"|"[::]:$port"|"$addr:$port")
        printf '%s\n' "$listener"
        found=0
        ;;
    esac
  done < <(ss -H -ltn 2>/dev/null | awk '{ print $4 }')
  return $found
}

docker_port_owner() {
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | awk -F'\t' -v p=":$1->" 'index($2, p) { print $1 }' | paste -sd, -
}

# ---------------------------------------------------------------- Tailscale
# El JSON de Tailscale se analiza con scripts/tsjson.py (Python 3, solo lectura); nunca con grep/sed.
TSJSON="$COMMON_DIR/tsjson.py"

ts_json() {
  tailscale status --json 2>/dev/null || true
}

ts_field() { # state|dns|ip4|certs
  have python3 || return 0
  ts_json | python3 "$TSJSON" status "$1" 2>/dev/null || true
}

ts_state() { ts_field state; }

ts_self_dns() {
  local dns
  dns=$(ts_field dns)
  dns=$(normalize_dns "$dns")
  is_ts_dns "$dns" && printf '%s' "$dns"
  return 0
}

# Informativo: Docker ya no depende de esta IP.
ts_ip4() {
  local ip
  ip=$(ts_field ip4)
  is_tailscale_ip "$ip" && printf '%s' "$ip"
  return 0
}

ts_cert_domains() {
  local n
  n=$(ts_field certs)
  [[ $n =~ ^[0-9]+$ ]] && printf '%s' "$n"
  return 0
}

ts_version() {
  local v
  v=$(tailscale version 2>/dev/null | sed -n '1p' || true)
  [[ $v =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([-+][A-Za-z0-9._+-]*)?$ ]] && printf '%s' "${v%%[-+]*}"
  return 0
}

# Tailscale Serve nuevo (CLI de la version 1.52 en adelante) con reenvio TCP (--tcp).
ts_serve_supported() {
  local v help
  v=$(ts_version)
  [[ -n $v ]] || return 1
  version_gt "$v" "1.51.99" || return 1
  help=$(tailscale serve --help 2>&1 || true)
  grep -Fq -- '--tcp' <<<"$help"
}

# Lee la configuracion de Serve. Con $1=interactive puede pedir contrasena de sudo; si no, usa "sudo -n".
# shellcheck disable=SC2120  # el argumento opcional lo usa configure-tailscale.sh
ts_serve_json() {
  local out
  if out=$(tailscale serve status --json 2>/dev/null); then
    printf '%s' "$out"
    return 0
  fi
  if [[ $EUID -ne 0 ]] && have sudo; then
    if [[ ${1:-} == interactive ]]; then
      out=$(sudo tailscale serve status --json 2>/dev/null) && { printf '%s' "$out"; return 0; }
    else
      out=$(sudo -n tailscale serve status --json 2>/dev/null) && { printf '%s' "$out"; return 0; }
    fi
  fi
  return 1
}

# Clasifica los dos servicios de Gitea en Tailscale Serve. Entrada: JSON en $1.
# Rellena TS_SCHEMA, TS_HTTPS, TS_HTTPS_DETAIL, TS_SSH, TS_SSH_DETAIL, TS_FUNNEL, TS_FUNNEL_OTHER, TS_TCP_PORTS.
# Devuelve 3 si el JSON no se reconoce (no se debe decidir nada con el).
ts_serve_inspect() {
  local json=$1 out line rc=0 key val
  TS_SCHEMA=unrecognized; TS_HTTPS=""; TS_HTTPS_DETAIL=""; TS_SSH=""; TS_SSH_DETAIL=""
  TS_FUNNEL=""; TS_FUNNEL_OTHER=""; TS_TCP_PORTS=""; TS_REASON=""
  have python3 || { TS_REASON="falta python3"; return 3; }
  out=$(python3 "$TSJSON" serve --dns "$GITEA_TS_DNS" --https-port "${TS_CHECK_HTTPS_PORT:-$GITEA_TS_HTTPS_PORT}" \
    --web-port "$GITEA_WEB_PORT" --ssh-port "$GITEA_SSH_PORT" --ssh-local-port "$GITEA_SSH_LOCAL_PORT" <<<"$json") || rc=$?
  while IFS= read -r line; do
    key=${line%%=*}; val=${line#*=}
    case $key in
      schema) TS_SCHEMA=$val ;;
      reason) TS_REASON=$val ;;
      https) TS_HTTPS=$val ;;
      https_detail) TS_HTTPS_DETAIL=$val ;;
      ssh) TS_SSH=$val ;;
      ssh_detail) TS_SSH_DETAIL=$val ;;
      funnel) TS_FUNNEL=$val ;;
      funnel_other) TS_FUNNEL_OTHER=$val ;;
      tcp_ports) TS_TCP_PORTS=$val ;;
    esac
  done <<<"$out"
  [[ $rc -eq 0 && $TS_SCHEMA == ok ]] || return 3
  return 0
}

ts_serve_is_empty() {
  local compact
  compact=$(tr -d '[:space:]' <<<"$1")
  [[ $compact == "{}" ]]
}

ts_help() {
  cat <<'EOF'
Tailscale no esta instalado o conectado. Procedimiento oficial (no se ejecuta automaticamente):
  1. Instalar: https://tailscale.com/download/linux (revise el script antes de ejecutarlo).
  2. Conectar el servidor a su tailnet:  sudo tailscale up
     (abre una URL de autenticacion; este proyecto nunca lo hace por usted).
  3. Habilitar MagicDNS y certificados HTTPS en https://login.tailscale.com/admin/dns
  4. Verificar:  tailscale status   y   tailscale version
EOF
}

# ---------------------------------------------------------------- informe de estados
# Distingue cada etapa por separado: un contenedor encendido o una pagina HTTP NO bastan para dar por instalado.
STATE_FAILS=0
STATE_PENDING=0
state_line() { # SI|PENDIENTE|NO-VERIFICADO|FALLA  etiqueta  [detalle]
  local st=$1 label=$2 detail=${3:-} color=$C_YELLOW txt
  case $st in
    SI) color=$C_GREEN; txt="SI" ;;
    FALLA) color=$C_RED; txt="FALLA"; STATE_FAILS=$((STATE_FAILS + 1)) ;;
    PENDIENTE) txt="PENDIENTE"; STATE_PENDING=$((STATE_PENDING + 1)) ;;
    *) txt="NO VERIFICADO"; STATE_PENDING=$((STATE_PENDING + 1)) ;;
  esac
  printf '  %s[%-13s]%s %s%s\n' "$color" "$txt" "$C_RESET" "$label" "${detail:+ - $detail}"
}

report_states() {
  local id state ports banner admins json
  STATE_FAILS=0; STATE_PENDING=0
  section "Estado por etapas"

  if container_running; then state_line SI "Contenedor iniciado" "$(container_image)"; else state_line FALLA "Contenedor iniciado" "no esta en ejecucion"; fi
  state=$(container_health)
  case $state in
    healthy) state_line SI "Healthcheck de Docker" "healthy" ;;
    starting) state_line PENDIENTE "Healthcheck de Docker" "starting (espere y repita)" ;;
    *) state_line FALLA "Healthcheck de Docker" "$state" ;;
  esac
  if http_ok "$(local_url)/api/healthz"; then state_line SI "Web accesible localmente" "$(local_url)"; else state_line FALLA "Web accesible localmente" "$(local_url) sin respuesta"; fi
  if ports_loopback_only; then
    state_line SI "Puertos Docker solo en 127.0.0.1" "web $GITEA_WEB_PORT, ssh $GITEA_SSH_LOCAL_PORT"
  else
    state_line FALLA "Puertos Docker solo en 127.0.0.1" "se esperaba 127.0.0.1:$GITEA_WEB_PORT y 127.0.0.1:$GITEA_SSH_LOCAL_PORT: $(container_ports | paste -sd, -)"
  fi
  banner=$(ssh_banner 127.0.0.1 "$GITEA_SSH_LOCAL_PORT")
  if [[ $banner == SSH-* ]]; then state_line SI "SSH de Git responde en local" "127.0.0.1:$GITEA_SSH_LOCAL_PORT"; else state_line FALLA "SSH de Git responde en local" "sin banner SSH en 127.0.0.1:$GITEA_SSH_LOCAL_PORT"; fi

  local lock_rc=0
  installer_locked || lock_rc=$?
  if [[ $lock_rc -eq 0 ]]; then
    state_line SI "Asistente de Gitea completado" "INSTALL_LOCK=true"
    admins=$(dc exec -T gitea gitea -c /etc/gitea/app.ini admin user list --admin 2>/dev/null | awk 'NR > 1 && NF { n++ } END { print n + 0 }' || true)
    if [[ ${admins:-0} =~ ^[1-9][0-9]*$ ]]; then
      state_line SI "Cuenta administradora creada" "$admins administrador(es)"
    else
      state_line NO-VERIFICADO "Cuenta administradora creada" "no se pudo listar administradores"
    fi
  elif [[ $lock_rc -eq 2 ]]; then
    state_line NO-VERIFICADO "Asistente de Gitea completado" "sin permiso para leer config/app.ini (ejecute con sudo o como root)"
    state_line NO-VERIFICADO "Cuenta administradora creada" "idem"
  else
    state_line PENDIENTE "Asistente de Gitea completado" "cree la cuenta administradora (docs/INSTALACION-MANANA.md, Fase 7)"
    state_line PENDIENTE "Cuenta administradora creada" "depende del asistente"
  fi

  if ! have tailscale || ! have python3; then
    state_line NO-VERIFICADO "HTTPS privado (Tailscale Serve)" "falta tailscale o python3"
    state_line NO-VERIFICADO "SSH privado (Tailscale Serve)" "falta tailscale o python3"
  elif ! json=$(ts_serve_json) || ! ts_serve_inspect "$json"; then
    state_line NO-VERIFICADO "HTTPS privado (Tailscale Serve)" "no se pudo leer o reconocer 'tailscale serve status --json'"
    state_line NO-VERIFICADO "SSH privado (Tailscale Serve)" "idem"
  else
    case $TS_HTTPS in
      ours) state_line SI "HTTPS privado habilitado" "$GITEA_ROOT_URL -> http://127.0.0.1:$GITEA_WEB_PORT" ;;
      free) state_line PENDIENTE "HTTPS privado habilitado" "ejecute scripts/configure-tailscale.sh" ;;
      *) state_line FALLA "HTTPS privado habilitado" "el puerto $GITEA_TS_HTTPS_PORT lo usa otra cosa: $TS_HTTPS_DETAIL" ;;
    esac
    case $TS_SSH in
      ours) state_line SI "SSH privado habilitado" "tailnet:$GITEA_SSH_PORT -> tcp://127.0.0.1:$GITEA_SSH_LOCAL_PORT" ;;
      free) state_line PENDIENTE "SSH privado habilitado" "ejecute scripts/configure-tailscale.sh" ;;
      *) state_line FALLA "SSH privado habilitado" "el puerto $GITEA_SSH_PORT lo usa otra cosa: $TS_SSH_DETAIL" ;;
    esac
    if [[ $TS_FUNNEL == on ]]; then state_line FALLA "Sin Funnel (exposicion publica)" "Funnel activo sobre un puerto de Gitea"; else state_line SI "Sin Funnel (exposicion publica)" "sin Funnel en los puertos de Gitea"; fi
  fi

  state_line NO-VERIFICADO "Operacion Git verificada (clone/push/pull)" "prueba manual desde Windows: docs/INSTALACION-MANANA.md, Fase 11"

  local last
  last=$({ ls -1t -- "$BACKUP_DIR"/*.tar.gz 2>/dev/null || true; } | sed -n '1p')
  if [[ -z $last ]]; then
    state_line PENDIENTE "Backup verificado" "aun no hay respaldos: scripts/backup.sh"
  elif (cd -- "$(dirname -- "$last")" && sha256sum -c --quiet -- "$(basename -- "$last").sha256" >/dev/null 2>&1); then
    state_line SI "Backup verificado (SHA-256 e integridad del archivo)" "$(basename -- "$last")"
    state_line NO-VERIFICADO "Restauracion probada en un entorno separado" "prueba manual: docs/BACKUPS.md"
  else
    state_line FALLA "Backup verificado" "$(basename -- "$last") no supera la comprobacion SHA-256"
  fi
}
