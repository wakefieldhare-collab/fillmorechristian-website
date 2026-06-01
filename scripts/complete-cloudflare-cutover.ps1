param(
    [string]$Domain = "fillmorechristian.org",
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

& (Join-Path $PSScriptRoot "test-dns-cutover.ps1") -Mode After -ExpectedCloudflareNameservers $ExpectedCloudflareNameservers
& (Join-Path $PSScriptRoot "configure-r2-media-domain.ps1") -RequireActive -VerifyAllPublicMedia
& (Join-Path $PSScriptRoot "migrate-cloudflare-audio.ps1") -SkipUpload -SkipR2Verify -VerifyAllPublicMedia

Write-Host "Cloudflare cutover has been prepared locally. Review the generated RSS/feed changes, commit them, push, and deploy."
Write-Host "Skipping automatic Cloudflare Pages deploy because the feed rewrite creates local files that must be committed first."
Write-Host "After commit and push, run: npm run deploy:cloudflare"
