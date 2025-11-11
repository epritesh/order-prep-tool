Param(
    [string]$Version = (Get-Date -Format 'yyyyMMdd-HHmm')
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipName = "order-prep-widget-$Version.zip"
# Write the zip OUTSIDE the source folder to avoid self-inclusion/lock conflicts
$parent = Split-Path -Parent $here
$zipPath = Join-Path $parent $zipName

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Host "Packing widget from: $here" -ForegroundColor Cyan

# Ensure plugin-manifest.json exists
if (!(Test-Path (Join-Path $here 'plugin-manifest.json'))) {
    Write-Error 'plugin-manifest.json not found. Run from widget root (order_prep folder).'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($here, $zipPath)

Write-Host "Created $zipPath" -ForegroundColor Green
Write-Host "Upload this zip in Zoho Books Developer Space > Extensions > Upload Extension" -ForegroundColor Yellow
