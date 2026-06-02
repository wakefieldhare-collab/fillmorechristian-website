param(
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$ProjectName = "fillmorechristian-website"
)

$ErrorActionPreference = "Stop"

function Get-WranglerInvocation {
    $wranglerCommand = Get-Command wrangler -ErrorAction SilentlyContinue
    if ($wranglerCommand) {
        return [pscustomobject]@{
            Command = $wranglerCommand.Source
            PrefixArgs = @()
            Label = "wrangler"
        }
    }

    $npxCommand = Get-Command npx -ErrorAction SilentlyContinue
    if ($npxCommand) {
        return [pscustomobject]@{
            Command = $npxCommand.Source
            PrefixArgs = @("wrangler")
            Label = "npx wrangler"
        }
    }

    throw "wrangler is not installed or available through npx."
}

function Get-CloudflareToken {
    foreach ($name in @("CLOUDFLARE_API_TOKEN", "CF_API_TOKEN")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{
                Name = $name
                Value = $value
            }
        }
    }

    return $null
}

function Invoke-CloudflareApi {
    param(
        [string]$Token,
        [string]$Path
    )

    $uri = "https://api.cloudflare.com/client/v4/$Path"
    try {
        return Invoke-RestMethod -Uri $uri -Method Get -Headers @{
            Authorization = "Bearer $Token"
        }
    } catch {
        $statusCode = $null
        $bodyText = ""
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $bodyText = $reader.ReadToEnd()
            } catch {}
        }

        $message = $_.Exception.Message
        if ($bodyText) {
            $message = "$message Body: $bodyText"
        }

        $statusSuffix = if ($statusCode) { " (HTTP $statusCode)" } else { "" }
        throw "Cloudflare API request failed for $Path$statusSuffix`: $message"
    }
}

function Test-CloudflareTokenPagesAccess {
    param([object]$TokenInfo)

    $verifyResponse = Invoke-CloudflareApi -Token $TokenInfo.Value -Path "user/tokens/verify"
    if (-not $verifyResponse.success -or $verifyResponse.result.status -ne "active") {
        throw "Cloudflare token from $($TokenInfo.Name) is not active."
    }

    $projectResponse = Invoke-CloudflareApi -Token $TokenInfo.Value -Path "accounts/$AccountId/pages/projects/$ProjectName"
    if (-not $projectResponse.success -or -not $projectResponse.result) {
        throw "Cloudflare token from $($TokenInfo.Name) did not return Pages project $ProjectName."
    }

    Write-Output "AuthMode: EnvToken"
    Write-Output "Cloudflare Pages auth preflight OK: token from $($TokenInfo.Name) is active and can access project $ProjectName in account $AccountId."
}

function Test-WranglerOAuthPagesAccess {
    $wrangler = Get-WranglerInvocation
    $savedCloudflareToken = [Environment]::GetEnvironmentVariable("CLOUDFLARE_API_TOKEN")
    $savedCfToken = [Environment]::GetEnvironmentVariable("CF_API_TOKEN")

    try {
        [Environment]::SetEnvironmentVariable("CLOUDFLARE_API_TOKEN", $null, "Process")
        [Environment]::SetEnvironmentVariable("CF_API_TOKEN", $null, "Process")

        $whoamiOutput = & $wrangler.Command @($wrangler.PrefixArgs) whoami 2>&1
        if ($LASTEXITCODE -ne 0 -or ($whoamiOutput -join "`n") -match "not authenticated") {
            throw "$($wrangler.Label) is not authenticated with a Wrangler OAuth session."
        }

        $projectListOutput = & $wrangler.Command @($wrangler.PrefixArgs) pages project list 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "$($wrangler.Label) could not list Cloudflare Pages projects."
        }

        if (($projectListOutput -join "`n") -notmatch [regex]::Escape($ProjectName)) {
            throw "$($wrangler.Label) is authenticated, but project $ProjectName was not found in account $AccountId."
        }

        Write-Output "AuthMode: WranglerOAuth"
        Write-Output "Cloudflare Pages auth preflight OK: Wrangler OAuth can access project $ProjectName in account $AccountId."
    } finally {
        [Environment]::SetEnvironmentVariable("CLOUDFLARE_API_TOKEN", $savedCloudflareToken, "Process")
        [Environment]::SetEnvironmentVariable("CF_API_TOKEN", $savedCfToken, "Process")
    }
}

$tokenInfo = Get-CloudflareToken
$tokenFailure = ""

if ($tokenInfo) {
    try {
        Test-CloudflareTokenPagesAccess -TokenInfo $tokenInfo
        return
    } catch {
        $tokenFailure = "Env token $($tokenInfo.Name) could not access Pages project $ProjectName`: $($_.Exception.Message)"
    }
}

try {
    Test-WranglerOAuthPagesAccess
    if ($tokenFailure) {
        Write-Warning "$tokenFailure. Using Wrangler OAuth instead; deployment scripts will clear CLOUDFLARE_API_TOKEN/CF_API_TOKEN before invoking Wrangler."
    }
    return
} catch {
    $details = @()
    if ($tokenFailure) { $details += $tokenFailure }
    $details += "Wrangler OAuth could not access Pages project $ProjectName`: $($_.Exception.Message)"
    throw (($details -join " ") + " Set CLOUDFLARE_API_TOKEN or CF_API_TOKEN to a Cloudflare API token with Account:Cloudflare Pages Edit access for account $AccountId, or run npx wrangler login. Token URL: https://dash.cloudflare.com/profile/api-tokens")
}
