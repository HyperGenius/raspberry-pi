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

  SFTPGO_BASE_URL           required  e.g. http://192.168.10.55:8080
  SFTPGO_USER               required
  SFTPGO_PASSWORD           required
  RECORDINGS_DEST_DIR       required  local destination folder
  EPGSTATION_BASE_URL       required  e.g. http://192.168.10.55:8888 (not needed with -SkipRecordingCheck)
  SFTPGO_REMOTE_DIR         optional  source folder on SFTPGo (default /data)
  COPY_RECORDINGS_DATA_DIR  optional  where the log and metrics files go (default %ProgramData%\CopyRecordings)

Each run appends to <data dir>\logs\copy-YYYYMMDD.log (files older than 30 days are deleted) and, when it ends,
rewrites <data dir>\metrics\copy_recordings.prom (Prometheus text format, read by Grafana Alloy's textfile collector).
Nothing is written with -WhatIf.

.PARAMETER SkipRecordingCheck
Copy without checking EPGStation for an active recording. Cannot be combined with -DeleteAfterCopy.

.PARAMETER SleepAfter
When the run ends, start the scheduled task \MyTasks\SleepAfterCopy (Sleep-Computer.ps1), which puts the PC back to sleep
if the scheduled task woke it. Not done after a run skipped because of a recording (the task's retry still has to run),
or with -WhatIf. Register that task first (see README).

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
    [switch]$DeleteAfterCopy,
    [switch]$SleepAfter
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is slow with the progress bar on Windows PowerShell 5.1
$script:stopwatch = [Diagnostics.Stopwatch]::StartNew()

$envFile = Join-Path $PSScriptRoot '..\.env.ps1'
if (Test-Path -LiteralPath $envFile) { . $envFile }

$script:copied = 0
$script:skipped = 0
$script:deleted = 0
$script:failed = 0
$script:bytesCopied = [int64]0
$script:deleteStopped = $false
$script:authFailed = $false

# ---- log and metrics files ----
$dataDir = if ($env:COPY_RECORDINGS_DATA_DIR) { $env:COPY_RECORDINGS_DATA_DIR } else { Join-Path $env:ProgramData 'CopyRecordings' }
$dataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dataDir)
$logDir = Join-Path $dataDir 'logs'
$metricsFile = Join-Path $dataDir 'metrics\copy_recordings.prom'
$logRetentionDays = 30
$script:logFile = $null
$utf8 = New-Object System.Text.UTF8Encoding $false  # no BOM: Alloy and windows_exporter read the files as they are

if (-not $WhatIfPreference) {
    try {
        [IO.Directory]::CreateDirectory($logDir) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path $metricsFile)) | Out-Null
        $script:logFile = Join-Path $logDir ('copy-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Get-ChildItem -LiteralPath $logDir -Filter 'copy-*.log' -File |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$logRetentionDays) } |
            Remove-Item -Force -Confirm:$false -ErrorAction SilentlyContinue  # may be held open by Alloy; retried next run
    } catch {
        $script:logFile = $null
        Write-Warning "Could not prepare the log folder $logDir (no log file or metrics will be written): $($_.Exception.Message)"
    }
}

# Writes to the console and appends "<ISO 8601 time> <LEVEL> <message>" to today's log file.
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error $Message -ErrorAction Continue }
        default { Write-Host $Message }
    }
    if ($script:logFile) {
        $line = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Level, ($Message -replace '\r?\n', ' | ')
        try { [IO.File]::AppendAllText($script:logFile, $line + "`n", $utf8) } catch { }
    }
}

