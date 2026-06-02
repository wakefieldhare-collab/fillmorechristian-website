param(
    [string]$Domain = "fillmorechristian.org",
    [string]$ProductionBaseUrl = "https://www.fillmorechristian.org",
    [string]$ApexBaseUrl = "https://fillmorechristian.org",
    [string[]]$ExpectedCloudflareNameservers = @("eric.ns.cloudflare.com", "sky.ns.cloudflare.com"),
    [switch]$WaitForDns,
    [int]$MaxAttempts = 30,
    [int]$DelaySeconds = 60,
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"

$verifyScript = Join-Path $PSScriptRoot "verify-production-cutover.ps1"
$parameters = @{
    Domain = $Domain
    ProductionBaseUrl = $ProductionBaseUrl
    ApexBaseUrl = $ApexBaseUrl
    PodcastMediaSampleCount = 5
    TimeoutSec = $TimeoutSec
    VerifyAllPodcastMedia = $true
}

if ($ExpectedCloudflareNameservers.Count -gt 0) {
    $parameters.ExpectedCloudflareNameservers = $ExpectedCloudflareNameservers
}

if ($WaitForDns) {
    $parameters.WaitForDns = $true
    $parameters.MaxAttempts = $MaxAttempts
    $parameters.DelaySeconds = $DelaySeconds
}

& $verifyScript @parameters
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Post-cancellation verification passed."
Write-Host "The independent Cloudflare Pages site, owned podcast feed, and R2-backed audio route are serving production traffic without TheChurchCo dependencies."
Write-Host "Keep Squarespace auto-renew enabled until Cloudflare Registrar shows the transfer in progress or complete."
