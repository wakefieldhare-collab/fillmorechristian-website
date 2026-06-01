param(
    [string]$Domain = "fillmorechristian.org",
    [string]$SnapshotPath = "",
    [string]$OutDir = "exports\dns",
    [string]$PagesProject = "fillmorechristian-website"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputDir = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $root $OutDir }
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

if (-not $SnapshotPath) {
    $snapshot = Get-ChildItem -LiteralPath $outputDir -Filter "$Domain-*-records.csv" |
        Where-Object { $_.Name -match "^$([regex]::Escape($Domain))-\d{8}-\d{6}-records\.csv$" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $snapshot) {
        throw "No DNS snapshot found in $outputDir. Run scripts\export-dns-snapshot.ps1 first."
    }
    $SnapshotPath = $snapshot.FullName
} elseif (-not [System.IO.Path]::IsPathRooted($SnapshotPath)) {
    $SnapshotPath = Join-Path $root $SnapshotPath
}

if (-not (Test-Path -LiteralPath $SnapshotPath)) {
    throw "DNS snapshot not found: $SnapshotPath"
}

$records = @(Import-Csv -LiteralPath $SnapshotPath)
if ($records.Count -eq 0) {
    throw "DNS snapshot contains no records: $SnapshotPath"
}

function ConvertTo-RelativeName {
    param([string]$Name)

    $trimmed = $Name.TrimEnd(".")
    if ($trimmed -eq $Domain) { return "@" }
    if ($trimmed.EndsWith(".$Domain")) {
        return $trimmed.Substring(0, $trimmed.Length - $Domain.Length - 1)
    }
    return $trimmed
}

function Format-ZoneValue {
    param(
        [string]$Type,
        [string]$Value
    )

    if ($Type -eq "TXT") {
        $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
        return '"' + $escaped + '"'
    }

    if ($Type -in @("CNAME", "MX", "NS") -and -not $Value.EndsWith(".")) {
        return "$Value."
    }

    return $Value
}

$oldWebsiteRecords = @(
    $records | Where-Object {
        ($_.Name -eq $Domain -and $_.Type -in @("A", "AAAA")) -or
        ($_.Name -eq "www.$Domain" -and $_.Type -eq "CNAME")
    } | Sort-Object Name, Type, Value
)

if ($oldWebsiteRecords.Count -eq 0) {
    throw "DNS snapshot has no old website records to exclude. Use a full export from scripts\export-dns-snapshot.ps1, not the Cloudflare preserve CSV."
}

$preserveRecords = @(
    $records | Where-Object {
        $_.Type -ne "NS" -and
        -not (($_.Name -eq $Domain -and $_.Type -in @("A", "AAAA")) -or
              ($_.Name -eq "www.$Domain" -and $_.Type -eq "CNAME"))
    } | Sort-Object Name, Type, Priority, Value -Unique
)

$preserveCsvPath = Join-Path $outputDir "$Domain-cloudflare-preserve-records.csv"
$zonePath = Join-Path $outputDir "$Domain-cloudflare-preserve-records.zone"
$planPath = Join-Path $outputDir "$Domain-cloudflare-dns-cutover-plan.md"

$preserveRecords | Export-Csv -LiteralPath $preserveCsvPath -NoTypeInformation -Encoding UTF8

$zoneLines = New-Object System.Collections.Generic.List[string]
$zoneLines.Add("`$ORIGIN $Domain.")
$zoneLines.Add("`$TTL 300")
foreach ($record in $preserveRecords) {
    $name = ConvertTo-RelativeName $record.Name
    $ttl = if ($record.TTL -and [int]$record.TTL -gt 0) { [int]$record.TTL } else { 300 }
    if ($record.Type -eq "MX") {
        $zoneLines.Add(("{0} {1} IN MX {2} {3}" -f $name, $ttl, $record.Priority, (Format-ZoneValue $record.Type $record.Value)))
    } else {
        $zoneLines.Add(("{0} {1} IN {2} {3}" -f $name, $ttl, $record.Type, (Format-ZoneValue $record.Type $record.Value)))
    }
}
$zoneLines -join "`r`n" | Set-Content -LiteralPath $zonePath -Encoding UTF8

$mailRecords = @($preserveRecords | Where-Object { $_.Type -in @("MX", "TXT") })
$notes = New-Object System.Collections.Generic.List[string]
$notes.Add("# Cloudflare DNS Cutover Plan for $Domain")
$notes.Add("")
$notes.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$notes.Add("")
$notes.Add(('Source snapshot: `{0}`' -f $SnapshotPath))
$notes.Add("")
$notes.Add("## Import/Preserve Before Nameserver Change")
$notes.Add("")
$notes.Add("Import or manually create the records in:")
$notes.Add("")
$notes.Add(('- `{0}`' -f $preserveCsvPath))
$notes.Add(('- `{0}`' -f $zonePath))
$notes.Add("")
$notes.Add("These records intentionally exclude the old TheChurchCo website records. They preserve mail and verification records only.")
$notes.Add("")
foreach ($record in $mailRecords) {
    if ($record.Type -eq "MX") {
        $notes.Add(('- MX `{0}` priority `{1}` -> `{2}`' -f $record.Name, $record.Priority, $record.Value))
    } else {
        $notes.Add(('- TXT `{0}` -> `{1}`' -f $record.Name, $record.Value))
    }
}
$notes.Add("")
$notes.Add("## Replace During Cloudflare Pages Setup")
$notes.Add("")
$notes.Add("Do not recreate these old website records in Cloudflare:")
$notes.Add("")
foreach ($record in $oldWebsiteRecords) {
    $priorityText = if ($record.Priority) { " priority $($record.Priority)" } else { "" }
    $notes.Add(('- {0} `{1}`{2} -> `{3}`' -f $record.Type, $record.Name, $priorityText, $record.Value))
}
$notes.Add("")
$notes.Add("Instead, let Cloudflare Pages add or verify custom domains for:")
$notes.Add("")
$notes.Add(('- `www.{0}`' -f $Domain))
$notes.Add(('- `{0}`' -f $Domain))
$notes.Add("")
$notes.Add(('Expected Pages project name: `{0}`' -f $PagesProject))
$notes.Add("")
$notes.Add("## Verify")
$notes.Add("")
$notes.Add("Before nameserver change:")
$notes.Add("")
$notes.Add('```powershell')
$notes.Add(".\scripts\test-dns-cutover.ps1 -Mode Before")
$notes.Add('```')
$notes.Add("")
$notes.Add("After Cloudflare gives assigned nameservers and Squarespace is updated:")
$notes.Add("")
$notes.Add('```powershell')
$notes.Add('.\scripts\test-dns-cutover.ps1 -Mode After -ExpectedCloudflareNameservers "name1.ns.cloudflare.com","name2.ns.cloudflare.com"')
$notes.Add('```')
$notes.Add("")
$notes.Add("Only cancel TheChurchCo after website, feed, media, and mail checks pass.")

$notes -join "`r`n" | Set-Content -LiteralPath $planPath -Encoding UTF8

Write-Host "Wrote Cloudflare DNS preserve CSV: $preserveCsvPath"
Write-Host "Wrote Cloudflare DNS preserve zone: $zonePath"
Write-Host "Wrote Cloudflare DNS cutover plan: $planPath"
