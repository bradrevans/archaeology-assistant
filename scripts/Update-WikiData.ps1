<#
.SYNOPSIS
    Fetches the latest RS3 Archaeology Materials and Artefacts data from the official
    RuneScape Wiki and regenerates data/materials.lua and data/artefacts.lua.

.DESCRIPTION
    Replayable build-time data generator for the Archaeology Assistant plugin.
    Queries:
      - https://runescape.wiki/w/Materials_(Archaeology)?action=raw
      - https://runescape.wiki/w/Artefacts
    Validates parsed counts and recipe integrity before writing Lua modules.

.PARAMETER OutputDir
    Target directory for generated Lua data files. Defaults to <repo>/data.

.PARAMETER DryRun
    If set, fetches, parses, and validates the Wiki data without writing files.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $OutputDir = Join-Path (Split-Path -Parent $scriptDir) "data"
}
Add-Type -AssemblyName System.Web

$MaterialsUrl = "https://runescape.wiki/w/Materials_(Archaeology)?action=raw"
$ArtefactsUrl = "https://runescape.wiki/w/Artefacts"
$Headers = @{
    "User-Agent" = "RS3-Archaeology-Assistant-Generator/0.1.0 (Brad Evans; bradrevans@gmail.com)"
}

function Invoke-WikiFetch {
    param([string]$Url)
    Write-Host "Fetching $Url ..." -ForegroundColor Cyan
    $response = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec 30
    if ($response.StatusCode -ne 200 -or [string]::IsNullOrWhiteSpace($response.Content)) {
        throw "Failed to fetch valid content from $Url (HTTP $($response.StatusCode))"
    }
    return $response.Content
}

function Escape-LuaString {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace("\", "\\").Replace('"', '\"')
}

# 1. Fetch & Parse Archaeology Materials
$matRaw = Invoke-WikiFetch -Url $MaterialsUrl
$materials = New-Object System.Collections.Generic.List[object]
$archMatNames = @{}

$rows = $matRaw -split "\|-"
foreach ($row in $rows) {
    $lines = @($row -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith("|") })
    if ($lines.Count -ge 2) {
        $mLv = [regex]::Match($lines[0], "^\|\s*(\d+)\s*$")
        $mNm = [regex]::Match($lines[1], "\{\{plinkt\|([^}|]+)")
        if ($mLv.Success -and $mNm.Success) {
            $lvl = [int]$mLv.Groups[1].Value
            $name = $mNm.Groups[1].Value.Trim()
            $culture = "Tutorial"
            $caches = New-Object System.Collections.Generic.List[string]
            if ($lines.Count -ge 5) {
                $culture = $lines[3].TrimStart("|").Trim()
                $rawCaches = $lines[4].TrimStart("|").Trim()
                $cMatches = [regex]::Matches($rawCaches, "\[\[(?:[^|\]]+\|)?([^\]]+)\]\]")
                foreach ($cm in $cMatches) {
                    $val = $cm.Groups[1].Value.Trim()
                    if (-not $caches.Contains($val)) {
                        $caches.Add($val)
                    }
                }
            }
            $materials.Add([PSCustomObject]@{
                Name    = $name
                Level   = $lvl
                Culture = $culture
                Caches  = $caches
            })
            $archMatNames[$name.ToLowerInvariant()] = $name
        }
    }
}

if ($materials.Count -lt 40) {
    throw "Sanity check failed: expected at least 40 Archaeology materials, but parsed $($materials.Count). Wiki markup may have changed."
}
Write-Host "Parsed $($materials.Count) canonical Archaeology materials." -ForegroundColor Green

# 2. Fetch & Parse Artefacts
$artHtml = Invoke-WikiFetch -Url $ArtefactsUrl
$trMatches = [regex]::Matches($artHtml, '(?s)<tr data-rowid="([^"]+)">(.*?)</tr>\s*(?=<tr data-rowid="|</tbody></table>\s*<div)')

if ($trMatches.Count -lt 200) {
    throw "Sanity check failed: expected at least 200 artefacts, but found $($trMatches.Count). Wiki table structure may have changed."
}

$artefacts = New-Object System.Collections.Generic.List[object]
$secondarySet = New-Object System.Collections.Generic.HashSet[string]

