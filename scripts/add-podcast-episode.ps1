param(
    [Parameter(Mandatory = $true)]
    [string]$AudioPath,

    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [datetime]$Date,

    [string]$Description = "",
    [string]$Speaker = "Fillmore Christian",
    [string]$Slug = "",
    [string]$FileName = "",
    [string]$PublishTimeLocal = "",
    [string]$TimeZoneId = "Central Standard Time",
    [string]$BaseAudioUrl = "https://www.fillmorechristian.org/media",
    [string]$Bucket = "",
    [switch]$UploadR2,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$audioDir = Join-Path $root "exports\thechurchco-podcast\audio"
$inventoryPath = Join-Path $root "exports\thechurchco-podcast\audio-inventory.csv"
$manifestPath = Join-Path $root "exports\thechurchco-podcast\manifest.csv"
$r2ManifestPath = Join-Path $root "exports\thechurchco-podcast\r2-audio-manifest.csv"
$feedPaths = @(
    "podcast-category\fillmore-christian\feed\podcast",
    "podcast.xml",
    "feed.xml"
)

function ConvertTo-SafeFileName {
    param([string]$Name)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    $safeBase = ($base -replace "[^\w\.-]+", "-").Trim("-")
    if (-not $safeBase) {
        throw "Could not create a safe file name from $Name"
    }
    return "$safeBase$extension"
}

function ConvertTo-Slug {
    param([string]$Text)

    $slugText = $Text.ToLowerInvariant()
    $slugText = $slugText -replace "'", ""
    $slugText = $slugText -replace "[^a-z0-9]+", "-"
    $slugText = $slugText.Trim("-")
    if (-not $slugText) {
        throw "Could not create an episode slug from title: $Text"
    }
    return $slugText
}

function Get-WranglerInvocation {
    $wranglerCommand = Get-Command wrangler -ErrorAction SilentlyContinue
    if ($wranglerCommand) {
        return [pscustomobject]@{
            Command = $wranglerCommand.Source
            PrefixArgs = @()
            Label = "wrangler"
        }
    }

    $npxCommand = Get-Command npx -ErrorAction SilentlyContinue
    if ($npxCommand) {
        return [pscustomobject]@{
            Command = $npxCommand.Source
            PrefixArgs = @("wrangler")
            Label = "npx wrangler"
        }
    }

    throw "wrangler is not installed or available through npx."
}

function Assert-CloudflareAuth {
    param([object]$Wrangler)

    $whoamiOutput = & $Wrangler.Command @($Wrangler.PrefixArgs) whoami 2>&1
    if ($LASTEXITCODE -ne 0 -or ($whoamiOutput -join "`n") -match "not authenticated") {
        throw "Cloudflare is not authenticated. Run npx wrangler login first."
    }
}

function Get-ContentType {
    param([string]$Name)

    $lower = $Name.ToLowerInvariant()
    if ($lower.EndsWith(".m4a")) { return "audio/mp4" }
    if ($lower.EndsWith(".wav")) { return "audio/wav" }
    return "audio/mpeg"
}

function Format-PubDate {
    param(
        [datetime]$DateValue,
        [string]$TimeText,
        [string]$ZoneId
    )

    $time = if ($TimeText) {
        [TimeSpan]::Parse($TimeText)
    } else {
        (Get-Item -LiteralPath $resolvedAudioPath).LastWriteTime.TimeOfDay
    }

    $localUnspecified = [datetime]::SpecifyKind($DateValue.Date.Add($time), [System.DateTimeKind]::Unspecified)
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($ZoneId)
    $offset = $zone.GetUtcOffset($localUnspecified)
    $dateOffset = [datetimeoffset]::new($localUnspecified, $offset)
    return $dateOffset.ToUniversalTime().ToString("ddd, dd MMM yyyy HH:mm:ss +0000", [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))
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
        if (-not $NamespaceUri -and $child.NamespaceURI) { continue }
        return $child
    }

    return $null
}

function Add-TextElement {
    param(
        [xml]$Document,
        [System.Xml.XmlElement]$Parent,
        [string]$LocalName,
        [string]$Value,
        [string]$NamespaceUri = "",
        [string]$Prefix = "",
        [switch]$CData
    )

    $element = if ($NamespaceUri) {
        $Document.CreateElement($Prefix, $LocalName, $NamespaceUri)
    } else {
        $Document.CreateElement($LocalName)
    }

    if ($CData) {
        [void]$element.AppendChild($Document.CreateCDataSection($Value))
    } else {
        $element.InnerText = $Value
    }

    [void]$Parent.AppendChild($element)
    return $element
}

