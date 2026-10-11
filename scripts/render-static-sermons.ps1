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

function Join-LastWords {
    param([string]$Text)
    # Keep the last three words together so a title never wraps to a short final line.
    # Tokens without letters or digits (such as "-") do not count as words. A nowrap span is used
    # rather than &nbsp; because browsers still break after hyphens.
    $words = @($Text -split " " | Where-Object { $_ })
    $wordPositions = @(for ($i = 0; $i -lt $words.Count; $i++) { if ($words[$i] -match "[A-Za-z0-9]") { $i } })
    if ($wordPositions.Count -le 3) { return "<span class=`"nowrap`">$(HtmlEncode $Text)</span>" }
    $split = $wordPositions[$wordPositions.Count - 3]
    $head = ($words[0..($split - 1)] | ForEach-Object { HtmlEncode $_ }) -join " "
    $tail = ($words[$split..($words.Count - 1)] | ForEach-Object { HtmlEncode $_ }) -join " "
    return "$head <span class=`"nowrap`">$tail</span>"
}

function Build-MetaHtml {
    param([object[]]$Parts)
    # Each part stays on one line (CSS nowrap). A short final part is held to the part before it.
    $spans = @(foreach ($part in $Parts) {
        $classAttr = if ($part.Class) { " class=`"$($part.Class)`"" } else { "" }
        "<span$classAttr>$(HtmlEncode $part.Text)</span>"
    })
    $last = $Parts[$Parts.Count - 1]
    if ($spans.Count -ge 2 -and @($last.Text -split " ").Count -le 2) {
        $held = "<span class=`"nowrap`">$($spans[$spans.Count - 2]) &middot; $($spans[$spans.Count - 1])</span>"
        $spans = if ($spans.Count -eq 2) { @($held) } else { @($spans[0..($spans.Count - 3)]) + $held }
    }
    return $spans -join " &middot; "
}

$bibleBooks = @(
    "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth", "1 Samuel", "2 Samuel",
    "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra", "Nehemiah", "Esther", "Job", "Psalms", "Proverbs",
    "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah", "Lamentations", "Ezekiel", "Daniel", "Hosea", "Joel", "Amos",
    "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk", "Zephaniah", "Haggai", "Zechariah", "Malachi",
    "Matthew", "Mark", "Luke", "John", "Acts", "Romans", "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians",
    "Philippians", "Colossians", "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus", "Philemon",
    "Hebrews", "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John", "Jude", "Revelation"
)
$firstNewTestamentBook = [Array]::IndexOf($bibleBooks, "Matthew")

function Get-PassageBook {
    param([string]$Passage)
    if (-not $Passage) { return "" }
    $match = $bibleBooks | Where-Object { $Passage -eq $_ -or $Passage.StartsWith("$_ ") } | Sort-Object Length -Descending | Select-Object -First 1
    if ($match) { return $match }
    return ""
}

function Get-PassageSortKey {
    param([string]$Passage, [string]$Book)
    $rest = $Passage.Substring($Book.Length).Trim()
    $chapter = 0
    $verse = 0
    if ($rest -match "^(\d+)(?::(\d+))?") {
        $chapter = [int]$Matches[1]
        if ($Matches[2]) { $verse = [int]$Matches[2] }
    }
    return ($chapter * 1000) + $verse
}

function Get-BookAnchor {
    param([string]$Book)
    return "book-" + (($Book.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-"))
}

function Build-PassageViewHtml {
    param($Entries)

    $withBook = @($Entries | Where-Object { $_.Book })
    $books = @($withBook | ForEach-Object { $_.Book } | Sort-Object -Unique { [Array]::IndexOf($bibleBooks, $_) })
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('          <nav class="passage-book-nav" aria-label="Jump to a book of the Bible">')
    foreach ($book in $books) {
        $count = @($withBook | Where-Object { $_.Book -eq $book }).Count
        $lines.Add("            <a href=`"#$(Get-BookAnchor $book)`">$(HtmlEncode $book) <span class=`"passage-book-count`">$count</span></a>")
    }
    $lines.Add('          </nav>')

    $currentTestament = ""
    foreach ($book in $books) {
        $testament = if ([Array]::IndexOf($bibleBooks, $book) -ge $firstNewTestamentBook) { "New Testament" } else { "Old Testament" }
        if ($testament -ne $currentTestament) {
            $lines.Add("          <h2 class=`"passage-testament`">$testament</h2>")
            $currentTestament = $testament
        }
        $bookEntries = @($withBook | Where-Object { $_.Book -eq $book } | Sort-Object @{ Expression = { $_.PassageSortKey } }, @{ Expression = { $_.SortTimestamp } })
        $lines.Add("          <div class=`"passage-book`" id=`"$(Get-BookAnchor $book)`">")
        $lines.Add("            <h3>$(HtmlEncode $book)</h3>")
        $lines.Add('            <ul class="passage-list">')
        foreach ($entry in $bookEntries) {
            $linkAttrs = if ($entry.IsExternal) { " target=`"_blank`" rel=`"noopener`"" } else { "" }
            $kind = if ($entry.IsExternal) { " <span class=`"passage-kind`">Video</span>" } else { "" }
            $lines.Add("              <li>")
            $lines.Add("                <span class=`"passage-ref`">$((HtmlEncode $entry.Passage) -replace ' ', '&nbsp;')$kind</span>")
            if ($entry.Href) {
                $lines.Add("                <a href=`"$(HtmlEncode $entry.Href)`"$linkAttrs>$(Join-LastWords $entry.Title)</a>")
            } else {
                $lines.Add("                <span class=`"passage-title`">$(Join-LastWords $entry.Title)</span>")
            }
            $lines.Add("                <span class=`"passage-meta`"><span>$((HtmlEncode $entry.Speaker) -replace ' ', '&nbsp;')</span>, <span>$((HtmlEncode $entry.Date) -replace ' ', '&nbsp;')</span></span>")
            $lines.Add("              </li>")
        }
        $lines.Add('            </ul>')
        $lines.Add('          </div>')
    }

    return $lines -join "`r`n"
}

function Replace-BetweenMarkers {
    param([string]$Page, [string]$Name, [string]$Content)
    $startMarker = "        <!-- $($Name)_START -->"
    $endMarker = "        <!-- $($Name)_END -->"
    $start = $Page.IndexOf($startMarker)
    $end = $Page.IndexOf($endMarker)
    if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
        throw "Could not find $Name markers in $pageFile"
    }
    $replacement = $startMarker + "`r`n" + $Content + "`r`n" + "        " + $endMarker.Trim()
    return $Page.Substring(0, $start) + $replacement + $Page.Substring($end + $endMarker.Length)
}

function Build-ArchiveSummaryHtml {
    param($Items, [int]$VideoCount)

    $totalCount = @($Items).Count + $VideoCount
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
$index = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "sermon-index.json") | ConvertFrom-Json
$entries = New-Object System.Collections.Generic.List[object]
$central = [System.TimeZoneInfo]::FindSystemTimeZoneById("Central Standard Time")

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
    $slug = if ($episodePath) { ($episodePath -replace "^episode/", "").Trim("/") } else { "" }
    $passageProperty = if ($slug) { $index.passages.PSObject.Properties[$slug] } else { $null }
    $passage = if ($passageProperty) { [string]$passageProperty.Value } else { "" }
    $book = Get-PassageBook $passage
    if ($passage -and -not $book) { throw "Unrecognized book in passage '$passage' for $slug" }
    $search = "$title $date $speaker $passage $description $audioSizeLabel $durationLabel"

    $cardClass = if ($audioUrl) { "sermon-item" } else { "sermon-item no-audio" }
    $hasAudio = if ($audioUrl) { "true" } else { "false" }
    $html = @()
    $html += "        <article class=`"$cardClass`" data-year=`"$(HtmlEncode $year)`" data-has-audio=`"$hasAudio`" data-sort-date=`"$(HtmlEncode $sortTimestamp)`" data-title=`"$(HtmlEncode $title.ToLowerInvariant())`" data-search=`"$(HtmlEncode $search.ToLowerInvariant())`">"
    if ($episodePath) {
        $html += "          <h3><a href=`"$(HtmlEncode $episodePath)`">$(Join-LastWords $title)</a></h3>"
    } else {
        $html += "          <h3>$(Join-LastWords $title)</h3>"
    }
    $metaParts = @(@{ Text = $date }, @{ Text = $speaker })
    if ($passage) {
        $metaParts += @{ Text = $passage; Class = "sermon-passage" }
    }
    if ($audioSizeLabel) {
        $metaParts += @{ Text = "Audio $audioSizeLabel"; Class = "sermon-audio-size" }
    }
    if ($durationLabel) {
        $metaParts += @{ Text = "Duration $durationLabel"; Class = "sermon-duration" }
    }
    $html += "          <div class=`"sermon-meta`">$(Build-MetaHtml $metaParts)</div>"
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
        $html += "          <p class=`"sermon-audio-missing`">Audio is not attached to this archived <span class=`"nowrap`">feed item yet.</span></p>"
        if ($episodeCanonicalUrl) {
            $html += "          <div class=`"sermon-actions`"><button class=`"copy-button sermon-copy-link`" type=`"button`" data-copy-value=`"$(HtmlEncode $episodeCanonicalUrl)`" data-copy-label=`"Copy Link`" data-copy-label-success=`"Copied`" data-copy-success=`"Sermon link copied.`" data-copy-fallback=`"Sermon link selected. Press Ctrl+C to copy it.`" data-copy-fail=`"Copy failed. Open the sermon and copy the page address.`">Copy Link</button></div>"
        }
    }
    $html += "        </article>"
    $entries.Add([pscustomobject]@{
        SortTimestamp = [long]$sortTimestamp
        Html = ($html -join "`r`n")
        Title = $title
        Date = $date
        Speaker = $speaker
        Passage = $passage
        Book = $book
        PassageSortKey = if ($book) { Get-PassageSortKey $passage $book } else { 0 }
        Href = $episodePath
        IsExternal = $false
    })
}

foreach ($video in @($index.videoSermons)) {
    $sunday = [datetime]::ParseExact([string]$video.date, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture).AddHours(10.5)
    $offset = $central.GetUtcOffset($sunday)
    $when = [datetimeoffset]::new($sunday, $offset)
    $title = [string]$video.title
    $date = $when.ToString("MMMM d, yyyy", [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))
    $year = $when.ToString("yyyy")
    $sortTimestamp = $when.ToUnixTimeSeconds()
    $teacher = [string]$video.teacher
    $passage = [string]$video.passage
    $book = Get-PassageBook $passage
    if (-not $book) { throw "Unrecognized book in video sermon passage '$passage'" }
    $url = [string]$video.url
    if (-not $url.StartsWith("https://")) { throw "Video sermon link must use HTTPS: $url" }
    $source = [string]$video.source
    $search = "$title $date $teacher $passage video sermon $source"

    $html = @()
    $html += "        <article class=`"sermon-item sermon-video`" data-year=`"$year`" data-has-audio=`"false`" data-sort-date=`"$sortTimestamp`" data-title=`"$(HtmlEncode $title.ToLowerInvariant())`" data-search=`"$(HtmlEncode $search.ToLowerInvariant())`">"
    $html += "          <h3><a href=`"$(HtmlEncode $url)`" target=`"_blank`" rel=`"noopener`">$(Join-LastWords $title)</a></h3>"
    $metaHtml = Build-MetaHtml @(@{ Text = $date }, @{ Text = $teacher }, @{ Text = $passage; Class = "sermon-passage" }, @{ Text = "Video sermon"; Class = "sermon-video-label" })
    $html += "          <div class=`"sermon-meta`">$metaHtml</div>"
    $html += "          <p class=`"sermon-description`">Shown during our Sunday&nbsp;worship&nbsp;service.</p>"
    $html += "          <div class=`"sermon-actions`"><a href=`"$(HtmlEncode $url)`" class=`"sermon-watch`" target=`"_blank`" rel=`"noopener`">Watch at $(HtmlEncode $source)</a></div>"
    $html += "        </article>"
    $entries.Add([pscustomobject]@{
        SortTimestamp = [long]$sortTimestamp
        Html = ($html -join "`r`n")
        Title = $title
        Date = $date
        Speaker = $teacher
        Passage = $passage
        Book = $book
        PassageSortKey = Get-PassageSortKey $passage $book
        Href = $url
        IsExternal = $true
    })
}

$sortedEntries = @($entries | Sort-Object SortTimestamp -Descending)
$videoCount = @($index.videoSermons).Count

$page = Get-Content -Raw -LiteralPath $pageFile
$updated = Replace-BetweenMarkers $page "STATIC_SERMONS" (($sortedEntries | ForEach-Object { $_.Html }) -join "`r`n")
$updated = Replace-BetweenMarkers $updated "SERMON_ARCHIVE_SUMMARY" (Build-ArchiveSummaryHtml $items $videoCount)
$updated = Replace-BetweenMarkers $updated "SERMON_PASSAGES" (Build-PassageViewHtml $sortedEntries)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($pageFile, $updated.TrimEnd() + "`r`n", $utf8NoBom)

$mappedCount = @($sortedEntries | Where-Object { $_.Book }).Count
Write-Host "Rendered $($sortedEntries.Count) sermon cards ($videoCount video), $mappedCount grouped by passage, into $SermonsPage"