foreach ($tm in $trMatches) {
    $name = [System.Web.HttpUtility]::HtmlDecode($tm.Groups[1].Value).Trim()
    $trBody = $tm.Groups[2].Value

    $mLvl = [regex]::Match($trBody, '<td data-sort-value="(\d+)">')
    $level = if ($mLvl.Success) { [int]$mLvl.Groups[1].Value } else { 1 }

    $damagedName = "$name (damaged)"
    $recipe = New-Object System.Collections.Generic.List[object]

    $mTable = [regex]::Match($trBody, '(?s)<table class="products-materials"[^>]*>(.*?)</table>')
    if ($mTable.Success) {
        $subRows = [regex]::Matches($mTable.Groups[1].Value, '(?s)<tr class="nohighlight">(.*?)</tr>')
        foreach ($sr in $subRows) {
            $srText = $sr.Groups[1].Value
            $mQty = [regex]::Match($srText, '>\s*([\d,]+)\s*(?:\u00D7|&#215;|&times;|[^\s\d<]+)\s*<')
            $links = [regex]::Matches($srText, '<a [^>]*title="([^"]+)"[^>]*>([^<]+)</a>')
            if ($mQty.Success -and $links.Count -gt 0) {
                $qty = [int]($mQty.Groups[1].Value -replace ",", "")
                $lastLink = $links[$links.Count - 1]
                $itemTitle = [System.Web.HttpUtility]::HtmlDecode($lastLink.Groups[1].Value).Trim()
                $itemText = [System.Web.HttpUtility]::HtmlDecode($lastLink.Groups[2].Value).Trim()

                if ($itemText.ToLowerInvariant().Contains("(damaged)") -or $itemTitle.ToLowerInvariant().Contains("(damaged)") -or $itemText.ToLowerInvariant().EndsWith("(unpowered)")) {
                    $damagedName = $itemText
                } else {
                    $recipe.Add([PSCustomObject]@{
                        Name  = $itemText
                        Count = $qty
                    })
                    if (-not $archMatNames.ContainsKey($itemText.ToLowerInvariant())) {
                        [void]$secondarySet.Add($itemText)
                    }
                }
            }
        }
    }

    if ($recipe.Count -eq 0) {
        throw "Sanity check failed: artefact '$name' had 0 parsed restoration materials."
    }

    $mChronotes = [regex]::Match($trBody, 'chronotes-100[^>]*>([\d,]+)<')
    $chronotes = if ($mChronotes.Success) { [int]($mChronotes.Groups[1].Value -replace ",", "") } else { 0 }

    $xp = 0.0
    $parts = $trBody -split "</table></td>", 2
    if ($parts.Count -eq 2) {
        $tdMatches = [regex]::Matches($parts[1], '<td(?:\s+data-sort-value="([^"]+)")?[^>]*>')
        if ($tdMatches.Count -ge 2 -and $tdMatches[1].Groups[1].Success) {
            [double]::TryParse(
                $tdMatches[1].Groups[1].Value,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$xp
            ) | Out-Null
        }
    }

    $artefacts.Add([PSCustomObject]@{
        Name        = $name
        DamagedName = $damagedName
        Level       = $level
        Xp          = $xp
        Chronotes   = $chronotes
        Materials   = $recipe
    })
}

$secondaryItems = @($secondarySet) | Sort-Object
Write-Host "Parsed $($artefacts.Count) artefacts and $($secondaryItems.Count) secondary restoration items." -ForegroundColor Green

# 3. Resolve In-Game Item IDs for Materials & Artefacts
Write-Host "Resolving item IDs from RuneScape Wiki..." -ForegroundColor Cyan

function Resolve-ItemIds {
    param([string[]]$Titles)
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Titles) {
        if (-not [string]::IsNullOrWhiteSpace($t) -and -not $unique.Contains($t)) {
            $unique.Add($t)
        }
    }

    $idMap = @{}
    $batchSize = 40
    for ($i = 0; $i -lt $unique.Count; $i += $batchSize) {
        $batch = @($unique | Select-Object -Skip $i -First $batchSize)
        $encoded = ($batch | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join "%7C"
        $url = "https://runescape.wiki/api.php?action=query&prop=revisions&rvprop=content&rvslots=main&titles=$encoded&redirects=1&format=json"
        try {
            $res = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 30
            if ($res.query -and $res.query.pages) {
                foreach ($page in $res.query.pages.PSObject.Properties.Value) {
                    if ($page.revisions -and $page.revisions[0].slots -and $page.revisions[0].slots.main) {
                        $text = $page.revisions[0].slots.main."*"
                        if ($text -match 'id\d*\s*=\s*(\d+)') {
                            $idMap[$page.title] = [int]$Matches[1]
                        }
                    }
                }
            }
            if ($res.query -and $res.query.redirects) {
                foreach ($r in $res.query.redirects) {
                    if ($idMap.ContainsKey($r.to)) {
                        $idMap[$r.from] = $idMap[$r.to]
                    }
                }
            }
            if ($res.query -and $res.query.normalized) {
                foreach ($n in $res.query.normalized) {
                    if ($idMap.ContainsKey($n.to)) {
                        $idMap[$n.from] = $idMap[$n.to]
                    }
                }
            }
        } catch {
            Write-Warning "Failed batch item ID lookup: $_"
        }
    }
    return $idMap
}

