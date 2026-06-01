param(
    [string]$StagingBaseUrl = "https://wakefieldhare-collab.github.io/fillmorechristian-website",
    [string]$BuildOutputDir = "dist",
    [switch]$SkipRemote,
    [switch]$VerifyAudioHashes,
    [switch]$RequireIndependentAudio,
    [switch]$VerifyPodcastMedia,
    [switch]$VerifyAllPodcastMedia,
    [int]$PodcastMediaSampleCount = 5
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [string]$Name,
        [ValidateSet("OK", "WARN", "FAIL")]
        [string]$Status,
        [string]$Details
    )

    $checks.Add([pscustomobject]@{
        Status = $Status
        Check = $Name
        Details = $Details
    })
}

function Join-Url {
    param([string]$Base, [string]$Path)
    return $Base.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Get-XmlDocument {
    param([string]$Path)

    try {
        [xml]$xml = Get-Content -Raw -LiteralPath $Path
        return $xml
    } catch {
        throw "Could not parse XML file $Path`: $($_.Exception.Message)"
    }
}

function ConvertTo-LocalAudioFileName {
    param([string]$Url)

    $uri = [Uri]$Url
    $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    return $fileName -replace '[^\w\.\-]+', '-'
}

function Get-EnclosureUrls {
    param([xml]$Feed)

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Feed.rss.channel.item)) {
        if ($item.enclosure -and $item.enclosure.url) {
            $urls.Add([string]$item.enclosure.url)
        }
    }
    return $urls
}

function Get-EpisodeSlug {
    param([string]$Url)

    try {
        $uri = [Uri]$Url
        $segments = @($uri.AbsolutePath.Trim("/") -split "/" | Where-Object { $_ })
        if ($segments.Count -ge 2 -and $segments[0] -eq "episode") {
            return $segments[1]
        }
    } catch {}
    return ""
}

function Get-LegacyPodcastPostId {
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

$requiredFiles = @(
    "index.html",
    "about.html",
    "beliefs.html",
    "events.html",
    "sermons.html",
    "contact.html",
    "team.html",
    "404.html",
    "css\style.css",
    "js\main.js",
    "js\sermons.js",
    "podcast-category\fillmore-christian\feed\podcast",
    "podcast.xml",
    "feed.xml",
    "robots.txt",
    "sitemap.xml",
    "_headers",
    "_routes.json",
    "_redirects"
)

$missingRequired = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if ($missingRequired.Count -eq 0) {
    Add-Check "Required static files" "OK" "$($requiredFiles.Count) required files present"
} else {
    Add-Check "Required static files" "FAIL" ("Missing: " + ($missingRequired -join ", "))
}

$wranglerConfigPath = Join-Path $root "wrangler.toml"
if (Test-Path -LiteralPath $wranglerConfigPath) {
    $wranglerConfig = Get-Content -Raw -LiteralPath $wranglerConfigPath
    $wranglerIssues = New-Object System.Collections.Generic.List[string]
    if ($wranglerConfig -notmatch '(?m)^name\s*=\s*"fillmorechristian-website"') {
        $wranglerIssues.Add("project name is missing or unexpected")
    }
    if ($wranglerConfig -notmatch '(?m)^compatibility_date\s*=\s*"\d{4}-\d{2}-\d{2}"') {
        $wranglerIssues.Add("compatibility_date is missing")
    }
    if ($wranglerConfig -notmatch "(?m)^pages_build_output_dir\s*=\s*`"$([regex]::Escape($BuildOutputDir))`"") {
        $wranglerIssues.Add("pages_build_output_dir does not match $BuildOutputDir")
    }

    if ($wranglerIssues.Count -eq 0) {
        Add-Check "Wrangler Pages config" "OK" "wrangler.toml points Cloudflare Pages at $BuildOutputDir"
    } else {
        Add-Check "Wrangler Pages config" "FAIL" ($wranglerIssues -join "; ")
    }
} else {
    Add-Check "Wrangler Pages config" "FAIL" "wrangler.toml is missing"
}

$publicHtmlPages = @(
    "index.html",
    "about.html",
    "beliefs.html",
    "events.html",
    "sermons.html",
    "contact.html",
    "team.html"
)

$metadataFailures = New-Object System.Collections.Generic.List[string]
foreach ($relativePath in $publicHtmlPages) {
    $htmlPath = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $htmlPath)) {
        continue
    }

    $html = Get-Content -Raw -LiteralPath $htmlPath
    $expectedCanonical = if ($relativePath -eq "index.html") {
        "https://www.fillmorechristian.org/"
    } else {
        "https://www.fillmorechristian.org/$relativePath"
    }

    if ($html -notmatch "<link\s+rel=`"canonical`"\s+href=`"$([regex]::Escape($expectedCanonical))`"") {
        $metadataFailures.Add("$relativePath missing canonical")
    }
    if ($html -notmatch "<meta\s+property=`"og:title`"") {
        $metadataFailures.Add("$relativePath missing og:title")
    }
    if ($html -notmatch "<meta\s+property=`"og:description`"") {
        $metadataFailures.Add("$relativePath missing og:description")
    }
    if ($html -notmatch "<meta\s+property=`"og:url`"") {
        $metadataFailures.Add("$relativePath missing og:url")
    }
    if ($html -notmatch "<meta\s+property=`"og:image`"") {
        $metadataFailures.Add("$relativePath missing og:image")
    }
    if ($html -notmatch "<meta\s+name=`"twitter:card`"") {
        $metadataFailures.Add("$relativePath missing twitter:card")
    }
}

if ($metadataFailures.Count -eq 0) {
    Add-Check "Public page metadata" "OK" "$($publicHtmlPages.Count) public pages have canonical, Open Graph, and Twitter metadata"
} else {
    Add-Check "Public page metadata" "FAIL" ($metadataFailures -join "; ")
}

$notFoundPath = Join-Path $root "404.html"
if (Test-Path -LiteralPath $notFoundPath) {
    $notFoundHtml = Get-Content -Raw -LiteralPath $notFoundPath
    if ($notFoundHtml -match "<meta\s+name=`"robots`"\s+content=`"noindex`"") {
        Add-Check "404 indexing metadata" "OK" "404 page is marked noindex"
    } else {
        Add-Check "404 indexing metadata" "FAIL" "404 page is missing robots noindex metadata"
    }
}

$buildOutputPath = Join-Path $root $BuildOutputDir
if (Test-Path -LiteralPath $buildOutputPath) {
    $missingBuildFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $buildOutputPath $_)) })
    $forbiddenBuildPaths = @("exports", "functions", "scripts", ".git", "MIGRATION-RUNBOOK.md", "SETUP-GUIDE.md") |
        Where-Object { Test-Path -LiteralPath (Join-Path $buildOutputPath $_) }
    $forbiddenBuildImages = @("images\church-exterior.jpg", "images\sanctuary-service.png") |
        Where-Object { Test-Path -LiteralPath (Join-Path $buildOutputPath $_) }

    if ($missingBuildFiles.Count -eq 0 -and $forbiddenBuildPaths.Count -eq 0 -and $forbiddenBuildImages.Count -eq 0) {
        Add-Check "Cloudflare build output" "OK" "$BuildOutputDir contains publish assets and excludes migration-only files"
    } else {
        $details = @()
        if ($missingBuildFiles.Count -gt 0) { $details += "missing: $($missingBuildFiles -join ', ')" }
        if ($forbiddenBuildPaths.Count -gt 0) { $details += "should not publish: $($forbiddenBuildPaths -join ', ')" }
        if ($forbiddenBuildImages.Count -gt 0) { $details += "unoptimized images should not publish: $($forbiddenBuildImages -join ', ')" }
        Add-Check "Cloudflare build output" "FAIL" ($details -join "; ")
    }
} else {
    Add-Check "Cloudflare build output" "WARN" "$BuildOutputDir not found; run npm run build before Cloudflare deployment"
}

