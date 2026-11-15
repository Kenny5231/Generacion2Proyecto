#!/usr/bin/env bash
# test-lifecycle.sh - Prueba LOCAL de la logica de los scripts con comandos SIMULADOS.
#
# IMPORTANTE: simula docker, tailscale, curl, ss, sudo y timeout con "stubs" en un directorio temporal. Valida la
# logica de los scripts (configure, preflight, install, backup, restore, update, Tailscale Serve, rollback, bloqueo,
# reinicio tras fallos), NO el comportamiento real de Docker, Tailscale ni Gitea: eso solo puede verificarse en el
# servidor (scripts/preflight.sh, install.sh, smoke-test.sh y la prueba integral de docs/INSTALACION-MANANA.md).
# Nada de lo que aqui pasa debe presentarse como prueba de integracion real. No toca /srv ni ningun contenedor real.
set -Eeuo pipefail
if [[ ${LIFECYCLE_CHILD:-0} != 1 ]] && command -v timeout >/dev/null 2>&1; then
  limit=${LIFECYCLE_TIMEOUT:-600}
  exec timeout --signal=TERM --kill-after=10 "${limit}s" env LIFECYCLE_CHILD=1 bash "$0" "$@"
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  [PASA]     %s\n' "$*"; }
nope() { FAIL=$((FAIL + 1)); printf '  [FALLA]    %s\n' "$*"; }
SKIP=0
skip() { SKIP=$((SKIP + 1)); printf '  [OMITIDA]  %s\n' "$*"; }
GROUP_STARTED=$SECONDS
GROUP_NAME="inicio"
section() {
  if [[ $GROUP_NAME != inicio ]]; then printf '[DURACION] %s: %ss\n' "$GROUP_NAME" "$((SECONDS - GROUP_STARTED))"; fi
  GROUP_NAME=$*; GROUP_STARTED=$SECONDS; printf '\n== %s ==\n[EJECUTANDO] grupo %s\n' "$GROUP_NAME" "$GROUP_NAME"
}
check() {
  local d=$1 start=$SECONDS elapsed; shift
  printf '  [EJECUTANDO] %s\n' "$d"
  if "$@"; then
    elapsed=$((SECONDS - start)); pass "$d (${elapsed}s)"
  else
    elapsed=$((SECONDS - start)); nope "$d (${elapsed}s)"
  fi
}
has() { grep -q -- "$1" "$2"; }
hasnt() { ! grep -q -- "$1" "$2"; }

if [[ $(uname -s) != "Linux" ]]; then
  skip "Requiere Linux (use WSL o Ubuntu)."
  printf 'Pasan: %s | Fallan: %s | Omitidas: %s\n' "$PASS" "$FAIL" "$SKIP"
  exit 2
fi
for tool in timeout tar gzip sha256sum flock awk sed realpath install python3; do
  command -v "$tool" >/dev/null 2>&1 || { skip "Falta $tool."; printf 'Pasan: %s | Fallan: %s | Omitidas: %s\n' "$PASS" "$FAIL" "$SKIP"; exit 2; }
done

TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; } # seguro: solo el directorio temporal propio creado con mktemp
trap cleanup EXIT
trap 'exit 143' TERM INT
BIN="$TMP/bin"
BIN_NOTS="$TMP/bin-sin-tailscale"
STATE="$TMP/state"
INSTALL="$TMP/srv/gitea-privado"
BACKUPS="$TMP/srv/backups"
mkdir -p "$BIN" "$BIN_NOTS" "$STATE" "$INSTALL" "$BACKUPS"
REAL_TAR="$(command -v tar)"
REAL_INSTALL="$(command -v install)"
REAL_MV="$(command -v mv)"

# ---------------------------------------------------------------- stubs
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
S=$FAKE_STATE
echo "docker $*" >>"$S/calls.log"
inst() { cat "$S/install_dir" 2>/dev/null || true; }
env_val() { sed -n "s/^$1=//p" "$(inst)/.env" 2>/dev/null | head -n 1; }
healthy() {
  [[ -e $S/running && ! -e $S/unhealthy ]] || return 1
  local d; d=$(inst)
  [[ -z $d || ! -e $d/data/POISON ]]
}
case ${1:-} in
  --version) echo "Docker version 99.0.0 (simulado)"; exit 0 ;;
  info) exit 0 ;;
  pull)
    [[ -z ${FAKE_PULL_FAIL:-} || $2 != *"$FAKE_PULL_FAIL"* ]] || exit 1
    echo "$2" >>"$S/images"; exit 0 ;;
  image) [[ $2 == inspect ]] && grep -Fxq -- "$3" "$S/images" 2>/dev/null; exit $? ;;
  ps)
    case "$*" in
      *"-a -q"*) [[ -e $S/created ]] && echo fakecid123; exit 0 ;;
      *"--format"*) echo otro-contenedor; [[ -e $S/created ]] && echo gitea-privado; exit 0 ;;
      *"-q"*) [[ -e $S/running ]] && echo fakecid123; echo othercid; exit 0 ;;
    esac
    exit 0 ;;
  network) [[ $2 == ls ]] && echo bridge; [[ $2 == ls ]] || exit 1; exit 0 ;;
  port)
    w=$(env_val GITEA_WEB_PORT); w=${w:-3090}; l=$(env_val GITEA_SSH_LOCAL_PORT); l=${l:-2222}
    if [[ -n ${FAKE_PORTS_BAD:-} ]]; then echo "3000/tcp -> 0.0.0.0:$w"; else echo "3000/tcp -> 127.0.0.1:$w"; fi
    echo "2222/tcp -> 127.0.0.1:$l"; exit 0 ;;
  inspect)
    case "$*" in
      *Labels*) echo gitea-privado ;;
      *State.Running*) [[ -e $S/running ]] && echo true || echo false ;;
      *State.Health*) if healthy; then echo healthy; elif [[ -e $S/running ]]; then echo unhealthy; else echo exited; fi ;;
      *RestartCount*) echo 0 ;;
      *Config.Image*) cat "$S/image" 2>/dev/null || echo "docker.gitea.com/gitea:28.3.0-rootless" ;;
      *Mounts*) d=$(realpath "$(inst)"); printf '%s/data /var/lib/gitea\n%s/config /etc/gitea\n' "$d" "$d" ;;
    esac
    exit 0 ;;
  compose)
    shift
    sub=""; pd=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        --project-directory) pd=$2; shift 2 ;;
        --project-name|-p|-f|--env-file) shift 2 ;;
        version) echo "2.99.0"; exit 0 ;;
        *) sub=$1; shift; break ;;
      esac
    done
    case $sub in
      config)
        if [[ ${1:-} != "-q" ]]; then
          ver=$(sed -n 's/^GITEA_VERSION=//p' "$pd/.env" 2>/dev/null | head -n 1)
          w=$(sed -n 's/^GITEA_WEB_PORT=//p' "$pd/.env" | head -n 1); l=$(sed -n 's/^GITEA_SSH_LOCAL_PORT=//p' "$pd/.env" | head -n 1)
          echo "image: docker.gitea.com/gitea:${ver}-rootless"
          printf 'ports:\n  - mode: ingress\n    host_ip: 127.0.0.1\n    target: 3000\n    published: "%s"\n  - mode: ingress\n    host_ip: 127.0.0.1\n    target: 2222\n    published: "%s"\n' "${w:-3090}" "${l:-2222}"
          [[ -z ${FAKE_PUBLIC_PORTS:-} ]] || echo "    host_ip: 0.0.0.0"
        fi
        exit 0 ;;
      ps) [[ -e $S/created ]] && echo "fakecid$(cat "$S/cid" 2>/dev/null || echo 1)"; exit 0 ;;
      stop) rm -f "$S/running"; exit 0 ;;
      start) touch "$S/running" "$S/created"; exit 0 ;;
      up)
        touch "$S/running" "$S/created"
        echo "$pd" >"$S/install_dir"
        case "$*" in *--force-recreate*) echo $(( $(cat "$S/cid" 2>/dev/null || echo 1) + 1 )) >"$S/cid" ;; esac
        if [[ ! -e $S/keep_version ]]; then
          ver=$(sed -n 's/^GITEA_VERSION=//p' "$pd/.env" 2>/dev/null | head -n 1)
          echo "$ver" >"$S/running_version"
          echo "docker.gitea.com/gitea:${ver}-rootless" >"$S/image"
        fi
        mkdir -p "$pd/data/git" "$pd/data/data" "$pd/config"
        [[ -e $pd/config/app.ini ]] || printf '[security]\nINSTALL_LOCK = false\n' >"$pd/config/app.ini"
        exit 0 ;;
      exec)
        args="$*"
        case $args in
          *"gitea --version"*) echo "Gitea version $(cat "$S/running_version" 2>/dev/null || echo 0.0.0) built with simulacion" ;;
          *"admin user list"*) [[ -z ${FAKE_NO_USERS:-} ]] || exit 1; printf 'ID Username Email IsActive IsAdmin\n1 admin a@b true true\n' ;;
        esac
        exit 0 ;;
      logs|pull) exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
S=$FAKE_STATE
case "$*" in
  *https://*) if grep -q HTTPS "$S/serve.json" 2>/dev/null; then printf '200'; else printf '000'; fi; exit 0 ;;
