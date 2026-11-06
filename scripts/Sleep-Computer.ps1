<#
.SYNOPSIS
Puts the PC back to sleep after an unattended wake (started by Copy-Recordings.ps1 -SleepAfter).

.DESCRIPTION
Meant to run as the scheduled task \MyTasks\SleepAfterCopy (SYSTEM, no trigger), which Copy-Recordings.ps1 -SleepAfter starts
when it finishes. It is a separate task because a process that sleeps is frozen until the next wake: if Copy-Recordings.ps1
itself slept, its task would still be "running" at the next trigger and the next run would not start.

  1. Sleeps only if the PC was woken by a timer: the latest "resumed from a low-power state" event
     (System log, Microsoft-Windows-Power-Troubleshooter, ID 1) is at most -MaxWakeAgeHours old and its wake source
     matches -WakeSourcePattern (an RTC alarm, "Device -ACPI Wake Alarm", on the PC this was built on; the source
     does not name the task there) or names -WakeTaskName. A PC that was already awake (or that you woke yourself,
     by the power button, a keyboard or the network adapter) is left alone.
  2. Waits -DelaySeconds so that Grafana Alloy can send the final log and metrics (its scrape interval is 60 s).
  3. Skips sleeping if a logon session has had keyboard/mouse input in the last -MinIdleMinutes
     (only reported by some sessions, e.g. remote desktop; the console session often reports none).
  4. Suspends (sleep, not hibernate).

The outcome is appended to the Copy-Recordings log (<data dir>\logs\copy-YYYYMMDD.log, COPY_RECORDINGS_DATA_DIR as in
Copy-Recordings.ps1). With -WhatIf nothing is waited for or suspended; the idle check is still reported.

Limits: if you start using the PC after the task woke it and before the script ends, the console session's input time is
usually not available, so it may go to sleep under you. Media playback is not detected either.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$DelaySeconds = 120,
    [int]$MinIdleMinutes = 10,
    [string]$WakeTaskName = 'MyTasks\CopyRecordings',
    [string]$WakeSourcePattern = 'Wake Alarm|Timer',
    [int]$MaxWakeAgeHours = 8
)

$ErrorActionPreference = 'Stop'

$envFile = Join-Path $PSScriptRoot '..\.env.ps1'
if (Test-Path -LiteralPath $envFile) { . $envFile }

