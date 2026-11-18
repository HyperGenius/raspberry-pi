<#
.SYNOPSIS
Registers the scheduled tasks described in windows\tasks\tasks.psd1 (CopyRecordings, SleepAfterCopy). Safe to run any number of times.

.DESCRIPTION
The config file is the single source of truth. For every task in it, this script builds the complete task definition
(action, triggers, principal, settings) and compares it with the registered task of the same name:

  - not registered yet   -> registers it                       ([create])
  - registered, same     -> does nothing                       ([unchanged])
  - registered, differs  -> prints the differences, replaces   ([update])

Because the whole definition is rebuilt from the config, running it twice gives the same result, and removing a switch from
the config removes it from the task. Tasks that are not in the config are never touched or deleted.

Replacing a task resets what was changed by hand in Task Scheduler (including a task you disabled: it becomes enabled again).
A task that is running right now keeps running. Run with -WhatIf first: it shows the differences and changes nothing.

Scripts are referenced by their location next to this script ($PSScriptRoot), so no path is written in the config.
Needs an elevated PowerShell (not for -WhatIf). Works on Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER ConfigPath
The config file. Default: ..\windows\tasks\tasks.psd1 (copy tasks.psd1.example there and edit it).

.PARAMETER TaskPath
Overrides the TaskPath of the config (for trying this out under another folder, e.g. '\MyTasksTest\').
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\windows\tasks\tasks.psd1'),
    [string]$TaskPath
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 under -WhatIf prints a "WhatIf: alias" line for every alias the CIM module defines when it loads.
# Load the modules first, with -WhatIf off.
$savedWhatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module CimCmdlets, ScheduledTasks
$WhatIfPreference = $savedWhatIf

# --- Config ---------------------------------------------------------------------------------------------------------

# Rejects keys that are missing or not known, so that a typo in the config is an error instead of being ignored.
function Assert-Keys($Table, [string[]]$Allowed, [string[]]$Required, [string]$Where) {
    if ($Table -isnot [hashtable]) { throw "${Where}: must be a hashtable (@{ ... })" }
    foreach ($k in $Table.Keys) {
        if ($Allowed -cnotcontains $k) { throw "${Where}: unknown key '$k' (allowed: $($Allowed -join ', '))" }
    }
    foreach ($k in $Required) {
        if (-not $Table.ContainsKey($k)) { throw "${Where}: missing key '$k'" }
    }
}

function Import-TaskConfig([string]$Path, [string]$ScriptsDir) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config not found: $Path (copy windows\tasks\tasks.psd1.example to windows\tasks\tasks.psd1 and edit it)"
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path
    Assert-Keys $config @('TaskPath', 'Tasks') @('Tasks') 'config'
    if (@($config.Tasks).Count -eq 0) { throw 'config: Tasks is empty' }

    $names = @{}
    $i = 0
    foreach ($task in @($config.Tasks)) {
        $i++
        Assert-Keys $task @('Name', 'Script', 'Arguments', 'Triggers', 'Settings') @('Name', 'Script') "Tasks[$i]"
        $where = "Task '$($task.Name)'"
        if ($task.Name -notmatch '^[\w .-]+$') { throw "$where : Name may only contain letters, digits, space, '_', '.', '-'" }
        if ($names.ContainsKey($task.Name)) { throw "$where : Name is used twice" }
        $names[$task.Name] = $true
        if (-not (Test-Path -LiteralPath (Join-Path $ScriptsDir $task.Script) -PathType Leaf)) {
            throw "$where : script not found in scripts\: $($task.Script)"
        }
        foreach ($a in $task.Arguments) {
            if ($a -notmatch '^-\S+$') { throw "$where : each Arguments item must be one token that starts with '-' (got '$a')" }
        }
        foreach ($t in $task.Triggers) {
            if ($t -isnot [hashtable] -or $t.Type -isnot [string]) { throw "$where : each trigger needs a Type" }
            switch ($t.Type) {
                'Daily' {
                    Assert-Keys $t @('Type', 'At') @('Type', 'At') "$where trigger Daily"
                    $parsed = [datetime]::MinValue
                    if (-not [datetime]::TryParseExact($t.At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$parsed)) {
                        throw "$where : trigger At must be HH:mm (24-hour), got '$($t.At)'"
                    }
                }
                'WakeEvent' {
                    Assert-Keys $t @('Type', 'WakeSource', 'Delay') @('Type', 'WakeSource') "$where trigger WakeEvent"
                    if ($t.WakeSource -match '[''"<>&]') { throw "$where : WakeSource must not contain ' `" < > &" }
                    if ($t.Delay) { [void][Xml.XmlConvert]::ToTimeSpan($t.Delay) }   # ISO 8601 duration such as PT2M
                }
                default { throw "$where : unknown trigger Type '$($t.Type)' (Daily, WakeEvent)" }
            }
        }
        if ($task.Settings) {
            Assert-Keys $task.Settings @('WakeToRun', 'StartWhenAvailable', 'RestartCount', 'RestartIntervalMinutes', 'ExecutionTimeLimitHours') @() "$where Settings"
            if ($task.Settings.ContainsKey('RestartCount') -and -not $task.Settings.ContainsKey('RestartIntervalMinutes')) {
                throw "$where : RestartCount needs RestartIntervalMinutes"
            }
        }
    }
    return $config
}

# --- Building the task we want -----------------------------------------------------------------------------------

# Fires 'Delay' after the PC resumed from sleep by the given wake source (the Power-Troubleshooter event, ID 1).
function New-WakeEventTrigger([string]$WakeSource, [string]$Delay) {
    $query = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]] and *[EventData[Data[@Name='WakeSourceText']='@@SOURCE@@']]</Select></Query></QueryList>
