param(
    [string]$Domain = "fillmorechristian.org",
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$Bucket = "fillmore-christian-sermons",
    [string]$MediaHostname = "media.fillmorechristian.org",
    [switch]$VerifyAllPublicMedia,
    [switch]$SkipPublicVerify,
    [switch]$RequireActive
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Get-WranglerOAuthToken {
    $configPath = Join-Path $env:APPDATA "xdg.config\.wrangler\config\default.toml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Wrangler OAuth config was not found. Run npx wrangler login first."
    }

    $configText = Get-Content -Raw -LiteralPath $configPath
    $match = [regex]::Match($configText, '(?m)^oauth_token\s*=\s*"([^"]+)"')
    if (-not $match.Success) {
        throw "Wrangler OAuth token was not found. Run npx wrangler login first."
    }

    return $match.Groups[1].Value
}

function Invoke-CloudflareApi {
    param(
        [ValidateSet("GET", "POST", "PUT")]
        [string]$Method,
        [string]$Path,
        [string]$Token,
        [object]$Body = $null
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $uri = "https://api.cloudflare.com/client/v4/" + $Path.TrimStart("/")
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Headers $headers -Uri $uri
    }

    $headers["Content-Type"] = "application/json"
    return Invoke-RestMethod -Method $Method -Headers $headers -Uri $uri -Body ($Body | ConvertTo-Json -Depth 6)
}

function Assert-PersonalGitHubRemote {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    if ($originUrl -match "wake-byte") {
        throw "Refusing to configure Cloudflare media from the work GitHub owner: $originUrl"
    }
    if ($originUrl -notmatch "github\.com[:/]wakefieldhare-collab/fillmorechristian-website(\.git)?$") {
        throw "Unexpected origin remote. Expected wakefieldhare-collab/fillmorechristian-website, found: $originUrl"
    }
}

function Format-CloudflareError {
    param([object]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($response) {
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            $body = $reader.ReadToEnd()
            if ($body) {
                return $body
            }
        } catch {
            return $ErrorRecord.Exception.Message
        }
    }

    if ($ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }

    return $ErrorRecord.Exception.Message
}

Assert-PersonalGitHubRemote

if ($SkipPublicVerify -and $VerifyAllPublicMedia) {
    throw "SkipPublicVerify cannot be combined with VerifyAllPublicMedia."
}

$token = Get-WranglerOAuthToken

$zoneResponse = Invoke-CloudflareApi -Method GET -Token $token -Path "zones?name=$Domain&account.id=$AccountId"
$zone = @($zoneResponse.result | Where-Object { $_.name -eq $Domain } | Select-Object -First 1)
if ($zone.Count -eq 0) {
    throw "$Domain is not present in Cloudflare DNS. Add it before configuring $MediaHostname."
}

$zoneId = [string]$zone[0].id
$zoneStatus = [string]$zone[0].status
$zoneNameservers = @($zone[0].name_servers | ForEach-Object { [string]$_ })
if ($zoneStatus -ne "active") {
    $message = "$Domain is in Cloudflare with status $zoneStatus. Set Squarespace nameservers to $($zoneNameservers -join ', ') and wait for Cloudflare to mark the zone active before configuring $MediaHostname."
    if ($RequireActive) {
        throw $message
    }
    Write-Warning $message
    return
}

$listResponse = Invoke-CloudflareApi -Method GET -Token $token -Path "accounts/$AccountId/r2/buckets/$Bucket/domains/custom"
$existing = @($listResponse.result.domains | Where-Object { $_.domain -eq $MediaHostname } | Select-Object -First 1)

if ($existing.Count -eq 0) {
    try {
        $createResponse = Invoke-CloudflareApi -Method POST -Token $token -Path "accounts/$AccountId/r2/buckets/$Bucket/domains/custom" -Body @{
            domain = $MediaHostname
            enabled = $true
            zoneId = $zoneId
        }
        $domainResult = $createResponse.result
        Write-Host "Attached $MediaHostname to R2 bucket $Bucket."
    } catch {
        throw "Could not attach $MediaHostname to R2 bucket $Bucket`: $(Format-CloudflareError $_)"
    }
} else {
    $domainResult = $existing[0]
    Write-Host "$MediaHostname is already attached to R2 bucket $Bucket."
}

$getResponse = Invoke-CloudflareApi -Method GET -Token $token -Path "accounts/$AccountId/r2/buckets/$Bucket/domains/custom/$MediaHostname"
$domainResult = $getResponse.result
$ownershipStatus = [string]$domainResult.status.ownership
$sslStatus = [string]$domainResult.status.ssl
$enabled = [bool]$domainResult.enabled

Write-Host "$MediaHostname R2 status: enabled=$enabled; ownership=$ownershipStatus; ssl=$sslStatus."
if (-not $enabled) {
    throw "$MediaHostname is attached but not enabled for public R2 access."
}

if ($ownershipStatus -ne "active" -or $sslStatus -ne "active") {
    Write-Warning "$MediaHostname is attached, but ownership/SSL is not fully active yet. Re-run this command after Cloudflare finishes provisioning."
    return
}

if (-not $SkipPublicVerify) {
    $verifyArgs = @("-TimeoutSec", "20")
    if ($VerifyAllPublicMedia) {
        $verifyArgs += "-All"
    } else {
        $verifyArgs += @("-SampleCount", "5")
    }
    & (Join-Path $PSScriptRoot "test-r2-public-audio.ps1") @verifyArgs
}

Write-Host "$MediaHostname is ready for podcast feed enclosure URLs."
