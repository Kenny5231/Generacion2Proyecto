<#
.SYNOPSIS
    Transfiere el proyecto gitea-privado desde Windows a una carpeta de preparacion en el HOME
    del servidor Ubuntu usando SSH/SCP.

.DESCRIPTION
    - Pide host, usuario y puerto SSH de ADMINISTRACION del servidor (no es el puerto Git 2222).
    - Comprueba la conexion antes de copiar. La verificacion de huella SSH queda ACTIVA:
      la primera vez SSH le mostrara la huella para que la confirme manualmente.
    - Copia solo archivos de despliegue; excluye .git, .env*, respaldos, logs, bases de datos,
      datos y temporales. Normaliza los finales de linea a LF.
    - Escribe unicamente en ~/<RemoteDir> (por defecto gitea-privado-staging). No toca una
      instalacion existente en /srv/gitea-privado.

.PARAMETER ServerHost
    Nombre o IP del servidor para SSH de administracion.

.PARAMETER User
    Usuario SSH en el servidor.

.PARAMETER SshPort
    Puerto SSH de administracion (por defecto 22; pueden ser otro, NO asuma 2222).

.PARAMETER RemoteDir
    Carpeta de preparacion relativa al HOME remoto (por defecto gitea-privado-staging).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\windows\upload-project.ps1
#>
[CmdletBinding()]
param(
    [string]$ServerHost,
    [string]$User,
    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,
    [string]$RemoteDir = 'gitea-privado-staging'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[ADVERTENCIA] $m" -ForegroundColor Yellow }
function Stop-Script($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

foreach ($tool in 'ssh', 'scp') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Stop-Script "No se encontro '$tool'. Active el Cliente OpenSSH de Windows."
    }
}