# Rewrites the .prom file atomically (windows_exporter must never see a half-written file).
function Write-Metrics([string]$reason, [int]$code) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lastSuccess = [int64]0
    if ($code -eq 0) {
        $lastSuccess = $now
    } elseif (Test-Path -LiteralPath $metricsFile) {
        # Keep the time of the last success across failed runs (and runs skipped because of a recording).
        $m = [regex]::Match((Get-Content -LiteralPath $metricsFile -Raw), '(?m)^copy_recordings_last_success_timestamp_seconds (\d+)')
        if ($m.Success) { $lastSuccess = [int64]$m.Groups[1].Value }
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# HELP copy_recordings_last_run_timestamp_seconds Unix time when the last run ended.')
    $lines.Add('# TYPE copy_recordings_last_run_timestamp_seconds gauge')
    $lines.Add("copy_recordings_last_run_timestamp_seconds $now")
    $lines.Add('# HELP copy_recordings_last_success_timestamp_seconds Unix time of the last run that exited with 0 (0 if never).')
    $lines.Add('# TYPE copy_recordings_last_success_timestamp_seconds gauge')
    $lines.Add("copy_recordings_last_success_timestamp_seconds $lastSuccess")
    $lines.Add('# HELP copy_recordings_last_success 1 if the last run exited with 0, otherwise 0.')
    $lines.Add('# TYPE copy_recordings_last_success gauge')
    $lines.Add("copy_recordings_last_success $(if ($code -eq 0) { 1 } else { 0 })")
    $lines.Add('# HELP copy_recordings_files Files handled by the last run, by result.')
    $lines.Add('# TYPE copy_recordings_files gauge')
    foreach ($kv in @(@('copied', $script:copied), @('skipped', $script:skipped), @('deleted', $script:deleted), @('failed', $script:failed))) {
        $lines.Add("copy_recordings_files{result=`"$($kv[0])`"} $($kv[1])")
    }
    $lines.Add('# HELP copy_recordings_bytes_copied Bytes copied by the last run.')
    $lines.Add('# TYPE copy_recordings_bytes_copied gauge')
    $lines.Add("copy_recordings_bytes_copied $script:bytesCopied")
    $lines.Add('# HELP copy_recordings_duration_seconds Duration of the last run.')
    $lines.Add('# TYPE copy_recordings_duration_seconds gauge')
    $lines.Add('copy_recordings_duration_seconds ' + [math]::Round($script:stopwatch.Elapsed.TotalSeconds, 1).ToString($inv))
    $lines.Add('# HELP copy_recordings_exit_reason 1 for how the last run ended, 0 for the others.')
    $lines.Add('# TYPE copy_recordings_exit_reason gauge')
    foreach ($r in 'ok', 'recording', 'config', 'epgstation', 'auth', 'failed', 'delete_stopped') {
        $lines.Add("copy_recordings_exit_reason{reason=`"$r`"} $(if ($r -eq $reason) { 1 } else { 0 })")
    }
    $tmp = $metricsFile + '.tmp'
    [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), $utf8)
    Move-Item -LiteralPath $tmp -Destination $metricsFile -Force -Confirm:$false
}

# Every exit goes through here so that the metrics are always written.
# reason: ok | recording | config | epgstation | auth | failed | delete_stopped
function Complete-Run([string]$reason, [int]$code) {
    if ($script:logFile) {
        try { Write-Metrics $reason $code } catch { Write-Warning "Could not write $metricsFile : $($_.Exception.Message)" }
    }
    # A separate task does the sleeping: this process would be frozen by the sleep, and its task would still be running at the next trigger.
    if ($SleepAfter -and -not $WhatIfPreference -and $reason -ne 'recording') {
        try {
            Start-ScheduledTask -TaskPath '\MyTasks' -TaskName 'SleepAfterCopy'
            Write-Log 'Started the SleepAfterCopy task'
            # The task has no console, so record what the scheduler says about it (a result other than 0x41301/0x0 means it did not run the script).
            Start-Sleep -Seconds 5
            $sleepTask = Get-ScheduledTask -TaskPath '\MyTasks' -TaskName 'SleepAfterCopy'
            $sleepInfo = $sleepTask | Get-ScheduledTaskInfo
            $sleepAction = $sleepTask.Actions | Select-Object -First 1
            Write-Log ('SleepAfterCopy: state={0} lastRun={1:s} lastResult=0x{2:X} action={3} {4}' -f $sleepTask.State, $sleepInfo.LastRunTime, $sleepInfo.LastTaskResult, $sleepAction.Execute, $sleepAction.Arguments)
        } catch {
            Write-Log "Could not start the SleepAfterCopy task (register it first; see README): $($_.Exception.Message)" WARN
        }
    }
    exit $code
}

Write-Log "Start: DeleteAfterCopy=$([bool]$DeleteAfterCopy) SkipRecordingCheck=$([bool]$SkipRecordingCheck) WhatIf=$([bool]$WhatIfPreference)"

