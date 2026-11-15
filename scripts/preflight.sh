#!/usr/bin/env bash
# preflight.sh - Analiza el servidor ANTES de instalar. ESTRICTAMENTE de solo lectura: no modifica Docker,
# Tailscale, el firewall, contenedores ni el disco (no crea directorios; no usa 'docker pull').
# Salida: OK / ADVERTENCIA / ERROR. Codigo de salida 1 si hay errores criticos.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/preflight.sh
Variables opcionales: GITEA_INSTALL_DIR (por defecto /srv/gitea-privado).
Lee .env si existe; de lo contrario usa 3090 (HTTP local), 2222 (SSH local), 2222 (SSH en la tailnet) y 443 (HTTPS).
Distingue: primera instalacion, instalacion existente saludable, con problemas o configuracion parcial.
EOF
}

# Contenedores del proyecto Compose propio (por etiqueta; no depende de que compose.yaml/.env sean validos).
own_container_ids() {
  docker ps -a -q --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.service=gitea" 2>/dev/null || true
}

check_system() {
  section "Sistema"
  if [[ $(uname -s) == "Linux" ]]; then
    ok "Sistema operativo: Linux"
  else
    fail "Este proyecto se instala en Linux (Ubuntu Server); se detecto $(uname -s)."
  fi
  local distro="desconocida" distro_id=""
  if [[ -r /etc/os-release ]]; then
    distro=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-desconocida}")
    distro_id=$(. /etc/os-release && printf '%s' "${ID:-}")
  fi
  if [[ $distro_id == "ubuntu" ]]; then
    ok "Distribucion: $distro"
  else
    warn "Distribucion: $distro (el proyecto esta pensado para Ubuntu Server)."
  fi
  case $(uname -m) in
    x86_64|aarch64) ok "Arquitectura: $(uname -m) (imagen oficial disponible)" ;;
    *) warn "Arquitectura $(uname -m): verifique que la imagen de Gitea la soporta." ;;
  esac
  if [[ $EUID -eq 0 ]]; then
    warn "Se esta ejecutando como root. Se recomienda un usuario normal con acceso a Docker."
  fi
  local mem_kb
  mem_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
  if [[ ${mem_kb:-} =~ ^[0-9]+$ ]]; then
    if (( mem_kb < 262144 )); then
      fail "Memoria disponible muy baja: $(human_kb "$mem_kb") (Gitea necesita al menos unos 256 MiB libres)."
    elif (( mem_kb < 786432 )); then
      warn "Memoria disponible baja: $(human_kb "$mem_kb") (se recomiendan 768 MiB o mas con los demas contenedores en marcha)."
    else
      ok "Memoria disponible: $(human_kb "$mem_kb")"
    fi
  else
    warn "No se pudo leer la memoria disponible."
  fi
}

check_dependencies() {
  section "Dependencias"
  local cmd
  for cmd in curl tar gzip sha256sum flock awk sed grep df mktemp stat realpath sort paste timeout python3; do
    if have "$cmd"; then
      ok "Comando disponible: $cmd"
    else
      case $cmd in
        python3) fail "Falta 'python3' (se usa para analizar el JSON de Tailscale y comprobar bases SQLite). Instale con: sudo apt install python3 (no se instala automaticamente)." ;;
        *) fail "Falta el comando '$cmd' (paquete: coreutils/util-linux/curl segun el caso)." ;;
      esac
    fi
  done
  if have ss; then
    ok "Comando disponible: ss"
  else
    warn "Falta 'ss' (paquete iproute2): no se podran comprobar puertos locales."
  fi
  if [[ $EUID -ne 0 ]]; then
    if have sudo; then
      ok "sudo disponible (se usa solo para /srv y para leer datos de Gitea)."
    else
      fail "Falta sudo y no se esta ejecutando como root."
    fi
  fi
}

