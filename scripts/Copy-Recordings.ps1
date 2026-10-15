<#
.SYNOPSIS
Copies recordings from SFTPGo (REST API) to a local folder.

.DESCRIPTION
Walks SFTPGO_REMOTE_DIR recursively and downloads every file into RECORDINGS_DEST_DIR,
keeping the directory layout.
Before copying, it asks the EPGStation API whether a recording is in progress and
aborts without copying if so (or if the API cannot be reached). Files that already exist with the same name and size are
skipped, so it is safe to re-run. Each file is written to a temporary ".download.part" in its folder and renamed when
complete. Without -DeleteAfterCopy the remote side is only read, never modified.
Files named ".sftpgo-upload.*" (uploads in progress) are ignored.

Settings come from environment variables. If .env.ps1 exists in the repository root
(git-ignored; see .env.ps1.example) it is loaded first.

  SFTPGO_BASE_URL      required  e.g. http://192.168.10.55:8080
  SFTPGO_USER          required
  SFTPGO_PASSWORD      required
  RECORDINGS_DEST_DIR  required  local destination folder
  EPGSTATION_BASE_URL  required  e.g. http://192.168.10.55:8888 (not needed with -SkipRecordingCheck)
  SFTPGO_REMOTE_DIR    optional  source folder on SFTPGo (default /data)

.PARAMETER SkipRecordingCheck
Copy without checking EPGStation for an active recording. Cannot be combined with -DeleteAfterCopy.

.PARAMETER DeleteAfterCopy
Delete each remote file once its local copy is complete (just copied, or already present with the same size).
EPGStation is checked again before every delete; if a recording has started or the API cannot be reached,
the remaining files are copied but not deleted. Directories are never deleted.
With -WhatIf nothing is copied or deleted; the files that would be are listed.

Exit code: 0 on success, 1 on a configuration/authentication error, an active recording,
any failed file, or deletes stopped by a recording.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipRecordingCheck,
    [switch]$DeleteAfterCopy
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is slow with the progress bar on Windows PowerShell 5.1

if ($DeleteAfterCopy -and $SkipRecordingCheck) {
    Write-Error '-DeleteAfterCopy cannot be combined with -SkipRecordingCheck (a file being recorded could be deleted)' -ErrorAction Continue
    exit 1
}

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
# Resolve now: the .NET calls below use the process directory, not PowerShell's current location.
$destRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:RECORDINGS_DEST_DIR)

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

# Streams a download to disk. Not Invoke-WebRequest -OutFile: it treats [ ] in recording names as wildcards.
Add-Type -AssemblyName System.Net.Http
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromHours(24)
function Save-RemoteFile([string]$uri, [string]$path) {
    Get-AuthHeader | Out-Null
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get), $uri
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue 'Bearer', $script:token
    $resp = $script:http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
        $resp.EnsureSuccessStatusCode() | Out-Null
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [IO.File]::Create($path)
        # Flush to disk: with -DeleteAfterCopy the remote file is gone once this returns.
        try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose(); $in.Dispose() }
    } finally {
        $resp.Dispose(); $req.Dispose()
    }
}

function Get-RemoteEntries([string]$path) {
    $uri = "$baseUrl/api/v2/user/dirs?path=$([uri]::EscapeDataString($path))"
    # Decode as UTF-8 ourselves: SFTPGo sends no charset, so Invoke-RestMethod on Windows PowerShell 5.1 reads it as ISO-8859-1.
    $res = Invoke-WebRequest -Uri $uri -Headers (Get-AuthHeader) -UseBasicParsing
    $entries = [Text.Encoding]::UTF8.GetString($res.RawContentStream.ToArray()) | ConvertFrom-Json
    if ($null -eq $entries) { return @() }  # empty directory
    return @($entries)  # not @(ConvertFrom-Json ...): Windows PowerShell 5.1 would nest the array
}

# Returns the active recordings. Throws if the EPGStation API cannot be reached.
function Get-ActiveRecordings {
    $uri = "$($env:EPGSTATION_BASE_URL.TrimEnd('/'))/api/recording?isHalfWidth=true&offset=0&limit=100"
    return Invoke-RestMethod -Uri $uri
}

