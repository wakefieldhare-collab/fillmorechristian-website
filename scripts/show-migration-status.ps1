param(
    [string]$Domain = "fillmorechristian.org",
    [string]$StagingBaseUrl = "https://wakefieldhare-collab.github.io/fillmorechristian-website",
    [string]$ExpectedGitHubOwner = "wakefieldhare-collab",
    [string]$ExpectedGitHubRepo = "fillmorechristian-website",
    [string]$ForbiddenGitHubOwner = "wake-byte",
    [string]$ExpectedAudioHost = "media.fillmorechristian.org",
    [datetime]$RenewalDate = "2026-06-15",
    [datetime]$DisableAutoRenewDeadline = "2026-06-14",
    [switch]$SkipNetwork,
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$rows = New-Object System.Collections.Generic.List[object]

function Add-Status {
    param(
        [string]$Area,
        [ValidateSet("OK", "WARN", "FAIL", "AUTH", "INFO")]
        [string]$Status,
        [string]$Details
    )

    $rows.Add([pscustomobject]@{
        Area = $Area
        Status = $Status
        Details = $Details
    })
}

function Get-WranglerInvocation {
    $wranglerCommand = Get-Command wrangler -ErrorAction SilentlyContinue
    if ($wranglerCommand) {
        return [pscustomobject]@{
            Command = $wranglerCommand.Source
            PrefixArgs = @()
            Label = "wrangler"
        }
    }

    $npxCommand = Get-Command npx -ErrorAction SilentlyContinue
    if ($npxCommand) {
        return [pscustomobject]@{
            Command = $npxCommand.Source
            PrefixArgs = @("wrangler")
            Label = "npx wrangler"
        }
    }

    return $null
}

function ConvertTo-LocalAudioFileName {
    param([string]$Url)

    try {
        $uri = [Uri]$Url
        $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        return $fileName -replace '[^\w\.\-]+', '-'
    } catch {
        return ""
    }
}

function Get-FeedEnclosureUrls {
    param([xml]$Feed)

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Feed.rss.channel.item)) {
        if ($item.enclosure -and $item.enclosure.url) {
            $urls.Add([string]$item.enclosure.url)
        }
    }
    return $urls
}

function Get-ContentText {
    param([object]$Response)

    if ($Response.Content -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString($Response.Content)
    }

    return [string]$Response.Content
}

$today = Get-Date
$daysUntilRenewal = [int]($RenewalDate.Date - $today.Date).TotalDays
$daysUntilDecision = [int]($DisableAutoRenewDeadline.Date - $today.Date).TotalDays
if ($daysUntilDecision -lt 0) {
    Add-Status "Squarespace renewal" "FAIL" "Auto-renew decision deadline $($DisableAutoRenewDeadline.ToString('yyyy-MM-dd')) has passed; check Squarespace immediately."
} elseif ($daysUntilDecision -le 3) {
    Add-Status "Squarespace renewal" "WARN" "$daysUntilDecision day(s) until the auto-renew decision deadline; renewal is $($RenewalDate.ToString('yyyy-MM-dd'))."
} else {
    Add-Status "Squarespace renewal" "OK" "$daysUntilDecision day(s) until the auto-renew decision deadline; renewal is in $daysUntilRenewal day(s)."
}

try {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    $expectedPattern = "github\.com[:/]$([regex]::Escape($ExpectedGitHubOwner))/$([regex]::Escape($ExpectedGitHubRepo))(\.git)?$"
    if ($originUrl -match [regex]::Escape($ForbiddenGitHubOwner)) {
        Add-Status "GitHub owner" "FAIL" "Origin points at forbidden work owner: $originUrl"
    } elseif ($originUrl -match $expectedPattern) {
        Add-Status "GitHub owner" "OK" "Origin is $ExpectedGitHubOwner/$ExpectedGitHubRepo."
    } else {
        Add-Status "GitHub owner" "WARN" "Unexpected origin remote: $originUrl"
    }

    $latestCommit = (& git -C $root log -1 --oneline 2>$null).Trim()
    $dirtyFiles = @(& git -C $root status --porcelain)
    if ($dirtyFiles.Count -eq 0) {
        Add-Status "Working tree" "OK" "Clean at $latestCommit."
    } else {
        Add-Status "Working tree" "WARN" "$($dirtyFiles.Count) changed file(s); latest commit is $latestCommit."
    }
} catch {
    Add-Status "GitHub owner" "WARN" "Could not inspect git state: $($_.Exception.Message)"
}

