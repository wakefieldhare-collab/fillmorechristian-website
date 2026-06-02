param(
    [string]$Domain = "fillmorechristian.org",
    [string]$StagingBaseUrl = "https://wakefieldhare-collab.github.io/fillmorechristian-website",
    [string]$ExpectedGitHubOwner = "wakefieldhare-collab",
    [string]$ExpectedGitHubRepo = "fillmorechristian-website",
    [string]$ForbiddenGitHubOwner = "wake-byte",
    [string]$CloudflareAccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$CloudflarePagesProject = "fillmorechristian-website",
    [string]$R2Bucket = "fillmore-christian-sermons",
    [string]$ExpectedAudioHost = "www.fillmorechristian.org",
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

function Get-WranglerOAuthToken {
    $configPath = Join-Path $env:APPDATA "xdg.config\.wrangler\config\default.toml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return ""
    }

    $configText = Get-Content -Raw -LiteralPath $configPath
    $match = [regex]::Match($configText, '(?m)^oauth_token\s*=\s*"([^"]+)"')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return ""
}

function Get-CloudflareApiToken {
    foreach ($name in @("CLOUDFLARE_API_TOKEN", "CF_API_TOKEN")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) {
            return $value
        }
    }

    return ""
}

function Invoke-CloudflareGet {
    param(
        [string]$Path,
        [string]$Token
    )

    $headers = @{ Authorization = "Bearer $Token" }
    return Invoke-RestMethod -Method Get -Headers $headers -Uri ("https://api.cloudflare.com/client/v4/" + $Path.TrimStart("/"))
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
$cloudflareAuthenticated = $false
$cloudflareToken = ""
$cloudflareDnsToken = Get-CloudflareApiToken
if ($cloudflareDnsToken) {
    Add-Status "Cloudflare token cleanup" "INFO" "A Cloudflare DNS API token is available in this shell; revoke temporary migration tokens after DNS cutover and cancellation readiness pass."
    Remove-Item Env:\CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CF_API_TOKEN -ErrorAction SilentlyContinue
}
$cloudflareZoneStatus = ""
$cloudflareZoneId = ""
$cloudflareZoneNameservers = @()
$cloudflareDnsPrepared = $false
if ($null -eq $wrangler) {
    Add-Status "Cloudflare auth" "FAIL" "Wrangler is not available. Install or use npx wrangler."
} else {
    $whoamiOutput = & $wrangler.Command @($wrangler.PrefixArgs) whoami 2>&1
    if ($LASTEXITCODE -eq 0 -and (($whoamiOutput -join "`n") -notmatch "not authenticated")) {
        $cloudflareAuthenticated = $true
        $cloudflareToken = Get-WranglerOAuthToken
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
    if ($cloudflareAuthenticated -and $wrangler) {
        if ($cloudflareToken) {
            try {
                $zoneResponse = Invoke-CloudflareGet -Token $cloudflareToken -Path "zones?name=$Domain&account.id=$CloudflareAccountId"
                $zone = @($zoneResponse.result | Where-Object { $_.name -eq $Domain } | Select-Object -First 1)
                if ($zone.Count -gt 0) {
                    $cloudflareZoneStatus = [string]$zone[0].status
                    $cloudflareZoneId = [string]$zone[0].id
                    $cloudflareZoneNameservers = @($zone[0].name_servers | ForEach-Object { [string]$_ })
                    if ($cloudflareZoneStatus -eq "active") {
                        Add-Status "Cloudflare zone" "OK" "$Domain is active in Cloudflare with nameservers: $($cloudflareZoneNameservers -join ', ')."
                    } else {
                        Add-Status "Cloudflare zone" "AUTH" "$Domain is in Cloudflare with status $cloudflareZoneStatus; assigned nameservers: $($cloudflareZoneNameservers -join ', ')."
                    }
                } else {
                    Add-Status "Cloudflare zone" "AUTH" "$Domain has not been added to Cloudflare DNS."
                }
            } catch {
                Add-Status "Cloudflare zone" "WARN" "Could not inspect Cloudflare zone metadata: $($_.Exception.Message)"
            }
        }

        if ($cloudflareDnsToken -and $cloudflareZoneId) {
            try {
                $recordsResponse = Invoke-CloudflareGet -Token $cloudflareDnsToken -Path "zones/$cloudflareZoneId/dns_records?per_page=100"
                $records = @($recordsResponse.result)
                $dnsIssues = New-Object System.Collections.Generic.List[string]

                if (@($records | Where-Object { $_.type -eq "CNAME" -and $_.name -eq $Domain -and $_.content -eq "$CloudflarePagesProject.pages.dev" -and [bool]$_.proxied }).Count -eq 0) {
                    $dnsIssues.Add("missing proxied apex Pages CNAME")
                }
                if (@($records | Where-Object { $_.type -eq "CNAME" -and $_.name -eq "www.$Domain" -and $_.content -eq "$CloudflarePagesProject.pages.dev" -and [bool]$_.proxied }).Count -eq 0) {
                    $dnsIssues.Add("missing proxied www Pages CNAME")
                }
                if (@($records | Where-Object { $_.type -eq "A" -and $_.name -eq $Domain -and $_.content -eq "77.83.141.16" }).Count -gt 0) {
                    $dnsIssues.Add("old TheChurchCo apex A remains")
                }
                if (@($records | Where-Object { $_.type -eq "CNAME" -and $_.name -eq "www.$Domain" -and $_.content -eq "ssl.thechurchco.com" }).Count -gt 0) {
                    $dnsIssues.Add("old TheChurchCo www CNAME remains")
                }
                if (@($records | Where-Object { $_.type -eq "MX" -and $_.name -eq $Domain -and $_.content -in @("mxa.mailgun.org", "mxb.mailgun.org") }).Count -ne 2) {
                    $dnsIssues.Add("missing Mailgun MX records")
                }
                if (@($records | Where-Object { $_.type -eq "TXT" -and $_.name -eq $Domain -and $_.content -eq "v=spf1 include:mailgun.org ~all" }).Count -eq 0) {
                    $dnsIssues.Add("missing SPF TXT")
                }
                if (@($records | Where-Object { $_.type -eq "TXT" -and $_.name -eq "_dmarc.$Domain" -and $_.content -match "^v=DMARC1;" }).Count -eq 0) {
                    $dnsIssues.Add("missing DMARC TXT")
                }
                if (@($records | Where-Object { $_.type -eq "TXT" -and $_.name -eq "pic._domainkey.$Domain" -and $_.content -match "^k=rsa;" }).Count -eq 0) {
                    $dnsIssues.Add("missing Mailgun DKIM TXT")
                }

                if ($dnsIssues.Count -eq 0) {
                    $cloudflareDnsPrepared = $true
                    Add-Status "Cloudflare DNS records" "OK" "Pages, mail, SPF, DMARC, DKIM, and verification records are prepared in Cloudflare; old TheChurchCo web targets are removed."
                } else {
                    Add-Status "Cloudflare DNS records" "AUTH" "Cloudflare DNS still needs record work: $($dnsIssues -join '; ')."
                }
            } catch {
                Add-Status "Cloudflare DNS records" "WARN" "Could not inspect Cloudflare DNS records: $($_.Exception.Message)"
            }
        } elseif ($cloudflareZoneId) {
            Add-Status "Cloudflare DNS records" "INFO" "DNS records were not inspected because no CLOUDFLARE_API_TOKEN or CF_API_TOKEN is set for DNS-read access."
        }

        try {
            $pagesOutput = (& $wrangler.Command @($wrangler.PrefixArgs) pages project list 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0 -and $pagesOutput -match [regex]::Escape($CloudflarePagesProject) -and $pagesOutput -match "$([regex]::Escape($CloudflarePagesProject))\.pages\.dev") {
                Add-Status "Cloudflare Pages" "OK" "Project $CloudflarePagesProject is deployed at https://$CloudflarePagesProject.pages.dev/."
            } elseif ($LASTEXITCODE -eq 0) {
                Add-Status "Cloudflare Pages" "WARN" "Could not find $CloudflarePagesProject in Pages project list."
            } else {
                Add-Status "Cloudflare Pages" "WARN" "Could not list Cloudflare Pages projects."
            }
        } catch {
            Add-Status "Cloudflare Pages" "WARN" "Could not inspect Cloudflare Pages: $($_.Exception.Message)"
        }

        if ($cloudflareToken) {
            try {
                $pagesDomainsResponse = Invoke-CloudflareGet -Token $cloudflareToken -Path "accounts/$CloudflareAccountId/pages/projects/$CloudflarePagesProject/domains"
                $pagesDomains = @($pagesDomainsResponse.result | Where-Object { $_.name -in @($Domain, "www.$Domain") })
                $expectedPagesDomains = @($Domain, "www.$Domain")
                $missingPagesDomains = @($expectedPagesDomains | Where-Object { $_ -notin @($pagesDomains.name) })
                if ($missingPagesDomains.Count -eq 0 -and $pagesDomains.Count -gt 0) {
                    $domainDetails = @($pagesDomains | Sort-Object name | ForEach-Object { "$($_.name):$($_.status)" })
                    if (@($pagesDomains | Where-Object { $_.status -ne "active" }).Count -eq 0) {
                        Add-Status "Pages custom domains" "OK" "Apex and www are active: $($domainDetails -join ', ')."
                    } else {
                        Add-Status "Pages custom domains" "AUTH" "Apex and www are attached but pending: $($domainDetails -join ', ')."
                    }
                } else {
                    Add-Status "Pages custom domains" "AUTH" "Missing Pages custom domain(s): $($missingPagesDomains -join ', ')."
                }
            } catch {
                Add-Status "Pages custom domains" "WARN" "Could not inspect Pages custom domains: $($_.Exception.Message)"
            }
        }

        try {
            $r2Output = (& $wrangler.Command @($wrangler.PrefixArgs) r2 bucket list 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0) {
                if ($r2Output -match [regex]::Escape($R2Bucket)) {
                    Add-Status "R2 account" "OK" "R2 is enabled and bucket $R2Bucket exists."
                } else {
                    Add-Status "R2 account" "WARN" "R2 is enabled, but bucket $R2Bucket was not listed."
                }
            } elseif ($r2Output -match "enable R2|code:\s*10042") {
                Add-Status "R2 account" "AUTH" "Enable R2 in the Cloudflare dashboard before uploading sermon audio."
            } else {
                Add-Status "R2 account" "WARN" "Could not list R2 buckets."
            }
        } catch {
            $r2Error = $_.Exception.Message
            if ($r2Error -match "enable R2|code:\s*10042|/r2/buckets") {
                Add-Status "R2 account" "AUTH" "Enable R2 in the Cloudflare dashboard before uploading sermon audio."
            } else {
                Add-Status "R2 account" "WARN" "Could not inspect R2: $r2Error"
            }
        }
    }

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
    $authAreas = @($authNeeded | ForEach-Object { $_.Area })
    $dnsApplyGuidance = "Run npm run apply:cloudflare-dns -- -Apply after setting CLOUDFLARE_API_TOKEN with Zone:Read and Zone:DNS Edit, or verify the same records in the Cloudflare dashboard"
    if ("Cloudflare auth" -in $authAreas) {
        Add-Status "Next authorization" "AUTH" "Wake authorization needed next: run npx wrangler login."
    } elseif (("Cloudflare zone" -in $authAreas) -and ($cloudflareZoneStatus -eq "pending") -and $cloudflareZoneNameservers.Count -gt 0) {
        if ($cloudflareDnsPrepared) {
            Add-Status "Next authorization" "AUTH" "Wake authorization needed next: set Squarespace nameservers to $($cloudflareZoneNameservers -join ', '). Cloudflare DNS records are already prepared."
        } elseif (-not $cloudflareDnsToken) {
            Add-Status "Next authorization" "AUTH" "Wake authorization needed next: verify Cloudflare DNS records with a DNS-read token or dashboard, then set Squarespace nameservers to $($cloudflareZoneNameservers -join ', ')."
        } else {
            Add-Status "Next authorization" "AUTH" "Wake authorization needed next: $dnsApplyGuidance, then set Squarespace nameservers to $($cloudflareZoneNameservers -join ', ')."
        }
    } elseif (("R2 account" -in $authAreas) -and ("DNS nameservers" -in $authAreas)) {
        Add-Status "Next authorization" "AUTH" "Wake authorization needed next: enable R2, add fillmorechristian.org to Cloudflare DNS, then update Squarespace nameservers when records are verified."
    } elseif ("R2 account" -in $authAreas) {
        Add-Status "Next authorization" "AUTH" "Wake authorization needed next: enable R2 in the Cloudflare dashboard."
    } elseif ("DNS nameservers" -in $authAreas) {
        if ($cloudflareZoneNameservers.Count -gt 0) {
            if ($cloudflareDnsPrepared) {
                Add-Status "Next authorization" "AUTH" "Wake authorization needed next: set Squarespace nameservers to $($cloudflareZoneNameservers -join ', '). Cloudflare DNS records are already prepared."
            } elseif (-not $cloudflareDnsToken) {
                Add-Status "Next authorization" "AUTH" "Wake authorization needed next: verify Cloudflare DNS records with a DNS-read token or dashboard, then set Squarespace nameservers to $($cloudflareZoneNameservers -join ', ')."
            } else {
                Add-Status "Next authorization" "AUTH" "Wake authorization needed next: $dnsApplyGuidance, then set Squarespace nameservers to $($cloudflareZoneNameservers -join ', ')."
            }
        } else {
            Add-Status "Next authorization" "AUTH" "Wake authorization needed next: add fillmorechristian.org to Cloudflare DNS and update Squarespace nameservers after records are verified."
        }
    } else {
        Add-Status "Next authorization" "AUTH" "Wake authorization is needed for: $($authAreas -join ', ')."
    }
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