function New-PodcastItem {
    param(
        [xml]$Document,
        [string]$ItemTitle,
        [string]$ItemLink,
        [string]$ItemPubDate,
        [string]$ItemDescription,
        [string]$ItemSpeaker,
        [string]$ItemAudioUrl,
        [string]$ItemAudioLength,
        [string]$ItemAudioType
    )

    $contentNs = "http://purl.org/rss/1.0/modules/content/"
    $dcNs = "http://purl.org/dc/elements/1.1/"
    $itunesNs = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    $googleNs = "http://www.google.com/schemas/play-podcasts/1.0"

    $item = $Document.CreateElement("item")
    [void](Add-TextElement $Document $item "title" $ItemTitle)
    [void](Add-TextElement $Document $item "link" $ItemLink)
    [void](Add-TextElement $Document $item "pubDate" $ItemPubDate)
    [void](Add-TextElement $Document $item "creator" $ItemSpeaker $dcNs "dc")
    $guid = Add-TextElement $Document $item "guid" $ItemLink
    $guid.SetAttribute("isPermaLink", "false")
    [void](Add-TextElement $Document $item "description" $ItemDescription "" "" -CData)
    [void](Add-TextElement $Document $item "subtitle" $ItemDescription $itunesNs "itunes" -CData)
    [void](Add-TextElement $Document $item "encoded" $ItemDescription $contentNs "content" -CData)
    [void](Add-TextElement $Document $item "summary" $ItemDescription $itunesNs "itunes" -CData)
    [void](Add-TextElement $Document $item "description" $ItemDescription $googleNs "googleplay" -CData)

    $enclosure = $Document.CreateElement("enclosure")
    $enclosure.SetAttribute("url", $ItemAudioUrl)
    $enclosure.SetAttribute("length", $ItemAudioLength)
    $enclosure.SetAttribute("type", $ItemAudioType)
    [void]$item.AppendChild($enclosure)

    [void](Add-TextElement $Document $item "explicit" "no" $itunesNs "itunes")
    [void](Add-TextElement $Document $item "explicit" "no" $googleNs "googleplay")
    [void](Add-TextElement $Document $item "block" "no" $itunesNs "itunes")
    [void](Add-TextElement $Document $item "block" "no" $googleNs "googleplay")
    [void](Add-TextElement $Document $item "author" $ItemSpeaker $itunesNs "itunes")

    return $item
}

function Save-XmlDocument {
    param(
        [xml]$Document,
        [string]$Path
    )

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    $Document.Save($writer)
    $writer.Close()
}