check_docker() {
  section "Docker"
  if ! have docker; then
    fail "Docker no esta instalado. Instale Docker Engine siguiendo https://docs.docker.com/engine/install/ubuntu/"
    DOCKER_OK=0
    return
  fi
  ok "Docker presente: $(docker --version 2>/dev/null || echo 'version desconocida')"
  local out
  if out=$(docker info 2>&1); then
    ok "Docker Engine responde."
    DOCKER_OK=1
  else
    DOCKER_OK=0
    if grep -qi 'permission denied' <<<"$out"; then
      fail "Sin permisos para usar Docker. Agregue su usuario al grupo docker (sudo usermod -aG docker \$USER, luego cierre sesion y vuelva a entrar) o ejecute con un usuario autorizado."
    else
      fail "Docker Engine no responde: $(head -n 1 <<<"$out")"
    fi
    return
  fi
  local ver
  ver=$(docker compose version --short 2>/dev/null || true)
  ver=${ver#v}
  if [[ -n $ver && ${ver%%.*} =~ ^[0-9]+$ ]] && (( ${ver%%.*} >= 2 )); then
    ok "Docker Compose V2 disponible: $ver"
  else
    fail "Docker Compose V2 no disponible (se necesita el plugin 'docker compose', no 'docker-compose' v1)."
    DOCKER_OK=0
  fi
}

check_tailscale() {
  section "Tailscale"
  TS_DNS=""
  TS_OK=0
  if ! have tailscale; then
    fail "Tailscale no esta instalado."
    ts_help
    return
  fi
  ok "Tailscale instalado: $(tailscale version 2>/dev/null | sed -n '1p')"
  local state
  state=$(ts_state)
  if [[ $state == "Running" ]]; then
    ok "Tailscale conectado (estado: Running)."
  else
    fail "Tailscale no esta conectado (estado: ${state:-desconocido})."
    ts_help
    return
  fi
  TS_DNS=$(ts_self_dns)
  if is_ts_dns "$TS_DNS"; then
    ok "MagicDNS: nombre del servidor $TS_DNS"
  else
    fail "No se obtuvo un nombre DNS .ts.net (resultado: '${TS_DNS:-vacio}'). Habilite MagicDNS en https://login.tailscale.com/admin/dns"
    TS_DNS=""
    return
  fi
  if [[ ! $(ts_cert_domains) =~ ^[1-9][0-9]*$ ]]; then
    warn "Tailscale no informa dominios de certificado: habilite HTTPS en https://login.tailscale.com/admin/dns antes de publicar HTTPS."
  else
    ok "Certificados HTTPS de Tailscale habilitados para la tailnet."
  fi
  if [[ -n ${GITEA_TS_DNS:-} && $GITEA_TS_DNS != "$TS_DNS" ]]; then
    warn "El DNS de .env ($GITEA_TS_DNS) difiere del actual ($TS_DNS). Ejecute scripts/configure.sh --regenerate."
  fi
  if ts_serve_supported; then
    ok "El cliente Tailscale admite 'serve --https' y 'serve --tcp' (version $(ts_version))."
    TS_OK=1
  else
    fail "El cliente Tailscale ($(ts_version || true)) no admite 'serve --tcp' (se necesita 1.52 o posterior). Actualice Tailscale con el procedimiento oficial."
  fi
}

check_ports() {
  section "Puertos locales (Docker, solo 127.0.0.1)"
  if ! have ss; then
    warn "No se pueden comprobar los puertos sin 'ss'."
    return
  fi
  local cid ports label port conflicts owner
  cid=$(own_container_ids | sed -n '1p')
  ports=""
  if [[ $DOCKER_OK -eq 1 && -n $cid ]]; then
    ports=$(docker port "$cid" 2>/dev/null || true)
  fi
  for label in "HTTP local:$GITEA_WEB_PORT:3000" "SSH local:$GITEA_SSH_LOCAL_PORT:2222"; do
    IFS=: read -r label port inner <<<"$label"
    if conflicts=$(port_conflicts "$port" "127.0.0.1"); then
      # Solo es "propio" si el contenedor de ESTE proyecto publica exactamente ese puerto en 127.0.0.1.
      if grep -Eq -- "^${inner}/tcp -> 127\.0\.0\.1:${port}$" <<<"$ports"; then
        ok "Puerto $label 127.0.0.1:$port en uso por el contenedor de esta misma instalacion."
      else
        owner=$(docker_port_owner "$port" || true)
        fail "Puerto $label $port ocupado (${conflicts//$'\n'/, })${owner:+ por contenedor(es): $owner}. Elija otro (configure.sh --web-port / --ssh-local-port); no se detendra nada ajeno."
      fi
    else
      ok "Puerto $label 127.0.0.1:$port libre."
    fi
  done
}

check_serve() {
  section "Puertos de Tailscale Serve (colisiones en la tailnet)"
  if [[ ${TS_OK:-0} -ne 1 || -z ${TS_DNS:-} ]]; then
    warn "Se omite: Tailscale no esta listo."
    return
  fi
  local json dns_backup=${GITEA_TS_DNS:-}
  if ! json=$(ts_serve_json); then
    warn "No se pudo leer 'tailscale serve status --json' sin contrasena (sudo -n). Verifiquelo a mano: sudo tailscale serve status"
    return
  fi
  GITEA_TS_DNS=$TS_DNS
  if ! ts_serve_inspect "$json"; then
    fail "No se reconoce la estructura de 'tailscale serve status --json' (${TS_REASON:-sin motivo}). No se tomaran decisiones automaticas."
    printf '%s\n' "$json" | head -c 2000
    printf '\n'
    GITEA_TS_DNS=$dns_backup
    return
  fi
  GITEA_TS_DNS=$dns_backup
  case $TS_HTTPS in
    free) ok "Puerto HTTPS $GITEA_TS_HTTPS_PORT de Serve libre." ;;
    ours) ok "El HTTPS $GITEA_TS_HTTPS_PORT de Serve ya publica Gitea ($TS_HTTPS_DETAIL)." ;;
    *) fail "El puerto HTTPS $GITEA_TS_HTTPS_PORT de Serve lo usa un servicio ajeno: $TS_HTTPS_DETAIL. Use otro (443, 8443 o 10000) con configure.sh --https-port." ;;
  esac
  case $TS_SSH in
    free) ok "Puerto SSH $GITEA_SSH_PORT de la tailnet libre en Serve." ;;
    ours) ok "El puerto $GITEA_SSH_PORT de Serve ya reenvia el SSH de Gitea ($TS_SSH_DETAIL)." ;;
    *) fail "El puerto $GITEA_SSH_PORT de la tailnet lo usa un servicio ajeno de Serve: $TS_SSH_DETAIL. Use otro con configure.sh --ssh-port." ;;
  esac
  if [[ $TS_FUNNEL == on ]]; then
    fail "Hay Funnel activo sobre un puerto de Gitea. Gitea debe ser privado."
  fi
  [[ -z $TS_FUNNEL_OTHER ]] || warn "Hay Funnel activo en otros servicios de este nodo ($TS_FUNNEL_OTHER); este proyecto no los toca."
}