$feedPaths = @(
    "podcast-category\fillmore-christian\feed\podcast",
    "podcast.xml",
    "feed.xml"
)

$feeds = @{}
$feedItemCounts = @{}
$feedEnclosureCounts = @{}
foreach ($relativePath in $feedPaths) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        continue
    }

    try {
        $feed = Get-XmlDocument $path
        $items = @($feed.rss.channel.item)
        $feeds[$relativePath] = $feed
        $feedItemCounts[$relativePath] = $items.Count
        $feedEnclosureCounts[$relativePath] = @(Get-EnclosureUrls $feed).Count
        Add-Check "Feed XML parses: $relativePath" "OK" "$($items.Count) items, $($feedEnclosureCounts[$relativePath]) enclosures"
    } catch {
        Add-Check "Feed XML parses: $relativePath" "FAIL" $_.Exception.Message
    }
}

if ($feedItemCounts.Count -eq $feedPaths.Count) {
    $distinctItemCounts = @($feedItemCounts.Values | Select-Object -Unique)
    $distinctEnclosureCounts = @($feedEnclosureCounts.Values | Select-Object -Unique)
    if ($distinctItemCounts.Count -eq 1 -and $distinctEnclosureCounts.Count -eq 1) {
        Add-Check "Feed aliases match" "OK" "$($distinctItemCounts[0]) items and $($distinctEnclosureCounts[0]) enclosures in each feed copy"
    } else {
        Add-Check "Feed aliases match" "FAIL" "Item counts: $($feedItemCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } -join '; '); enclosure counts: $($feedEnclosureCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } -join '; ')"
    }
}

