param(
    [string]$AudioDir = "exports\thechurchco-podcast\audio",
    [string]$OutputPath = "exports\thechurchco-podcast\audio-duration-inventory.csv",
    [string[]]$FeedPaths = @(
        "podcast-category\fillmore-christian\feed\podcast",
        "podcast.xml",
        "feed.xml"
    )
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$audioPath = if ([System.IO.Path]::IsPathRooted($AudioDir)) { $AudioDir } else { Join-Path $root $AudioDir }
$outputFile = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $root $OutputPath }

# The duration inventory is the durable record. The local audio folder is only a
# working folder for newly added sermons, so it may be missing or partial; files
# present there add or refresh rows, and every other row is kept as recorded.
$hasAudioDir = Test-Path -LiteralPath $audioPath

function ConvertTo-LocalAudioFileName {
    param([string]$Url)

    if (-not $Url) { return "" }
    try {
        $uri = [Uri]$Url
        $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        return $fileName -replace '[^\w\.\-]+', '-'
    } catch {
        return ""
    }
}

function ConvertTo-DurationSeconds {
    param([string]$DurationText)

    if (-not $DurationText) { return 0 }
    $clean = ($DurationText -replace '[^\d:]', '').Trim()
    if (-not $clean) { return 0 }

    $parts = @($clean -split ":" | ForEach-Object { [int]$_ })
    if ($parts.Count -eq 3) {
        return ($parts[0] * 3600) + ($parts[1] * 60) + $parts[2]
    }
    if ($parts.Count -eq 2) {
        return ($parts[0] * 60) + $parts[1]
    }
    if ($parts.Count -eq 1) {
        return $parts[0]
    }

    return 0
}

function Format-Duration {
    param([int]$Seconds)

    if ($Seconds -le 0) { return "" }
    $span = [TimeSpan]::FromSeconds($Seconds)
    return "{0:00}:{1:00}:{2:00}" -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
}

function Get-FirstChildElement {
    param(
        [System.Xml.XmlElement]$Parent,
        [string]$LocalName,
        [string]$NamespaceUri = ""
    )

    foreach ($child in @($Parent.ChildNodes)) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        if ($child.LocalName -ne $LocalName) { continue }
        if ($NamespaceUri -and $child.NamespaceURI -ne $NamespaceUri) { continue }
        return $child
    }

    return $null
}

function Set-ItunesDuration {
    param(
        [xml]$Feed,
        [System.Xml.XmlElement]$Item,
        [string]$Duration
    )

    $itunesNs = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    $durationElement = Get-FirstChildElement -Parent $Item -LocalName "duration" -NamespaceUri $itunesNs
    if (-not $durationElement) {
        $durationElement = $Feed.CreateElement("itunes", "duration", $itunesNs)
        [void]$Item.AppendChild($durationElement)
    }

    if ($durationElement.InnerText -ne $Duration) {
        $durationElement.InnerText = $Duration
        return 1
    }

    return 0
}

$durationByFileName = @{}
if (Test-Path -LiteralPath $outputFile) {
    foreach ($row in @(Import-Csv -LiteralPath $outputFile)) {
        if ($row.FileName -and [int]$row.DurationSeconds -gt 0) {
            $durationByFileName[$row.FileName] = [pscustomobject]@{
                FileName = $row.FileName
                Duration = $row.Duration
                DurationSeconds = [int]$row.DurationSeconds
                SizeBytes = [int64]$row.SizeBytes
            }
        }
    }
}

$localFiles = if ($hasAudioDir) { @(Get-ChildItem -LiteralPath $audioPath -File | Sort-Object Name) } else { @() }
$namespace = $null
if ($localFiles.Count -gt 0) {
    $shell = New-Object -ComObject Shell.Application
    $namespace = $shell.Namespace([string]$audioPath)
    if (-not $namespace) {
        throw "Could not read audio metadata directory: $audioPath"
    }
}

foreach ($file in $localFiles) {
    $item = $namespace.ParseName($file.Name)
    if (-not $item) {
        continue
    }

    $durationText = [string]$namespace.GetDetailsOf($item, 27)
    $durationSeconds = ConvertTo-DurationSeconds $durationText
    $duration = Format-Duration $durationSeconds
    if (-not $duration) {
        continue
    }

    $durationByFileName[$file.Name] = [pscustomobject]@{
        FileName = $file.Name
        Duration = $duration
        DurationSeconds = $durationSeconds
        SizeBytes = $file.Length
    }
}

$durationRows = @($durationByFileName.Values | Sort-Object FileName)
if ($durationRows.Count -eq 0) {
    throw "No audio durations are recorded in $OutputPath or readable from $audioPath"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFile) | Out-Null
$durationRows | Export-Csv -LiteralPath $outputFile -NoTypeInformation -Encoding UTF8

foreach ($relativePath in $FeedPaths) {
    $path = if ([System.IO.Path]::IsPathRooted($relativePath)) { $relativePath } else { Join-Path $root $relativePath }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Feed file not found: $path"
    }

    [xml]$feed = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    $updated = 0
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($item in @($feed.rss.channel.item)) {
        if (-not $item.enclosure -or -not $item.enclosure.url) {
            continue
        }

        $fileName = ConvertTo-LocalAudioFileName ([string]$item.enclosure.url)
        if (-not $fileName -or -not $durationByFileName.ContainsKey($fileName)) {
            $missing.Add([string]$item.title)
            continue
        }

        $updated += Set-ItunesDuration -Feed $feed -Item $item -Duration $durationByFileName[$fileName].Duration
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($path, $settings)
    $feed.Save($writer)
    $writer.Close()

    if ($missing.Count -gt 0) {
        Write-Warning "$($missing.Count) feed item(s) in $relativePath did not match a local duration: $($missing -join '; ')"
    }
    Write-Host "Updated $updated podcast duration field(s) in $relativePath"
}

Write-Host "Wrote $($durationRows.Count) audio duration row(s) to $OutputPath"
