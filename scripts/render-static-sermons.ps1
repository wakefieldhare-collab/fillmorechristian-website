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

function Get-CanonicalEpisodeUrl {
    param([string]$RelativePath)
    if (-not $RelativePath) { return "" }
    return "https://www.fillmorechristian.org/$RelativePath"
}

function Build-ArchiveSummaryHtml {
    param($Items)

    $totalCount = @($Items).Count
    $audioCount = @($Items | Where-Object { $_.enclosure -and [string]$_.enclosure.url }).Count
    $years = @(
        $Items |
            ForEach-Object { Format-Year ([string]$_.pubDate) } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $yearRange = if ($years.Count -gt 1) {
        "$($years[0])-$($years[$years.Count - 1])"
    } elseif ($years.Count -eq 1) {
        $years[0]
    } else {
        "Archive"
    }

    return @(
        '        <div class="archive-summary-item">',
        "          <span class=""archive-summary-value"">$(HtmlEncode ([string]$totalCount))</span>",
        '          <span class="archive-summary-label">messages archived</span>',
        '        </div>',
        '        <div class="archive-summary-item">',
        "          <span class=""archive-summary-value"">$(HtmlEncode ([string]$audioCount))</span>",
        '          <span class="archive-summary-label">with audio</span>',
        '        </div>',
        '        <div class="archive-summary-item">',
        "          <span class=""archive-summary-value"">$(HtmlEncode $yearRange)</span>",
        '          <span class="archive-summary-label">teaching years</span>',
        '        </div>'
    ) -join "`r`n"
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
    $pageAudioUrl = Get-PageAudioUrl $audioUrl
    $episodePath = Get-RelativeEpisodePath ([string]$item.link)
    $episodeCanonicalUrl = Get-CanonicalEpisodeUrl $episodePath
    $search = "$title $date $speaker $description"

    $cardClass = if ($audioUrl) { "sermon-item" } else { "sermon-item no-audio" }
    $hasAudio = if ($audioUrl) { "true" } else { "false" }
    $html = @()
    $html += "        <article class=`"$cardClass`" data-year=`"$(HtmlEncode $year)`" data-has-audio=`"$hasAudio`" data-sort-date=`"$(HtmlEncode $sortTimestamp)`" data-title=`"$(HtmlEncode $title.ToLowerInvariant())`" data-search=`"$(HtmlEncode $search.ToLowerInvariant())`">"
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
        $html += "          <audio controls preload=`"none`"><source src=`"$(HtmlEncode $pageAudioUrl)`" type=`"$(Get-AudioType $audioUrl)`">Your browser does not support audio playback.</audio>"
        $actionLinks = @("<a href=`"$(HtmlEncode $pageAudioUrl)`" class=`"sermon-download`" download>Download Audio</a>")
        if ($episodeCanonicalUrl) {
            $actionLinks += "<button class=`"copy-button sermon-copy-link`" type=`"button`" data-copy-value=`"$(HtmlEncode $episodeCanonicalUrl)`" data-copy-label=`"Copy Link`" data-copy-label-success=`"Copied`" data-copy-success=`"Sermon link copied.`" data-copy-fallback=`"Sermon link selected. Press Ctrl+C to copy it.`" data-copy-fail=`"Copy failed. Open the sermon and copy the page address.`">Copy Link</button>"
        }
        $html += "          <div class=`"sermon-actions`">$($actionLinks -join '')</div>"
    } else {
        $html += "          <p class=`"sermon-audio-missing`">Audio is not attached to this archived feed item yet.</p>"
        if ($episodeCanonicalUrl) {
            $html += "          <div class=`"sermon-actions`"><button class=`"copy-button sermon-copy-link`" type=`"button`" data-copy-value=`"$(HtmlEncode $episodeCanonicalUrl)`" data-copy-label=`"Copy Link`" data-copy-label-success=`"Copied`" data-copy-success=`"Sermon link copied.`" data-copy-fallback=`"Sermon link selected. Press Ctrl+C to copy it.`" data-copy-fail=`"Copy failed. Open the sermon and copy the page address.`">Copy Link</button></div>"
        }
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

$summaryStartMarker = "        <!-- SERMON_ARCHIVE_SUMMARY_START -->"
$summaryEndMarker = "        <!-- SERMON_ARCHIVE_SUMMARY_END -->"
$summaryStart = $updated.IndexOf($summaryStartMarker)
$summaryEnd = $updated.IndexOf($summaryEndMarker)

if ($summaryStart -lt 0 -or $summaryEnd -lt 0 -or $summaryEnd -lt $summaryStart) {
    throw "Could not find sermon archive summary markers in $pageFile"
}

$summaryReplacement = $summaryStartMarker + "`r`n" + (Build-ArchiveSummaryHtml $items) + "`r`n" + "        " + $summaryEndMarker.Trim()
$updated = $updated.Substring(0, $summaryStart) + $summaryReplacement + $updated.Substring($summaryEnd + $summaryEndMarker.Length)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($pageFile, $updated.TrimEnd() + "`r`n", $utf8NoBom)

Write-Host "Rendered $($cards.Count) static sermon cards and archive summary into $SermonsPage"