$script:copied = 0
$script:skipped = 0
$script:deleted = 0
$script:failed = 0
$script:deleteStopped = $false

# Deletes a remote file whose local copy is complete, unless a recording has started since the last check.
function Remove-RemoteFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$remotePath)
    if ($script:deleteStopped -or -not $PSCmdlet.ShouldProcess($remotePath, 'Delete')) { return }
    try {
        $recording = Get-ActiveRecordings
    } catch {
        Write-Warning "Could not check EPGStation for active recordings; no more files will be deleted: $($_.Exception.Message)"
        $script:deleteStopped = $true
        return
    }
    if ([int]$recording.total -gt 0) {
        Write-Warning "EPGStation started recording ($($recording.total)); no more files will be deleted"
        $script:deleteStopped = $true
        return
    }
    try {
        $uri = "$baseUrl/api/v2/user/files?path=$([uri]::EscapeDataString($remotePath))"
        Invoke-RestMethod -Method Delete -Uri $uri -Headers (Get-AuthHeader) | Out-Null
        Write-Host "Deleted $remotePath"
        $script:deleted++
    } catch {
        Write-Warning "Failed to delete: $remotePath : $($_.Exception.Message)"
        $script:failed++
    }
}

function Copy-Directory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$remote, [string]$local)
    foreach ($entry in Get-RemoteEntries $remote) {
        $name = [string]$entry.name
        if ($name.StartsWith('.sftpgo-upload.')) { continue }  # an upload in progress (written by SFTPGo, renamed when done)
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
                if (-not $WhatIfPreference) { [IO.Directory]::CreateDirectory($localPath) | Out-Null }
                Copy-Directory $remotePath $localPath
            } catch {
                Write-Warning "Failed: $remotePath : $($_.Exception.Message)"
                $script:failed++
            }
            continue
        }

        if ((Test-Path -LiteralPath $localPath -PathType Leaf) -and (Get-Item -LiteralPath $localPath).Length -eq [int64]$entry.size) {
            $script:skipped++
            if ($DeleteAfterCopy) { Remove-RemoteFile $remotePath }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($remotePath, 'Copy')) {
            # With -WhatIf, also list the delete that would follow the copy.
            if ($WhatIfPreference -and $DeleteAfterCopy) { Remove-RemoteFile $remotePath }
            continue
        }

        # A fixed, wildcard-free temporary name: recording names contain [ ], which -OutFile may treat as a pattern.
        $part = Join-Path $local '.download.part'
        try {
            Write-Host "Copying $remotePath"
            $uri = "$baseUrl/api/v2/user/files?path=$([uri]::EscapeDataString($remotePath))"
            Save-RemoteFile $uri $part
            if ((Get-Item -LiteralPath $part).Length -ne [int64]$entry.size) {
                throw "size mismatch (expected $($entry.size) bytes)"
            }
            Move-Item -LiteralPath $part -Destination $localPath -Force -Confirm:$false
            $script:copied++
        } catch {
            Write-Warning "Failed: $remotePath : $($_.Exception.Message)"
            Remove-Item -LiteralPath $part -Force -Confirm:$false -ErrorAction SilentlyContinue
            $script:failed++
            continue
        }
        if ($DeleteAfterCopy) { Remove-RemoteFile $remotePath }
    }
}

if (-not $SkipRecordingCheck) {
    try {
        $recording = Get-ActiveRecordings
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
    if (-not $WhatIfPreference) { [IO.Directory]::CreateDirectory($destRoot) | Out-Null }
    Copy-Directory $remoteRoot $destRoot
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}

Write-Host "Done: copied $script:copied, skipped $script:skipped, deleted $script:deleted, failed $script:failed"
if ($script:deleteStopped) { Write-Warning 'Deleting was stopped; re-run when no recording is in progress to delete the remaining files.' }
if ($script:failed -gt 0 -or $script:deleteStopped) { exit 1 }
