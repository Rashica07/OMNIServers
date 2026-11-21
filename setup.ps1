# OMNIServers setup for Windows. From PowerShell in the repo folder:
#   .\setup.ps1            run the desktop app
#   .\setup.ps1 -Check     only look for what is missing
# It installs nothing: it tells you what to install.
param([switch]$Check)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"; $env:DOTNET_NOLOGO = "1"
$sdk = $null
try { $sdk = (& dotnet --list-sdks) -match '^10\.' } catch {}
if ($sdk) { Write-Host "  OK  .NET 10 SDK" }
else { Write-Host "  MISSING  .NET 10 SDK -> https://dotnet.microsoft.com/download/dotnet/10.0  (or: winget install Microsoft.DotNet.SDK.10)"; exit 1 }
if ($Check) { exit 0 }
Set-Location (Join-Path $root "apps\desktop")
dotnet run --project src/CraftPanel.App -c Release
