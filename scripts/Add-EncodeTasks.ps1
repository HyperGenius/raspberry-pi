<#
.SYNOPSIS
Adds the *.m2ts recordings in a folder to the Amatsukaze encode queue (AmatsukazeAddTask.exe), choosing the profile by a key in the file name.

.DESCRIPTION
For every *.m2ts directly in ENCODE_RECORDED_DIR, the first line of the profile map whose key is contained in the
file name decides the profile. A file with no matching key is skipped (logged as a warning). A file that was already
added is skipped too (the originals stay in place because of --no-move, so a re-run must not queue them again).

Profile map (ENCODE_PROFILE_MAP, default windows\amatsukaze\encode-profiles.csv in the repository): UTF-8 text, one
"key,profile" per line. Blank lines and lines starting with # are ignored. The first matching line wins, so put
specific keys above general ones. Matching is case-insensitive. Neither a key nor a profile name may contain a comma.
The profile must exist in Amatsukaze (names are case-sensitive there).

Settings come from environment variables. If .env.ps1 exists in the repository root it is loaded first.
If a value contains Japanese, save .env.ps1 as UTF-8 with BOM (Windows PowerShell 5.1 reads it as ANSI otherwise).

  ENCODE_OUTPUT_DIR         required  folder for the encoded files (created if missing)
  ENCODE_RECORDED_DIR       optional  default E:\RaspberryPi_recorded
  AMATSUKAZE_DIR            optional  default C:\ProgramData\Amatsukaze
  AMATSUKAZE_HOST           optional  default localhost
  AMATSUKAZE_PORT           optional  default 32768
  ENCODE_PROFILE_MAP        optional  path of the profile map
  ENCODE_DATA_DIR           optional  where the log and the list of added files go (default %ProgramData%\EncodeRecordings)

Each run appends to <data dir>\logs\encode-YYYYMMDD.log (files older than 30 days are deleted). The added files are
remembered in <data dir>\submitted.txt as "name|size|profile"; delete a line to add that file again.
Nothing is written or added with -WhatIf.

Exit code: 0 on success (including "nothing to do" and skipped files without a profile), 1 on a configuration error
or when AmatsukazeAddTask.exe failed for any file.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

$envFile = Join-Path $PSScriptRoot '..\.env.ps1'
if (Test-Path -LiteralPath $envFile) { . $envFile }

$script:added = 0
$script:skippedNoProfile = 0
$script:skippedDone = 0
$script:failed = 0

# ---- log ----
function Get-Setting([string]$name, [string]$default) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($v) { return $v } else { return $default }
}
$dataDir = Get-Setting 'ENCODE_DATA_DIR' (Join-Path $env:ProgramData 'EncodeRecordings')
$dataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dataDir)
$logDir = Join-Path $dataDir 'logs'
$submittedFile = Join-Path $dataDir 'submitted.txt'
$logRetentionDays = 30
$script:logFile = $null
$utf8 = New-Object System.Text.UTF8Encoding $false

