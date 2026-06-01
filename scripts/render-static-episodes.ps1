param(
    [string]$FeedPath = "podcast-category\fillmore-christian\feed\podcast",
    [string]$EpisodeDir = "episode",
    [string]$SitemapPath = "sitemap.xml",
    [string]$FunctionsDir = "functions",
    [string]$LegacyRedirectManifestPath = "exports\thechurchco-podcast\legacy-podcast-redirects.csv",
    [string]$RoutesPath = "_routes.json"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$feedFile = Join-Path $root $FeedPath
$episodeRoot = Join-Path $root $EpisodeDir
$sitemapFile = Join-Path $root $SitemapPath
$functionsRoot = Join-Path $root $FunctionsDir
$legacyRedirectManifestFile = Join-Path $root $LegacyRedirectManifestPath
$routesFile = Join-Path $root $RoutesPath

if (-not (Test-Path -LiteralPath $feedFile)) {
    throw "Feed file not found: $feedFile"
}

function HtmlEncode {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function JsonEncode {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 12 -Compress)
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

function Get-EpisodeSlug {
    param([string]$Url)

    $uri = [Uri]$Url
    $segments = @($uri.AbsolutePath.Trim("/") -split "/" | Where-Object { $_ })
    if ($segments.Count -ge 2 -and $segments[0] -eq "episode") {
        return $segments[1]
    }

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

function Write-Sitemap {
    param([object[]]$EpisodeRows)

    $publicPages = @(
        @{ Loc = "https://www.fillmorechristian.org/"; Priority = "1.0" },
        @{ Loc = "https://www.fillmorechristian.org/about.html"; Priority = "0.8" },
        @{ Loc = "https://www.fillmorechristian.org/beliefs.html"; Priority = "0.8" },
        @{ Loc = "https://www.fillmorechristian.org/team.html"; Priority = "0.7" },
        @{ Loc = "https://www.fillmorechristian.org/events.html"; Priority = "0.7" },
        @{ Loc = "https://www.fillmorechristian.org/sermons.html"; Priority = "0.9" },
        @{ Loc = "https://www.fillmorechristian.org/podcast.html"; Priority = "0.8" },
        @{ Loc = "https://www.fillmorechristian.org/contact.html"; Priority = "0.8" }
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" encoding="UTF-8"?>')
    $lines.Add('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
    foreach ($page in $publicPages) {
        $lines.Add('  <url>')
        $lines.Add("    <loc>$($page.Loc)</loc>")
        $lines.Add("    <priority>$($page.Priority)</priority>")
        $lines.Add('  </url>')
    }

    foreach ($episode in $EpisodeRows) {
        $lines.Add('  <url>')
        $lines.Add("    <loc>$($episode.CanonicalUrl)</loc>")
        if ($episode.LastMod) {
            $lines.Add("    <lastmod>$($episode.LastMod)</lastmod>")
        }
        $lines.Add('    <priority>0.6</priority>')
        $lines.Add('  </url>')
    }

    $lines.Add('</urlset>')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($sitemapFile, ($lines -join "`r`n") + "`r`n", $utf8NoBom)
}

function Get-LegacyPostId {
    param([string]$Url)

    if (-not $Url) { return "" }
    try {
        $uri = [Uri]$Url
        $queryText = $uri.Query.TrimStart("?")
        if (-not $queryText) { return "" }

        $query = @{}
        foreach ($pair in ($queryText -split "&")) {
            if (-not $pair) { continue }
            $parts = $pair -split "=", 2
            $name = [Uri]::UnescapeDataString($parts[0])
            $value = if ($parts.Count -gt 1) { [Uri]::UnescapeDataString($parts[1]) } else { "" }
            $query[$name] = $value
        }

        if ($query["post_type"] -eq "podcasts" -and $query["p"]) {
            return $query["p"]
        }
    } catch {}
    return ""
}

function Write-LegacyRedirectFunction {
    param([object[]]$Rows)

    New-Item -ItemType Directory -Force -Path $functionsRoot | Out-Null
    $manifestDir = Split-Path -Parent $legacyRedirectManifestFile
    New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null

    $Rows | Export-Csv -LiteralPath $legacyRedirectManifestFile -NoTypeInformation -Encoding UTF8

    $mapLines = New-Object System.Collections.Generic.List[string]
    foreach ($row in ($Rows | Sort-Object PostId)) {
        $mapLines.Add("  `"$($row.PostId)`": `"$($row.Path)`"")
    }
    $mapBody = $mapLines -join ",`r`n"

    $functionSourceTemplate = @'
const LEGACY_PODCAST_REDIRECTS = {
__LEGACY_PODCAST_REDIRECTS__
};

function getMediaKey(pathname) {
  if (!pathname.startsWith("/media/")) {
    return "";
  }

  try {
    const key = decodeURIComponent(pathname.slice("/media/".length));
    if (!key || key.startsWith("/") || key.includes("..") || key.includes("\\")) {
      return "";
    }
    return key;
  } catch {
    return "";
  }
}

function getFallbackContentType(key) {
  const lowerKey = key.toLowerCase();
  if (lowerKey.endsWith(".m4a")) {
    return "audio/mp4";
  }
  if (lowerKey.endsWith(".wav")) {
    return "audio/wav";
  }
  return "audio/mpeg";
}

function parseRangeHeader(rangeHeader, size) {
  if (!rangeHeader) {
    return null;
  }

  const match = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader.trim());
  if (!match) {
    return { unsatisfiable: true };
  }

  const startText = match[1];
  const endText = match[2];
  if (!startText && !endText) {
    return { unsatisfiable: true };
  }

  if (!startText) {
    const suffixLength = Number.parseInt(endText, 10);
    if (!Number.isFinite(suffixLength) || suffixLength <= 0) {
      return { unsatisfiable: true };
    }

    const length = Math.min(suffixLength, size);
    return {
      offset: size - length,
      length
    };
  }

  const offset = Number.parseInt(startText, 10);
  const end = endText ? Number.parseInt(endText, 10) : size - 1;
  if (!Number.isFinite(offset) || !Number.isFinite(end) || offset < 0 || end < offset || offset >= size) {
    return { unsatisfiable: true };
  }

  return {
    offset,
    length: Math.min(end, size - 1) - offset + 1
  };
}

function setObjectHeaders(headers, object, key) {
  object.writeHttpMetadata(headers);
  if (!headers.has("Content-Type")) {
    headers.set("Content-Type", getFallbackContentType(key));
  }
  if (object.httpEtag) {
    headers.set("ETag", object.httpEtag);
  }
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
  headers.set("X-Content-Type-Options", "nosniff");
}

async function handleMediaRequest(context, key) {
  const { request, env } = context;
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", {
      status: 405,
      headers: { Allow: "GET, HEAD" }
    });
  }

  if (!env.SERMON_AUDIO) {
    return new Response("Sermon audio binding is not configured", { status: 503 });
  }

  const head = await env.SERMON_AUDIO.head(key);
  if (!head) {
    return new Response("Audio not found", { status: 404 });
  }

  const headers = new Headers();
  setObjectHeaders(headers, head, key);

  const range = parseRangeHeader(request.headers.get("Range"), head.size);
  if (range?.unsatisfiable) {
    headers.set("Content-Range", `bytes */${head.size}`);
    return new Response(null, { status: 416, headers });
  }

  const options = range ? { range } : undefined;
  const object = request.method === "HEAD" ? head : await env.SERMON_AUDIO.get(key, options);
  if (!object) {
    return new Response("Audio not found", { status: 404 });
  }

  if (object !== head) {
    setObjectHeaders(headers, object, key);
  }

  const status = range ? 206 : 200;
  if (range) {
    const rangeEnd = range.offset + range.length - 1;
    headers.set("Content-Range", `bytes ${range.offset}-${rangeEnd}/${head.size}`);
    headers.set("Content-Length", String(range.length));
  } else {
    headers.set("Content-Length", String(head.size));
  }

  return new Response(request.method === "HEAD" ? null : object.body, { status, headers });
}

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const mediaKey = getMediaKey(url.pathname);

  if (mediaKey) {
    return handleMediaRequest(context, mediaKey);
  }

  if (url.searchParams.get("post_type") === "podcasts") {
    const targetPath = LEGACY_PODCAST_REDIRECTS[url.searchParams.get("p") || ""];
    if (targetPath) {
      return Response.redirect(new URL(targetPath, url.origin).toString(), 301);
    }
  }

  return context.next();
}
'@
    $functionSource = $functionSourceTemplate.Replace("__LEGACY_PODCAST_REDIRECTS__", $mapBody)

    [System.IO.File]::WriteAllText((Join-Path $functionsRoot "index.js"), $functionSource.TrimEnd() + "`r`n", $utf8NoBom)

    $routesJson = @"
{
  "version": 1,
  "include": ["/", "/media/*"],
  "exclude": []
}
"@
    [System.IO.File]::WriteAllText($routesFile, $routesJson.TrimEnd() + "`r`n", $utf8NoBom)
}

[xml]$feed = Get-Content -Raw -LiteralPath $feedFile
$items = @($feed.rss.channel.item)
if ($items.Count -eq 0) {
    throw "Feed has no items: $feedFile"
}

$episodeSummaries = New-Object System.Collections.Generic.List[object]
foreach ($item in $items) {
    $title = [string]$item.title
    $slug = Get-EpisodeSlug ([string]$item.link)
    if (-not $slug) {
        throw "Could not derive episode slug for $title"
    }

    $episodeSummaries.Add([pscustomobject]@{
        Title = $title
        Slug = $slug
    })
}

if (Test-Path -LiteralPath $episodeRoot) {
    Remove-Item -LiteralPath $episodeRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $episodeRoot | Out-Null

$episodeRows = New-Object System.Collections.Generic.List[object]
$legacyRedirectRows = New-Object System.Collections.Generic.List[object]
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

for ($episodeIndex = 0; $episodeIndex -lt $items.Count; $episodeIndex++) {
    $item = $items[$episodeIndex]
    $title = $episodeSummaries[$episodeIndex].Title
    $slug = $episodeSummaries[$episodeIndex].Slug

    $date = Format-Date ([string]$item.pubDate)
    $lastMod = ""
    try {
        $lastMod = ([datetimeoffset]::Parse([string]$item.pubDate)).ToString("yyyy-MM-dd")
    } catch {}

    $speaker = Clean-Speaker (Get-ElementTextByLocalName $item "author")
    $description = Clean-Description (Strip-Html ([string]$item.description))
    $summary = if ($description) { $description } else { "Listen to $title from the Fillmore Christian Church sermon archive." }
    if ($summary.Length -gt 155) {
        $summary = $summary.Substring(0, 152).TrimEnd() + "..."
    }

    $enclosure = $item.enclosure
    $audioUrl = if ($enclosure) { [string]$enclosure.url } else { "" }
    $pageAudioUrl = Get-PageAudioUrl $audioUrl
    $audioLength = if ($enclosure -and $enclosure.length) { [string]$enclosure.length } else { "" }
    $audioType = if ($audioUrl) { Get-AudioType $audioUrl } else { "" }
    $canonicalUrl = "https://www.fillmorechristian.org/episode/$slug/"
    $canonicalPath = "/episode/$slug/"
    $localDir = Join-Path $episodeRoot $slug
    New-Item -ItemType Directory -Path $localDir | Out-Null

    $downloadActionMarkup = if ($audioUrl) {
        '              <a href="' + (HtmlEncode $pageAudioUrl) + '" class="btn btn-outline" download>Download Audio</a>' + "`r`n"
    } else {
        ""
    }

    $episodeCopyMarkup = @"
            <div class="podcast-feed-copy episode-link-copy">
              <label for="episode-link-url">Sermon link</label>
              <div class="copy-field">
                <input id="episode-link-url" type="text" value="$canonicalUrl" readonly>
                <button class="copy-button" type="button" data-copy-value="$canonicalUrl" data-copy-status-target="episode-copy-status" data-copy-label="Copy" data-copy-success="Sermon link copied." data-copy-fallback="Sermon link selected. Press Ctrl+C to copy it." data-copy-fail="Copy failed. Copy the page address from your browser.">Copy</button>
              </div>
              <p id="episode-copy-status" class="copy-status" aria-live="polite">Use this direct link to share this sermon.</p>
            </div>
"@

    $audioMarkup = if ($audioUrl) {
        '          <audio controls preload="none"><source src="' + (HtmlEncode $pageAudioUrl) + '" type="' + $audioType + '">Your browser does not support audio playback.</audio>'
    } else {
        '          <p class="sermon-audio-missing">Audio is not attached to this archived feed item yet.</p>'
    }

    $descriptionMarkup = if ($description) {
        '          <p class="episode-description">' + (HtmlEncode $description) + '</p>'
    } else {
        ""
    }

    $newerEpisode = if ($episodeIndex -gt 0) { $episodeSummaries[$episodeIndex - 1] } else { $null }
    $olderEpisode = if ($episodeIndex -lt ($episodeSummaries.Count - 1)) { $episodeSummaries[$episodeIndex + 1] } else { $null }
    $newerNavMarkup = if ($newerEpisode) {
        '          <a class="episode-nav-link" href="../' + (HtmlEncode $newerEpisode.Slug) + '/"><span>Newer Message</span><strong>' + (HtmlEncode $newerEpisode.Title) + '</strong></a>'
    } else {
        '          <span class="episode-nav-link episode-nav-disabled"><span>Newer Message</span><strong>Latest message</strong></span>'
    }
    $olderNavMarkup = if ($olderEpisode) {
        '          <a class="episode-nav-link" href="../' + (HtmlEncode $olderEpisode.Slug) + '/"><span>Older Message</span><strong>' + (HtmlEncode $olderEpisode.Title) + '</strong></a>'
    } else {
        '          <span class="episode-nav-link episode-nav-disabled"><span>Older Message</span><strong>Oldest message</strong></span>'
    }

    $episodeNavMarkup = @"
        <nav class="episode-nav" aria-label="Sermon episode navigation">
$newerNavMarkup
$olderNavMarkup
        </nav>
"@

    $jsonLd = [ordered]@{
        "@context" = "https://schema.org"
        "@type" = "PodcastEpisode"
        "name" = $title
        "description" = $summary
        "url" = $canonicalUrl
        "datePublished" = $lastMod
        "isPartOf" = [ordered]@{
            "@type" = "PodcastSeries"
            "name" = "Fillmore Christian"
            "url" = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast"
        }
        "publisher" = [ordered]@{
            "@type" = "Church"
            "name" = "Fillmore Christian Church"
            "url" = "https://www.fillmorechristian.org/"
        }
    }

    if ($audioUrl) {
        $audioObject = [ordered]@{
            "@type" = "AudioObject"
            "contentUrl" = $audioUrl
            "encodingFormat" = $audioType
        }
        if ($audioLength) {
            $audioObject["contentSize"] = $audioLength
        }
        $jsonLd["associatedMedia"] = $audioObject
    }

    $jsonLdMarkup = JsonEncode $jsonLd

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$(HtmlEncode $title) | Fillmore Christian Church</title>
  <meta name="description" content="$(HtmlEncode $summary)">
  <link rel="canonical" href="$canonicalUrl">
  <link rel="icon" href="../../favicon.svg" type="image/svg+xml">
  <link rel="manifest" href="../../site.webmanifest">
  <link rel="alternate" type="application/rss+xml" title="Fillmore Christian Podcast" href="https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast">
  <meta name="theme-color" content="#173247">
  <meta property="og:title" content="$(HtmlEncode $title) | Fillmore Christian Church">
  <meta property="og:description" content="$(HtmlEncode $summary)">
  <meta property="og:type" content="article">
  <meta property="og:url" content="$canonicalUrl">
  <meta property="og:image" content="https://www.fillmorechristian.org/images/podcast-cover.jpg">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="$(HtmlEncode $title) | Fillmore Christian Church">
  <meta name="twitter:description" content="$(HtmlEncode $summary)">
  <meta name="twitter:image" content="https://www.fillmorechristian.org/images/podcast-cover.jpg">
  <script type="application/ld+json">$jsonLdMarkup</script>
  <link rel="stylesheet" href="../../css/style.css?v=20260601-16">
</head>
<body>
  <nav class="navbar">
    <div class="container">
      <a href="../../index.html" class="nav-brand">
        <img src="../../images/fcc-logo.png" alt="" class="nav-brand-logo" aria-hidden="true">
        <div class="nav-brand-text">
          <span class="nav-brand-name">Fillmore Christian Church</span>
          <span class="nav-brand-tagline">established in 1865</span>
        </div>
      </a>
      <button class="nav-toggle" aria-label="Toggle navigation">&#9776;</button>
      <ul class="nav-links">
        <li><a href="../../index.html">Home</a></li>
        <li class="nav-dropdown">
          <a href="../../about.html">About</a>
          <ul class="nav-dropdown-menu">
            <li><a href="../../beliefs.html">Our Beliefs</a></li>
            <li><a href="../../team.html">Our Team</a></li>
          </ul>
        </li>
        <li><a href="../../events.html">Events</a></li>
        <li><a href="../../sermons.html" class="active">Past Sermons</a></li>
        <li><a href="../../contact.html">Contact Us</a></li>
      </ul>
    </div>
  </nav>

  <main>
    <section class="page-header sermon-header episode-header">
      <div class="container">
        <p class="eyebrow">Sermon archive</p>
        <h1>$(HtmlEncode $title)</h1>
        <p>$(HtmlEncode $date) &middot; $(HtmlEncode $speaker)</p>
      </div>
    </section>

    <section class="section">
      <div class="container episode-layout">
        <article class="episode-player">
          <div class="episode-art-wrap">
            <img src="../../images/podcast-cover.jpg" alt="Fillmore Christian podcast cover art" width="1400" height="1400" loading="lazy" decoding="async">
          </div>
          <div class="episode-content">
            <p class="eyebrow">Listen</p>
            <h2>$(HtmlEncode $title)</h2>
            <div class="sermon-meta"><span>$(HtmlEncode $date)</span> &middot; <span>$(HtmlEncode $speaker)</span></div>
$descriptionMarkup
$audioMarkup
            <div class="episode-actions">
$downloadActionMarkup              <a href="../../sermons.html" class="btn btn-outline">All Sermons</a>
              <a href="../../podcast.html" class="btn btn-outline">Subscribe</a>
            </div>
$episodeCopyMarkup
          </div>
        </article>
$episodeNavMarkup
      </div>
    </section>
  </main>

  <footer>
    <div class="container">
      <p>&copy; 2026 Fillmore Christian Church. All rights reserved.</p>
      <p>Fillmore, Missouri</p>
    </div>
  </footer>

  <script src="../../js/main.js?v=20260601-17"></script>
</body>
</html>
"@

    [System.IO.File]::WriteAllText((Join-Path $localDir "index.html"), $html.TrimEnd() + "`r`n", $utf8NoBom)
    $episodeRows.Add([pscustomobject]@{
        Slug = $slug
        CanonicalUrl = $canonicalUrl
        LastMod = $lastMod
    })

    $legacyPostId = Get-LegacyPostId ([string]$item.guid.'#text')
    if ($legacyPostId) {
        $legacyRedirectRows.Add([pscustomobject]@{
            PostId = $legacyPostId
            Title = $title
            Path = $canonicalPath
        })
    }
}

Write-Sitemap $episodeRows
Write-LegacyRedirectFunction $legacyRedirectRows

Write-Host "Rendered $($episodeRows.Count) static episode pages into $EpisodeDir"
Write-Host "Rendered $($legacyRedirectRows.Count) legacy podcast query redirect(s)"
Write-Host "Updated sitemap: $SitemapPath"
