param(
    [string]$FeedPath = "podcast-category\fillmore-christian\feed\podcast",
    [string]$SermonsPage = "sermons.html"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$feedFile = Join-Path $root $FeedPath
$pageFile = Join-Path $root $SermonsPage

if (-not (Test-Path -LiteralPath $feedFile)) {
    throw "Feed file not found: $feedFile"
}

if (-not (Test-Path -LiteralPath $pageFile)) {
    throw "Sermons page not found: $pageFile"
}

function HtmlEncode {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Strip-Html {
    param([string]$Html)
    if (-not $Html) { return "" }
    return ([regex]::Replace($Html, "<[^>]+>", " ") -replace "\s+", " ").Trim()
}

function Clean-Description {
    param([string]$Text)
    if (-not $Text) { return "" }
    if ($Text -match "^(?i:description)(\s+(?i:description))*$") { return "" }
    return $Text
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

function Format-Year {
    param([string]$DateText)
    if (-not $DateText) { return "" }
    try {
        return ([datetimeoffset]::Parse($DateText)).ToString("yyyy")
    } catch {
        return ""
    }
}

function Format-SortTimestamp {
    param([string]$DateText)
    if (-not $DateText) { return "0" }
    try {
        return ([datetimeoffset]::Parse($DateText)).ToUnixTimeSeconds().ToString([System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return "0"
    }
}

function Get-AudioType {
    param([string]$Url)
    $lower = $Url.ToLowerInvariant()
    if ($lower.EndsWith(".m4a")) { return "audio/mp4" }
    if ($lower.EndsWith(".wav")) { return "audio/wav" }
    return "audio/mpeg"
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

[xml]$feed = Get-Content -Raw -LiteralPath $feedFile
$items = @($feed.rss.channel.item)
$cards = New-Object System.Collections.Generic.List[string]

foreach ($item in $items) {
    $title = [string]$item.title
    $date = Format-Date ([string]$item.pubDate)
    $year = Format-Year ([string]$item.pubDate)
    $sortTimestamp = Format-SortTimestamp ([string]$item.pubDate)
    $speaker = Clean-Speaker ([string]$item.GetElementsByTagName("itunes:author")[0].InnerText)
    $description = Clean-Description (Strip-Html ([string]$item.description))
    if ($description.Length -gt 240) {
        $description = $description.Substring(0, 240) + "..."
    }

    $enclosure = $item.enclosure
    $audioUrl = if ($enclosure) { [string]$enclosure.url } else { "" }
    $episodePath = Get-RelativeEpisodePath ([string]$item.link)
    $search = "$title $date $speaker $description"

    $cardClass = if ($audioUrl) { "sermon-item" } else { "sermon-item no-audio" }
    $html = @()
    $html += "        <article class=`"$cardClass`" data-year=`"$(HtmlEncode $year)`" data-sort-date=`"$(HtmlEncode $sortTimestamp)`" data-title=`"$(HtmlEncode $title.ToLowerInvariant())`" data-search=`"$(HtmlEncode $search.ToLowerInvariant())`">"
    if ($episodePath) {
        $html += "          <h3><a href=`"$(HtmlEncode $episodePath)`">$(HtmlEncode $title)</a></h3>"
    } else {
        $html += "          <h3>$(HtmlEncode $title)</h3>"
    }
    $html += "          <div class=`"sermon-meta`"><span>$(HtmlEncode $date)</span> &middot; <span>$(HtmlEncode $speaker)</span></div>"
    if ($description) {
        $html += "          <p class=`"sermon-description`">$(HtmlEncode $description)</p>"
    }
    if ($audioUrl) {
        $html += "          <audio controls preload=`"none`"><source src=`"$(HtmlEncode $audioUrl)`" type=`"$(Get-AudioType $audioUrl)`">Your browser does not support audio playback.</audio>"
        $html += "          <div class=`"sermon-actions`"><a href=`"$(HtmlEncode $audioUrl)`" class=`"sermon-download`" download>Download Audio</a></div>"
    } else {
        $html += "          <p class=`"sermon-audio-missing`">Audio is not attached to this archived feed item yet.</p>"
    }
    $html += "        </article>"
    $cards.Add(($html -join "`r`n"))
}

$page = Get-Content -Raw -LiteralPath $pageFile
$startMarker = "        <!-- STATIC_SERMONS_START -->"
$endMarker = "        <!-- STATIC_SERMONS_END -->"
$start = $page.IndexOf($startMarker)
$end = $page.IndexOf($endMarker)

if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
    throw "Could not find static sermon markers in $pageFile"
}

$replacement = $startMarker + "`r`n" + ($cards -join "`r`n") + "`r`n" + "        " + $endMarker.Trim()
$updated = $page.Substring(0, $start) + $replacement + $page.Substring($end + $endMarker.Length)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($pageFile, $updated.TrimEnd() + "`r`n", $utf8NoBom)

Write-Host "Rendered $($cards.Count) static sermon cards into $SermonsPage"
