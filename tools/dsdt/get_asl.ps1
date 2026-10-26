# Pulls asl.exe (Microsoft ACPI assembler) out of the official WDK NuGet package,
# so you don't have to install the whole Windows Driver Kit.
param([string]$Version = '10.0.28000.2526')

$pkg = Join-Path $env:TEMP "wdk.$Version.nupkg"
$dst = Join-Path $PSScriptRoot 'asl.exe'
$url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/$Version/microsoft.windows.wdk.x64.$Version.nupkg"

Write-Host "Downloading WDK package (~110 MB)..."
Invoke-WebRequest $url -OutFile $pkg -UseBasicParsing

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($pkg)
try {
    $entry = $zip.Entries | ? { $_.FullName -like '*/x64/ACPIVerify/asl.exe' } | Select-Object -First 1
    if (-not $entry) { Write-Error 'asl.exe not found in the package'; exit 1 }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dst, $true)
} finally { $zip.Dispose() }
Remove-Item $pkg

$sig = Get-AuthenticodeSignature $dst
"asl.exe: $($sig.Status), signed by $($sig.SignerCertificate.Subject -replace ',.*','')"
