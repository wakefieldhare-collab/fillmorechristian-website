param(
    [string]$PodcastManifestPath = "exports\thechurchco-podcast\manifest.csv",
    [string]$InventoryPath = "exports\thechurchco-podcast\audio-inventory.csv",
    [string]$AudioDir = "exports\thechurchco-podcast\audio",
    [string]$OutputPath = "exports\thechurchco-podcast\r2-audio-manifest.csv",
    [string]$Prefix = "",
    [string]$BaseAudioUrl = ""
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $root $Path
}

function ConvertTo-LocalAudioFileName {
    param([string]$Url)

    $uri = [Uri]$Url
    $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    return $fileName -replace '[^\w\.\-]+', '-'
}

function Get-ContentType {
    param([string]$FileName)

    $lower = $FileName.ToLowerInvariant()
    if ($lower.EndsWith(".m4a")) { return "audio/mp4" }
    if ($lower.EndsWith(".wav")) { return "audio/wav" }
    return "audio/mpeg"
}

$manifestPath = Resolve-RepoPath $PodcastManifestPath
$inventoryPath = Resolve-RepoPath $InventoryPath
$audioPath = Resolve-RepoPath $AudioDir
$outPath = Resolve-RepoPath $OutputPath

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Podcast manifest not found: $manifestPath"
}
if (-not (Test-Path -LiteralPath $inventoryPath)) {
    throw "Audio inventory not found: $inventoryPath"
}
if (-not (Test-Path -LiteralPath $audioPath)) {
    throw "Audio directory not found: $audioPath"
}

$podcastRows = @(Import-Csv -LiteralPath $manifestPath)
$inventoryRows = @(Import-Csv -LiteralPath $inventoryPath)
$inventoryByName = @{}
foreach ($row in $inventoryRows) {
    if ($inventoryByName.ContainsKey($row.FileName)) {
        throw "Duplicate audio inventory entry for $($row.FileName)"
    }
    $inventoryByName[$row.FileName] = $row
}

$references = @(
    foreach ($row in $podcastRows) {
        if (-not $row.EnclosureUrl) {
            continue
        }

        $fileName = ConvertTo-LocalAudioFileName $row.EnclosureUrl
        if (-not $fileName) {
            throw "Could not derive local filename for enclosure URL: $($row.EnclosureUrl)"
        }

        [pscustomobject]@{
            Title = $row.Title
            EnclosureUrl = $row.EnclosureUrl
            FileName = $fileName
        }
    }
)

if ($references.Count -eq 0) {
    throw "No enclosure URLs found in podcast manifest: $manifestPath"
}

$collisions = @(
    $references |
        Group-Object FileName |
        Where-Object { @($_.Group.EnclosureUrl | Select-Object -Unique).Count -gt 1 }
)
if ($collisions.Count -gt 0) {
    $details = $collisions | ForEach-Object {
        "$($_.Name): $(@($_.Group.EnclosureUrl | Select-Object -Unique) -join ', ')"
    }
    throw "Multiple distinct source URLs collapse to the same local filename: $($details -join '; ')"
}

$normalizedPrefix = ($Prefix -replace "\\", "/").Trim("/")
$base = $BaseAudioUrl.TrimEnd("/")
$rows = @(
    foreach ($group in ($references | Group-Object FileName | Sort-Object Name)) {
        $fileName = $group.Name
        $filePath = Join-Path $audioPath $fileName
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Audio file missing for manifest entry: $filePath"
        }

        $file = Get-Item -LiteralPath $filePath
        if (-not $inventoryByName.ContainsKey($fileName)) {
            throw "Audio inventory is missing an entry for $fileName"
        }

        $inventory = $inventoryByName[$fileName]
        if ([int64]$inventory.SizeBytes -ne $file.Length) {
            throw "Audio size mismatch for $fileName`: inventory has $($inventory.SizeBytes), local file has $($file.Length)"
        }

        $objectKey = if ($normalizedPrefix) { "$normalizedPrefix/$fileName" } else { $fileName }
        $sourceUrls = @($group.Group.EnclosureUrl | Select-Object -Unique)
        $titles = @($group.Group.Title | Where-Object { $_ } | Select-Object -Unique)

        [pscustomobject]@{
            ObjectKey = $objectKey
            FileName = $fileName
            ContentType = Get-ContentType $fileName
            SizeBytes = $file.Length
            SHA256 = $inventory.SHA256
            FeedReferenceCount = $group.Count
            SourceUrlCount = $sourceUrls.Count
            SourceUrls = $sourceUrls -join " | "
            EpisodeTitles = $titles -join " | "
            PublicUrl = if ($base) { "$base/$objectKey" } else { "" }
        }
    }
)

$outDir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$rows | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8

$totalBytes = ($rows | Measure-Object -Property SizeBytes -Sum).Sum
Write-Host "Wrote R2 audio manifest: $outPath"
Write-Host "$($rows.Count) objects, $($references.Count) feed references, $totalBytes bytes"