$queryTitles = New-Object System.Collections.Generic.List[string]
foreach ($m in $materials) { [void]$queryTitles.Add($m.Name) }
foreach ($sec in $secondaryItems) { [void]$queryTitles.Add($sec) }
foreach ($a in $artefacts) {
    [void]$queryTitles.Add($a.DamagedName)
    [void]$queryTitles.Add($a.Name)
}
# Known special-case aliases
[void]$queryTitles.Add("Tetracompass (unpowered)")
[void]$queryTitles.Add("Spear of Annihilation with shaft + spokes")

$itemIdMap = Resolve-ItemIds -Titles $queryTitles.ToArray()

# Fallback alias mappings
if ($itemIdMap.ContainsKey("Tetracompass (unpowered)")) {
    $itemIdMap["Tetracompass (unpowered) (damaged)"] = $itemIdMap["Tetracompass (unpowered)"]
}
if ($itemIdMap.ContainsKey("Spear of Annihilation with shaft + spokes")) {
    $itemIdMap["Spear of Annihilation (damaged)"] = $itemIdMap["Spear of Annihilation with shaft + spokes"]
}

# Attach resolved IDs
foreach ($m in $materials) {
    $m | Add-Member -NotePropertyName "Id" -NotePropertyValue ($itemIdMap[$m.Name]) -Force
}
$secIdMap = @{}
foreach ($sec in $secondaryItems) {
    $secIdMap[$sec] = $itemIdMap[$sec]
}
foreach ($a in $artefacts) {
    $foundId = if ($itemIdMap.ContainsKey($a.DamagedName)) {
        $itemIdMap[$a.DamagedName]
    } elseif ($itemIdMap.ContainsKey($a.Name)) {
        $itemIdMap[$a.Name]
    } else {
        $null
    }
    $a | Add-Member -NotePropertyName "Id" -NotePropertyValue $foundId -Force
}

$matWithId = @($materials | Where-Object { $null -ne $_.Id }).Count
$artWithId = @($artefacts | Where-Object { $null -ne $_.Id }).Count
Write-Host "Resolved item IDs: $matWithId/$($materials.Count) materials, $artWithId/$($artefacts.Count) artefacts." -ForegroundColor Green