$dataDir = if ($env:COPY_RECORDINGS_DATA_DIR) { $env:COPY_RECORDINGS_DATA_DIR } else { Join-Path $env:ProgramData 'CopyRecordings' }
$dataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dataDir)
$logDir = Join-Path $dataDir 'logs'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    Write-Host "${Level}: $Message"
    try {
        [IO.Directory]::CreateDirectory($logDir) | Out-Null
        $file = Join-Path $logDir ('copy-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        $line = '{0} {1} sleep: {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'), $Level, $Message
        [IO.File]::AppendAllText($file, $line + "`n", $utf8)
    } catch { }
}

# Anything that goes wrong from here on is written to the log (the task has no console to read).
trap {
    Write-Log "Failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" ERROR
    exit 1
}
Write-Log "Started as $env:USERNAME (PowerShell $($PSVersionTable.PSVersion))"

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class SleepHelper
{
    [StructLayout(LayoutKind.Sequential)]
    struct WTS_SESSION_INFO { public int SessionId; public IntPtr WinStationName; public int State; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WTSINFO
    {
        public int State;
        public int SessionId;
        public int IncomingBytes, OutgoingBytes, IncomingFrames, OutgoingFrames, IncomingCompressedBytes, OutgoingCompressedBytes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
        public long ConnectTime, DisconnectTime, LastInputTime, LogonTime, CurrentTime;
    }

    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    static extern bool WTSQuerySessionInformationW(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")]
    static extern void WTSFreeMemory(IntPtr memory);
    [DllImport("powrprof.dll", SetLastError = true)]
    static extern bool SetSuspendState(bool hibernate, bool force, bool wakeupEventsDisabled);

    // "UserName@Station: idle seconds" for every logon session that has a user (the services session 0 and listeners have none).
    public static List<string> Sessions(out double minIdleSeconds)
    {
        minIdleSeconds = double.MaxValue;
        var result = new List<string>();
        IntPtr list; int count;
        if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out list, out count)) throw new System.ComponentModel.Win32Exception();
        try
        {
            int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; i++)
            {
                var s = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(list.ToInt64() + (long)i * size), typeof(WTS_SESSION_INFO));
                IntPtr buf; int bytes;
                if (!WTSQuerySessionInformationW(IntPtr.Zero, s.SessionId, 24 /* WTSSessionInfo */, out buf, out bytes)) continue;
                try
                {
                    var info = (WTSINFO)Marshal.PtrToStructure(buf, typeof(WTSINFO));
                    if (string.IsNullOrEmpty(info.UserName)) continue;
                    double idle = info.LastInputTime == 0 ? double.MaxValue : (info.CurrentTime - info.LastInputTime) / 1e7;
                    if (idle < minIdleSeconds) minIdleSeconds = idle;
                    result.Add(info.UserName + "@" + info.WinStationName + ": " + (idle == double.MaxValue ? "no input" : ((long)idle).ToString() + " s"));
                }
                finally { WTSFreeMemory(buf); }
            }
        }
        finally { WTSFreeMemory(list); }
        return result;
    }

    public static bool Suspend() { return SetSuspendState(false, false, false); }  // false = sleep, not hibernate
}
'@

# Was the PC woken by a timer? The source is "Device -ACPI Wake Alarm" here, or "Timer - Windows will execute 'NT TASK\<task>' ..." elsewhere.
try {
    $wake = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 1
} catch {
    Write-Log "Could not read the wake history, so the PC is left awake: $($_.Exception.Message)" WARN
    exit 1
}
$wakeAge = if ($wake) { (Get-Date) - $wake.TimeCreated } else { [TimeSpan]::MaxValue }
if (-not $wake -or $wakeAge.TotalHours -gt $MaxWakeAgeHours -or -not ($wake.Message -match $WakeSourcePattern -or $wake.Message.Contains("NT TASK\$WakeTaskName"))) {
    $source = if ($wake) { $m = $wake.Message -replace '\s+', ' '; $m.Substring([Math]::Max(0, $m.Length - 100)) } else { 'no wake event' }
    Write-Log "Not sleeping: the PC was not woken by a timer (latest wake: $(if ($wake) { $wake.TimeCreated.ToString('s') } else { '-' }); $source)"
    exit 0
}

if ($PSCmdlet.ShouldProcess('this computer', "Wait ${DelaySeconds}s, then sleep unless in use")) {
    Write-Log "Waiting ${DelaySeconds}s for Alloy to send the log and metrics"
    Start-Sleep -Seconds $DelaySeconds
}

[double]$idleSeconds = 0
try {
    $sessions = [SleepHelper]::Sessions([ref]$idleSeconds)
} catch {
    Write-Log "Could not read the logon sessions, so the PC is left awake: $($_.Exception.Message)" WARN
    exit 1
}
$detail = if ($sessions.Count -gt 0) { $sessions -join '; ' } else { 'no logon sessions' }

Write-Verbose "Sessions: $detail"
if ($idleSeconds -lt $MinIdleMinutes * 60) {
    Write-Log "Not sleeping: the PC was used in the last $MinIdleMinutes minutes ($detail)"
    exit 0
}

if ($PSCmdlet.ShouldProcess('this computer', 'Sleep')) {
    Write-Log "Going to sleep ($detail)"
    if (-not [SleepHelper]::Suspend()) {
        Write-Log "SetSuspendState failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" WARN
        exit 1
    }
}
