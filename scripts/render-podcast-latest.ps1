param(
    [string]$FeedPath = "podcast-category\fillmore-christian\feed\podcast",
    [string]$PodcastPage = "podcast.html",
    [int]$Count = 3
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$feedFile = Join-Path $root $FeedPath
$pageFile = Join-Path $root $PodcastPage

if (-not (Test-Path -LiteralPath $feedFile)) {
    throw "Feed file not found: $feedFile"
}

if (-not (Test-Path -LiteralPath $pageFile)) {
    throw "Podcast page not found: $pageFile"
}

function HtmlEncode {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Clean-Speaker {
    param([string]$Text)
    $speaker = ($Text -replace "\s+", " ").Trim()
    if (-not $speaker) { return "Fillmore Christian" }
    if ($speaker -match "^(?i:thechurchco)") { return "Fillmore Christian" }
    return $speaker
}

function Format-Date {
    param([string]$DateText)
    if (-not $DateText) { return "" }
    try {
        return ([datetimeoffset]::Parse($DateText)).ToString("MMMM d, yyyy", [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))
    } catch {
        return $DateText
    }
}

function Format-FileSize {
    param([string]$BytesText)

    $bytes = [long]0
    if (-not [long]::TryParse($BytesText, [ref]$bytes) -or $bytes -le 0) { return "" }
    if ($bytes -ge 1073741824) { return ("{0:N1} GB" -f ($bytes / 1073741824.0)) }
    if ($bytes -ge 1048576) { return ("{0:N1} MB" -f ($bytes / 1048576.0)) }
    if ($bytes -ge 1024) { return ("{0:N0} KB" -f ($bytes / 1024.0)) }
    return "$bytes bytes"
}

function Get-AudioType {
    param([string]$Url)
    $lower = $Url.ToLowerInvariant()
    if ($lower.EndsWith(".m4a")) { return "audio/mp4" }
    if ($lower.EndsWith(".wav")) { return "audio/wav" }
    return "audio/mpeg"
}

function Get-PageAudioUrl {
    param([string]$Url)
    if (-not $Url) { return "" }
    try {
        $uri = [Uri]$Url
        if ($uri.Host -ieq "www.fillmorechristian.org" -and $uri.AbsolutePath.StartsWith("/media/")) {
            return $uri.PathAndQuery
        }
    } catch {}
    return $Url
}

function Get-RelativeEpisodePath {
    param([string]$Url)

    if (-not $Url) { return "" }
    try {
        $uri = [Uri]$Url
        $segments = @($uri.AbsolutePath.Trim("/") -split "/" | Where-Object { $_ })
        if ($segments.Count -ge 2 -and $segments[0] -eq "episode") {
            return "episode/$($segments[1])/"
        }
    } catch {}
    return ""
}

function Get-ElementTextByLocalName {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$LocalName
    )

    foreach ($child in @($Element.ChildNodes)) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -eq $LocalName) {
            return [string]$child.InnerText
        }
    }
    return ""
}

function Build-LatestCard {
    param([System.Xml.XmlElement]$Item)

    $title = [string]$Item.title
    $date = Format-Date ([string]$Item.pubDate)
    $speaker = Clean-Speaker (Get-ElementTextByLocalName $Item "author")
    $audioUrl = if ($Item.enclosure) { [string]$Item.enclosure.url } else { "" }
    $pageAudioUrl = Get-PageAudioUrl $audioUrl
    $audioSizeLabel = if ($Item.enclosure -and $Item.enclosure.length) { Format-FileSize ([string]$Item.enclosure.length) } else { "" }
    $episodePath = Get-RelativeEpisodePath ([string]$Item.link)

    $lines = @(
        '          <article class="podcast-latest-card" data-static-podcast-latest="true">'
    )

    if ($episodePath) {
        $lines += "            <h3><a href=`"$(HtmlEncode $episodePath)`">$(HtmlEncode $title)</a></h3>"
    } else {
        $lines += "            <h3>$(HtmlEncode $title)</h3>"
    }

    $metaParts = @("$(HtmlEncode $date)", "$(HtmlEncode $speaker)")
    if ($audioSizeLabel) {
        $metaParts += "Audio $(HtmlEncode $audioSizeLabel)"
    }
    $lines += "            <p class=`"sermon-meta`">$($metaParts -join ' &middot; ')</p>"

    if ($audioUrl) {
        $lines += "            <audio controls preload=`"none`"><source src=`"$(HtmlEncode $pageAudioUrl)`" type=`"$(Get-AudioType $audioUrl)`">Your browser does not support audio playback.</audio>"
    } else {
        $lines += '            <p class="sermon-audio-missing">Audio is not attached to this archived feed item yet.</p>'
    }

    $actionLines = @()
    if ($episodePath) {
        $actionLines += "              <a href=`"$(HtmlEncode $episodePath)`" class=`"btn btn-outline`">Open Message</a>"
    }
    if ($pageAudioUrl) {
        $actionLines += "              <a href=`"$(HtmlEncode $pageAudioUrl)`" class=`"btn btn-outline`" download>Download Audio</a>"
    }

    if ($actionLines.Count -gt 0) {
        $lines += '            <div class="podcast-latest-actions">'
        $lines += $actionLines
        $lines += '            </div>'
    }

    $lines += '          </article>'
    return $lines -join "`r`n"
}

if ($Count -lt 1) {
    throw "Count must be at least 1."
}

[xml]$feed = Get-Content -Raw -LiteralPath $feedFile
$latestItems = @($feed.rss.channel.item | Where-Object { $_.enclosure -and $_.enclosure.url } | Select-Object -First $Count)
if ($latestItems.Count -eq 0) {
    throw "Podcast feed has no audio items: $feedFile"
}

$cards = @($latestItems | ForEach-Object { Build-LatestCard $_ })

$page = Get-Content -Raw -LiteralPath $pageFile
$startMarker = "          <!-- PODCAST_LATEST_START -->"
$endMarker = "          <!-- PODCAST_LATEST_END -->"
$start = $page.IndexOf($startMarker)
$end = $page.IndexOf($endMarker)

if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
    throw "Could not find podcast latest markers in $PodcastPage"
}

$replacement = $startMarker + "`r`n" + ($cards -join "`r`n") + "`r`n" + "          " + $endMarker.Trim()
$updated = $page.Substring(0, $start) + $replacement + $page.Substring($end + $endMarker.Length)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($pageFile, $updated.TrimEnd() + "`r`n", $utf8NoBom)

Write-Host "Rendered $($cards.Count) latest podcast message card(s) into $PodcastPage"
