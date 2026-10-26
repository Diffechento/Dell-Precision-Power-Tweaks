#Requires -RunAsAdministrator
# Loads (default) or removes (-Remove) the DSDT registry override via asl.exe /loadtable.
# Windows only honours the override while test signing is on. Reboot to apply either way.
param(
    [string]$Aml = (Join-Path $PSScriptRoot 'DSDT_patched.aml'),
    [switch]$Remove
)

$asl = Join-Path $PSScriptRoot 'asl.exe'
if (-not (Test-Path $asl)) { Write-Error "asl.exe not found, run get_asl.ps1 first"; exit 1 }
if (-not (Test-Path $Aml)) { Write-Error "$Aml not found"; exit 1 }

if ($Remove) { & $asl /nologo /loadtable /d $Aml } else { & $asl /nologo /loadtable $Aml }

$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\ACPI\Parameters\DSDT'
if (Test-Path $key) { "Override present: $((Get-ChildItem $key -Recurse | Select-Object -Last 1).Name)" }
else { 'No DSDT override in the registry.' }
if ((bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes') -eq $null) {
    Write-Warning 'testsigning is OFF - the override will be ignored. bcdedit /set testsigning on'
}
