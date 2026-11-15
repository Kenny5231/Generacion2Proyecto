<#
.SYNOPSIS
    Configura Git y SSH en Windows para usar el Gitea privado (clave Ed25519 propia + alias SSH).

.DESCRIPTION
    - Verifica Git y OpenSSH.
    - Crea una clave Ed25519 exclusiva para Gitea SOLO si no existe (nunca sobrescribe claves).
      La frase de contrasena la pide ssh-keygen directamente: este script no la lee ni la guarda.
    - Muestra la clave PUBLICA (nunca la privada) y explica donde registrarla.
    - Crea o actualiza un bloque delimitado en ~/.ssh/config sin tocar el resto del archivo
      (antes guarda una copia de seguridad).
    - Opcionalmente prueba la conexion. La huella del servidor la verifica usted: no se desactiva
      ninguna comprobacion de host SSH.

.PARAMETER ServerName
    Nombre DNS de Tailscale del servidor (termina en .ts.net). Se pregunta si se omite.

.PARAMETER SshPort
    Puerto SSH de Git que Tailscale Serve ofrece en la tailnet (GITEA_SSH_PORT del servidor; por defecto 2222).
    No es el SSH de administracion de Ubuntu ni el puerto local de Docker.

.PARAMETER Alias
    Alias de Host en ~/.ssh/config (por defecto git-privado).

.PARAMETER KeyName
    Nombre del archivo de clave en ~/.ssh (por defecto id_ed25519_gitea_privado).

.PARAMETER ExpectedFingerprint
    Huella SHA256:... de la clave Ed25519 del servidor Git, obtenida POR SEPARADO en el servidor
    (scripts/status.sh). Si se indica, el script consulta la huella anunciada con ssh-keyscan y solo
    la agrega a known_hosts si COINCIDE. Si no se indica, SSH le pedira confirmar la huella a mano.
    Nunca se desactiva StrictHostKeyChecking.

.PARAMETER SkipTest
    No ofrece probar la conexion al final.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\windows\setup-git.ps1 -ServerName miservidor.mi-tailnet.ts.net -SshPort 2222
#>
[CmdletBinding()]
param(
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$SshPort = 2222,
    [string]$Alias = 'git-privado',
    [string]$KeyName = 'id_ed25519_gitea_privado',
    [string]$ExpectedFingerprint,
    [switch]$SkipTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m) { Write-Host "[ADVERTENCIA] $m" -ForegroundColor Yellow }