$sermonsPath = Join-Path $root "sermons.html"
if (Test-Path -LiteralPath $sermonsPath) {
    $sermonsHtml = Get-Content -Raw -LiteralPath $sermonsPath
    $staticCards = ([regex]::Matches($sermonsHtml, 'class="sermon-item')).Count
    $expectedCards = if ($feedItemCounts.ContainsKey($feedPaths[0])) { $feedItemCounts[$feedPaths[0]] } else { 0 }
    if ($expectedCards -gt 0 -and $staticCards -eq $expectedCards) {
        Add-Check "Static sermon archive" "OK" "$staticCards static cards match the podcast feed"
    } else {
        Add-Check "Static sermon archive" "FAIL" "$staticCards static cards, expected $expectedCards from the podcast feed"
    }

    $cardsWithYear = ([regex]::Matches($sermonsHtml, 'class="sermon-item[^"]*"\s+data-year="\d{4}"')).Count
    if ($expectedCards -gt 0 -and $cardsWithYear -eq $expectedCards) {
        Add-Check "Sermon year filter data" "OK" "$cardsWithYear static cards include feed-derived years"
    } else {
        Add-Check "Sermon year filter data" "FAIL" "$cardsWithYear static card year value(s), expected $expectedCards"
    }

    if ($sermonsHtml -match 'id="sermon-year"') {
        Add-Check "Sermon year filter control" "OK" "Archive page includes year filter control"
    } else {
        Add-Check "Sermon year filter control" "FAIL" "Archive page is missing #sermon-year"
    }

    $downloadLinks = ([regex]::Matches($sermonsHtml, 'class="sermon-download"')).Count
    $expectedDownloadLinks = if ($feedEnclosureCounts.ContainsKey($feedPaths[0])) { $feedEnclosureCounts[$feedPaths[0]] } else { 0 }
    if ($expectedDownloadLinks -gt 0 -and $downloadLinks -eq $expectedDownloadLinks) {
        Add-Check "Sermon audio downloads" "OK" "$downloadLinks downloadable audio link(s) match feed enclosures"
    } else {
        Add-Check "Sermon audio downloads" "FAIL" "$downloadLinks downloadable audio link(s), expected $expectedDownloadLinks from the podcast feed"
    }

    if ($sermonsHtml.Contains("description description")) {
        Add-Check "Sermon placeholder cleanup" "FAIL" "Placeholder text remains in sermons.html"
    } else {
        Add-Check "Sermon placeholder cleanup" "OK" "No placeholder description text found"
    }

    if ($sermonsHtml -match "thechurchcodaniel") {
        Add-Check "Sermon platform-account cleanup" "FAIL" "Old TheChurchCo account text remains in sermons.html"
    } else {
        Add-Check "Sermon platform-account cleanup" "OK" "No old platform-account speaker text found"
    }
}