if (-not $ServerHost) { $ServerHost = Read-Host 'Hostname o IP del servidor Ubuntu (SSH de administracion)' }
if (-not $User) { $User = Read-Host 'Usuario SSH del servidor' }
$ServerHost = $ServerHost.Trim()
$User = $User.Trim()
if ($ServerHost -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') { Stop-Script "Host invalido: '$ServerHost'" }
if ($User -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*$') { Stop-Script "Usuario invalido: '$User'" }
if ($RemoteDir -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$' -or $RemoteDir -match '\.\.') {
    Stop-Script "Carpeta remota invalida: '$RemoteDir' (use una ruta relativa simple, sin '..')."
}

$target = "$User@$ServerHost"
$projectRoot = Split-Path -Parent $PSScriptRoot
Write-Info "Proyecto: $projectRoot"
Write-Info "Destino:  ${target}:~/$RemoteDir (puerto SSH $SshPort)"

# --- Comprobar conexion (la huella del servidor se confirma manualmente) ---
Write-Info 'Comprobando la conexion SSH. Si es la primera vez, SSH mostrara la huella del servidor: comparela con la de Ubuntu (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub, ejecutado en el servidor) antes de escribir "yes".'
$probe = & ssh -p $SshPort -o ConnectTimeout=15 $target 'echo conexion-ok'
if ($LASTEXITCODE -ne 0 -or ($probe | Out-String).Trim() -ne 'conexion-ok') {
    Stop-Script 'No se pudo conectar por SSH. Verifique host, usuario y puerto de administracion (no es el puerto Git 2222).'
}
Write-Ok 'Conexion SSH verificada.'

# --- Estado remoto ---
$remoteState = (& ssh -p $SshPort $target "if [ -e /srv/gitea-privado/compose.yaml ]; then echo PROD_EXISTS; fi; if [ -e $RemoteDir ]; then echo STAGING_EXISTS; fi; echo fin") | Out-String
if ($remoteState -match 'PROD_EXISTS') {
    Write-Warn 'Ya existe una instalacion en /srv/gitea-privado. Este script NO la modifica; solo copia a la carpeta de preparacion. install.sh conservara .env, data y config.'
}
if ($remoteState -match 'STAGING_EXISTS') {
    Write-Warn "Ya existe ~/$RemoteDir. Se actualizaran los archivos del proyecto con el mismo nombre (no se borra nada)."
    $ans = Read-Host 'Continuar? (s/N)'
    if ($ans -notmatch '^(s|si|y|yes)$') { Stop-Script 'Cancelado por el usuario.' }
}

# --- Preparar copia limpia ---
$include = @('compose.yaml', '.env.example', '.gitignore', '.gitattributes', 'README.md', 'ENTREGA.md', 'REVISION-SEGURIDAD.md', 'scripts', 'windows', 'docs', 'tests')
$excludeName = '(^\.env$|^\.env\.(?!example$)|\.log$|\.db$|\.sqlite3?$|\.tar\.gz$|\.tgz$|\.zip$|\.sha256$|\.bak|\.pem$|\.key$|\.ppk$|\.p12$|\.pfx$|\.partial$|\.tmp$|\.swp$|^id_|^Thumbs\.db$)'
$excludeDir = '(^|[\\/])(\.git|data|config|backups|tmp|\.tools|\.vscode|__pycache__)([\\/]|$)'
$textExt = '\.(sh|py|yaml|yml|md|example)$|^\.gitignore$|^\.gitattributes$'

$stage = Join-Path ([IO.Path]::GetTempPath()) ('gitea-privado-upload-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $count = 0
    foreach ($item in $include) {
        $src = Join-Path $projectRoot $item
        if (-not (Test-Path $src)) { continue }
        $files = @()
        if ((Get-Item $src).PSIsContainer) { $files = @(Get-ChildItem -Path $src -Recurse -File -Force) } else { $files = @(Get-Item $src -Force) }
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($projectRoot.Length).TrimStart('\', '/')
            if ($rel -match $excludeDir -or $f.Name -match $excludeName) { continue }
            $dest = Join-Path $stage $rel
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            if ($f.Name -match $textExt) {
                $text = [IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n"
                [IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
            } else {
                Copy-Item -Path $f.FullName -Destination $dest
            }
            $count++
        }
    }
    if ($count -eq 0) { Stop-Script 'No se encontraron archivos para transferir.' }
    Write-Ok "$count archivos preparados (sin .env, .git, datos ni respaldos)."

    # --- Transferir ---
    & ssh -p $SshPort $target "mkdir -p -- $RemoteDir"
    if ($LASTEXITCODE -ne 0) { Stop-Script 'No se pudo crear la carpeta de preparacion remota.' }
    Push-Location $stage
    try {
        $names = @(Get-ChildItem -Force | ForEach-Object { $_.Name })
        $scpArgs = @('-P', "$SshPort", '-r') + $names + @("${target}:$RemoteDir/")
        & scp @scpArgs
        if ($LASTEXITCODE -ne 0) { Stop-Script 'scp fallo. Alternativa manual: comprima la carpeta y copiela con "scp -P <puerto> archivo usuario@host:".' }
    } finally {
        Pop-Location
    }
    $permissionCheck = "set -eu; chmod +x $RemoteDir/scripts/*.sh $RemoteDir/tests/*.sh || { rc=`$?; echo chmod-fallo-codigo-`$rc >&2; exit `$rc; }; for f in $RemoteDir/scripts/*.sh $RemoteDir/tests/*.sh; do test -x `$f || { echo permiso-ejecutable-faltante:`$f >&2; exit 1; }; done; for f in common preflight configure install configure-tailscale status backup restore update smoke-test; do test -x $RemoteDir/scripts/`$f.sh || { echo permiso-requerido-faltante:scripts/`$f.sh >&2; exit 1; }; done; for f in test-static test-lifecycle; do test -x $RemoteDir/tests/`$f.sh || { echo permiso-requerido-faltante:tests/`$f.sh >&2; exit 1; }; done; echo PERMISSIONS_OK"
    $permissionOutput = (& ssh -p $SshPort $target $permissionCheck 2>&1 | Out-String)
    $permissionExit = $LASTEXITCODE
    if ($permissionExit -ne 0 -or $permissionOutput -notmatch 'PERMISSIONS_OK') {
        Write-Warn 'Transfer completed, but executable permissions could not be restored or verified.'
        Write-Host "Salida remota: $permissionOutput" -ForegroundColor Yellow
        Write-Host "Ubuntu manual recovery: cd ~/$RemoteDir && chmod +x scripts/*.sh tests/*.sh && for f in scripts/*.sh tests/*.sh; do test -x `"`$f`" || exit 1; done" -ForegroundColor Yellow
        Write-Host 'Alternativa para ejecutar el preflight sin bit ejecutable: bash scripts/preflight.sh' -ForegroundColor Yellow
        Stop-Script 'Unix executable permission recovery was not confirmed.'
    }
    Write-Ok "Permisos ejecutables recuperados y verificados; transferencia completada a ~/$RemoteDir"
} finally {
    if (Test-Path $stage) { Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host 'Siguientes pasos en el servidor (Bash; docs/INSTALACION-MANANA.md, Fases 4 a 6):' -ForegroundColor White
Write-Host "    ssh -p $SshPort $target"
Write-Host "    cd ~/$RemoteDir"
Write-Host '    ./scripts/preflight.sh            # solo lectura'
Write-Host '    ./scripts/configure.sh            # genera .env (nada se publica todavia)'
Write-Host '    ./scripts/install.sh              # instala; Tailscale Serve se activa despues, en la Fase 8'
Write-Host 'Nota: este es el SSH de ADMINISTRACION de Ubuntu; el SSH propio de Gitea es otro servicio (puerto 2222 por defecto).'
