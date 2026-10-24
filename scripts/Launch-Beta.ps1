<#
.SYNOPSIS
    Builds and deploys the Archaeology Assistant plugin and launches the RS3 Plugin Developer Beta client.
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

if (-not $SkipBuild) {
    $buildScript = Join-Path $PSScriptRoot "Build-Plugin.ps1"
    & $buildScript -Deploy
} else {
    $betaUri = "jagex:launch=runescape,args=[configURI=rs-launch://www.runescape.com/jav_config_beta.ws]"
    Write-Host "Launching RS3 Plugin Developer Beta via Jagex Launcher..." -ForegroundColor Cyan
    Start-Process $betaUri
    return
}

$betaUri = "jagex:launch=runescape,args=[configURI=rs-launch://www.runescape.com/jav_config_beta.ws]"
Write-Host "Launching RS3 Plugin Developer Beta via Jagex Launcher..." -ForegroundColor Cyan
Start-Process $betaUri