$sampleEpisodePath = ""
if ($feeds.ContainsKey($feedPaths[0])) {
    $episodeIssues = New-Object System.Collections.Generic.List[string]
    $feedItems = @($feeds[$feedPaths[0]].rss.channel.item)
    $episodeSlugs = @($feedItems | ForEach-Object { Get-EpisodeSlug ([string]$_.link) } | Where-Object { $_ })
    $uniqueEpisodeSlugs = @($episodeSlugs | Select-Object -Unique)
    if ($episodeSlugs.Count -ne $feedItems.Count) {
        $episodeIssues.Add("$($feedItems.Count - $episodeSlugs.Count) feed item(s) do not have /episode/ links")
    }
    if ($uniqueEpisodeSlugs.Count -ne $episodeSlugs.Count) {
        $episodeIssues.Add("duplicate episode slugs found")
    }

    $missingEpisodePages = @($uniqueEpisodeSlugs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root "episode\$_\index.html")) })
    if ($missingEpisodePages.Count -gt 0) {
        $episodeIssues.Add("missing episode pages: $($missingEpisodePages -join ', ')")
    }

    $redirectsPath = Join-Path $root "_redirects"
    if ((Test-Path -LiteralPath $redirectsPath) -and (Get-Content -Raw -LiteralPath $redirectsPath) -match "(?m)^/episode/\*") {
        $episodeIssues.Add("_redirects still contains a wildcard /episode/* redirect")
    }

    $sitemapPath = Join-Path $root "sitemap.xml"
    if (Test-Path -LiteralPath $sitemapPath) {
        $sitemapText = Get-Content -Raw -LiteralPath $sitemapPath
        $missingSitemapEpisodes = @($uniqueEpisodeSlugs | Where-Object { $sitemapText -notmatch [regex]::Escape("https://www.fillmorechristian.org/episode/$_/") })
        if ($missingSitemapEpisodes.Count -gt 0) {
            $episodeIssues.Add("missing episode sitemap URLs: $($missingSitemapEpisodes -join ', ')")
        }
    } else {
        $episodeIssues.Add("sitemap.xml is missing")
    }

    if (Test-Path -LiteralPath $buildOutputPath) {
        $missingBuildEpisodePages = @($uniqueEpisodeSlugs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $buildOutputPath "episode\$_\index.html")) })
        if ($missingBuildEpisodePages.Count -gt 0) {
            $episodeIssues.Add("missing built episode pages: $($missingBuildEpisodePages -join ', ')")
        }
    }

    if ($uniqueEpisodeSlugs.Count -gt 0) {
        $sampleEpisodePath = "episode/$($uniqueEpisodeSlugs[0])/"
    }

    if ($episodeIssues.Count -eq 0) {
        Add-Check "Static episode pages" "OK" "$($uniqueEpisodeSlugs.Count) episode pages generated and indexed"
    } else {
        Add-Check "Static episode pages" "FAIL" ($episodeIssues -join "; ")
    }

    $legacyRedirectIssues = New-Object System.Collections.Generic.List[string]
    $legacyManifestPath = Join-Path $root "exports\thechurchco-podcast\legacy-podcast-redirects.csv"
    $legacyFunctionPath = Join-Path $root "functions\index.js"
    $routesPath = Join-Path $root "_routes.json"
    $expectedLegacyRedirects = New-Object System.Collections.Generic.List[object]

    foreach ($item in $feedItems) {
        $slug = Get-EpisodeSlug ([string]$item.link)
        $guidText = if ($item.guid.'#text') { [string]$item.guid.'#text' } else { [string]$item.guid }
        $postId = Get-LegacyPodcastPostId $guidText
        if ($postId -and $slug) {
            $expectedLegacyRedirects.Add([pscustomobject]@{
                PostId = $postId
                Path = "/episode/$slug/"
            })
        }
    }

    if ($expectedLegacyRedirects.Count -eq 0) {
        $legacyRedirectIssues.Add("no legacy WordPress podcast query links found in the feed")
    }

    if (Test-Path -LiteralPath $legacyManifestPath) {
        $legacyRows = @(Import-Csv -LiteralPath $legacyManifestPath)
        $duplicateLegacyRows = @($legacyRows | Group-Object PostId | Where-Object { $_.Count -gt 1 })
        foreach ($duplicate in $duplicateLegacyRows) {
            $legacyRedirectIssues.Add("duplicate legacy post ID in manifest: $($duplicate.Name)")
        }

        if ($legacyRows.Count -ne $expectedLegacyRedirects.Count) {
            $legacyRedirectIssues.Add("manifest has $($legacyRows.Count) row(s), expected $($expectedLegacyRedirects.Count)")
        }

        foreach ($expected in $expectedLegacyRedirects) {
            $matchingRow = @($legacyRows | Where-Object { $_.PostId -eq $expected.PostId -and $_.Path -eq $expected.Path })
            if ($matchingRow.Count -eq 0) {
                $legacyRedirectIssues.Add("missing redirect $($expected.PostId) -> $($expected.Path)")
            }
        }
    } else {
        $legacyRedirectIssues.Add("legacy redirect manifest is missing")
    }

    if (Test-Path -LiteralPath $legacyFunctionPath) {
        $legacyFunctionText = Get-Content -Raw -LiteralPath $legacyFunctionPath
        foreach ($expected in $expectedLegacyRedirects) {
            $expectedMapping = "`"$($expected.PostId)`": `"$($expected.Path)`""
            if (-not $legacyFunctionText.Contains($expectedMapping)) {
                $legacyRedirectIssues.Add("function is missing mapping $expectedMapping")
            }
        }

        if ($legacyFunctionText -notmatch "Response\.redirect" -or $legacyFunctionText -notmatch "post_type") {
            $legacyRedirectIssues.Add("function does not look like a podcast query redirect handler")
        }
    } else {
        $legacyRedirectIssues.Add("functions\index.js is missing")
    }

    if (Test-Path -LiteralPath $routesPath) {
        try {
            $routes = Get-Content -Raw -LiteralPath $routesPath | ConvertFrom-Json
            if ($routes.version -ne 1 -or "/" -notin @($routes.include)) {
                $legacyRedirectIssues.Add("_routes.json does not include the root path for the query redirect function")
            }
        } catch {
            $legacyRedirectIssues.Add("_routes.json is not valid JSON")
        }
    } else {
        $legacyRedirectIssues.Add("_routes.json is missing")
    }

    if (Test-Path -LiteralPath $buildOutputPath) {
        if (-not (Test-Path -LiteralPath (Join-Path $buildOutputPath "_routes.json"))) {
            $legacyRedirectIssues.Add("built output is missing _routes.json")
        }
    }

    if ($legacyRedirectIssues.Count -eq 0) {
        Add-Check "Legacy podcast query redirects" "OK" "$($expectedLegacyRedirects.Count) old WordPress-style podcast links map to episode pages"
    } else {
        Add-Check "Legacy podcast query redirects" "FAIL" ($legacyRedirectIssues -join "; ")
    }
}

