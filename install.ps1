#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up ThrottleStop auto power-switching for Dell Precision 5570.
    Does NOT perform the UEFI PROCHOT unlock — see README.md Part 1 for that.

.PARAMETER ThrottleStopDir
    Path to the folder containing ThrottleStop.exe.
    If omitted, the script searches common locations automatically.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -ThrottleStopDir "C:\Tools\ThrottleStop"
#>
param(
    [string]$ThrottleStopDir = ""
)

$ErrorActionPreference = "Stop"
$REPO = $PSScriptRoot

# ── 1. Locate ThrottleStop ────────────────────────────────────────────────────

if ($ThrottleStopDir) {
    if (-not (Test-Path "$ThrottleStopDir\ThrottleStop.exe")) {
        Write-Error "ThrottleStop.exe not found in: $ThrottleStopDir"
        exit 1
    }
    $TS_DIR = $ThrottleStopDir
} else {
    $candidates = @(
        "$REPO"
        "$env:LOCALAPPDATA\ThrottleStop"
        "C:\ThrottleStop"
        "$env:USERPROFILE\Desktop\ThrottleStop*"
        "$env:USERPROFILE\Downloads\ThrottleStop*"
    ) | ForEach-Object { Resolve-Path $_ -ErrorAction SilentlyContinue } |
        Where-Object { Test-Path "$_\ThrottleStop.exe" } |
        Select-Object -First 1

    if (-not $candidates) {
        Write-Error "ThrottleStop.exe not found. Specify path: .\install.ps1 -ThrottleStopDir 'C:\path\to\ThrottleStop'"
        exit 1
    }
    $TS_DIR = $candidates.Path
}

Write-Host ""
Write-Host "ThrottleStop folder : $TS_DIR"

# ── 2. Copy scripts ───────────────────────────────────────────────────────────

foreach ($f in @("on_power_change.ps1", "start_ts_minimized.ps1")) {
    $src = "$REPO\scripts\$f"
    if (-not (Test-Path $src)) { Write-Error "Missing: $src"; exit 1 }
    Copy-Item $src "$TS_DIR\" -Force
}
Write-Host "Scripts copied      : on_power_change.ps1, start_ts_minimized.ps1"

# ── 3. Report NVIDIA detection (handled at runtime by on_power_change.ps1) ───

$pnpLines = & pnputil /enum-devices /class Display 2>&1
foreach ($line in $pnpLines) {
    if ($line -match 'Instance ID:\s*(PCI\\VEN_10DE\S+)') {
        Write-Host "NVIDIA device found : $($Matches[1].Trim())"
        break
    }
}

# ── 4. Deploy ThrottleStop.ini (config + profile names) ──────────────────────

$ini       = "$TS_DIR\ThrottleStop.ini"
$configSrc = "$REPO\configs\ThrottleStop.ini"

Get-Process ThrottleStop -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

if (Test-Path $configSrc) {
    Copy-Item $configSrc $ini -Force
    Write-Host "Config deployed     : ThrottleStop.ini (power limits, lock settings)"
}

if (Test-Path $ini) {
    $ansi = [System.Text.Encoding]::GetEncoding(1251)
    $text = [System.IO.File]::ReadAllText($ini, $ansi)
    $text = $text -replace '(?m)^ProfileName1=.*', 'ProfileName1=AC Max'
    $text = $text -replace '(?m)^ProfileName4=.*', 'ProfileName4=Battery ECO'
    [System.IO.File]::WriteAllText($ini, $text, $ansi)
    Write-Host "INI profile names   : set (AC Max / Battery ECO)"
} else {
    Write-Host "ThrottleStop.ini not found — profile names will be set on first run."
}

# ── 5. Create scheduled tasks ─────────────────────────────────────────────────

$sid = (New-Object System.Security.Principal.NTAccount("$env:USERDOMAIN\$env:USERNAME")).Translate(
    [System.Security.Principal.SecurityIdentifier]).Value

# Task: PowerSourceChange — fires on Kernel-Power Event 105 (AC plug/unplug)
$xmlPower = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><EventTrigger><Enabled>true</Enabled>
    <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=105]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
  </EventTrigger></Triggers>
  <Principals><Principal><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>Queue</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT2M</ExecutionTimeLimit></Settings>
  <Actions><Exec>
    <Command>powershell.exe</Command>
    <Arguments>-WindowStyle Hidden -ExecutionPolicy Bypass -File "$TS_DIR\on_power_change.ps1"</Arguments>
  </Exec></Actions>
</Task>
"@

# Task: GpuResumeCheck — fires on Kernel-Power Event 507 (exit Modern Standby),
# re-checks the dGPU power limit only (on_power_change.ps1 -Resume)
$xmlResume = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><EventTrigger><Enabled>true</Enabled>
    <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    <Delay>PT5S</Delay>
  </EventTrigger></Triggers>
  <Principals><Principal><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT2M</ExecutionTimeLimit></Settings>
  <Actions><Exec>
    <Command>powershell.exe</Command>
    <Arguments>-WindowStyle Hidden -ExecutionPolicy Bypass -File "$TS_DIR\on_power_change.ps1" -Resume</Arguments>
  </Exec></Actions>
</Task>
"@

# Task: ThrottleStop — start minimized at logon
$xmlLogon = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><LogonTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary></LogonTrigger></Triggers>
  <Principals><Principal><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings>
  <Actions><Exec>
    <Command>powershell.exe</Command>
    <Arguments>-WindowStyle Hidden -ExecutionPolicy Bypass -File "$TS_DIR\start_ts_minimized.ps1"</Arguments>
  </Exec></Actions>
</Task>
"@

foreach ($task in @(
    [pscustomobject]@{ Name = "PowerSourceChange"; Xml = $xmlPower  }
    [pscustomobject]@{ Name = "GpuResumeCheck";    Xml = $xmlResume }
    [pscustomobject]@{ Name = "ThrottleStop";      Xml = $xmlLogon  }
)) {
    $tmp = "$env:TEMP\ts_task_$($task.Name).xml"
    [System.IO.File]::WriteAllText($tmp, $task.Xml, [System.Text.Encoding]::Unicode)
    try { schtasks /delete /tn $task.Name /f 2>&1 | Out-Null } catch {}
    schtasks /create /tn $task.Name /xml $tmp /f 2>&1 | Out-Null
    Remove-Item $tmp
    Write-Host "Task created        : $($task.Name)"
}

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Installation complete ==="
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Open ThrottleStop, go to Profile 1 (AC Max)"
Write-Host "  2. UNCHECK the 'BD PROCHOT' checkbox"
Write-Host "     (if greyed out: UEFI PROCHOT Lock is not unlocked, see README.md Part 1)"
Write-Host "  3. Click TURN ON"
Write-Host ""
Write-Host "Plug/unplug charger to test switching. Log: $TS_DIR\power_monitor.log"