try {
    $ghStatus = (& gh auth status 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Add-Status "GitHub auth" "WARN" "gh auth status did not pass."
    } else {
        $activeAccountMatches = [regex]::Matches($ghStatus, "account\s+([^\s]+)[\s\S]*?Active account:\s+true")
        $activeAccounts = @($activeAccountMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($ForbiddenGitHubOwner -in $activeAccounts) {
            Add-Status "GitHub auth" "FAIL" "Active gh account is forbidden work owner $ForbiddenGitHubOwner."
        } elseif ($ExpectedGitHubOwner -in $activeAccounts) {
            Add-Status "GitHub auth" "OK" "Active gh account is $ExpectedGitHubOwner."
        } elseif ($activeAccounts.Count -gt 0) {
            Add-Status "GitHub auth" "WARN" "Active gh account is $($activeAccounts -join ', '), expected $ExpectedGitHubOwner."
        } else {
            Add-Status "GitHub auth" "WARN" "Could not identify the active gh account."
        }
    }
} catch {
    Add-Status "GitHub auth" "WARN" "Could not inspect gh auth: $($_.Exception.Message)"
}

$wrangler = Get-WranglerInvocation
if ($null -eq $wrangler) {
    Add-Status "Cloudflare auth" "FAIL" "Wrangler is not available. Install or use npx wrangler."
} else {
    $whoamiOutput = & $wrangler.Command @($wrangler.PrefixArgs) whoami 2>&1
    if ($LASTEXITCODE -eq 0 -and (($whoamiOutput -join "`n") -notmatch "not authenticated")) {
        Add-Status "Cloudflare auth" "OK" "$($wrangler.Label) is authenticated."
    } else {
        Add-Status "Cloudflare auth" "AUTH" "Run npx wrangler login before R2 upload, Pages deploy, DNS, or production cutover."
    }
}

$feedPath = Join-Path $root "podcast-category\fillmore-christian\feed\podcast"
$manifestPath = Join-Path $root "exports\thechurchco-podcast\manifest.csv"
$audioDir = Join-Path $root "exports\thechurchco-podcast\audio"
$inventoryPath = Join-Path $root "exports\thechurchco-podcast\audio-inventory.csv"
$r2ManifestPath = Join-Path $root "exports\thechurchco-podcast\r2-audio-manifest.csv"
$feedEnclosureUrls = @()

if (Test-Path -LiteralPath $feedPath) {
    try {
        [xml]$feed = Get-Content -Raw -Encoding UTF8 -LiteralPath $feedPath
        $items = @($feed.rss.channel.item)
        $feedEnclosureUrls = @(Get-FeedEnclosureUrls -Feed $feed)
        $churchCoUrls = @($feedEnclosureUrls | Where-Object { $_ -match "thechurchco|churchco" })
        $ownedAudioUrls = @($feedEnclosureUrls | Where-Object {
            try { ([Uri]$_).Host -eq $ExpectedAudioHost } catch { $false }
        })

        if ($churchCoUrls.Count -gt 0) {
            Add-Status "Podcast feed" "WARN" "$($items.Count) items, $($feedEnclosureUrls.Count) enclosures; $($churchCoUrls.Count) still depend on TheChurchCo."
        } elseif ($ownedAudioUrls.Count -eq $feedEnclosureUrls.Count -and $feedEnclosureUrls.Count -gt 0) {
            Add-Status "Podcast feed" "OK" "$($items.Count) items; all $($feedEnclosureUrls.Count) enclosures use $ExpectedAudioHost."
        } else {
            Add-Status "Podcast feed" "WARN" "$($items.Count) items; enclosures do not all use $ExpectedAudioHost."
        }
    } catch {
        Add-Status "Podcast feed" "FAIL" "Could not parse local feed: $($_.Exception.Message)"
    }
} else {
    Add-Status "Podcast feed" "FAIL" "Local podcast feed is missing."
}

if ((Test-Path -LiteralPath $manifestPath) -and (Test-Path -LiteralPath $audioDir)) {
    $manifestRows = @(Import-Csv -LiteralPath $manifestPath)
    $rowsWithAudio = @($manifestRows | Where-Object { $_.EnclosureUrl })
    $expectedAudioFiles = @($rowsWithAudio | ForEach-Object { ConvertTo-LocalAudioFileName $_.EnclosureUrl } | Where-Object { $_ } | Select-Object -Unique)
    $audioFiles = @(Get-ChildItem -LiteralPath $audioDir -File)
    $missingAudio = @($expectedAudioFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $audioDir $_)) })
    $totalBytes = ($audioFiles | Measure-Object -Property Length -Sum).Sum
    $sizeGb = [Math]::Round($totalBytes / 1GB, 2)
    if ($missingAudio.Count -eq 0) {
        Add-Status "Audio backup" "OK" "$($audioFiles.Count) local file(s), $sizeGb GB, covering $($expectedAudioFiles.Count) unique feed audio file(s)."
    } else {
        Add-Status "Audio backup" "FAIL" "Missing local backup file(s): $($missingAudio -join ', ')"
    }
} else {
    Add-Status "Audio backup" "FAIL" "Manifest or audio backup directory is missing."
}