esac
d=$(cat "$S/install_dir" 2>/dev/null || true)
if [[ -e $S/running && ! -e $S/unhealthy && ( -z $d || ! -e $d/data/POISON ) ]]; then printf '200'; else printf '000'; fi
STUB
cat >"$BIN/tailscale" <<'STUB'
#!/usr/bin/env bash
S=$FAKE_STATE
echo "tailscale $*" >>"$S/ts-calls.log"
SJ=$S/serve.json
[[ -f $SJ ]] || echo '{}' >"$SJ"
case "${1:-}" in
  status)
    cat <<JSON
{
  "Version": "1.0-simulado",
  "BackendState": "$(cat "$S/ts_state" 2>/dev/null || echo Running)",
  "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1"],
  "CertDomains": ["srv.tail1234.ts.net"],
  "Self": { "ID": "x", "DNSName": "srv.tail1234.ts.net.", "Online": true, "TailscaleIPs": ["100.101.102.103"] },
  "Peer": { "nodekey:abc": { "DNSName": "otro.tail1234.ts.net." } }
}
JSON
    ;;
  ip) echo "100.101.102.103" ;;
  version) echo "${FAKE_TS_VERSION:-1.76.1}"; echo "  tailscale commit: simulado" ;;
  serve)
    shift
    case "${1:-}" in
      --help) echo "FLAGS"; echo "  --bg"; echo "  --https"; [[ -n ${FAKE_TS_OLD:-} ]] || echo "  --tcp"; exit 0 ;;
      status)
        if [[ ${2:-} == --json ]]; then
          if [[ -f $S/serve-raw.json ]]; then cat "$S/serve-raw.json"; else cat "$SJ"; fi
        else echo "(estado simulado de serve)"; fi
        exit 0 ;;
      reset) echo "RESET" >>"$S/ts-mutations.log"; exit 0 ;;
      --bg)
        spec=$2; target=$3
        case $spec in
          --https=*) [[ -z ${FAKE_TS_FAIL_HTTPS:-} ]] || exit 1; kind=https ;;
          --tcp=*) [[ -z ${FAKE_TS_FAIL_SSH:-} ]] || exit 1; kind=tcp ;;
          *) exit 1 ;;
        esac
        echo "$*" >>"$S/ts-mutations.log"
        python3 - "$SJ" "$kind" "${spec#*=}" "$target" <<'PY'
import json, sys
path, kind, port, target = sys.argv[1:5]
cfg = json.load(open(path))
cfg.setdefault("TCP", {})
if kind == "https":
    cfg["TCP"][port] = {"HTTPS": True}
    cfg.setdefault("Web", {})["srv.tail1234.ts.net:%s" % port] = {"Handlers": {"/": {"Proxy": target}}}
else:
    cfg["TCP"][port] = {"TCPForward": target.replace("tcp://", "")}
json.dump(cfg, open(path, "w"))
PY
        exit 0 ;;
      *) echo "$*" >>"$S/ts-mutations.log"; exit 0 ;;
    esac ;;
  funnel) echo "FUNNEL $*" >>"$S/ts-mutations.log" ;;
