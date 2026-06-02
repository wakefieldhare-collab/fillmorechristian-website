param(
    [string]$Domain = "fillmorechristian.org",
    [string]$ProductionBaseUrl = "https://www.fillmorechristian.org",
    [string]$ApexBaseUrl = "https://fillmorechristian.org",
    [string]$PodcastFeedPath = "podcast-category/fillmore-christian/feed/podcast",
    [string]$R2ManifestPath = "exports\thechurchco-podcast\r2-audio-manifest.csv",
    [string]$ExpectedAudioHost = "www.fillmorechristian.org",
    [string[]]$ExpectedCloudflareNameservers = @(),
    [switch]$VerifyAllPodcastMedia,
    [int]$PodcastMediaSampleCount = 5,
    [int]$TimeoutSec = 20
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

function Resolve-Answers {
    param(
        [string]$Name,
        [string]$Type
    )

    try {
        $expectedName = $Name.TrimEnd(".").ToLowerInvariant()
        return @(Resolve-DnsName -Name $Name -Type $Type -ErrorAction Stop | Where-Object {
            if ($_.Section -eq "Answer") { return $true }
            $recordName = if ($_.Name) { $_.Name.TrimEnd(".").ToLowerInvariant() } else { "" }
            if ($recordName -and $recordName -ne $expectedName) { return $false }

            switch ($Type) {
                "A" { return [bool]$_.IPAddress }
                "AAAA" { return [bool]$_.IPAddress }
                "CNAME" { return [bool]$_.NameHost }
                "MX" { return [bool]$_.NameExchange }
                "NS" { return [bool]$_.NameHost }
                "TXT" { return [bool]$_.Strings }
            }
        })
    } catch {
        return @()
    }
}

function Get-RecordValue {
    param($Answer, [string]$Type)

    switch ($Type) {
        "A" { return $Answer.IPAddress }
        "AAAA" { return $Answer.IPAddress }
        "CNAME" { return $Answer.NameHost.TrimEnd(".") }
        "MX" { return $Answer.NameExchange.TrimEnd(".") }
        "NS" { return $Answer.NameHost.TrimEnd(".") }
        "TXT" { return ($Answer.Strings -join "") }
    }
}

function Invoke-Http {
    param([string]$Url)

    $currentUrl = $Url
    try {
        for ($redirectCount = 0; $redirectCount -le 5; $redirectCount++) {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $currentUrl -MaximumRedirection 0 -TimeoutSec $TimeoutSec
            if ($response.StatusCode -notin @(301, 302, 303, 307, 308)) {
                return $response
            }

            $location = Get-HeaderValue -Headers $response.Headers -Name "Location"
            if (-not $location) {
                Add-Check "HTTP: $currentUrl" "FAIL" "HTTP $($response.StatusCode) redirect did not include a Location header"
                return $null
            }

            $currentUrl = [Uri]::new([Uri]$currentUrl, $location).AbsoluteUri
        }

        Add-Check "HTTP: $Url" "FAIL" "Exceeded redirect limit"
        return $null
    } catch {
        Add-Check "HTTP: $currentUrl" "FAIL" $_.Exception.Message
        return $null
    }
}

function Get-HeaderValue {
    param(
        $Headers,
        [string]$Name
    )

    foreach ($key in $Headers.Keys) {
        if ($key -ieq $Name) {
            $value = $Headers[$key]
            if ($value -is [array]) {
                return [string]$value[0]
            }
            return [string]$value
        }
    }
    return ""
}

try {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    $activeStatus = (& gh auth status 2>&1) -join "`n"
    if ($originUrl -match "wakefieldhare-collab/fillmorechristian-website(\.git)?$" -and
        $originUrl -notmatch "wake-byte" -and
        $activeStatus -match "account\s+wakefieldhare-collab[\s\S]*?Active account:\s+true" -and
        $activeStatus -notmatch "account\s+wake-byte[\s\S]*?Active account:\s+true") {
        Add-Check "Personal GitHub guard" "OK" "origin and active gh account use wakefieldhare-collab"
    } else {
        Add-Check "Personal GitHub guard" "FAIL" "origin or active gh account is not the personal repo/account"
    }
} catch {
    Add-Check "Personal GitHub guard" "FAIL" $_.Exception.Message
}

$nsValues = @(Resolve-Answers $Domain "NS" | ForEach-Object { Get-RecordValue $_ "NS" } | Sort-Object -Unique)
if ($ExpectedCloudflareNameservers.Count -gt 0) {
    $normalizedActualNs = @($nsValues | ForEach-Object { $_.TrimEnd(".").ToLowerInvariant() })
    $missingNs = @($ExpectedCloudflareNameservers | ForEach-Object { $_.TrimEnd(".").ToLowerInvariant() } | Where-Object { $_ -notin $normalizedActualNs })
    if ($missingNs.Count -eq 0) {
        Add-Check "Cloudflare nameservers" "OK" "Expected Cloudflare nameservers are active"
    } else {
        Add-Check "Cloudflare nameservers" "FAIL" "Missing expected nameservers: $($missingNs -join ', '); current: $($nsValues -join ', ')"
    }
} else {
    $cloudflareNs = @($nsValues | Where-Object { $_ -like "*.ns.cloudflare.com" })
    if ($cloudflareNs.Count -ge 2) {
        Add-Check "Cloudflare nameservers" "OK" "Cloudflare nameservers are active: $($cloudflareNs -join ', ')"
    } else {
        Add-Check "Cloudflare nameservers" "FAIL" "Cloudflare nameservers are not active. Current: $($nsValues -join ', ')"
    }
}

$apexA = @(Resolve-Answers $Domain "A" | ForEach-Object { Get-RecordValue $_ "A" } | Sort-Object -Unique)
$wwwCname = @(Resolve-Answers "www.$Domain" "CNAME" | ForEach-Object { Get-RecordValue $_ "CNAME" } | Sort-Object -Unique)
if ("77.83.141.16" -notin $apexA -and "ssl.thechurchco.com" -notin $wwwCname) {
    Add-Check "Old website DNS removed" "OK" "Apex and www no longer point at TheChurchCo-era records"
} else {
    Add-Check "Old website DNS removed" "FAIL" "Current apex A: $($apexA -join ', '); current www CNAME: $($wwwCname -join ', ')"
}

$dnsCacheStatusScript = Join-Path $PSScriptRoot "show-dns-cache-status.ps1"
if (Test-Path -LiteralPath $dnsCacheStatusScript) {
    try {
        $dnsCacheOutput = @(& $dnsCacheStatusScript -Domain $Domain -ExpectedCloudflareNameservers $ExpectedCloudflareNameservers -WriteReport -FailOnStale *>&1)
        $clearLine = @($dnsCacheOutput | Where-Object { [string]$_ -match "No stale old TheChurchCo/Squarespace DNS answers" } | Select-Object -First 1)
        $details = if ($clearLine.Count -gt 0) { [string]$clearLine[0] } else { "No stale old DNS answers observed across configured public resolvers" }
        Add-Check "Recursive DNS cache cleared" "OK" $details
    } catch {
        Add-Check "Recursive DNS cache cleared" "FAIL" "$($_.Exception.Message). Do not cancel TheChurchCo yet."
    }
} else {
    Add-Check "Recursive DNS cache cleared" "FAIL" "Missing DNS cache verifier script: $dnsCacheStatusScript"
}

$mxValues = @(Resolve-Answers $Domain "MX" | ForEach-Object { "{0}:{1}" -f $_.Preference, (Get-RecordValue $_ "MX") } | Sort-Object)
$requiredMx = @("10:mxa.mailgun.org", "10:mxb.mailgun.org")
$missingMx = @($requiredMx | Where-Object { $_ -notin $mxValues })
if ($missingMx.Count -eq 0) {
    Add-Check "Mail DNS preserved" "OK" "Mailgun MX records are present"
} else {
    Add-Check "Mail DNS preserved" "FAIL" "Missing MX: $($missingMx -join ', '); current: $($mxValues -join ', ')"
}

$txtValues = @(Resolve-Answers $Domain "TXT" | ForEach-Object { Get-RecordValue $_ "TXT" })
if ("v=spf1 include:mailgun.org ~all" -in $txtValues) {
    Add-Check "Mail SPF preserved" "OK" "Mailgun SPF TXT record is present"
} else {
    Add-Check "Mail SPF preserved" "FAIL" "SPF record is missing. Current TXT: $($txtValues -join '; ')"
}

$dmarcValues = @(Resolve-Answers "_dmarc.$Domain" "TXT" | ForEach-Object { Get-RecordValue $_ "TXT" })
$publishedDmarc = @($dmarcValues | Where-Object { $_ -match "^v=DMARC1;" })
if ($publishedDmarc.Count -gt 0) {
    Add-Check "Mail DMARC published" "OK" "DMARC TXT record is present at _dmarc.$Domain"
} else {
    Add-Check "Mail DMARC published" "FAIL" "DMARC TXT record is missing. Current _dmarc TXT: $($dmarcValues -join '; ')"
}

$homeResponse = Invoke-Http -Url (Join-Url $ProductionBaseUrl "/")
if ($homeResponse) {
    if ($homeResponse.StatusCode -eq 200 -and
        $homeResponse.Content -match "Fillmore Christian Church" -and
        $homeResponse.Content -match "site\.webmanifest" -and
        $homeResponse.Content -match "favicon\.svg" -and
        $homeResponse.Content -match 'data-mailto="church@fillmorechristian\.org"' -and
        $homeResponse.Content -match 'data-mailto-fallback' -and
        $homeResponse.Content -match 'data-copy-source="home-message-draft"' -and
        $homeResponse.Content -match 'data-copy-value="church@fillmorechristian\.org"' -and
        $homeResponse.Content -notmatch "thechurchco|ssl\.thechurchco\.com") {
        Add-Check "Production homepage" "OK" "$ProductionBaseUrl serves the static site shell with contact fallbacks"
    } else {
        Add-Check "Production homepage" "FAIL" "$ProductionBaseUrl did not look like the independent static site"
    }
}

$apexHomeResponse = Invoke-Http -Url (Join-Url $ApexBaseUrl "/")
if ($apexHomeResponse) {
    if ($apexHomeResponse.StatusCode -eq 200 -and
        $apexHomeResponse.Content -match "Fillmore Christian Church" -and
        $apexHomeResponse.Content -match "site\.webmanifest" -and
        $apexHomeResponse.Content -match "favicon\.svg" -and
        $apexHomeResponse.Content -notmatch "thechurchco|ssl\.thechurchco\.com") {
        Add-Check "Production apex homepage" "OK" "$ApexBaseUrl serves or redirects to the independent static site shell"
    } else {
        Add-Check "Production apex homepage" "FAIL" "$ApexBaseUrl did not look like the independent static site"
    }
}

$sermons = Invoke-Http -Url (Join-Url $ProductionBaseUrl "/sermons.html")
if ($sermons) {
    $sermonCards = ([regex]::Matches($sermons.Content, 'class="sermon-item')).Count
    $audioAvailabilityFlags = ([regex]::Matches($sermons.Content, 'data-has-audio="(?:true|false)"')).Count
    $archiveControlsPresent = $sermons.Content -match 'id="podcast-feed-url"' -and
        $sermons.Content -match 'id="sermon-search"' -and
        $sermons.Content -match 'id="sermon-year"' -and
        $sermons.Content -match 'id="sermon-sort"' -and
        $sermons.Content -match 'id="sermon-audio-only"' -and
        $sermons.Content -match 'id="sermon-clear"'

    if ($sermons.StatusCode -eq 200 -and
        $archiveControlsPresent -and
        $sermonCards -ge 70 -and
        $audioAvailabilityFlags -eq $sermonCards -and
        $sermons.Content -notmatch "thechurchco|ssl\.thechurchco\.com") {
        Add-Check "Production sermons archive" "OK" "$sermonCards sermon cards, archive filters, audio-only filter, and podcast subscribe control are live"
    } else {
        Add-Check "Production sermons archive" "FAIL" "Sermons archive is missing static archive controls/audio metadata, has too few cards, or still references TheChurchCo"
    }
}

$podcastPage = Invoke-Http -Url (Join-Url $ProductionBaseUrl "/podcast.html")
if ($podcastPage) {
    $staticLatestCount = ([regex]::Matches($podcastPage.Content, 'data-static-podcast-latest="true"')).Count
    $latestAudioSizeCount = ([regex]::Matches($podcastPage.Content, 'Audio \d+(?:\.\d+)? (?:KB|MB|GB|bytes)')).Count
    $latestDurationCount = ([regex]::Matches($podcastPage.Content, 'Duration \d+ (?:hr \d+ min|min \d+ sec)')).Count
    if ($podcastPage.StatusCode -eq 200 -and
        $podcastPage.Content -match 'id="podcast-feed-url"' -and
        $podcastPage.Content -match 'id="podcast-latest-list"' -and
        $staticLatestCount -eq 3 -and
        $latestAudioSizeCount -eq 3 -and
        $latestDurationCount -eq 3 -and
        $podcastPage.Content -match '/media/' -and
        $podcastPage.Content -match 'Open Message' -and
        $podcastPage.Content -match 'js/podcast\.js\?v=' -and
        $podcastPage.Content -match 'class="podcast-subscription-grid"' -and
        $podcastPage.Content -match 'data-subscribe-option="apple"' -and
        $podcastPage.Content -match 'data-subscribe-option="spotify"' -and
        $podcastPage.Content -match 'data-subscribe-option="rss"' -and
        $podcastPage.Content -match 'data-copy-value="https://www\.fillmorechristian\.org/podcast-category/fillmore-christian/feed/podcast"' -and
        $podcastPage.Content -match '"@type": "PodcastSeries"' -and
        $podcastPage.Content -notmatch "thechurchco|ssl\.thechurchco\.com") {
        Add-Check "Production podcast page" "OK" "Owned podcast subscription page is live with app choices and recent-message feed enhancement with audio sizes and durations"
    } else {
        Add-Check "Production podcast page" "FAIL" "Podcast page is missing app choices, feed copy controls, recent-message feed enhancement/audio sizes/durations, structured data, or still references TheChurchCo"
    }
}

foreach ($asset in @("site.webmanifest", "contact.vcf", "events.ics")) {
    $assetResponse = Invoke-Http -Url (Join-Url $ProductionBaseUrl $asset)
    if ($assetResponse) {
        if ($assetResponse.StatusCode -eq 200) {
            Add-Check "Production asset: $asset" "OK" "HTTP 200"
        } else {
            Add-Check "Production asset: $asset" "FAIL" "HTTP $($assetResponse.StatusCode)"
        }
    }
}

$contactResponse = Invoke-Http -Url (Join-Url $ProductionBaseUrl "/contact.html")
if ($contactResponse) {
    if ($contactResponse.StatusCode -eq 200 -and
        $contactResponse.Content -match 'data-mailto="church@fillmorechristian\.org"' -and
        $contactResponse.Content -match 'data-mailto-fallback' -and
        $contactResponse.Content -match 'data-copy-source="contact-message-draft"' -and
        $contactResponse.Content -match 'data-copy-value="church@fillmorechristian\.org"' -and
        $contactResponse.Content -match 'id="contact-email-copy-status"' -and
        $contactResponse.Content -notmatch "thechurchco|ssl\.thechurchco\.com") {
        Add-Check "Production contact fallback" "OK" "Contact page has static mailto form, copyable draft fallback, and copyable email fallback"
    } else {
        Add-Check "Production contact fallback" "FAIL" "Contact page is missing static contact controls or still references TheChurchCo"
    }
}

$podcastFeedUrl = Join-Url $ProductionBaseUrl $PodcastFeedPath
$feedResponse = Invoke-Http -Url $podcastFeedUrl
$feedXml = $null
if ($feedResponse) {
    try {
        [xml]$feedXml = $feedResponse.Content
        $items = @($feedXml.rss.channel.item)
        $enclosures = @($items | Where-Object { $_.enclosure -and $_.enclosure.url } | ForEach-Object { [string]$_.enclosure.url })
        $durationItems = @($items | Where-Object {
            $_.enclosure -and $_.enclosure.url -and @($_.ChildNodes | Where-Object { $_.LocalName -eq "duration" -and $_.InnerText -match '^\d{2}:\d{2}:\d{2}$' }).Count -gt 0
        })
        if ($items.Count -ge 70 -and $enclosures.Count -ge 70 -and $durationItems.Count -eq $enclosures.Count) {
            Add-Check "Production podcast feed" "OK" "$($items.Count) items, $($enclosures.Count) enclosures with durations"
        } else {
            Add-Check "Production podcast feed" "FAIL" "$($items.Count) items, $($enclosures.Count) enclosures, $($durationItems.Count) durations"
        }

        $dependentUrls = @($enclosures | Where-Object { $_ -match "thechurchco|ssl\.thechurchco\.com|thechurchco-production" })
        $nonHttpsUrls = @($enclosures | Where-Object { -not $_.StartsWith("https://") })
        $unexpectedHosts = @()
        if ($ExpectedAudioHost) {
            $unexpectedHosts = @(
                $enclosures |
                    ForEach-Object { ([Uri]$_).Host.ToLowerInvariant() } |
                    Where-Object { $_ -ne $ExpectedAudioHost.ToLowerInvariant() } |
                    Sort-Object -Unique
            )
        }

        if ($dependentUrls.Count -eq 0 -and $nonHttpsUrls.Count -eq 0 -and $unexpectedHosts.Count -eq 0) {
            Add-Check "Production audio independence" "OK" "All enclosures use https://$ExpectedAudioHost"
        } else {
            $details = @()
            if ($dependentUrls.Count -gt 0) { $details += "$($dependentUrls.Count) enclosure URL(s) still depend on TheChurchCo" }
            if ($nonHttpsUrls.Count -gt 0) { $details += "$($nonHttpsUrls.Count) enclosure URL(s) are not HTTPS" }
            if ($unexpectedHosts.Count -gt 0) { $details += "unexpected audio host(s): $($unexpectedHosts -join ', ')" }
            Add-Check "Production audio independence" "FAIL" ($details -join "; ")
        }

        $episodePath = ""
        $firstLink = [string]@($items | Where-Object { $_.link } | Select-Object -First 1).link
        if ($firstLink) {
            try {
                $episodePath = ([Uri]$firstLink).AbsolutePath
            } catch {}
        }
        if ($episodePath) {
            $episode = Invoke-Http -Url (Join-Url $ProductionBaseUrl $episodePath)
            if ($episode) {
                if ($episode.StatusCode -eq 200 -and $episode.Content -match "<audio" -and $episode.Content -match "Download Audio" -and $episode.Content -match 'class="sermon-duration"') {
                    Add-Check "Production episode pages" "OK" "$episodePath includes audio player, duration, and download"
                } else {
                    Add-Check "Production episode pages" "FAIL" "$episodePath is missing the static episode audio UI or duration"
                }
            }
        } else {
            Add-Check "Production episode pages" "FAIL" "Could not identify an episode URL from the production feed"
        }

        $tempFeed = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $tempFeed -Value $feedResponse.Content -NoNewline
            if ($VerifyAllPodcastMedia) {
                & (Join-Path $PSScriptRoot "test-podcast-media.ps1") -FeedPath $tempFeed -SampleCount $PodcastMediaSampleCount -TimeoutSec $TimeoutSec -Quiet -All
            } else {
                & (Join-Path $PSScriptRoot "test-podcast-media.ps1") -FeedPath $tempFeed -SampleCount $PodcastMediaSampleCount -TimeoutSec $TimeoutSec -Quiet
            }
            $scope = if ($VerifyAllPodcastMedia) { "all" } else { "$PodcastMediaSampleCount sampled" }
            Add-Check "Production audio media responses" "OK" "Verified $scope unique enclosure URL(s)"
        } catch {
            Add-Check "Production audio media responses" "FAIL" $_.Exception.Message
        } finally {
            Remove-Item -LiteralPath $tempFeed -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Add-Check "Production podcast feed" "FAIL" "Could not parse RSS from $podcastFeedUrl`: $($_.Exception.Message)"
    }
}

$r2VerifierPath = Join-Path $PSScriptRoot "test-r2-public-audio.ps1"
$productionMediaBaseUrl = (Join-Url $ProductionBaseUrl "media").TrimEnd("/")
if (Test-Path -LiteralPath $r2VerifierPath) {
    try {
        & $r2VerifierPath -ManifestPath $R2ManifestPath -BaseUrlOverride $productionMediaBaseUrl -All -TimeoutSec $TimeoutSec -Quiet
        Add-Check "Production R2 media route" "OK" "All R2 audio manifest objects respond through $productionMediaBaseUrl"
    } catch {
        Add-Check "Production R2 media route" "FAIL" $_.Exception.Message
    }
} else {
    Add-Check "Production R2 media route" "FAIL" "Missing verifier script: $r2VerifierPath"
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) TheChurchCo cancellation readiness check(s) failed. Do not cancel TheChurchCo yet."
}

$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) TheChurchCo cancellation readiness warning(s) remain."
}
