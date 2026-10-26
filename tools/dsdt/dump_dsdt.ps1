# Saves the DSDT that Windows is currently using to .\DSDT.aml (no admin needed).
# With an override loaded this returns the overridden table, so it doubles as a check.
param([string]$Out = (Join-Path $PSScriptRoot 'DSDT.aml'))

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class FwTable {
  [DllImport("kernel32.dll")] public static extern uint GetSystemFirmwareTable(uint sig, uint id, byte[] buf, uint size);
}
'@
$ACPI = 0x41435049
$id = [BitConverter]::ToUInt32([Text.Encoding]::ASCII.GetBytes('DSDT'), 0)
$size = [FwTable]::GetSystemFirmwareTable($ACPI, $id, $null, 0)
if (-not $size) { Write-Error 'DSDT not returned by GetSystemFirmwareTable'; exit 1 }
$buf = New-Object byte[] $size
[FwTable]::GetSystemFirmwareTable($ACPI, $id, $buf, $size) | Out-Null
[IO.File]::WriteAllBytes($Out, $buf)

$patched = ($buf.Length -gt 0x70107 -and $buf[0x70107] -eq 0xD1 -and $buf[0x6DFE5] -eq 0xA3)
'{0}: {1} bytes, checksum 0x{2:X2}, skin-temp patch active: {3}' -f $Out, $size, $buf[9], $patched