esac
STUB
cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
[[ ${1:-} != "-n" ]] || shift
exec "$@"
STUB
cat >"$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$BIN/ss" <<'STUB'
#!/usr/bin/env bash
[[ -f $FAKE_STATE/ss_out ]] && cat "$FAKE_STATE/ss_out"
exit 0
STUB
cat >"$BIN/timeout" <<'STUB'
#!/usr/bin/env bash
if [[ -e $FAKE_STATE/running && ! -e $FAKE_STATE/ssh_down ]]; then printf 'SSH-2.0-Gitea-simulado'; fi
exit 0
STUB
# Sin privilegios no se puede cambiar el propietario a UID 1000: la simulacion lo omite.
cat >"$BIN/chown" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$BIN/install" <<STUB
#!/usr/bin/env bash
args=()
while [[ \$# -gt 0 ]]; do
  case \$1 in
    -o|-g) shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
exec "$REAL_INSTALL" "\${args[@]}"
STUB
cat >"$BIN/tar" <<STUB
#!/usr/bin/env bash
if [[ -n \${FAKE_TAR_FAIL:-} && "\$*" == *-czpf* ]]; then echo "tar simulado: fallo forzado al crear" >&2; exit 2; fi
if [[ -n \${FAKE_TAR_FAIL_X:-} && "\$*" == *-xzpf* ]]; then echo "tar simulado: fallo forzado al extraer" >&2; exit 2; fi
exec "$REAL_TAR" "\$@"
STUB
# mv simulado: puede fallar solo al DEVOLVER los datos anteriores (origen *.pre-restore-*), para probar la recuperacion manual.
cat >"$BIN/mv" <<STUB
#!/usr/bin/env bash
if [[ -n \${FAKE_MV_FAIL_PRE:-} ]]; then
  for a in "\$@"; do
    [[ \$a == -* ]] && continue
    [[ \$a == *pre-restore-* ]] && { echo "mv simulado: fallo forzado" >&2; exit 1; }
    break
  done
fi
exec "$REAL_MV" "\$@"
STUB
chmod +x "$BIN"/*
# PATH alternativo sin Tailscale (simula que no esta instalado).
for f in "$BIN"/*; do [[ $(basename "$f") == tailscale ]] || ln -s "$f" "$BIN_NOTS/$(basename "$f")"; done
ORIG_PATH="$PATH"
export PATH="$BIN:$PATH"
export FAKE_STATE="$STATE"
unset GITEA_INSTALL_DIR GITEA_BACKUP_DIR COMPOSE_PROJECT_NAME GITEA_CONTAINER_NAME GITEA_VERSION GITEA_TAILSCALE_IP TZ || true

reset_state() { rm -rf -- "${STATE:?}"/* ; : >"$STATE/calls.log"; : >"$STATE/ts-calls.log"; : >"$STATE/ts-mutations.log"; } # seguro: estado simulado propio
reset_state

# ---------------------------------------------------------------- proyecto simulado
cp -r "$ROOT/compose.yaml" "$ROOT/.env.example" "$ROOT/scripts" "$INSTALL/"
# Copia limpia (sin .env) para probar primera instalacion y configuracion desde cero.
mkdir -p "$TMP/clean" && cp -r "$ROOT/compose.yaml" "$ROOT/.env.example" "$ROOT/scripts" "$TMP/clean/"
export GITEA_INSTALL_DIR="$INSTALL"
export TZ=UTC

section "configure.sh"
if "$INSTALL/scripts/configure.sh" --yes --backup-dir "$BACKUPS" >"$TMP/configure.log" 2>&1; then
  pass "configure.sh genera .env con Tailscale simulado"
else
  nope "configure.sh fallo"; cat "$TMP/configure.log"
fi
check ".env con permisos 600" test "$(stat -c %a "$INSTALL/.env")" = "600"
check ".env: DNS del nodo propio (no el de un par)" has '^GITEA_TS_DNS=srv.tail1234.ts.net$' "$INSTALL/.env"
check ".env: URL publica HTTPS correcta" has '^GITEA_ROOT_URL=https://srv.tail1234.ts.net/$' "$INSTALL/.env"
check ".env: cuatro puertos (web 3090, ssh local 2222, ssh tailnet 2222, https 443)" bash -c "grep -q '^GITEA_WEB_PORT=3090\$' '$INSTALL/.env' && grep -q '^GITEA_SSH_LOCAL_PORT=2222\$' '$INSTALL/.env' && grep -q '^GITEA_SSH_PORT=2222\$' '$INSTALL/.env' && grep -q '^GITEA_TS_HTTPS_PORT=443\$' '$INSTALL/.env'"
check ".env nuevo no incluye la clave obsoleta GITEA_TAILSCALE_IP" hasnt 'GITEA_TAILSCALE_IP' "$INSTALL/.env"
before=$(sha256sum "$INSTALL/.env")
"$INSTALL/scripts/configure.sh" >"$TMP/configure2.log" 2>&1 || true
after=$(sha256sum "$INSTALL/.env")
[[ $before == "$after" ]] && has 'Sin cambios' "$TMP/configure2.log" && pass "configure.sh es repetible: segunda ejecucion sin cambios" || nope "configure.sh no es idempotente"
"$INSTALL/scripts/configure.sh" --regenerate --yes >"$TMP/configure3.log" 2>&1 || true
ls "$INSTALL"/.env.bak-* >/dev/null 2>&1 && pass "--regenerate conserva copia .env.bak-*" || nope "--regenerate no guardo copia"
check "--regenerate conserva valores personalizados" has "^GITEA_BACKUP_DIR=$BACKUPS$" "$INSTALL/.env"

section "configure.sh: entradas invalidas, sin Tailscale y migracion"
mkdir -p "$TMP/cfg1" && cp "$ROOT/compose.yaml" "$ROOT/.env.example" "$TMP/cfg1/"
for bad in "--web-port 70000" "--web-port abc" "--ssh-local-port 0" "--ssh-port 99999" "--https-port 8080" "--web-port 2222" "--ssh-port 443"; do
  # shellcheck disable=SC2086
  if GITEA_INSTALL_DIR="$TMP/cfg1" "$TMP/clean/scripts/configure.sh" --target "$TMP/cfg1" --yes $bad >"$TMP/cfg-bad.log" 2>&1; then
    nope "configure.sh acepto $bad"
  else
    [[ ! -e $TMP/cfg1/.env ]] && pass "configure.sh rechaza $bad y no escribe .env" || nope "configure.sh escribio .env con $bad"
  fi
done
if GITEA_INSTALL_DIR="$TMP/cfg1" PATH="$BIN_NOTS:$ORIG_PATH" "$TMP/clean/scripts/configure.sh" --target "$TMP/cfg1" --yes >"$TMP/cfg-nots.log" 2>&1; then
  nope "configure.sh se ejecuto sin Tailscale ni --ts-dns"; cat "$TMP/cfg-nots.log"
else
  [[ ! -e $TMP/cfg1/.env ]] && has 'Tailscale' "$TMP/cfg-nots.log" && pass "Sin configuracion de Tailscale: configure.sh se detiene, explica y no escribe .env" || nope "Sin Tailscale: comportamiento inesperado"
fi
if GITEA_INSTALL_DIR="$TMP/cfg1" PATH="$BIN_NOTS:$ORIG_PATH" "$TMP/clean/scripts/configure.sh" --target "$TMP/cfg1" --yes --ts-dns prueba.tail1234.ts.net --web-port 3191 --ssh-local-port 2299 --ssh-port 2200 --https-port 8443 >"$TMP/cfg-manual.log" 2>&1 \
  && has '^GITEA_WEB_PORT=3191$' "$TMP/cfg1/.env" && has '^GITEA_SSH_LOCAL_PORT=2299$' "$TMP/cfg1/.env" && has '^GITEA_SSH_PORT=2200$' "$TMP/cfg1/.env" && has '^GITEA_ROOT_URL=https://prueba.tail1234.ts.net:8443/$' "$TMP/cfg1/.env"; then
  pass "Con --ts-dns y puertos personalizados no hace falta Tailscale; los cuatro puertos son independientes"
else
  nope "configure.sh con --ts-dns/puertos personalizados"; tail -n 20 "$TMP/cfg-manual.log"
fi
# .env incompleto: faltan variables obligatorias.
mkdir -p "$TMP/cfg2" && cp "$ROOT/compose.yaml" "$TMP/cfg2/"
printf 'GITEA_VERSION=28.3.0\nGITEA_TS_DNS=srv.tail1234.ts.net\n' >"$TMP/cfg2/.env"
if "$INSTALL/scripts/configure.sh" --target "$TMP/cfg2" >"$TMP/cfg-missing.log" 2>&1; then nope "configure.sh acepto un .env sin GITEA_ROOT_URL/GITEA_SSH_DOMAIN"; else pass "Variables faltantes (GITEA_ROOT_URL, GITEA_SSH_DOMAIN) se detectan y se rechazan"; fi
# Migracion desde el .env anterior (SSH publicado en la IP de Tailscale).
mkdir -p "$TMP/cfg3" && cp "$ROOT/compose.yaml" "$ROOT/.env.example" "$TMP/cfg3/"
cat >"$TMP/cfg3/.env" <<'ENVV'
GITEA_VERSION=28.3.0
GITEA_TAILSCALE_IP=100.101.102.103
GITEA_TS_DNS=srv.tail1234.ts.net
GITEA_TS_HTTPS_PORT=443
GITEA_ROOT_URL=https://srv.tail1234.ts.net/
GITEA_SSH_DOMAIN=srv.tail1234.ts.net
GITEA_WEB_PORT=3090
GITEA_SSH_PORT=2200
TZ=UTC
ENVV
chmod 600 "$TMP/cfg3/.env"
"$INSTALL/scripts/configure.sh" --target "$TMP/cfg3" >"$TMP/cfg-legacy.log" 2>&1 || true
check "Un .env anterior se acepta, se ignora GITEA_TAILSCALE_IP y se explica la migracion" bash -c "grep -q 'obsoleta' '$TMP/cfg-legacy.log' && grep -q 'Migracion' '$TMP/cfg-legacy.log'"
"$INSTALL/scripts/configure.sh" --target "$TMP/cfg3" --regenerate --yes >"$TMP/cfg-legacy2.log" 2>&1 || true
if hasnt 'GITEA_TAILSCALE_IP' "$TMP/cfg3/.env" && has '^GITEA_SSH_PORT=2200$' "$TMP/cfg3/.env" && has '^GITEA_SSH_LOCAL_PORT=2200$' "$TMP/cfg3/.env"; then
  pass "Migracion: --regenerate elimina GITEA_TAILSCALE_IP y conserva el puerto SSH (2200) como local y de tailnet"
else
  nope "Migracion del .env anterior incorrecta"; cat "$TMP/cfg3/.env"
fi
ls "$TMP"/cfg3/.env.bak-* >/dev/null 2>&1 && pass "La migracion guarda copia del .env anterior" || nope "Sin copia del .env anterior"

# ---------------------------------------------------------------- datos simulados
seed_data() {
  rm -rf -- "$INSTALL/data" "$INSTALL/config" # seguro: datos simulados dentro del directorio temporal
  mkdir -p "$INSTALL/data/data/ssh" "$INSTALL/data/git/repositories/usuario/repo.git" "$INSTALL/config"
  python3 - "$INSTALL/data/data/gitea.db" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE version (id INTEGER PRIMARY KEY, version INTEGER)")
con.execute("INSERT INTO version VALUES (1, 305)")
con.execute("CREATE TABLE repository (id INTEGER PRIMARY KEY, name TEXT)")
con.execute("INSERT INTO repository VALUES (1, 'repo')")
con.execute("CREATE TABLE meta (v TEXT)")
con.execute("INSERT INTO meta VALUES ('v1')")
con.commit()
con.close()
PY
  echo "ref: refs/heads/main" >"$INSTALL/data/git/repositories/usuario/repo.git/HEAD"
  echo "ssh-ed25519 AAAA-simulado" >"$INSTALL/data/data/ssh/gitea.ed25519.pub"
  printf '[security]\nINSTALL_LOCK = true\n' >"$INSTALL/config/app.ini"
}
db_meta() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('SELECT v FROM meta').fetchone()[0])" "$1" 2>/dev/null || true; }
set_running() { touch "$STATE/running" "$STATE/created"; echo "$INSTALL" >"$STATE/install_dir"; echo "28.3.0" >"$STATE/running_version"; echo "docker.gitea.com/gitea:28.3.0-rootless" >"$STATE/image"; echo "docker.gitea.com/gitea:28.3.0-rootless" >"$STATE/images"; }
seed_data
set_running
: >"$STATE/calls.log"

section "preflight.sh: solo lectura"
snapshot() { find "$TMP/srv" -printf '%p %y %s %T@\n' 2>/dev/null | sort; }
snap_before=$(snapshot)
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight.log" 2>&1; then
  pass "preflight.sh termina sin errores con una instalacion saludable simulada"
else
  nope "preflight.sh fallo"; tail -n 30 "$TMP/preflight.log"
fi
check "preflight reconoce 'INSTALACION EXISTENTE SALUDABLE' (la propia no se confunde con un servicio ajeno)" has 'INSTALACION EXISTENTE SALUDABLE' "$TMP/preflight.log"
check "preflight no modifica el disco" test "$snap_before" = "$(snapshot)"
check "preflight no ejecuta comandos Docker que modifiquen nada" bash -c "! grep -E 'docker (pull|run|rm|stop|start|restart|kill|network (create|rm|connect)|compose .*(up|stop|start|down|rm|pull|restart))' '$STATE/calls.log'"
check "preflight no modifica Tailscale (ni Serve ni Funnel)" test ! -s "$STATE/ts-mutations.log"
# Puerto local ocupado por un servicio ajeno (sin contenedor propio).
reset_state; seed_data; echo "$INSTALL" >"$STATE/install_dir"
echo "LISTEN 0 4096 127.0.0.1:3090 0.0.0.0:*" >"$STATE/ss_out"
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-port.log" 2>&1; then nope "preflight no detecto un puerto local ocupado por un servicio ajeno"; else has 'ocupado' "$TMP/preflight-port.log" && pass "preflight detecta colision del puerto HTTP local con un servicio ajeno" || nope "mensaje de colision inesperado"; fi
echo "LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:*" >"$STATE/ss_out"
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-port2.log" 2>&1; then nope "preflight no detecto el SSH local ocupado"; else pass "preflight detecta colision del puerto SSH local (0.0.0.0:2222)"; fi
rm -f "$STATE/ss_out"
# Colision en Tailscale Serve: HTTPS 443 ajeno.
echo '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}' >"$STATE/serve.json"
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-serve.log" 2>&1; then nope "preflight no detecto un HTTPS ajeno en Serve"; else has 'ajeno' "$TMP/preflight-serve.log" && pass "preflight detecta colision del HTTPS 443 con un servicio ajeno de Serve" || nope "mensaje Serve inesperado"; fi
echo '{"TCP":{"2222":{"TCPForward":"127.0.0.1:2200"}}}' >"$STATE/serve.json"
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-serve2.log" 2>&1; then nope "preflight no detecto el puerto SSH ajeno en Serve"; else pass "preflight detecta colision del puerto SSH 2222 en Serve"; fi
echo '{"Nuevo":1}' >"$STATE/serve.json"
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-serve3.log" 2>&1; then nope "preflight acepto un JSON de Serve desconocido"; else has 'No se reconoce' "$TMP/preflight-serve3.log" && pass "preflight falla de forma segura con un JSON de Serve no reconocido" || nope "mensaje de JSON desconocido inesperado"; fi
rm -f "$STATE/serve.json"
# Servicios propios de Serve ya publicados: no son conflicto.
reset_state; seed_data; set_running
"$INSTALL/scripts/configure-tailscale.sh" --yes >/dev/null 2>&1 || true
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-own.log" 2>&1 && has 'ya publica Gitea' "$TMP/preflight-own.log"; then pass "preflight reconoce como propios los servicios de Serve de esta instalacion"; else nope "preflight trato los servicios propios de Serve como conflicto"; tail -n 20 "$TMP/preflight-own.log"; fi
# Primera instalacion, configuracion parcial y problemas.
reset_state
FRESH="$TMP/fresh/gitea-privado"
if GITEA_INSTALL_DIR="$FRESH" GITEA_BACKUP_DIR="$TMP/fresh/backups" "$TMP/clean/scripts/preflight.sh" >"$TMP/preflight-first.log" 2>&1 && has 'PRIMERA INSTALACION' "$TMP/preflight-first.log"; then pass "preflight reconoce una PRIMERA INSTALACION"; else nope "preflight primera instalacion"; tail -n 20 "$TMP/preflight-first.log"; fi
check "preflight no crea directorios (sigue sin existir $FRESH)" test ! -e "$FRESH"
PARTIAL="$TMP/partial/gitea-privado"; mkdir -p "$PARTIAL/data"
GITEA_INSTALL_DIR="$PARTIAL" GITEA_BACKUP_DIR="$TMP/partial/backups" "$TMP/clean/scripts/preflight.sh" >"$TMP/preflight-partial.log" 2>&1 || true
check "preflight reconoce una CONFIGURACION PARCIAL" has 'CONFIGURACION PARCIAL' "$TMP/preflight-partial.log"
seed_data; set_running; touch "$STATE/unhealthy"
"$INSTALL/scripts/preflight.sh" >"$TMP/preflight-bad.log" 2>&1 || true
check "preflight reconoce una INSTALACION EXISTENTE CON PROBLEMAS" has 'CON PROBLEMAS' "$TMP/preflight-bad.log"
rm -f "$STATE/unhealthy"
# Entorno invalido y sin Tailscale.
BADENV="$TMP/badenv/gitea-privado"; mkdir -p "$BADENV"
printf 'GITEA_VERSION=latest\nGITEA_WEB_PORT=abc\n' >"$BADENV/.env"
if GITEA_INSTALL_DIR="$BADENV" "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-env.log" 2>&1; then nope "preflight acepto variables invalidas"; else pass "preflight rechaza variables de entorno invalidas"; fi
if PATH="$BIN_NOTS:$ORIG_PATH" "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-nots.log" 2>&1; then nope "preflight no fallo sin Tailscale"; else has 'Tailscale no esta instalado' "$TMP/preflight-nots.log" && pass "preflight falla y explica si Tailscale no esta instalado" || nope "mensaje sin Tailscale inesperado"; fi
echo Stopped >"$STATE/ts_state"
if "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-stop.log" 2>&1; then nope "preflight no fallo con Tailscale desconectado"; else pass "preflight falla si Tailscale no esta conectado"; fi
rm -f "$STATE/ts_state"
FAKE_TS_OLD=1 "$INSTALL/scripts/preflight.sh" >"$TMP/preflight-old.log" 2>&1 && nope "preflight acepto un Tailscale sin 'serve --tcp'" || pass "preflight rechaza un cliente Tailscale sin 'serve --tcp'"

# ---------------------------------------------------------------- Tailscale Serve
section "configure-tailscale.sh"
reset_state; seed_data; set_running
"$INSTALL/scripts/configure-tailscale.sh" --dry-run >"$TMP/ts-dry.log" 2>&1 || true
check "--dry-run no cambia Serve" test ! -s "$STATE/ts-mutations.log"
check "--dry-run muestra los dos comandos (HTTPS y TCP)" bash -c "grep -q -- '--https=443 http://127.0.0.1:3090' '$TMP/ts-dry.log' && grep -q -- '--tcp=2222 tcp://127.0.0.1:2222' '$TMP/ts-dry.log'"
if "$INSTALL/scripts/configure-tailscale.sh" >"$TMP/ts1.log" 2>&1; then pass "configure-tailscale.sh publica HTTPS y SSH"; else nope "configure-tailscale.sh fallo"; tail -n 30 "$TMP/ts1.log"; fi
check "Se ejecutaron exactamente: serve --https=443 y serve --tcp=2222 hacia 127.0.0.1" bash -c "[[ \$(wc -l <'$STATE/ts-mutations.log') -eq 2 ]] && grep -q -- '--bg --https=443 http://127.0.0.1:3090' '$STATE/ts-mutations.log' && grep -q -- '--bg --tcp=2222 tcp://127.0.0.1:2222' '$STATE/ts-mutations.log'"
check "Nunca se uso reset, off ni Funnel" bash -c "! grep -Eq 'RESET|FUNNEL| off' '$STATE/ts-mutations.log' && ! grep -Eq 'tailscale (funnel|up|down|set|logout)' '$STATE/ts-calls.log'"
check "Serve termino con HTTPS y TCP propios (analisis JSON)" bash -c "python3 scripts/tsjson.py serve --dns srv.tail1234.ts.net --https-port 443 --web-port 3090 --ssh-port 2222 --ssh-local-port 2222 <'$STATE/serve.json' | grep -q '^https=ours' " 
lines_before=$(wc -l <"$STATE/ts-mutations.log")
"$INSTALL/scripts/configure-tailscale.sh" >"$TMP/ts2.log" 2>&1 || true
check "Repetir el script no duplica servicios (sin comandos nuevos)" test "$lines_before" = "$(wc -l <"$STATE/ts-mutations.log")"
check "Repetir informa 'Sin cambios'" has 'Sin cambios' "$TMP/ts2.log"

# Servicio ajeno en el HTTPS.
reset_state; seed_data; set_running
echo '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}' >"$STATE/serve.json"
if "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-foreign.log" 2>&1; then nope "configure-tailscale.sh pisaba un HTTPS ajeno"; else pass "Un HTTPS ajeno en 443 no se reemplaza (el script se detiene)"; fi
check "Con conflicto no se ejecuta ningun cambio (ni siquiera el SSH)" test ! -s "$STATE/ts-mutations.log"
check "Ofrece alternativas (otro puerto) sin tocar nada" has '--https-port 8443' "$TMP/ts-foreign.log"
echo '{"TCP":{"2222":{"TCPForward":"127.0.0.1:2200"}}}' >"$STATE/serve.json"
if "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-foreign2.log" 2>&1; then nope "configure-tailscale.sh pisaba un puerto SSH ajeno"; else pass "Un reenvio TCP ajeno en 2222 no se reemplaza"; fi
check "Sin cambios con el SSH ajeno" test ! -s "$STATE/ts-mutations.log"
# Servicios ajenos en otros puertos: se conservan.
echo '{"TCP":{"8443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"}}}}}' >"$STATE/serve.json"
"$INSTALL/scripts/configure-tailscale.sh" >"$TMP/ts-confirm.log" 2>&1 && nope "Sin --yes y sin terminal se agrego Serve junto a servicios ajenos" || pass "Con servicios ajenos existentes se exige confirmacion (sin terminal: cancela)"
check "Cancelado: no se modifico Serve" test ! -s "$STATE/ts-mutations.log"
if "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-coexist.log" 2>&1 && grep -q '"8443"' "$STATE/serve.json" && grep -q '"2222"' "$STATE/serve.json"; then pass "Con --yes agrega Gitea y conserva el servicio ajeno existente"; else nope "Coexistencia con servicios ajenos"; tail -n 20 "$TMP/ts-coexist.log"; fi
# Funnel activo.
reset_state; seed_data; set_running
echo '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3090"}}}},"AllowFunnel":{"srv.tail1234.ts.net:443":true}}' >"$STATE/serve.json"
if "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-funnel.log" 2>&1; then nope "configure-tailscale.sh acepto Funnel activo sobre Gitea"; else pass "Funnel activo sobre Gitea: el script se detiene (Gitea debe ser privado)"; fi
# JSON no reconocido.
reset_state; seed_data; set_running
echo '{"FormatoNuevo":{"x":1}}' >"$STATE/serve-raw.json"
if "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-json.log" 2>&1; then nope "configure-tailscale.sh actuo con un JSON desconocido"; else has 'FormatoNuevo' "$TMP/ts-json.log" && pass "JSON desconocido: falla de forma segura y muestra los datos para revision" || nope "no muestra el JSON recibido"; fi
check "JSON desconocido: no se modifico nada" test ! -s "$STATE/ts-mutations.log"
# Cliente antiguo.
reset_state; seed_data; set_running
if FAKE_TS_OLD=1 "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-old.log" 2>&1; then nope "configure-tailscale.sh actuo con un cliente sin --tcp"; else has 'alternativa' "$TMP/ts-old.log" || has 'Alternativa' "$TMP/ts-old.log"; fi
check "Cliente sin --tcp: se detiene, ofrece alternativa privada (tunel SSH) y nunca usa 0.0.0.0" bash -c "grep -q 'ssh -L' '$TMP/ts-old.log' && test ! -s '$STATE/ts-mutations.log'"
FAKE_TS_VERSION=1.40.0 "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-old2.log" 2>&1 && nope "acepto Tailscale 1.40" || pass "Una version de Tailscale anterior a 1.52 se rechaza"
# Tailscale desconectado / ausente.
echo Stopped >"$STATE/ts_state"
"$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-stop.log" 2>&1 && nope "actuo con Tailscale desconectado" || pass "Tailscale desconectado: el script se detiene"
rm -f "$STATE/ts_state"
PATH="$BIN_NOTS:$ORIG_PATH" "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-none.log" 2>&1 && nope "actuo sin Tailscale" || pass "Sin Tailscale instalado: el script se detiene"
# Asistente sin completar.
printf '[security]\nINSTALL_LOCK = false\n' >"$INSTALL/config/app.ini"
if "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-unlocked.log" 2>&1; then nope "publico Gitea con el asistente sin completar"; else has 'asistente' "$TMP/ts-unlocked.log" && pass "Asistente pendiente: no se publica en la tailnet (tunel SSH primero)" || nope "mensaje de asistente pendiente inesperado"; fi
check "Asistente pendiente: Serve intacto" test ! -s "$STATE/ts-mutations.log"
"$INSTALL/scripts/configure-tailscale.sh" --dry-run --allow-unfinished-installer >"$TMP/ts-unlocked2.log" 2>&1 && pass "--allow-unfinished-installer permite continuar (aqui solo --dry-run)" || nope "--allow-unfinished-installer"
printf '[security]\nINSTALL_LOCK = true\n' >"$INSTALL/config/app.ini"
# Estado parcial: HTTPS ok y SSH falla.
reset_state; seed_data; set_running
if FAKE_TS_FAIL_SSH=1 "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-partial.log" 2>&1; then nope "no informo el fallo del SSH"; else
  rc=$?
  [[ $rc -eq 2 ]] && has 'ESTADO PARCIAL' "$TMP/ts-partial.log" && pass "Fallo del segundo servicio: informa ESTADO PARCIAL (codigo 2)" || nope "estado parcial no informado (codigo $rc)"
fi
check "Estado parcial: el HTTPS ya configurado NO se elimina" bash -c "grep -q -- '--https=443' '$STATE/ts-mutations.log' && ! grep -q 'off' '$STATE/ts-mutations.log' && grep -q HTTPS '$STATE/serve.json'"
check "Estado parcial: explica como completar o revertir solo lo de Gitea" bash -c "grep -q 'serve --https=443 off' '$TMP/ts-partial.log' && grep -q 'serve --tcp=2222 off' '$TMP/ts-partial.log'"
FAKE_TS_FAIL_SSH='' "$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-complete.log" 2>&1 && grep -q '"2222"' "$STATE/serve.json" && pass "Repetir el script completa solo lo que faltaba (el SSH)" || nope "no se pudo completar el estado parcial"

# ---------------------------------------------------------------- backup
section "backup.sh"
reset_state; seed_data; set_running
if "$INSTALL/scripts/backup.sh" --label prueba >"$TMP/backup.log" 2>&1; then
  pass "backup.sh termina correctamente"
else
  nope "backup.sh fallo"; cat "$TMP/backup.log"
fi
ARCHIVE=$(ls -1 "$BACKUPS"/gitea-privado-*-prueba.tar.gz 2>/dev/null | head -n 1 || true)
[[ -n $ARCHIVE && -f $ARCHIVE.sha256 ]] && pass "Se crearon el .tar.gz y el .sha256" || nope "Faltan archivos de respaldo"
check "Respaldo con permisos 600" test "$(stat -c %a "$ARCHIVE")" = "600"
check "SHA-256 verificable" bash -c "cd '$BACKUPS' && sha256sum -c --quiet '$(basename "$ARCHIVE").sha256'"
listing=$(tar -tzf "$ARCHIVE")
grep -q '^MANIFEST.txt$' <<<"$listing" && grep -q '^config/app.ini$' <<<"$listing" && grep -q '^data/data/gitea.db$' <<<"$listing" && grep -q '^data/git/repositories/usuario/repo.git/HEAD$' <<<"$listing" \
  && pass "El respaldo incluye base de datos, repositorios, configuracion y manifiesto" || nope "Contenido del respaldo incompleto"
grep -q '^data/data/ssh/gitea.ed25519.pub$' <<<"$listing" && pass "El respaldo incluye las claves SSH del servidor (data/data/ssh)" || nope "Faltan las claves SSH del servidor"
manifest=$(tar -xzOf "$ARCHIVE" MANIFEST.txt)
grep -q '^GITEA_VERSION=28.3.0$' <<<"$manifest" && grep -q '^DB_SCHEMA_VERSION=305$' <<<"$manifest" && pass "El manifiesto registra la version de Gitea y la del esquema de la base de datos" || nope "Manifiesto incompleto: $manifest"
check "Gitea vuelve a estar en ejecucion tras el respaldo" test -e "$STATE/running"
check "Solo se detuvo el servicio gitea" has 'compose .* stop -t 60 gitea' "$STATE/calls.log"
check "Ningun comando docker fuera de 'docker compose' del proyecto" bash -c "! grep -E 'docker (stop|kill|rm|system|volume)' '$STATE/calls.log'"
check "Toda llamada compose usa --project-name gitea-privado" bash -c "! grep 'docker compose' '$STATE/calls.log' | grep -v -e '--project-name gitea-privado' -e 'compose version'"
section "backup.sh: nombres unicos, sin borrar respaldos, fallos"
for _ in 1 2 3; do "$INSTALL/scripts/backup.sh" --label rapido >/dev/null 2>&1 || true; done
check "Tres respaldos seguidos con la misma etiqueta generan nombres distintos" test "$(ls -1 "$BACKUPS"/*-rapido.tar.gz | wc -l)" -eq 3
check "Los respaldos anteriores se conservan (nunca se borran)" test -f "$ARCHIVE"
before_count=$(ls -1 "$BACKUPS"/*.tar.gz | wc -l)
if FAKE_TAR_FAIL=1 "$INSTALL/scripts/backup.sh" --label fallo >"$TMP/backup-fail.log" 2>&1; then
  nope "backup.sh no devolvio error cuando tar fallo"
else
  pass "backup.sh devuelve error si tar falla"
fi
check "Gitea se reinicia aunque el respaldo falle" test -e "$STATE/running"
after_count=$(ls -1 "$BACKUPS"/*.tar.gz | wc -l)
[[ $before_count == "$after_count" ]] && ! ls "$BACKUPS"/*.partial >/dev/null 2>&1 && pass "No quedan archivos parciales tras el fallo" || nope "Quedaron archivos parciales"
check "El fallo se explica con un mensaje comprensible (etapa y estado de Gitea)" has 'NO se completo' "$TMP/backup-fail.log"
# Base de datos danada: no se genera un respaldo que parezca bueno.
cp "$INSTALL/data/data/gitea.db" "$TMP/gitea.db.bueno"
printf 'esto no es una base sqlite valida' >"$INSTALL/data/data/gitea.db"
if "$INSTALL/scripts/backup.sh" --label danada >"$TMP/backup-db.log" 2>&1; then nope "backup.sh respaldo una base de datos danada sin avisar"; else pass "Una base de datos danada hace fallar el respaldo (no se crea un archivo enganoso)"; fi
check "Base danada: no queda archivo ni parcial y Gitea sigue en ejecucion" bash -c "! ls '$BACKUPS'/*danada* >/dev/null 2>&1 && test -e '$STATE/running'"
cp "$TMP/gitea.db.bueno" "$INSTALL/data/data/gitea.db"
section "backup.sh: ejecuciones simultaneas y destino invalido"
exec 8>"$BACKUPS/.backup.lock"
flock -n 8
if "$INSTALL/scripts/backup.sh" --label lock >"$TMP/backup-lock.log" 2>&1; then
  nope "backup.sh se ejecuto con el bloqueo tomado"
else
  has 'otro respaldo' "$TMP/backup-lock.log" && pass "El bloqueo impide respaldos simultaneos" || nope "Mensaje de bloqueo inesperado"
fi
exec 8>&-
if "$INSTALL/scripts/backup.sh" --dir "$INSTALL/data/backups" >"$TMP/backup-in.log" 2>&1; then
  nope "backup.sh acepto un destino dentro de la instalacion"
else
  pass "backup.sh rechaza un destino dentro del directorio respaldado"
fi

# ---------------------------------------------------------------- restore
section "restore.sh"
run_restore() { # archivo respuesta [opciones...]
  local file=$1 answer=$2
  shift 2
  if command -v script >/dev/null 2>&1; then
    printf '%s\n' "$answer" | script -qec "$INSTALL/scripts/restore.sh $* $file" /dev/null
  else
    return 99
  fi
}
make_archive() { # nombre [POISON|CORRUPTDB] -> crea un respaldo valido (con SHA-256) con contenido alterado a proposito
  local name=$1 kind=${2:-} work="$TMP/arch-$1"
  mkdir -p "$work/data/data" "$work/data/git/repositories/usuario/repo.git" "$work/config"
  printf 'BACKUP_FORMAT=1\nGITEA_VERSION=28.3.0\nCREATED_AT=2000-01-01T00:00:00Z\n' >"$work/MANIFEST.txt"
  cp "$TMP/gitea.db.bueno" "$work/data/data/gitea.db"
  echo "ref: refs/heads/main" >"$work/data/git/repositories/usuario/repo.git/HEAD"
  printf '[security]\nINSTALL_LOCK = true\n' >"$work/config/app.ini"
  [[ $kind != POISON ]] || echo x >"$work/data/POISON"
  [[ $kind != CORRUPTDB ]] || printf 'basura' >"$work/data/data/gitea.db"
  "$REAL_TAR" -czf "$BACKUPS/gitea-privado-arch-$name.tar.gz" -C "$work" MANIFEST.txt data config
  ( cd "$BACKUPS" && sha256sum "gitea-privado-arch-$name.tar.gz" >"gitea-privado-arch-$name.tar.gz.sha256" )
}
if ! command -v script >/dev/null 2>&1; then
  skip "Falta el comando 'script' (util-linux): se omiten las pruebas interactivas de restore.sh."
else
  echo "dato nuevo que no estaba en el respaldo" >"$INSTALL/data/marcador-posterior.txt"
  printf 'basura' >"$INSTALL/data/data/gitea.db"
  rm -f "$INSTALL/data/git/repositories/usuario/repo.git/HEAD"

  run_restore "$ARCHIVE" "NO" >"$TMP/restore-no.log" 2>&1 || true
  check "Sin confirmacion escrita no se modifica nada" test -f "$INSTALL/data/marcador-posterior.txt"

  if run_restore "$ARCHIVE" "RESTAURAR" >"$TMP/restore.log" 2>&1; then
    pass "restore.sh termina correctamente con confirmacion"
  else
    nope "restore.sh fallo"; tail -n 30 "$TMP/restore.log"
  fi
  [[ ! -e $INSTALL/data/marcador-posterior.txt && "$(db_meta "$INSTALL/data/data/gitea.db")" == "v1" && -f $INSTALL/data/git/repositories/usuario/repo.git/HEAD ]] \
    && pass "Los datos del respaldo quedaron restaurados (base de datos SQLite integra y repositorio)" || nope "Datos no restaurados correctamente"
  pre=$(ls -d "$INSTALL"/data.pre-restore-* 2>/dev/null | head -n 1 || true)
  [[ -n $pre && -f $pre/marcador-posterior.txt ]] && pass "Los datos anteriores se conservaron (renombrados, no borrados)" || nope "No se conservaron los datos anteriores"
  ls "$BACKUPS"/*-pre-restore.tar.gz >/dev/null 2>&1 && pass "Se creo un respaldo previo automatico (pre-restore)" || nope "Falta el respaldo previo a la restauracion"
  check "Gitea en ejecucion tras restaurar" test -e "$STATE/running"
  check "La restauracion verifica aplicacion, base de datos y repositorios (no solo el contenedor)" bash -c "grep -q 'integrity_check correcto' '$TMP/restore.log' && grep -q 'lista usuarios' '$TMP/restore.log' && grep -q 'Repositorios: 1' '$TMP/restore.log' && grep -q 'RESTAURACION VERIFICADA' '$TMP/restore.log'"
  check "Los datos anteriores no se borran: el script lo declara" has 'NUNCA los borra' "$TMP/restore.log"
  check "Se bloqueo la restauracion (bloqueo compartido con backup.sh) y solo se detuvo gitea" bash -c "! grep -E 'docker (stop|kill|rm|system|volume)' '$STATE/calls.log'"

  # Archivo alterado: el SHA-256 debe detener la restauracion antes de tocar nada.
  cp "$ARCHIVE" "$BACKUPS/gitea-privado-20000101-000000-alterado.tar.gz"
  cp "$ARCHIVE.sha256" "$BACKUPS/gitea-privado-20000101-000000-alterado.tar.gz.sha256"
  sed -i 's/gitea-privado-[0-9-]*-prueba.tar.gz/gitea-privado-20000101-000000-alterado.tar.gz/' "$BACKUPS/gitea-privado-20000101-000000-alterado.tar.gz.sha256"
  printf 'basura' >>"$BACKUPS/gitea-privado-20000101-000000-alterado.tar.gz"
  echo "estado intacto" >"$INSTALL/data/centinela.txt"
  if run_restore "$BACKUPS/gitea-privado-20000101-000000-alterado.tar.gz" "RESTAURAR" >"$TMP/restore-bad.log" 2>&1; then
    nope "restore.sh acepto un respaldo alterado"
  else
    [[ -f $INSTALL/data/centinela.txt ]] && pass "Un respaldo con SHA-256 incorrecto se rechaza sin modificar datos" || nope "Se modificaron datos con un respaldo alterado"
  fi
  # Archivo inexistente y sin .sha256.
  run_restore "$BACKUPS/no-existe.tar.gz" "RESTAURAR" >"$TMP/restore-none.log" 2>&1 && nope "acepto un respaldo inexistente" || pass "Un respaldo inexistente se rechaza"
  cp "$ARCHIVE" "$BACKUPS/gitea-privado-sinsha.tar.gz"
  run_restore "$BACKUPS/gitea-privado-sinsha.tar.gz" "RESTAURAR" >"$TMP/restore-nosha.log" 2>&1 && nope "acepto un respaldo sin .sha256" || pass "Un respaldo sin archivo .sha256 se rechaza"

  # Archivos maliciosos con SHA-256 valido: deben rechazarse por contenido.
  make_evil() { # nombre
    local name=$1 work="$TMP/evil-$1"
    mkdir -p "$work"
    printf 'BACKUP_FORMAT=1\nGITEA_VERSION=28.3.0\nCREATED_AT=2000-01-01T00:00:00Z\n' >"$work/MANIFEST.txt"
    mkdir -p "$work/data" "$work/config"
    echo x >"$work/config/app.ini"
    case $name in
      traversal) "$REAL_TAR" -czf "$BACKUPS/gitea-privado-evil-$name.tar.gz" -C "$work" --transform='s,^config/app.ini$,config/../../escape.txt,' MANIFEST.txt data config ;;
      absoluta) "$REAL_TAR" -czPf "$BACKUPS/gitea-privado-evil-$name.tar.gz" -C "$work" --transform="s,^MANIFEST.txt\$,/tmp/gitea-evil-abs.txt," MANIFEST.txt data config ;;
      extra) mkdir -p "$work/etc"; echo x >"$work/etc/passwd"; "$REAL_TAR" -czf "$BACKUPS/gitea-privado-evil-$name.tar.gz" -C "$work" MANIFEST.txt data config etc ;;
      symlink) ln -s /etc "$work/data/enlace"; "$REAL_TAR" -czf "$BACKUPS/gitea-privado-evil-$name.tar.gz" -C "$work" MANIFEST.txt data config ;;
      symlink-rel) ln -s ../../../etc "$work/data/enlace"; "$REAL_TAR" -czf "$BACKUPS/gitea-privado-evil-$name.tar.gz" -C "$work" MANIFEST.txt data config ;;
      hardlink) echo y >"$work/data/a"; ln "$work/data/a" "$work/data/b"; "$REAL_TAR" -czf "$BACKUPS/gitea-privado-evil-$name.tar.gz" -C "$work" MANIFEST.txt data config --transform='s,^data/b$,data/b,' ;;
      fifo) mkfifo "$work/data/tuberia"; "$REAL_TAR" -czf "$BACKUPS/gitea-privado-evil-$name.tar.gz" -C "$work" MANIFEST.txt data config ;;
    esac
    ( cd "$BACKUPS" && sha256sum "gitea-privado-evil-$name.tar.gz" >"gitea-privado-evil-$name.tar.gz.sha256" )
  }
  for kind in traversal absoluta extra symlink symlink-rel fifo; do
    make_evil "$kind"
    if run_restore "$BACKUPS/gitea-privado-evil-$kind.tar.gz" "RESTAURAR" >"$TMP/restore-evil-$kind.log" 2>&1; then
      nope "restore.sh acepto un respaldo malicioso ($kind)"
    else
      grep -q 'no es seguro' "$TMP/restore-evil-$kind.log" && [[ -f $INSTALL/data/centinela.txt && ! -e $TMP/srv/escape.txt && ! -e $TMP/escape.txt && ! -e /tmp/gitea-evil-abs.txt ]] \
        && pass "Respaldo malicioso '$kind' rechazado sin tocar datos" || nope "Rechazo incorrecto del respaldo '$kind'"
    fi
  done

  # Imagen no disponible: se aborta ANTES de detener nada.
  sed -i 's/^GITEA_VERSION=.*/GITEA_VERSION=28.4.0/' "$INSTALL/.env"
  : >"$STATE/calls.log"; echo "docker.gitea.com/gitea:28.4.0-rootless" >"$STATE/images"
  if FAKE_PULL_FAIL=28.3.0 run_restore "$ARCHIVE" "RESTAURAR" --use-backup-version >"$TMP/restore-noimg.log" 2>&1; then
    nope "restore.sh continuo sin poder obtener la imagen del respaldo"
  else
    has 'no esta disponible' "$TMP/restore-noimg.log" && test -e "$STATE/running" && ! grep -q 'stop' "$STATE/calls.log" && [[ -f $INSTALL/data/centinela.txt ]] \
      && pass "Imagen del respaldo no disponible: se aborta antes de detener Gitea ni mover datos" || nope "Comportamiento inesperado sin imagen"
  fi

  # Diferencia de version: exige --use-backup-version.
  rm -f "$STATE/images"; echo "docker.gitea.com/gitea:28.4.0-rootless" >"$STATE/images"
  if run_restore "$ARCHIVE" "RESTAURAR" >"$TMP/restore-ver.log" 2>&1; then
    nope "restore.sh no exigio --use-backup-version"
  else
    has 'use-backup-version' "$TMP/restore-ver.log" && pass "Versiones distintas: se exige --use-backup-version" || nope "Mensaje de version inesperado"
  fi
  if run_restore "$ARCHIVE" "RESTAURAR" --use-backup-version >"$TMP/restore-ver2.log" 2>&1 && has '^GITEA_VERSION=28.3.0$' "$INSTALL/.env" && [[ "$(cat "$STATE/running_version")" == "28.3.0" ]]; then
    pass "--use-backup-version fija la version del respaldo en .env y Gitea corre con esa imagen"
  else
    nope "--use-backup-version no ajusto .env"; tail -n 20 "$TMP/restore-ver2.log"
  fi

  section "restore.sh: fallos y recuperacion"
  echo "estado previo a la restauracion fallida" >"$INSTALL/data/centinela.txt"
  make_archive poison POISON
  make_archive corrupt CORRUPTDB
  # (a) La aplicacion no queda saludable tras restaurar: reversion automatica verificada.
  if run_restore "$BACKUPS/gitea-privado-arch-poison.tar.gz" "RESTAURAR" >"$TMP/restore-f1.log" 2>&1; then
    nope "restore.sh dio por buena una restauracion cuya aplicacion no esta saludable"
  else
    check "Restauracion con aplicacion no saludable: se detecta y se declara FALLIDA" has 'LA RESTAURACION FALLO' "$TMP/restore-f1.log"
    check "Reversion automatica: los datos anteriores volvieron a su lugar" test -f "$INSTALL/data/centinela.txt"
    check "Lo restaurado a medias se conservo aparte (*.failed-*), no se borro" bash -c "for d in '$INSTALL'/data.failed-*; do test -e \"\$d/POISON\" && exit 0; done; exit 1"
    check "Tras revertir, Gitea esta saludable con los datos anteriores" bash -c "test -e '$STATE/running' && ! test -e '$INSTALL/data/POISON'"
  fi
  # (b) La base de datos restaurada esta danada aunque el SHA-256 sea valido.
  if run_restore "$BACKUPS/gitea-privado-arch-corrupt.tar.gz" "RESTAURAR" >"$TMP/restore-f2.log" 2>&1; then
    nope "restore.sh acepto una base de datos danada"
  else
    has 'integrity_check' "$TMP/restore-f2.log" && [[ -f $INSTALL/data/centinela.txt ]] && pass "Base de datos restaurada danada: se detecta (integrity_check) y se revierte" || nope "Base danada: comportamiento inesperado"
  fi
  # (c) Fallo durante la extraccion.
  if FAKE_TAR_FAIL_X=1 run_restore "$ARCHIVE" "RESTAURAR" >"$TMP/restore-f3.log" 2>&1; then
    nope "restore.sh no fallo cuando la extraccion fallo"
  else
    [[ -f $INSTALL/data/centinela.txt ]] && test -e "$STATE/running" && pass "Fallo de extraccion: se devuelven los datos anteriores y Gitea sigue en ejecucion" || nope "Fallo de extraccion: estado inesperado"
  fi
  # (d) La reversion automatica NO es posible: se detiene, se conserva todo y se dan instrucciones exactas.
  if FAKE_MV_FAIL_PRE=1 run_restore "$BACKUPS/gitea-privado-arch-poison.tar.gz" "RESTAURAR" >"$TMP/restore-f4.log" 2>&1; then
    nope "restore.sh no fallo cuando la reversion era imposible"
  else
    check "Reversion imposible: entrega instrucciones de RECUPERACION MANUAL exactas" bash -c "grep -q 'RECUPERACION MANUAL' '$TMP/restore-f4.log' && grep -q 'sudo mv $INSTALL/data.pre-restore-' '$TMP/restore-f4.log'"
    check "Reversion imposible: se conservan AMBOS conjuntos de datos (anteriores y restaurados)" bash -c "ls -d '$INSTALL'/data.pre-restore-* >/dev/null 2>&1 && ls -d '$INSTALL'/data.failed-* >/dev/null 2>&1"
  fi
  # Se deja el entorno consistente para las siguientes pruebas (equivale a seguir las instrucciones manuales).
  rm -rf "$INSTALL"/data.pre-restore-* "$INSTALL"/config.pre-restore-* "$INSTALL"/data.failed-* "$INSTALL"/config.failed-* "$INSTALL"/data "$INSTALL"/config # seguro: datos simulados dentro del directorio temporal
  seed_data; reset_state; set_running
fi

echo
section "update.sh"
sed -i 's/^GITEA_VERSION=.*/GITEA_VERSION=28.3.0/' "$INSTALL/.env"
if "$INSTALL/scripts/update.sh" --version 29.0.0 --yes >"$TMP/update-major.log" 2>&1; then
  nope "update.sh acepto un salto de version mayor sin confirmacion escrita"
else
  has '^GITEA_VERSION=28.3.0$' "$INSTALL/.env" && pass "Salto de version mayor: exige confirmacion escrita y no cambia .env" || nope ".env cambio en un salto mayor rechazado"
fi
if "$INSTALL/scripts/update.sh" --version 28.2.0 --yes >"$TMP/update-down.log" 2>&1; then
  nope "update.sh acepto un downgrade"
else
  has 'downgrade' "$TMP/update-down.log" && pass "update.sh rechaza un downgrade" || nope "Mensaje de downgrade inesperado"
fi
if "$INSTALL/scripts/update.sh" --version latest --yes >"$TMP/update-bad.log" 2>&1; then
  nope "update.sh acepto 'latest'"
else
  pass "update.sh rechaza versiones que no son X.Y.Z (nada de latest)"
fi
if FAKE_PULL_FAIL=28.3.5 "$INSTALL/scripts/update.sh" --version 28.3.5 --yes >"$TMP/update-noimg.log" 2>&1; then
  nope "update.sh acepto una version cuya imagen no existe"
else
  has '^GITEA_VERSION=28.3.0$' "$INSTALL/.env" && ! ls "$BACKUPS"/*pre-update-28.3.0* >/dev/null 2>&1 && pass "Imagen inexistente: update.sh se detiene antes de crear respaldo o cambiar .env" || nope "update.sh avanzo sin imagen"
fi
# Una simple respuesta HTTP no es una migracion exitosa: si sigue corriendo la version anterior, es un fallo.
touch "$STATE/keep_version"
if "$INSTALL/scripts/update.sh" --version 28.3.1 --yes >"$TMP/update-same.log" 2>&1; then
  nope "update.sh dio por buena una actualizacion donde sigue corriendo la version anterior"
else
  has 'no es la solicitada' "$TMP/update-same.log" && has 'PROCEDIMIENTO DE RECUPERACION' "$TMP/update-same.log" && pass "Si la version en ejecucion no es la nueva, update.sh falla y muestra el procedimiento de recuperacion" || nope "Mensaje inesperado"
fi
rm -f "$STATE/keep_version"
sed -i 's/^GITEA_VERSION=.*/GITEA_VERSION=28.3.0/' "$INSTALL/.env"; echo "28.3.0" >"$STATE/running_version"
touch "$STATE/unhealthy"
if "$INSTALL/scripts/update.sh" --version 28.3.1 --yes >"$TMP/update-unh.log" 2>&1; then
  nope "update.sh dio por buena una actualizacion con la aplicacion no saludable"
else
  has 'healthcheck' "$TMP/update-unh.log" && pass "Aplicacion no saludable tras actualizar: update.sh falla (no basta con que el contenedor este encendido)" || nope "Mensaje inesperado (no saludable)"
fi
rm -f "$STATE/unhealthy"
sed -i 's/^GITEA_VERSION=.*/GITEA_VERSION=28.3.0/' "$INSTALL/.env"; echo "28.3.0" >"$STATE/running_version"
if "$INSTALL/scripts/update.sh" --version 28.3.1 --yes >"$TMP/update.log" 2>&1; then
  has '^GITEA_VERSION=28.3.1$' "$INSTALL/.env" && pass "update.sh actualiza GITEA_VERSION a 28.3.1" || nope ".env no se actualizo"
  ls "$BACKUPS"/*-pre-update-28.3.0.tar.gz >/dev/null 2>&1 && pass "update.sh crea el respaldo previo (pre-update-28.3.0) antes de modificar" || nope "Falta el respaldo previo a la actualizacion"
  has 'docker pull docker.gitea.com/gitea:28.3.1-rootless' "$STATE/calls.log" && pass "update.sh descarga la imagen rootless indicada" || nope "No se descargo la imagen esperada"
  check "update.sh comprueba que corre la version NUEVA y el esquema de la base de datos" bash -c "grep -q 'Se esta ejecutando la version nueva' '$TMP/update.log' && grep -q 'Esquema de la base de datos' '$TMP/update.log'"
  check "Gitea en ejecucion tras actualizar con la version 28.3.1" bash -c "test -e '$STATE/running' && test \"\$(cat '$STATE/running_version')\" = 28.3.1"
  check "update.sh conserva la copia anterior (respaldo e imagen previa)" has 'La copia anterior se conserva' "$TMP/update.log"
else
  nope "update.sh fallo"; tail -n 30 "$TMP/update.log"
fi
check "update.sh nunca uso 'latest' ni toco otros contenedores" bash -c "! grep -E 'latest|docker (stop|kill|rm)' '$STATE/calls.log'"

echo
section "install.sh (instalacion nueva y repeticion)"
STAGING="$TMP/staging"
INSTALL2="$TMP/srv2/gitea-privado"
mkdir -p "$STAGING" "$TMP/srv2"
cp -r "$ROOT/compose.yaml" "$ROOT/.env.example" "$ROOT/.gitignore" "$ROOT/scripts" "$STAGING/"
reset_state
if GITEA_INSTALL_DIR="$INSTALL2" GITEA_BACKUP_DIR="$TMP/srv2/backups" "$STAGING/scripts/install.sh" --yes >"$TMP/install.log" 2>&1; then
  pass "install.sh completa una instalacion nueva (con comandos simulados)"
else
  nope "install.sh fallo"; tail -n 40 "$TMP/install.log"
fi
[[ -f $INSTALL2/compose.yaml && -d $INSTALL2/data && -d $INSTALL2/config && -d $TMP/srv2/backups ]] && pass "Se crearon la instalacion, data/, config/ y la carpeta de respaldos" || nope "Faltan directorios de la instalacion"
[[ "$(stat -c %a "$INSTALL2/.env")" == "600" && ! -e $STAGING/.env ]] && pass ".env generado solo en el destino (600) y no en la carpeta de preparacion" || nope "Ubicacion/permisos de .env incorrectos"
check "Gitea iniciado por install.sh" test -e "$STATE/running"
check "install.sh informa que falta el asistente de la cuenta administradora" has 'PENDIENTE (hacer ANTES de publicar' "$TMP/install.log"
check "install.sh distingue etapas: contenedor, healthcheck, web, puertos, asistente, HTTPS, SSH, Git y backup" bash -c "for s in 'Contenedor iniciado' 'Healthcheck de Docker' 'Web accesible localmente' 'Puertos Docker solo en 127.0.0.1' 'Asistente de Gitea completado' 'HTTPS privado habilitado' 'SSH privado habilitado' 'Operacion Git verificada' 'Backup verificado'; do grep -q \"\$s\" '$TMP/install.log' || exit 1; done"
check "install.sh NO da por hecho lo no verificado (Git y backup quedan pendientes)" bash -c "grep 'Operacion Git verificada' '$TMP/install.log' | grep -q 'NO VERIFICADO' && grep 'Backup verificado' '$TMP/install.log' | grep -q 'PENDIENTE'"
check "install.sh explica el tunel SSH administrativo para el asistente" has 'ssh -L 3090:127.0.0.1:3090' "$TMP/install.log"
check "install.sh descarga la imagen" bash -c "grep -q 'docker pull\|compose .* pull' '$STATE/calls.log'"
check "install.sh no publica en Tailscale por si mismo" test ! -s "$STATE/ts-mutations.log"
env_before=$(sha256sum "$INSTALL2/.env")
ups_before=$(grep -c ' up ' "$STATE/calls.log" || true)
if GITEA_INSTALL_DIR="$INSTALL2" GITEA_BACKUP_DIR="$TMP/srv2/backups" "$INSTALL2/scripts/install.sh" >"$TMP/install2.log" 2>&1; then
  ups_after=$(grep -c ' up ' "$STATE/calls.log" || true)
  [[ $env_before == "$(sha256sum "$INSTALL2/.env")" && $ups_before == "$ups_after" ]] && pass "Repetir install.sh no cambia .env ni reinicia Gitea sin autorizacion" || nope "La repeticion cambio .env o reinicio Gitea"
else
  nope "install.sh fallo al repetirse"; tail -n 40 "$TMP/install2.log"
fi
# Los puertos reales no cumplen: la instalacion NO se declara completa aunque haya HTTP.
reset_state
INSTALL3="$TMP/srv3/gitea-privado"; mkdir -p "$TMP/srv3"
if FAKE_PORTS_BAD=1 GITEA_INSTALL_DIR="$INSTALL3" GITEA_BACKUP_DIR="$TMP/srv3/backups" "$STAGING/scripts/install.sh" --yes >"$TMP/install-bad.log" 2>&1; then
  nope "install.sh declaro completa una instalacion con un puerto publicado en 0.0.0.0"
else
  has 'host_ip\|Puertos publicados\|127.0.0.1' "$TMP/install-bad.log" && pass "Un puerto publicado fuera de 127.0.0.1 hace fallar install.sh (verificacion de puertos reales)" || nope "mensaje de puertos inesperado"
fi
reset_state
if FAKE_PUBLIC_PORTS=1 GITEA_INSTALL_DIR="$INSTALL3" GITEA_BACKUP_DIR="$TMP/srv3/backups" "$STAGING/scripts/install.sh" --yes >"$TMP/install-bad2.log" 2>&1; then
  nope "install.sh acepto una configuracion Compose con host_ip 0.0.0.0"
else
  pass "install.sh rechaza una configuracion Compose resuelta con puertos en 0.0.0.0"
fi

echo
section "status.sh y smoke-test.sh"
sed -i 's/^GITEA_VERSION=.*/GITEA_VERSION=28.3.0/' "$INSTALL/.env"
reset_state; seed_data; set_running
"$INSTALL/scripts/configure-tailscale.sh" --yes >"$TMP/ts-for-status.log" 2>&1 || cat "$TMP/ts-for-status.log"
"$INSTALL/scripts/status.sh" >"$TMP/status.log" 2>&1 || true
check "status.sh muestra el estado por etapas" has 'Estado por etapas' "$TMP/status.log"
check "status.sh: HTTPS y SSH de Serve detectados como habilitados" bash -c "grep 'HTTPS privado habilitado' '$TMP/status.log' | grep -q 'SI' && grep 'SSH privado habilitado' '$TMP/status.log' | grep -q 'SI'"
check "status.sh no modifica nada (sin comandos mutantes)" bash -c "! grep -E 'compose .* (up|stop|start|down)' '$STATE/calls.log'"
check "status.sh muestra la seccion de huellas SSH del servidor" has 'Huellas SSH del servidor Git' "$TMP/status.log"
if "$INSTALL/scripts/smoke-test.sh" >"$TMP/smoke.log" 2>&1; then pass "smoke-test.sh pasa con el entorno simulado"; else nope "smoke-test.sh fallo"; tail -n 30 "$TMP/smoke.log"; fi
check "smoke-test comprueba healthcheck, puertos locales, SSH local, Serve y ausencia de Funnel" bash -c "for s in 'Healthcheck de Docker: healthy' 'Docker publica solo 127.0.0.1' 'SSH de Git responde en 127.0.0.1' 'Serve: HTTPS' 'Serve: TCP' 'Sin Funnel'; do grep -q \"\$s\" '$TMP/smoke.log' || exit 1; done"
check "smoke-test marca como OMITIDA la autenticacion SSH y recuerda la prueba integral manual" bash -c "grep -q 'OMITIDA' '$TMP/smoke.log' && grep -q 'prueba integral manual' '$TMP/smoke.log'"
FAKE_PORTS_BAD=1 "$INSTALL/scripts/smoke-test.sh" >"$TMP/smoke-bad.log" 2>&1 && nope "smoke-test no detecto un puerto publicado en 0.0.0.0" || pass "smoke-test detecta puertos publicados fuera de 127.0.0.1"
echo '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3090"}}}},"AllowFunnel":{"srv.tail1234.ts.net:443":true}}' >"$STATE/serve.json"
"$INSTALL/scripts/smoke-test.sh" >"$TMP/smoke-funnel.log" 2>&1 && nope "smoke-test no detecto Funnel" || pass "smoke-test detecta Funnel activo (exposicion publica)"
rm -f "$STATE/serve.json"
"$INSTALL/scripts/configure-tailscale.sh" --yes >/dev/null 2>&1 || true
: >"$STATE/calls.log"
"$INSTALL/scripts/smoke-test.sh" --recreate-test >"$TMP/smoke-rec.log" 2>&1 </dev/null || true
check "--recreate-test sin confirmacion explicita NO recrea el contenedor" bash -c "! grep -q -- '--force-recreate' '$STATE/calls.log'"
if "$INSTALL/scripts/smoke-test.sh" --recreate-test --yes >"$TMP/smoke-rec2.log" 2>&1; then
  has 'Los datos persisten' "$TMP/smoke-rec2.log" && pass "--recreate-test --yes recrea el contenedor y comprueba la persistencia" || nope "persistencia no verificada"
else
  nope "smoke-test --recreate-test --yes fallo"; tail -n 20 "$TMP/smoke-rec2.log"
fi

echo
printf '[DURACION] %s: %ss\n' "$GROUP_NAME" "$((SECONDS - GROUP_STARTED))"
printf 'Pasan: %s | Fallan: %s | Omitidas: %s\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 )) || exit 1
echo "Prueba de ciclo de vida (SIMULADA, no es una prueba de integracion real) completada sin fallos."
