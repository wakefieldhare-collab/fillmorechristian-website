param(
    [string]$FeedPath = "podcast-category\fillmore-christian\feed\podcast",
    [string]$HomePage = "index.html"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$feedFile = Join-Path $root $FeedPath
$homeFile = Join-Path $root $HomePage

if (-not (Test-Path -LiteralPath $feedFile)) {
    throw "Feed file not found: $feedFile"
}

if (-not (Test-Path -LiteralPath $homeFile)) {
    throw "Homepage not found: $homeFile"
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

[xml]$feed = Get-Content -Raw -LiteralPath $feedFile
$latestItems = @($feed.rss.channel.item | Where-Object { $_.enclosure -and $_.enclosure.url } | Select-Object -First 1)
if ($latestItems.Count -eq 0) {
    throw "Podcast feed has no audio items: $feedFile"
}
$latest = $latestItems[0]

$title = [string]$latest.title
$date = Format-Date ([string]$latest.pubDate)
$speaker = Clean-Speaker (Get-ElementTextByLocalName $latest "author")
$description = Clean-Description (Strip-Html ([string]$latest.description))
if ($description.Length -gt 170) {
    $description = $description.Substring(0, 167).TrimEnd() + "..."
}

$audioUrl = [string]$latest.enclosure.url
$pageAudioUrl = Get-PageAudioUrl $audioUrl
$episodePath = Get-RelativeEpisodePath ([string]$latest.link)
if (-not $episodePath) {
    $episodePath = "sermons.html"
}

$descriptionMarkup = if ($description) {
    "          <p class=`"latest-sermon-summary`">$(HtmlEncode $description)</p>"
} else {
    ""
}

$replacementLines = @(
    "          <!-- LATEST_SERMON_START -->",
    "          <p class=`"latest-sermon-kicker`">Latest message</p>",
    "          <h3>$(HtmlEncode $title)</h3>",
    "          <p class=`"latest-sermon-meta`">$(HtmlEncode $date) &middot; $(HtmlEncode $speaker)</p>"
)

if ($descriptionMarkup) {
    $replacementLines += $descriptionMarkup
}

$replacementLines += @(
    "          <audio controls preload=`"none`"><source src=`"$(HtmlEncode $pageAudioUrl)`" type=`"$(Get-AudioType $audioUrl)`">Your browser does not support audio playback.</audio>",
    "          <div class=`"latest-sermon-actions`">",
    "            <a href=`"$(HtmlEncode $episodePath)`" class=`"btn btn-light`">Open Message</a>",
    "            <a href=`"$(HtmlEncode $pageAudioUrl)`" class=`"btn btn-light`" download>Download Audio</a>",
    "          </div>",
    "          <!-- LATEST_SERMON_END -->"
)

$page = Get-Content -Raw -LiteralPath $homeFile
$startMarker = "          <!-- LATEST_SERMON_START -->"
$endMarker = "          <!-- LATEST_SERMON_END -->"
$start = $page.IndexOf($startMarker)
$end = $page.IndexOf($endMarker)

if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
    throw "Could not find latest sermon markers in $HomePage"
}

$replacement = $replacementLines -join "`r`n"
$updated = $page.Substring(0, $start) + $replacement + $page.Substring($end + $endMarker.Length)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($homeFile, $updated.TrimEnd() + "`r`n", $utf8NoBom)

Write-Host "Rendered latest homepage sermon: $title"
