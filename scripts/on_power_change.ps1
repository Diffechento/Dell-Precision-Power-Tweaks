$TS_DIR  = $PSScriptRoot
$TS_EXE  = "$TS_DIR\ThrottleStop.exe"
$INI     = "$TS_DIR\ThrottleStop.ini"
$LOG     = "$TS_DIR\power_monitor.log"
$NVIDIA  = "PCI\VEN_10DE&DEV_25BA&SUBSYS_0B1A1028&REV_A1\4&3afd7104&0&0008"

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
Log "Event 105: AC=$isAC"

if ($isAC) {
    Log "-> AC: enabling NVIDIA + Profile 0"
    & pnputil /enable-device $NVIDIA | Out-Null
    Set-TSProfile 0
} else {
    Log "-> Battery: Profile 3 + disabling NVIDIA"
    Set-TSProfile 3
    Start-Sleep -Milliseconds 800   # brief wait for GPU workloads to migrate
    & pnputil /disable-device $NVIDIA | Out-Null
}

Log "Done"