if ($feeds.ContainsKey($feedPaths[0])) {
    $enclosureUrls = @(Get-EnclosureUrls $feeds[$feedPaths[0]])
    $httpUrls = @($enclosureUrls | Where-Object { $_.StartsWith("http://") })
    if ($httpUrls.Count -eq 0) {
        Add-Check "Podcast enclosure HTTPS" "OK" "All $($enclosureUrls.Count) enclosure URLs use HTTPS"
    } else {
        Add-Check "Podcast enclosure HTTPS" "FAIL" "$($httpUrls.Count) enclosure URLs still use HTTP"
    }

    $churchCoUrls = @($enclosureUrls | Where-Object { $_ -match "thechurchco" })
    if ($churchCoUrls.Count -eq 0) {
        Add-Check "Podcast audio independence" "OK" "No enclosure URLs point at TheChurchCo"
    } elseif ($RequireIndependentAudio) {
        Add-Check "Podcast audio independence" "FAIL" "$($churchCoUrls.Count) enclosure URLs still point at TheChurchCo"
    } else {
        Add-Check "Podcast audio independence" "WARN" "$($churchCoUrls.Count) enclosure URLs still point at TheChurchCo until R2 rewrite"
    }

    $feedText = Get-Content -Raw -LiteralPath (Join-Path $root $feedPaths[0])
    $feedAuthorArtifacts = [regex]::Matches($feedText, ">(thechurchco[^<]*)<", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($feedAuthorArtifacts.Count -eq 0) {
        Add-Check "Podcast author cleanup" "OK" "No old platform-account author fields found"
    } else {
        Add-Check "Podcast author cleanup" "FAIL" "$($feedAuthorArtifacts.Count) old platform-account author field(s) remain"
    }

    $artworkUrl = "https://www.fillmorechristian.org/images/podcast-cover.jpg"
    $feedArtworkUrls = [regex]::Matches($feedText, "<(?:itunes:|googleplay:)?image\b[^>]*href=`"([^`"]+)`"|<url>([^<]+\.(?:jpg|jpeg|png|webp))</url>", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
        ForEach-Object {
            if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
        }
    $badArtworkUrls = @($feedArtworkUrls | Where-Object { $_ -and $_ -ne $artworkUrl } | Select-Object -Unique)
    if ($badArtworkUrls.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $root "images\podcast-cover.jpg"))) {
        Add-Check "Podcast artwork independence" "OK" "Podcast artwork points at local site asset"
    } else {
        $details = @()
        if ($badArtworkUrls.Count -gt 0) { $details += "unexpected artwork URLs: $($badArtworkUrls -join ', ')" }
        if (-not (Test-Path -LiteralPath (Join-Path $root "images\podcast-cover.jpg"))) { $details += "images\podcast-cover.jpg is missing" }
        Add-Check "Podcast artwork independence" "FAIL" ($details -join "; ")
    }
}

$manifestPath = Join-Path $root "exports\thechurchco-podcast\manifest.csv"
$audioDir = Join-Path $root "exports\thechurchco-podcast\audio"
$inventoryPath = Join-Path $root "exports\thechurchco-podcast\audio-inventory.csv"
$r2ManifestPath = Join-Path $root "exports\thechurchco-podcast\r2-audio-manifest.csv"
$manifestRows = @()
$rowsWithAudio = @()

if (Test-Path -LiteralPath $manifestPath) {
    $manifestRows = @(Import-Csv -LiteralPath $manifestPath)
    $rowsWithAudio = @($manifestRows | Where-Object { $_.EnclosureUrl })
    Add-Check "Podcast manifest" "OK" "$($manifestRows.Count) rows, $($rowsWithAudio.Count) rows with audio enclosures"

    if (Test-Path -LiteralPath $audioDir) {
        $audioFiles = @(Get-ChildItem -LiteralPath $audioDir -File)
        $expectedAudioFiles = @($rowsWithAudio | ForEach-Object { ConvertTo-LocalAudioFileName $_.EnclosureUrl } | Where-Object { $_ } | Select-Object -Unique)
        $missingAudio = @($expectedAudioFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $audioDir $_)) })
        if ($missingAudio.Count -eq 0) {
            Add-Check "Podcast audio backup coverage" "OK" "$($audioFiles.Count) local files cover $($expectedAudioFiles.Count) unique enclosure filenames"
        } else {
            Add-Check "Podcast audio backup coverage" "FAIL" ("Missing audio backups: " + ($missingAudio -join ", "))
        }
    } else {
        Add-Check "Podcast audio backup coverage" "FAIL" "Audio backup directory not found: $audioDir"
    }
} else {
    Add-Check "Podcast manifest" "FAIL" "Manifest not found: $manifestPath"
}

if ((Test-Path -LiteralPath $inventoryPath) -and (Test-Path -LiteralPath $audioDir)) {
    $inventoryRows = @(Import-Csv -LiteralPath $inventoryPath)
    $badInventory = New-Object System.Collections.Generic.List[string]
    foreach ($row in $inventoryRows) {
        $filePath = Join-Path $audioDir $row.FileName
        if (-not (Test-Path -LiteralPath $filePath)) {
            $badInventory.Add("$($row.FileName): missing")
            continue
        }

        $file = Get-Item -LiteralPath $filePath
        if ([int64]$row.SizeBytes -ne $file.Length) {
            $badInventory.Add("$($row.FileName): size mismatch")
            continue
        }

        if ($VerifyAudioHashes) {
            $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
            if ($hash -ne $row.SHA256) {
                $badInventory.Add("$($row.FileName): SHA256 mismatch")
            }
        }
    }

    if ($badInventory.Count -eq 0) {
        $hashNote = if ($VerifyAudioHashes) { " with SHA-256 verification" } else { "" }
        Add-Check "Podcast audio inventory" "OK" "$($inventoryRows.Count) inventory rows match local files$hashNote"
    } else {
        Add-Check "Podcast audio inventory" "FAIL" ($badInventory -join "; ")
    }
} else {
    Add-Check "Podcast audio inventory" "WARN" "Inventory or audio directory not present"
}