check_disk() {
  section "Espacio en disco"
  local dir kb
  for dir in "$INSTALL_DIR" "$BACKUP_DIR"; do
    kb=$(avail_kb "$dir")
    if [[ -z $kb ]]; then
      warn "No se pudo medir el espacio disponible para $dir"
    elif (( kb < 1048576 )); then
      fail "Menos de 1 GiB libre para $dir ($(human_kb "$kb"))."
    elif (( kb < 5242880 )); then
      warn "Poco espacio libre para $dir ($(human_kb "$kb")); se recomiendan al menos 5 GiB."
    else
      ok "Espacio libre para $dir: $(human_kb "$kb")"
    fi
  done
  if [[ $(df -Pk -- "$(nearest_existing "$INSTALL_DIR")" | awk 'NR == 2 { print $1 }') == "$(df -Pk -- "$(nearest_existing "$BACKUP_DIR")" | awk 'NR == 2 { print $1 }')" ]]; then
    warn "Los respaldos estan en el MISMO disco que los datos: no protegen ante perdida o dano fisico del servidor. Copie respaldos cifrados a otro medio (docs/BACKUPS.md)."
  fi
}

# Clasifica la instalacion: first | healthy | unhealthy | partial
check_existing_install() {
  section "Instalacion previa"
  local has_compose=0 has_data=0 has_env=0 cids cid="" state="first"
  [[ -f $INSTALL_DIR/compose.yaml ]] && has_compose=1
  [[ -d $INSTALL_DIR/data || -d $INSTALL_DIR/config ]] && has_data=1
  [[ -n $ENV_FILE ]] && has_env=1
  if [[ $DOCKER_OK -eq 1 ]]; then
    cids=$(own_container_ids)
    cid=$(sed -n '1p' <<<"$cids")
  fi
  if [[ -n $cid ]]; then
    local running health
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)
    if [[ $running == true && $health == healthy ]] && http_ok "$(local_url)/api/healthz"; then
      state="healthy"
    else
      state="unhealthy"
      INSTALL_DETAIL="contenedor en ejecucion: ${running:-?}, healthcheck: ${health:-?}"
    fi
  elif [[ $has_compose -eq 1 || $has_data -eq 1 || $has_env -eq 1 ]]; then
    state="partial"
    INSTALL_DETAIL="compose.yaml: $has_compose, data/config: $has_data, .env: $has_env, contenedor: no"
  fi
  case $state in
    first) ok "PRIMERA INSTALACION: no hay compose.yaml, datos ni contenedor propio en $INSTALL_DIR." ;;
    healthy) ok "INSTALACION EXISTENTE SALUDABLE: el contenedor propio funciona. install.sh la conservara (repeticion segura)." ;;
    unhealthy) warn "INSTALACION EXISTENTE CON PROBLEMAS (${INSTALL_DETAIL}). Revise scripts/status.sh y los registros antes de repetir install.sh." ;;
    partial) warn "CONFIGURACION PARCIAL (${INSTALL_DETAIL}). install.sh conservara lo existente y completara lo que falte." ;;
  esac
  [[ $has_data -eq 0 ]] || info "Los datos existentes en $INSTALL_DIR (data/config) se conservaran: install.sh nunca los borra."
  if [[ -n $ENV_FILE ]]; then
    ok "Configuracion encontrada: $ENV_FILE"
  else
    info "Aun no existe .env (lo generara scripts/configure.sh)."
  fi
  INSTALL_STATE=$state
}

