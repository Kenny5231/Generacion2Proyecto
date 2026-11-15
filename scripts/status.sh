#!/usr/bin/env bash
# status.sh - Estado de solo lectura de Gitea privado. No modifica nada.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
set +e

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  echo "Uso: scripts/status.sh   (muestra contenedor, imagen, puertos, disco, Tailscale, URL y respuesta HTTP)"
  exit 0
fi

init_context
export SUDO_NONINTERACTIVE=1   # solo lectura: si hace falta sudo para leer datos, se omite en vez de pedir contrasena

show_container() {
  section "Contenedor"
  if ! have docker; then
    warn "Docker no esta disponible."
    return
  fi
  if [[ ! -f $INSTALL_DIR/compose.yaml ]]; then
    warn "No hay instalacion en $INSTALL_DIR (falta compose.yaml)."
    return
  fi
  local id
  id=$(container_id)
  if [[ -z $id ]]; then
    warn "El contenedor del proyecto '$PROJECT_NAME' no existe. Ejecute scripts/install.sh"
    return
  fi
  docker inspect -f 'Nombre: {{.Name}}
Estado: {{.State.Status}} (en ejecucion: {{.State.Running}})
Salud: {{if .State.Health}}{{.State.Health.Status}}{{else}}sin healthcheck{{end}}
Iniciado: {{.State.StartedAt}}
Reinicios: {{.RestartCount}}
Politica de reinicio: {{.HostConfig.RestartPolicy.Name}}
Imagen: {{.Config.Image}}' "$id"
  if container_running; then
    ok "Gitea en ejecucion."
    echo "Version en ejecucion: $(dc exec -T gitea gitea --version 2>/dev/null | sed -n '1p')"
  else
    fail "Gitea NO esta en ejecucion. Inicie con: docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml up -d gitea"
  fi
  echo "Version configurada (.env): ${GITEA_VERSION:-no definida}"
  echo "Puertos publicados (deben ser solo 127.0.0.1):"
  container_ports | sed 's/^/  /'
}

show_data() {
  section "Datos y disco"
  echo "Instalacion: $INSTALL_DIR"
  echo "Datos:       $INSTALL_DIR/data"
  echo "Config:      $INSTALL_DIR/config"
  if [[ -r $INSTALL_DIR/data ]]; then
    du -sh -- "$INSTALL_DIR/data" "$INSTALL_DIR/config" 2>/dev/null | sed 's/^/  /'
  else
    info "Sin permiso de lectura sobre data/ (propietario UID $GITEA_UID). Use: sudo du -sh $INSTALL_DIR/data"
  fi
  df -h -- "$(nearest_existing "$INSTALL_DIR")" | sed 's/^/  /'
  echo "Respaldos:   $BACKUP_DIR"
  if [[ -d $BACKUP_DIR ]]; then
    local last
    last=$({ ls -1t -- "$BACKUP_DIR"/*.tar.gz 2>/dev/null || true; } | sed -n '1p')
    if [[ -n $last ]]; then
      echo "  Ultimo respaldo: $last ($(date -r "$last" '+%Y-%m-%d %H:%M'))"
    else
      warn "Aun no hay respaldos. Ejecute scripts/backup.sh"
    fi
    df -h -- "$BACKUP_DIR" | sed 's/^/  /'
  else
    warn "El directorio de respaldos todavia no existe."
  fi
}

show_tailscale() {
  section "Tailscale"
  if ! have tailscale; then
    warn "Tailscale no esta instalado."
    return
  fi
  local state
  state=$(ts_state)
  if [[ $state == "Running" ]]; then
    ok "Tailscale conectado. DNS: $(ts_self_dns) (version $(ts_version))"
  else
    fail "Tailscale no esta conectado (estado: ${state:-desconocido})."
  fi
  echo "Tailscale Serve:"
  tailscale serve status 2>&1 | sed 's/^/  /'
}

show_http() {
  section "Acceso"
  local code
  echo "URL privada (Tailscale Serve HTTPS $GITEA_TS_HTTPS_PORT): ${GITEA_ROOT_URL:-no configurada}"
  echo "SSH de Git (Tailscale Serve TCP $GITEA_SSH_PORT): ssh://git@${GITEA_SSH_DOMAIN:-?}:${GITEA_SSH_PORT}/<usuario>/<repo>.git"
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$(local_url)/api/healthz" 2>/dev/null)
  if [[ $code =~ ^2 ]]; then
    ok "HTTP local $(local_url): $code"
  else
    fail "HTTP local $(local_url): ${code:-sin respuesta}"
  fi
  if [[ -n ${GITEA_ROOT_URL:-} ]]; then
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$GITEA_ROOT_URL" 2>/dev/null)
    if [[ $code =~ ^[23] ]]; then
      ok "HTTPS privado $GITEA_ROOT_URL: $code"
    else
      warn "HTTPS privado $GITEA_ROOT_URL: ${code:-sin respuesta} (active Serve con scripts/configure-tailscale.sh)"
    fi
  fi
  local keys
  keys=$(as_data_owner sh -c "ls $INSTALL_DIR/data/data/ssh/*.pub 2>/dev/null" 2>/dev/null || true)
  if [[ -n $keys ]]; then
    echo "Huellas SSH del servidor Git (compare con la que muestra su cliente al conectar):"
    local f
    while IFS= read -r f; do
      as_data_owner ssh-keygen -lf "$f" 2>/dev/null | sed 's/^/  /'
    done <<<"$keys"
  else
    echo "Huellas SSH del servidor Git: aun no hay claves (se crean al iniciar Gitea) o falta permiso. Use:"
    echo "  sudo sh -c 'for f in $INSTALL_DIR/data/data/ssh/*.pub; do ssh-keygen -lf \$f; done'"
    echo "  o, sin permisos en el servidor, desde cualquier equipo de la tailnet: ssh-keyscan -p $GITEA_SSH_PORT ${GITEA_SSH_DOMAIN:-<dns>} | ssh-keygen -lf -"
  fi
}

show_commands() {
  section "Comandos utiles"
  cat <<EOF
Registros (en vivo): docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml logs -f --tail 100 gitea
Recursos:            docker stats --no-stream ${CONTAINER_NAME}
Iniciar / detener:   docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml start gitea | stop gitea | restart gitea
EOF
}

show_container
show_data
show_tailscale
show_http
report_states
show_commands
