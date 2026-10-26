<#
.SYNOPSIS
    Packages Archaeology Assistant into a Mod.io submission-ready ZIP file.

.DESCRIPTION
    1. Validates plugin manifest and Lua syntax via scripts/Build-Plugin.ps1.
    2. Stages a clean runtime bundle in dist/archaeology-assistant.
    3. Compresses files so main.lua and plugin.json are strictly at the ROOT of the archive.
    4. Names the package archaeology-assistant-v<version>.zip.
    5. Verifies top-level archive structure as required by the RuneScape Mod.io guidelines.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot "Build-Plugin.ps1"

# 1. Run build script to validate & stage runtime files
Write-Host "--- Step 1: Building and Validating Plugin ---" -ForegroundColor Cyan
& $BuildScript

$manifestPath = Join-Path $RepoRoot "plugin.json"
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$version = $manifest.version

$DistDir = Join-Path $RepoRoot "dist\archaeology-assistant"
$DistRoot = Join-Path $RepoRoot "dist"

# Output zip path
$zipName = "archaeology-assistant-v$version.zip"
$zipPath = Join-Path $DistRoot $zipName

Write-Host "`n--- Step 2: Creating Submission Zip Archive ---" -ForegroundColor Cyan
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

# Clean up any legacy alias zip if present
$legacyAltZip = Join-Path $DistRoot "archaeology-assistant-$($version -replace '\.', '').zip"
if (Test-Path $legacyAltZip) { Remove-Item -Force $legacyAltZip }

# Add-Type for zip compression to ensure forward slashes and root-level packaging
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zipArchive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -Path $DistDir -Recurse | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $relPath = $_.FullName.Substring($DistDir.Length).TrimStart('\', '/')
        # Use forward slashes in zip entries for cross-platform compatibility
        $entryName = $relPath -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $_.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $zipArchive.Dispose()
}

Write-Host "Archive created successfully:" -ForegroundColor Green
Write-Host "  -> $zipPath" -ForegroundColor White

Write-Host "`n--- Step 3: Verifying Mod.io Archive Structure ---" -ForegroundColor Cyan
$verifyArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$hasRootMain = $false
$hasRootManifest = $false
$entryList = @()

try {
    foreach ($entry in $verifyArchive.Entries) {
        $entryList += $entry.FullName
        if ($entry.FullName -eq "main.lua") { $hasRootMain = $true }
        if ($entry.FullName -eq "plugin.json") { $hasRootManifest = $true }
    }
} finally {
    $verifyArchive.Dispose()
}

if (-not $hasRootMain -or -not $hasRootManifest) {
    throw "Verification failed: main.lua and plugin.json must reside at the root of the ZIP file!"
}

Write-Host "Mod.io Structure Verification: PASSED" -ForegroundColor Green
Write-Host "Archive contents ($($entryList.Count) files):" -ForegroundColor Gray
$entryList | ForEach-Object { Write-Host "   $($_)" -ForegroundColor Gray }

$zipSize = (Get-Item $zipPath).Length
Write-Host "`nPackage Size: $([math]::Round($zipSize / 1KB, 1)) KB" -ForegroundColor Green
Write-Host "Ready for Mod.io upload!" -ForegroundColor Cyan
