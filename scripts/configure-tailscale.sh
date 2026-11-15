#!/usr/bin/env bash
# configure-tailscale.sh - Publica Gitea en la tailnet con Tailscale Serve (dos servicios privados).
#
#   1. HTTPS: <DNS>:<GITEA_TS_HTTPS_PORT>  ->  http://127.0.0.1:<GITEA_WEB_PORT>
#   2. SSH Git (TCP): <DNS>:<GITEA_SSH_PORT> ->  tcp://127.0.0.1:<GITEA_SSH_LOCAL_PORT>
#
# Garantias: nunca usa Funnel, nunca ejecuta 'tailscale serve reset' ni 'off', nunca toca el firewall,
# las ACL/grants ni la configuracion global de Tailscale, y no reemplaza servicios ajenos. La configuracion
# existente se analiza como JSON (scripts/tsjson.py), no con busquedas de texto. Es repetible.
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat <<'EOF'
Uso: scripts/configure-tailscale.sh [opciones]
  --https-port N              Puerto HTTPS de Serve (443, 8443 o 10000). Por defecto el de .env.
  --dry-run                   Solo analiza y muestra los comandos; no cambia nada.
  --yes                       Acepta la confirmacion de agregar Serve junto a servicios existentes.
  --allow-unfinished-installer
                              Publica aunque el asistente de Gitea aun no este completado
                              (NO recomendado: cualquiera en su tailnet con acceso podria crear el administrador).
  -h, --help                  Muestra esta ayuda.

Comandos que ejecuta (sintaxis oficial de 'tailscale serve', Tailscale 1.52 o posterior):
  sudo tailscale serve --bg --https=<puerto_https> http://127.0.0.1:<GITEA_WEB_PORT>
  sudo tailscale serve --bg --tcp=<GITEA_SSH_PORT> tcp://127.0.0.1:<GITEA_SSH_LOCAL_PORT>
Referencia: https://tailscale.com/docs/reference/tailscale-cli/serve
EOF
}

