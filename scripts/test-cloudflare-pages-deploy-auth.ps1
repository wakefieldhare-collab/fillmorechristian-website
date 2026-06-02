param(
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$ProjectName = "fillmorechristian-website"
)

$ErrorActionPreference = "Stop"

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

    throw "Set CLOUDFLARE_API_TOKEN or CF_API_TOKEN to a Cloudflare API token with Account:Cloudflare Pages Edit access for account $AccountId. Token URL: https://dash.cloudflare.com/profile/api-tokens"
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

$tokenInfo = Get-CloudflareToken

$verifyResponse = Invoke-CloudflareApi -Token $tokenInfo.Value -Path "user/tokens/verify"
if (-not $verifyResponse.success -or $verifyResponse.result.status -ne "active") {
    throw "Cloudflare token from $($tokenInfo.Name) is not active. Create a replacement token with Account:Cloudflare Pages Edit access for account $AccountId."
}

try {
    $projectResponse = Invoke-CloudflareApi -Token $tokenInfo.Value -Path "accounts/$AccountId/pages/projects/$ProjectName"
} catch {
    throw "Cloudflare token from $($tokenInfo.Name) is active but cannot read Pages project $ProjectName in account $AccountId. Create a token with Account:Cloudflare Pages Edit access scoped to the FCC account, then rerun. Details: $($_.Exception.Message)"
}

if (-not $projectResponse.success -or -not $projectResponse.result) {
    throw "Cloudflare token from $($tokenInfo.Name) did not return Pages project $ProjectName. Create a token with Account:Cloudflare Pages Edit access scoped to the FCC account, then rerun."
}

Write-Host "Cloudflare Pages auth preflight OK: token from $($tokenInfo.Name) is active and can access project $ProjectName in account $AccountId."
