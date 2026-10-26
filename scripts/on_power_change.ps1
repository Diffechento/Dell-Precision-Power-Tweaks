# -Resume: run from the wake-from-sleep task, only re-checks the GPU power limit on AC
param([switch]$Resume)

$TS_DIR  = $PSScriptRoot
$TS_EXE  = "$TS_DIR\ThrottleStop.exe"
$INI     = "$TS_DIR\ThrottleStop.ini"
$LOG     = "$TS_DIR\power_monitor.log"

# Get-PnpDevice instead of parsing pnputil: pnputil output is localized ("Instance ID:" is translated on Russian Windows).
# No -PresentOnly, so a disabled dGPU is still found.
$NVIDIA  = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' } |
    Select-Object -First 1 -ExpandProperty InstanceId

function Log($msg) {
    Add-Content -Path $LOG -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ErrorAction SilentlyContinue
}

function Get-ACStatus {
    try {
        $s = Get-WmiObject -Class BatteryStatus -Namespace root\wmi -ErrorAction Stop
        return [bool]$s.PowerOnline
    } catch {
        $b = Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue
        return ($b -eq $null -or $b.BatteryStatus -ne 1)
    }
}

function Get-GpuPowerLimit {
    $line = & nvidia-smi -q -d POWER 2>$null | Select-String 'Current Power Limit\s*:\s*([\d.]+) W' | Select-Object -First 1
    if ($line) { return [double]$line.Matches[0].Groups[1].Value }
    return $null
}

# After enable / resume the dGPU can come up stuck at 20W (P5, mem 810MHz); restarting the device restores the full limit
function Ensure-GpuFullPower {
    if (-not $NVIDIA) { return }
    $limit = $null
    $deadline = (Get-Date).AddSeconds(15)
    while ($limit -eq $null -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $limit = Get-GpuPowerLimit
    }
    Log "GPU power limit: $limit W"
    if ($limit -eq $null -or $limit -ge 35) { return }

    & pnputil /restart-device $NVIDIA | Out-Null
    Start-Sleep -Seconds 5
    Log "GPU restarted, power limit now: $(Get-GpuPowerLimit) W"
}

function Set-TSProfile($profileIndex) {
    Get-Process ThrottleStop -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300

    $content = [System.IO.File]::ReadAllText($INI, [System.Text.Encoding]::GetEncoding(1251))
    $content = $content -replace '(?m)^Profile=\d+', "Profile=$profileIndex"
    [System.IO.File]::WriteAllText($INI, $content, [System.Text.Encoding]::GetEncoding(1251))

    Start-Process $TS_EXE

    try {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class TS_Win { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd); }'
    } catch {}

    $p = Get-Process ThrottleStop -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($p) {
        $deadline = (Get-Date).AddSeconds(4)
        while ($p.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
            $p.Refresh()
        }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
            [TS_Win]::ShowWindow($p.MainWindowHandle, 7)
        }
    }
}

# Short delay for OS to settle power state
Start-Sleep -Milliseconds 800

$isAC = Get-ACStatus

if ($Resume) {
    Log "Event 507 (resume): AC=$isAC"
    if ($isAC) { Ensure-GpuFullPower }
    exit
}

Log "Event 105: AC=$isAC"

if ($isAC) {
    Log "-> AC: Profile 0$(if ($NVIDIA) { ' + enabling NVIDIA' })"
    if ($NVIDIA) { & pnputil /enable-device $NVIDIA | Out-Null }
    Set-TSProfile 0
    Ensure-GpuFullPower
} else {
    Log "-> Battery: Profile 3$(if ($NVIDIA) { ' + disabling NVIDIA' })"
    Set-TSProfile 3
    if ($NVIDIA) {
        Start-Sleep -Milliseconds 800
        & pnputil /disable-device $NVIDIA | Out-Null
    }
}

Log "Done"
