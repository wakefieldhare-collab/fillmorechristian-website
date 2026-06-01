param(
    [string]$StagingBaseUrl = "https://wakefieldhare-collab.github.io/fillmorechristian-website",
    [string]$BuildOutputDir = "dist",
    [switch]$SkipRemote,
    [switch]$VerifyAudioHashes,
    [switch]$RequireIndependentAudio
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
    "_redirects"
)

$missingRequired = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if ($missingRequired.Count -eq 0) {
    Add-Check "Required static files" "OK" "$($requiredFiles.Count) required files present"
} else {
    Add-Check "Required static files" "FAIL" ("Missing: " + ($missingRequired -join ", "))
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
    $forbiddenBuildPaths = @("exports", "scripts", ".git", "MIGRATION-RUNBOOK.md", "SETUP-GUIDE.md") |
        Where-Object { Test-Path -LiteralPath (Join-Path $buildOutputPath $_) }

    if ($missingBuildFiles.Count -eq 0 -and $forbiddenBuildPaths.Count -eq 0) {
        Add-Check "Cloudflare build output" "OK" "$BuildOutputDir contains publish assets and excludes migration-only files"
    } else {
        $details = @()
        if ($missingBuildFiles.Count -gt 0) { $details += "missing: $($missingBuildFiles -join ', ')" }
        if ($forbiddenBuildPaths.Count -gt 0) { $details += "should not publish: $($forbiddenBuildPaths -join ', ')" }
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
}

$manifestPath = Join-Path $root "exports\thechurchco-podcast\manifest.csv"
$audioDir = Join-Path $root "exports\thechurchco-podcast\audio"
$inventoryPath = Join-Path $root "exports\thechurchco-podcast\audio-inventory.csv"

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

if (-not $SkipRemote) {
    foreach ($path in @("", "about.html", "beliefs.html", "team.html", "events.html", "sermons.html", "contact.html", "podcast-category/fillmore-christian/feed/podcast", "robots.txt", "sitemap.xml")) {
        $url = Join-Url $StagingBaseUrl $path
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -MaximumRedirection 5
            Add-Check "Staging URL: /$path" "OK" "HTTP $($response.StatusCode)"

            if ($path -in @("", "about.html", "beliefs.html", "team.html", "events.html", "sermons.html", "contact.html")) {
                $expectedCanonical = if ($path -eq "") {
                    "https://www.fillmorechristian.org/"
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
            }

            if ($path -eq "sermons.html") {
                $remoteCards = ([regex]::Matches($response.Content, 'class="sermon-item')).Count
                if ($feedItemCounts.ContainsKey($feedPaths[0]) -and $remoteCards -ne $feedItemCounts[$feedPaths[0]]) {
                    Add-Check "Staging sermon card count" "FAIL" "$remoteCards remote cards, expected $($feedItemCounts[$feedPaths[0]])"
                } else {
                    Add-Check "Staging sermon card count" "OK" "$remoteCards sermon cards"
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
            }
        } catch {
            Add-Check "Staging URL: /$path" "FAIL" $_.Exception.Message
        }
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
