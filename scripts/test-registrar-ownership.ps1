param(
    [string]$Domain = "fillmorechristian.org",
    [string]$ExpectedRegistrarNamePattern = "Cloudflare Registrar",
    [string[]]$ExpectedNameservers = @("eric.ns.cloudflare.com", "sky.ns.cloudflare.com"),
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [ValidateSet("OK", "WARN", "FAIL")]
        [string]$Status,
        [string]$Check,
        [string]$Details
    )

    $checks.Add([pscustomobject]@{
        Status = $Status
        Check = $Check
        Details = $Details
    })
}

function Get-VcardFullName {
    param([object]$Entity)

    if (-not $Entity.vcardArray -or $Entity.vcardArray.Count -lt 2) {
        return ""
    }

    foreach ($entry in @($Entity.vcardArray[1])) {
        if ($entry.Count -ge 4 -and [string]$entry[0] -eq "fn") {
            return [string]$entry[3]
        }
    }

    return ""
}

$rdapUrl = "https://rdap.org/domain/$Domain"
try {
    $rdap = Invoke-RestMethod -Uri $rdapUrl -TimeoutSec $TimeoutSec
} catch {
    throw "Could not read RDAP registration data for $Domain from $rdapUrl`: $($_.Exception.Message)"
}

$registrarEntities = @($rdap.entities | Where-Object { "registrar" -in @($_.roles) })
$registrarNames = @($registrarEntities | ForEach-Object { Get-VcardFullName -Entity $_ } | Where-Object { $_ } | Select-Object -Unique)
$registrarIds = @($registrarEntities | ForEach-Object {
    foreach ($publicId in @($_.publicIds)) {
        if ([string]$publicId.type -match "IANA Registrar ID") {
            [string]$publicId.identifier
        }
    }
} | Where-Object { $_ } | Select-Object -Unique)

$nameservers = @($rdap.nameservers | ForEach-Object {
    if ($_.ldhName) {
        [string]$_.ldhName.ToLowerInvariant().TrimEnd(".")
    }
} | Sort-Object -Unique)

$expirationEvent = @($rdap.events | Where-Object { $_.eventAction -eq "expiration" } | Select-Object -First 1)
$lastChangedEvent = @($rdap.events | Where-Object { $_.eventAction -eq "last changed" } | Select-Object -First 1)
$rdapUpdatedEvent = @($rdap.events | Where-Object { $_.eventAction -eq "last update of RDAP database" } | Select-Object -First 1)

if ($registrarNames.Count -gt 0 -and (($registrarNames -join "; ") -match $ExpectedRegistrarNamePattern)) {
    Add-Check "OK" "Registrar ownership" "RDAP registrar is $($registrarNames -join '; ')."
} elseif ($registrarNames.Count -gt 0) {
    Add-Check "FAIL" "Registrar ownership" "RDAP registrar is $($registrarNames -join '; '), expected a match for '$ExpectedRegistrarNamePattern'."
} else {
    Add-Check "FAIL" "Registrar ownership" "RDAP did not expose a registrar name."
}

if ($registrarIds.Count -gt 0) {
    Add-Check "OK" "Registrar public ID" "IANA registrar ID(s): $($registrarIds -join ', ')."
} else {
    Add-Check "WARN" "Registrar public ID" "RDAP did not expose an IANA registrar ID."
}

$missingNameservers = @($ExpectedNameservers | ForEach-Object { $_.ToLowerInvariant().TrimEnd(".") } | Where-Object { $_ -notin $nameservers })
if ($missingNameservers.Count -eq 0) {
    Add-Check "OK" "RDAP nameservers" "RDAP nameservers include expected Cloudflare nameservers: $($ExpectedNameservers -join ', ')."
} else {
    Add-Check "FAIL" "RDAP nameservers" "Missing expected nameserver(s): $($missingNameservers -join ', '); RDAP nameservers: $($nameservers -join ', ')."
}

if ($expirationEvent -and $expirationEvent.eventDate) {
    Add-Check "OK" "Registration expiration" "RDAP expiration event: $($expirationEvent.eventDate)."
} else {
    Add-Check "WARN" "Registration expiration" "RDAP did not expose an expiration event."
}

if ($lastChangedEvent -and $lastChangedEvent.eventDate) {
    Add-Check "OK" "Registration last changed" "RDAP last changed event: $($lastChangedEvent.eventDate)."
} else {
    Add-Check "WARN" "Registration last changed" "RDAP did not expose a last changed event."
}

if ($rdapUpdatedEvent -and $rdapUpdatedEvent.eventDate) {
    Add-Check "OK" "RDAP database update" "RDAP database update event: $($rdapUpdatedEvent.eventDate)."
} else {
    Add-Check "WARN" "RDAP database update" "RDAP did not expose a database-update event."
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) registrar ownership check(s) failed. Keep Squarespace auto-renew enabled until Cloudflare Registrar transfer is visibly underway or complete and RDAP shows Cloudflare as registrar."
}

$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) registrar ownership warning(s) remain."
}

Write-Host "Registrar ownership verification passed. RDAP shows $Domain at the expected registrar and Cloudflare nameservers remain attached."
