param(
    [string]$StagingBaseUrl = "https://wakefieldhare-collab.github.io/fillmorechristian-website",
    [string]$ExpectedGitHubOwner = "wakefieldhare-collab",
    [string]$ExpectedGitHubRepo = "fillmorechristian-website",
    [string]$ForbiddenGitHubOwner = "wake-byte",
    [string]$BuildOutputDir = "dist",
    [switch]$SkipRemote,
    [switch]$VerifyAudioHashes,
    [switch]$SkipLocalAudioBackup,
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

function Invoke-RemoteWebRequest {
    param(
        [string]$Url,
        [int]$MaxRedirects = 5
    )

    $currentUrl = $Url
    for ($redirectCount = 0; $redirectCount -le $MaxRedirects; $redirectCount++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $currentUrl -MaximumRedirection 0
            $statusCode = [int]$response.StatusCode
            if ($statusCode -in @(301, 302, 303, 307, 308) -and $redirectCount -lt $MaxRedirects) {
                $location = [string]$response.Headers["Location"]
                if (-not $location) {
                    throw "Redirect from $currentUrl did not include a Location header."
                }

                $currentUri = New-Object System.Uri($currentUrl)
                $nextUri = New-Object System.Uri($currentUri, $location)
                $currentUrl = $nextUri.AbsoluteUri
                continue
            }

            return [pscustomobject]@{
                Response = $response
                FinalUrl = $currentUrl
                RedirectCount = $redirectCount
            }
        } catch {
            $webResponse = $_.Exception.Response
            if (-not $webResponse) {
                throw
            }

            $statusCode = [int]$webResponse.StatusCode
            if ($statusCode -notin @(301, 302, 303, 307, 308) -or $redirectCount -ge $MaxRedirects) {
                throw
            }

            $location = [string]$webResponse.Headers["Location"]
            if (-not $location) {
                throw
            }

            $currentUri = New-Object System.Uri($currentUrl)
            $nextUri = New-Object System.Uri($currentUri, $location)
            $currentUrl = $nextUri.AbsoluteUri
        }
    }

    throw "Too many redirects for $Url"
}