if ($VerifyPodcastMedia) {
    try {
        $mediaArgs = @{
            FeedPath = $feedPaths[0]
            Quiet = $true
        }
        if ($VerifyAllPodcastMedia) {
            $mediaArgs.All = $true
        } else {
            $mediaArgs.SampleCount = $PodcastMediaSampleCount
        }

        & (Join-Path $PSScriptRoot "test-podcast-media.ps1") @mediaArgs | Out-Null
        $scope = if ($VerifyAllPodcastMedia) { "all unique enclosure URLs" } else { "$PodcastMediaSampleCount sampled enclosure URL(s)" }
        Add-Check "Podcast media reachability" "OK" "Verified $scope"
    } catch {
        Add-Check "Podcast media reachability" "FAIL" $_.Exception.Message
    }
}

if (Test-Path -LiteralPath $r2ManifestPath) {
    $r2Rows = @(Import-Csv -LiteralPath $r2ManifestPath)
    $r2Issues = New-Object System.Collections.Generic.List[string]
    $duplicateObjectKeys = @($r2Rows | Group-Object ObjectKey | Where-Object { $_.Count -gt 1 })
    foreach ($duplicate in $duplicateObjectKeys) {
        $r2Issues.Add("duplicate object key: $($duplicate.Name)")
    }

    $expectedR2FileNames = @($rowsWithAudio | ForEach-Object { ConvertTo-LocalAudioFileName $_.EnclosureUrl } | Where-Object { $_ } | Select-Object -Unique)
    $manifestFileNames = @($r2Rows.FileName | Where-Object { $_ } | Select-Object -Unique)
    $missingR2Files = @($expectedR2FileNames | Where-Object { $_ -notin $manifestFileNames })
    $extraR2Files = @($manifestFileNames | Where-Object { $_ -notin $expectedR2FileNames })
    if ($missingR2Files.Count -gt 0) {
        $r2Issues.Add("missing expected files: $($missingR2Files -join ', ')")
    }
    if ($extraR2Files.Count -gt 0) {
        $r2Issues.Add("extra files: $($extraR2Files -join ', ')")
    }

    $feedReferenceTotal = 0
    foreach ($row in $r2Rows) {
        if (-not $row.ObjectKey -or -not $row.FileName -or -not $row.ContentType) {
            $r2Issues.Add("row missing ObjectKey, FileName, or ContentType")
            continue
        }

        $feedReferenceTotal += [int]$row.FeedReferenceCount
        if (Test-Path -LiteralPath $audioDir) {
            $filePath = Join-Path $audioDir $row.FileName
            if (-not (Test-Path -LiteralPath $filePath)) {
                $r2Issues.Add("$($row.FileName): local audio file missing")
                continue
            }

            $file = Get-Item -LiteralPath $filePath
            if ($row.SizeBytes -and [int64]$row.SizeBytes -ne $file.Length) {
                $r2Issues.Add("$($row.FileName): size mismatch")
            }
        }
    }

    if ($feedReferenceTotal -ne $rowsWithAudio.Count) {
        $r2Issues.Add("feed reference total is $feedReferenceTotal, expected $($rowsWithAudio.Count)")
    }

    if ($RequireIndependentAudio) {
        $publicUrls = @($r2Rows.PublicUrl | Where-Object { $_ })
        $enclosureUrls = if ($feeds.ContainsKey($feedPaths[0])) { @(Get-EnclosureUrls $feeds[$feedPaths[0]]) } else { @() }
        if ($publicUrls.Count -eq 0) {
            $r2Issues.Add("manifest has no PublicUrl values")
        } else {
            $missingPublicUrls = @($enclosureUrls | Where-Object { $_ -notin $publicUrls })
            if ($missingPublicUrls.Count -gt 0) {
                $r2Issues.Add("$($missingPublicUrls.Count) feed enclosure URL(s) are not present in the R2 public URL set")
            }
        }
    }

    if ($r2Issues.Count -eq 0) {
        Add-Check "R2 audio manifest" "OK" "$($r2Rows.Count) R2 objects cover $($rowsWithAudio.Count) feed enclosure references"
    } else {
        Add-Check "R2 audio manifest" "FAIL" ($r2Issues -join "; ")
    }
} else {
    Add-Check "R2 audio manifest" "WARN" "R2 manifest not found; run scripts\build-r2-audio-manifest.ps1 before uploading audio"
}

