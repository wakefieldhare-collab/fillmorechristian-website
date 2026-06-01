param(
    [string]$Domain = "fillmorechristian.org",
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$PagesProject = "fillmorechristian-website",
    [string]$Bucket = "fillmore-christian-sermons",
    [string]$MediaHostname = "media.fillmorechristian.org",
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

$preserveCsvFullPath = Resolve-RepoPath $PreserveCsvPath
$preserveZoneFullPath = Resolve-RepoPath $PreserveZonePath

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

    $requiredRecords = @(
        @{ Name = $Domain; Type = "MX"; Value = "mxa.mailgun.org"; Priority = "10" },
        @{ Name = $Domain; Type = "MX"; Value = "mxb.mailgun.org"; Priority = "10" },
        @{ Name = $Domain; Type = "TXT"; Value = "MS=ms48673064"; Priority = "" },
        @{ Name = $Domain; Type = "TXT"; Value = "v=spf1 include:mailgun.org ~all"; Priority = "" }
    )
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($required in $requiredRecords) {
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
        Add-Check "Required mail records" "OK" "Mailgun MX/SPF and Microsoft verification records are present"
    } else {
        Add-Check "Required mail records" "FAIL" "Missing: $($missing -join '; ')"
    }
}

if (-not (Test-Path -LiteralPath $preserveZoneFullPath)) {
    Add-Check "BIND zone import file" "FAIL" "Missing $preserveZoneFullPath"
} else {
    $zoneText = Get-Content -Raw -LiteralPath $preserveZoneFullPath
    $zoneIssues = New-Object System.Collections.Generic.List[string]
    foreach ($needle in @("mxa.mailgun.org.", "mxb.mailgun.org.", '"MS=ms48673064"', '"v=spf1 include:mailgun.org ~all"')) {
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
if ($mailIssues.Count -eq 0) {
    Add-Check "Current public mail DNS" "OK" "Required mail and verification records are visible before cutover"
} else {
    Add-Check "Current public mail DNS" "FAIL" ($mailIssues -join "; ")
}

$wrangler = Get-WranglerInvocation
if ($null -eq $wrangler) {
    Add-Check "Cloudflare auth" "WARN" "Wrangler is not available; dashboard setup can still proceed manually"
} else {
    $whoamiOutput = (& $wrangler.Command @($wrangler.PrefixArgs) whoami 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $whoamiOutput -notmatch "not authenticated") {
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

Add-Check "Next dashboard step" "INFO" "Add $Domain at https://dash.cloudflare.com/$AccountId/domains, import the preserve records, then configure Pages custom domains and $MediaHostname on the R2 bucket. Do not update Squarespace nameservers until records are verified."

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) Cloudflare DNS import readiness check(s) failed."
}

$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) Cloudflare DNS import readiness warning(s) remain."
}
