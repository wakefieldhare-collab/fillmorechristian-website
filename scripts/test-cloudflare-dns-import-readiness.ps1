param(
    [string]$Domain = "fillmorechristian.org",
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$PagesProject = "fillmorechristian-website",
    [string]$Bucket = "fillmore-christian-sermons",
    [string]$PreserveCsvPath = "exports\dns\fillmorechristian.org-cloudflare-preserve-records.csv",
    [string]$PreserveZonePath = "exports\dns\fillmorechristian.org-cloudflare-preserve-records.zone"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$checks = New-Object System.Collections.Generic.List[object]

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $root $Path
}

function Add-Check {
    param(
        [string]$Name,
        [ValidateSet("OK", "WARN", "FAIL", "INFO")]
        [string]$Status,
        [string]$Details
    )

    $checks.Add([pscustomobject]@{
        Status = $Status
        Check = $Name
        Details = $Details
    })
}

function Resolve-Answers {
    param(
        [string]$Name,
        [string]$Type
    )

    try {
        return @(Resolve-DnsName -Name $Name -Type $Type -ErrorAction Stop | Where-Object { $_.Section -eq "Answer" })
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

function Invoke-CloudflareGet {
    param(
        [string]$Path,
        [string]$Token
    )

    $headers = @{ Authorization = "Bearer $Token" }
    return Invoke-RestMethod -Method Get -Headers $headers -Uri ("https://api.cloudflare.com/client/v4/" + $Path.TrimStart("/"))
}

$preserveCsvFullPath = Resolve-RepoPath $PreserveCsvPath
$preserveZoneFullPath = Resolve-RepoPath $PreserveZonePath
$cloudflareToken = ""
$assignedNameservers = @()
$cloudflareZoneStatus = ""
$expectedPreserveRecords = @(
    @{ Name = $Domain; Type = "MX"; Value = "mxa.mailgun.org"; Priority = "10" },
    @{ Name = $Domain; Type = "MX"; Value = "mxb.mailgun.org"; Priority = "10" },
    @{ Name = $Domain; Type = "TXT"; Value = "MS=ms48673064"; Priority = "" },
    @{ Name = $Domain; Type = "TXT"; Value = "v=spf1 include:mailgun.org ~all"; Priority = "" },
    @{ Name = "pic._domainkey.$Domain"; Type = "TXT"; Value = "k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDDMspMJXAZ/D2ygNZBnGbLY5Z9DjNaNiLDjKY79O1JYgtYlkOERm5SVNOb1nKavNA98hqTLLN+1N7LQGoaeqY0O8ddDa8NclV57cTekdu4by/fcKN+8zycaOE2HRH9hZP1RLNmandRuUQfmTYMrXIWrjBU0xaQdbXZHMP0pN5FuQIDAQAB"; Priority = "" },
    @{ Name = "cbsw2pw4sdud.$Domain"; Type = "CNAME"; Value = "gv-6xwzpofnvqguxs.dv.googlehosted.com"; Priority = "" },
    @{ Name = "4jb3ni34htue.$Domain"; Type = "CNAME"; Value = "gv-xvljhthdwk5dxh.dv.googlehosted.com"; Priority = "" },
    @{ Name = "334xc4sml6cf.$Domain"; Type = "CNAME"; Value = "gv-ujhethalu73pqt.dv.googlehosted.com"; Priority = "" }
)

if (-not (Test-Path -LiteralPath $preserveCsvFullPath)) {
    Add-Check "Preserve CSV" "FAIL" "Missing $preserveCsvFullPath"
} else {
    $records = @(Import-Csv -LiteralPath $preserveCsvFullPath)
    if ($records.Count -eq 0) {
        Add-Check "Preserve CSV" "FAIL" "Preserve CSV has no records"
    } else {
        Add-Check "Preserve CSV" "OK" "$($records.Count) import record(s) found"
    }

    $forbidden = @(
        $records | Where-Object {
            ($_.Name -eq $Domain -and $_.Type -in @("A", "AAAA")) -or
            ($_.Name -eq "www.$Domain" -and $_.Type -eq "CNAME") -or
            ($_.Value -match "thechurchco|77\.83\.141\.16")
        }
    )
    if ($forbidden.Count -eq 0) {
        Add-Check "Old website records excluded" "OK" "Import file does not carry TheChurchCo web records"
    } else {
        Add-Check "Old website records excluded" "FAIL" "Forbidden web record(s): $(@($forbidden | ForEach-Object { "$($_.Type) $($_.Name) -> $($_.Value)" }) -join '; ')"
    }

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($required in $expectedPreserveRecords) {
        $match = @(
            $records | Where-Object {
                $_.Name -eq $required.Name -and
                $_.Type -eq $required.Type -and
                $_.Value -eq $required.Value -and
                ([string]$_.Priority) -eq $required.Priority
            }
        )
        if ($match.Count -eq 0) {
            $missing.Add("$($required.Type) $($required.Name) -> $($required.Value)")
        }
    }
    if ($missing.Count -eq 0) {
        Add-Check "Required preserve records" "OK" "Mailgun, Microsoft, DKIM, and Google verification records are present"
    } else {
        Add-Check "Required preserve records" "FAIL" "Missing: $($missing -join '; ')"
    }
}

if (-not (Test-Path -LiteralPath $preserveZoneFullPath)) {
    Add-Check "BIND zone import file" "FAIL" "Missing $preserveZoneFullPath"
} else {
    $zoneText = Get-Content -Raw -LiteralPath $preserveZoneFullPath
    $zoneIssues = New-Object System.Collections.Generic.List[string]
    foreach ($needle in @("mxa.mailgun.org.", "mxb.mailgun.org.", '"MS=ms48673064"', '"v=spf1 include:mailgun.org ~all"', "pic._domainkey", "gv-6xwzpofnvqguxs.dv.googlehosted.com.", "gv-xvljhthdwk5dxh.dv.googlehosted.com.", "gv-ujhethalu73pqt.dv.googlehosted.com.")) {
        if ($zoneText -notmatch [regex]::Escape($needle)) {
            $zoneIssues.Add($needle)
        }
    }
    if ($zoneText -match "ssl\.thechurchco\.com|77\.83\.141\.16") {
        $zoneIssues.Add("old website records still present")
    }

    if ($zoneIssues.Count -eq 0) {
        Add-Check "BIND zone import file" "OK" "Zone import file contains preserve records and excludes old website targets"
    } else {
        Add-Check "BIND zone import file" "FAIL" "Issues: $($zoneIssues -join '; ')"
    }
}

$nsValues = @(Resolve-Answers $Domain "NS" | ForEach-Object { Get-RecordValue $_ "NS" } | Sort-Object -Unique)
$googleNs = @($nsValues | Where-Object { $_ -like "ns-cloud-d*.googledomains.com" })
$cloudflareNs = @($nsValues | Where-Object { $_ -like "*.ns.cloudflare.com" })
if ($googleNs.Count -eq 4) {
    Add-Check "Public nameservers" "OK" "Still on Squarespace/Google nameservers; no production cutover has happened"
} elseif ($cloudflareNs.Count -ge 2) {
    Add-Check "Public nameservers" "WARN" "Cloudflare nameservers appear active already: $($cloudflareNs -join ', ')"
} else {
    Add-Check "Public nameservers" "WARN" "Current nameservers: $($nsValues -join ', ')"
}

$mxValues = @(Resolve-Answers $Domain "MX" | ForEach-Object { "{0}:{1}" -f $_.Preference, (Get-RecordValue $_ "MX") } | Sort-Object)
$txtValues = @(Resolve-Answers $Domain "TXT" | ForEach-Object { Get-RecordValue $_ "TXT" })
$mailIssues = New-Object System.Collections.Generic.List[string]
foreach ($requiredMx in @("10:mxa.mailgun.org", "10:mxb.mailgun.org")) {
    if ($requiredMx -notin $mxValues) {
        $mailIssues.Add("missing public MX $requiredMx")
    }
}
foreach ($requiredTxt in @("MS=ms48673064", "v=spf1 include:mailgun.org ~all")) {
    if ($requiredTxt -notin $txtValues) {
        $mailIssues.Add("missing public TXT $requiredTxt")
    }
}
$dkimValues = @(Resolve-Answers "pic._domainkey.$Domain" "TXT" | ForEach-Object { Get-RecordValue $_ "TXT" })
if ($expectedPreserveRecords[4].Value -notin $dkimValues) {
    $mailIssues.Add("missing public DKIM TXT pic._domainkey.$Domain")
}
foreach ($requiredCname in @(
    @{ Name = "cbsw2pw4sdud.$Domain"; Value = "gv-6xwzpofnvqguxs.dv.googlehosted.com" },
    @{ Name = "4jb3ni34htue.$Domain"; Value = "gv-xvljhthdwk5dxh.dv.googlehosted.com" },
    @{ Name = "334xc4sml6cf.$Domain"; Value = "gv-ujhethalu73pqt.dv.googlehosted.com" }
)) {
    $cnameValues = @(Resolve-Answers $requiredCname.Name "CNAME" | ForEach-Object { Get-RecordValue $_ "CNAME" })
    if ($requiredCname.Value -notin $cnameValues) {
        $mailIssues.Add("missing public Google verification CNAME $($requiredCname.Name)")
    }
}
if ($mailIssues.Count -eq 0) {
    Add-Check "Current public preserve DNS" "OK" "Required mail, DKIM, and verification records are visible before cutover"
} else {
    Add-Check "Current public preserve DNS" "FAIL" ($mailIssues -join "; ")
}

$wrangler = Get-WranglerInvocation
if ($null -eq $wrangler) {
    Add-Check "Cloudflare auth" "WARN" "Wrangler is not available; dashboard setup can still proceed manually"
} else {
    $whoamiOutput = (& $wrangler.Command @($wrangler.PrefixArgs) whoami 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $whoamiOutput -notmatch "not authenticated") {
        $cloudflareToken = Get-WranglerOAuthToken
        Add-Check "Cloudflare auth" "OK" "$($wrangler.Label) is authenticated"
    } else {
        Add-Check "Cloudflare auth" "WARN" "Wrangler is not authenticated; dashboard setup can still proceed manually"
    }

    $pagesOutput = (& $wrangler.Command @($wrangler.PrefixArgs) pages project list 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $pagesOutput -match [regex]::Escape($PagesProject)) {
        Add-Check "Cloudflare Pages project" "OK" "$PagesProject exists"
    } elseif ($LASTEXITCODE -eq 0) {
        Add-Check "Cloudflare Pages project" "FAIL" "$PagesProject was not found in Cloudflare Pages"
    } else {
        Add-Check "Cloudflare Pages project" "WARN" "Could not list Pages projects"
    }

    $r2Output = (& $wrangler.Command @($wrangler.PrefixArgs) r2 bucket list 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $r2Output -match [regex]::Escape($Bucket)) {
        Add-Check "R2 bucket" "OK" "$Bucket exists"
    } elseif ($LASTEXITCODE -eq 0) {
        Add-Check "R2 bucket" "FAIL" "$Bucket was not found in R2"
    } else {
        Add-Check "R2 bucket" "WARN" "Could not list R2 buckets"
    }
}

if ($cloudflareToken) {
    try {
        $zoneResponse = Invoke-CloudflareGet -Token $cloudflareToken -Path "zones?name=$Domain&account.id=$AccountId"
        $zone = @($zoneResponse.result | Where-Object { $_.name -eq $Domain } | Select-Object -First 1)
        if ($zone.Count -eq 0) {
            Add-Check "Cloudflare zone" "WARN" "$Domain has not been added to Cloudflare DNS"
        } else {
            $cloudflareZoneStatus = [string]$zone[0].status
            $assignedNameservers = @($zone[0].name_servers | ForEach-Object { [string]$_ })
            if ($cloudflareZoneStatus -eq "active") {
                Add-Check "Cloudflare zone" "OK" "$Domain is active in Cloudflare with nameservers $($assignedNameservers -join ', ')"
            } else {
                Add-Check "Cloudflare zone" "OK" "$Domain is in Cloudflare with status $cloudflareZoneStatus; assigned nameservers are $($assignedNameservers -join ', ')"
            }
        }
    } catch {
        Add-Check "Cloudflare zone" "WARN" "Could not inspect Cloudflare zone metadata: $($_.Exception.Message)"
    }

    try {
        $pagesDomainsResponse = Invoke-CloudflareGet -Token $cloudflareToken -Path "accounts/$AccountId/pages/projects/$PagesProject/domains"
        $pagesDomains = @($pagesDomainsResponse.result | Where-Object { $_.name -in @($Domain, "www.$Domain") })
        $expectedPagesDomains = @($Domain, "www.$Domain")
        $missingPagesDomains = @($expectedPagesDomains | Where-Object { $_ -notin @($pagesDomains.name) })
        if ($missingPagesDomains.Count -eq 0 -and $pagesDomains.Count -gt 0) {
            $domainDetails = @($pagesDomains | Sort-Object name | ForEach-Object { "$($_.name):$($_.status)" })
            Add-Check "Pages custom domains" "OK" "Apex and www are attached: $($domainDetails -join ', ')"
        } else {
            Add-Check "Pages custom domains" "WARN" "Missing Pages custom domain(s): $($missingPagesDomains -join ', ')"
        }
    } catch {
        Add-Check "Pages custom domains" "WARN" "Could not inspect Pages custom domains: $($_.Exception.Message)"
    }
}

if ($cloudflareZoneStatus -eq "pending" -and $assignedNameservers.Count -gt 0) {
    Add-Check "Next dashboard step" "INFO" "In Cloudflare DNS for $Domain, verify/import the preserve records, remove old TheChurchCo web targets if present, then set Squarespace nameservers to $($assignedNameservers -join ', '). R2 audio is served through the Pages /media route."
} else {
    Add-Check "Next dashboard step" "INFO" "Add $Domain at https://dash.cloudflare.com/$AccountId/domains, import the preserve records, then configure Pages custom domains. Do not update Squarespace nameservers until records are verified."
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) Cloudflare DNS import readiness check(s) failed."
}

$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) Cloudflare DNS import readiness warning(s) remain."
}
