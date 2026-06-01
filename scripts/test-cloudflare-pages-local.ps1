param(
    [string]$BuildOutputDir = "dist",
    [int]$Port = 8788,
    [int]$TimeoutSeconds = 45,
    [string]$CompatibilityDate = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$buildOutputPath = Join-Path $root $BuildOutputDir
$wranglerConfigPath = Join-Path $root "wrangler.toml"
$wrangler = Get-Command wrangler -ErrorAction Stop
$logDir = Join-Path $env:TEMP "fillmore-cloudflare-pages-test"
$stdoutPath = Join-Path $logDir "wrangler-pages-dev.out.log"
$stderrPath = Join-Path $logDir "wrangler-pages-dev.err.log"
$persistPath = Join-Path $logDir "state"
$workspaceWranglerPath = Join-Path $root ".wrangler"
$hadWorkspaceWrangler = Test-Path -LiteralPath $workspaceWranglerPath

function Stop-ProcessTree {
    param([int]$ProcessId)

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-CloudflareDevByPort {
    param([int]$Port)

    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
        if ($processInfo -and $processInfo.CommandLine -match "wrangler|workerd") {
            Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-NoRedirect {
    param(
        [string]$Url,
        [string]$Method = "GET"
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Headers = $response.Headers
            ContentHeaders = $response.Content.Headers
            Location = $response.Headers.Location
            Content = $content
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Assert-Status {
    param(
        [object]$Response,
        [int[]]$Expected,
        [string]$Name
    )

    if ($Response.StatusCode -notin $Expected) {
        throw "$Name returned HTTP $($Response.StatusCode); expected $($Expected -join " or ")"
    }
}

function Get-HeaderValue {
    param(
        [object]$Headers,
        [string]$Name
    )

    try {
        return (($Headers.GetValues($Name) | Select-Object -First 1) -as [string])
    } catch {
        return ""
    }
}

if (-not (Test-Path -LiteralPath $buildOutputPath)) {
    throw "Build output not found: $buildOutputPath. Run npm run build first."
}

$existingListener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($existingListener.Count -gt 0) {
    throw "Port $Port is already in use. Re-run with a different -Port value."
}

if (-not $CompatibilityDate) {
    if (-not (Test-Path -LiteralPath $wranglerConfigPath)) {
        throw "wrangler.toml not found and no CompatibilityDate was provided."
    }

    $wranglerConfig = Get-Content -Raw -LiteralPath $wranglerConfigPath
    if ($wranglerConfig -notmatch '(?m)^compatibility_date\s*=\s*"([^"]+)"') {
        throw "Could not read compatibility_date from wrangler.toml."
    }

    $CompatibilityDate = $Matches[1]
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $persistPath -Recurse -Force -ErrorAction SilentlyContinue

$arguments = @(
    "pages",
    "dev",
    $buildOutputPath,
    "--ip",
    "127.0.0.1",
    "--port",
    $Port,
    "--compatibility-date",
    $CompatibilityDate,
    "--persist-to",
    $persistPath,
    "--show-interactive-dev-session",
    "false"
)

$launcher = $wrangler.Source
$launcherArguments = $arguments
if ([System.IO.Path]::GetExtension($launcher) -eq ".ps1") {
    $launcherArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $launcher
    ) + $arguments
    $launcher = (Get-Command powershell.exe -ErrorAction Stop).Source
}

$process = Start-Process `
    -FilePath $launcher `
    -ArgumentList $launcherArguments `
    -WorkingDirectory $root `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

try {
    $baseUrl = "http://127.0.0.1:$Port"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $ready = $false
    $lastReadyError = ""
    $lastReadyStatus = ""

    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { "" }
            throw "wrangler pages dev exited early. stdout: $stdout stderr: $stderr"
        }

        try {
            $response = Invoke-NoRedirect -Url "$baseUrl/"
            $lastReadyStatus = "HTTP $($response.StatusCode)"
            if ($response.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {
            $lastReadyError = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $ready) {
        throw "wrangler pages dev did not become ready within $TimeoutSeconds seconds. Last status: $lastReadyStatus. Last error: $lastReadyError"
    }

    $checks = New-Object System.Collections.Generic.List[object]

    $homeResponse = Invoke-NoRedirect -Url "$baseUrl/"
    Assert-Status -Response $homeResponse -Expected @(200) -Name "Home page"
    if ($homeResponse.Content -notmatch "Fillmore Christian Church") {
        throw "Home page did not include the church name"
    }
    if ($homeResponse.Content -match "fonts\.googleapis\.com|fonts\.gstatic\.com") {
        throw "Home page still references Google-hosted fonts"
    }
    if ($homeResponse.Content -notmatch 'data-mailto="church@fillmorechristian\.org"' -or
        $homeResponse.Content -notmatch 'data-status-target="home-contact-form-status"' -or
        $homeResponse.Content -notmatch 'id="home-contact-form-status"\s+class="form-status"\s+aria-live="polite"' -or
        $homeResponse.Content -notmatch 'data-copy-value="church@fillmorechristian\.org"' -or
        $homeResponse.Content -notmatch 'id="home-email-copy-status"') {
        throw "Home page is missing the static contact form status or copyable email fallback"
    }
    $checks.Add([pscustomobject]@{ Check = "Home page"; Status = "OK"; Details = "HTTP 200" })

    if ($homeResponse.Content -match "google\.com/maps/embed|<iframe" -or $homeResponse.Content -notmatch "location-panel") {
        throw "Home page does not use the self-hosted location panel cleanly"
    }
    $checks.Add([pscustomobject]@{ Check = "Home location panel"; Status = "OK"; Details = "Self-hosted location panel without embedded maps" })

    $expectedSecurityHeaders = @{
        "X-Content-Type-Options" = "nosniff"
        "X-Frame-Options" = "SAMEORIGIN"
        "Referrer-Policy" = "strict-origin-when-cross-origin"
        "Permissions-Policy" = "camera=(), microphone=(), geolocation=()"
    }
    $missingSecurityHeaders = @(
        foreach ($name in $expectedSecurityHeaders.Keys) {
            $actual = Get-HeaderValue -Headers $homeResponse.Headers -Name $name
            if ($actual -ne $expectedSecurityHeaders[$name]) {
                "$name=$actual"
            }
        }
    )
    if ($missingSecurityHeaders.Count -gt 0) {
        throw "Home page is missing expected security headers: $($missingSecurityHeaders -join '; ')"
    }
    $checks.Add([pscustomobject]@{ Check = "Security headers"; Status = "OK"; Details = "nosniff, frame, referrer, and permissions policies" })

    if ($homeResponse.Content -notmatch 'id="first-visit-guide"' -or
        $homeResponse.Content -notmatch "First time at Fillmore\?" -or
        $homeResponse.Content -notmatch "Sunday School starts at 9:00 AM" -or
        $homeResponse.Content -notmatch "Children are welcome in worship" -or
        $homeResponse.Content -notmatch "Get Directions" -or
        $homeResponse.Content -notmatch "Ask a Question") {
        throw "Home page is missing the first-visit guide or its visitor actions"
    }
    $checks.Add([pscustomobject]@{ Check = "Homepage visitor guide"; Status = "OK"; Details = "Published output includes first-visit guidance and visitor actions" })

    $legacyQuery = Invoke-NoRedirect -Url "$baseUrl/?post_type=podcasts&p=603"
    Assert-Status -Response $legacyQuery -Expected @(301) -Name "Legacy podcast query redirect"
    if (-not $legacyQuery.Location -or $legacyQuery.Location.ToString() -ne "$baseUrl/episode/be-ready-luke-12/") {
        throw "Legacy podcast query redirect pointed to '$($legacyQuery.Location)'"
    }
    $checks.Add([pscustomobject]@{ Check = "Legacy podcast query redirect"; Status = "OK"; Details = "p=603 -> /episode/be-ready-luke-12/" })

    $prettySermons = Invoke-NoRedirect -Url "$baseUrl/sermons/"
    Assert-Status -Response $prettySermons -Expected @(301, 302, 308) -Name "Pretty sermons redirect"
    if (-not $prettySermons.Location -or $prettySermons.Location.ToString() -notmatch "/sermons\.html$") {
        throw "Pretty sermons redirect pointed to '$($prettySermons.Location)'"
    }
    $checks.Add([pscustomobject]@{ Check = "Pretty sermons redirect"; Status = "OK"; Details = "/sermons/ -> /sermons.html" })

    $podcastFeedSlash = Invoke-NoRedirect -Url "$baseUrl/podcast-category/fillmore-christian/feed/podcast/"
    Assert-Status -Response $podcastFeedSlash -Expected @(301, 302, 308) -Name "Trailing podcast feed redirect"
    $podcastFeedSlashLocation = if ($podcastFeedSlash.Location) { $podcastFeedSlash.Location.ToString() } else { "" }
    if ($podcastFeedSlashLocation -notin @("$baseUrl/podcast-category/fillmore-christian/feed/podcast", "/podcast-category/fillmore-christian/feed/podcast")) {
        throw "Trailing podcast feed redirect pointed to '$($podcastFeedSlash.Location)'"
    }
    $checks.Add([pscustomobject]@{ Check = "Trailing podcast feed redirect"; Status = "OK"; Details = "/podcast-category/fillmore-christian/feed/podcast/ -> canonical feed path" })

    $sermonsPageContent = Get-Content -Raw -LiteralPath (Join-Path $buildOutputPath "sermons.html")
    if ($sermonsPageContent -notmatch 'id="podcast-feed-url"' -or $sermonsPageContent -notmatch 'data-copy-value="https://www\.fillmorechristian\.org/podcast-category/fillmore-christian/feed/podcast"' -or $sermonsPageContent -match "being moved out of TheChurchCo|during the move|ChurchCo transition|preserved podcast RSS feed path") {
        throw "Sermons page is missing the copyable RSS feed URL or still contains migration-era copy"
    }
    $checks.Add([pscustomobject]@{ Check = "Sermons subscribe controls"; Status = "OK"; Details = "Published output includes copyable canonical RSS feed URL" })

    if ($sermonsPageContent -notmatch 'id="sermon-audio-only"' -or $sermonsPageContent -notmatch 'data-has-audio="true"' -or $sermonsPageContent -notmatch 'data-has-audio="false"') {
        throw "Sermons page is missing the audio-only filter or audio availability metadata"
    }
    $checks.Add([pscustomobject]@{ Check = "Sermons audio filter"; Status = "OK"; Details = "Published output includes audio-only filter and audio availability metadata" })

    $mainScriptContent = Get-Content -Raw -LiteralPath (Join-Path $buildOutputPath "js\main.js")
    if ($mainScriptContent -notmatch "document\.addEventListener\('play'" -or $mainScriptContent -notmatch "querySelectorAll\('audio'\)" -or $mainScriptContent -notmatch "\.pause\(\)") {
        throw "Main script is missing the one-at-a-time audio playback guard"
    }
    $checks.Add([pscustomobject]@{ Check = "Audio playback guard"; Status = "OK"; Details = "Starting one sermon pauses other audio players" })

    if ($mainScriptContent -notmatch "aria-expanded" -or $mainScriptContent -notmatch "aria-controls" -or $mainScriptContent -notmatch "setNavigationOpen" -or $mainScriptContent -notmatch "closeDropdowns" -or $mainScriptContent -notmatch "Escape") {
        throw "Main script is missing accessible mobile navigation state handling"
    }
    $checks.Add([pscustomobject]@{ Check = "Accessible navigation"; Status = "OK"; Details = "Mobile menu exposes expanded state and keyboard close behavior" })

    $feed = Invoke-NoRedirect -Url "$baseUrl/podcast-category/fillmore-christian/feed/podcast"
    Assert-Status -Response $feed -Expected @(200) -Name "Podcast feed"
    $contentType = [string]$feed.ContentHeaders.ContentType
    if ($contentType -notmatch "application/rss\+xml") {
        throw "Podcast feed returned unexpected content type '$contentType'"
    }
    if ($feed.Content -notmatch "<rss\b" -or $feed.Content -notmatch "Fillmore Christian") {
        throw "Podcast feed did not look like the Fillmore Christian RSS feed"
    }
    $checks.Add([pscustomobject]@{ Check = "Podcast feed"; Status = "OK"; Details = "RSS content type and XML body" })

    $calendar = Invoke-NoRedirect -Url "$baseUrl/events.ics"
    Assert-Status -Response $calendar -Expected @(200) -Name "Event calendar"
    $calendarContentType = [string]$calendar.ContentHeaders.ContentType
    if ($calendarContentType -notmatch "text/calendar") {
        throw "Event calendar returned unexpected content type '$calendarContentType'"
    }
    if ($calendar.Content -notmatch "BEGIN:VCALENDAR" -or $calendar.Content -notmatch "SUMMARY:Sunday Worship" -or $calendar.Content -notmatch "RRULE:FREQ=WEEKLY;BYDAY=SU") {
        throw "Event calendar did not include the recurring Sunday schedule"
    }
    $checks.Add([pscustomobject]@{ Check = "Event calendar"; Status = "OK"; Details = "text/calendar recurring Sunday schedule" })

    $eventsPageContent = Get-Content -Raw -LiteralPath (Join-Path $buildOutputPath "events.html")
    if ($eventsPageContent -notmatch 'id="calendar-feed-url"' -or
        $eventsPageContent -notmatch 'data-copy-value="https://www\.fillmorechristian\.org/events\.ics"' -or
        $eventsPageContent -notmatch 'id="calendar-copy-status"\s+class="copy-status"\s+aria-live="polite"') {
        throw "Events page is missing the copyable calendar feed URL"
    }
    $checks.Add([pscustomobject]@{ Check = "Calendar subscribe controls"; Status = "OK"; Details = "Published output includes copyable canonical iCal feed URL" })

    $homePageContent = Get-Content -Raw -LiteralPath (Join-Path $buildOutputPath "index.html")
    if ($homePageContent -notmatch '<img\s+src="favicon\.svg"\s+alt=""\s+class="nav-brand-mark"\s+aria-hidden="true">' -or
        $homePageContent -notmatch 'nav-brand-name">Fillmore Christian Church') {
        throw "Built home page is missing the branded navigation mark"
    }
    $checks.Add([pscustomobject]@{ Check = "Navigation brand mark"; Status = "OK"; Details = "Published output includes the Fillmore-branded navigation mark" })

    $eventsScript = Invoke-NoRedirect -Url "$baseUrl/js/events.js"
    Assert-Status -Response $eventsScript -Expected @(200) -Name "Events script"
    if ($eventsScript.Content -notmatch "events\.ics" -or $eventsScript.Content -match "googleapis|GOOGLE_CALENDAR_ID|GOOGLE_API_KEY") {
        throw "Events script does not use the self-hosted iCal feed cleanly"
    }
    $checks.Add([pscustomobject]@{ Check = "Events script"; Status = "OK"; Details = "Loads self-hosted events.ics without Google Calendar API" })

    $aboutPageContent = Get-Content -Raw -LiteralPath (Join-Path $buildOutputPath "about.html")
    if ($aboutPageContent -match "google\.com/maps/embed|<iframe" -or $aboutPageContent -notmatch "location-panel") {
        throw "Built about page does not use the self-hosted location panel cleanly"
    }
    $checks.Add([pscustomobject]@{ Check = "About location panel"; Status = "OK"; Details = "No embedded map iframe" })

    $font = Invoke-NoRedirect -Url "$baseUrl/fonts/source-sans-3-latin-400-700.woff2"
    Assert-Status -Response $font -Expected @(200) -Name "Self-hosted font"
    $fontContentType = [string]$font.ContentHeaders.ContentType
    if ($fontContentType -notmatch "font/woff2") {
        throw "Self-hosted font returned unexpected content type '$fontContentType'"
    }
    $fontCacheControl = Get-HeaderValue -Headers $font.Headers -Name "Cache-Control"
    if ($fontCacheControl -notmatch "max-age=31536000" -or $fontCacheControl -notmatch "immutable") {
        throw "Self-hosted font returned unexpected cache control '$fontCacheControl'"
    }
    $checks.Add([pscustomobject]@{ Check = "Self-hosted font"; Status = "OK"; Details = "WOFF2 content type and immutable cache" })

    $contactCard = Invoke-NoRedirect -Url "$baseUrl/contact.vcf"
    Assert-Status -Response $contactCard -Expected @(200) -Name "Contact card"
    $contactCardContentType = [string]$contactCard.ContentHeaders.ContentType
    if ($contactCardContentType -notmatch "text/vcard") {
        throw "Contact card returned unexpected content type '$contactCardContentType'"
    }
    if ($contactCard.Content -notmatch "BEGIN:VCARD" -or $contactCard.Content -notmatch "FN:Fillmore Christian Church" -or $contactCard.Content -notmatch "church@fillmorechristian\.org") {
        throw "Contact card did not include the church contact details"
    }
    $checks.Add([pscustomobject]@{ Check = "Contact card"; Status = "OK"; Details = "text/vcard church email and address" })

    $contactPageContent = Get-Content -Raw -LiteralPath (Join-Path $buildOutputPath "contact.html")
    if ($contactPageContent -match "google\.com/maps/embed|<iframe" -or $contactPageContent -notmatch "location-panel") {
        throw "Built contact page does not use the self-hosted location panel cleanly"
    }
    $checks.Add([pscustomobject]@{ Check = "Contact location panel"; Status = "OK"; Details = "No embedded map iframe" })

    if ($contactPageContent -notmatch 'data-mailto="church@fillmorechristian\.org"' -or
        $contactPageContent -notmatch 'data-status-target="contact-form-status"' -or
        $contactPageContent -notmatch 'id="contact-form-status"\s+class="form-status"\s+aria-live="polite"' -or
        $contactPageContent -notmatch 'data-copy-value="church@fillmorechristian\.org"' -or
        $contactPageContent -notmatch 'id="contact-email-copy-status"') {
        throw "Built contact page is missing the static mailto form status or copyable email fallback"
    }
    $mainScript = Invoke-NoRedirect -Url "$baseUrl/js/main.js"
    Assert-Status -Response $mainScript -Expected @(200) -Name "Main script"
    if ($mainScript.Content -notmatch "data-status-target" -or $mainScript.Content -notmatch "email app should now have a draft") {
        throw "Main script is missing contact form status messaging"
    }
    $checks.Add([pscustomobject]@{ Check = "Contact fallback"; Status = "OK"; Details = "Static mailto form, visible status message, and copyable email fallback" })

    $favicon = Invoke-NoRedirect -Url "$baseUrl/favicon.svg"
    Assert-Status -Response $favicon -Expected @(200) -Name "Favicon"
    if ($favicon.Content -notmatch "<svg\b" -or $favicon.Content -notmatch "#173247" -or $favicon.Content -notmatch "Fillmore Christian Church") {
        throw "Favicon did not look like the Fillmore-branded SVG"
    }
    $checks.Add([pscustomobject]@{ Check = "Favicon"; Status = "OK"; Details = "Fillmore-branded SVG" })

    $webManifest = Invoke-NoRedirect -Url "$baseUrl/site.webmanifest"
    Assert-Status -Response $webManifest -Expected @(200) -Name "Web app manifest"
    $manifestContentType = [string]$webManifest.ContentHeaders.ContentType
    if ($manifestContentType -notmatch "application/manifest\+json") {
        throw "Web app manifest returned unexpected content type '$manifestContentType'"
    }
    try {
        $manifestJson = $webManifest.Content | ConvertFrom-Json
        $manifestIconSources = @($manifestJson.icons | ForEach-Object { $_.src })
        if ($manifestJson.name -ne "Fillmore Christian Church" -or $manifestJson.theme_color -ne "#173247" -or "favicon.svg" -notin $manifestIconSources) {
            throw "Manifest fields did not match the Fillmore site branding"
        }
    } catch {
        throw "Web app manifest did not parse as expected: $($_.Exception.Message)"
    }
    $checks.Add([pscustomobject]@{ Check = "Web app manifest"; Status = "OK"; Details = "application/manifest+json and expected icon" })

    $episode = Invoke-NoRedirect -Url "$baseUrl/episode/be-ready-luke-12/"
    Assert-Status -Response $episode -Expected @(200) -Name "Static episode page"
    if ($episode.Content -match "fonts\.googleapis\.com|fonts\.gstatic\.com") {
        throw "Static episode page still references Google-hosted fonts"
    }
    if ($episode.Content -notmatch "<audio\s+controls" -or $episode.Content -notmatch "Download Audio" -or $episode.Content -notmatch "All Sermons" -or $episode.Content -notmatch 'class="episode-nav"' -or $episode.Content -notmatch "Newer Message" -or $episode.Content -notmatch "Older Message" -or $episode.Content -notmatch 'href="../../favicon\.svg"' -or $episode.Content -notmatch 'href="../../site\.webmanifest"' -or $episode.Content -notmatch 'id="episode-link-url"' -or $episode.Content -notmatch 'data-copy-value="https://www\.fillmorechristian\.org/episode/be-ready-luke-12/"' -or $episode.Content -notmatch 'id="episode-copy-status"') {
        throw "Static episode page is missing audio, download, archive navigation, episode navigation, brand asset links, or copyable canonical sermon link"
    }
    $checks.Add([pscustomobject]@{ Check = "Static episode page"; Status = "OK"; Details = "Audio player, download, archive navigation, episode navigation, brand asset links, and copyable sermon link" })

    $checks | Format-Table -AutoSize
} finally {
    Stop-ProcessTree -ProcessId $process.Id
    Stop-CloudflareDevByPort -Port $Port
    Remove-Item -LiteralPath $persistPath -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $hadWorkspaceWrangler) {
        Remove-Item -LiteralPath $workspaceWranglerPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
