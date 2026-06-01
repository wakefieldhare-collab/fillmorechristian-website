param(
    [string]$FeedUrl = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast",
    [string]$SiteUrl = "https://www.fillmorechristian.org",
    [switch]$DownloadAudio
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$exportDir = Join-Path $root "exports\thechurchco-podcast"
$audioDir = Join-Path $exportDir "audio"
$legacyFeedDir = Join-Path $root "podcast-category\fillmore-christian\feed"
$legacyFeedPath = Join-Path $legacyFeedDir "podcast"
$publicFeedPath = Join-Path $root "podcast.xml"
$feedAliasPath = Join-Path $root "feed.xml"
$manifestPath = Join-Path $exportDir "manifest.csv"
$rawFeedPath = Join-Path $exportDir "thechurchco-feed-original.xml"

function Repair-Mojibake {
    param([string]$Text)

    $badDash = [string]::Concat([char]0x00e2, [char]0x20ac, [char]0x201c)
    $badEmDash = [string]::Concat([char]0x00e2, [char]0x20ac, [char]0x201d)
    $badApostrophe = [string]::Concat([char]0x00e2, [char]0x20ac, [char]0x2122)
    $badOpenQuote = [string]::Concat([char]0x00e2, [char]0x20ac, [char]0x0153)
    $badCloseQuote = [string]::Concat([char]0x00e2, [char]0x20ac, [char]0x009d)

    return $Text.Replace($badDash, "-").
        Replace($badEmDash, "-").
        Replace($badApostrophe, "'").
        Replace($badOpenQuote, '"').
        Replace($badCloseQuote, '"')
}

function Normalize-SpeakerName {
    param([string]$Text)
    $speaker = ($Text -replace "\s+", " ").Trim()
    if (-not $speaker) { return "Fillmore Christian" }
    if ($speaker -match "^(?i:thechurchco)") { return "Fillmore Christian" }
    return $speaker
}

function Normalize-ItemAuthors {
    param([System.Xml.XmlElement[]]$Items)

    foreach ($item in $Items) {
        foreach ($child in @($item.ChildNodes)) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                ($child.LocalName -eq "author" -or $child.LocalName -eq "creator")) {
                $child.InnerText = Normalize-SpeakerName $child.InnerText
            }
        }
    }
}

New-Item -ItemType Directory -Force -Path $exportDir, $legacyFeedDir | Out-Null
if ($DownloadAudio) {
    New-Item -ItemType Directory -Force -Path $audioDir | Out-Null
}

Write-Host "Fetching podcast feed: $FeedUrl"
$response = Invoke-WebRequest -Uri $FeedUrl -UseBasicParsing -MaximumRedirection 5
$response.Content | Set-Content -LiteralPath $rawFeedPath -Encoding UTF8

[xml]$feed = $response.Content
$channel = $feed.rss.channel

if (-not $channel) {
    throw "Feed did not contain rss/channel."
}

$ns = New-Object System.Xml.XmlNamespaceManager($feed.NameTable)
$ns.AddNamespace("atom", "http://www.w3.org/2005/Atom")
$ns.AddNamespace("itunes", "http://www.itunes.com/dtds/podcast-1.0.dtd")

$canonicalFeedUrl = "$SiteUrl/podcast-category/fillmore-christian/feed/podcast"
$atomLink = $channel.SelectSingleNode("atom:link[@rel='self']", $ns)
if ($atomLink) {
    $atomLink.SetAttribute("href", $canonicalFeedUrl)
}

$items = @($channel.item)
Normalize-ItemAuthors $items
$rows = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $items.Count; $i++) {
    $item = $items[$i]
    $enclosure = $item.enclosure
    $audioUrl = ""
    $localFile = ""

    if ($enclosure -and $enclosure.url) {
        $audioUrl = [string]$enclosure.url
        if ($audioUrl.StartsWith("http://")) {
            $audioUrl = "https://" + $audioUrl.Substring(7)
            $enclosure.SetAttribute("url", $audioUrl)
        }

        $uri = [Uri]$audioUrl
        $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        $fileName = $fileName -replace '[^\w\.\-]+', '-'
        $localFile = "audio/$fileName"

        if ($DownloadAudio) {
            $target = Join-Path $audioDir $fileName
            if (Test-Path -LiteralPath $target) {
                Write-Host "Skipping existing audio: $fileName"
            } else {
                Write-Host ("Downloading {0}/{1}: {2}" -f ($i + 1), $items.Count, $fileName)
                Invoke-WebRequest -Uri $audioUrl -OutFile $target -UseBasicParsing -MaximumRedirection 5
            }
        }
    }

    $rows.Add([pscustomobject]@{
        Title = Repair-Mojibake ([string]$item.title)
        PubDate = [string]$item.pubDate
        Guid = [string]$item.guid.'#text'
        EnclosureUrl = $audioUrl
        EnclosureLength = if ($enclosure) { [string]$enclosure.length } else { "" }
        LocalAudioFile = $localFile
    })
}

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$settings.Indent = $true

foreach ($path in @($legacyFeedPath, $publicFeedPath, $feedAliasPath)) {
    $writer = [System.Xml.XmlWriter]::Create($path, $settings)
    $feed.Save($writer)
    $writer.Close()

    $normalized = (Get-Content -Raw -LiteralPath $path) -replace "http://thechurchco-production\.s3\.amazonaws\.com", "https://thechurchco-production.s3.amazonaws.com"
    $normalized = Repair-Mojibake $normalized
    $normalized | Set-Content -LiteralPath $path -Encoding UTF8
}

$rows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8

Write-Host "Podcast items: $($items.Count)"
Write-Host "Wrote legacy feed: $legacyFeedPath"
Write-Host "Wrote public feed copy: $publicFeedPath"
Write-Host "Wrote feed alias: $feedAliasPath"
Write-Host "Wrote manifest: $manifestPath"
if ($DownloadAudio) {
    Write-Host "Downloaded audio folder: $audioDir"
} else {
    Write-Host "Audio download skipped. Re-run with -DownloadAudio before canceling TheChurchCo."
}
