#!/usr/bin/env bash
# smoke-test.sh - Pruebas de funcionamiento en el servidor (requiere la instalacion real).
# Por defecto solo lee. Las pruebas que reinician o recrean Gitea requieren opciones explicitas.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/smoke-test.sh [--ssh-alias ALIAS] [--recreate-test [--yes]]
  --ssh-alias ALIAS   Prueba la autenticacion SSH con 'ssh -T ALIAS' (alias de ~/.ssh/config con su
                      clave ya registrada en Gitea). Normalmente se ejecuta desde Windows
                      (vea windows/setup-git.ps1); si se omite, esa prueba se marca como OMITIDA.
  --recreate-test     Recrea el contenedor de Gitea (breve interrupcion) y comprueba que los datos
                      persisten y que el servicio responde despues. Pide confirmacion (--yes la acepta).
Por defecto solo lee. Codigo de salida: 0 si todo lo ejecutado paso; 1 si alguna prueba fallo.
EOF
}

SSH_ALIAS=""
RECREATE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-alias) [[ $# -ge 2 ]] || die "--ssh-alias requiere un valor."; SSH_ALIAS=$2; shift 2 ;;
    --recreate-test) RECREATE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Opcion desconocida: $1" ;;
  esac
done
[[ -z $SSH_ALIAS || $SSH_ALIAS =~ ^[A-Za-z0-9._-]+$ ]] || die "Alias SSH invalido."

init_context
SKIPPED=0
skip() { SKIPPED=$((SKIPPED + 1)); printf '[OMITIDA] %s\n' "$*"; }

test_compose() {
  local out
  if out=$(dc config -q 2>&1); then
    ok "Docker Compose valido."
  else
    fail "Docker Compose invalido: $out"
  fi
}

test_container() {
  if container_running; then
    ok "Contenedor de Gitea en ejecucion."
  else
    fail "El contenedor de Gitea no esta en ejecucion."
  fi
}

test_http_local() {
  if wait_for_gitea 30; then
    ok "Servicio web local responde en $(local_url)."
  else
    fail "El servicio web local no responde en $(local_url)."
  fi
}

test_no_public_ports() {
  local id ports listeners
  id=$(container_id)
  [[ -n $id ]] || { skip "Puertos publicados (no hay contenedor)."; return; }
  ports=$(container_ports)
  if ports_loopback_only; then
    ok "Docker publica solo 127.0.0.1:${GITEA_WEB_PORT} (HTTP) y 127.0.0.1:${GITEA_SSH_LOCAL_PORT} (SSH)."
  else
    fail "Puertos publicados inesperados (se esperaba solo 127.0.0.1:${GITEA_WEB_PORT} y 127.0.0.1:${GITEA_SSH_LOCAL_PORT}): ${ports:-ninguno detectado}"
  fi
  if have ss; then
    listeners=$(ss -H -ltn 2>/dev/null | awk '{ print $4 }' | grep -E ":(${GITEA_WEB_PORT}|${GITEA_SSH_LOCAL_PORT})$" | grep -Ev '^127\.0\.0\.1:' || true)
    if [[ -z $listeners ]]; then
      ok "Ningun oyente en interfaces no locales para los puertos ${GITEA_WEB_PORT} y ${GITEA_SSH_LOCAL_PORT}."
    else
      fail "Hay oyentes fuera de 127.0.0.1 en los puertos de Gitea: ${listeners//$'\n'/, }"
    fi
  else
    skip "Oyentes locales (falta 'ss')."
  fi
}

test_health() {
  local state
  state=$(container_health)
  if [[ $state == healthy ]]; then ok "Healthcheck de Docker: healthy."; else fail "Healthcheck de Docker: $state."; fi
  local v
  v=$(running_gitea_version)
  if [[ $v == "$GITEA_VERSION" ]]; then ok "Version en ejecucion: $v (coincide con .env)."; else fail "Version en ejecucion '${v:-desconocida}' distinta de .env ($GITEA_VERSION)."; fi
}

test_ssh_local() {
  local banner
  banner=$(ssh_banner 127.0.0.1 "$GITEA_SSH_LOCAL_PORT")
  if [[ $banner == SSH-* ]]; then
    ok "SSH de Git responde en 127.0.0.1:$GITEA_SSH_LOCAL_PORT ($banner)."
  else
    fail "No hay banner SSH en 127.0.0.1:$GITEA_SSH_LOCAL_PORT."
  fi
}

test_install_state() {
  local rc=0
  installer_locked || rc=$?
  case $rc in
    0) ok "Asistente de instalacion completado (INSTALL_LOCK=true)." ;;
    1) skip "Asistente de instalacion de Gitea pendiente (cuenta administradora sin crear)." ;;
    *) skip "No se pudo leer config/app.ini (se necesita sudo)." ;;
  esac
}