function Get-XmlDocument {
    param([string]$Path)

    try {
        [xml]$xml = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
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

function ConvertTo-PageAudioUrl {
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

$gitHubIssues = New-Object System.Collections.Generic.List[string]
$gitHubWarnings = New-Object System.Collections.Generic.List[string]
$expectedRepoPattern = "github\.com[:/]$([regex]::Escape($ExpectedGitHubOwner))/$([regex]::Escape($ExpectedGitHubRepo))(\.git)?$"

try {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    if (-not $originUrl) {
        $gitHubIssues.Add("origin remote is not configured")
    } elseif ($originUrl -match [regex]::Escape($ForbiddenGitHubOwner)) {
        $gitHubIssues.Add("origin remote points at forbidden owner $ForbiddenGitHubOwner`: $originUrl")
    } elseif ($originUrl -notmatch $expectedRepoPattern) {
        $gitHubIssues.Add("origin remote should be $ExpectedGitHubOwner/$ExpectedGitHubRepo, found $originUrl")
    }
} catch {
    $gitHubIssues.Add("could not read git origin remote")
}

try {
    $ghStatus = (& gh auth status 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        $gitHubWarnings.Add("gh is not authenticated; verify Cloudflare/GitHub connection manually")
    } else {
        $activeAccountMatches = [regex]::Matches($ghStatus, "account\s+([^\s]+)[\s\S]*?Active account:\s+true")
        $activeAccounts = @($activeAccountMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($ForbiddenGitHubOwner -in $activeAccounts) {
            $gitHubIssues.Add("gh active account is forbidden owner $ForbiddenGitHubOwner")
        }
        if ($activeAccounts.Count -gt 0 -and $ExpectedGitHubOwner -notin $activeAccounts) {
            $gitHubIssues.Add("gh active account should be $ExpectedGitHubOwner, found $($activeAccounts -join ', ')")
        }
        if ($activeAccounts.Count -eq 0) {
            $gitHubWarnings.Add("could not identify active gh account from gh auth status")
        }
    }
} catch {
    $gitHubWarnings.Add("gh auth status could not be checked")
}

if ($gitHubIssues.Count -gt 0) {
    $details = @($gitHubIssues)
    if ($gitHubWarnings.Count -gt 0) { $details += @($gitHubWarnings) }
    Add-Check "GitHub owner guard" "FAIL" ($details -join "; ")
} elseif ($gitHubWarnings.Count -gt 0) {
    Add-Check "GitHub owner guard" "WARN" ($gitHubWarnings -join "; ")
} else {
    Add-Check "GitHub owner guard" "OK" "origin and active gh account use $ExpectedGitHubOwner"
}

$requiredFiles = @(
    "index.html",
    "about.html",
    "beliefs.html",
    "events.ics",
    "events.html",
    "sermons.html",
    "contact.html",
    "contact.vcf",
    "team.html",
    "404.html",
    "favicon.svg",
    "fonts\playfair-display-latin-400-700.woff2",
    "fonts\source-sans-3-latin-400-700.woff2",
    "site.webmanifest",
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

$headersPath = Join-Path $root "_headers"
if (Test-Path -LiteralPath $headersPath) {
    $headersText = Get-Content -Raw -LiteralPath $headersPath
    $headerIssues = New-Object System.Collections.Generic.List[string]
    $expectedHeaderPatterns = @{
        "RSS content type" = "Content-Type:\s+application/rss\+xml;\s*charset=utf-8"
        "RSS cache control" = "Cache-Control:\s+public,\s*max-age=300"
        "Calendar content type" = "Content-Type:\s+text/calendar;\s*charset=utf-8"
        "Contact card content type" = "Content-Type:\s+text/vcard;\s*charset=utf-8"
        "Manifest content type" = "Content-Type:\s+application/manifest\+json;\s*charset=utf-8"
        "Font content type" = "Content-Type:\s+font/woff2"
        "Font cache control" = "Cache-Control:\s+public,\s*max-age=31536000,\s*immutable"
        "nosniff" = "X-Content-Type-Options:\s+nosniff"
        "frame policy" = "X-Frame-Options:\s+SAMEORIGIN"
        "referrer policy" = "Referrer-Policy:\s+strict-origin-when-cross-origin"
        "permissions policy" = "Permissions-Policy:\s+camera=\(\),\s*microphone=\(\),\s*geolocation=\(\)"
    }
    foreach ($label in $expectedHeaderPatterns.Keys) {
        if ($headersText -notmatch $expectedHeaderPatterns[$label]) {
            $headerIssues.Add("missing $label")
        }
    }

    if ($headerIssues.Count -eq 0) {
        Add-Check "Cloudflare headers" "OK" "RSS content type/cache and static-site security headers configured"
    } else {
        Add-Check "Cloudflare headers" "FAIL" ($headerIssues -join "; ")
    }
} else {
    Add-Check "Cloudflare headers" "FAIL" "_headers is missing"
}

$redirectsPath = Join-Path $root "_redirects"
if (Test-Path -LiteralPath $redirectsPath) {
    $redirectsText = Get-Content -Raw -LiteralPath $redirectsPath
    $redirectIssues = New-Object System.Collections.Generic.List[string]
    if ($redirectsText -notmatch '(?m)^/podcast-category/fillmore-christian/feed/podcast/\s+/podcast-category/fillmore-christian/feed/podcast\s+301\s*$') {
        $redirectIssues.Add("missing canonical trailing-slash podcast feed redirect")
    }
    if ($redirectsText -notmatch '(?m)^/podcast/\s+/podcast\.html\s+301\s*$') {
        $redirectIssues.Add("missing pretty podcast page redirect")
    }
    if ($redirectsText -notmatch '(?m)^/feed/\s+/podcast-category/fillmore-christian/feed/podcast\s+302\s*$' -or $redirectsText -notmatch '(?m)^/feed\.xml\s+/podcast-category/fillmore-christian/feed/podcast\s+302\s*$' -or $redirectsText -notmatch '(?m)^/podcast\.xml\s+/podcast-category/fillmore-christian/feed/podcast\s+302\s*$') {
        $redirectIssues.Add("missing podcast feed alias redirects")
    }

    if ($redirectIssues.Count -eq 0) {
        Add-Check "Cloudflare redirects" "OK" "Pretty pages, podcast aliases, and trailing-slash feed paths are preserved"
    } else {
        Add-Check "Cloudflare redirects" "FAIL" ($redirectIssues -join "; ")
    }
} else {
    Add-Check "Cloudflare redirects" "FAIL" "_redirects is missing"
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
    "podcast.html",
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
    if ($html -notmatch "<link\s+rel=`"alternate`"\s+type=`"application/rss\+xml`"\s+title=`"Fillmore Christian Podcast`"\s+href=`"https://www\.fillmorechristian\.org/podcast-category/fillmore-christian/feed/podcast`"") {
        $metadataFailures.Add("$relativePath missing podcast RSS autodiscovery")
    }
    if ($html -notmatch "<link\s+rel=`"icon`"\s+href=`"favicon\.svg`"\s+type=`"image/svg\+xml`"") {
        $metadataFailures.Add("$relativePath missing favicon")
    }
    if ($html -notmatch '<img\s+src="images/fcc-logo-mark\.png"\s+alt=""\s+class="nav-brand-logo"\s+aria-hidden="true">') {
        $metadataFailures.Add("$relativePath missing compact FCC navigation mark")
    }
    if ($relativePath -eq "index.html" -and $html -notmatch '<img\s+src="images/fcc-logo\.png"\s+alt="Fillmore Christian Church"\s+class="hero-logo"\s+width="2048"\s+height="2048"\s+decoding="async">') {
        $metadataFailures.Add("index.html missing official full FCC hero logo")
    }
    if ($relativePath -eq "podcast.html") {
        if ($html -notmatch '<a\s+href="podcast\.html"\s+class="active">Podcast</a>') {
            $metadataFailures.Add("podcast.html missing active podcast navigation link")
        }
    } elseif ($html -notmatch '<a\s+href="podcast\.html">Podcast</a>') {
        $metadataFailures.Add("$relativePath missing podcast navigation link")
    }
    if ($html -notmatch "<link\s+rel=`"manifest`"\s+href=`"site\.webmanifest`"") {
        $metadataFailures.Add("$relativePath missing web app manifest")
    }
    if ($html -notmatch "<meta\s+name=`"theme-color`"\s+content=`"#173247`"") {
        $metadataFailures.Add("$relativePath missing theme color")
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
    if ($html -match "fonts\.googleapis\.com|fonts\.gstatic\.com") {
        $metadataFailures.Add("$relativePath still references Google-hosted fonts")
    }
    if ($html -match "google\.com/maps/embed|<iframe") {
        $metadataFailures.Add("$relativePath still embeds third-party iframe content")
    }
}

if ($metadataFailures.Count -eq 0) {
    Add-Check "Public page metadata" "OK" "$($publicHtmlPages.Count) public pages have canonical, podcast RSS, FCC brand assets, brand icon, web app manifest, Open Graph, and Twitter metadata"
} else {
    Add-Check "Public page metadata" "FAIL" ($metadataFailures -join "; ")
}

$publicCopyIssues = New-Object System.Collections.Generic.List[string]
foreach ($relativePath in @("index.html", "sermons.html", "podcast.html", "404.html")) {
    $htmlPath = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $htmlPath)) { continue }

    $html = Get-Content -Raw -LiteralPath $htmlPath
    if ($html -match "being moved out of TheChurchCo|during the move|ChurchCo transition|preserved podcast RSS feed path") {
        $publicCopyIssues.Add("$relativePath still has migration-era public copy")
    }
}
if ($publicCopyIssues.Count -eq 0) {
    Add-Check "Public website copy" "OK" "Home, sermons, and 404 pages read as stable public pages"
} else {
    Add-Check "Public website copy" "FAIL" ($publicCopyIssues -join "; ")
}

$homeHtmlPath = Join-Path $root "index.html"
if (Test-Path -LiteralPath $homeHtmlPath) {
    $homeHtml = Get-Content -Raw -LiteralPath $homeHtmlPath
    if ($homeHtml -match 'id="first-visit-guide"' -and
        $homeHtml -match "First time at Fillmore\?" -and
        $homeHtml -match "Sunday School starts at 9:00 AM" -and
        $homeHtml -match "Children are welcome in worship" -and
        $homeHtml -match "Get Directions" -and
        $homeHtml -match "Ask a Question") {
        Add-Check "Homepage visitor guide" "OK" "Homepage includes first-visit guidance, Sunday timing, family note, directions, and contact action"
    } else {
        Add-Check "Homepage visitor guide" "FAIL" "Homepage is missing first-visit guidance, timing, family note, directions, or contact action"
    }
} else {
    Add-Check "Homepage visitor guide" "FAIL" "index.html is missing"
}

$brandAssetIssues = New-Object System.Collections.Generic.List[string]
$fullLogoPath = Join-Path $root "images\fcc-logo.png"
$navLogoPath = Join-Path $root "images\fcc-logo-mark.png"
$faviconPath = Join-Path $root "favicon.svg"
$siteManifestPath = Join-Path $root "site.webmanifest"
if (Test-Path -LiteralPath $fullLogoPath) {
    if ((Get-Item -LiteralPath $fullLogoPath).Length -lt 100000) {
        $brandAssetIssues.Add("images/fcc-logo.png is unexpectedly small for the official full logo")
    }
} else {
    $brandAssetIssues.Add("images/fcc-logo.png is missing")
}

if (Test-Path -LiteralPath $navLogoPath) {
    if ((Get-Item -LiteralPath $navLogoPath).Length -lt 10000) {
        $brandAssetIssues.Add("images/fcc-logo-mark.png is unexpectedly small")
    }
} else {
    $brandAssetIssues.Add("images/fcc-logo-mark.png is missing")
}

if (Test-Path -LiteralPath $faviconPath) {
    $faviconText = Get-Content -Raw -LiteralPath $faviconPath
    if ($faviconText -notmatch "<svg\b" -or $faviconText -notmatch "#173247" -or $faviconText -notmatch "Fillmore Christian Church") {
        $brandAssetIssues.Add("favicon.svg does not look like the Fillmore-branded SVG")
    }
} else {
    $brandAssetIssues.Add("favicon.svg is missing")
}

if (Test-Path -LiteralPath $siteManifestPath) {
    try {
        $siteManifest = Get-Content -Raw -LiteralPath $siteManifestPath | ConvertFrom-Json
        $manifestIconSources = @($siteManifest.icons | ForEach-Object { $_.src })
        if ($siteManifest.name -ne "Fillmore Christian Church") { $brandAssetIssues.Add("manifest name is unexpected") }
        if ($siteManifest.short_name -ne "Fillmore Christian") { $brandAssetIssues.Add("manifest short_name is unexpected") }
        if ($siteManifest.theme_color -ne "#173247") { $brandAssetIssues.Add("manifest theme_color is unexpected") }
        if ("favicon.svg" -notin $manifestIconSources) { $brandAssetIssues.Add("manifest does not reference favicon.svg") }
    } catch {
        $brandAssetIssues.Add("site.webmanifest is not valid JSON: $($_.Exception.Message)")
    }
} else {
    $brandAssetIssues.Add("site.webmanifest is missing")
}

if ($brandAssetIssues.Count -eq 0) {
    Add-Check "Owned brand assets" "OK" "Official FCC logo, compact navigation mark, favicon.svg, and site.webmanifest are self-hosted and Fillmore-branded"
} else {
    Add-Check "Owned brand assets" "FAIL" ($brandAssetIssues -join "; ")
}

$fontAssetIssues = New-Object System.Collections.Generic.List[string]
$fontFiles = @(
    "fonts\playfair-display-latin-400-700.woff2",
    "fonts\source-sans-3-latin-400-700.woff2"
)
foreach ($fontFile in $fontFiles) {
    $fontPath = Join-Path $root $fontFile
    if (-not (Test-Path -LiteralPath $fontPath)) {
        $fontAssetIssues.Add("$fontFile is missing")
    } elseif ((Get-Item -LiteralPath $fontPath).Length -lt 10000) {
        $fontAssetIssues.Add("$fontFile looks too small to be a valid font")
    }
}

$cssPath = Join-Path $root "css\style.css"
if (Test-Path -LiteralPath $cssPath) {
    $cssText = Get-Content -Raw -LiteralPath $cssPath
    if ($cssText -notmatch "@font-face" -or $cssText -notmatch "playfair-display-latin-400-700\.woff2" -or $cssText -notmatch "source-sans-3-latin-400-700\.woff2") {
        $fontAssetIssues.Add("css/style.css does not load the self-hosted fonts")
    }
    if ($cssText -match "fonts\.googleapis\.com|fonts\.gstatic\.com") {
        $fontAssetIssues.Add("css/style.css still references Google-hosted fonts")
    }
} else {
    $fontAssetIssues.Add("css/style.css is missing")
}

if ($fontAssetIssues.Count -eq 0) {
    Add-Check "Self-hosted fonts" "OK" "Playfair Display and Source Sans 3 are served from local WOFF2 assets"
} else {
    Add-Check "Self-hosted fonts" "FAIL" ($fontAssetIssues -join "; ")
}

$locationPanelIssues = New-Object System.Collections.Generic.List[string]
foreach ($relativePath in @("index.html", "about.html", "contact.html")) {
    $htmlPath = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $htmlPath)) {
        $locationPanelIssues.Add("$relativePath is missing")
        continue
    }

    $html = Get-Content -Raw -LiteralPath $htmlPath
    if ($html -match "google\.com/maps/embed|<iframe") {
        $locationPanelIssues.Add("$relativePath still embeds third-party map content")
    }
    if ($html -notmatch "location-panel" -or $html -notmatch "Get Directions" -or $html -notmatch "310 N\. Florence Street") {
        $locationPanelIssues.Add("$relativePath is missing the self-hosted location panel")
    }
}

if ($locationPanelIssues.Count -eq 0) {
    Add-Check "Self-hosted location panels" "OK" "Home, about, and contact pages use local location panels instead of embedded maps"
} else {
    Add-Check "Self-hosted location panels" "FAIL" ($locationPanelIssues -join "; ")
}

$contactCardPath = Join-Path $root "contact.vcf"
if (Test-Path -LiteralPath $contactCardPath) {
    $contactCardText = Get-Content -Raw -LiteralPath $contactCardPath
    $contactHtml = Get-Content -Raw -LiteralPath (Join-Path $root "contact.html")
    $contactCardIssues = New-Object System.Collections.Generic.List[string]
    if ($contactCardText -notmatch "(?m)^BEGIN:VCARD") { $contactCardIssues.Add("missing VCARD start") }
    if ($contactCardText -notmatch "(?m)^FN:Fillmore Christian Church") { $contactCardIssues.Add("missing church name") }
    if ($contactCardText -notmatch "church@fillmorechristian\.org") { $contactCardIssues.Add("missing church email") }
    if ($contactCardText -notmatch "310 N\. Florence Street") { $contactCardIssues.Add("missing street address") }
    if ($contactHtml -notmatch 'href="contact\.vcf"' -or $contactHtml -notmatch '<link\s+rel="alternate"\s+type="text/vcard"') {
        $contactCardIssues.Add("contact page does not link or advertise contact.vcf")
    }
    if ($contactHtml -notmatch 'data-mailto="church@fillmorechristian\.org"' -or
        $contactHtml -notmatch 'data-status-target="contact-form-status"' -or
        $contactHtml -notmatch 'id="contact-form-status"\s+class="form-status"\s+aria-live="polite"' -or
        $contactHtml -notmatch 'data-copy-value="church@fillmorechristian\.org"' -or
        $contactHtml -notmatch 'id="contact-email-copy-status"') {
        $contactCardIssues.Add("contact page is missing the static mailto form status or copyable email fallback")
    }
    $homeHtml = Get-Content -Raw -LiteralPath (Join-Path $root "index.html")
    if ($homeHtml -notmatch 'data-mailto="church@fillmorechristian\.org"' -or
        $homeHtml -notmatch 'data-status-target="home-contact-form-status"' -or
        $homeHtml -notmatch 'id="home-contact-form-status"\s+class="form-status"\s+aria-live="polite"' -or
        $homeHtml -notmatch 'data-copy-value="church@fillmorechristian\.org"' -or
        $homeHtml -notmatch 'id="home-email-copy-status"') {
        $contactCardIssues.Add("home page is missing the static contact form status or copyable email fallback")
    }

    $mainScriptText = Get-Content -Raw -LiteralPath (Join-Path $root "js\main.js")
    if ($mainScriptText -notmatch "data-status-target" -or $mainScriptText -notmatch "church@fillmorechristian\.org" -or $mainScriptText -notmatch "email app should now have a draft") {
        $contactCardIssues.Add("main script is missing contact form status messaging")
    }

    if ($contactCardIssues.Count -eq 0) {
        Add-Check "Self-hosted contact card" "OK" "contact.vcf, static mailto forms with status messaging, and copyable email fallbacks publish church contact details"
    } else {
        Add-Check "Self-hosted contact card" "FAIL" ($contactCardIssues -join "; ")
    }
} else {
    Add-Check "Self-hosted contact card" "FAIL" "contact.vcf is missing"
}

$calendarPath = Join-Path $root "events.ics"
if (Test-Path -LiteralPath $calendarPath) {
    $calendarText = Get-Content -Raw -LiteralPath $calendarPath
    $calendarIssues = New-Object System.Collections.Generic.List[string]
    $eventsScriptPath = Join-Path $root "js\events.js"
    if ($calendarText -notmatch "(?m)^BEGIN:VCALENDAR") { $calendarIssues.Add("missing VCALENDAR start") }
    if ($calendarText -notmatch "(?m)^SUMMARY:Sunday School") { $calendarIssues.Add("missing Sunday School event") }
    if ($calendarText -notmatch "(?m)^SUMMARY:Sunday Worship") { $calendarIssues.Add("missing Sunday Worship event") }
    if ($calendarText -notmatch "(?m)^RRULE:FREQ=WEEKLY;BYDAY=SU") { $calendarIssues.Add("missing weekly Sunday recurrence") }
    if ($calendarText -notmatch "TZID=America/Chicago") { $calendarIssues.Add("missing America/Chicago timezone reference") }

    $indexHtml = Get-Content -Raw -LiteralPath (Join-Path $root "index.html")
    $eventsHtml = Get-Content -Raw -LiteralPath (Join-Path $root "events.html")
    if ($indexHtml -notmatch 'href="events\.ics"' -or $eventsHtml -notmatch 'href="events\.ics"') {
        $calendarIssues.Add("index or events page does not link events.ics")
    }
    if ($eventsHtml -notmatch '<link\s+rel="alternate"\s+type="text/calendar"') {
        $calendarIssues.Add("events page missing calendar autodiscovery")
    }
    if ($eventsHtml -notmatch '<script type="application/ld\+json">' -or
        $eventsHtml -notmatch '"@type": "ItemList"' -or
        $eventsHtml -notmatch '"name": "Sunday School"' -or
        $eventsHtml -notmatch '"name": "Sunday Worship"' -or
        $eventsHtml -notmatch '"scheduleTimezone": "America/Chicago"') {
        $calendarIssues.Add("events page is missing structured recurring event metadata")
    }
    $eventJsonMatch = [regex]::Match($eventsHtml, '(?s)<script type="application/ld\+json">\s*(.*?)\s*</script>')
    if ($eventJsonMatch.Success) {
        try {
            $eventJson = $eventJsonMatch.Groups[1].Value | ConvertFrom-Json
            $eventItems = @($eventJson.itemListElement)
            if ($eventJson.'@type' -ne "ItemList" -or $eventItems.Count -ne 2) {
                $calendarIssues.Add("events structured data does not contain the expected two-item schedule")
            }
        } catch {
            $calendarIssues.Add("events structured data is not valid JSON")
        }
    }
    if ($eventsHtml -notmatch 'id="calendar-feed-url"' -or
        $eventsHtml -notmatch 'data-copy-value="https://www\.fillmorechristian\.org/events\.ics"' -or
        $eventsHtml -notmatch 'id="calendar-copy-status"\s+class="copy-status"\s+aria-live="polite"') {
        $calendarIssues.Add("events page is missing the copyable calendar feed URL")
    }
    if (Test-Path -LiteralPath $eventsScriptPath) {
        $eventsScript = Get-Content -Raw -LiteralPath $eventsScriptPath
        if ($eventsScript -notmatch "events\.ics") { $calendarIssues.Add("events script does not load the self-hosted iCal feed") }
        if ($eventsScript -match "googleapis|GOOGLE_CALENDAR_ID|GOOGLE_API_KEY") { $calendarIssues.Add("events script still references Google Calendar API") }
        if ($eventsScript -notmatch "generateUpcomingOccurrences" -or $eventsScript -notmatch "loadUpcomingEvents\(upcomingContainer, 4\)") {
            $calendarIssues.Add("events script does not expand weekly recurring events into upcoming dated occurrences")
        }
    } else {
        $calendarIssues.Add("js/events.js is missing")
    }

    if ($calendarIssues.Count -eq 0) {
        Add-Check "Self-hosted event calendar" "OK" "events.ics publishes recurring Sunday School and worship schedule, and the events UI loads and exposes a copyable feed locally"
    } else {
        Add-Check "Self-hosted event calendar" "FAIL" ($calendarIssues -join "; ")
    }
} else {
    Add-Check "Self-hosted event calendar" "FAIL" "events.ics is missing"
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

$deployScriptPath = Join-Path $root "scripts\deploy-cloudflare-pages.ps1"
if (Test-Path -LiteralPath $deployScriptPath) {
    $deployScriptText = Get-Content -Raw -LiteralPath $deployScriptPath
    if ($deployScriptText -match "wake-byte" -and $deployScriptText -match "test-cloudflare-pages-local\.ps1" -and $deployScriptText -match "pages[\s`"']*,[\s`"']*deploy") {
        Add-Check "Cloudflare deploy script" "OK" "Guarded Pages deploy script checks owner, preflight, and Wrangler deploy"
    } else {
        Add-Check "Cloudflare deploy script" "FAIL" "Deploy script is missing owner guard, preflight, or Wrangler deploy command"
    }
} else {
    Add-Check "Cloudflare deploy script" "FAIL" "scripts\deploy-cloudflare-pages.ps1 is missing"
}

$pagesWorkflowPath = Join-Path $root ".github\workflows\pages.yml"
if (Test-Path -LiteralPath $pagesWorkflowPath) {
    $pagesWorkflowText = Get-Content -Raw -LiteralPath $pagesWorkflowPath
    if ($pagesWorkflowText -match "(?m)^\s+readiness:\s*$" -and
        $pagesWorkflowText -match "test-migration-readiness\.ps1\s+-SkipRemote\s+-SkipLocalAudioBackup" -and
        $pagesWorkflowText -match "FORCE_JAVASCRIPT_ACTIONS_TO_NODE24:\s+true" -and
        $pagesWorkflowText -match "actions/checkout@v6" -and
        $pagesWorkflowText -match "actions/setup-node@v6" -and
        $pagesWorkflowText -match "actions/upload-pages-artifact@v4" -and
        $pagesWorkflowText -match "runs-on:\s+windows-2025-vs2026" -and
        $pagesWorkflowText -match "(?s)needs:\s*\r?\n\s+- build\s*\r?\n\s+- readiness") {
        Add-Check "Staging CI readiness gate" "OK" "GitHub Pages deploy waits for the migration readiness job and uses Node 24-ready Actions/runtime labels"
    } else {
        Add-Check "Staging CI readiness gate" "FAIL" "GitHub Pages workflow is missing the readiness job requirement, Node 24-ready actions, or explicit Windows runner label"
    }
} else {
    Add-Check "Staging CI readiness gate" "FAIL" ".github\workflows\pages.yml is missing"
}

$statusScriptPath = Join-Path $root "scripts\show-migration-status.ps1"
$packageJsonPath = Join-Path $root "package.json"
if ((Test-Path -LiteralPath $statusScriptPath) -and (Test-Path -LiteralPath $packageJsonPath)) {
    $statusScriptText = Get-Content -Raw -LiteralPath $statusScriptPath
    $packageJsonText = Get-Content -Raw -LiteralPath $packageJsonPath
    if ($statusScriptText -match "npx wrangler login" -and
        $statusScriptText -match "Squarespace renewal" -and
        $statusScriptText -match "wakefieldhare-collab" -and
        $statusScriptText -match "www\.fillmorechristian\.org" -and
        $statusScriptText -match "apply:cloudflare-dns" -and
        $statusScriptText -match "Zone:DNS Edit" -and
        $packageJsonText -match '"status:migration"') {
        Add-Check "Migration status command" "OK" "Read-only status script summarizes owner, renewal, audio, R2, DNS, staging, auth state, and DNS-token next step"
    } else {
        Add-Check "Migration status command" "FAIL" "Migration status script or npm alias is missing key ownership/auth/audio checks"
    }
} else {
    Add-Check "Migration status command" "FAIL" "scripts\show-migration-status.ps1 or package.json is missing"
}

$cancellationScriptPath = Join-Path $root "scripts\test-thechurchco-cancellation-readiness.ps1"
$domainTransferScriptPath = Join-Path $root "scripts\test-domain-transfer-readiness.ps1"
$audioMigrationScriptPath = Join-Path $root "scripts\migrate-cloudflare-audio.ps1"
$audioUploadScriptPath = Join-Path $root "scripts\upload-podcast-audio-to-r2.ps1"
$audioUploadVerifierScriptPath = Join-Path $root "scripts\test-r2-audio-upload.ps1"
$publicAudioScriptPath = Join-Path $root "scripts\test-r2-public-audio.ps1"
$mediaDomainScriptPath = Join-Path $root "scripts\configure-r2-media-domain.ps1"
$cutoverScriptPath = Join-Path $root "scripts\complete-cloudflare-cutover.ps1"
if (Test-Path -LiteralPath $domainTransferScriptPath) {
    $domainTransferScriptText = Get-Content -Raw -LiteralPath $domainTransferScriptPath
    $packageJsonPath = Join-Path $root "package.json"
    $packageJsonText = if (Test-Path -LiteralPath $packageJsonPath) { Get-Content -Raw -LiteralPath $packageJsonPath } else { "" }
    if ($domainTransferScriptText -match "Squarespace renewal deadline" -and
        $domainTransferScriptText -match "Cloudflare DNS active" -and
        $domainTransferScriptText -match "Mail MX preserved" -and
        $domainTransferScriptText -match "Old website DNS removed" -and
        $domainTransferScriptText -match "Do not disable Squarespace auto-renew" -and
        $packageJsonText -match '"verify:domain-transfer"') {
        Add-Check "Domain transfer safety gate" "OK" "Registrar transfer verifier guards renewal timing, Cloudflare DNS, mail, and old website DNS"
    } else {
        Add-Check "Domain transfer safety gate" "FAIL" "Domain transfer verifier is missing renewal, DNS, mail, old-record, or npm-script checks"
    }
} else {
    Add-Check "Domain transfer safety gate" "FAIL" "scripts\test-domain-transfer-readiness.ps1 is missing"
}

if (Test-Path -LiteralPath $cancellationScriptPath) {
    $cancellationScriptText = Get-Content -Raw -LiteralPath $cancellationScriptPath
    if ($cancellationScriptText -match "Cloudflare nameservers" -and
        $cancellationScriptText -match "Production audio independence" -and
        $cancellationScriptText -match "www\.fillmorechristian\.org" -and
        $cancellationScriptText -match "Production podcast page" -and
        $cancellationScriptText -match "sermon-audio-only" -and
        $cancellationScriptText -match "data-has-audio" -and
        $cancellationScriptText -match "test-r2-public-audio\.ps1" -and
        $cancellationScriptText -match "BaseUrlOverride" -and
        $cancellationScriptText -match "Production R2 media route" -and
        $cancellationScriptText -match "Do not cancel TheChurchCo yet") {
        Add-Check "TheChurchCo cancellation gate" "OK" "Production cancellation verifier checks DNS, static site, podcast page, sermon archive filters, mail, feed, audio independence, and the production Pages /media route"
    } else {
        Add-Check "TheChurchCo cancellation gate" "FAIL" "Cancellation verifier is missing DNS, podcast page, sermon archive filter, audio independence, production media-route, or stop-condition checks"
    }
} else {
    Add-Check "TheChurchCo cancellation gate" "FAIL" "scripts\test-thechurchco-cancellation-readiness.ps1 is missing"
}

if ((Test-Path -LiteralPath $audioMigrationScriptPath) -and (Test-Path -LiteralPath $publicAudioScriptPath) -and (Test-Path -LiteralPath $cutoverScriptPath)) {
    $audioMigrationScriptText = Get-Content -Raw -LiteralPath $audioMigrationScriptPath
    $publicAudioScriptText = Get-Content -Raw -LiteralPath $publicAudioScriptPath
    $cutoverScriptText = Get-Content -Raw -LiteralPath $cutoverScriptPath
    $packageJsonPath = Join-Path $root "package.json"
    $packageJsonText = if (Test-Path -LiteralPath $packageJsonPath) { Get-Content -Raw -LiteralPath $packageJsonPath } else { "" }
    if ($audioMigrationScriptText -match "test-r2-public-audio\.ps1" -and
        $audioMigrationScriptText -match "VerifyPublicMedia" -and
        $audioMigrationScriptText -match "SkipPublicMediaVerify" -and
        $audioMigrationScriptText -match "www\.fillmorechristian\.org/media" -and
        $publicAudioScriptText -match "PublicUrl" -and
        $publicAudioScriptText -match "Content-Length" -and
        $publicAudioScriptText -match "Content-Type" -and
        $cutoverScriptText -match "test-dns-cutover\.ps1" -and
        $cutoverScriptText -match "test-r2-public-audio\.ps1" -and
        $cutoverScriptText -match "BaseUrlOverride" -and
        $cutoverScriptText -match "ProductionBaseUrl" -and
        $cutoverScriptText -match "/media" -and
        $cutoverScriptText -match "StagingBaseUrl" -and
        $cutoverScriptText -match "RequireIndependentAudio" -and
        $cutoverScriptText -match "ExpectedCloudflareNameservers" -and
        $packageJsonText -match '"complete:cloudflare-cutover"') {
        Add-Check "R2 public audio preflight" "OK" "Audio migration verifies R2 public URLs; cutover checks the Pages /media route and independent podcast feed"
    } else {
        Add-Check "R2 public audio preflight" "FAIL" "Audio migration is missing R2 public URL verification, Pages media-route cutover checks, or npm aliases"
    }
} else {
    Add-Check "R2 public audio preflight" "FAIL" "scripts\migrate-cloudflare-audio.ps1, scripts\complete-cloudflare-cutover.ps1, or scripts\test-r2-public-audio.ps1 is missing"
}

if ((Test-Path -LiteralPath $audioMigrationScriptPath) -and (Test-Path -LiteralPath $audioUploadScriptPath) -and (Test-Path -LiteralPath $audioUploadVerifierScriptPath)) {
    $audioMigrationScriptText = if ($audioMigrationScriptText) { $audioMigrationScriptText } else { Get-Content -Raw -LiteralPath $audioMigrationScriptPath }
    $audioUploadScriptText = Get-Content -Raw -LiteralPath $audioUploadScriptPath
    $audioUploadVerifierScriptText = Get-Content -Raw -LiteralPath $audioUploadVerifierScriptPath
    if ($audioMigrationScriptText -match "Assert-CloudflareAuth" -and
        $audioUploadScriptText -match "Assert-CloudflareAuth" -and
        $audioUploadVerifierScriptText -match "Assert-CloudflareAuth" -and
        $audioMigrationScriptText -match "wrangler login" -and
        $audioUploadScriptText -match "wrangler login" -and
        $audioUploadVerifierScriptText -match "wrangler login") {
        Add-Check "R2 Cloudflare auth guard" "OK" "Audio migration, direct upload, and R2 verifier fail early when Wrangler is not authenticated"
    } else {
        Add-Check "R2 Cloudflare auth guard" "FAIL" "R2 migration scripts are missing a clear Cloudflare authentication preflight"
    }
} else {
    Add-Check "R2 Cloudflare auth guard" "FAIL" "R2 migration, upload, or verifier script is missing"
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

$podcastOwnershipIssues = New-Object System.Collections.Generic.List[string]
$canonicalPodcastFeedUrl = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast"
$ownedPodcastGenerator = "Fillmore Christian Church static podcast feed"
$doubleEncodedNbsp = -join ([char[]]@(
    0x00C3,
    0x0192,
    0x00E2,
    0x20AC,
    0x0161,
    0x00C3,
    0x201A,
    0x00C2,
    0x00A0
))
foreach ($relativePath in $feedPaths) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        $podcastOwnershipIssues.Add("$relativePath is missing")
        continue
    }

    $feedText = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    if ($feedText -notmatch "<title>Fillmore Christian Church</title>") {
        $podcastOwnershipIssues.Add("$relativePath has an unexpected channel title")
    }
    if ($feedText -notmatch "<atom:link\b[^>]*href=`"$([regex]::Escape($canonicalPodcastFeedUrl))`"[^>]*rel=`"self`"[^>]*type=`"application/rss\+xml`"[^>]*/>") {
        $podcastOwnershipIssues.Add("$relativePath is missing the canonical atom self link")
    }
    if ($feedText -notmatch "<itunes:owner>\s*<itunes:name>Fillmore Christian Church</itunes:name>\s*<itunes:email>church@fillmorechristian\.org</itunes:email>\s*</itunes:owner>") {
        $podcastOwnershipIssues.Add("$relativePath is missing complete iTunes owner metadata")
    }
    if ($feedText -notmatch "<image>\s*<url>https://www\.fillmorechristian\.org/images/podcast-cover\.jpg</url>\s*<title>Fillmore Christian Church</title>\s*<link>https://www\.fillmorechristian\.org</link>\s*</image>") {
        $podcastOwnershipIssues.Add("$relativePath is missing owned RSS image metadata")
    }
    if ($feedText -notmatch "<itunes:subtitle>[^<]+</itunes:subtitle>" -or $feedText -notmatch "<googleplay:explicit>no</googleplay:explicit>") {
        $podcastOwnershipIssues.Add("$relativePath is missing podcast directory metadata")
    }
    if ($feedText -notmatch "<generator>$([regex]::Escape($ownedPodcastGenerator))</generator>" -or $feedText -match "wordpress\.org") {
        $podcastOwnershipIssues.Add("$relativePath still carries old generator metadata")
    }
    if ($feedText.Contains($doubleEncodedNbsp)) {
        $podcastOwnershipIssues.Add("$relativePath still contains double-encoded nonbreaking-space artifacts")
    }
}

if ($podcastOwnershipIssues.Count -eq 0) {
    Add-Check "Podcast ownership metadata" "OK" "Feed copies identify Fillmore Christian Church as owner and generator"
} else {
    Add-Check "Podcast ownership metadata" "FAIL" ($podcastOwnershipIssues -join "; ")
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

    $expectedAudioCards = if ($feedEnclosureCounts.ContainsKey($feedPaths[0])) { $feedEnclosureCounts[$feedPaths[0]] } else { 0 }
    $sermonYears = [regex]::Matches($sermonsHtml, 'data-year="(\d{4})"') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    $expectedYearRange = if ($sermonYears.Count -gt 1) {
        "$($sermonYears[0])-$($sermonYears[$sermonYears.Count - 1])"
    } elseif ($sermonYears.Count -eq 1) {
        $sermonYears[0]
    } else {
        ""
    }
    if ($expectedCards -gt 0 -and
        $sermonsHtml -match 'id="sermon-archive-summary"' -and
        $sermonsHtml -match 'SERMON_ARCHIVE_SUMMARY_START' -and
        $sermonsHtml -match 'SERMON_ARCHIVE_SUMMARY_END' -and
        $sermonsHtml -match "<span class=`"archive-summary-value`">$expectedCards</span>\s*<span class=`"archive-summary-label`">messages archived</span>" -and
        $sermonsHtml -match "<span class=`"archive-summary-value`">$expectedAudioCards</span>\s*<span class=`"archive-summary-label`">with audio</span>" -and
        $expectedYearRange -and
        $sermonsHtml -match "<span class=`"archive-summary-value`">$([regex]::Escape($expectedYearRange))</span>\s*<span class=`"archive-summary-label`">teaching years</span>") {
        Add-Check "Sermon archive summary" "OK" "$expectedCards messages, $expectedAudioCards with audio, $expectedYearRange teaching years"
    } else {
        Add-Check "Sermon archive summary" "FAIL" "Archive summary is missing or does not match feed-derived counts and years"
    }

    $cardsWithYear = ([regex]::Matches($sermonsHtml, 'class="sermon-item[^"]*"\s+data-year="\d{4}"')).Count
    if ($expectedCards -gt 0 -and $cardsWithYear -eq $expectedCards) {
        Add-Check "Sermon year filter data" "OK" "$cardsWithYear static cards include feed-derived years"
    } else {
        Add-Check "Sermon year filter data" "FAIL" "$cardsWithYear static card year value(s), expected $expectedCards"
    }

    $cardsWithSortData = ([regex]::Matches($sermonsHtml, 'class="sermon-item[^"]*"\s+data-year="\d{4}"\s+data-has-audio="(?:true|false)"\s+data-sort-date="\d+"\s+data-title="[^"]+"')).Count
    if ($expectedCards -gt 0 -and $cardsWithSortData -eq $expectedCards) {
        Add-Check "Sermon sort data" "OK" "$cardsWithSortData static cards include date and title sort metadata"
    } else {
        Add-Check "Sermon sort data" "FAIL" "$cardsWithSortData static card sort value(s), expected $expectedCards"
    }

    $cardsWithAudioFlag = ([regex]::Matches($sermonsHtml, 'class="sermon-item[^"]*"\s+data-year="\d{4}"\s+data-has-audio="(?:true|false)"')).Count
    $audioCardCount = ([regex]::Matches($sermonsHtml, 'data-has-audio="true"')).Count
    if ($expectedCards -gt 0 -and $cardsWithAudioFlag -eq $expectedCards -and $audioCardCount -eq $expectedAudioCards -and $sermonsHtml -match 'id="sermon-audio-only"') {
        Add-Check "Sermon audio filter" "OK" "$audioCardCount cards have audio and the audio-only control is present"
    } else {
        Add-Check "Sermon audio filter" "FAIL" "$cardsWithAudioFlag audio flag(s), $audioCardCount audio card(s), expected $expectedCards flag(s) and $expectedAudioCards audio card(s)"
    }

    if ($sermonsHtml -match 'id="sermon-year"') {
        Add-Check "Sermon year filter control" "OK" "Archive page includes year filter control"
    } else {
        Add-Check "Sermon year filter control" "FAIL" "Archive page is missing #sermon-year"
    }

    if ($sermonsHtml -match 'id="sermon-sort"' -and $sermonsHtml -match 'value="newest"' -and $sermonsHtml -match 'value="oldest"' -and $sermonsHtml -match 'value="title"') {
        Add-Check "Sermon sort control" "OK" "Archive page includes newest, oldest, and title sort options"
    } else {
        Add-Check "Sermon sort control" "FAIL" "Archive page is missing #sermon-sort or expected sort options"
    }

    if ($sermonsHtml -match 'id="sermon-search"' -and $sermonsHtml -match 'id="sermon-clear"' -and $sermonsHtml -match 'id="sermon-share-link"' -and $sermonsHtml -match 'id="sermon-share-status"') {
        Add-Check "Sermon search controls" "OK" "Archive page includes search, clear, and copyable filtered-link controls"
    } else {
        Add-Check "Sermon search controls" "FAIL" "Archive page is missing #sermon-search, #sermon-clear, #sermon-share-link, or #sermon-share-status"
    }

    $sermonsScriptPath = Join-Path $root "js\sermons.js"
    if (Test-Path -LiteralPath $sermonsScriptPath) {
        $sermonsScriptText = Get-Content -Raw -LiteralPath $sermonsScriptPath
        if ($sermonsScriptText -match "URLSearchParams" -and
            $sermonsScriptText -match "history\.replaceState" -and
            $sermonsScriptText -match "applyArchiveStateFromUrl" -and
            $sermonsScriptText -match "updateArchiveUrl" -and
            $sermonsScriptText -match "updateArchiveShareLink" -and
            $sermonsScriptText -match "Showing all" -and
            $sermonsScriptText -match "Showing ") {
            Add-Check "Sermon filter deep links" "OK" "Archive filters can load from and write to URL query parameters and copy the current filtered link"
        } else {
            Add-Check "Sermon filter deep links" "FAIL" "Archive filters are missing URL query parameter persistence, copyable filtered-link sync, or clear count copy"
        }
    } else {
        Add-Check "Sermon filter deep links" "FAIL" "js\sermons.js is missing"
    }

    $expectedFeedUrl = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast"
    $podcastHtmlPath = Join-Path $root "podcast.html"
    $podcastHtml = if (Test-Path -LiteralPath $podcastHtmlPath) { Get-Content -Raw -LiteralPath $podcastHtmlPath } else { "" }
    if ($sermonsHtml -match 'href="podcast\.html"[^>]*>Subscribe</a>' -and
        $podcastHtml -match 'id="podcast-feed-url"' -and
        $podcastHtml -match 'data-copy-value="https://www\.fillmorechristian\.org/podcast-category/fillmore-christian/feed/podcast"' -and
        $podcastHtml -match 'class="podcast-subscription-grid"' -and
        $podcastHtml -match 'data-subscribe-option="apple"' -and
        $podcastHtml -match 'data-subscribe-option="spotify"' -and
        $podcastHtml -match 'data-subscribe-option="rss"' -and
        $podcastHtml -match [regex]::Escape($expectedFeedUrl) -and
        $podcastHtml -match '"@type": "PodcastSeries"') {
        Add-Check "Podcast subscribe controls" "OK" "Archive page links to an owned podcast landing page with app choices and a copyable canonical RSS feed URL"
    } else {
        Add-Check "Podcast subscribe controls" "FAIL" "Archive page or podcast landing page is missing subscribe controls, app choices, structured data, or the copyable canonical RSS feed URL"
    }

    $downloadLinks = ([regex]::Matches($sermonsHtml, 'class="sermon-download"')).Count
    $expectedDownloadLinks = if ($feedEnclosureCounts.ContainsKey($feedPaths[0])) { $feedEnclosureCounts[$feedPaths[0]] } else { 0 }
    if ($expectedDownloadLinks -gt 0 -and $downloadLinks -eq $expectedDownloadLinks) {
        Add-Check "Sermon audio downloads" "OK" "$downloadLinks downloadable audio link(s) match feed enclosures"
    } else {
        Add-Check "Sermon audio downloads" "FAIL" "$downloadLinks downloadable audio link(s), expected $expectedDownloadLinks from the podcast feed"
    }

    $mainScriptPath = Join-Path $root "js\main.js"
    if (Test-Path -LiteralPath $mainScriptPath) {
        $mainScriptText = Get-Content -Raw -LiteralPath $mainScriptPath
        if ($mainScriptText -match "document\.addEventListener\('play'" -and $mainScriptText -match "querySelectorAll\('audio'\)" -and $mainScriptText -match "\.pause\(\)") {
            Add-Check "Sermon audio playback guard" "OK" "Starting one audio player pauses the rest"
        } else {
            Add-Check "Sermon audio playback guard" "FAIL" "Main script is missing the one-at-a-time audio playback guard"
        }

        if ($mainScriptText -match "aria-expanded" -and
            $mainScriptText -match "aria-controls" -and
            $mainScriptText -match "setNavigationOpen" -and
            $mainScriptText -match "closeDropdowns" -and
            $mainScriptText -match "Escape") {
            Add-Check "Accessible navigation controls" "OK" "Mobile navigation exposes expanded state and closes from keyboard controls"
        } else {
            Add-Check "Accessible navigation controls" "FAIL" "Main script is missing accessible mobile navigation state handling"
        }
    } else {
        Add-Check "Sermon audio playback guard" "FAIL" "js\main.js is missing"
        Add-Check "Accessible navigation controls" "FAIL" "js\main.js is missing"
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

$homePath = Join-Path $root "index.html"
if ($feeds.ContainsKey($feedPaths[0]) -and (Test-Path -LiteralPath $homePath)) {
    $homeHtml = Get-Content -Raw -LiteralPath $homePath
    $latestAudioItem = @($feeds[$feedPaths[0]].rss.channel.item | Where-Object { $_.enclosure -and $_.enclosure.url } | Select-Object -First 1)
    $latestTitle = if ($latestAudioItem) { [string]$latestAudioItem.title } else { "" }
    $latestAudioUrl = if ($latestAudioItem) { [string]$latestAudioItem.enclosure.url } else { "" }
    $latestPageAudioUrl = ConvertTo-PageAudioUrl $latestAudioUrl

    if ($latestTitle -and
        $homeHtml -match 'id="latest-sermon"' -and
        $homeHtml -match [regex]::Escape($latestTitle) -and
        $homeHtml -match [regex]::Escape($latestPageAudioUrl) -and
        $homeHtml -match '<a\s+href="podcast\.html"\s+class="btn btn-outline">Subscribe to Podcast</a>' -and
        $homeHtml -match "Download Audio") {
        Add-Check "Homepage latest sermon" "OK" "Latest audio item is featured on the homepage"
    } else {
        Add-Check "Homepage latest sermon" "FAIL" "Homepage latest sermon block is missing, stale, or not linked to podcast subscription"
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

    $missingEpisodeNavigation = New-Object System.Collections.Generic.List[string]
    $missingEpisodeStructuredData = New-Object System.Collections.Generic.List[string]
    $missingEpisodeBrandAssets = New-Object System.Collections.Generic.List[string]
    $missingEpisodeCopyLinks = New-Object System.Collections.Generic.List[string]
    foreach ($slug in $uniqueEpisodeSlugs) {
        $episodePagePath = Join-Path $root "episode\$slug\index.html"
        if (-not (Test-Path -LiteralPath $episodePagePath)) {
            continue
        }

        $episodeHtml = Get-Content -Raw -LiteralPath $episodePagePath
        if ($episodeHtml -notmatch 'class="episode-nav"' -or $episodeHtml -notmatch "Newer Message" -or $episodeHtml -notmatch "Older Message") {
            $missingEpisodeNavigation.Add($slug)
        }
        if ($episodeHtml -notmatch '<script\s+type="application/ld\+json">(?s).*"@type":"PodcastEpisode"' -or $episodeHtml -notmatch '"isPartOf":\{"@type":"PodcastSeries","name":"Fillmore Christian"' -or $episodeHtml -notmatch '"publisher":\{"@type":"Church","name":"Fillmore Christian Church"') {
            $missingEpisodeStructuredData.Add($slug)
        }
        if ($episodeHtml -notmatch '<link\s+rel="icon"\s+href="../../favicon\.svg"\s+type="image/svg\+xml">' -or $episodeHtml -notmatch '<img\s+src="../../images/fcc-logo-mark\.png"\s+alt=""\s+class="nav-brand-logo"\s+aria-hidden="true">' -or $episodeHtml -notmatch '<a\s+href="../../podcast\.html">Podcast</a>' -or $episodeHtml -notmatch '<link\s+rel="manifest"\s+href="../../site\.webmanifest">' -or $episodeHtml -notmatch '<meta\s+name="theme-color"\s+content="#173247">') {
            $missingEpisodeBrandAssets.Add($slug)
        }
        $expectedEpisodeUrl = "https://www.fillmorechristian.org/episode/$slug/"
        if ($episodeHtml -notmatch 'id="episode-link-url"' -or $episodeHtml -notmatch [regex]::Escape('data-copy-value="' + $expectedEpisodeUrl + '"') -or $episodeHtml -notmatch 'id="episode-copy-status"') {
            $missingEpisodeCopyLinks.Add($slug)
        }
    }
    if ($missingEpisodeNavigation.Count -gt 0) {
        $episodeIssues.Add("episode navigation missing from: $($missingEpisodeNavigation -join ', ')")
    }
    if ($missingEpisodeStructuredData.Count -gt 0) {
        $episodeIssues.Add("episode structured data missing from: $($missingEpisodeStructuredData -join ', ')")
    }
    if ($missingEpisodeBrandAssets.Count -gt 0) {
        $episodeIssues.Add("episode brand asset metadata missing from: $($missingEpisodeBrandAssets -join ', ')")
    }
    if ($missingEpisodeCopyLinks.Count -gt 0) {
        $episodeIssues.Add("episode copyable canonical links missing from: $($missingEpisodeCopyLinks -join ', ')")
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
$mediaFunctionPath = Join-Path $root "functions\media\[[path]].js"
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
    if (Test-Path -LiteralPath $mediaFunctionPath) {
        $mediaFunctionText = Get-Content -Raw -LiteralPath $mediaFunctionPath
        if ($mediaFunctionText -notmatch "SERMON_AUDIO" -or $mediaFunctionText -notmatch "handleMediaRequest" -or $mediaFunctionText -notmatch "Accept-Ranges") {
            $legacyRedirectIssues.Add("functions\media\[[path]].js does not include the Pages R2 media handler")
        }
    } else {
        $legacyRedirectIssues.Add("functions\media\[[path]].js is missing")
    }

    if (Test-Path -LiteralPath $routesPath) {
        try {
            $routes = Get-Content -Raw -LiteralPath $routesPath | ConvertFrom-Json
            if ($routes.version -ne 1 -or "/" -notin @($routes.include) -or "/media/*" -notin @($routes.include)) {
                $legacyRedirectIssues.Add("_routes.json does not include the root and /media/* paths for Pages Functions")
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

    if ($SkipLocalAudioBackup) {
        Add-Check "Podcast audio backup coverage" "WARN" "Local audio backup file check skipped for CI; run without -SkipLocalAudioBackup before canceling TheChurchCo"
    } elseif (Test-Path -LiteralPath $audioDir) {
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
    $dnsImportVerifierPath = Join-Path $root "scripts\test-cloudflare-dns-import-readiness.ps1"
    if (-not (Test-Path -LiteralPath $dnsImportVerifierPath)) {
        $dnsIssues.Add("DNS import readiness verifier is missing")
    }
    $dnsApplyScriptPath = Join-Path $root "scripts\apply-cloudflare-dns-cutover-records.ps1"
    if (-not (Test-Path -LiteralPath $dnsApplyScriptPath)) {
        $dnsIssues.Add("Cloudflare DNS apply script is missing")
    }
    $packageJsonText = Get-Content -Raw -LiteralPath (Join-Path $root "package.json")
    if ($packageJsonText -notmatch '"verify:dns-import"\s*:\s*"powershell -ExecutionPolicy Bypass -File scripts/test-cloudflare-dns-import-readiness\.ps1"') {
        $dnsIssues.Add("package.json is missing verify:dns-import script")
    }
    if ($packageJsonText -notmatch '"apply:cloudflare-dns"\s*:\s*"powershell -ExecutionPolicy Bypass -File scripts/apply-cloudflare-dns-cutover-records\.ps1"') {
        $dnsIssues.Add("package.json is missing apply:cloudflare-dns script")
    }
    $requiredDnsRows = @(
        @{ Name = "fillmorechristian.org"; Type = "MX"; Value = "mxa.mailgun.org"; Priority = "10" },
        @{ Name = "fillmorechristian.org"; Type = "MX"; Value = "mxb.mailgun.org"; Priority = "10" },
        @{ Name = "fillmorechristian.org"; Type = "TXT"; Value = "v=spf1 include:mailgun.org ~all"; Priority = "" },
        @{ Name = "fillmorechristian.org"; Type = "TXT"; Value = "MS=ms48673064"; Priority = "" },
        @{ Name = "pic._domainkey.fillmorechristian.org"; Type = "TXT"; Value = "k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDDMspMJXAZ/D2ygNZBnGbLY5Z9DjNaNiLDjKY79O1JYgtYlkOERm5SVNOb1nKavNA98hqTLLN+1N7LQGoaeqY0O8ddDa8NclV57cTekdu4by/fcKN+8zycaOE2HRH9hZP1RLNmandRuUQfmTYMrXIWrjBU0xaQdbXZHMP0pN5FuQIDAQAB"; Priority = "" },
        @{ Name = "cbsw2pw4sdud.fillmorechristian.org"; Type = "CNAME"; Value = "gv-6xwzpofnvqguxs.dv.googlehosted.com"; Priority = "" },
        @{ Name = "4jb3ni34htue.fillmorechristian.org"; Type = "CNAME"; Value = "gv-xvljhthdwk5dxh.dv.googlehosted.com"; Priority = "" },
        @{ Name = "334xc4sml6cf.fillmorechristian.org"; Type = "CNAME"; Value = "gv-ujhethalu73pqt.dv.googlehosted.com"; Priority = "" }
    )
    foreach ($required in $requiredDnsRows) {
        $match = @($dnsRows | Where-Object {
            $_.Name -eq $required.Name -and
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
    if ($zoneText -notmatch "mxa\.mailgun\.org\." -or $zoneText -notmatch "mxb\.mailgun\.org\." -or $zoneText -notmatch "include:mailgun\.org" -or $zoneText -notmatch "pic\._domainkey" -or $zoneText -notmatch "gv-6xwzpofnvqguxs\.dv\.googlehosted\.com\." -or $zoneText -notmatch "gv-xvljhthdwk5dxh\.dv\.googlehosted\.com\." -or $zoneText -notmatch "gv-ujhethalu73pqt\.dv\.googlehosted\.com\.") {
        $dnsIssues.Add("zone file does not contain expected mail, DKIM, and Google verification records")
    }

    $dnsPlanText = Get-Content -Raw -LiteralPath $dnsPlanPath
    if ($dnsPlanText -notmatch "A ``fillmorechristian\.org``.*77\.83\.141\.16" -or $dnsPlanText -notmatch "CNAME ``www\.fillmorechristian\.org``.*ssl\.thechurchco\.com") {
        $dnsIssues.Add("cutover plan does not explicitly list old website records to replace")
    }
    if ($dnsPlanText -notmatch "SERMON_AUDIO" -or $dnsPlanText -notmatch "https://www\.fillmorechristian\.org/media/" -or $dnsPlanText -notmatch 'same-origin `/media/<object-key>`') {
        $dnsIssues.Add("cutover plan does not explicitly include the Pages R2 media route and verification")
    }
    if ($dnsPlanText -notmatch "CNAME ``fillmorechristian\.org`` -> ``fillmorechristian-website\.pages\.dev``" -or
        $dnsPlanText -notmatch "CNAME ``www\.fillmorechristian\.org`` -> ``fillmorechristian-website\.pages\.dev``") {
        $dnsIssues.Add("cutover plan does not explicitly list the Cloudflare Pages DNS records")
    }

    if ($dnsIssues.Count -eq 0) {
        Add-Check "Cloudflare DNS cutover artifacts" "OK" "$($dnsRows.Count) preserve records cover mail and verification without old website records; plan includes the Pages R2 media route"
    } else {
        Add-Check "Cloudflare DNS cutover artifacts" "FAIL" ($dnsIssues -join "; ")
    }
} else {
    Add-Check "Cloudflare DNS cutover artifacts" "WARN" "DNS cutover artifacts are missing; run scripts\build-cloudflare-dns-plan.ps1"
}

if (-not $SkipRemote) {
    $remotePaths = @("", "about.html", "beliefs.html", "team.html", "events.html", "sermons.html", "podcast.html", "contact.html")
    if ($sampleEpisodePath) {
        $remotePaths += $sampleEpisodePath
    }
    $remotePaths += @("podcast-category/fillmore-christian/feed/podcast", "events.ics", "contact.vcf", "favicon.svg", "site.webmanifest", "robots.txt", "sitemap.xml")

    foreach ($path in $remotePaths) {
        $url = Join-Url $StagingBaseUrl $path
        try {
            $remoteResponse = Invoke-RemoteWebRequest -Url $url -MaxRedirects 5
            $response = $remoteResponse.Response
            $redirectNote = if ($remoteResponse.RedirectCount -gt 0) { " after $($remoteResponse.RedirectCount) redirect(s) to $($remoteResponse.FinalUrl)" } else { "" }
            Add-Check "Staging URL: /$path" "OK" "HTTP $($response.StatusCode)$redirectNote"

            if ($path -in @("", "about.html", "beliefs.html", "team.html", "events.html", "sermons.html", "podcast.html", "contact.html") -or $path -eq $sampleEpisodePath) {
                $expectedCanonical = if ($path -eq "") {
                    "https://www.fillmorechristian.org/"
                } elseif ($path -eq $sampleEpisodePath) {
                    "https://www.fillmorechristian.org/$path"
                } else {
                    "https://www.fillmorechristian.org/$path"
                }

                $hasCanonical = $response.Content -match "<link\s+rel=`"canonical`"\s+href=`"$([regex]::Escape($expectedCanonical))`""
                $hasPodcastAlternate = $response.Content -match "<link\s+rel=`"alternate`"\s+type=`"application/rss\+xml`"\s+title=`"Fillmore Christian Podcast`"\s+href=`"https://www\.fillmorechristian\.org/podcast-category/fillmore-christian/feed/podcast`""
                $hasOpenGraph = $response.Content -match "<meta\s+property=`"og:title`"" -and $response.Content -match "<meta\s+property=`"og:image`""
                $hasTwitter = $response.Content -match "<meta\s+name=`"twitter:card`""
                $hasNoGoogleFonts = $response.Content -notmatch "fonts\.googleapis\.com|fonts\.gstatic\.com"
                $hasNoMapEmbeds = $response.Content -notmatch "google\.com/maps/embed|<iframe"
                $faviconHref = if ($path -eq $sampleEpisodePath) { "../../favicon\.svg" } else { "favicon\.svg" }
                $manifestHref = if ($path -eq $sampleEpisodePath) { "../../site\.webmanifest" } else { "site\.webmanifest" }
                $hasBrandAssets = $response.Content -match "<link\s+rel=`"icon`"\s+href=`"$faviconHref`"\s+type=`"image/svg\+xml`"" -and
                    $response.Content -match "<link\s+rel=`"manifest`"\s+href=`"$manifestHref`"" -and
                    $response.Content -match "<meta\s+name=`"theme-color`"\s+content=`"#173247`""

                if ($hasCanonical -and $hasPodcastAlternate -and $hasOpenGraph -and $hasTwitter -and $hasBrandAssets -and $hasNoGoogleFonts -and $hasNoMapEmbeds) {
                    Add-Check "Staging metadata: /$path" "OK" "Canonical, podcast RSS, brand icon, web app manifest, Open Graph, Twitter, and self-hosted dependency metadata present"
                } else {
                    $metadataDetails = @()
                    if (-not $hasCanonical) { $metadataDetails += "canonical" }
                    if (-not $hasPodcastAlternate) { $metadataDetails += "podcast RSS autodiscovery" }
                    if (-not $hasBrandAssets) { $metadataDetails += "brand icon or web app manifest" }
                    if (-not $hasOpenGraph) { $metadataDetails += "Open Graph" }
                    if (-not $hasTwitter) { $metadataDetails += "Twitter" }
                    if (-not $hasNoGoogleFonts) { $metadataDetails += "self-hosted fonts" }
                    if (-not $hasNoMapEmbeds) { $metadataDetails += "self-hosted map/location panel" }
                    Add-Check "Staging metadata: /$path" "FAIL" "Missing on staging: $($metadataDetails -join ', ')"
                }

                if ($path -eq $sampleEpisodePath) {
                    $sampleEpisodeCanonical = "https://www.fillmorechristian.org/$sampleEpisodePath"
                    if ($response.Content -match "<audio\s+controls" -and $response.Content -match "Download Audio" -and $response.Content -match "All Sermons" -and $response.Content -match 'href="../../podcast\.html"' -and $response.Content -match 'class="episode-nav"' -and $response.Content -match "Older Message" -and $response.Content -match '"@type":"PodcastEpisode"' -and $response.Content -match '"associatedMedia":\{"@type":"AudioObject"' -and $response.Content -match 'id="episode-link-url"' -and $response.Content -match [regex]::Escape('data-copy-value="' + $sampleEpisodeCanonical + '"') -and $response.Content -match 'id="episode-copy-status"') {
                        Add-Check "Staging episode page" "OK" "Sample episode page has audio, download, archive navigation, podcast navigation, episode navigation, structured data, and copyable sermon link"
                    } else {
                        Add-Check "Staging episode page" "FAIL" "Sample episode page is missing audio, download, archive navigation, podcast navigation, episode navigation, structured data, or copyable sermon link"
                    }
                }

                if ($path -eq "") {
                    $latestAudioItem = if ($feeds.ContainsKey($feedPaths[0])) {
                        @($feeds[$feedPaths[0]].rss.channel.item | Where-Object { $_.enclosure -and $_.enclosure.url } | Select-Object -First 1)
                    } else {
                        @()
                    }
                    $latestTitle = if ($latestAudioItem) { [string]$latestAudioItem.title } else { "" }
                    if ($latestTitle -and $response.Content -match 'id="latest-sermon"' -and $response.Content -match [regex]::Escape($latestTitle) -and $response.Content -match "Download Audio" -and $response.Content -match '<a\s+href="podcast\.html"\s+class="btn btn-outline">Subscribe to Podcast</a>') {
                        Add-Check "Staging homepage latest sermon" "OK" "Latest audio item and podcast subscription CTA are featured on staging"
                    } elseif ($latestTitle) {
                        Add-Check "Staging homepage latest sermon" "FAIL" "Latest sermon block is missing, stale, or missing the podcast subscription CTA on staging"
                    }
                }
            }

            if ($path -eq "podcast.html") {
                if ($response.Content -match 'id="podcast-feed-url"' -and
                    $response.Content -match 'data-copy-value="https://www\.fillmorechristian\.org/podcast-category/fillmore-christian/feed/podcast"' -and
                    $response.Content -match 'class="podcast-subscription-grid"' -and
                    $response.Content -match 'data-subscribe-option="apple"' -and
                    $response.Content -match 'data-subscribe-option="spotify"' -and
                    $response.Content -match 'data-subscribe-option="rss"' -and
                    $response.Content -match '"@type": "PodcastSeries"' -and
                    $response.Content -notmatch "thechurchco|ssl\.thechurchco\.com") {
                    Add-Check "Staging podcast page" "OK" "Owned podcast landing page has app choices, feed copy controls, and structured data"
                } else {
                    Add-Check "Staging podcast page" "FAIL" "Podcast page is missing app choices, feed copy controls, structured data, or contains old platform references"
                }
            }

            if ($path -eq "sermons.html") {
                $remoteCards = ([regex]::Matches($response.Content, 'class="sermon-item')).Count
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and $remoteCards -ne $feedItemCounts[$feedPaths[0]]) {
                    Add-Check "Staging sermon card count" "FAIL" "$remoteCards remote cards, expected $($feedItemCounts[$feedPaths[0]])"
                } else {
                    Add-Check "Staging sermon card count" "OK" "$remoteCards sermon cards"
                }

                $expectedRemoteAudioCards = if ($feedEnclosureCounts.ContainsKey($feedPaths[0])) { $feedEnclosureCounts[$feedPaths[0]] } else { 0 }
                $remoteYears = [regex]::Matches($response.Content, 'data-year="(\d{4})"') |
                    ForEach-Object { $_.Groups[1].Value } |
                    Sort-Object -Unique
                $expectedRemoteYearRange = if ($remoteYears.Count -gt 1) {
                    "$($remoteYears[0])-$($remoteYears[$remoteYears.Count - 1])"
                } elseif ($remoteYears.Count -eq 1) {
                    $remoteYears[0]
                } else {
                    ""
                }
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and
                    $response.Content -match 'id="sermon-archive-summary"' -and
                    $response.Content -match "<span class=`"archive-summary-value`">$($feedItemCounts[$feedPaths[0]])</span>\s*<span class=`"archive-summary-label`">messages archived</span>" -and
                    $response.Content -match "<span class=`"archive-summary-value`">$expectedRemoteAudioCards</span>\s*<span class=`"archive-summary-label`">with audio</span>" -and
                    $expectedRemoteYearRange -and
                    $response.Content -match "<span class=`"archive-summary-value`">$([regex]::Escape($expectedRemoteYearRange))</span>\s*<span class=`"archive-summary-label`">teaching years</span>") {
                    Add-Check "Staging sermon archive summary" "OK" "$remoteCards messages, $expectedRemoteAudioCards with audio, $expectedRemoteYearRange teaching years"
                } else {
                    Add-Check "Staging sermon archive summary" "FAIL" "Archive summary is missing or does not match feed-derived counts and years"
                }

                $remoteCardsWithYear = ([regex]::Matches($response.Content, 'class="sermon-item[^"]*"\s+data-year="\d{4}"')).Count
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and $remoteCardsWithYear -eq $feedItemCounts[$feedPaths[0]] -and $response.Content -match 'id="sermon-year"') {
                    Add-Check "Staging sermon year filter" "OK" "$remoteCardsWithYear sermon cards include years and filter control is present"
                } else {
                    Add-Check "Staging sermon year filter" "FAIL" "$remoteCardsWithYear sermon card year value(s); filter control present: $($response.Content -match 'id=`"sermon-year`"')"
                }

                $remoteCardsWithSortData = ([regex]::Matches($response.Content, 'class="sermon-item[^"]*"\s+data-year="\d{4}"\s+data-has-audio="(?:true|false)"\s+data-sort-date="\d+"\s+data-title="[^"]+"')).Count
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and $remoteCardsWithSortData -eq $feedItemCounts[$feedPaths[0]] -and $response.Content -match 'id="sermon-sort"') {
                    Add-Check "Staging sermon sort control" "OK" "$remoteCardsWithSortData sermon cards include sort metadata and sort control is present"
                } else {
                    Add-Check "Staging sermon sort control" "FAIL" "$remoteCardsWithSortData sermon card sort value(s); sort control present: $($response.Content -match 'id=`"sermon-sort`"')"
                }

                $remoteCardsWithAudioFlag = ([regex]::Matches($response.Content, 'class="sermon-item[^"]*"\s+data-year="\d{4}"\s+data-has-audio="(?:true|false)"')).Count
                $remoteAudioCards = ([regex]::Matches($response.Content, 'data-has-audio="true"')).Count
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and $feedEnclosureCounts.ContainsKey($feedPaths[0]) -and $remoteCardsWithAudioFlag -eq $feedItemCounts[$feedPaths[0]] -and $remoteAudioCards -eq $expectedRemoteAudioCards -and $response.Content -match 'id="sermon-audio-only"') {
                    Add-Check "Staging sermon audio filter" "OK" "$remoteAudioCards cards have audio and audio-only control is present"
                } else {
                    Add-Check "Staging sermon audio filter" "FAIL" "$remoteCardsWithAudioFlag audio flag(s), $remoteAudioCards audio card(s), audio control present: $($response.Content -match 'id=`"sermon-audio-only`"')"
                }

                if ($response.Content -match 'id="sermon-search"' -and $response.Content -match 'id="sermon-clear"' -and $response.Content -match 'id="sermon-share-link"') {
                    Add-Check "Staging sermon search controls" "OK" "Search, clear, and filtered-link copy controls are present"
                } else {
                    Add-Check "Staging sermon search controls" "FAIL" "Search, clear, or filtered-link copy controls are missing"
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

            if ($path -eq "events.ics") {
                $remoteCalendarContentType = [string]$response.Headers["Content-Type"]
                if ($response.Content -match "(?m)^BEGIN:VCALENDAR" -and $response.Content -match "SUMMARY:Sunday Worship" -and $response.Content -match "RRULE:FREQ=WEEKLY;BYDAY=SU" -and $remoteCalendarContentType -match "text/calendar") {
                    Add-Check "Staging event calendar" "OK" "events.ics is published with text/calendar content type"
                } else {
                    Add-Check "Staging event calendar" "FAIL" "events.ics content or content type was unexpected"
                }
            }

            if ($path -eq "contact.vcf") {
                if ($response.Content -match "(?m)^BEGIN:VCARD" -and $response.Content -match "FN:Fillmore Christian Church" -and $response.Content -match "church@fillmorechristian\.org" -and $response.Content -match "310 N\. Florence Street") {
                    Add-Check "Staging contact card" "OK" "contact.vcf is published with church email and address"
                } else {
                    Add-Check "Staging contact card" "FAIL" "contact.vcf content was unexpected"
                }
            }

            if ($path -eq "favicon.svg") {
                if ($response.Content -match "<svg\b" -and $response.Content -match "#173247" -and $response.Content -match "Fillmore Christian Church") {
                    Add-Check "Staging favicon" "OK" "favicon.svg is published"
                } else {
                    Add-Check "Staging favicon" "FAIL" "favicon.svg content was unexpected"
                }
            }

            if ($path -eq "site.webmanifest") {
                $manifestContentType = [string]$response.Headers["Content-Type"]
                try {
                    $manifestText = if ($response.Content -is [byte[]]) {
                        [System.Text.Encoding]::UTF8.GetString($response.Content)
                    } else {
                        [string]$response.Content
                    }
                    $remoteManifest = $manifestText | ConvertFrom-Json
                    $remoteIconSources = @($remoteManifest.icons | ForEach-Object { $_.src })
                    if ($manifestContentType -match "application/manifest\+json" -and $remoteManifest.name -eq "Fillmore Christian Church" -and $remoteManifest.theme_color -eq "#173247" -and "favicon.svg" -in $remoteIconSources) {
                        Add-Check "Staging web app manifest" "OK" "site.webmanifest is published with the expected content type"
                    } else {
                        Add-Check "Staging web app manifest" "FAIL" "site.webmanifest fields or content type were unexpected"
                    }
                } catch {
                    Add-Check "Staging web app manifest" "FAIL" "site.webmanifest was not valid JSON: $($_.Exception.Message)"
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

exit 0