if (-not $WhatIfPreference) {
    try {
        [IO.Directory]::CreateDirectory($logDir) | Out-Null
        $script:logFile = Join-Path $logDir ('encode-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Get-ChildItem -LiteralPath $logDir -Filter 'encode-*.log' -File |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$logRetentionDays) } |
            Remove-Item -Force -Confirm:$false -ErrorAction SilentlyContinue
    } catch {
        $script:logFile = $null
        Write-Warning "Could not prepare the log folder $logDir (no log file will be written): $($_.Exception.Message)"
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

# Log the failure of a task that runs as SYSTEM, where nobody sees the console.
trap {
    Write-Log "Unexpected error: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" ERROR
    exit 1
}

Write-Log "Start: WhatIf=$([bool]$WhatIfPreference)"

# ---- settings ----
if (-not $env:ENCODE_OUTPUT_DIR) {
    Write-Log 'Missing environment variable: ENCODE_OUTPUT_DIR (see .env.ps1.example)' ERROR
    exit 1
}
$recordedDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Get-Setting 'ENCODE_RECORDED_DIR' 'E:\RaspberryPi_recorded'))
$outputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:ENCODE_OUTPUT_DIR)
$amatsukazeDir = (Get-Setting 'AMATSUKAZE_DIR' 'C:\ProgramData\Amatsukaze').TrimEnd('\')
$amatsukazeExe = Join-Path $amatsukazeDir 'exe_files\AmatsukazeAddTask.exe'
$amatsukazeHost = Get-Setting 'AMATSUKAZE_HOST' 'localhost'
$amatsukazePort = Get-Setting 'AMATSUKAZE_PORT' '32768'
$mapFile = Get-Setting 'ENCODE_PROFILE_MAP' (Join-Path $PSScriptRoot '..\windows\amatsukaze\encode-profiles.csv')
$mapFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($mapFile)

foreach ($check in @(@($amatsukazeExe, 'AmatsukazeAddTask.exe'), @($mapFile, 'the profile map (copy encode-profiles.csv.example)'))) {
    if (-not (Test-Path -LiteralPath $check[0] -PathType Leaf)) {
        Write-Log "Not found: $($check[1]): $($check[0])" ERROR
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $recordedDir -PathType Container)) {
    Write-Log "Not found: the recorded folder: $recordedDir" ERROR
    exit 1
}

# ---- profile map: first match wins ----
$rules = New-Object System.Collections.Generic.List[object]
$lineNo = 0
foreach ($line in [IO.File]::ReadAllLines($mapFile, $utf8)) {
    $lineNo++
    $t = $line.Trim().TrimStart([char]0xFEFF)
    if (-not $t -or $t.StartsWith('#')) { continue }
    $parts = $t.Split(',', 2)
    $key = $parts[0].Trim()
    $profile = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
    if (-not $key -or -not $profile) {
        Write-Log "Ignoring line $lineNo of the profile map (need key,profile): $t" WARN
        continue
    }
    $rules.Add([pscustomobject]@{ Key = $key; Profile = $profile })
}
if ($rules.Count -eq 0) {
    Write-Log "The profile map has no entries: $mapFile" ERROR
    exit 1
}
Write-Log "Profile map: $($rules.Count) entries ($mapFile)"

# ---- already added ----
$done = @{}
if (Test-Path -LiteralPath $submittedFile) {
    foreach ($l in [IO.File]::ReadAllLines($submittedFile, $utf8)) {
        $p = $l.Split('|')
        if ($p.Count -ge 2) { $done["$($p[0])|$($p[1])"] = $true }
    }
}

if (-not $WhatIfPreference) { [IO.Directory]::CreateDirectory($outputDir) | Out-Null }

# -LiteralPath is not available for -Filter; recording names contain [ ], so list and filter by extension.
$files = @(Get-ChildItem -LiteralPath $recordedDir -File | Where-Object { $_.Extension -ieq '.m2ts' } | Sort-Object Name)
Write-Log "Found $($files.Count) m2ts file(s) in $recordedDir"

foreach ($f in $files) {
    $id = "$($f.Name)|$($f.Length)"
    if ($done.ContainsKey($id)) { $script:skippedDone++; continue }

    $rule = $rules | Where-Object { $f.Name.IndexOf($_.Key, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
    if (-not $rule) {
        Write-Log "No profile for: $($f.Name) (skipped)" WARN
        $script:skippedNoProfile++
        continue
    }

    $exeArgs = @(
        '-r', $amatsukazeDir, '-f', $f.FullName, '-ip', $amatsukazeHost, '-p', $amatsukazePort,
        '-o', $outputDir, '-s', $rule.Profile, '--priority', '3', '--no-move', '--clear-succeeded'
    )
    if (-not $PSCmdlet.ShouldProcess($f.Name, "Add to Amatsukaze with profile '$($rule.Profile)'")) { continue }

    Write-Log "Adding: $($f.Name) (key '$($rule.Key)', profile '$($rule.Profile)')"
    try {
        & $amatsukazeExe @exeArgs | ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
    } catch {
        Write-Log "Failed to add: $($f.Name): $($_.Exception.Message)" WARN
        $script:failed++
        continue
    }
    [IO.File]::AppendAllText($submittedFile, "$id|$($rule.Profile)`n", $utf8)
    $done[$id] = $true
    $script:added++
}

Write-Log "Done: added $script:added, already added $script:skippedDone, no profile $script:skippedNoProfile, failed $script:failed"
exit $(if ($script:failed -gt 0) { 1 } else { 0 })