$dnsPreservePath = Join-Path $root "exports\dns\fillmorechristian.org-cloudflare-preserve-records.csv"
$dnsZonePath = Join-Path $root "exports\dns\fillmorechristian.org-cloudflare-preserve-records.zone"
$dnsPlanPath = Join-Path $root "exports\dns\fillmorechristian.org-cloudflare-dns-cutover-plan.md"
if ((Test-Path -LiteralPath $dnsPreservePath) -and (Test-Path -LiteralPath $dnsZonePath) -and (Test-Path -LiteralPath $dnsPlanPath)) {
    $dnsRows = @(Import-Csv -LiteralPath $dnsPreservePath)
    $dnsIssues = New-Object System.Collections.Generic.List[string]
    $requiredDnsRows = @(
        @{ Type = "MX"; Value = "mxa.mailgun.org"; Priority = "10" },
        @{ Type = "MX"; Value = "mxb.mailgun.org"; Priority = "10" },
        @{ Type = "TXT"; Value = "v=spf1 include:mailgun.org ~all"; Priority = "" },
        @{ Type = "TXT"; Value = "MS=ms48673064"; Priority = "" }
    )
    foreach ($required in $requiredDnsRows) {
        $match = @($dnsRows | Where-Object {
            $_.Name -eq "fillmorechristian.org" -and
            $_.Type -eq $required.Type -and
            $_.Value -eq $required.Value -and
            $_.Priority -eq $required.Priority
        })
        if ($match.Count -eq 0) {
            $dnsIssues.Add("missing $($required.Type) $($required.Value)")
        }
    }

    $oldWebsiteRows = @($dnsRows | Where-Object {
        ($_.Type -eq "A" -and $_.Value -eq "77.83.141.16") -or
        ($_.Type -eq "CNAME" -and $_.Value -eq "ssl.thechurchco.com")
    })
    if ($oldWebsiteRows.Count -gt 0) {
        $dnsIssues.Add("old website records are present in preserve import")
    }

    $zoneText = Get-Content -Raw -LiteralPath $dnsZonePath
    if ($zoneText -notmatch "mxa\.mailgun\.org\." -or $zoneText -notmatch "mxb\.mailgun\.org\." -or $zoneText -notmatch "include:mailgun\.org") {
        $dnsIssues.Add("zone file does not contain expected mail records")
    }

    if ($dnsIssues.Count -eq 0) {
        Add-Check "Cloudflare DNS cutover artifacts" "OK" "$($dnsRows.Count) preserve records cover mail and verification without old website records"
    } else {
        Add-Check "Cloudflare DNS cutover artifacts" "FAIL" ($dnsIssues -join "; ")
    }
} else {
    Add-Check "Cloudflare DNS cutover artifacts" "WARN" "DNS cutover artifacts are missing; run scripts\build-cloudflare-dns-plan.ps1"
}

