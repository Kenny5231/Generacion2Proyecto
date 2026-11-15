#!/usr/bin/env bash
# test-static.sh - Pruebas estaticas del proyecto. No necesita el servidor Ubuntu.
# Usa las herramientas disponibles (bash, ShellCheck, PowerShell, Docker) y marca como OMITIDAS
# las comprobaciones cuyas herramientas no existen; nunca finge haberlas ejecutado.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT"

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf '  [PASA]     %s\n' "$*"; }
nope() { FAIL=$((FAIL + 1)); printf '  [FALLA]    %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  [OMITIDA]  %s\n' "$*"; }
group() { printf '\n== %s ==\n' "$*"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT # seguro: directorio temporal propio creado con mktemp

SH_FILES=(scripts/*.sh tests/*.sh)
PS_FILES=(windows/*.ps1)
TEXT_FILES=(compose.yaml .env.example .gitignore .gitattributes README.md ENTREGA.md REVISION-SEGURIDAD.md scripts/*.sh scripts/*.py windows/*.ps1 docs/*.md tests/*.sh)

# ---------------------------------------------------------------- 1. archivos
group "Archivos requeridos"
REQUIRED=(
  compose.yaml .env.example .gitignore README.md ENTREGA.md REVISION-SEGURIDAD.md
  scripts/common.sh scripts/preflight.sh scripts/configure.sh scripts/install.sh
  scripts/configure-tailscale.sh scripts/tsjson.py scripts/status.sh scripts/backup.sh scripts/restore.sh
  scripts/update.sh scripts/smoke-test.sh
  windows/setup-git.ps1 windows/upload-project.ps1
  docs/INSTALACION-MANANA.md docs/ARQUITECTURA.md docs/SEGURIDAD.md docs/BACKUPS.md
  docs/COMANDOS-GIT.md docs/SOLUCION-PROBLEMAS.md
  tests/test-static.sh tests/test-lifecycle.sh
)
missing=0
for f in "${REQUIRED[@]}"; do
  if [[ ! -s $f ]]; then
    nope "Falta o esta vacio: $f"
    missing=1
  fi
done
[[ $missing -eq 0 ]] && pass "Existen y no estan vacios los ${#REQUIRED[@]} archivos requeridos"

# ---------------------------------------------------------------- 2. sintaxis bash
group "Sintaxis Bash"
for f in "${SH_FILES[@]}"; do
  if bash -n "$f" 2>"$TMP_DIR/err"; then
    pass "bash -n $f"
  else
    nope "bash -n $f: $(head -n 1 "$TMP_DIR/err")"
  fi
  if grep -q $'\r' "$f"; then
    nope "$f tiene finales de linea CRLF (debe ser LF)"
  fi
  if ! grep -q '^set -Eeuo pipefail' "$f"; then
    nope "$f no activa 'set -Eeuo pipefail'"
  fi
done

# ---------------------------------------------------------------- 3. ShellCheck
group "ShellCheck"
SHELLCHECK=""
if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK="shellcheck"
elif [[ -x $ROOT/.tools/bin/shellcheck ]]; then
  SHELLCHECK="$ROOT/.tools/bin/shellcheck"
fi
if [[ -n $SHELLCHECK ]]; then
  if "$SHELLCHECK" -x -S warning "${SH_FILES[@]}" >"$TMP_DIR/sc" 2>&1; then
    pass "ShellCheck sin advertencias (${#SH_FILES[@]} archivos)"
  else
    nope "ShellCheck reporto problemas:"
    head -n 40 "$TMP_DIR/sc"
  fi
else
  skip "ShellCheck no esta instalado (sudo apt install shellcheck). Ejecutelo en Ubuntu antes de instalar."
fi

# ---------------------------------------------------------------- 4. PowerShell
group "Sintaxis PowerShell"
PWSH=""
for candidate in pwsh powershell.exe powershell; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PWSH=$candidate
    break
  fi
done
if [[ -n $PWSH ]]; then
  for f in "${PS_FILES[@]}"; do
    path=$f
    if [[ $PWSH == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
      path=$(wslpath -w "$ROOT/$f")
    elif [[ $PWSH == *.exe ]]; then
      path="$ROOT/$f"
    fi
    if out=$("$PWSH" -NoProfile -NonInteractive -Command "\$t=\$null;\$e=\$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$path',[ref]\$t,[ref]\$e); if(\$e.Count -gt 0){\$e | ForEach-Object { \$_.Message }; exit 1}" 2>&1); then
      pass "PowerShell analiza sin errores: $f"
    else
      nope "PowerShell: $f: $out"
    fi
  done
else
  skip "PowerShell no esta disponible: los .ps1 no se analizaron (ejecutelo en Windows)."
fi
for f in "${PS_FILES[@]}"; do
  if LC_ALL=C grep -q -P '[^\x00-\x7F]' "$f"; then
    nope "$f contiene caracteres no ASCII (PowerShell 5.1 puede leerlos mal)"
  fi
done

# ---------------------------------------------------------------- 5. compose (texto)
group "compose.yaml (analisis de texto)"
check_text() { # descripcion patron archivo
  if grep -Eq -- "$2" "$3"; then pass "$1"; else nope "$1"; fi
}
check_absent() { # descripcion patron archivo
  if grep -Eq -- "$2" "$3"; then nope "$1"; else pass "$1"; fi
}
check_text "Imagen oficial rootless con version desde GITEA_VERSION" '^[[:space:]]+image: docker\.gitea\.com/gitea:\$\{GITEA_VERSION:\?[^}]*\}-rootless$' compose.yaml
check_absent "Sin etiqueta latest" ':latest' compose.yaml
check_text "Reinicio automatico (unless-stopped)" 'restart: unless-stopped' compose.yaml
check_text "no-new-privileges activo" 'no-new-privileges:true' compose.yaml
check_text "Persistencia ./data:/var/lib/gitea" '\./data:/var/lib/gitea' compose.yaml
check_text "Persistencia ./config:/etc/gitea" '\./config:/etc/gitea' compose.yaml
check_text "Nombre de proyecto exclusivo" '^name: gitea-privado$' compose.yaml
check_text "Web enlazada a 127.0.0.1 (puerto 3000 interno)" '"127\.0\.0\.1:\$\{GITEA_WEB_PORT:-3090\}:3000"' compose.yaml
check_text "SSH enlazado a 127.0.0.1 con puerto local propio (2222 interno)" '"127\.0\.0\.1:\$\{GITEA_SSH_LOCAL_PORT:-2222\}:2222"' compose.yaml
check_absent "Compose no depende de GITEA_TAILSCALE_IP (arranque independiente de Tailscale)" '^[^#]*GITEA_TAILSCALE_IP' compose.yaml
check_text "Se anuncia el puerto SSH de la tailnet (GITEA_SSH_PORT) en las URL de clonado" 'GITEA__server__SSH_PORT: \$\{GITEA_SSH_PORT:-2222\}' compose.yaml
check_text "Healthcheck usa /api/healthz (sin alternativa laxa)" 'test: \["CMD-SHELL", "curl -fsS -o /dev/null http://127\.0\.0\.1:3000/api/healthz"\]' compose.yaml
check_text "Se eliminan todas las capacidades (cap_drop ALL)" 'cap_drop:' compose.yaml
check_text "Git hooks personalizados deshabilitados" 'GITEA__security__DISABLE_GIT_HOOKS: "true"' compose.yaml
check_text "Usuario rootless 1000:1000" 'user: "1000:1000"' compose.yaml
for key in 'GITEA__service__DISABLE_REGISTRATION: "true"' 'GITEA__service__REQUIRE_SIGNIN_VIEW: "true"' 'GITEA__repository__FORCE_PRIVATE: "true"' 'GITEA__repository__DEFAULT_PRIVATE: private' 'GITEA__actions__ENABLED: "false"' 'GITEA__database__DB_TYPE: sqlite3' 'GITEA__server__START_SSH_SERVER: "true"' 'GITEA__server__SSH_LISTEN_PORT: "2222"'; do
  if grep -Fq -- "$key" compose.yaml; then pass "Configuracion: $key"; else nope "Falta: $key"; fi
done
check_absent "No define INSTALL_LOCK (no bloquea el asistente inicial)" '^[[:space:]]+GITEA__security__INSTALL_LOCK' compose.yaml
for bad in 'privileged' 'network_mode' 'docker\.sock' 'pid:[[:space:]]*host' 'cap_add' '0\.0\.0\.0' 'ipc:[[:space:]]*host'; do
  check_absent "Compose no contiene '$bad'" "^[^#]*$bad" compose.yaml
done
bad_ports=$(awk '/^    ports:/ { f = 1; next } f && /^    [a-z]/ { f = 0 } f && /^      - / && $0 !~ /"127\.0\.0\.1:/ { print }' compose.yaml)
if [[ -z $bad_ports ]]; then pass "Todos los puertos publicados estan enlazados a 127.0.0.1"; else nope "Puertos no enlazados a 127.0.0.1: $bad_ports"; fi
n_ports=$(awk '/^    ports:/ { f = 1; next } f && /^    [a-z]/ { f = 0 } f && /^      - / { n++ } END { print n + 0 }' compose.yaml)
if [[ $n_ports -eq 2 ]]; then pass "Compose publica exactamente 2 puertos (HTTP y SSH locales)"; else nope "Se esperaban 2 puertos publicados y hay $n_ports"; fi

# ---------------------------------------------------------------- 6. compose (docker)
group "Docker Compose con variables de prueba"
DOCKER=""
for candidate in docker docker.exe; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" compose version >/dev/null 2>&1; then
    DOCKER=$candidate
    break
  fi
done
if [[ -n $DOCKER ]]; then
  test_env=(GITEA_VERSION=28.3.0 GITEA_TS_DNS=srv.tail1234.ts.net GITEA_SSH_DOMAIN=srv.tail1234.ts.net GITEA_ROOT_URL=https://srv.tail1234.ts.net/)
  # WSLENV reenvia las variables cuando se usa docker.exe de Windows desde WSL (no afecta a Linux).
  test_env+=(WSLENV=GITEA_VERSION:GITEA_TS_DNS:GITEA_SSH_DOMAIN:GITEA_ROOT_URL:GITEA_WEB_PORT:GITEA_SSH_LOCAL_PORT:GITEA_SSH_PORT)
  if rendered=$(env "${test_env[@]}" "$DOCKER" compose -f compose.yaml config 2>"$TMP_DIR/err"); then
    pass "docker compose config valida con variables de prueba"
    if [[ $(grep -c 'host_ip: 127.0.0.1' <<<"$rendered") -eq 2 ]]; then pass "HTTP y SSH publicados solo en 127.0.0.1 (2 puertos)"; else nope "Se esperaban exactamente 2 puertos en 127.0.0.1"; fi
    if grep -q 'published: "3090"' <<<"$rendered" && grep -q 'published: "2222"' <<<"$rendered"; then pass "Puertos por defecto: web 3090 y SSH local 2222"; else nope "Puertos publicados por defecto inesperados"; fi
    if grep -Eq 'host_ip: (0\.0\.0\.0|::)' <<<"$rendered"; then nope "Hay puertos en todas las interfaces"; else pass "Ningun puerto en 0.0.0.0"; fi
    if grep -q 'image: docker.gitea.com/gitea:28.3.0-rootless' <<<"$rendered"; then pass "Imagen fija 28.3.0-rootless"; else nope "Imagen inesperada"; fi
    if grep -Eq 'privileged|network_mode|docker\.sock' <<<"$rendered"; then nope "La configuracion resuelta incluye privileged/network_mode/docker.sock"; else pass "Configuracion resuelta sin privileged, network_mode ni docker.sock"; fi
    if grep -q 'GITEA__server__SSH_PORT: "2222"' <<<"$rendered" && grep -q 'GITEA__server__SSH_LISTEN_PORT: "2222"' <<<"$rendered"; then pass "SSH anunciado y escuchado en 2222 por defecto"; else nope "SSH_PORT/SSH_LISTEN_PORT inesperados"; fi
  else
    nope "docker compose config fallo: $(head -n 3 "$TMP_DIR/err")"
  fi
  # Los cuatro puertos son independientes: el SSH anunciado en la tailnet no cambia el puerto local publicado.
  if rendered=$(env "${test_env[@]}" GITEA_WEB_PORT=3191 GITEA_SSH_LOCAL_PORT=2299 GITEA_SSH_PORT=2200 "$DOCKER" compose -f compose.yaml config 2>"$TMP_DIR/err"); then
    if grep -q 'published: "3191"' <<<"$rendered" && grep -q 'published: "2299"' <<<"$rendered" && grep -q 'GITEA__server__SSH_PORT: "2200"' <<<"$rendered" && grep -q 'GITEA__server__SSH_LISTEN_PORT: "2222"' <<<"$rendered"; then
      pass "Puertos configurables: HTTP local, SSH local y SSH anunciado son independientes"
    else
      nope "Los puertos configurables no se reflejan como se esperaba"
    fi
  else
    nope "docker compose config fallo con puertos personalizados: $(head -n 3 "$TMP_DIR/err")"
  fi
  # La IP de Tailscale ya no se necesita: Compose arranca sin ella.
  if env "${test_env[@]}" GITEA_TAILSCALE_IP=100.101.102.103 "$DOCKER" compose -f compose.yaml config >/dev/null 2>&1; then
    pass "Compose arranca sin depender de la IP de Tailscale (una variable heredada se ignora)"
  else
    nope "Compose fallo con una GITEA_TAILSCALE_IP heredada"
  fi
  # Sin variables obligatorias Compose debe detenerse.
  for req in GITEA_VERSION GITEA_TS_DNS GITEA_SSH_DOMAIN GITEA_ROOT_URL; do
    if env "${test_env[@]}" "$req=" "$DOCKER" compose -f compose.yaml config >/dev/null 2>&1; then
      nope "Compose NO se detuvo con $req vacia"
    else
      pass "Compose se detiene si falta $req"
    fi
  done
else
  skip "Docker Compose no esta disponible: compose.yaml no se valido con 'docker compose config'."
fi

# ---------------------------------------------------------------- 7. .env.example y .gitignore
group "Configuracion y archivos sensibles"
for key in GITEA_VERSION GITEA_INSTALL_DIR GITEA_BACKUP_DIR GITEA_TS_DNS GITEA_TS_HTTPS_PORT GITEA_ROOT_URL GITEA_SSH_DOMAIN GITEA_WEB_PORT GITEA_SSH_LOCAL_PORT GITEA_SSH_PORT TZ; do
  if grep -q "^${key}=" .env.example; then pass ".env.example define $key"; else nope ".env.example no define $key"; fi
done
check_text ".env.example fija GITEA_VERSION=28.3.0" '^GITEA_VERSION=28\.3\.0$' .env.example
check_absent ".env.example ya no define la clave obsoleta GITEA_TAILSCALE_IP" '^GITEA_TAILSCALE_IP=' .env.example
check_text ".env.example deja el DNS vacio" '^GITEA_TS_DNS=$' .env.example
check_text ".env.example: puertos por defecto 3090/2222/2222/443" '^GITEA_WEB_PORT=3090$' .env.example
check_absent ".env.example sin claves/contrasenas/tokens" '^[A-Z_]*(PASS|PASSWORD|SECRET|TOKEN|PRIVATE)[A-Z_]*=' .env.example
for pattern in '^\.env$' '^data/$' '^config/$' '^\*\.tar\.gz$' '^\*\.zip$' '^\*\.sha256$' '^\*\.log$' '^\*\.db$'; do
  check_text ".gitignore contiene $pattern" "$pattern" .gitignore
done
if [[ -e .env ]]; then
  if git check-ignore -q .env 2>/dev/null || grep -q '^\.env$' .gitignore; then pass ".env presente y excluido de Git"; else nope ".env presente pero no excluido"; fi
fi

group "Secretos y contrasenas"
leaks=$(grep -nEI -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|(PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE_KEY)[A-Z_]*=[^[:space:]$"<>]{3,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|ssh-(ed25519|rsa) AAAA[A-Za-z0-9+/]{20,}|tskey-[A-Za-z0-9-]{10,}' "${TEXT_FILES[@]}" 2>/dev/null | grep -v '^tests/test-static.sh:' || true)
if [[ -z $leaks ]]; then pass "No se detectaron contrasenas, claves ni tokens reales"; else nope "Posibles secretos:"; printf '%s\n' "$leaks" | head -n 10; fi
# No debe haber IP ni dominios reales de ejemplo con apariencia de produccion en .env.example
check_absent "No hay IP 100.x escrita en .env.example" '^GITEA_TAILSCALE_IP=100\.' .env.example

# ---------------------------------------------------------------- 8. comandos peligrosos
group "Comandos peligrosos en scripts"
exec_lines() { # imprime lineas no comentadas de los scripts con numero y archivo
  grep -nE -- "$1" "${SH_FILES[@]}" "${PS_FILES[@]}" 2>/dev/null | grep -v '^tests/test-static.sh:' | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
for pattern in 'docker[[:space:]]+system[[:space:]]+prune' 'docker[[:space:]]+volume[[:space:]]+(prune|rm)' 'docker[[:space:]]+image[[:space:]]+prune' \
  'down[[:space:]]+(-v|--volumes)' 'docker[[:space:]]+(stop|kill|rm|rmi|restart|pause)[[:space:]]' 'chmod[[:space:]]+(-R[[:space:]]+)?0?777' \
  'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' 'wget[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' \
  'StrictHostKeyChecking[[:space:]=]+(no|off|accept-new)' 'UserKnownHostsFile[[:space:]=]+/dev/null' \
  'tailscale[[:space:]]+funnel' '^[[:space:]]*(sudo[[:space:]]+)?tailscale[[:space:]]+(up|down|logout|set|serve[[:space:]]+reset)' \
  '--privileged' 'docker\.sock' '\b(ufw|iptables|nft)\b[[:space:]]+(allow|-A|-I|add|disable)' 'mkfs|dd[[:space:]]+if=' 'network_mode'; do
  hits=$(exec_lines "$pattern")
  if [[ -z $hits ]]; then pass "Sin ejecutar: $pattern"; else nope "Patron peligroso '$pattern':"; printf '%s\n' "$hits" | head -n 5; fi
done
# rm recursivo solo con anotacion "# seguro:" en la misma linea
rm_hits=$(grep -nE -- '(^|[;&|[:space:]])rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*)[[:space:]]' "${SH_FILES[@]}" | grep -v '^tests/test-static.sh:' | grep -v '# seguro:' | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -z $rm_hits ]]; then pass "Todo 'rm -r' recursivo esta anotado como seguro"; else nope "rm -r sin anotacion '# seguro:':"; printf '%s\n' "$rm_hits"; fi
# Todo "docker compose" ejecutable debe indicar el proyecto (-p / --project-name) salvo 'version'.
dc_hits=$(grep -nE -- 'docker compose' scripts/*.sh | grep -Ev 'docker compose (-p|--project-name|version)|--project-name|^[^:]+:[0-9]+:[[:space:]]*#' | grep -E '^[^:]+:[0-9]+:[[:space:]]*[^[:space:]#]' | grep -Ev 'printf|echo|\$\(|cat|warn|info|fail|die|ok |confirm' || true)
if [[ -z $dc_hits ]]; then pass "Los 'docker compose' ejecutados siempre indican el proyecto"; else nope "docker compose sin proyecto:"; printf '%s\n' "$dc_hits" | head -n 5; fi
if grep -qE 'Get-Content[[:space:]]+(-Path[[:space:]]+)?\$keyPath([[:space:]]|$)' windows/setup-git.ps1; then nope "setup-git.ps1 lee la clave privada"; else pass "setup-git.ps1 no lee la clave privada"; fi

# ---------------------------------------------------------------- 9. funciones de validacion
group "Pruebas unitarias de validadores (scripts/common.sh)"
unit_out=$(bash -s <<'UNIT' 2>&1
set -Eeuo pipefail
source scripts/common.sh
t() { if "$@"; then echo "ok: $*"; else echo "FALLA: $*"; return 1; fi; }
n() { if "$@"; then echo "FALLA (debia rechazar): $*"; return 1; else echo "ok (rechaza): $*"; fi; }
t is_tailscale_ip 100.101.102.103
t is_tailscale_ip 100.64.0.5
t is_tailscale_ip 100.127.1.1
n is_tailscale_ip 192.168.1.10
n is_tailscale_ip 100.63.0.1
n is_tailscale_ip 100.128.0.1
n is_tailscale_ip 100.100.100.100
n is_tailscale_ip 100.64.0.0
n is_tailscale_ip ""
n is_tailscale_ip 100.101.102.300
t is_ts_dns srv.tail1234.ts.net
t is_ts_dns mi-servidor.tail-abc.ts.net
n is_ts_dns srv.example.ts.net
n is_ts_dns servidor.nombre-tailnet.ts.net
n is_ts_dns localhost
n is_ts_dns 192.168.1.10
n is_ts_dns srv.tail1234.com
n is_ts_dns ""
t is_port 3090
t is_port 65535
n is_port 0
n is_port 70000
n is_port abc
t is_version 28.3.0
n is_version latest
n is_version 28.3
t version_gt 28.3.1 28.3.0
t version_gt 29.0.0 28.12.9
n version_gt 28.3.0 28.3.0
n version_gt 28.2.9 28.3.0
t is_abs_path /srv/gitea-privado
n is_abs_path relativo/ruta
n is_abs_path /
n is_abs_path /srv/../etc
[[ "$(build_root_url srv.tail1234.ts.net 443)" == "https://srv.tail1234.ts.net/" ]] && echo "ok: build_root_url 443"
[[ "$(build_root_url srv.tail1234.ts.net 8443)" == "https://srv.tail1234.ts.net:8443/" ]] && echo "ok: build_root_url 8443"
[[ "$(normalize_dns Srv.Tail1234.TS.net.)" == "srv.tail1234.ts.net" ]] && echo "ok: normalize_dns"
t is_under /srv/gitea-privado/data /srv/gitea-privado
n is_under /srv/backups/gitea-privado /srv/gitea-privado
d=$(mktemp -d)
printf 'GITEA_VERSION=28.3.0\nTZ=UTC\n' >"$d/ok.env"
printf 'GITEA_VERSION=$(touch /tmp/pwned)\n' >"$d/bad.env"
printf 'OTRA_CLAVE=1\n' >"$d/key.env"
( load_env_file "$d/ok.env" && [[ $GITEA_VERSION == 28.3.0 ]] ) && echo "ok: load_env_file valido"
( load_env_file "$d/bad.env" ) >/dev/null 2>&1 && { echo "FALLA: acepto una linea con sustitucion"; exit 1; } || echo "ok (rechaza): linea con sustitucion"
( load_env_file "$d/key.env" ) >/dev/null 2>&1 && { echo "FALLA: acepto una clave no permitida"; exit 1; } || echo "ok (rechaza): clave no permitida"
env_set "$d/ok.env" GITEA_VERSION 28.3.1
env_set "$d/ok.env" GITEA_WEB_PORT 3091
[[ "$(read_env_value "$d/ok.env" GITEA_VERSION)" == "28.3.1" && "$(read_env_value "$d/ok.env" GITEA_WEB_PORT)" == "3091" && "$(read_env_value "$d/ok.env" TZ)" == "UTC" ]] && echo "ok: env_set/read_env_value"
[[ "$(stat -c %a "$d/ok.env")" == "600" ]] && echo "ok: env_set conserva permisos 600"
rm -rf -- "$d" # seguro: directorio temporal propio creado con mktemp
UNIT
) || true
if grep -q '^FALLA' <<<"$unit_out" || ! grep -q 'ok: env_set/read_env_value' <<<"$unit_out"; then
  nope "Validadores: hay fallos"
  printf '%s\n' "$unit_out" | grep -v '^ok' | head -n 15
else
  pass "Validadores y utilidades de .env: $(grep -c '^ok' <<<"$unit_out") comprobaciones correctas"
fi

# ---------------------------------------------------------------- 9b. JSON de Tailscale
group "Analisis estructurado del JSON de Tailscale (scripts/tsjson.py)"
if command -v python3 >/dev/null 2>&1; then
  if python3 -m py_compile scripts/tsjson.py 2>"$TMP_DIR/err"; then pass "tsjson.py compila"; else nope "tsjson.py no compila: $(head -n 2 "$TMP_DIR/err")"; fi
  find scripts -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true # seguro: cache generada por py_compile
  serve() { python3 scripts/tsjson.py serve --dns srv.tail1234.ts.net --https-port 443 --web-port 3090 --ssh-port 2222 --ssh-local-port 2222; }
  expect() { # descripcion JSON patron-salida codigo-esperado
    local out rc=0
    out=$(printf '%s' "$2" | serve) || rc=$?
    if [[ $rc -eq $4 ]] && grep -Eq -- "$3" <<<"$out"; then pass "$1"; else nope "$1 (codigo $rc; salida: $(tr '\n' ' ' <<<"$out"))"; fi
  }
  H='"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3090"}}}}'
  S='"2222":{"TCPForward":"127.0.0.1:2222"}'
  expect "Serve vacio {}: ambos servicios libres" '{}' '^https=free$' 0
  expect "Serve vacio {}: SSH libre" '{}' '^ssh=free$' 0
  expect "HTTPS propio reconocido (proxy a 127.0.0.1:3090)" "{$H}" '^https=ours$' 0
  expect "HTTPS propio: el SSH sigue libre" "{$H}" '^ssh=free$' 0
  expect "HTTPS + SSH propios (dos servicios)" '{"TCP":{"443":{"HTTPS":true},'"$S"'},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3090"}}}}}' '^ssh=ours$' 0
  expect "Proxy con barra final equivale al nuestro" '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3090/"}}}}}' '^https=ours$' 0
  expect "HTTPS ajeno (otro puerto local) = foreign, no se pisa" '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}' '^https=foreign$' 0
  expect "Coincidencia textual NO basta: URL de Gitea en otra ruta = foreign" '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/otra":{"Proxy":"http://127.0.0.1:3090"}}}}}' '^https=foreign$' 0
  expect "HTTPS con rutas extra = foreign" '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3090"},"/x":{"Path":"/tmp"}}}}}' '^https=foreign$' 0
  expect "Puerto 443 con TCP (no HTTPS) = foreign" '{"TCP":{"443":{"TCPForward":"127.0.0.1:9999"}}}' '^https=foreign$' 0
  expect "SSH: puerto 2222 reenviado a otro destino = foreign" '{"TCP":{"2222":{"TCPForward":"127.0.0.1:2200"}}}' '^ssh=foreign$' 0
  expect "SSH: puerto 2222 con TLS terminado = foreign" '{"TCP":{"2222":{"TCPForward":"127.0.0.1:2222","TerminateTLS":"srv.tail1234.ts.net"}}}' '^ssh=foreign$' 0
  expect "Otros servicios en otros puertos no cuentan como conflicto" '{"TCP":{"8443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"}}}}}' '^https=free$' 0
  expect "Funnel sobre el puerto de Gitea se detecta" '{"TCP":{"443":{"HTTPS":true}},"Web":{"srv.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3090"}}}},"AllowFunnel":{"srv.tail1234.ts.net:443":true}}' '^funnel=on$' 0
  expect "Funnel ajeno se informa pero no es el de Gitea" '{"AllowFunnel":{"srv.tail1234.ts.net:8443":true}}' '^funnel=none$' 0
  expect "Estructura desconocida: falla de forma segura" '{"Nuevo":{"x":1}}' '^schema=unrecognized$' 3
  expect "JSON invalido: falla de forma segura" 'esto no es json' '^schema=unrecognized$' 3
  expect "Entrada vacia: falla de forma segura" '' '^schema=unrecognized$' 3
  expect "TCP con tipo inesperado: falla de forma segura" '{"TCP":[1,2]}' '^schema=unrecognized$' 3
  status_field() { printf '%s' "$2" | python3 scripts/tsjson.py status "$1"; }
  ST='{"BackendState":"Running","Self":{"DNSName":"Srv.Tail1234.ts.net.","TailscaleIPs":["fd7a:115c::1","100.101.102.103"]},"CertDomains":["srv.tail1234.ts.net"],"Peer":{"k":{"DNSName":"otro.tail1234.ts.net."}}}'
  [[ "$(status_field state "$ST")" == "Running" ]] && pass "status: BackendState" || nope "status: BackendState"
  [[ "$(status_field dns "$ST")" == "srv.tail1234.ts.net" ]] && pass "status: DNS propio normalizado (no el de un par)" || nope "status: DNS"
  [[ "$(status_field ip4 "$ST")" == "100.101.102.103" ]] && pass "status: IPv4 propia" || nope "status: IPv4"
  [[ "$(status_field certs "$ST")" == "1" ]] && pass "status: dominios de certificado" || nope "status: certs"
else
  skip "python3 no esta disponible: no se probo tsjson.py (necesario tambien en el servidor)."
fi

# ---------------------------------------------------------------- 9c. variables y puertos
group "Validacion de variables y puertos (common.sh)"
ports_out=$(bash -s <<'UNIT' 2>&1
set -Eeuo pipefail
source scripts/common.sh
good() { # descripcion
  local desc=$1; shift
  ( CHECK_ERRORS=0; eval "$@"; validate_ports >/dev/null 2>&1 ) && echo "ok: $desc" || echo "FALLA: $desc (debia aceptar)"
}
bad() {
  local desc=$1; shift
  ( CHECK_ERRORS=0; eval "$@"; validate_ports >/dev/null 2>&1 ) && echo "FALLA: $desc (debia rechazar)" || echo "ok (rechaza): $desc"
}
D='GITEA_WEB_PORT=3090 GITEA_SSH_LOCAL_PORT=2222 GITEA_SSH_PORT=2222 GITEA_TS_HTTPS_PORT=443'
good "puertos por defecto" "$D"
good "SSH local distinto del SSH de la tailnet" "$D; GITEA_SSH_LOCAL_PORT=2299"
good "HTTPS 8443" "$D; GITEA_TS_HTTPS_PORT=8443"
bad "web fuera de rango" "$D; GITEA_WEB_PORT=70000"
bad "web no numerico" "$D; GITEA_WEB_PORT=abc"
bad "SSH local vacio" "$D; GITEA_SSH_LOCAL_PORT="
bad "SSH tailnet 0" "$D; GITEA_SSH_PORT=0"
bad "web y SSH local iguales" "$D; GITEA_WEB_PORT=2222"
bad "HTTPS no admitido por Serve (8080)" "$D; GITEA_TS_HTTPS_PORT=8080"
bad "SSH de la tailnet igual al HTTPS" "$D; GITEA_SSH_PORT=443"
UNIT
) || true
if grep -q '^FALLA' <<<"$ports_out" || ! grep -q '^ok' <<<"$ports_out"; then
  nope "validate_ports: hay fallos"; printf '%s\n' "$ports_out" | grep -v '^ok' | head -n 10
else
  pass "validate_ports: $(grep -c '^ok' <<<"$ports_out") casos correctos (puertos invalidos y combinaciones peligrosas rechazados)"
fi
allowed_missing=""
while IFS= read -r key; do
  grep -Eq "(^| )${key}( |$)" <<<"$(sed -n '/^readonly ENV_ALLOWED_KEYS=(/,/^)/p' scripts/common.sh)" || allowed_missing="$allowed_missing $key"
done < <(sed -n 's/^#\{0,1\} \{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\1/p' .env.example | sort -u)
if [[ -z $allowed_missing ]]; then pass "Toda clave de .env.example esta en la lista permitida de common.sh"; else nope "Claves de .env.example fuera de ENV_ALLOWED_KEYS:$allowed_missing"; fi
if grep -nE '(^|[;&[:space:]])(source|\.)[[:space:]]+[^[:space:]]*\.env([[:space:]]|$|")' scripts/*.sh | grep -v 'env.example' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >/dev/null; then
  nope "Algun script ejecuta .env con 'source'"
else
  pass "Ningun script usa 'source .env' (parser estricto con lista de claves)"
fi

# ---------------------------------------------------------------- 9d. scripts de Windows
group "Scripts de Windows (analisis de contenido)"
for f in "${PS_FILES[@]}"; do
  if grep -qiE 'StrictHostKeyChecking[[:space:]=]+(no|off|accept-new)|UserKnownHostsFile[[:space:]=]+(/dev/null|NUL)' "$f"; then nope "$f desactiva la verificacion de huellas SSH"; else pass "$f no desactiva la verificacion de huellas SSH"; fi
  if grep -qiE '(password|passwd|contrasena)[[:space:]]*=[[:space:]]*["'\''][^"'\'']+["'\'']' "$f"; then nope "$f parece contener una contrasena escrita"; else pass "$f sin contrasenas escritas"; fi
  if grep -q '#requires -version [6-9]' "$f"; then nope "$f exige PowerShell 6+ (debe funcionar en Windows PowerShell 5.1)"; else pass "$f no exige PowerShell 6 o superior"; fi
done
check_text "setup-git.ps1 usa el puerto de Tailscale Serve por defecto 2222" '\$SshPort = 2222' windows/setup-git.ps1
check_text "setup-git.ps1 genera claves Ed25519" 'ssh-keygen -t ed25519' windows/setup-git.ps1
check_text "setup-git.ps1 usa IdentitiesOnly" 'IdentitiesOnly yes' windows/setup-git.ps1
check_text "upload-project.ps1 excluye .env, .git, bases de datos, respaldos y claves" 'excludeName' windows/upload-project.ps1
for item in '\.git' '\.db' 'tar\.gz' 'pem' 'id_'; do
  if grep -E 'excludeName|excludeDir' windows/upload-project.ps1 | grep -qF -- "$item"; then pass "upload-project.ps1 excluye $item"; else nope "upload-project.ps1 no excluye $item"; fi
done

# ---------------------------------------------------------------- 10. documentacion
group "Documentacion"
for f in docs/*.md README.md ENTREGA.md; do
  [[ -s $f ]] || continue
  if grep -q $'\r' "$f"; then nope "$f tiene CRLF"; fi
done
for heading in 'Fase 1' 'Fase 2' 'Fase 3' 'Fase 4' 'Fase 5' 'Fase 6' 'Fase 7' 'Fase 8' 'Fase 9' 'Fase 10' 'Fase 11' 'Fase 12'; do
  if grep -Eq "^#+ .*${heading}( |:|$)" docs/INSTALACION-MANANA.md 2>/dev/null; then pass "INSTALACION-MANANA.md incluye '$heading'"; else nope "INSTALACION-MANANA.md no incluye '$heading'"; fi
done
for q in 'D(o|ó)nde ejecutar' 'Resultado esperado' 'Si falla' 'Qu(e|é) modifica'; do
  n=$(grep -c -i -E -- "$q" docs/INSTALACION-MANANA.md 2>/dev/null || true)
  if [[ ${n:-0} -ge 12 ]]; then pass "INSTALACION-MANANA.md: cada fase indica '$q' ($n apariciones)"; else nope "INSTALACION-MANANA.md: '$q' aparece ${n:-0} veces (se esperaban al menos 12, una por fase)"; fi
done
for section_name in 'Descripci(o|ó)n' 'Caracter(i|í)sticas' 'Requisitos' 'Arquitectura' 'Preparaci(o|ó)n' 'Instalaci(o|ó)n' 'Uso cotidiano' 'Seguridad' 'Backups' 'Soluci(o|ó)n de errores'; do
  if grep -Eqi "^#+ .*${section_name}" README.md 2>/dev/null; then pass "README incluye '$section_name'"; else nope "README no incluye '$section_name'"; fi
done

group "Seguridad del procedimiento de restauracion de prueba"
if grep -q "GITEA_SSH_LOCAL_PORT=2322" docs/BACKUPS.md && grep -q "GITEA_SSH_PORT=2322" docs/BACKUPS.md; then pass "Restauracion de prueba cambia SSH local y SSH anunciado"; else nope "Restauracion de prueba no separa los puertos SSH"; fi
if grep -q "GITEA_SSH_LOCAL_PORT=.*2222" docs/BACKUPS.md; then nope "Restauracion de prueba reutiliza SSH local productivo 2222"; else pass "Restauracion de prueba no fija SSH local en 2222"; fi
for token in 'GITEA_WEB_PORT=3190' 'GITEA_BACKUP_DIR=/srv/backups/gitea-prueba' 'GITEA_INSTALL_DIR=/srv/gitea-prueba' 'gitea-prueba' 'ss -ltn' '127.0.0.1:3190'; do
  if grep -Fq "$token" docs/BACKUPS.md; then pass "Procedimiento aislado documenta $token"; else nope "Procedimiento aislado omite $token"; fi
done
if grep -Fq 'GITEA__server__ROOT_URL: http://127.0.0.1:3190/' docs/BACKUPS.md; then pass "Restauracion de prueba usa URL local, no la URL productiva"; else nope "Restauracion de prueba conserva la URL publica productiva"; fi
for doc in ENTREGA.md docs/SEGURIDAD.md docs/BACKUPS.md docs/COMANDOS-GIT.md; do
  if grep -Fq 'data/data/ssh' "$doc"; then pass "$doc usa la ruta rootless data/data/ssh"; else nope "$doc no documenta data/data/ssh"; fi
done
bad_entrega_ssh=$(grep -nE '(^|[[:space:]])data/ssh/\*\.pub|`data/ssh/\*\.pub|/srv/gitea-privado/data/ssh/' ENTREGA.md || true)
if grep -Fq 'data/data/ssh/*.pub' ENTREGA.md && [[ -z $bad_entrega_ssh ]]; then pass "ENTREGA documenta la ruta rootless exacta de claves SSH"; else nope "ENTREGA contiene una referencia SSH obsoleta: $bad_entrega_ssh"; fi
if grep -Fq 'scripts/x.sh' docs/SOLUCION-PROBLEMAS.md; then nope "SOLUCION-PROBLEMAS cita un script inexistente"; else pass "SOLUCION-PROBLEMAS cita scripts reales"; fi
group "Coherencia entre documentos, scripts y configuracion"
DOC_FILES=(README.md ENTREGA.md REVISION-SEGURIDAD.md docs/*.md)
# 1. Todo script o archivo citado en la documentacion existe.
missing_refs=""
while IFS= read -r ref; do
  [[ -e $ref ]] || missing_refs="$missing_refs $ref"
done < <(grep -hoE '(scripts/[A-Za-z0-9_-]+\.(sh|py)|windows/[A-Za-z0-9_-]+\.ps1|tests/[A-Za-z0-9_-]+\.sh)' "${DOC_FILES[@]}" | sort -u)
if [[ -z $missing_refs ]]; then pass "Todos los scripts citados en la documentacion existen"; else nope "La documentacion cita archivos inexistentes:$missing_refs"; fi
# 2. Toda opcion --xxx citada junto a un script de este proyecto existe en ese script.
bad_flags=""
while IFS=$'\t' read -r script flag; do
  [[ -f $script ]] || continue
  grep -q -- "$flag" "$script" || bad_flags="$bad_flags $script:$flag"
done < <(grep -hoE '(scripts/[A-Za-z0-9_-]+\.sh|windows/[A-Za-z0-9_-]+\.ps1)[^|`]*' "${DOC_FILES[@]}" | awk '{ s = $1; for (i = 2; i <= NF; i++) if ($i ~ /^--[a-z][a-z-]+$/) print s "\t" $i }' | sort -u)
if [[ -z $bad_flags ]]; then pass "Toda opcion --xxx documentada junto a un script existe en ese script"; else nope "Opciones documentadas que el script no define:$bad_flags"; fi
# 3. Variables de .env.example mencionadas en la documentacion principal.
undoc=""
for key in GITEA_WEB_PORT GITEA_SSH_LOCAL_PORT GITEA_SSH_PORT GITEA_TS_HTTPS_PORT; do
  grep -q "$key" README.md docs/ARQUITECTURA.md docs/INSTALACION-MANANA.md || undoc="$undoc $key"
done
if [[ -z $undoc ]]; then pass "Los cuatro puertos (web, SSH local, SSH tailnet, HTTPS) estan documentados"; else nope "Variables de puerto sin documentar:$undoc"; fi
# 4. La arquitectura anterior no debe quedar descrita como vigente.
stale=$(grep -nE 'GITEA_TAILSCALE_IP|publicad[oa] (solo )?en la IP de Tailscale|IP de Tailscale \(100' "${DOC_FILES[@]}" 2>/dev/null | grep -viE 'obsolet|anterior|heredad|migraci|ya no|antiguo|antes' || true)
if [[ -z $stale ]]; then pass "La documentacion no describe como vigente el SSH publicado en la IP de Tailscale"; else nope "Texto desactualizado:"; printf '%s\n' "$stale" | head -n 5; fi
wrong_keys=$(grep -nE 'data/ssh/' "${DOC_FILES[@]}" scripts/*.sh windows/*.ps1 2>/dev/null | grep -v 'data/data/ssh' || true)
if [[ -z $wrong_keys ]]; then pass "Las rutas de claves SSH del servidor usan data/data/ssh (ruta real de la imagen rootless)"; else nope "Ruta de claves SSH incorrecta:"; printf '%s\n' "$wrong_keys" | head -n 5; fi
for term in 'Funnel' 'ACL' 'huella' '2FA' 'SHA-256' 'cifrad'; do
  if grep -qi -- "$term" docs/SEGURIDAD.md docs/BACKUPS.md; then pass "SEGURIDAD/BACKUPS tratan '$term'"; else nope "SEGURIDAD/BACKUPS no mencionan '$term'"; fi
done
if grep -qiE 'mismo disco' docs/BACKUPS.md; then pass "BACKUPS advierte que un respaldo en el mismo disco no protege ante dano fisico"; else nope "BACKUPS no advierte sobre el mismo disco"; fi
if grep -qE '^\| *Riesgo' REVISION-SEGURIDAD.md; then pass "REVISION-SEGURIDAD.md contiene la tabla de riesgos"; else nope "REVISION-SEGURIDAD.md sin tabla de riesgos"; fi
if grep -qiE 'no (se )?(ha |fue )?(probado|ejecutado|verificado).*(ubuntu|servidor)|pendiente.*(ubuntu|servidor)' ENTREGA.md; then pass "ENTREGA.md declara que nada se probo aun en el servidor Ubuntu"; else nope "ENTREGA.md no aclara que falta probar en el servidor Ubuntu"; fi

# ---------------------------------------------------------------- resumen
group "Resumen"
printf 'Pasan: %s | Fallan: %s | Omitidas: %s\n' "$PASS" "$FAIL" "$SKIP"
if (( SKIP > 0 )); then
  echo "Las comprobaciones OMITIDAS dependen de herramientas ausentes en este equipo; ejecute de nuevo donde existan."
fi
if (( FAIL > 0 )); then
  exit 1
fi
echo "Pruebas estaticas completadas sin fallos."