if ($DryRun) {
    Write-Host "[DryRun] Validation succeeded. Skipping file generation." -ForegroundColor Yellow
    return
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 4. Generate data/materials.lua
$sbMat = New-Object System.Text.StringBuilder
[void]$sbMat.AppendLine("-- Auto-generated by scripts/Update-WikiData.ps1 from official RuneScape Wiki data")
[void]$sbMat.AppendLine("-- Do not edit the LIST table manually; re-run scripts/Update-WikiData.ps1 after game updates.")
[void]$sbMat.AppendLine("")
[void]$sbMat.AppendLine("local Materials = {}")
[void]$sbMat.AppendLine("")
[void]$sbMat.AppendLine("Materials.LIST = {")

foreach ($m in $materials) {
    $cacheItems = @($m.Caches | ForEach-Object { "`"$(Escape-LuaString $_)`"" }) -join ", "
    $idVal = if ($m.Id) { $m.Id } else { "nil" }
    [void]$sbMat.AppendLine("    { id = $idVal, name = `"$(Escape-LuaString $m.Name)`", level = $($m.Level), culture = `"$(Escape-LuaString $m.Culture)`", isArchMaterial = true, caches = { $cacheItems } },")
}
foreach ($sec in $secondaryItems) {
    $idVal = if ($secIdMap[$sec]) { $secIdMap[$sec] } else { "nil" }
    [void]$sbMat.AppendLine("    { id = $idVal, name = `"$(Escape-LuaString $sec)`", level = 1, culture = `"Secondary`", isArchMaterial = false, caches = {} },")
}

[void]$sbMat.AppendLine(@'
}

Materials.BY_NAME = {}
Materials.BY_LOWER = {}
Materials.BY_ID = {}

for idx, mat in ipairs(Materials.LIST) do
    mat.order = idx
    Materials.BY_NAME[mat.name] = mat
    Materials.BY_LOWER[string.lower(mat.name)] = mat
    if mat.id then
        Materials.BY_ID[mat.id] = mat
    end
end

function Materials.normalize(name)
    if not name then return "" end
    local s = string.lower(tostring(name))
    s = string.gsub(s, "<col=[^>]+>", "")
    s = string.gsub(s, "</col>", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

function Materials.get(name)
    if not name then return nil end
    return Materials.BY_NAME[name] or Materials.BY_LOWER[Materials.normalize(name)]
end

function Materials.getById(id)
    if not id then return nil end
    return Materials.BY_ID[id]
end

function Materials.isMaterial(name)
    return Materials.get(name) ~= nil
end

function Materials.isArchMaterial(name)
    local m = Materials.get(name)
    return m ~= nil and m.isArchMaterial == true
end

return Materials
'@)

$matPath = Join-Path $OutputDir "materials.lua"
[System.IO.File]::WriteAllText($matPath, $sbMat.ToString(), $utf8NoBom)
Write-Host "Wrote $matPath" -ForegroundColor Cyan

# 5. Fetch & Parse Excavation Hotspots
$hotspotsUrl = "https://runescape.wiki/api.php?action=parse&page=Excavation_hotspots&prop=text&format=json"
Write-Host "Fetching $hotspotsUrl ..." -ForegroundColor Cyan
$hJson = Invoke-WebRequest -Uri $hotspotsUrl -Headers $Headers -UseBasicParsing -TimeoutSec 30
$hData = ConvertFrom-Json $hJson.Content
$hHtml = $hData.parse.text.'*'

$hRows = [regex]::Split($hHtml, '<tr>')
$hotspotsMap = @{}
$artToLoc = @{}

foreach ($hRow in $hRows) {
    $mLevel = [regex]::Match($hRow, 'data-level="(\d+)"')
    $mName = [regex]::Match($hRow, '<td><a[^>]*title="([^"]+)"[^>]*>([^<]+)</a></td>')
    if ($mLevel.Success -and $mName.Success) {
        $level = [int]$mLevel.Groups[1].Value
        $hName = [System.Net.WebUtility]::HtmlDecode($mName.Groups[2].Value.Trim())
        
        $mats = New-Object System.Collections.Generic.List[string]
        $tdMatches = [regex]::Matches($hRow, '(?s)<td[^>]*>(.*?)</td>')
        if ($tdMatches.Count -ge 8) {
            $site = ($tdMatches[3].Groups[1].Value -replace '<[^>]+>', '').Trim()
            $digsite = ($tdMatches[4].Groups[1].Value -replace '<[^>]+>', '').Trim()

            $locStr = if ($digsite -ne "N/A" -and -not [string]::IsNullOrWhiteSpace($digsite)) {
                $dsClean = $digsite -replace ' Dig Site$', ''
                "$hName ($dsClean)"
            } elseif ($site -ne "N/A" -and -not [string]::IsNullOrWhiteSpace($site)) {
                $sClean = $site -replace ' excavation site$', '' -replace ' - Exterior$', ''
                "$hName ($sClean)"
            } else {
                $hName
            }

            $artHtml = $tdMatches[6].Groups[1].Value
            $artMatches = [regex]::Matches($artHtml, 'title="([^"]+)"')
            foreach ($am in $artMatches) {
                $aName = [System.Net.WebUtility]::HtmlDecode($am.Groups[1].Value.Trim())
                if ($aName -notmatch 'Category:|File:|Special:') {
                    $base = $aName -replace ' \(damaged\)$', ''
                    if (-not $artToLoc.ContainsKey($base)) {
                        $artToLoc[$base] = $locStr
                    }
                }
            }

            $matsHtml = $tdMatches[7].Groups[1].Value
            $matMatches = [regex]::Matches($matsHtml, 'title="([^"]+)"')
            foreach ($mm in $matMatches) {
                $matName = [System.Net.WebUtility]::HtmlDecode($mm.Groups[1].Value.Trim())
                if ($matName -notmatch 'Category:|File:|Special:' -and -not $mats.Contains($matName)) {
                    $mats.Add($matName)
                }
            }
        }
        
        if (-not $hotspotsMap.ContainsKey($hName)) {
            $hotspotsMap[$hName] = @{
                level = $level
                materials = $mats
            }
        } else {
            foreach ($mat in $mats) {
                if (-not $hotspotsMap[$hName].materials.Contains($mat)) {
                    $hotspotsMap[$hName].materials.Add($mat)
                }
            }
        }
    }
}

$artFallbacks = @{
    "Centurion's seal" = "Centurion remains (Guild)"
    "Tetracompass (unpowered)" = "Tetracompass rewards"
    "Wingsuit v1" = "Stormguard Citadel"
    "Spear of Annihilation" = "Big High War God shrine (Warforge)"
}

$sbHot = New-Object System.Text.StringBuilder
[void]$sbHot.AppendLine("-- data/hotspots.lua")
[void]$sbHot.AppendLine("-- Auto-generated by scripts/Update-WikiData.ps1 from official RuneScape Wiki data")
[void]$sbHot.AppendLine("-- Maps active Excavation Hotspot world names to their yielded restoration materials.")
[void]$sbHot.AppendLine("")
[void]$sbHot.AppendLine("local Hotspots = {}")
[void]$sbHot.AppendLine("")
[void]$sbHot.AppendLine("Hotspots.BY_NAME = {")

$sortedHotNames = $hotspotsMap.Keys | Sort-Object { $hotspotsMap[$_].level }, { $_ }
foreach ($nameKey in $sortedHotNames) {
    $h = $hotspotsMap[$nameKey]
    $matsList = ($h.materials | ForEach-Object { '"' + (Escape-LuaString $_) + '"' }) -join ", "
    $escapedName = Escape-LuaString $nameKey
    [void]$sbHot.AppendLine("    [`"$escapedName`"] = { level = $($h.level), materials = { $matsList } },")
}

[void]$sbHot.AppendLine("}")
[void]$sbHot.AppendLine("")
[void]$sbHot.AppendLine("-- Fast lowercase index for case-insensitive and tag-stripped matching")
[void]$sbHot.AppendLine("Hotspots.BY_LOWER = {}")
[void]$sbHot.AppendLine("for name, data in pairs(Hotspots.BY_NAME) do")
[void]$sbHot.AppendLine("    Hotspots.BY_LOWER[string.lower(name)] = data")
[void]$sbHot.AppendLine("end")
[void]$sbHot.AppendLine("")
[void]$sbHot.AppendLine("local function cleanHotspotName(name)")
[void]$sbHot.AppendLine("    if not name or type(name) ~= `"string`" then return `"`" end")
[void]$sbHot.AppendLine("    local s = string.gsub(name, `"<[^>]+>`", `"`")")
[void]$sbHot.AppendLine("    s = string.gsub(s, `"[\194\160\160]`", `" `")")
[void]$sbHot.AppendLine("    s = string.gsub(s, `"^%s+`", `"`")")
[void]$sbHot.AppendLine("    s = string.gsub(s, `"%s+$`", `"`")")
[void]$sbHot.AppendLine("    return s")
[void]$sbHot.AppendLine("end")
[void]$sbHot.AppendLine("")
[void]$sbHot.AppendLine("function Hotspots.get(name)")
[void]$sbHot.AppendLine("    if not name then return nil end")
[void]$sbHot.AppendLine("    local direct = Hotspots.BY_NAME[name]")
[void]$sbHot.AppendLine("    if direct then return direct end")
[void]$sbHot.AppendLine("    local cleaned = cleanHotspotName(name)")
[void]$sbHot.AppendLine("    if cleaned ~= name then")
[void]$sbHot.AppendLine("        local cMatch = Hotspots.BY_NAME[cleaned]")
[void]$sbHot.AppendLine("        if cMatch then return cMatch end")
[void]$sbHot.AppendLine("    end")
[void]$sbHot.AppendLine("    return Hotspots.BY_LOWER[string.lower(cleaned)]")
[void]$sbHot.AppendLine("end")
[void]$sbHot.AppendLine("")
[void]$sbHot.AppendLine("function Hotspots.findMatch(rawName)")
[void]$sbHot.AppendLine("    if not rawName then return nil end")
[void]$sbHot.AppendLine("    local exact = Hotspots.get(rawName)")
[void]$sbHot.AppendLine("    if exact then return exact, rawName end")
[void]$sbHot.AppendLine("    local cleaned = cleanHotspotName(rawName)")
[void]$sbHot.AppendLine("    local lowerClean = string.lower(cleaned)")
[void]$sbHot.AppendLine("    for name, data in pairs(Hotspots.BY_NAME) do")
[void]$sbHot.AppendLine("        local lowerKey = string.lower(name)")
[void]$sbHot.AppendLine("        if lowerClean == lowerKey or string.find(lowerClean, lowerKey, 1, true) then")
[void]$sbHot.AppendLine("            return data, name")
[void]$sbHot.AppendLine("        end")
[void]$sbHot.AppendLine("    end")
[void]$sbHot.AppendLine("    return nil, cleaned")
[void]$sbHot.AppendLine("end")
[void]$sbHot.AppendLine("")
[void]$sbHot.AppendLine("return Hotspots")

$hotPath = Join-Path $OutputDir "hotspots.lua"
[System.IO.File]::WriteAllText($hotPath, $sbHot.ToString(), $utf8NoBom)
Write-Host "Wrote $hotPath" -ForegroundColor Cyan

# 6. Generate data/artefacts.lua
$sbArt = New-Object System.Text.StringBuilder
[void]$sbArt.AppendLine("-- Auto-generated by scripts/Update-WikiData.ps1 from official RuneScape Wiki data")
[void]$sbArt.AppendLine("-- Do not edit the LIST table manually; re-run scripts/Update-WikiData.ps1 after game updates.")
[void]$sbArt.AppendLine("")
[void]$sbArt.AppendLine("local Artefacts = {}")
[void]$sbArt.AppendLine("")
[void]$sbArt.AppendLine("Artefacts.LIST = {")

foreach ($a in $artefacts) {
    $matStr = @($a.Materials | ForEach-Object { "{ name = `"$(Escape-LuaString $_.Name)`", count = $($_.Count) }" }) -join ", "
    $xpStr = $a.Xp.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $idVal = if ($a.Id) { $a.Id } else { "nil" }
    $loc = if ($artToLoc.ContainsKey($a.Name)) {
        $artToLoc[$a.Name]
    } elseif ($artFallbacks.ContainsKey($a.Name)) {
        $artFallbacks[$a.Name]
    } else {
        "Archaeology"
    }
    [void]$sbArt.AppendLine("    {")
    [void]$sbArt.AppendLine("        id = $idVal,")
    [void]$sbArt.AppendLine("        name = `"$(Escape-LuaString $a.Name)`",")
    [void]$sbArt.AppendLine("        damagedName = `"$(Escape-LuaString $a.DamagedName)`",")
    [void]$sbArt.AppendLine("        level = $($a.Level),")
    [void]$sbArt.AppendLine("        location = `"$(Escape-LuaString $loc)`",")
    [void]$sbArt.AppendLine("        xp = $xpStr,")
    [void]$sbArt.AppendLine("        chronotes = $($a.Chronotes),")
    [void]$sbArt.AppendLine("        materials = { $matStr }")
    [void]$sbArt.AppendLine("    },")
}

[void]$sbArt.AppendLine(@'
}

Artefacts.BY_DAMAGED_LOWER = {}
Artefacts.BY_BASE_LOWER = {}
Artefacts.BY_ID = {}

local function normalizeName(name)
    if not name then return "" end
    local s = string.lower(tostring(name))
    s = string.gsub(s, "<col=[^>]+>", "")
    s = string.gsub(s, "</col>", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

for idx, art in ipairs(Artefacts.LIST) do
    art.order = idx
    Artefacts.BY_DAMAGED_LOWER[normalizeName(art.damagedName)] = art
    Artefacts.BY_BASE_LOWER[normalizeName(art.name)] = art
    if art.id then
        Artefacts.BY_ID[art.id] = art
    end
end

local function extractDamagedBaseName(rawName)
    local norm = normalizeName(rawName)
    local base = string.match(norm, "^(.-)%s*%(damaged%)$")
    if base then
        return base, true
    end
    local unpowered = string.match(norm, "^(.-)%s*%(unpowered%)$")
    if unpowered then
        return unpowered, true
    end
    return norm, false
end

function Artefacts.normalize(name)
    return normalizeName(name)
end

function Artefacts.findById(id)
    if not id then return nil end
    return Artefacts.BY_ID[id]
end

function Artefacts.findByName(rawName)
    if not rawName or rawName == "" then
        return nil
    end
    local norm = normalizeName(rawName)
    local exact = Artefacts.BY_DAMAGED_LOWER[norm]
    if exact then
        return exact, true
    end

    local base, isDamagedSuffix = extractDamagedBaseName(rawName)
    if isDamagedSuffix then
        local byBase = Artefacts.BY_BASE_LOWER[base]
        if byBase then
            return byBase, true
        end
    else
        local byRestored = Artefacts.BY_BASE_LOWER[base]
        if byRestored then
            return byRestored, false
        end
    end
    return nil
end

function Artefacts.findRestoredByName(rawName)
    if not rawName or rawName == "" then return nil end
    local norm = normalizeName(rawName)
    return Artefacts.BY_BASE_LOWER[norm]
end

function Artefacts.findByObj(obj)
    if not obj then
        return nil
    end

    local okName, name = pcall(function() return obj.name end)
    if not okName or not name or name == "" then
        return nil
    end

    local entry = Artefacts.findByName(name)
    if entry then
        return entry
    end

    return nil
end

return Artefacts
'@)

$artPath = Join-Path $OutputDir "artefacts.lua"
[System.IO.File]::WriteAllText($artPath, $sbArt.ToString(), $utf8NoBom)
Write-Host "Wrote $artPath" -ForegroundColor Cyan

# 4. Fetch & Parse Collections
Write-Host "Fetching Collections data..." -ForegroundColor Cyan
$CollectionsUrl = "https://runescape.wiki/w/Collections"
$colHtml = Invoke-WikiFetch -Url $CollectionsUrl

$tableMatch = [regex]::Match($colHtml, '(?s)<table[^>]+data-tableid="Achievements list"[^>]*>(.*?)</table>')
$overview = @{}

if ($tableMatch.Success) {
    $rows = [regex]::Matches($tableMatch.Groups[1].Value, '(?s)<tr[^>]*>(.*?)</tr>')
    foreach ($r in $rows) {
        $mRowId = [regex]::Match($r.Value, 'data-rowid="([^"]+)"')
        $rawAchId = if ($mRowId.Success) { [System.Net.WebUtility]::HtmlDecode($mRowId.Groups[1].Value) } else { "" }
        $achNum = 0
        $achId = if ([int]::TryParse($rawAchId, [ref]$achNum)) { $achNum } else { 0 }

        $cells = [regex]::Matches($r.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>')
        if ($cells.Count -ge 8) {
            $lvl = [int]($cells[0].Groups[1].Value -replace '<[^>]+>', '').Trim()
            $colName = [System.Net.WebUtility]::HtmlDecode(($cells[1].Groups[1].Value -replace '<[^>]+>', '').Trim())
            $collector = [System.Net.WebUtility]::HtmlDecode(($cells[2].Groups[1].Value -replace '<[^>]+>', '').Trim())
            $oneTime = [System.Net.WebUtility]::HtmlDecode(($cells[3].Groups[1].Value -replace '<[^>]+>', '').Trim())
            if ($oneTime -eq "N/A") { $oneTime = "" }
            $recurring = [System.Net.WebUtility]::HtmlDecode(($cells[4].Groups[1].Value -replace '<[^>]+>', '').Trim())
            if ($recurring -eq "N/A") { $recurring = "" }
            $chronotes = [System.Net.WebUtility]::HtmlDecode(($cells[5].Groups[1].Value -replace '<[^>]+>', '').Trim())
            $isRepeatable = ($cells[6].Groups[1].Value -replace '<[^>]+>', '').Trim() -eq "Yes"
            $artCount = [int]($cells[7].Groups[1].Value -replace '<[^>]+>', '').Trim()

            $overview[$colName] = @{
                Level = $lvl
                Name = $colName
                Collector = $collector
                OneTimeReward = $oneTime
                RecurringReward = $recurring
                Chronotes = $chronotes
                IsRepeatable = $isRepeatable
                ExpectedCount = $artCount
                AchievementId = $achId
            }
        }
    }
}

$sections = [regex]::Split($colHtml, '(?=<table[^>]+data-tableid="Archaeology Collection - )')
$collectionsList = New-Object System.Collections.Generic.List[object]

for ($i = 1; $i -lt $sections.Count; $i++) {
    $sec = $sections[$i]
    $mName = [regex]::Match($sec, 'data-tableid="Archaeology Collection - ([^"]+)"')
    if ($mName.Success) {
        $cName = [System.Net.WebUtility]::HtmlDecode($mName.Groups[1].Value.Trim())
        $artRows = [regex]::Matches($sec, '(?s)<tr data-rowid="([^"]+)">\s*<td>\s*(\d+)\s*</td>')
        $artefacts = New-Object System.Collections.Generic.List[string]
        foreach ($ar in $artRows) {
            $artName = [System.Net.WebUtility]::HtmlDecode($ar.Groups[1].Value.Trim())
            if (-not $artefacts.Contains($artName)) {
                $artefacts.Add($artName)
            }
        }

        $info = $overview[$cName]
        $lvl = if ($info) { $info.Level } else { 0 }
        $collector = if ($info) { $info.Collector } else { "Unknown" }
        $oneTime = if ($info) { $info.OneTimeReward } else { "" }
        $recurring = if ($info) { $info.RecurringReward } else { "" }
        $chronotes = if ($info) { $info.Chronotes } else { "" }
        $isRepeatable = if ($info) { $info.IsRepeatable } else { $true }
        $achId = if ($info) { $info.AchievementId } else { 0 }

        $benefitType = ""
        $specialBenefit = ""

        if ($oneTime -like "*Seal of the Praefectus Praetorio*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Font of Life (+500 Max LP)"
        } elseif ($oneTime -like "*Abyssal thread*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Pouch Protector (Pouches never degrade)"
        } elseif ($oneTime -like "*Lock of hair*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Inspire Genius (+2% Artisan XP)"
        } elseif ($oneTime -like "*Guardian's tear*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Inspire Love (+2% Gathering XP)"
        } elseif ($oneTime -like "*Oo'glog Wellspring*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Permanent Salt-water Thermal Buff"
        } elseif ($oneTime -like "*King Oberon's moonshroom spores*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Inspire Effort (+2% Support XP)"
        } elseif ($oneTime -like "*Ariadne's Diadem*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Inspire Awe (+2% Combat XP)"
        } elseif ($oneTime -like "*Petasos*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Nexus Mod (Abyssal Nexus buff)"
        } elseif ($oneTime -like "*Helm of Terror*") {
            $benefitType = "relic"
            $specialBenefit = "Relic: Death Ward Piece (-10% damage at low HP)"
        } elseif ($oneTime -like "*Inquisitor staff piece*") {
            $benefitType = "weapon"
            $specialBenefit = "T97 Weapon: Inquisitor Staff Piece"
        } elseif ($oneTime -like "*Howl's Thinking Cap*") {
            $benefitType = "mystery"
            $specialBenefit = "Mystery: Howl's Workshop Blueprint Access"
        } elseif ($oneTime -like "*Koschei's needle*") {
            $benefitType = "mystery"
            $specialBenefit = "Mystery: Blessing of Koschei / Monolith"
        } elseif ($oneTime -like "*The Mortal Cup*" -or $oneTime -like "*Kaladanda*" -or $oneTime -like "*Amascut's Enchanted Gem*" -or $oneTime -like "*Cosmic pyramid*" -or $oneTime -like "*Pastkeeper's tapestry*") {
            $benefitType = "mystery"
            $specialBenefit = "Mystery Unlock: $oneTime"
        } elseif ($recurring -like "*Tetracompass piece*") {
            $benefitType = "tetra"
            $specialBenefit = "Tetracompass Piece Farm"
        }

        $collectionsList.Add([PSCustomObject]@{
            Name            = $cName
            Level           = $lvl
            Collector       = $collector
            OneTimeReward   = $oneTime
            RecurringReward = $recurring
            Chronotes       = $chronotes
            IsRepeatable    = $isRepeatable
            BenefitType     = $benefitType
            SpecialBenefit  = $specialBenefit
            AchievementId   = $achId
            Artefacts       = $artefacts
        })
    }
}

$sbCol = New-Object System.Text.StringBuilder
[void]$sbCol.AppendLine("-- data/collections.lua")
[void]$sbCol.AppendLine("-- Auto-generated by scripts/Update-WikiData.ps1 from official RuneScape Wiki data")
[void]$sbCol.AppendLine("-- Contains all 79 RS3 Archaeology collections, collectors, levels, rewards, and required artefacts.")
[void]$sbCol.AppendLine("")
[void]$sbCol.AppendLine("local Collections = {}")
[void]$sbCol.AppendLine("")
[void]$sbCol.AppendLine("Collections.LIST = {")

$sortedCols = $collectionsList | Sort-Object { $_.Level }, { $_.Name }
foreach ($c in $sortedCols) {
    $escName = Escape-LuaString $c.Name
    $escCollector = Escape-LuaString $c.Collector
    $escOneTime = Escape-LuaString $c.OneTimeReward
    $escRecurring = Escape-LuaString $c.RecurringReward
    $escChronotes = Escape-LuaString $c.Chronotes
    $escBenefit = Escape-LuaString $c.SpecialBenefit
    $escType = Escape-LuaString $c.BenefitType
    $isRep = if ($c.IsRepeatable) { "true" } else { "false" }
    
    $artLines = ($c.Artefacts | ForEach-Object { '            "' + (Escape-LuaString $_) + '"' }) -join ",`n"

    [void]$sbCol.AppendLine("    {")
    [void]$sbCol.AppendLine("        name = `"$escName`",")
    [void]$sbCol.AppendLine("        level = $($c.Level),")
    [void]$sbCol.AppendLine("        collector = `"$escCollector`",")
    [void]$sbCol.AppendLine("        oneTimeReward = `"$escOneTime`",")
    [void]$sbCol.AppendLine("        recurringReward = `"$escRecurring`",")
    [void]$sbCol.AppendLine("        chronotes = `"$escChronotes`",")
    [void]$sbCol.AppendLine("        isRepeatable = $isRep,")
    [void]$sbCol.AppendLine("        achievementId = $($c.AchievementId),")
    [void]$sbCol.AppendLine("        benefitType = `"$escType`",")
    [void]$sbCol.AppendLine("        specialBenefit = `"$escBenefit`",")
    [void]$sbCol.AppendLine("        artefacts = {")
    [void]$sbCol.AppendLine($artLines)
    [void]$sbCol.AppendLine("        }")
    [void]$sbCol.AppendLine("    },")
}

[void]$sbCol.AppendLine("}")
[void]$sbCol.AppendLine("")
[void]$sbCol.AppendLine("Collections.BY_NAME = {}")
[void]$sbCol.AppendLine("for _, col in ipairs(Collections.LIST) do")
[void]$sbCol.AppendLine("    Collections.BY_NAME[col.name] = col")
[void]$sbCol.AppendLine("end")
[void]$sbCol.AppendLine("")
[void]$sbCol.AppendLine("return Collections")

$colPath = Join-Path $OutputDir "collections.lua"
[System.IO.File]::WriteAllText($colPath, $sbCol.ToString(), $utf8NoBom)
Write-Host "Wrote $colPath ($($collectionsList.Count) collections)" -ForegroundColor Cyan
Write-Host "Wiki data update complete!" -ForegroundColor Green
