param(
    [string]$Domain = "fillmorechristian.org",
    [string]$ProductionBaseUrl = "https://www.fillmorechristian.org",
    [string[]]$ExpectedCloudflareNameservers = @("eric.ns.cloudflare.com", "sky.ns.cloudflare.com"),
    [switch]$WaitForDns,
    [int]$MaxAttempts = 30,
    [int]$DelaySeconds = 60
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Assert-PersonalGitHubRemote {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    if ($originUrl -match "wake-byte") {
        throw "Refusing cutover from the work GitHub owner: $originUrl"
    }
    if ($originUrl -notmatch "github\.com[:/]wakefieldhare-collab/fillmorechristian-website(\.git)?$") {
        throw "Unexpected origin remote. Expected wakefieldhare-collab/fillmorechristian-website, found: $originUrl"
    }
}

function Assert-CleanWorkingTree {
    $dirtyFiles = @(& git -C $root status --porcelain)
    if ($dirtyFiles.Count -gt 0) {
        throw "Working tree is dirty. Commit or stash changes before completing cutover."
    }
}

function Test-CloudflareNameservers {
    try {
        $nsValues = @(
            Resolve-DnsName -Name $Domain -Type NS -ErrorAction Stop |
                Where-Object { $_.NameHost } |
                ForEach-Object { $_.NameHost.TrimEnd(".").ToLowerInvariant() } |
                Sort-Object -Unique
        )
    } catch {
        Write-Warning "Could not resolve NS records for $Domain`: $($_.Exception.Message)"
        return $false
    }

    $expected = @($ExpectedCloudflareNameservers | ForEach-Object { $_.TrimEnd(".").ToLowerInvariant() })
    $missing = @($expected | Where-Object { $_ -notin $nsValues })
    if ($missing.Count -eq 0) {
        Write-Host "$Domain is using expected Cloudflare nameservers: $($nsValues -join ', ')"
        return $true
    }

    Write-Warning "$Domain nameservers are not ready. Current: $($nsValues -join ', '); missing: $($missing -join ', ')"
    return $false
}

if ($MaxAttempts -lt 1) {
    throw "MaxAttempts must be at least 1."
}
if ($DelaySeconds -lt 1) {
    throw "DelaySeconds must be at least 1."
}

Assert-PersonalGitHubRemote
Assert-CleanWorkingTree

$dnsReady = $false
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "DNS cutover check attempt $attempt of $MaxAttempts..."
    $dnsReady = Test-CloudflareNameservers
    if ($dnsReady) {
        break
    }

    if (-not $WaitForDns) {
        break
    }
    if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Seconds $DelaySeconds
    }
}

if (-not $dnsReady) {
    throw "Cloudflare nameservers are not active yet. Set Squarespace nameservers to $($ExpectedCloudflareNameservers -join ', ') and rerun this command."
}

$normalizedProductionBaseUrl = $ProductionBaseUrl.TrimEnd("/")
$productionMediaBaseUrl = "$normalizedProductionBaseUrl/media"

& (Join-Path $PSScriptRoot "test-dns-cutover.ps1") -Mode After -ExpectedCloudflareNameservers $ExpectedCloudflareNameservers
& (Join-Path $PSScriptRoot "test-r2-public-audio.ps1") -BaseUrlOverride $productionMediaBaseUrl -All
& (Join-Path $PSScriptRoot "test-migration-readiness.ps1") -RequireIndependentAudio -VerifyPodcastMedia -StagingBaseUrl $normalizedProductionBaseUrl

Write-Host "Cloudflare cutover checks passed. The static site, podcast feed, and R2-backed /media audio are ready for production cancellation checks."
Write-Host "Before canceling TheChurchCo, run: npm run verify:cancel-thechurchco"