if (-not $SkipRemote) {
    $remotePaths = @("", "about.html", "beliefs.html", "team.html", "events.html", "sermons.html", "contact.html")
    if ($sampleEpisodePath) {
        $remotePaths += $sampleEpisodePath
    }
    $remotePaths += @("podcast-category/fillmore-christian/feed/podcast", "robots.txt", "sitemap.xml")

    foreach ($path in $remotePaths) {
        $url = Join-Url $StagingBaseUrl $path
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -MaximumRedirection 5
            Add-Check "Staging URL: /$path" "OK" "HTTP $($response.StatusCode)"

            if ($path -in @("", "about.html", "beliefs.html", "team.html", "events.html", "sermons.html", "contact.html") -or $path -eq $sampleEpisodePath) {
                $expectedCanonical = if ($path -eq "") {
                    "https://www.fillmorechristian.org/"
                } elseif ($path -eq $sampleEpisodePath) {
                    "https://www.fillmorechristian.org/$path"
                } else {
                    "https://www.fillmorechristian.org/$path"
                }

                if ($response.Content -match "<link\s+rel=`"canonical`"\s+href=`"$([regex]::Escape($expectedCanonical))`"" -and
                    $response.Content -match "<meta\s+property=`"og:title`"" -and
                    $response.Content -match "<meta\s+property=`"og:image`"" -and
                    $response.Content -match "<meta\s+name=`"twitter:card`"") {
                    Add-Check "Staging metadata: /$path" "OK" "Canonical, Open Graph, and Twitter metadata present"
                } else {
                    Add-Check "Staging metadata: /$path" "FAIL" "Missing required page metadata on staging"
                }

                if ($path -eq $sampleEpisodePath) {
                    if ($response.Content -match "<audio\s+controls" -and $response.Content -match "Download Audio" -and $response.Content -match "All Sermons") {
                        Add-Check "Staging episode page" "OK" "Sample episode page has audio, download, and archive navigation"
                    } else {
                        Add-Check "Staging episode page" "FAIL" "Sample episode page is missing audio, download, or archive navigation"
                    }
                }
            }

            if ($path -eq "sermons.html") {
                $remoteCards = ([regex]::Matches($response.Content, 'class="sermon-item')).Count
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and $remoteCards -ne $feedItemCounts[$feedPaths[0]]) {
                    Add-Check "Staging sermon card count" "FAIL" "$remoteCards remote cards, expected $($feedItemCounts[$feedPaths[0]])"
                } else {
                    Add-Check "Staging sermon card count" "OK" "$remoteCards sermon cards"
                }

                $remoteCardsWithYear = ([regex]::Matches($response.Content, 'class="sermon-item[^"]*"\s+data-year="\d{4}"')).Count
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and $remoteCardsWithYear -eq $feedItemCounts[$feedPaths[0]] -and $response.Content -match 'id="sermon-year"') {
                    Add-Check "Staging sermon year filter" "OK" "$remoteCardsWithYear sermon cards include years and filter control is present"
                } else {
                    Add-Check "Staging sermon year filter" "FAIL" "$remoteCardsWithYear sermon card year value(s); filter control present: $($response.Content -match 'id=`"sermon-year`"')"
                }

                if ($response.Content -match "thechurchcodaniel|description description") {
                    Add-Check "Staging sermon metadata cleanup" "FAIL" "Stale placeholder or platform-account text found on staging"
                } else {
                    Add-Check "Staging sermon metadata cleanup" "OK" "No stale placeholder or platform-account text found on staging"
                }
            }

            if ($path -eq "podcast-category/fillmore-christian/feed/podcast") {
                $remoteAuthorArtifacts = [regex]::Matches($response.Content, ">(thechurchco[^<]*)<", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($remoteAuthorArtifacts.Count -eq 0) {
                    Add-Check "Staging podcast author cleanup" "OK" "No old platform-account author fields found on staging"
                } else {
                    Add-Check "Staging podcast author cleanup" "FAIL" "$($remoteAuthorArtifacts.Count) old platform-account author field(s) found on staging"
                }

                $remoteArtworkUrls = [regex]::Matches($response.Content, "<(?:itunes:|googleplay:)?image\b[^>]*href=`"([^`"]+)`"|<url>([^<]+\.(?:jpg|jpeg|png|webp))</url>", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
                    ForEach-Object {
                        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
                    }
                $badRemoteArtworkUrls = @($remoteArtworkUrls | Where-Object { $_ -and $_ -ne "https://www.fillmorechristian.org/images/podcast-cover.jpg" } | Select-Object -Unique)
                if ($badRemoteArtworkUrls.Count -eq 0) {
                    Add-Check "Staging podcast artwork" "OK" "Podcast artwork points at the local site asset on staging"
                } else {
                    Add-Check "Staging podcast artwork" "FAIL" "Unexpected artwork URLs on staging: $($badRemoteArtworkUrls -join ', ')"
                }
            }
        } catch {
            Add-Check "Staging URL: /$path" "FAIL" $_.Exception.Message
        }
    }

    $optimizedStagingImages = @(
        "images/church-exterior-1200.jpg",
        "images/church-exterior-1200.webp",
        "images/podcast-cover.jpg",
        "images/sanctuary-service-1200.jpg",
        "images/sanctuary-service-1200.webp"
    )
    $missingOptimizedImages = New-Object System.Collections.Generic.List[string]
    foreach ($imagePath in $optimizedStagingImages) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri (Join-Url $StagingBaseUrl $imagePath) -Method Head -MaximumRedirection 5 | Out-Null
        } catch {
            $missingOptimizedImages.Add($imagePath)
        }
    }

    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $forbiddenStagingImages = @("images/church-exterior.jpg", "images/sanctuary-service.png")
    $publishedForbiddenImages = New-Object System.Collections.Generic.List[string]
    foreach ($imagePath in $forbiddenStagingImages) {
        try {
            $url = (Join-Url $StagingBaseUrl $imagePath) + "?readiness=$cacheBust"
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -MaximumRedirection 5
            if ($response.StatusCode -lt 400) {
                $publishedForbiddenImages.Add($imagePath)
            }
        } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ne 404) {
                $publishedForbiddenImages.Add("$imagePath returned HTTP $([int]$_.Exception.Response.StatusCode)")
            } elseif (-not $_.Exception.Response) {
                $publishedForbiddenImages.Add("$imagePath check failed: $($_.Exception.Message)")
            }
        }
    }

    if ($missingOptimizedImages.Count -eq 0 -and $publishedForbiddenImages.Count -eq 0) {
        Add-Check "Staging optimized images" "OK" "Optimized images are published and unused source images are not"
    } else {
        $details = @()
        if ($missingOptimizedImages.Count -gt 0) { $details += "missing optimized: $($missingOptimizedImages -join ', ')" }
        if ($publishedForbiddenImages.Count -gt 0) { $details += "source images still public: $($publishedForbiddenImages -join ', ')" }
        Add-Check "Staging optimized images" "FAIL" ($details -join "; ")
    }
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) migration readiness check(s) failed."
}

$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) migration readiness warning(s) remain."
}