ARG_HTTPS=""
DRY_RUN=0
ALLOW_UNFINISHED=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --https-port) [[ $# -ge 2 ]] || die "--https-port requiere un valor."; ARG_HTTPS=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --allow-unfinished-installer) ALLOW_UNFINISHED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Opcion desconocida: $1" ;;
  esac
done

HTTPS_PORT=""
HTTPS_TARGET=""
SSH_TARGET=""
SERVE_JSON=""

serve_cmd() { # imprime el comando como arreglo listo para ejecutar (con sudo si hace falta)
  if [[ $EUID -ne 0 ]]; then printf 'sudo '; fi
  printf '%s ' tailscale serve "$@"
  printf '\n'
}

run_serve() {
  if [[ $EUID -ne 0 ]]; then
    sudo tailscale serve "$@"
  else
    tailscale serve "$@"
  fi
}

print_manual_alternatives() {
  cat <<EOF

Alternativa privada y segura mientras tanto (no abre ningun puerto publico):
  - Acceso web y SSH por un tunel SSH administrativo hacia 127.0.0.1 (ejemplo; sustituya los datos reales):
      ssh -L ${GITEA_WEB_PORT}:127.0.0.1:${GITEA_WEB_PORT} -L ${GITEA_SSH_LOCAL_PORT}:127.0.0.1:${GITEA_SSH_LOCAL_PORT} <USUARIO_ADMIN>@<HOST_ADMIN_DEL_SERVIDOR>
    y use http://localhost:${GITEA_WEB_PORT} y ssh://git@localhost:${GITEA_SSH_LOCAL_PORT}/<usuario>/<repo>.git
  - Nunca recurra a 0.0.0.0 ni a Funnel.
EOF
}

show_target_table() {
  cat <<EOF
Servicios de Gitea en Tailscale Serve (solo dentro de su tailnet):
  HTTPS  ${GITEA_TS_DNS}:${HTTPS_PORT}   ->  ${HTTPS_TARGET}
  SSH    ${GITEA_TS_DNS}:${GITEA_SSH_PORT}   ->  ${SSH_TARGET}  (TCP sin terminar TLS)
EOF
}

revert_help() {
  cat <<EOF

Para completar solo lo que falta:   scripts/configure-tailscale.sh   (es repetible)
Para revertir SOLO los servicios de Gitea (no toca nada mas):
  sudo tailscale serve --https=${HTTPS_PORT} off
  sudo tailscale serve --tcp=${GITEA_SSH_PORT} off
(este proyecto nunca ejecuta 'off' ni 'reset' por si solo)
EOF
}

# Relee Serve y devuelve el estado de un servicio: free|ours|foreign
reread_state() { # https|ssh
  local json
  json=$(ts_serve_json interactive) || return 2
  TS_CHECK_HTTPS_PORT=$HTTPS_PORT ts_serve_inspect "$json" || return 3
  if [[ $1 == https ]]; then printf '%s' "$TS_HTTPS"; else printf '%s' "$TS_SSH"; fi
}

main() {
  init_context
  [[ -n $ENV_FILE ]] || die "No existe .env. Ejecute primero scripts/configure.sh"
  validate_config || die "El .env no es valido; corrijalo con scripts/configure.sh --regenerate"

  need_cmd tailscale
  need_cmd python3
  local state dns
  state=$(ts_state)
  [[ $state == "Running" ]] || { ts_help; die "Tailscale no esta conectado (estado: ${state:-desconocido})."; }
  dns=$(ts_self_dns)
  [[ $dns == "$GITEA_TS_DNS" ]] || die "El DNS de Tailscale (${dns:-desconocido}) no coincide con .env ($GITEA_TS_DNS). Ejecute configure.sh --regenerate."

  HTTPS_PORT=${ARG_HTTPS:-$GITEA_TS_HTTPS_PORT}
  case $HTTPS_PORT in
    443|8443|10000) ;;
    *) die "Puerto HTTPS no admitido: $HTTPS_PORT (use 443, 8443 o 10000)." ;;
  esac
  [[ $HTTPS_PORT != "$GITEA_SSH_PORT" ]] || die "El puerto HTTPS ($HTTPS_PORT) no puede coincidir con GITEA_SSH_PORT."
  HTTPS_TARGET="http://127.0.0.1:$GITEA_WEB_PORT"
  SSH_TARGET="tcp://127.0.0.1:$GITEA_SSH_LOCAL_PORT"

  section "Compatibilidad del cliente Tailscale"
  if ! ts_serve_supported; then
    fail "El cliente Tailscale ($(ts_version || true)) no admite 'serve --tcp' (se necesita 1.52 o posterior). No se configura nada."
    print_manual_alternatives
    die "Actualice Tailscale con el procedimiento oficial (https://tailscale.com/download/linux) y repita."
  fi
  ok "Tailscale $(ts_version): admite 'serve --https' y 'serve --tcp'."
  if [[ ! $(ts_cert_domains) =~ ^[1-9][0-9]*$ ]]; then
    warn "Tailscale no informa dominios de certificado: habilite MagicDNS y HTTPS en https://login.tailscale.com/admin/dns antes de publicar HTTPS."
  fi

  section "Asistente de instalacion de Gitea"
  if installer_locked; then
    ok "El asistente ya esta completado (INSTALL_LOCK=true): es seguro publicar."
  elif [[ $ALLOW_UNFINISHED -eq 1 ]]; then
    warn "El asistente NO esta completado y se publicara igualmente (--allow-unfinished-installer)."
  else
    fail "El asistente de instalacion de Gitea aun no se completo (o no se pudo comprobar INSTALL_LOCK)."
    cat <<EOF
Publicar ahora permitiria que cualquier dispositivo autorizado de su tailnet cree la cuenta administradora.
Complete primero el asistente por un tunel SSH administrativo (docs/INSTALACION-MANANA.md, Fase 7):
  ssh -L ${GITEA_WEB_PORT}:127.0.0.1:${GITEA_WEB_PORT} <USUARIO_ADMIN>@<HOST_ADMIN_DEL_SERVIDOR>    y abra http://localhost:${GITEA_WEB_PORT}
y repita este script. Si su politica de Tailscale ya limita el acceso solo a usted, puede usar --allow-unfinished-installer.
EOF
    exit 1
  fi

  section "Configuracion actual de Tailscale Serve"
  local existing=1
  if ! SERVE_JSON=$(ts_serve_json interactive); then
    die "No se pudo leer 'tailscale serve status --json'. Ejecute con un usuario con sudo o con 'sudo tailscale set --operator=\$USER' (cambio que usted debe autorizar)."
  fi
  if ts_serve_is_empty "$SERVE_JSON"; then
    existing=0
    ok "No hay configuracion de Serve previa."
  else
    tailscale serve status 2>/dev/null || sudo tailscale serve status 2>/dev/null || true
  fi
  TS_CHECK_HTTPS_PORT=$HTTPS_PORT
  if ! ts_serve_inspect "$SERVE_JSON"; then
    fail "No se reconoce la estructura de 'tailscale serve status --json' (${TS_REASON:-sin motivo}). No se modifico nada."
    printf '%s\n' "--- JSON recibido (para revision) ---"
    printf '%s\n' "$SERVE_JSON" | head -c 4000
    printf '\n%s\n' "--- fin ---"
    die "Revise el JSON y configure Serve manualmente con los comandos de --help, o actualice este proyecto."
  fi
  show_target_table
  info "HTTPS $HTTPS_PORT: $TS_HTTPS ($TS_HTTPS_DETAIL) | SSH $GITEA_SSH_PORT: $TS_SSH ($TS_SSH_DETAIL)"
  if [[ $TS_FUNNEL == on ]]; then
    fail "Funnel esta activo sobre un puerto de Gitea. Gitea debe ser privado: desactive Funnel para ese puerto con el subcomando 'off' de Funnel (vea la documentacion de Tailscale). Este script nunca usa Funnel."
    exit 1
  fi
  [[ -z $TS_FUNNEL_OTHER ]] || warn "Hay Funnel activo en otros servicios de este nodo ($TS_FUNNEL_OTHER); no se tocan."

  local blocked=0
  if [[ $TS_HTTPS == foreign ]]; then
    fail "El puerto HTTPS $HTTPS_PORT ya lo usa un servicio ajeno a Gitea: $TS_HTTPS_DETAIL"
    blocked=1
  fi
  if [[ $TS_SSH == foreign ]]; then
    fail "El puerto SSH $GITEA_SSH_PORT de la tailnet ya lo usa un servicio ajeno a Gitea: $TS_SSH_DETAIL"
    blocked=1
  fi
  if [[ $blocked -eq 1 ]]; then
    cat <<EOF
No se modifico nada (no se pisan servicios ajenos). Opciones:
  1. Otro puerto HTTPS:  scripts/configure-tailscale.sh --https-port 8443   (443, 8443 o 10000)
  2. Otro puerto SSH:    scripts/configure.sh --regenerate --ssh-port <N>   y repita este script
  3. Liberar el puerto SOLO si esta seguro de que ya no se necesita (lo decide usted, no este proyecto):
       sudo tailscale serve --https=$HTTPS_PORT off     o     sudo tailscale serve --tcp=$GITEA_SSH_PORT off
EOF
    exit 1
  fi

  if [[ $TS_HTTPS == ours && $TS_SSH == ours ]]; then
    ok "Los dos servicios de Gitea ya estan publicados. Sin cambios."
    verify_end_to_end
    return 0
  fi

  local https_cmd ssh_cmd
  https_cmd=$(serve_cmd --bg "--https=$HTTPS_PORT" "$HTTPS_TARGET")
  ssh_cmd=$(serve_cmd --bg "--tcp=$GITEA_SSH_PORT" "$SSH_TARGET")
  section "Cambios previstos (solo se agrega; nada existente se reemplaza)"
  [[ $TS_HTTPS == ours ]] && info "HTTPS: ya configurado." || info "HTTPS: $https_cmd"
  [[ $TS_SSH == ours ]] && info "SSH:   ya configurado." || info "SSH:   $ssh_cmd"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "Modo --dry-run: no se ejecuto nada."
    return 0
  fi
  if [[ $existing -eq 1 ]]; then
    warn "Existen otros servicios de Serve. Solo se agregan los de Gitea, sin tocar los demas."
    confirm "Continuar?" || die "Cancelado por el usuario; no se modifico nada."
  fi

  local https_done=0 ssh_done=0
  [[ $TS_HTTPS == ours ]] && https_done=1
  [[ $TS_SSH == ours ]] && ssh_done=1

  if [[ $https_done -eq 0 ]]; then
    if run_serve --bg "--https=$HTTPS_PORT" "$HTTPS_TARGET" && [[ $(reread_state https || true) == ours ]]; then
      https_done=1
      ok "HTTPS de Gitea publicado y verificado en la configuracion de Serve."
    else
      fail "No se pudo publicar (o verificar) el HTTPS. Si pide habilitar HTTPS/certificados, hagalo en https://login.tailscale.com/admin/dns y repita."
      report_partial "$https_done" "$ssh_done"
      exit 2
    fi
  fi
  if [[ $ssh_done -eq 0 ]]; then
    if run_serve --bg "--tcp=$GITEA_SSH_PORT" "$SSH_TARGET" && [[ $(reread_state ssh || true) == ours ]]; then
      ssh_done=1
      ok "SSH de Git publicado y verificado en la configuracion de Serve."
    else
      fail "No se pudo publicar (o verificar) el SSH de Git."
      report_partial "$https_done" "$ssh_done"
      exit 2
    fi
  fi
  ok "Tailscale Serve configurado: HTTPS y SSH (solo dentro de su tailnet; sin Funnel)."

  if [[ $HTTPS_PORT != "$GITEA_TS_HTTPS_PORT" ]]; then
    local new_url
    new_url=$(build_root_url "$GITEA_TS_DNS" "$HTTPS_PORT")
    warn "El puerto HTTPS elegido ($HTTPS_PORT) difiere de .env ($GITEA_TS_HTTPS_PORT); la URL publica de Gitea debe ser $new_url"
    if confirm "Actualizar .env y recrear solo el contenedor de Gitea para aplicar la nueva URL?"; then
      env_set "$ENV_FILE" GITEA_TS_HTTPS_PORT "$HTTPS_PORT"
      env_set "$ENV_FILE" GITEA_ROOT_URL "$new_url"
      GITEA_TS_HTTPS_PORT=$HTTPS_PORT
      GITEA_ROOT_URL=$new_url
      dc up -d gitea
    else
      info "Edite GITEA_TS_HTTPS_PORT y GITEA_ROOT_URL en $ENV_FILE y ejecute: docker compose -p $PROJECT_NAME -f $INSTALL_DIR/compose.yaml up -d gitea"
    fi
  fi
  verify_end_to_end
}

