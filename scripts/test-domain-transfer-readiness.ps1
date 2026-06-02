param(
    [string]$Domain = "fillmorechristian.org",
    [string]$ProductionBaseUrl = "https://www.fillmorechristian.org",
    [string]$ApexBaseUrl = "https://fillmorechristian.org",
    [string]$ExpectedFeedUrl = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast",
    [string[]]$ExpectedCloudflareNameservers = @(),
    [datetime]$RenewalDate = "2026-06-15",
    [datetime]$DisableAutoRenewDeadline = "2026-06-14",
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"

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

    try {
        return Invoke-WebRequest -UseBasicParsing -Uri $Url -MaximumRedirection 5 -TimeoutSec $TimeoutSec
    } catch {
        Add-Check "HTTP: $Url" "FAIL" $_.Exception.Message
        return $null
    }
}

$today = (Get-Date).Date
$daysUntilDeadline = [int]($DisableAutoRenewDeadline.Date - $today).TotalDays
$daysUntilRenewal = [int]($RenewalDate.Date - $today).TotalDays
if ($daysUntilDeadline -lt 0) {
    Add-Check "Squarespace renewal deadline" "FAIL" "Auto-renew disable deadline $($DisableAutoRenewDeadline.ToString('yyyy-MM-dd')) has passed; verify renewal/transfer state in Squarespace immediately"
} elseif ($daysUntilDeadline -le 7) {
    Add-Check "Squarespace renewal deadline" "WARN" "$daysUntilDeadline day(s) until auto-renew should be disabled only if Cloudflare transfer is underway or complete; renewal is $($RenewalDate.ToString('yyyy-MM-dd'))"
} else {
    Add-Check "Squarespace renewal deadline" "OK" "$daysUntilDeadline day(s) until the $($DisableAutoRenewDeadline.ToString('yyyy-MM-dd')) auto-renew decision deadline; renewal is in $daysUntilRenewal day(s)"
}

$nsValues = @(Resolve-Answers $Domain "NS" | ForEach-Object { Get-RecordValue $_ "NS" } | Sort-Object -Unique)
$normalizedNs = @($nsValues | ForEach-Object { $_.TrimEnd(".").ToLowerInvariant() })
if ($ExpectedCloudflareNameservers.Count -gt 0) {
    $expectedNs = @($ExpectedCloudflareNameservers | ForEach-Object { $_.TrimEnd(".").ToLowerInvariant() })
    $missingNs = @($expectedNs | Where-Object { $_ -notin $normalizedNs })
    if ($missingNs.Count -eq 0) {
        Add-Check "Cloudflare DNS active" "OK" "Expected Cloudflare nameservers are active"
    } else {
        Add-Check "Cloudflare DNS active" "FAIL" "Missing expected nameservers: $($missingNs -join ', '); current: $($nsValues -join ', ')"
    }
} else {
    $cloudflareNs = @($normalizedNs | Where-Object { $_ -like "*.ns.cloudflare.com" })
    if ($cloudflareNs.Count -ge 2) {
        Add-Check "Cloudflare DNS active" "OK" "Cloudflare nameservers are active: $($nsValues -join ', ')"
    } else {
        Add-Check "Cloudflare DNS active" "FAIL" "Cloudflare nameservers are not active. Current: $($nsValues -join ', ')"
    }
}

$googleNs = @($normalizedNs | Where-Object { $_ -like "ns-cloud-d*.googledomains.com" })
if ($googleNs.Count -eq 0) {
    Add-Check "Squarespace DNS retired" "OK" "Domain no longer uses the old Google/Squarespace nameservers"
} else {
    Add-Check "Squarespace DNS retired" "FAIL" "Domain still uses Google/Squarespace nameservers: $($nsValues -join ', ')"
}

$mxValues = @(Resolve-Answers $Domain "MX" | ForEach-Object { "{0}:{1}" -f $_.Preference, (Get-RecordValue $_ "MX") } | Sort-Object)
$requiredMx = @("10:mxa.mailgun.org", "10:mxb.mailgun.org")
$missingMx = @($requiredMx | Where-Object { $_ -notin $mxValues })
if ($missingMx.Count -eq 0) {
    Add-Check "Mail MX preserved" "OK" "Mailgun MX records are present"
} else {
    Add-Check "Mail MX preserved" "FAIL" "Missing MX: $($missingMx -join ', '); current: $($mxValues -join ', ')"
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

$apexA = @(Resolve-Answers $Domain "A" | ForEach-Object { Get-RecordValue $_ "A" } | Sort-Object -Unique)
$wwwCname = @(Resolve-Answers "www.$Domain" "CNAME" | ForEach-Object { Get-RecordValue $_ "CNAME" } | Sort-Object -Unique)
if ("77.83.141.16" -notin $apexA -and "ssl.thechurchco.com" -notin $wwwCname) {
    Add-Check "Old website DNS removed" "OK" "Apex and www no longer point at TheChurchCo-era records"
} else {
    Add-Check "Old website DNS removed" "FAIL" "Current apex A: $($apexA -join ', '); current www CNAME: $($wwwCname -join ', ')"
}

$homeResponse = Invoke-Http -Url $ProductionBaseUrl
if ($homeResponse) {
    if ($homeResponse.StatusCode -eq 200 -and
        $homeResponse.Content -match "Fillmore Christian Church" -and
        $homeResponse.Content -match "site\.webmanifest" -and
        $homeResponse.Content -match "favicon\.svg" -and
        $homeResponse.Content -notmatch "ssl\.thechurchco\.com") {
        Add-Check "Production website" "OK" "$ProductionBaseUrl serves the static site shell"
    } else {
        Add-Check "Production website" "FAIL" "$ProductionBaseUrl did not look like the independent static site"
    }
}

$apexHomeResponse = Invoke-Http -Url $ApexBaseUrl
if ($apexHomeResponse) {
    if ($apexHomeResponse.StatusCode -eq 200 -and
        $apexHomeResponse.Content -match "Fillmore Christian Church" -and
        $apexHomeResponse.Content -match "site\.webmanifest" -and
        $apexHomeResponse.Content -match "favicon\.svg" -and
        $apexHomeResponse.Content -notmatch "ssl\.thechurchco\.com") {
        Add-Check "Apex production website" "OK" "$ApexBaseUrl serves or redirects to the independent static site shell"
    } else {
        Add-Check "Apex production website" "FAIL" "$ApexBaseUrl did not look like the independent static site"
    }
}

$feedResponse = Invoke-Http -Url $ExpectedFeedUrl
if ($feedResponse) {
    try {
        [xml]$feedXml = $feedResponse.Content
        $items = @($feedXml.rss.channel.item)
        $enclosures = @($items | Where-Object { $_.enclosure -and $_.enclosure.url })
        if ($items.Count -ge 70 -and $enclosures.Count -ge 70) {
            Add-Check "Production podcast feed" "OK" "$($items.Count) items, $($enclosures.Count) enclosures"
        } else {
            Add-Check "Production podcast feed" "FAIL" "$($items.Count) items, $($enclosures.Count) enclosures"
        }
    } catch {
        Add-Check "Production podcast feed" "FAIL" "Could not parse RSS from $ExpectedFeedUrl`: $($_.Exception.Message)"
    }
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) domain transfer readiness check(s) failed. Do not disable Squarespace auto-renew or rely on Cloudflare Registrar transfer yet."
}

$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) domain transfer readiness warning(s) remain."
}

Write-Host "Domain transfer readiness passed. Start/continue the Cloudflare Registrar transfer in Cloudflare and keep Squarespace auto-renew enabled until the transfer is visibly underway or complete."

exit 0