'@
    $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $class -ClientOnly
    $trigger.Enabled = $true
    $trigger.Subscription = $query.Trim().Replace('@@SOURCE@@', $WakeSource)
    if ($Delay) { $trigger.Delay = $Delay }
    return $trigger
}

function New-DesiredTask($Entry, [string]$ScriptsDir) {
    $argText = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $ScriptsDir $Entry.Script)
    if ($Entry.Arguments) { $argText += ' ' + (@($Entry.Arguments) -join ' ') }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argText

    $triggers = @()
    foreach ($t in $Entry.Triggers) {
        if ($t.Type -eq 'Daily') {
            $at = [datetime]::ParseExact($t.At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            $triggers += New-ScheduledTaskTrigger -Daily -At $at
        } else {
            $triggers += New-WakeEventTrigger $t.WakeSource $t.Delay
        }
    }

    $s = if ($Entry.Settings) { $Entry.Settings } else { @{} }
    $set = @{}
    if ($s.WakeToRun) { $set.WakeToRun = $true }
    if ($s.StartWhenAvailable) { $set.StartWhenAvailable = $true }
    if ($s.ContainsKey('RestartCount')) {
        $set.RestartCount = [int]$s.RestartCount
        $set.RestartInterval = New-TimeSpan -Minutes $s.RestartIntervalMinutes
    }
    if ($s.ContainsKey('ExecutionTimeLimitHours')) { $set.ExecutionTimeLimit = [TimeSpan]::FromHours($s.ExecutionTimeLimitHours) }

    $params = @{
        Action    = $action
        Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Settings  = New-ScheduledTaskSettingsSet @set
    }
    if ($triggers.Count -gt 0) { $params.Trigger = $triggers }
    return New-ScheduledTask @params
}

# --- Comparing ---------------------------------------------------------------------------------------------------

function ConvertTo-Minutes($Duration) {
    if (-not $Duration) { return 'none' }
    return [string][Xml.XmlConvert]::ToTimeSpan([string]$Duration).TotalMinutes
}

