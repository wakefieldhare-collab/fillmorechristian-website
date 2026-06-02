param(
    [string]$Domain = "fillmorechristian.org",
    [string]$PagesProject = "fillmorechristian-website",
    [string[]]$ExpectedCloudflareNameservers = @("eric.ns.cloudflare.com", "sky.ns.cloudflare.com"),
    [datetime]$RenewalDate = "2026-06-15",
    [datetime]$DisableAutoRenewDeadline = "2026-06-14"
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$now = Get-Date

function Get-DnsValues {
    param(
        [string]$Name,
        [string]$Type
    )

    try {
        return @(Resolve-DnsName $Name $Type -ErrorAction Stop | Where-Object { $_.Type -eq $Type })
    } catch {
        return @()
    }
}

function Test-HttpOk {
    param([string]$Url)

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 20
        return [pscustomobject]@{
            Ok = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300)
            StatusCode = [int]$response.StatusCode
            FinalUrl = $response.BaseResponse.ResponseUri.AbsoluteUri
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        return [pscustomobject]@{
            Ok = $false
            StatusCode = $statusCode
            FinalUrl = $Url
            Error = $_.Exception.Message
        }
    }
}

$originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
$gitStatus = @(& git -C $root status --porcelain)
$head = (& git -C $root log -1 --pretty="%h %s").Trim()

$currentNs = @(Get-DnsValues -Name $Domain -Type "NS" | ForEach-Object { $_.NameHost.ToLowerInvariant().TrimEnd(".") } | Sort-Object)
$currentApexA = @(Get-DnsValues -Name $Domain -Type "A" | ForEach-Object { $_.IPAddress } | Sort-Object)
$currentWwwCname = @(Get-DnsValues -Name "www.$Domain" -Type "CNAME" | ForEach-Object { $_.NameHost.ToLowerInvariant().TrimEnd(".") } | Sort-Object)
$pagesHome = Test-HttpOk -Url "https://$PagesProject.pages.dev/"
$pagesFeed = Test-HttpOk -Url "https://$PagesProject.pages.dev/podcast-category/fillmore-christian/feed/podcast"

$daysUntilRenewal = [int][Math]::Ceiling(($RenewalDate.Date - $now.Date).TotalDays)
$daysUntilDeadline = [int][Math]::Ceiling(($DisableAutoRenewDeadline.Date - $now.Date).TotalDays)

Write-Host "Fillmore Christian Cloudflare Registrar transfer checklist"
Write-Host "Generated: $($now.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Write-Host ""

Write-Host "Current evidence"
Write-Host "- Git origin: $originUrl"
Write-Host "- Git HEAD: $head"
Write-Host "- Working tree: $(if ($gitStatus.Count -eq 0) { 'clean' } else { 'dirty; commit or stash before cutover verification' })"
Write-Host "- Cloudflare Pages home: HTTP $($pagesHome.StatusCode) $($pagesHome.FinalUrl)"
Write-Host "- Cloudflare Pages podcast feed: HTTP $($pagesFeed.StatusCode) $($pagesFeed.FinalUrl)"
Write-Host "- Current public nameservers: $(if ($currentNs.Count -gt 0) { $currentNs -join ', ' } else { 'unresolved' })"
Write-Host "- Current apex A: $(if ($currentApexA.Count -gt 0) { $currentApexA -join ', ' } else { 'unresolved' })"
Write-Host "- Current www CNAME: $(if ($currentWwwCname.Count -gt 0) { $currentWwwCname -join ', ' } else { 'unresolved' })"
Write-Host "- Squarespace renewal: $($RenewalDate.ToString('yyyy-MM-dd')); auto-renew decision deadline: $($DisableAutoRenewDeadline.ToString('yyyy-MM-dd')) ($daysUntilDeadline day(s) left)"
Write-Host ""

Write-Host "Already completed"
Write-Host "- Cloudflare DNS zone is active for $Domain."
Write-Host "- Squarespace nameservers have been changed to Cloudflare: $($ExpectedCloudflareNameservers -join ', ')."
Write-Host "- Squarespace registrar lock has been turned off."
Write-Host "- Squarespace sends the transfer authorization code to the registrant contact: church@fillmorechristian.org."
Write-Host ""

Write-Host "Next Cloudflare Registrar step"
Write-Host "1. In Squarespace Domains for $Domain, click Request transfer code if the latest code is not already available."
Write-Host "2. Check church@fillmorechristian.org for the Squarespace transfer authorization code."
Write-Host "3. Open Cloudflare Dashboard > Domains > Transfers."
Write-Host "4. Confirm $Domain is selected and shows Ready for transfer."
Write-Host "5. Enter the Squarespace transfer authorization code in Step 2."
Write-Host "6. Continue to payment and start the transfer in Cloudflare."
Write-Host ""

Write-Host "Do not change these while the registrar transfer settles"
Write-Host "- Do not disable Squarespace auto-renew yet."
Write-Host "- Do not remove Mailgun/Microsoft/DKIM/Google verification DNS records."
Write-Host "- TheChurchCo website/podcast hosting may be canceled after preserving the final full-media production receipt."
Write-Host ""

Write-Host "Before starting the transfer"
Write-Host "1. Run: npm run verify:cloudflare-pages-auth"
Write-Host "2. Run: npm run verify:r2-pages-audio -- -All"
Write-Host "3. Confirm the latest production receipt passed: npm run verify:production-cutover -- -WaitForDns -VerifyAllPodcastMedia"
Write-Host "4. Keep auto-renew enabled because $Domain is within 30 days of renewal."
Write-Host ""

Write-Host "After starting the registrar transfer"
Write-Host "1. Confirm Cloudflare shows the transfer in progress or complete."
Write-Host "2. Re-run: npm run verify:production-cutover -- -WaitForDns -VerifyAllPodcastMedia"
Write-Host "3. Revoke temporary Cloudflare API tokens after the transfer is underway and the receipt stays green."