if (Test-Path -LiteralPath $inventoryPath) {
    $inventoryRows = @(Import-Csv -LiteralPath $inventoryPath)
    Add-Status "Audio inventory" "OK" "$($inventoryRows.Count) local audio inventory row(s) with recorded size and SHA-256."
} else {
    Add-Status "Audio inventory" "WARN" "Audio inventory is missing."
}

if (Test-Path -LiteralPath $r2ManifestPath) {
    $r2Rows = @(Import-Csv -LiteralPath $r2ManifestPath)
    $referenceTotal = ($r2Rows | Measure-Object -Property FeedReferenceCount -Sum).Sum
    $publicHosts = @($r2Rows.PublicUrl | Where-Object { $_ } | ForEach-Object {
        try { ([Uri]$_).Host } catch { "" }
    } | Where-Object { $_ } | Select-Object -Unique)

    if ($referenceTotal -eq $feedEnclosureUrls.Count -and $ExpectedAudioHost -in $publicHosts) {
        Add-Status "R2 manifest" "OK" "$($r2Rows.Count) object(s) cover $referenceTotal feed reference(s) for $ExpectedAudioHost."
    } else {
        Add-Status "R2 manifest" "WARN" "$($r2Rows.Count) object(s), $referenceTotal feed reference(s), host(s): $($publicHosts -join ', ')."
    }
} else {
    Add-Status "R2 manifest" "WARN" "R2 manifest is missing; run scripts\build-r2-audio-manifest.ps1."
}

if (-not $SkipNetwork) {
    try {
        $stagingHome = Invoke-WebRequest -UseBasicParsing -Uri ($StagingBaseUrl.TrimEnd("/") + "/") -TimeoutSec 20
        $stagingFeed = Invoke-WebRequest -UseBasicParsing -Uri ($StagingBaseUrl.TrimEnd("/") + "/podcast-category/fillmore-christian/feed/podcast") -TimeoutSec 20
        $feedText = Get-ContentText -Response $stagingFeed
        [xml]$stagingFeedXml = $feedText
        Add-Status "Staging" "OK" "Home HTTP $($stagingHome.StatusCode); RSS HTTP $($stagingFeed.StatusCode) with $(@($stagingFeedXml.rss.channel.item).Count) item(s)."
    } catch {
        Add-Status "Staging" "WARN" "Could not verify staging: $($_.Exception.Message)"
    }

    try {
        $nsValues = @(Resolve-DnsName -Name $Domain -Type NS -ErrorAction Stop | Where-Object { $_.NameHost } | ForEach-Object { $_.NameHost.TrimEnd(".").ToLowerInvariant() } | Sort-Object -Unique)
        if ($nsValues -match "cloudflare\.com$") {
            Add-Status "DNS nameservers" "OK" "$Domain is using Cloudflare nameservers: $($nsValues -join ', ')."
        } else {
            Add-Status "DNS nameservers" "AUTH" "$Domain is still using pre-cutover nameservers: $($nsValues -join ', ')."
        }
    } catch {
        Add-Status "DNS nameservers" "WARN" "Could not resolve nameservers: $($_.Exception.Message)"
    }

    try {
        $mxValues = @(Resolve-DnsName -Name $Domain -Type MX -ErrorAction Stop | Where-Object { $_.NameExchange } | ForEach-Object { $_.NameExchange.TrimEnd(".").ToLowerInvariant() } | Sort-Object -Unique)
        if (("mxa.mailgun.org" -in $mxValues) -and ("mxb.mailgun.org" -in $mxValues)) {
            Add-Status "Mail DNS" "OK" "Mailgun MX records are visible."
        } else {
            Add-Status "Mail DNS" "FAIL" "Expected Mailgun MX records were not both visible. Found: $($mxValues -join ', ')."
        }
    } catch {
        Add-Status "Mail DNS" "WARN" "Could not resolve MX records: $($_.Exception.Message)"
    }
} else {
    Add-Status "Network checks" "INFO" "Skipped by -SkipNetwork."
}

$authNeeded = @($rows | Where-Object { $_.Status -eq "AUTH" })
if ($authNeeded.Count -gt 0) {
    Add-Status "Next authorization" "AUTH" "Wake authorization needed next: npx wrangler login, then Cloudflare Pages/R2/DNS setup."
} else {
    Add-Status "Next authorization" "INFO" "No immediate auth blocker detected; run the strict readiness gates before production changes."
}

if ($AsJson) {
    $rows | ConvertTo-Json -Depth 4
    return
}

Write-Host "Fillmore Christian migration status"
Write-Host "Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Write-Host ""
$rows | Format-Table -AutoSize