# The parts of a task definition that this script owns, as a list of "name=value" lines. Works on a task that was just built
# (New-ScheduledTask) and on a registered one (Get-ScheduledTask), so the two can be compared. What Windows fills in on its
# own (registration date, the date part of a trigger's start time, ...) is left out.
function Get-TaskSignature($Task) {
    $lines = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($a in @($Task.Actions)) {
        $lines.Add("action[$n].execute=$($a.Execute)")
        $lines.Add("action[$n].arguments=$($a.Arguments)")
        $n++
    }
    $p = $Task.Principal
    $lines.Add("principal=$($p.UserId) / $($p.LogonType) / $($p.RunLevel)")

    $s = $Task.Settings
    foreach ($name in 'Enabled', 'WakeToRun', 'StartWhenAvailable', 'RestartCount', 'MultipleInstances', 'DisallowStartIfOnBatteries', 'StopIfGoingOnBatteries') {
        $lines.Add("settings.$name=$($s.$name)")
    }
    $lines.Add("settings.RestartIntervalMinutes=$(ConvertTo-Minutes $s.RestartInterval)")
    $lines.Add("settings.ExecutionTimeLimitMinutes=$(ConvertTo-Minutes $s.ExecutionTimeLimit)")

    foreach ($t in $Task.Triggers) {
        $kind = $t.CimClass.CimClassName -replace '^MSFT_Task(.*)Trigger$', '$1'
        $detail = switch ($kind) {
            'Daily' { 'at={0:HH:mm} every={1}d' -f [datetime]$t.StartBoundary, $t.DaysInterval }
            'Event' { 'delay={0} query={1}' -f (ConvertTo-Minutes $t.Delay), (($t.Subscription -replace '>\s+<', '><').Trim()) }
            default { '' }
        }
        $lines.Add("trigger=$kind enabled=$($t.Enabled) $detail".TrimEnd())
    }
    return $lines.ToArray()
}

# --- Main --------------------------------------------------------------------------------------------------------

if (-not $WhatIfPreference) {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this in an elevated (administrator) PowerShell. -WhatIf works without it.'
    }
}

$config = Import-TaskConfig $ConfigPath $PSScriptRoot
if (-not $TaskPath) { $TaskPath = if ($config.TaskPath) { $config.TaskPath } else { '\MyTasks\' } }
$TaskPath = '\' + $TaskPath.Trim('\') + '\'

$counts = @{ create = 0; update = 0; unchanged = 0 }
foreach ($entry in @($config.Tasks)) {
    $full = "$TaskPath$($entry.Name)"
    $desired = New-DesiredTask $entry $PSScriptRoot
    $existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $entry.Name -ErrorAction SilentlyContinue

    if (-not $existing) {
        Write-Host "[create]    $full"
        $verb = 'create'
    } else {
        $diff = @(Compare-Object (Get-TaskSignature $existing) (Get-TaskSignature $desired))
        if ($diff.Count -eq 0) {
            Write-Host "[unchanged] $full"
            $counts.unchanged++
            continue
        }
        Write-Host "[update]    $full"
        foreach ($d in $diff) { Write-Host ("    {0} {1}" -f $(if ($d.SideIndicator -eq '<=') { '- registered:' } else { '+ new:       ' }), $d.InputObject) }
        $verb = 'update'
    }

    if ($PSCmdlet.ShouldProcess($full, "Register scheduled task ($verb)")) {
        [void](Register-ScheduledTask -TaskPath $TaskPath -TaskName $entry.Name -InputObject $desired -Force)
    }
    $counts[$verb]++
}

$what = if ($WhatIfPreference) { 'would be' } else { 'were' }
Write-Host ("Done: {0} created, {1} updated, {2} unchanged ({3} {4} applied)." -f $counts.create, $counts.update, $counts.unchanged, ($counts.create + $counts.update), $what)
