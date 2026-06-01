param(
    [string]$Domain = "fillmorechristian.org",
    [string]$OutDir = "exports\dns"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputDir = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$recordsPath = Join-Path $outputDir "$Domain-$timestamp-records.csv"
$notesPath = Join-Path $outputDir "$Domain-$timestamp-notes.md"

function Add-Record {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Name,
        [string]$Type,
        [string]$Value,
        [int]$Ttl = 0,
        [string]$Priority = ""
    )

    if (-not $Value) {
        return
    }

    $Records.Add([pscustomobject]@{
        Name = $Name
        Type = $Type
        Value = $Value
        Priority = $Priority
        TTL = $Ttl
    })
}

function Resolve-Record {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [string]$Name,
        [string]$Type
    )

    try {
        $answers = @(Resolve-DnsName -Name $Name -Type $Type -ErrorAction Stop | Where-Object { $_.Section -eq "Answer" })
    } catch {
        return
    }

    foreach ($answer in $answers) {
        if ($answer.Name -and $answer.Name.TrimEnd(".") -ne $Name.TrimEnd(".")) {
            continue
        }

        switch ($Type) {
            "A" { Add-Record $Records $Name $Type $answer.IPAddress $answer.TTL }
            "AAAA" { Add-Record $Records $Name $Type $answer.IPAddress $answer.TTL }
            "CNAME" { Add-Record $Records $Name $Type $answer.NameHost $answer.TTL }
            "MX" { Add-Record $Records $Name $Type $answer.NameExchange $answer.TTL ([string]$answer.Preference) }
            "NS" { Add-Record $Records $Name $Type $answer.NameHost $answer.TTL }
            "TXT" { Add-Record $Records $Name $Type (($answer.Strings -join "")) $answer.TTL }
            "CAA" { Add-Record $Records $Name $Type $answer.Value $answer.TTL }
        }
    }
}

$records = New-Object System.Collections.Generic.List[object]
$namesToCheck = @(
    $Domain,
    "www.$Domain",
    "_dmarc.$Domain",
    "k1._domainkey.$Domain",
    "email.$Domain",
    "mail.$Domain"
)

foreach ($name in $namesToCheck) {
    Resolve-Record $records $name "CNAME"
    $hasCname = @($records | Where-Object { $_.Name -eq $name -and $_.Type -eq "CNAME" }).Count -gt 0
    if ($hasCname) {
        continue
    }

    $types = if ($name -eq $Domain) {
        @("A", "AAAA", "MX", "TXT", "CAA", "NS")
    } else {
        @("A", "AAAA", "TXT", "CAA")
    }

    foreach ($type in $types) {
        Resolve-Record $records $name $type
    }
}

$deduped = @($records | Sort-Object Name, Type, Priority, Value -Unique)
$deduped | Export-Csv -LiteralPath $recordsPath -NoTypeInformation -Encoding UTF8

$mx = @($deduped | Where-Object { $_.Type -eq "MX" })
$txt = @($deduped | Where-Object { $_.Type -eq "TXT" })
$www = @($deduped | Where-Object { $_.Name -eq "www.$Domain" -and $_.Type -eq "CNAME" })
$apexA = @($deduped | Where-Object { $_.Name -eq $Domain -and $_.Type -eq "A" })
$ns = @($deduped | Where-Object { $_.Name -eq $Domain -and $_.Type -eq "NS" })

$notes = @()
$notes += "# DNS Snapshot for $Domain"
$notes += ""
$notes += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
$notes += ""
$notes += "CSV: $recordsPath"
$notes += ""
$notes += "## Current Nameservers"
$notes += ""
foreach ($record in $ns) {
    $notes += "- $($record.Value)"
}
$notes += ""
$notes += "## Records To Preserve During Cloudflare Cutover"
$notes += ""
$notes += "### Mail"
$notes += ""
foreach ($record in $mx) {
    $notes += "- MX $($record.Name) priority $($record.Priority) -> $($record.Value)"
}
foreach ($record in $txt) {
    if ($record.Name -eq $Domain -or $record.Name -like "*_domainkey*" -or $record.Name -like "_dmarc*") {
        $notes += "- TXT $($record.Name) -> $($record.Value)"
    }
}
$notes += ""
$notes += "### Current Website Records"
$notes += ""
foreach ($record in $apexA) {
    $notes += "- A $($record.Name) -> $($record.Value)"
}
foreach ($record in $www) {
    $notes += "- CNAME $($record.Name) -> $($record.Value)"
}
$notes += ""
$notes += "## Cloudflare Cutover Notes"
$notes += ""
$notes += "- Preserve MX and TXT records before changing nameservers."
$notes += "- Replace the current TheChurchCo website records with Cloudflare Pages custom-domain records when Cloudflare provides them."
$notes += "- Re-run this snapshot immediately before the final nameserver change in case Squarespace DNS has changed."

$notes -join "`r`n" | Set-Content -LiteralPath $notesPath -Encoding UTF8

Write-Host "Wrote DNS records: $recordsPath"
Write-Host "Wrote DNS notes: $notesPath"
