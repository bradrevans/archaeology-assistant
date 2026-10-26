<#
.SYNOPSIS
    Validates, builds, and optionally deploys the Archaeology Assistant RS3 plugin.

.DESCRIPTION
    Ensures build/generator scripts, documentation, and repo metadata are NOT bundled
    into the plugin package. Copies only runtime plugin files:
      - plugin.json
      - main.lua
      - tracker.lua
      - data/*.lua
      - ui/*.lua
    into dist/archaeology-assistant (and when -Deploy is passed, into
    C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\archaeology-assistant).

.PARAMETER UpdateData
    If set, runs scripts/Update-WikiData.ps1 first to pull the latest RS3 Wiki data.

.PARAMETER Deploy
    If set, copies the clean plugin bundle directly into C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\archaeology-assistant.

.PARAMETER LaunchBeta
    If set, launches the Jagex Launcher directly into the RS3 Plugin Developer Beta environment.
#>
[CmdletBinding()]
param(
    [switch]$UpdateData,
    [switch]$Deploy,
    [switch]$LaunchBeta
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$DistDir  = Join-Path $RepoRoot "dist\archaeology-assistant"

# Official Windows RS3 Plugin Developer Beta path (plus standard ProgramData RuneScape path)
$TargetDirs = @(
    "C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\archaeology-assistant",
    "C:\ProgramData\Jagex\RuneScape\dev_plugins\archaeology-assistant"
)

# 1. Optionally refresh Wiki data first
if ($UpdateData) {
    $updateScript = Join-Path $PSScriptRoot "Update-WikiData.ps1"
    & $updateScript
}

# 2. Validate plugin.json
$manifestPath = Join-Path $RepoRoot "plugin.json"
if (-not (Test-Path $manifestPath)) {
    throw "Missing plugin.json at $manifestPath"
}
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($manifest.name) -or [string]::IsNullOrWhiteSpace($manifest.version) -or [string]::IsNullOrWhiteSpace($manifest.contactEmailAddress)) {
    throw "plugin.json must define name, version, and contactEmailAddress."
}
Write-Host "Validated plugin.json: $($manifest.name) v$($manifest.version) ($($manifest.contactEmailAddress))" -ForegroundColor Green

# 3. Validate data integrity & Lua files
$matText = Get-Content (Join-Path $RepoRoot "data\materials.lua") -Raw
$artText = Get-Content (Join-Path $RepoRoot "data\artefacts.lua") -Raw
$hotText = Get-Content (Join-Path $RepoRoot "data\hotspots.lua") -Raw
$definedMats = [regex]::Matches($matText, 'name\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$usedMats = [regex]::Matches($artText, '\{\s*name\s*=\s*"([^"]+)",\s*count\s*=\s*\d+\s*\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
$missingMats = @($usedMats | Where-Object { $_ -notin $definedMats })
if ($missingMats.Count -gt 0) {
    throw "Artefact recipes reference undefined materials: $($missingMats -join ', ')"
}
Write-Host "Validated recipe integrity: $($definedMats.Count) materials defined, 0 missing references." -ForegroundColor Green

if ($hotText -match '&#\d+;') {
    throw "data/hotspots.lua contains unescaped HTML entities!"
}

$runtimeFiles = @(
    "plugin.json",
    "main.lua",
    "tracker.lua",
    "data\materials.lua",
    "data\artefacts.lua",
    "data\hotspots.lua",
    "data\collections.lua",
    "ui\window.lua",
    "ui\overlay.lua"
)

foreach ($relPath in $runtimeFiles) {
    $fullPath = Join-Path $RepoRoot $relPath
    if (-not (Test-Path $fullPath)) {
        throw "Missing required plugin file: $relPath"
    }
    if ($relPath.EndsWith(".lua")) {
        # Check and strip UTF-8 BOM if present
        $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
        if ($fileBytes.Length -ge 3 -and $fileBytes[0] -eq 239 -and $fileBytes[1] -eq 187 -and $fileBytes[2] -eq 191) {
            [System.IO.File]::WriteAllBytes($fullPath, $fileBytes[3..($fileBytes.Length - 1)])
            Write-Host "Automatically stripped UTF-8 BOM from $relPath" -ForegroundColor Yellow
        }

        $content = Get-Content $fullPath -Raw
        $openBrace  = ([regex]::Matches($content, "\{")).Count
        $closeBrace = ([regex]::Matches($content, "\}")).Count
        $openParen  = ([regex]::Matches($content, "\(")).Count
        $closeParen = ([regex]::Matches($content, "\)")).Count
        if ($openBrace -ne $closeBrace -or $openParen -ne $closeParen) {
            throw "Syntax check failed: unbalanced braces or parentheses in $relPath"
        }
    }
}

# 4. Stage clean plugin bundle into dist/archaeology-assistant (excluding scripts/, README.md, etc.)
if (Test-Path $DistDir) {
    Remove-Item -Recurse -Force $DistDir
}
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

foreach ($relPath in $runtimeFiles) {
    $src = Join-Path $RepoRoot $relPath
    $dst = Join-Path $DistDir $relPath
    $dstParent = Split-Path -Parent $dst
    if (-not (Test-Path $dstParent)) {
        New-Item -ItemType Directory -Force -Path $dstParent | Out-Null
    }
    Copy-Item -Path $src -Destination $dst -Force
}

Write-Host "Built clean plugin package at: $DistDir" -ForegroundColor Cyan

# 5. Optionally deploy to RS3 dev_plugins
if ($Deploy) {
    foreach ($targetDir in $TargetDirs) {
        $devRoot = Split-Path -Parent $targetDir
        New-Item -ItemType Directory -Force -Path $devRoot | Out-Null
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }
        Get-ChildItem -Path $DistDir -Recurse | ForEach-Object {
            $rel = $_.FullName.Substring($DistDir.Length).TrimStart('\', '/')
            $dest = Join-Path $targetDir $rel
            if ($_.PSIsContainer) {
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            } else {
                Copy-Item -Path $_.FullName -Destination $dest -Force
            }
        }
        Write-Host "Deployed clean plugin bundle to: $targetDir" -ForegroundColor Green
    }

    # Ensure PrettyUI (6398181) is unpacked into dev_plugins\prettyui so local dependency "PrettyUI" resolves on prf
    $livePrettyZip = "C:\ProgramData\Jagex\RuneScape\plugins\6398181\6398181.zip"
    if (Test-Path $livePrettyZip) {
        foreach ($devPrettyDir in @(
            "C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\prettyui",
            "C:\ProgramData\Jagex\RuneScape\dev_plugins\prettyui"
        )) {
            $devPrettyMain = Join-Path $devPrettyDir "main.lua"
            if (-not (Test-Path $devPrettyMain)) {
                New-Item -ItemType Directory -Force -Path $devPrettyDir | Out-Null
                Expand-Archive -Path $livePrettyZip -DestinationPath $devPrettyDir -Force
                Write-Host "Unpacked PrettyUI local dependency to: $devPrettyDir" -ForegroundColor Cyan
            }
        }
    }
}

# 6. Optionally launch the RS3 Plugin Developer Beta via Jagex Launcher
if ($LaunchBeta) {
    $betaUri = "jagex:launch=runescape,args=[configURI=rs-launch://www.runescape.com/jav_config_beta.ws]"
    Write-Host "Launching RS3 Plugin Developer Beta via Jagex Launcher..." -ForegroundColor Cyan
    Start-Process $betaUri
}
