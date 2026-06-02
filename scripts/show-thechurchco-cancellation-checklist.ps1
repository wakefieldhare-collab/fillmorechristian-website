param(
    [string]$Domain = "fillmorechristian.org",
    [string]$ProductionBaseUrl = "https://www.fillmorechristian.org",
    [string]$ApexBaseUrl = "https://fillmorechristian.org",
    [datetime]$RenewalDate = "2026-06-15",
    [datetime]$DisableAutoRenewDeadline = "2026-06-14"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$now = Get-Date
$cutoverDir = Join-Path $root "exports\cutover"

function Get-LatestJsonReport {
    param([string]$Pattern)

    if (-not (Test-Path -LiteralPath $cutoverDir)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $cutoverDir -Filter $Pattern |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-StepStatusMap {
    param([object]$Report)

    $steps = @{}
    foreach ($step in @($Report.Steps)) {
        if ($step.Name) {
            $steps[[string]$step.Name] = [string]$step.Status
        }
    }
    return $steps
}

function Format-Boolean {
    param([bool]$Value)
    if ($Value) { return "yes" }
    return "no"
}

$originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
$gitStatus = @(& git -C $root status --porcelain)
$head = (& git -C $root log -1 --pretty="%h %s").Trim()

$latestProductionFile = Get-LatestJsonReport -Pattern "$Domain-production-cutover-*.json"
$latestDnsCacheFile = Get-LatestJsonReport -Pattern "$Domain-dns-cache-status-*.json"
$productionReport = $null
$dnsCacheReport = $null

if ($latestProductionFile) {
    $productionReport = Get-Content -Raw -LiteralPath $latestProductionFile.FullName | ConvertFrom-Json
}

if ($latestDnsCacheFile) {
    $dnsCacheReport = Get-Content -Raw -LiteralPath $latestDnsCacheFile.FullName | ConvertFrom-Json
}

$stepStatuses = if ($productionReport) { Get-StepStatusMap -Report $productionReport } else { @{} }
$fullMediaPass = $false
$dnsCachePass = $false
$cancellationPass = $false
$overallPass = $false

if ($productionReport) {
    $overallPass = ([string]$productionReport.OverallStatus -eq "PASS")
    $fullMediaPass = ([bool]$productionReport.VerifyAllPodcastMedia)
    $dnsCachePass = ($stepStatuses["Recursive DNS Cache Drainage"] -eq "PASS")
    $cancellationPass = ($stepStatuses["TheChurchCo Cancellation Readiness"] -eq "PASS")
}

$dnsCacheClear = $false
if ($dnsCacheReport) {
    $dnsCacheClear = ([int]$dnsCacheReport.staleAnswerCount -eq 0)
}

$safeToCancel = ($overallPass -and $fullMediaPass -and $dnsCachePass -and $cancellationPass -and $dnsCacheClear)
$daysUntilRenewal = [int][Math]::Ceiling(($RenewalDate.Date - $now.Date).TotalDays)
$daysUntilDeadline = [int][Math]::Ceiling(($DisableAutoRenewDeadline.Date - $now.Date).TotalDays)

Write-Host "Fillmore Christian TheChurchCo cancellation checklist"
Write-Host "Generated: $($now.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Write-Host ""

Write-Host "Current evidence"
Write-Host "- Git origin: $originUrl"
Write-Host "- Git HEAD: $head"
Write-Host "- Working tree: $(if ($gitStatus.Count -eq 0) { 'clean' } else { 'dirty; commit or stash before final verification' })"
Write-Host "- Production site: $ProductionBaseUrl"
Write-Host "- Apex site: $ApexBaseUrl"
Write-Host "- Squarespace renewal: $($RenewalDate.ToString('yyyy-MM-dd')); auto-renew decision deadline: $($DisableAutoRenewDeadline.ToString('yyyy-MM-dd')) ($daysUntilDeadline day(s) left, renewal in $daysUntilRenewal day(s))"

if ($productionReport) {
    Write-Host "- Latest full-media production receipt: $($latestProductionFile.Name)"
    Write-Host "  - Overall status: $($productionReport.OverallStatus)"
    Write-Host "  - Generated at: $($productionReport.GeneratedAt)"
    Write-Host "  - VerifyAllPodcastMedia: $(Format-Boolean -Value $fullMediaPass)"
    Write-Host "  - Recursive DNS Cache Drainage: $(if ($stepStatuses.ContainsKey('Recursive DNS Cache Drainage')) { $stepStatuses['Recursive DNS Cache Drainage'] } else { 'missing' })"
    Write-Host "  - TheChurchCo Cancellation Readiness: $(if ($stepStatuses.ContainsKey('TheChurchCo Cancellation Readiness')) { $stepStatuses['TheChurchCo Cancellation Readiness'] } else { 'missing' })"
} else {
    Write-Host "- Latest full-media production receipt: missing"
}

if ($dnsCacheReport) {
    Write-Host "- Latest DNS cache receipt: $($latestDnsCacheFile.Name); stale answer count: $($dnsCacheReport.staleAnswerCount)"
} else {
    Write-Host "- Latest DNS cache receipt: missing"
}

Write-Host ""
Write-Host "Cancellation readiness"
if ($safeToCancel) {
    Write-Host "- Status: READY to cancel TheChurchCo website/podcast hosting."
    Write-Host "- Basis: latest production receipt passed with all podcast media verified, recursive DNS cache clear, and TheChurchCo cancellation readiness green."
} else {
    Write-Host "- Status: NOT READY from local receipts."
    Write-Host "- Do not cancel TheChurchCo if the latest full-media production receipt is missing, stale, not PASS, not VerifyAllPodcastMedia, or lacks green DNS-cache/cancellation steps."
    Write-Host "- Run: npm run verify:production-cutover -- -WaitForDns -VerifyAllPodcastMedia"
}

Write-Host ""
Write-Host "Before clicking cancel"
Write-Host "1. Preserve the latest production receipt under exports/cutover/."
Write-Host "2. Confirm the command above still reports cancellation-ready if anything has changed."
Write-Host "3. Cancel only TheChurchCo website/podcast hosting."
Write-Host "4. Do not remove Cloudflare Pages, the R2 bucket, the R2 SERMON_AUDIO binding, Mailgun/Microsoft/DKIM/Google DNS records, or Squarespace registrar access."
Write-Host "5. Do not disable Squarespace auto-renew until Cloudflare Registrar shows the transfer in progress or complete."
Write-Host ""

Write-Host "After cancellation"
Write-Host "1. Run: npm run verify:post-cancellation"
Write-Host "2. Confirm the independent Cloudflare Pages site, owned podcast feed, and R2-backed /media audio route still pass."
Write-Host "3. Keep the new receipt with the migration records."
Write-Host ""

Write-Host "Separate registrar handoff"
Write-Host "- The Cloudflare Registrar transfer still needs the Squarespace transfer authorization code sent to church@fillmorechristian.org."
Write-Host "- Run: npm run cutover:registrar-checklist"

if (-not $safeToCancel) {
    exit 1
}
