param(
    [string]$ProjectName = "fillmorechristian-website",
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$Branch = "main",
    [string]$BuildOutputDir = "dist",
    [switch]$DryRun,
    [switch]$SkipPreflight,
    [switch]$AllowDirty
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$buildOutputPath = Join-Path $root $BuildOutputDir

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

function Invoke-Wrangler {
    param(
        [object]$Wrangler,
        [string[]]$Arguments
    )

    & $Wrangler.Command @($Wrangler.PrefixArgs) @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$($Wrangler.Label) $($Arguments -join ' ') failed."
    }
}

$wrangler = Get-WranglerInvocation

$originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
if ($originUrl -match "wake-byte") {
    throw "Refusing to deploy from the work GitHub owner: $originUrl"
}
if ($originUrl -notmatch "github\.com[:/]wakefieldhare-collab/fillmorechristian-website(\.git)?$") {
    throw "Unexpected origin remote. Expected wakefieldhare-collab/fillmorechristian-website, found: $originUrl"
}

$dirtyFiles = @(& git -C $root status --porcelain)
if ($dirtyFiles.Count -gt 0 -and -not $AllowDirty) {
    throw "Working tree is dirty. Commit or stash changes before deployment, or rerun with -AllowDirty."
}

if (-not $DryRun) {
    $authOutput = & (Join-Path $PSScriptRoot "test-cloudflare-pages-deploy-auth.ps1") -AccountId $AccountId -ProjectName $ProjectName 2>&1
    $authOutput | ForEach-Object { Write-Host $_ }
    if (($authOutput -join "`n") -match "AuthMode:\s+WranglerOAuth") {
        [Environment]::SetEnvironmentVariable("CLOUDFLARE_API_TOKEN", $null, "Process")
        [Environment]::SetEnvironmentVariable("CF_API_TOKEN", $null, "Process")
    }
}

if (-not $SkipPreflight) {
    Push-Location $root
    try {
        & npm run build
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed."
        }

        & (Join-Path $PSScriptRoot "test-migration-readiness.ps1") -SkipRemote
        & (Join-Path $PSScriptRoot "test-cloudflare-pages-local.ps1") -BuildOutputDir $BuildOutputDir
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $buildOutputPath)) {
    throw "Build output not found: $buildOutputPath"
}

$commitHash = (& git -C $root rev-parse HEAD).Trim()
$commitMessage = (& git -C $root log -1 --pretty=%s).Trim()
$deployArgs = @(
    "pages",
    "deploy",
    $buildOutputPath,
    "--project-name",
    $ProjectName,
    "--branch",
    $Branch,
    "--commit-hash",
    $commitHash,
    "--commit-message",
    $commitMessage
)

if ($AllowDirty -and $dirtyFiles.Count -gt 0) {
    $deployArgs += "--commit-dirty=true"
}

if ($DryRun) {
    Write-Host "Dry run: preflight passed. Would run:"
    Write-Host "$($wrangler.Label) $($deployArgs -join ' ')"
    return
}

$whoamiOutput = & $wrangler.Command @($wrangler.PrefixArgs) whoami 2>&1
if ($LASTEXITCODE -ne 0 -or ($whoamiOutput -join "`n") -match "not authenticated") {
    throw "Cloudflare is not authenticated. Set CLOUDFLARE_API_TOKEN/CF_API_TOKEN with Account:Cloudflare Pages Edit access, or run `npx wrangler login`."
}

Invoke-Wrangler -Wrangler $wrangler -Arguments $deployArgs
Write-Host "Cloudflare Pages deployment requested for $ProjectName from $commitHash."