report_partial() { # https_ok ssh_ok
  section "ESTADO PARCIAL"
  [[ $1 -eq 1 ]] && ok "HTTPS: publicado." || fail "HTTPS: NO publicado."
  [[ $2 -eq 1 ]] && ok "SSH:   publicado." || fail "SSH:   NO publicado."
  echo "No se elimino nada de lo ya configurado."
  revert_help
}

verify_end_to_end() {
  local code url banner ts_ip
  url=$(build_root_url "$GITEA_TS_DNS" "$HTTPS_PORT")
  section "Verificacion (desde este servidor; pruebe tambien desde otro equipo de su tailnet)"
  code=$(curl -sS -o /dev/null -m 20 -w '%{http_code}' "$url" 2>/dev/null || true)
  if [[ $code =~ ^[23][0-9][0-9]$ ]]; then
    ok "HTTPS privado responde: $url (HTTP $code)"
  else
    warn "Sin respuesta en $url (codigo: ${code:-ninguno}). Los certificados pueden tardar unos minutos; pruebe desde otro equipo."
  fi
  ts_ip=$(ts_ip4)
  banner=""
  [[ -z $ts_ip ]] || banner=$(ssh_banner "$ts_ip" "$GITEA_SSH_PORT")
  if [[ $banner == SSH-* ]]; then
    ok "SSH privado responde en ${ts_ip}:${GITEA_SSH_PORT} ($banner)"
  else
    warn "Sin banner SSH en la tailnet (${ts_ip:-sin IP}:$GITEA_SSH_PORT) desde este servidor. Pruebe desde Windows: ssh -T git-privado"
  fi
  cat <<EOF

Ver configuracion:  tailscale serve status
$(revert_help)
EOF
}

main