function Update-Feed {
    param(
        [string]$Path,
        [string]$ItemTitle,
        [string]$ItemLink,
        [string]$ItemPubDate,
        [string]$ItemDescription,
        [string]$ItemSpeaker,
        [string]$ItemAudioUrl,
        [string]$ItemAudioLength,
        [string]$ItemAudioType
    )

    [xml]$feed = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    $channel = $feed.rss.channel

    $oldItems = @(
        $channel.item |
            Where-Object {
                ([string]$_.link -eq $ItemLink) -or
                ([string]$_.guid -eq $ItemLink) -or
                ($_.enclosure -and [string]$_.enclosure.url -eq $ItemAudioUrl)
            }
    )
    foreach ($oldItem in $oldItems) {
        [void]$channel.RemoveChild($oldItem)
    }

    $newItem = New-PodcastItem `
        -Document $feed `
        -ItemTitle $ItemTitle `
        -ItemLink $ItemLink `
        -ItemPubDate $ItemPubDate `
        -ItemDescription $ItemDescription `
        -ItemSpeaker $ItemSpeaker `
        -ItemAudioUrl $ItemAudioUrl `
        -ItemAudioLength $ItemAudioLength `
        -ItemAudioType $ItemAudioType

    $firstItem = @($channel.item | Select-Object -First 1)[0]
    if ($firstItem) {
        [void]$channel.InsertBefore($newItem, $firstItem)
    } else {
        [void]$channel.AppendChild($newItem)
    }

    $lastBuildDate = Get-FirstChildElement $channel "lastBuildDate"
    if ($lastBuildDate) {
        $lastBuildDate.InnerText = $ItemPubDate
    }

    Save-XmlDocument $feed $Path
}

function Update-AudioInventory {
    param(
        [string]$Path,
        [string]$AudioFileName,
        [int64]$Size,
        [string]$Hash
    )

    $rows = @()
    if (Test-Path -LiteralPath $Path) {
        $rows = @(Import-Csv -LiteralPath $Path | Where-Object { $_.FileName -ne $AudioFileName })
    }

    $rows += [pscustomobject]@{
        FileName = $AudioFileName
        SizeBytes = $Size
        SHA256 = $Hash
    }

    $rows |
        Sort-Object FileName |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Update-PodcastManifest {
    param(
        [string]$Path,
        [string]$ItemTitle,
        [string]$ItemPubDate,
        [string]$ItemGuid,
        [string]$ItemAudioUrl,
        [string]$ItemAudioLength,
        [string]$AudioFileName
    )

    $rows = @()
    if (Test-Path -LiteralPath $Path) {
        $rows = @(Import-Csv -LiteralPath $Path | Where-Object {
            $_.Guid -ne $ItemGuid -and $_.EnclosureUrl -ne $ItemAudioUrl
        })
    }

    $rows += [pscustomobject]@{
        Title = $ItemTitle
        PubDate = $ItemPubDate
        Guid = $ItemGuid
        EnclosureUrl = $ItemAudioUrl
        EnclosureLength = $ItemAudioLength
        LocalAudioFile = "audio/$AudioFileName"
    }

    $rows |
        Sort-Object @{ Expression = {
            try { [datetimeoffset]::Parse($_.PubDate).ToUnixTimeSeconds() } catch { 0 }
        }; Descending = $true } |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $AudioPath)) {
    throw "Audio file not found: $AudioPath"
}

$resolvedAudioPath = (Resolve-Path -LiteralPath $AudioPath).Path
$sourceAudio = Get-Item -LiteralPath $resolvedAudioPath

if (-not (Test-Path -LiteralPath $audioDir)) {
    New-Item -ItemType Directory -Force -Path $audioDir | Out-Null
}

$targetFileName = if ($FileName) { ConvertTo-SafeFileName $FileName } else { ConvertTo-SafeFileName $sourceAudio.Name }
$targetPath = Join-Path $audioDir $targetFileName
Copy-Item -LiteralPath $resolvedAudioPath -Destination $targetPath -Force

$targetAudio = Get-Item -LiteralPath $targetPath
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToUpperInvariant()
$episodeSlug = if ($Slug) { ConvertTo-Slug $Slug } else { ConvertTo-Slug $Title }
$episodeUrl = "https://www.fillmorechristian.org/episode/$episodeSlug/"
$audioUrl = "$($BaseAudioUrl.TrimEnd("/"))/$targetFileName"
$pubDate = Format-PubDate -DateValue $Date -TimeText $PublishTimeLocal -ZoneId $TimeZoneId
$contentType = Get-ContentType $targetFileName

Update-AudioInventory `
    -Path $inventoryPath `
    -AudioFileName $targetFileName `
    -Size $targetAudio.Length `
    -Hash $hash

Update-PodcastManifest `
    -Path $manifestPath `
    -ItemTitle $Title `
    -ItemPubDate $pubDate `
    -ItemGuid $episodeUrl `
    -ItemAudioUrl $audioUrl `
    -ItemAudioLength $targetAudio.Length `
    -AudioFileName $targetFileName

foreach ($relativeFeedPath in $feedPaths) {
    $feedPath = Join-Path $root $relativeFeedPath
    if (-not (Test-Path -LiteralPath $feedPath)) {
        throw "Feed file not found: $feedPath"
    }

    Update-Feed `
        -Path $feedPath `
        -ItemTitle $Title `
        -ItemLink $episodeUrl `
        -ItemPubDate $pubDate `
        -ItemDescription $Description `
        -ItemSpeaker $Speaker `
        -ItemAudioUrl $audioUrl `
        -ItemAudioLength $targetAudio.Length `
        -ItemAudioType $contentType
}

& (Join-Path $PSScriptRoot "build-r2-audio-manifest.ps1") -BaseAudioUrl $BaseAudioUrl

& (Join-Path $PSScriptRoot "refresh-podcast-content.ps1") -SkipBuild:$SkipBuild

if ($UploadR2) {
    if (-not $Bucket) {
        throw "Pass -Bucket when using -UploadR2."
    }

    $wrangler = Get-WranglerInvocation
    Assert-CloudflareAuth -Wrangler $wrangler
    Write-Host "Uploading $targetFileName -> r2://$Bucket/$targetFileName"
    & $wrangler.Command @($wrangler.PrefixArgs) r2 object put "$Bucket/$targetFileName" --file $targetPath --content-type $contentType --remote --force
    if ($LASTEXITCODE -ne 0) {
        throw "R2 upload failed for $targetPath"
    }
}

Write-Host ""
Write-Host "Added podcast episode:"
Write-Host "  Title: $Title"
Write-Host "  Episode: $episodeUrl"
Write-Host "  Audio: $audioUrl"
Write-Host "  File: $targetPath"
Write-Host "  R2 manifest: $r2ManifestPath"
