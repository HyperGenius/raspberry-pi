<#
.SYNOPSIS
Installs Grafana Alloy on Windows and sends the Copy-Recordings.ps1 log and metrics to Grafana Cloud.

.DESCRIPTION
Run from an elevated PowerShell. Safe to re-run: it rewrites the configuration and restarts the service.

  1. Writes <data dir>\alloy\config.alloy (from windows\alloy\config.alloy.tmpl) and
     <data dir>\alloy\grafana-cloud-token. The folder is readable only by SYSTEM and Administrators.
  2. If the "Alloy" service does not exist, downloads the pinned installer from GitHub, checks its SHA-256
     against the release's SHA256SUMS, and installs it silently (service runs as LocalSystem).
  3. Validates the configuration, restarts the service, and checks that samples reach Grafana Cloud.

Settings come from environment variables. If .env.ps1 exists in the repository root
(git-ignored; see .env.ps1.example) it is loaded first.

  GRAFANA_CLOUD_PROMETHEUS_URL       required  Remote Write Endpoint, https://.../api/prom/push
  GRAFANA_CLOUD_PROMETHEUS_USERNAME  required  Prometheus Username / Instance ID (numbers)
  GRAFANA_CLOUD_LOKI_URL             required  https://logs-prod-....grafana.net/loki/api/v1/push
  GRAFANA_CLOUD_LOKI_USERNAME        required  Loki Username / Instance ID (numbers)
  GRAFANA_CLOUD_TOKEN                required  Cloud access policy token with metrics:write and logs:write only
  COPY_RECORDINGS_DATA_DIR           optional  same as Copy-Recordings.ps1 (default %ProgramData%\CopyRecordings)

.PARAMETER AlloyVersion
Alloy version to install when it is not installed yet (default: the version the Raspberry Pi uses).
Upgrading an installed Alloy is not done here.
#>
[CmdletBinding()]
param(
    [string]$AlloyVersion = '1.20.1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Fail([string]$message) {
    Write-Error $message -ErrorAction Continue
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail 'Run this script from an elevated (Administrator) PowerShell.' }

$envFile = Join-Path $PSScriptRoot '..\.env.ps1'
if (Test-Path -LiteralPath $envFile) { . $envFile }

$required = @('GRAFANA_CLOUD_PROMETHEUS_URL', 'GRAFANA_CLOUD_PROMETHEUS_USERNAME', 'GRAFANA_CLOUD_LOKI_URL', 'GRAFANA_CLOUD_LOKI_USERNAME', 'GRAFANA_CLOUD_TOKEN')
$missing = $required | Where-Object { -not [Environment]::GetEnvironmentVariable($_) }
if ($missing) { Fail "Missing environment variables: $($missing -join ', ') (see .env.ps1.example)" }

$utf8 = New-Object System.Text.UTF8Encoding $false
$dataDir = if ($env:COPY_RECORDINGS_DATA_DIR) { $env:COPY_RECORDINGS_DATA_DIR } else { Join-Path $env:ProgramData 'CopyRecordings' }
$dataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dataDir)
$alloyDir = Join-Path $dataDir 'alloy'
$configFile = Join-Path $alloyDir 'config.alloy'
$tokenFile = Join-Path $alloyDir 'grafana-cloud-token'

# ---- 1. configuration and token ----
foreach ($d in $dataDir, (Join-Path $dataDir 'logs'), (Join-Path $dataDir 'metrics'), $alloyDir) {
    [IO.Directory]::CreateDirectory($d) | Out-Null
}
# Only SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544); SIDs work on any display language.
& icacls.exe $alloyDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "icacls failed on $alloyDir" }

[IO.File]::WriteAllText($tokenFile, $env:GRAFANA_CLOUD_TOKEN, $utf8)

