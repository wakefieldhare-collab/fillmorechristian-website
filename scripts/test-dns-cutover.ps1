param(
    [ValidateSet("Before", "After")]
    [string]$Mode = "Before",
    [string]$Domain = "fillmorechristian.org",
    [string[]]$ExpectedCloudflareNameservers = @(),
    [string]$ExpectedFeedUrl = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast"
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

$nsValues = @(Resolve-Answers $Domain "NS" | ForEach-Object { Get-RecordValue $_ "NS" } | Sort-Object -Unique)
if ($Mode -eq "Before") {
    $googleNs = @($nsValues | Where-Object { $_ -like "ns-cloud-d*.googledomains.com" })
    if ($googleNs.Count -eq 4) {
        Add-Check "Current nameservers" "OK" "Domain still uses Google/Squarespace nameservers"
    } else {
        Add-Check "Current nameservers" "WARN" "Current nameservers: $($nsValues -join ', ')"
    }
} elseif ($ExpectedCloudflareNameservers.Count -gt 0) {
    $missingNs = @($ExpectedCloudflareNameservers | ForEach-Object { $_.TrimEnd(".").ToLowerInvariant() } | Where-Object { $_ -notin @($nsValues | ForEach-Object { $_.ToLowerInvariant() }) })
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

$mxAnswers = @(Resolve-Answers $Domain "MX")
$mxValues = @($mxAnswers | ForEach-Object { "{0}:{1}" -f $_.Preference, (Get-RecordValue $_ "MX") } | Sort-Object)
$requiredMx = @("10:mxa.mailgun.org", "10:mxb.mailgun.org")
$missingMx = @($requiredMx | Where-Object { $_ -notin $mxValues })
if ($missingMx.Count -eq 0) {
    Add-Check "Mailgun MX records" "OK" "Mailgun MX records are present"
} else {
    Add-Check "Mailgun MX records" "FAIL" "Missing MX: $($missingMx -join ', '); current: $($mxValues -join ', ')"
}

$txtValues = @(Resolve-Answers $Domain "TXT" | ForEach-Object { Get-RecordValue $_ "TXT" })
if ("v=spf1 include:mailgun.org ~all" -in $txtValues) {
    Add-Check "Mailgun SPF TXT" "OK" "SPF record is present"
} else {
    Add-Check "Mailgun SPF TXT" "FAIL" "SPF record is missing. Current TXT: $($txtValues -join '; ')"
}

if ("MS=ms48673064" -in $txtValues) {
    Add-Check "Microsoft verification TXT" "OK" "Microsoft verification record is present"
} else {
    Add-Check "Microsoft verification TXT" "WARN" "Microsoft verification TXT was not found. Current TXT: $($txtValues -join '; ')"
}

$dkimValues = @(Resolve-Answers "pic._domainkey.$Domain" "TXT" | ForEach-Object { Get-RecordValue $_ "TXT" })
$expectedDkim = "k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDDMspMJXAZ/D2ygNZBnGbLY5Z9DjNaNiLDjKY79O1JYgtYlkOERm5SVNOb1nKavNA98hqTLLN+1N7LQGoaeqY0O8ddDa8NclV57cTekdu4by/fcKN+8zycaOE2HRH9hZP1RLNmandRuUQfmTYMrXIWrjBU0xaQdbXZHMP0pN5FuQIDAQAB"
if ($expectedDkim -in $dkimValues) {
    Add-Check "Mailgun DKIM TXT" "OK" "pic._domainkey DKIM record is present"
} else {
    Add-Check "Mailgun DKIM TXT" "FAIL" "pic._domainkey DKIM record is missing"
}

$googleVerificationRecords = @(
    @{ Name = "cbsw2pw4sdud.$Domain"; Value = "gv-6xwzpofnvqguxs.dv.googlehosted.com" },
    @{ Name = "4jb3ni34htue.$Domain"; Value = "gv-xvljhthdwk5dxh.dv.googlehosted.com" },
    @{ Name = "334xc4sml6cf.$Domain"; Value = "gv-ujhethalu73pqt.dv.googlehosted.com" }
)
$missingGoogle = New-Object System.Collections.Generic.List[string]
foreach ($record in $googleVerificationRecords) {
    $values = @(Resolve-Answers $record.Name "CNAME" | ForEach-Object { Get-RecordValue $_ "CNAME" })
    if ($record.Value -notin $values) {
        $missingGoogle.Add("$($record.Name) -> $($record.Value)")
    }
}
if ($missingGoogle.Count -eq 0) {
    Add-Check "Google verification CNAMEs" "OK" "Google verification CNAMEs are present"
} else {
    Add-Check "Google verification CNAMEs" "FAIL" "Missing: $($missingGoogle -join '; ')"
}

$apexA = @(Resolve-Answers $Domain "A" | ForEach-Object { Get-RecordValue $_ "A" } | Sort-Object -Unique)
$wwwCname = @(Resolve-Answers "www.$Domain" "CNAME" | ForEach-Object { Get-RecordValue $_ "CNAME" } | Sort-Object -Unique)
if ($Mode -eq "Before") {
    if ("77.83.141.16" -in $apexA) {
        Add-Check "Current apex website record" "OK" "Apex still points at the existing TheChurchCo-era IP"
    } else {
        Add-Check "Current apex website record" "WARN" "Apex A records: $($apexA -join ', ')"
    }

    if ("ssl.thechurchco.com" -in $wwwCname) {
        Add-Check "Current www website record" "OK" "www still points at TheChurchCo"
    } else {
        Add-Check "Current www website record" "WARN" "www CNAME records: $($wwwCname -join ', ')"
    }
} else {
    if ("77.83.141.16" -notin $apexA) {
        Add-Check "Apex no longer on old website IP" "OK" "Apex A records: $($apexA -join ', ')"
    } else {
        Add-Check "Apex no longer on old website IP" "FAIL" "Apex still points at 77.83.141.16"
    }

    if ("ssl.thechurchco.com" -notin $wwwCname) {
        Add-Check "www no longer on TheChurchCo" "OK" "www CNAME records: $($wwwCname -join ', ')"
    } else {
        Add-Check "www no longer on TheChurchCo" "FAIL" "www still points at ssl.thechurchco.com"
    }

    try {
        $site = Invoke-WebRequest -UseBasicParsing -Uri "https://www.$Domain/" -MaximumRedirection 5
        if ($site.StatusCode -eq 200 -and $site.Content -match "Fillmore Christian") {
            Add-Check "Production website" "OK" "https://www.$Domain/ returns the static site"
        } else {
            Add-Check "Production website" "FAIL" "https://www.$Domain/ returned HTTP $($site.StatusCode) but did not look like the static site"
        }
    } catch {
        Add-Check "Production website" "FAIL" $_.Exception.Message
    }

    try {
        $feed = Invoke-WebRequest -UseBasicParsing -Uri $ExpectedFeedUrl -MaximumRedirection 5
        if ($feed.StatusCode -eq 200 -and $feed.Content -match "<rss" -and $feed.Content -match "Fillmore Christian") {
            Add-Check "Production podcast feed" "OK" "$ExpectedFeedUrl returns RSS"
        } else {
            Add-Check "Production podcast feed" "FAIL" "$ExpectedFeedUrl returned HTTP $($feed.StatusCode) but did not look like RSS"
        }
    } catch {
        Add-Check "Production podcast feed" "FAIL" $_.Exception.Message
    }
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) DNS cutover check(s) failed."
}

$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) DNS cutover warning(s) remain."
}
