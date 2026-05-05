$TS_DIR  = $PSScriptRoot
$TS_EXE  = "$TS_DIR\ThrottleStop.exe"
$INI     = "$TS_DIR\ThrottleStop.ini"
$LOG     = "$TS_DIR\power_monitor.log"

$NVIDIA  = $null
foreach ($line in (& pnputil /enum-devices /class Display 2>&1)) {
    if ($line -match 'Instance ID:\s*(PCI\\VEN_10DE\S+)') {
        $NVIDIA = $Matches[1].Trim()
        break
    }
}

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
    Log "-> AC: Profile 0$(if ($NVIDIA) { ' + enabling NVIDIA' })"
    if ($NVIDIA) { & pnputil /enable-device $NVIDIA | Out-Null }
    Set-TSProfile 0
} else {
    Log "-> Battery: Profile 3$(if ($NVIDIA) { ' + disabling NVIDIA' })"
    Set-TSProfile 3
    if ($NVIDIA) {
        Start-Sleep -Milliseconds 800
        & pnputil /disable-device $NVIDIA | Out-Null
    }
}

Log "Done"