function Stop-Script($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

function Test-TsDns([string]$name) {
    if ($name -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\.ts\.net$') { return $false }
    if ($name -match '(example|ejemplo|nombre-tailnet|tu-tailnet|your-|tailnet-name|servidor\.nombre|mi-tailnet)') { return $false }
    return $true
}

Write-Host ''
Write-Host '== Configuracion de Git y SSH para Gitea privado ==' -ForegroundColor White

# --- 1. Herramientas ---
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { Stop-Script 'Git no esta instalado. Instalelo desde https://git-scm.com/download/win y repita.' }
Write-Ok ("Git encontrado: " + (& git --version))

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
$sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $ssh -or -not $sshKeygen) {
    Stop-Script 'OpenSSH Client no esta disponible. Activelo en Configuracion > Aplicaciones > Caracteristicas opcionales > Cliente OpenSSH.'
}
Write-Ok ("OpenSSH encontrado: " + $ssh.Source)

$gitName = (& git config --global user.name) 2>$null
$gitMail = (& git config --global user.email) 2>$null
if (-not $gitName -or -not $gitMail) {
    Write-Warn 'Git no tiene user.name / user.email globales. Configurelos con:'
    Write-Host '    git config --global user.name  "Su Nombre"'
    Write-Host '    git config --global user.email "su-correo@dominio"'
}

# --- 2. Datos del servidor ---
if ($Alias -notmatch '^[A-Za-z0-9._-]+$') { Stop-Script "Alias invalido: $Alias" }
if ($KeyName -notmatch '^[A-Za-z0-9._-]+$') { Stop-Script "Nombre de clave invalido: $KeyName" }
if (-not $ServerName) { $ServerName = Read-Host 'Nombre DNS de Tailscale del servidor (termina en .ts.net)' }
$ServerName = $ServerName.Trim().TrimEnd('.').ToLowerInvariant()
if (-not (Test-TsDns $ServerName)) {
    Stop-Script "El nombre '$ServerName' no es un nombre .ts.net valido o parece un ejemplo. Obtengalo en el servidor con: tailscale status --json (campo Self.DNSName)."
}
Write-Ok "Servidor: $ServerName (puerto SSH de Git: $SshPort, alias: $Alias)"

# --- 3. Clave Ed25519 ---
$sshDir = Join-Path $HOME '.ssh'
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
$existing = @(Get-ChildItem -Path $sshDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^id_' -and $_.Extension -ne '.pub' })
if ($existing.Count -gt 0) {
    Write-Info ('Claves SSH existentes (no se modifican): ' + (($existing | ForEach-Object { $_.Name }) -join ', '))
} else {
    Write-Info 'No se encontraron claves SSH previas.'
}

$keyPath = Join-Path $sshDir $KeyName
$pubPath = "$keyPath.pub"
if (Test-Path $keyPath) {
    Write-Ok "La clave $KeyName ya existe: no se sobrescribe."
    if (-not (Test-Path $pubPath)) {
        Write-Info 'Falta el archivo .pub; se regenera desde la clave privada (puede pedir su frase de contrasena).'
        $pubText = (& ssh-keygen -y -f $keyPath)
        if ($LASTEXITCODE -ne 0) { Stop-Script 'No se pudo derivar la clave publica.' }
        [IO.File]::WriteAllText($pubPath, ($pubText + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
} else {
    Write-Info 'Se creara una clave Ed25519 nueva. Cuando ssh-keygen lo pida, escriba una frase de contrasena (recomendado).'
    & ssh-keygen -t ed25519 -a 100 -C "gitea-privado-$env:COMPUTERNAME" -f $keyPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pubPath)) { Stop-Script 'ssh-keygen no pudo crear la clave.' }
    Write-Ok "Clave creada: $keyPath (privada, no la comparta) y $pubPath (publica)."
}

# --- 4. Clave publica ---
Write-Host ''
Write-Host '== Clave PUBLICA (es seguro copiarla y pegarla en Gitea) ==' -ForegroundColor White
$pubKey = (Get-Content -Path $pubPath -Raw).Trim()
Write-Host $pubKey
try { Set-Clipboard -Value $pubKey; Write-Ok 'La clave publica se copio al portapapeles.' } catch { Write-Info 'No se pudo usar el portapapeles; copie el texto anterior.' }
Write-Host ''
Write-Host 'Donde registrarla en Gitea:'
Write-Host '  1. Abra la URL privada de Gitea e inicie sesion.'
Write-Host '  2. Avatar (arriba a la derecha) > Configuracion > Claves SSH / GPG > Agregar clave.'
Write-Host '  3. Pegue la clave publica, ponga un titulo (p. ej. "Mi PC Windows") y guarde.'

# --- 5. Bloque en ~/.ssh/config ---
$configPath = Join-Path $sshDir 'config'
$beginMark = '# BEGIN gitea-privado (administrado por setup-git.ps1)'
$endMark = '# END gitea-privado'
$identity = ($keyPath -replace '\\', '/')
$block = @(
    $beginMark,
    "Host $Alias",
    "    HostName $ServerName",
    "    Port $SshPort",
    '    User git',
    "    IdentityFile `"$identity`"",
    '    IdentitiesOnly yes',
    $endMark
) -join "`n"

$current = ''
if (Test-Path $configPath) { $current = [IO.File]::ReadAllText($configPath) }
$pattern = '(?s)' + [regex]::Escape($beginMark) + '.*?' + [regex]::Escape($endMark) + '\r?\n?'
$withoutBlock = [regex]::Replace($current, $pattern, '')
$escapedAlias = [regex]::Escape($Alias)
if ($withoutBlock -match "(?im)^\s*Host\s+(.*\s)?$escapedAlias(\s|$)") {
    Stop-Script "El alias '$Alias' ya esta definido fuera del bloque administrado en $configPath. Elija otro con -Alias o eliminelo manualmente."
}
if (Test-Path $configPath) {
    $backup = "$configPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -Path $configPath -Destination $backup
    Write-Info "Copia de seguridad de la configuracion SSH: $backup"
}
$newText = $withoutBlock.TrimEnd()
if ($newText.Length -gt 0) { $newText += "`n`n" }
$newText += $block + "`n"
[IO.File]::WriteAllText($configPath, $newText, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "Entrada '$Alias' escrita en $configPath (el resto del archivo no se modifico)."

# --- 6. Huella del servidor y prueba ---
Write-Host ''
Write-Host '== Verificar la huella del servidor SSH antes de aceptarla ==' -ForegroundColor White
Write-Host 'La huella Ed25519 REAL se obtiene en el servidor Ubuntu (por su SSH de administracion), no por este mismo canal:'
Write-Host '    cd /srv/gitea-privado; ./scripts/status.sh      (seccion "Huellas SSH del servidor Git")'
Write-Host '    sudo sh -c ''for f in /srv/gitea-privado/data/data/ssh/*.pub; do ssh-keygen -lf $f; done'''
Write-Host "Desde esta PC puede ver la que anuncia el servidor: ssh-keyscan -p $SshPort -t ed25519 $ServerName | ssh-keygen -lf -"
if ($ExpectedFingerprint) {
    if ($ExpectedFingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}$') { Stop-Script "La huella debe tener el formato SHA256:<43 caracteres base64> (la que muestra ssh-keygen -lf)." }
    $scanFile = Join-Path ([IO.Path]::GetTempPath()) ('gitea-hostkey-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $scan = @(& ssh-keyscan -p $SshPort -t ed25519 $ServerName 2>$null | Where-Object { $_ -and $_ -notmatch '^#' })
        if ($scan.Count -lt 1) { Stop-Script "No se pudo obtener la huella de ${ServerName}:$SshPort (Tailscale conectado? Serve del SSH configurado?)." }
        [IO.File]::WriteAllText($scanFile, (($scan -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $seen = (& ssh-keygen -lf $scanFile | Out-String)
        if ($seen -notmatch [regex]::Escape($ExpectedFingerprint)) {
            Stop-Script "La huella anunciada por el servidor NO coincide con la esperada. NO se agrega a known_hosts. Vista: $($seen.Trim())"
        }
        $knownHosts = Join-Path $sshDir 'known_hosts'
        $knownText = ''
        if (Test-Path $knownHosts) { $knownText = [IO.File]::ReadAllText($knownHosts) }
        $hostToken = "[$ServerName]:$SshPort"
        if ($SshPort -eq 22) { $hostToken = $ServerName }
        if ($knownText -match ('(?m)^' + [regex]::Escape($hostToken) + '\s')) {
            Write-Info "known_hosts ya contiene una entrada para $hostToken (no se modifica)."
        } else {
            [IO.File]::AppendAllText($knownHosts, (($scan -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok "Huella verificada y agregada a known_hosts para $hostToken."
        }
    } finally {
        if (Test-Path $scanFile) { Remove-Item -Path $scanFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host 'En la primera conexion SSH le mostrara una huella SHA256:...; acepte ("yes") SOLO si coincide con la del servidor.'
    Write-Host 'Para verificarla automaticamente: vuelva a ejecutar este script con -ExpectedFingerprint "SHA256:...".'
}

if (-not $SkipTest) {
    Write-Host ''
    $answer = Read-Host 'Ya registro la clave publica en Gitea y el servidor esta accesible? Probar la conexion ahora (s/N)'
    if ($answer -match '^(s|si|y|yes)$') {
        Write-Info "Ejecutando: ssh -T $Alias"
        & ssh -T $Alias
        if ($LASTEXITCODE -eq 255) {
            Write-Warn 'La conexion o la autenticacion fallo. Revise docs/SOLUCION-PROBLEMAS.md (seccion SSH).'
        } else {
            Write-Ok 'Conexion SSH establecida. Si vio "successfully authenticated", todo esta listo.'
        }
    } else {
        Write-Info "Pruebe mas tarde con:  ssh -T $Alias"
    }
}

Write-Host ''
Write-Host "Clonar un repositorio:  git clone ssh://git@${ServerName}:${SshPort}/<usuario>/<repositorio>.git"
Write-Host "Con el alias:           git clone ${Alias}:<usuario>/<repositorio>.git   (el alias ya incluye puerto, usuario y clave)"