if ($DeleteAfterCopy -and $SkipRecordingCheck) {
    Write-Log '-DeleteAfterCopy cannot be combined with -SkipRecordingCheck (a file being recorded could be deleted)' ERROR
    Complete-Run 'config' 1
}

$required = @('SFTPGO_BASE_URL', 'SFTPGO_USER', 'SFTPGO_PASSWORD', 'RECORDINGS_DEST_DIR')
if (-not $SkipRecordingCheck) { $required += 'EPGSTATION_BASE_URL' }
$missing = $required |
    Where-Object { -not [Environment]::GetEnvironmentVariable($_) }
if ($missing) {
    Write-Log "Missing environment variables: $($missing -join ', ') (see .env.ps1.example)" ERROR
    Complete-Run 'config' 1
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
            $script:authFailed = $true
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

# Deletes a remote file whose local copy is complete, unless a recording has started since the last check.
function Remove-RemoteFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$remotePath)
    if ($script:deleteStopped -or -not $PSCmdlet.ShouldProcess($remotePath, 'Delete')) { return }
    try {
        $recording = Get-ActiveRecordings
    } catch {
        Write-Log "Could not check EPGStation for active recordings; no more files will be deleted: $($_.Exception.Message)" WARN
        $script:deleteStopped = $true
        return
    }
    if ([int]$recording.total -gt 0) {
        Write-Log "EPGStation started recording ($($recording.total)); no more files will be deleted" WARN
        $script:deleteStopped = $true
        return
    }
    try {
        $uri = "$baseUrl/api/v2/user/files?path=$([uri]::EscapeDataString($remotePath))"
        Invoke-RestMethod -Method Delete -Uri $uri -Headers (Get-AuthHeader) | Out-Null
        Write-Log "Deleted $remotePath"
        $script:deleted++
    } catch {
        Write-Log "Failed to delete: $remotePath : $($_.Exception.Message)" WARN
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
            Write-Log "Skipping unsafe name: $remote/$name" WARN
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
                Write-Log "Failed: $remotePath : $($_.Exception.Message)" WARN
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
            Write-Log "Copying $remotePath ($($entry.size) bytes)"
            $uri = "$baseUrl/api/v2/user/files?path=$([uri]::EscapeDataString($remotePath))"
            Save-RemoteFile $uri $part
            if ((Get-Item -LiteralPath $part).Length -ne [int64]$entry.size) {
                throw "size mismatch (expected $($entry.size) bytes)"
            }
            Move-Item -LiteralPath $part -Destination $localPath -Force -Confirm:$false
            $script:copied++
            $script:bytesCopied += [int64]$entry.size
        } catch {
            Write-Log "Failed: $remotePath : $($_.Exception.Message)" WARN
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
        Write-Log "Could not check EPGStation for active recordings (check EPGSTATION_BASE_URL): $($_.Exception.Message)" ERROR
        Complete-Run 'epgstation' 1
    }
    if ([int]$recording.total -gt 0) {
        Write-Log "EPGStation is recording ($($recording.total)); nothing was copied:" WARN
        foreach ($r in @($recording.records)) { Write-Log "  $($r.name)" WARN }
        Complete-Run 'recording' 1
    }
    Write-Log 'No recording in progress.'
}

try {
    if (-not $WhatIfPreference) { [IO.Directory]::CreateDirectory($destRoot) | Out-Null }
    Copy-Directory $remoteRoot $destRoot
} catch {
    Write-Log $_.Exception.Message ERROR
    Complete-Run $(if ($script:authFailed) { 'auth' } else { 'failed' }) 1
}

Write-Log "Done: copied $script:copied, skipped $script:skipped, deleted $script:deleted, failed $script:failed ($script:bytesCopied bytes copied)"
if ($script:deleteStopped) { Write-Log 'Deleting was stopped; re-run when no recording is in progress to delete the remaining files.' WARN }
$reason = if ($script:authFailed) { 'auth' } elseif ($script:failed -gt 0) { 'failed' } elseif ($script:deleteStopped) { 'delete_stopped' } else { 'ok' }
Complete-Run $reason $(if ($reason -eq 'ok') { 0 } else { 1 })
