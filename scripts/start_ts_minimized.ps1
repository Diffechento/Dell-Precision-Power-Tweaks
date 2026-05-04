$TS_EXE = "$PSScriptRoot\ThrottleStop.exe"

Start-Process $TS_EXE

try {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class TS_Win { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd); }'
} catch {}

$p = Get-Process ThrottleStop -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($p) {
    $deadline = (Get-Date).AddSeconds(5)
    while ($p.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $p.Refresh()
    }
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
        [TS_Win]::ShowWindow($p.MainWindowHandle, 7)
    }
}
