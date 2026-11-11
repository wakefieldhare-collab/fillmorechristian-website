param(
    [string]$ProjectName = "fillmorechristian-website",
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$Branch = "main",
    [string]$BuildOutputDir = "dist",
    [switch]$DryRun,
    [switch]$SkipPreflight,
    [switch]$AllowDirty,
    [switch]$AllowUnpushed
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

# Windows PowerShell turns native stderr into terminating errors under
# ErrorActionPreference Stop when output is captured with 2>&1. npx and
# wrangler write ordinary warnings to stderr (for example the first-run
# "will be installed" notice), so judge native commands by exit code only.
function Invoke-NativeCapture {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $Command @Arguments 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }

    return [pscustomobject]@{
        Output = $output
        ExitCode = $exitCode
    }
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

$commitHash = (& git -C $root rev-parse HEAD).Trim()
$commitMessage = (& git -C $root log -1 --pretty=%s).Trim()
if (-not $AllowUnpushed) {
    $remoteHead = (& git -C $root ls-remote origin "refs/heads/$Branch" 2>$null | ForEach-Object { ($_ -split "\s+")[0] } | Select-Object -First 1)
    if (-not $remoteHead) {
        throw "Could not verify origin/$Branch. Push the personal repo branch first, or rerun with -AllowUnpushed for a deliberate local-only deployment."
    }
    if ($remoteHead -ne $commitHash) {
        throw "HEAD $commitHash is not pushed to origin/$Branch ($remoteHead). Push to wakefieldhare-collab first, or rerun with -AllowUnpushed for a deliberate local-only deployment."
    }
}

if (-not $DryRun) {
    $authOutput = & (Join-Path $PSScriptRoot "test-cloudflare-pages-deploy-auth.ps1") -AccountId $AccountId -ProjectName $ProjectName 2>&1
    $authOutput | ForEach-Object { Write-Host $_ }
    $authText = $authOutput | Out-String
    if ($authText -match "AuthMode:\s+WranglerOAuth") {
        [Environment]::SetEnvironmentVariable("CLOUDFLARE_API_TOKEN", $null, "Process")
        [Environment]::SetEnvironmentVariable("CF_API_TOKEN", $null, "Process")
        Remove-Item Env:\CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\CF_API_TOKEN -ErrorAction SilentlyContinue
        Write-Host "Using Wrangler OAuth for deploy; cleared CLOUDFLARE_API_TOKEN and CF_API_TOKEN for this process."
    }
}

if (-not $SkipPreflight) {
    Push-Location $root
    try {
        & npm run build
        if ($LASTEXITCODE -ne 0) {
            throw "npm run build failed."
        }

        # The readiness owner guard requires the active gh account to be
        # wakefieldhare-collab. The machine's global gh account may be a
        # different profile that must not be switched, so supply the church
        # account's token to this check only and clear it afterward.
        $setChurchGitHubToken = $false
        if (-not $env:GH_TOKEN) {
            $tokenResult = Invoke-NativeCapture -Command "gh" -Arguments @("auth", "token", "--hostname", "github.com", "--user", "wakefieldhare-collab")
            $churchToken = ($tokenResult.Output -join "").Trim()
            if ($tokenResult.ExitCode -eq 0 -and $churchToken) {
                $env:GH_TOKEN = $churchToken
                $setChurchGitHubToken = $true
            } else {
                Write-Warning "The wakefieldhare-collab GitHub account is not signed in to gh; the owner guard will check the global gh account instead."
            }
            Remove-Variable tokenResult, churchToken -ErrorAction SilentlyContinue
        }
        try {
            & (Join-Path $PSScriptRoot "test-migration-readiness.ps1") -SkipRemote
        } finally {
            if ($setChurchGitHubToken) {
                Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
            }
        }

        & (Join-Path $PSScriptRoot "test-cloudflare-pages-local.ps1") -BuildOutputDir $BuildOutputDir
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $buildOutputPath)) {
    throw "Build output not found: $buildOutputPath"
}

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

$whoami = Invoke-NativeCapture -Command $wrangler.Command -Arguments (@($wrangler.PrefixArgs) + @("whoami"))
if ($whoami.ExitCode -ne 0 -or ($whoami.Output -join "`n") -match "not authenticated") {
    throw "Cloudflare is not authenticated. Set CLOUDFLARE_API_TOKEN/CF_API_TOKEN with Account:Cloudflare Pages Edit access, or run `npx wrangler login`."
}

Invoke-Wrangler -Wrangler $wrangler -Arguments $deployArgs
Write-Host "Cloudflare Pages deployment requested for $ProjectName from $commitHash."