check_config() {
  section "Configuracion"
  local before=$CHECK_ERRORS
  if [[ -n $ENV_FILE ]]; then
    validate_config || true
  else
    validate_ports || true
  fi
  [[ $CHECK_ERRORS -ne $before ]] || ok "Variables y puertos validos (web $GITEA_WEB_PORT, ssh local $GITEA_SSH_LOCAL_PORT, ssh tailnet $GITEA_SSH_PORT, https $GITEA_TS_HTTPS_PORT)."
}

check_container_conflicts() {
  section "Conflictos con contenedores y redes actuales"
  if [[ $DOCKER_OK -ne 1 ]]; then
    warn "Se omite: Docker no esta disponible."
    return
  fi
  local name=$CONTAINER_NAME owner_project names networks total
  names=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
  if grep -Fxq -- "$name" <<<"$names"; then
    owner_project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
    if [[ $owner_project == "$PROJECT_NAME" ]]; then
      info "El contenedor '$name' pertenece a este proyecto Compose (instalacion propia)."
    else
      fail "Existe un contenedor ajeno llamado '$name'. Cambie GITEA_CONTAINER_NAME; no se tocara el existente."
    fi
  else
    ok "El nombre de contenedor '$name' esta libre."
  fi
  total=$(docker ps -q | wc -l | tr -d ' ')
  ok "Contenedores en ejecucion detectados: $total (no se modificaran)."
  networks=$(docker network ls --format '{{.Name}}' 2>/dev/null || true)
  if grep -Fxq -- "${PROJECT_NAME}_gitea-net" <<<"$networks"; then
    info "La red ${PROJECT_NAME}_gitea-net ya existe (instalacion previa de este proyecto)."
  else
    ok "Se creara una red propia (${PROJECT_NAME}_gitea-net), aislada de otros proyectos."
  fi
  if docker network inspect -f '{{.Name}} {{index .Labels "com.docker.compose.project"}}' "${PROJECT_NAME}_gitea-net" 2>/dev/null | grep -Eqv " ${PROJECT_NAME}\$"; then
    fail "La red ${PROJECT_NAME}_gitea-net existe pero NO pertenece a este proyecto Compose (conflicto de nombre)."
  fi
}

main() {
  case ${1:-} in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage; exit 2 ;;
  esac
  init_context
  DOCKER_OK=0
  TS_DNS=""
  TS_OK=0
  INSTALL_STATE=first
  INSTALL_DETAIL=""
  printf '%sPreflight de Gitea privado%s (solo lectura)\n' "$C_BOLD" "$C_RESET"
  info "Directorio de instalacion: $INSTALL_DIR | Respaldos: $BACKUP_DIR | Proyecto Compose: $PROJECT_NAME"
  check_system
  check_dependencies
  check_docker
  check_config
  check_tailscale
  check_ports
  check_serve
  check_disk
  check_existing_install
  check_container_conflicts

  section "Resumen"
  printf 'Errores: %s | Advertencias: %s | Estado de la instalacion: %s\n' "$CHECK_ERRORS" "$CHECK_WARNINGS" "$INSTALL_STATE"
  if (( CHECK_ERRORS > 0 )); then
    printf '%s[ERROR]%s Hay conflictos criticos. Corrijalos antes de instalar.\n' "$C_RED" "$C_RESET"
    exit 1
  fi
  ok "Preflight superado. Siguiente paso: scripts/configure.sh y scripts/install.sh"
}

main "$@"