# Alloy strings treat \ as an escape, so use forward slashes. Reject characters that would break out of a string.
$values = @{
    DATA_DIR            = $dataDir.Replace('\', '/')
    TOKEN_FILE          = $tokenFile.Replace('\', '/')
    PROMETHEUS_URL      = $env:GRAFANA_CLOUD_PROMETHEUS_URL
    PROMETHEUS_USERNAME = $env:GRAFANA_CLOUD_PROMETHEUS_USERNAME
    LOKI_URL            = $env:GRAFANA_CLOUD_LOKI_URL
    LOKI_USERNAME       = $env:GRAFANA_CLOUD_LOKI_USERNAME
}
$config = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\windows\alloy\config.alloy.tmpl'))
foreach ($k in $values.Keys) {
    if ($values[$k] -match '["\\\r\n]') { Fail "$k contains a character that is not allowed (`" \ or a line break)" }
    $config = $config.Replace("@@$k@@", $values[$k])
}
if ($config -match '@@[A-Z_]+@@') { Fail "Unreplaced placeholder in the template: $($Matches[0])" }
[IO.File]::WriteAllText($configFile, $config, $utf8)
Write-Host "Wrote $configFile and $tokenFile"

# ---- 2. install ----
if (-not (Get-Service -Name Alloy -ErrorAction SilentlyContinue)) {
    $work = Join-Path ([IO.Path]::GetTempPath()) ('alloy-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    try {
        $baseUrl = "https://github.com/grafana/alloy/releases/download/v$AlloyVersion"
        $zipName = 'alloy-installer-windows-amd64.exe.zip'
        $zip = Join-Path $work $zipName
        Write-Host "Downloading Alloy $AlloyVersion"
        Invoke-WebRequest -Uri "$baseUrl/$zipName" -OutFile $zip -UseBasicParsing
        # Decode the bytes ourselves: for a file served as application/octet-stream, .Content is a byte[] on Windows PowerShell 5.1.
        $sums = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest -Uri "$baseUrl/SHA256SUMS" -UseBasicParsing).RawContentStream.ToArray())
        $expected = ($sums -split "`n" | Where-Object { $_ -match "\s$([regex]::Escape($zipName))\s*$" } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
        if (-not $expected) { Fail "No checksum for $zipName in SHA256SUMS" }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ne $expected.ToUpperInvariant()) { Fail "Checksum mismatch for ${zipName}: expected $expected, got $actual" }

        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
        $installer = Join-Path $work 'alloy-installer-windows-amd64.exe'
        Write-Host 'Installing Alloy (silent)'
        # Quoted so that the path survives spaces; /DISABLEREPORTING turns off the anonymous usage statistics (as on the Pi).
        $p = Start-Process -FilePath $installer -ArgumentList '/S', "/CONFIG=`"$configFile`"", '/DISABLEREPORTING=yes' -Wait -PassThru
        if ($p.ExitCode -ne 0) { Fail "The Alloy installer exited with $($p.ExitCode)" }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-Service -Name Alloy -ErrorAction SilentlyContinue)) { Fail 'The Alloy service was not created' }
}

# ---- 3. validate, restart, check ----
$alloyExe = Join-Path $env:ProgramFiles 'GrafanaLabs\Alloy\alloy-windows-amd64.exe'
if (Test-Path -LiteralPath $alloyExe) {
    & $alloyExe validate $configFile
    if ($LASTEXITCODE -ne 0) { Fail "alloy validate failed for $configFile" }
} else {
    Write-Warning "$alloyExe not found; skipping alloy validate"
}

Restart-Service -Name Alloy
Write-Host 'Waiting for Alloy to send samples to Grafana Cloud (up to 2 minutes)'
$sent = $false
for ($i = 0; $i -lt 24 -and -not $sent; $i++) {
    Start-Sleep -Seconds 5
    try {
        $m = (Invoke-WebRequest -Uri 'http://127.0.0.1:12345/metrics' -UseBasicParsing -TimeoutSec 5).Content
        $ok = [regex]::Match($m, '(?m)^prometheus_remote_storage_samples_total\{[^}]*\} ([0-9.e+]+)')
        $ng = [regex]::Match($m, '(?m)^prometheus_remote_storage_samples_failed_total\{[^}]*\} ([0-9.e+]+)')
        $total = if ($ok.Success) { [double]$ok.Groups[1].Value } else { 0 }
        $failed = if ($ng.Success) { [double]$ng.Groups[1].Value } else { 0 }
        if (($total - $failed) -gt 0) { $sent = $true }
    } catch { }  # not listening yet
}
if (-not $sent) {
    Fail 'No samples reached Grafana Cloud. Check GRAFANA_CLOUD_* (a wrong token or user gives 401), and Event Viewer > Application for "Alloy".'
}
Write-Host 'OK: Alloy is sending to Grafana Cloud.'
