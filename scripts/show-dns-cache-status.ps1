param(
    [string]$Domain = "fillmorechristian.org",
    [string[]]$ExpectedCloudflareNameservers = @("eric.ns.cloudflare.com", "sky.ns.cloudflare.com"),
    [string]$OldApexAddress = "77.83.141.16",
    [string]$OldWwwCname = "ssl.thechurchco.com",
    [switch]$WriteReport,
    [switch]$FailOnStale
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$reportDir = Join-Path $root "exports\cutover"

$resolvers = @(
    [pscustomobject]@{ Name = "Cloudflare public"; Server = "1.1.1.1"; Kind = "Recursive" },
    [pscustomobject]@{ Name = "Google public"; Server = "8.8.8.8"; Kind = "Recursive" },
    [pscustomobject]@{ Name = "Quad9 public"; Server = "9.9.9.9"; Kind = "Recursive" },
    [pscustomobject]@{ Name = "OpenDNS public"; Server = "208.67.222.222"; Kind = "Recursive" },
    [pscustomobject]@{ Name = "Cloudflare Eric"; Server = "eric.ns.cloudflare.com"; Kind = "Authoritative" },
    [pscustomobject]@{ Name = "Cloudflare Sky"; Server = "sky.ns.cloudflare.com"; Kind = "Authoritative" }
)

function Normalize-DnsValue {
    param([string]$Value)
    return ($Value.Trim().TrimEnd(".")).ToLowerInvariant()
}

function Format-Ttl {
    param([int[]]$Ttls)
    $valid = @($Ttls | Where-Object { $_ -gt 0 })
    if ($valid.Count -eq 0) { return "" }
    return ([int]($valid | Measure-Object -Maximum).Maximum).ToString()
}

function Get-DnsAnswer {
    param(
        [string]$Server,
        [string]$Name,
        [ValidateSet("A", "CNAME", "NS")]
        [string]$Type
    )

    try {
        $answers = @(Resolve-DnsName -Name $Name -Type $Type -Server $Server -ErrorAction Stop)
        $values = New-Object System.Collections.Generic.List[string]
        $ttls = New-Object System.Collections.Generic.List[int]

        foreach ($answer in $answers) {
            if ($answer.Section -ne "Answer") { continue }

            if ($Type -eq "A" -and $answer.IPAddress) {
                $values.Add([string]$answer.IPAddress)
            } elseif ($Type -eq "CNAME" -and $answer.NameHost) {
                $values.Add([string]$answer.NameHost)
            } elseif ($Type -eq "NS" -and $answer.NameHost) {
                $values.Add([string]$answer.NameHost)
            }

            if ($answer.TTL) {
                $ttls.Add([int]$answer.TTL)
            }
        }

        return [pscustomobject]@{
            Values = @($values.ToArray())
            Ttls = @($ttls.ToArray())
            Error = ""
        }
    } catch {
        return [pscustomobject]@{
            Values = @()
            Ttls = @()
            Error = $_.Exception.Message
        }
    }
}

function New-StatusRow {
    param(
        [object]$Resolver,
        [string]$Record,
        [object]$Answer,
        [string]$Status,
        [string]$Details
    )

    return [pscustomobject]@{
        Resolver = $Resolver.Name
        Server = $Resolver.Server
        Kind = $Resolver.Kind
        Record = $Record
        Status = $Status
        Ttl = Format-Ttl $Answer.Ttls
        Values = if ($Answer.Values.Count -gt 0) { ($Answer.Values -join ", ") } else { "" }
        Details = $Details
    }
}

$rows = New-Object System.Collections.Generic.List[object]
$staleRows = New-Object System.Collections.Generic.List[object]
$expectedNs = @($ExpectedCloudflareNameservers | ForEach-Object { Normalize-DnsValue $_ })
$oldCname = Normalize-DnsValue $OldWwwCname

foreach ($resolver in $resolvers) {
    $apexA = Get-DnsAnswer -Server $resolver.Server -Name $Domain -Type A
    $apexNs = Get-DnsAnswer -Server $resolver.Server -Name $Domain -Type NS
    $wwwCname = Get-DnsAnswer -Server $resolver.Server -Name "www.$Domain" -Type CNAME
    $wwwA = Get-DnsAnswer -Server $resolver.Server -Name "www.$Domain" -Type A

    $apexAValues = @($apexA.Values | ForEach-Object { Normalize-DnsValue $_ })
    $apexNsValues = @($apexNs.Values | ForEach-Object { Normalize-DnsValue $_ })
    $wwwCnameValues = @($wwwCname.Values | ForEach-Object { Normalize-DnsValue $_ })
    $wwwAValues = @($wwwA.Values | ForEach-Object { Normalize-DnsValue $_ })

    $missingNs = @($expectedNs | Where-Object { $_ -notin $apexNsValues })
    $oldAVisible = (Normalize-DnsValue $OldApexAddress) -in $apexAValues
    $oldCnameVisible = $oldCname -in $wwwCnameValues

    $apexStatus = if ($apexA.Error) { "ERROR" } elseif ($oldAVisible) { "STALE" } elseif ($apexAValues.Count -gt 0) { "OK" } else { "WARN" }
    $apexDetails = if ($oldAVisible) { "Old TheChurchCo apex A is still cached" } elseif ($apexA.Error) { $apexA.Error } else { "Apex A does not include old website IP" }
    $row = New-StatusRow -Resolver $resolver -Record "$Domain A" -Answer $apexA -Status $apexStatus -Details $apexDetails
    $rows.Add($row)
    if ($apexStatus -eq "STALE") { $staleRows.Add($row) }

    $nsStatus = if ($apexNs.Error) { "ERROR" } elseif ($missingNs.Count -gt 0) { "STALE" } else { "OK" }
    $nsDetails = if ($missingNs.Count -gt 0) { "Missing expected NS: $($missingNs -join ', ')" } elseif ($apexNs.Error) { $apexNs.Error } else { "Expected Cloudflare nameservers visible" }
    $row = New-StatusRow -Resolver $resolver -Record "$Domain NS" -Answer $apexNs -Status $nsStatus -Details $nsDetails
    $rows.Add($row)
    if ($nsStatus -eq "STALE") { $staleRows.Add($row) }

    $cnameStatus = if ($wwwCname.Error) { "ERROR" } elseif ($oldCnameVisible) { "STALE" } elseif ($wwwCnameValues.Count -gt 0) { "OK" } else { "OK" }
    $cnameDetails = if ($oldCnameVisible) { "Old TheChurchCo www CNAME is still cached" } elseif ($wwwCname.Error) { $wwwCname.Error } else { "www CNAME does not include old website target" }
    $row = New-StatusRow -Resolver $resolver -Record "www.$Domain CNAME" -Answer $wwwCname -Status $cnameStatus -Details $cnameDetails
    $rows.Add($row)
    if ($cnameStatus -eq "STALE") { $staleRows.Add($row) }

    $wwwAStatus = if ($wwwA.Error) { "ERROR" } elseif ($oldAVisible -and $wwwAValues.Count -eq 0) { "WARN" } elseif ($wwwAValues.Count -gt 0) { "OK" } else { "WARN" }
    $wwwADetails = if ($wwwA.Error) { $wwwA.Error } elseif ($wwwAValues.Count -gt 0) { "www resolves to edge addresses" } else { "No www A answer" }
    $rows.Add((New-StatusRow -Resolver $resolver -Record "www.$Domain A" -Answer $wwwA -Status $wwwAStatus -Details $wwwADetails))
}

$generatedAt = Get-Date
$maxStaleTtl = 0
if ($staleRows.Count -gt 0) {
    $maxStaleTtl = [int](@($staleRows | Where-Object { $_.Ttl } | ForEach-Object { [int]$_.Ttl } | Measure-Object -Maximum).Maximum)
}
$estimatedClearAt = if ($maxStaleTtl -gt 0) { $generatedAt.AddSeconds($maxStaleTtl) } else { $null }

Write-Host "Fillmore Christian DNS cache status"
Write-Host "Generated: $($generatedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Write-Host ""
$rows | Format-Table Resolver, Kind, Record, Status, Ttl, Values -AutoSize

if ($staleRows.Count -gt 0) {
    Write-Warning "$($staleRows.Count) stale DNS answer(s) remain. Longest observed stale TTL: $maxStaleTtl second(s), estimated clear by $($estimatedClearAt.ToString('yyyy-MM-dd HH:mm:ss zzz')). Do not cancel TheChurchCo yet."
} else {
    Write-Host "No stale old TheChurchCo/Squarespace DNS answers were observed across configured resolvers."
}

if ($WriteReport) {
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $stamp = $generatedAt.ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $jsonPath = Join-Path $reportDir "$Domain-dns-cache-status-$stamp.json"
    $markdownPath = Join-Path $reportDir "$Domain-dns-cache-status-$stamp.md"

    [ordered]@{
        generatedAt = $generatedAt.ToUniversalTime().ToString("o")
        domain = $Domain
        expectedCloudflareNameservers = $ExpectedCloudflareNameservers
        oldApexAddress = $OldApexAddress
        oldWwwCname = $OldWwwCname
        staleAnswerCount = $staleRows.Count
        maxStaleTtlSeconds = $maxStaleTtl
        estimatedClearAt = if ($estimatedClearAt) { $estimatedClearAt.ToUniversalTime().ToString("o") } else { $null }
        rows = @($rows.ToArray())
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $jsonPath

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# DNS Cache Status for $Domain")
    $lines.Add("")
    $lines.Add("- Generated: $($generatedAt.ToUniversalTime().ToString("o"))")
    $lines.Add("- Stale answer count: $($staleRows.Count)")
    $lines.Add("- Longest observed stale TTL: $maxStaleTtl second(s)")
    if ($estimatedClearAt) {
        $lines.Add("- Estimated stale-cache clear time: $($estimatedClearAt.ToString("yyyy-MM-dd HH:mm:ss zzz"))")
    }
    $lines.Add("")
    $lines.Add("| Resolver | Kind | Record | Status | TTL | Values |")
    $lines.Add("| --- | --- | --- | --- | ---: | --- |")
    foreach ($row in $rows) {
        $values = ($row.Values -replace "\|", "\|")
        $lines.Add("| $($row.Resolver) | $($row.Kind) | $($row.Record) | $($row.Status) | $($row.Ttl) | $values |")
    }
    $lines | Set-Content -Encoding UTF8 -LiteralPath $markdownPath

    Write-Host ""
    Write-Host "DNS cache status report written:"
    Write-Host "  $markdownPath"
    Write-Host "  $jsonPath"
}

if ($FailOnStale -and $staleRows.Count -gt 0) {
    throw "$($staleRows.Count) stale DNS answer(s) remain. Longest observed stale TTL: $maxStaleTtl second(s)."
}