test_database() {
  local db
  db=$(gitea_db_path)
  if ! can_access_data; then skip "Base de datos (se necesita sudo)."; return; fi
  if ! as_data_owner test -f "$db"; then skip "Base de datos aun no creada (asistente pendiente)."; return; fi
  if sqlite_integrity_ok "$db"; then ok "Base de datos SQLite: integrity_check correcto."; else fail "Base de datos SQLite danada o ilegible: $db"; fi
}

test_backups() {
  local last
  last=$({ ls -1t -- "$BACKUP_DIR"/*.tar.gz 2>/dev/null || true; } | sed -n '1p')
  if [[ -z $last ]]; then
    skip "Respaldos: aun no hay ninguno (scripts/backup.sh)."
  elif (cd -- "$(dirname -- "$last")" && sha256sum -c --quiet -- "$(basename -- "$last").sha256" >/dev/null 2>&1); then
    ok "Ultimo respaldo con SHA-256 correcto: $(basename -- "$last")."
  else
    fail "El ultimo respaldo no supera su SHA-256: $last"
  fi
}

test_tailscale() {
  if ! have tailscale; then
    fail "Tailscale no esta instalado."
    return
  fi
  if [[ $(ts_state) == "Running" ]]; then
    ok "Tailscale conectado."
  else
    fail "Tailscale no esta conectado."
    return
  fi
  local json
  if ! json=$(ts_serve_json); then
    skip "Tailscale Serve (no se pudo leer sin contrasena; use sudo)."
    return
  fi
  if ! ts_serve_inspect "$json"; then
    fail "No se reconoce 'tailscale serve status --json' (${TS_REASON:-sin motivo})."
    return
  fi
  if [[ $TS_HTTPS == ours ]]; then ok "Serve: HTTPS $GITEA_TS_HTTPS_PORT -> http://127.0.0.1:$GITEA_WEB_PORT."; else fail "Serve: HTTPS de Gitea no esta configurado correctamente ($TS_HTTPS: $TS_HTTPS_DETAIL). Ejecute scripts/configure-tailscale.sh"; fi
  if [[ $TS_SSH == ours ]]; then ok "Serve: TCP $GITEA_SSH_PORT -> tcp://127.0.0.1:$GITEA_SSH_LOCAL_PORT."; else fail "Serve: SSH de Gitea no esta configurado correctamente ($TS_SSH: $TS_SSH_DETAIL). Ejecute scripts/configure-tailscale.sh"; fi
  if [[ $TS_FUNNEL == on ]]; then fail "Funnel activo sobre un puerto de Gitea (exposicion publica)."; else ok "Sin Funnel en los puertos de Gitea."; fi
}

test_https() {
  local code
  code=$(curl -sS -o /dev/null -m 20 -w '%{http_code}' "$GITEA_ROOT_URL" 2>/dev/null || true)
  if [[ $code =~ ^[23][0-9][0-9]$ ]]; then
    ok "HTTPS privado responde: $GITEA_ROOT_URL (HTTP $code)."
  else
    fail "HTTPS privado no responde en $GITEA_ROOT_URL (codigo: ${code:-ninguno}). Active Tailscale Serve: scripts/configure-tailscale.sh"
  fi
}

test_ssh_banner() {
  local banner host=$GITEA_SSH_DOMAIN
  banner=$(ssh_banner "$host" "$GITEA_SSH_PORT")
  if [[ $banner == SSH-* ]]; then
    ok "SSH Git responde por la tailnet en $host:$GITEA_SSH_PORT ($banner)."
  else
    fail "No hay banner SSH en $host:$GITEA_SSH_PORT desde este servidor (pruebe tambien desde Windows: ssh -T ALIAS)."
  fi
}

test_ssh_auth() {
  if [[ -z $SSH_ALIAS ]]; then
    skip "Autenticacion SSH (use --ssh-alias ALIAS o ejecute 'ssh -T git-privado' desde Windows)."
    return
  fi
  local out
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T "$SSH_ALIAS" 2>&1 || true)
  if grep -qi 'successfully authenticated' <<<"$out"; then
    ok "Autenticacion SSH correcta con el alias '$SSH_ALIAS'."
  else
    fail "Autenticacion SSH fallida con '$SSH_ALIAS': $(sed -n '1p' <<<"$out")"
  fi
}

test_mounts() {
  local id mounts
  id=$(container_id)
  [[ -n $id ]] || { skip "Montajes persistentes (no hay contenedor)."; return; }
  mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' "$id")
  if grep -Fxq "$(realpath -- "$INSTALL_DIR")/data /var/lib/gitea" <<<"$mounts" && grep -Fxq "$(realpath -- "$INSTALL_DIR")/config /etc/gitea" <<<"$mounts"; then
    ok "Persistencia: data -> /var/lib/gitea y config -> /etc/gitea (bind mounts en el disco)."
  else
    fail "Los bind mounts de persistencia no son los esperados: $mounts"
  fi
}

test_recreate() {
  if [[ $RECREATE -ne 1 ]]; then
    skip "Persistencia tras recrear el contenedor (use --recreate-test)."
    return
  fi
  if ! confirm "Recrear el contenedor de Gitea (breve interrupcion del servicio; datos intactos)?"; then
    skip "Recreacion cancelada (sin confirmacion; --yes la acepta)."
    return
  fi
  SUDO_NONINTERACTIVE=0
  local marker old_id new_id
  marker="$INSTALL_DIR/data/.smoke-marker-$(timestamp)"
  old_id=$(container_id)
  as_data_owner touch -- "$marker"
  info "Recreando solo el servicio gitea..."
  dc up -d --force-recreate gitea >/dev/null
  new_id=$(container_id)
  if [[ -n $old_id && $old_id != "$new_id" ]]; then
    ok "El contenedor fue reemplazado."
  else
    fail "El contenedor no fue reemplazado."
  fi
  if as_data_owner test -e "$marker"; then
    ok "Los datos persisten despues de reemplazar el contenedor."
  else
    fail "El marcador de prueba desaparecio: la persistencia no funciona."
  fi
  as_data_owner rm -f -- "$marker" # seguro: archivo marcador creado por esta prueba
  if wait_for_gitea 120; then
    ok "Gitea responde despues de recrearse."
  else
    fail "Gitea no responde despues de recrearse."
  fi
}

main() {
  need_cmd docker
  [[ -f $INSTALL_DIR/compose.yaml ]] || die "No hay instalacion en $INSTALL_DIR."
  validate_config || die "El .env no es valido."
  SUDO_NONINTERACTIVE=1
  printf '%sPruebas de funcionamiento%s\n' "$C_BOLD" "$C_RESET"
  test_compose
  test_container
  test_health
  test_http_local
  test_no_public_ports
  test_ssh_local
  test_mounts
  test_install_state
  test_database
  test_backups
  test_tailscale
  test_https
  test_ssh_banner
  test_ssh_auth
  test_recreate

  section "Resumen"
  printf 'Fallos: %s | Omitidas: %s | Advertencias: %s\n' "$CHECK_ERRORS" "$SKIPPED" "$CHECK_WARNINGS"
  cat <<'EOF'
Recuerde: estas pruebas NO sustituyen la prueba integral manual (clone/push/pull desde Windows, reinicio,
respaldo y restauracion en un entorno separado): docs/INSTALACION-MANANA.md, Fase 11. Las OMITIDAS no se ejecutaron.
EOF
  if (( CHECK_ERRORS > 0 )); then
    exit 1
  fi
  ok "Todas las pruebas ejecutadas pasaron."
}

main
