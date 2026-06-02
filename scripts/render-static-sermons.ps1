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

function Format-FileSize {
    param([string]$BytesText)

    $bytes = [long]0
    if (-not [long]::TryParse($BytesText, [ref]$bytes) -or $bytes -le 0) { return "" }
    if ($bytes -ge 1073741824) { return ("{0:N1} GB" -f ($bytes / 1073741824.0)) }
    if ($bytes -ge 1048576) { return ("{0:N1} MB" -f ($bytes / 1048576.0)) }
    if ($bytes -ge 1024) { return ("{0:N0} KB" -f ($bytes / 1024.0)) }
    return "$bytes bytes"
}

function Format-DurationLabel {
    param([string]$DurationText)

    if (-not $DurationText) { return "" }
    $clean = ($DurationText -replace '[^\d:]', '').Trim()
    if (-not $clean) { return "" }
    $parts = @($clean -split ":" | ForEach-Object { [int]$_ })
    $seconds = 0
    if ($parts.Count -eq 3) {
        $seconds = ($parts[0] * 3600) + ($parts[1] * 60) + $parts[2]
    } elseif ($parts.Count -eq 2) {
        $seconds = ($parts[0] * 60) + $parts[1]
    } elseif ($parts.Count -eq 1) {
        $seconds = $parts[0]
    }
    if ($seconds -le 0) { return "" }

    $span = [TimeSpan]::FromSeconds($seconds)
    $minutes = [int][Math]::Floor($span.TotalMinutes)
    if ($minutes -ge 60) {
        return ("{0} hr {1} min" -f [int][Math]::Floor($span.TotalHours), $span.Minutes)
    }
    return ("{0} min {1} sec" -f $minutes, $span.Seconds)
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
    $audioSizeLabel = if ($enclosure -and $enclosure.length) { Format-FileSize ([string]$enclosure.length) } else { "" }
    $durationLabel = Format-DurationLabel (Get-ElementTextByLocalName $item "duration")
    $episodePath = Get-RelativeEpisodePath ([string]$item.link)
    $episodeCanonicalUrl = Get-CanonicalEpisodeUrl $episodePath
    $search = "$title $date $speaker $description $audioSizeLabel $durationLabel"

    $cardClass = if ($audioUrl) { "sermon-item" } else { "sermon-item no-audio" }
    $hasAudio = if ($audioUrl) { "true" } else { "false" }
    $html = @()
    $html += "        <article class=`"$cardClass`" data-year=`"$(HtmlEncode $year)`" data-has-audio=`"$hasAudio`" data-sort-date=`"$(HtmlEncode $sortTimestamp)`" data-title=`"$(HtmlEncode $title.ToLowerInvariant())`" data-search=`"$(HtmlEncode $search.ToLowerInvariant())`">"
    if ($episodePath) {
        $html += "          <h3><a href=`"$(HtmlEncode $episodePath)`">$(HtmlEncode $title)</a></h3>"
    } else {
        $html += "          <h3>$(HtmlEncode $title)</h3>"
    }
    $metaParts = @("<span>$(HtmlEncode $date)</span>", "<span>$(HtmlEncode $speaker)</span>")
    if ($audioSizeLabel) {
        $metaParts += "<span class=`"sermon-audio-size`">Audio $(HtmlEncode $audioSizeLabel)</span>"
    }
    if ($durationLabel) {
        $metaParts += "<span class=`"sermon-duration`">Duration $(HtmlEncode $durationLabel)</span>"
    }
    $html += "          <div class=`"sermon-meta`">$($metaParts -join ' &middot; ')</div>"
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
