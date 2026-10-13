<#
.SYNOPSIS
Copies recordings from SFTPGo (REST API) to a local folder.

.DESCRIPTION
Walks SFTPGO_REMOTE_DIR recursively and downloads every file into RECORDINGS_DEST_DIR,
keeping the directory layout.
Before copying, it asks the EPGStation API whether a recording is in progress and
aborts without copying if so (or if the API cannot be reached). Files that already exist with the same name and size are
skipped, so it is safe to re-run. Each file is written to "<name>.part" and renamed when
complete. The remote side is only read, never modified.

Settings come from environment variables. If .env.ps1 exists in the repository root
(git-ignored; see .env.ps1.example) it is loaded first.

  SFTPGO_BASE_URL      required  e.g. http://192.168.10.55:8080
  SFTPGO_USER          required
  SFTPGO_PASSWORD      required
  RECORDINGS_DEST_DIR  required  local destination folder
  EPGSTATION_BASE_URL  required  e.g. http://192.168.10.55:8888 (not needed with -SkipRecordingCheck)
  SFTPGO_REMOTE_DIR    optional  source folder on SFTPGo (default /data)

.PARAMETER SkipRecordingCheck
Copy without checking EPGStation for an active recording.

Exit code: 0 on success, 1 on a configuration/authentication error, an active recording
or any failed file.
#>
[CmdletBinding()]
param([switch]$SkipRecordingCheck)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar on Windows PowerShell 5.1

$envFile = Join-Path $PSScriptRoot '..\.env.ps1'
if (Test-Path -LiteralPath $envFile) { . $envFile }

$required = @('SFTPGO_BASE_URL', 'SFTPGO_USER', 'SFTPGO_PASSWORD', 'RECORDINGS_DEST_DIR')
if (-not $SkipRecordingCheck) { $required += 'EPGSTATION_BASE_URL' }
$missing = $required |
    Where-Object { -not [Environment]::GetEnvironmentVariable($_) }
if ($missing) {
    Write-Error "Missing environment variables: $($missing -join ', ') (see .env.ps1.example)" -ErrorAction Continue
    exit 1
}

$baseUrl = $env:SFTPGO_BASE_URL.TrimEnd('/')
$remoteRoot = if ($env:SFTPGO_REMOTE_DIR) { $env:SFTPGO_REMOTE_DIR } else { '/data' }
$remoteRoot = '/' + $remoteRoot.Trim('/')
$destRoot = $env:RECORDINGS_DEST_DIR

# The token is valid for 20 minutes, so renew it well before that.
$script:token = $null
$script:tokenTime = [datetime]::MinValue
function Get-AuthHeader {
    if (((Get-Date) - $script:tokenTime).TotalMinutes -gt 10) {
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:SFTPGO_USER):$($env:SFTPGO_PASSWORD)"))
        try {
            $res = Invoke-RestMethod -Uri "$baseUrl/api/v2/user/token" -Headers @{ Authorization = "Basic $basic" }
        } catch {
            throw "Authentication failed (check SFTPGO_BASE_URL, SFTPGO_USER and SFTPGO_PASSWORD): $($_.Exception.Message)"
        }
        $script:token = $res.access_token
        $script:tokenTime = Get-Date
    }
    return @{ Authorization = "Bearer $script:token" }
}

function Get-RemoteEntries([string]$path) {
    $uri = "$baseUrl/api/v2/user/dirs?path=$([uri]::EscapeDataString($path))"
    $entries = Invoke-RestMethod -Uri $uri -Headers (Get-AuthHeader)
    return @($entries)  # not @(Invoke-RestMethod ...): Windows PowerShell 5.1 would nest the array
}

$script:copied = 0
$script:skipped = 0
$script:failed = 0

function Copy-Directory([string]$remote, [string]$local) {
    foreach ($entry in Get-RemoteEntries $remote) {
        $name = [string]$entry.name
        # Never let a remote name escape the destination folder.
        if (-not $name -or $name -eq '.' -or $name -eq '..' -or $name -match '[\/:*?"<>|]') {
            Write-Warning "Skipping unsafe name: $remote/$name"
            $script:failed++
            continue
        }
        $remotePath = "$remote/$name"
        $localPath = Join-Path $local $name

        if (([int64]$entry.mode -band 2147483648) -ne 0) {  # os.ModeDir
            try {
                New-Item -ItemType Directory -Force -Path $localPath | Out-Null
                Copy-Directory $remotePath $localPath
            } catch {
                Write-Warning "Failed: $remotePath : $($_.Exception.Message)"
                $script:failed++
            }
            continue
        }

        if ((Test-Path -LiteralPath $localPath -PathType Leaf) -and (Get-Item -LiteralPath $localPath).Length -eq [int64]$entry.size) {
            $script:skipped++
            continue
        }

        $part = "$localPath.part"
        try {
            Write-Host "Copying $remotePath"
            $uri = "$baseUrl/api/v2/user/files?path=$([uri]::EscapeDataString($remotePath))"
            Invoke-WebRequest -Uri $uri -Headers (Get-AuthHeader) -OutFile $part | Out-Null
            if ((Get-Item -LiteralPath $part).Length -ne [int64]$entry.size) {
                throw "size mismatch (expected $($entry.size) bytes)"
            }
            Move-Item -LiteralPath $part -Destination $localPath -Force
            $script:copied++
        } catch {
            Write-Warning "Failed: $remotePath : $($_.Exception.Message)"
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            $script:failed++
        }
    }
}

if (-not $SkipRecordingCheck) {
    try {
        $uri = "$($env:EPGSTATION_BASE_URL.TrimEnd('/'))/api/recording?isHalfWidth=true&offset=0&limit=100"
        $recording = Invoke-RestMethod -Uri $uri
    } catch {
        Write-Error "Could not check EPGStation for active recordings (check EPGSTATION_BASE_URL): $($_.Exception.Message)" -ErrorAction Continue
        exit 1
    }
    if ([int]$recording.total -gt 0) {
        Write-Warning "EPGStation is recording ($($recording.total)); nothing was copied:"
        foreach ($r in @($recording.records)) { Write-Warning "  $($r.name)" }
        exit 1
    }
    Write-Host 'No recording in progress.'
}

try {
    New-Item -ItemType Directory -Force -Path $destRoot | Out-Null
    Copy-Directory $remoteRoot $destRoot
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

Write-Host "Done: copied $script:copied, skipped $script:skipped, failed $script:failed"
if ($script:failed -gt 0) { exit 1 }
