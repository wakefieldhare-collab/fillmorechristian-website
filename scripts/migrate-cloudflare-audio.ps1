param(
    [string]$Bucket = "fillmore-christian-sermons",
    [string]$BaseAudioUrl = "https://media.fillmorechristian.org",
    [switch]$CreateBucket,
    [switch]$SkipUpload,
    [switch]$SkipR2Verify,
    [switch]$VerifyPublicMedia,
    [switch]$VerifyAllPublicMedia,
    [switch]$SkipPublicMediaVerify,
    [int]$PodcastMediaSampleCount = 5,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifestPath = "exports\thechurchco-podcast\r2-audio-manifest.csv"

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

function Assert-PersonalGitHubRemote {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    if ($originUrl -match "wake-byte") {
        throw "Refusing to migrate from the work GitHub owner: $originUrl"
    }
    if ($originUrl -notmatch "github\.com[:/]wakefieldhare-collab/fillmorechristian-website(\.git)?$") {
        throw "Unexpected origin remote. Expected wakefieldhare-collab/fillmorechristian-website, found: $originUrl"
    }
}

function Assert-CleanWorkingTree {
    $dirtyFiles = @(& git -C $root status --porcelain)
    if ($dirtyFiles.Count -gt 0) {
        throw "Working tree is dirty. Commit or stash changes before running the real audio migration."
    }
}

function Assert-BaseAudioUrl {
    try {
        $uri = [Uri]$BaseAudioUrl
    } catch {
        throw "BaseAudioUrl must be an absolute HTTPS URL. Found: $BaseAudioUrl"
    }

    if ($uri.Scheme -ne "https") {
        throw "BaseAudioUrl must use HTTPS. Found: $BaseAudioUrl"
    }
    if ($uri.Host -match "thechurchco|churchco") {
        throw "BaseAudioUrl must not point at TheChurchCo. Found: $BaseAudioUrl"
    }
}

function Assert-CloudflareAuth {
    param([object]$Wrangler)

    $whoamiOutput = & $Wrangler.Command @($Wrangler.PrefixArgs) whoami 2>&1
    if ($LASTEXITCODE -ne 0 -or ($whoamiOutput -join "`n") -match "not authenticated") {
        throw "Cloudflare is not authenticated. Run `npx wrangler login` first."
    }
}

Assert-PersonalGitHubRemote
Assert-BaseAudioUrl

if ($PodcastMediaSampleCount -lt 1) {
    throw "PodcastMediaSampleCount must be at least 1."
}

$verifyPublicMediaBeforeRewrite = -not $SkipPublicMediaVerify
if ($VerifyPublicMedia) {
    $verifyPublicMediaBeforeRewrite = $true
}
if ($SkipPublicMediaVerify -and ($VerifyPublicMedia -or $VerifyAllPublicMedia)) {
    throw "SkipPublicMediaVerify cannot be combined with VerifyPublicMedia or VerifyAllPublicMedia."
}

if ($DryRun) {
    $tempManifestPath = Join-Path ([System.IO.Path]::GetTempPath()) ("fcc-r2-audio-manifest-" + [guid]::NewGuid().ToString("N") + ".csv")
    try {
        & (Join-Path $PSScriptRoot "build-r2-audio-manifest.ps1") -BaseAudioUrl $BaseAudioUrl -OutputPath $tempManifestPath
        & (Join-Path $PSScriptRoot "upload-podcast-audio-to-r2.ps1") -Bucket $Bucket -ManifestPath $tempManifestPath -DryRun
        & (Join-Path $PSScriptRoot "test-r2-audio-upload.ps1") -Bucket $Bucket -ManifestPath $tempManifestPath -All -DryRun

        Write-Host "Dry run: would rewrite podcast enclosure URLs to $BaseAudioUrl."
        Write-Host "Dry run: would regenerate episode pages, sermon archive, homepage sermon feature, sitemap/build output, and strict readiness checks."
        if ($CreateBucket) {
            Write-Host "Dry run: would create R2 bucket if needed with wrangler r2 bucket create $Bucket."
        }
        if ($verifyPublicMediaBeforeRewrite) {
            $scope = if ($VerifyAllPublicMedia) { "all public podcast media URLs" } else { "$PodcastMediaSampleCount sampled public podcast media URL(s)" }
            Write-Host "Dry run: would verify $scope from the R2 public URL manifest before rewriting the feed."
            Write-Host "Dry run: would verify $scope again from the rewritten podcast feed."
        } else {
            Write-Host "Dry run: would skip public media URL verification because SkipPublicMediaVerify was supplied."
        }
    } finally {
        if (Test-Path -LiteralPath $tempManifestPath) {
            Remove-Item -LiteralPath $tempManifestPath -Force
        }
    }
    return
}

Assert-CleanWorkingTree
$wrangler = Get-WranglerInvocation
Assert-CloudflareAuth -Wrangler $wrangler

if ($CreateBucket) {
    Invoke-Wrangler -Wrangler $wrangler -Arguments @("r2", "bucket", "create", $Bucket)
}

& (Join-Path $PSScriptRoot "build-r2-audio-manifest.ps1") -BaseAudioUrl $BaseAudioUrl -OutputPath $manifestPath

if (-not $SkipUpload) {
    & (Join-Path $PSScriptRoot "upload-podcast-audio-to-r2.ps1") -Bucket $Bucket -ManifestPath $manifestPath
}

if (-not $SkipR2Verify) {
    & (Join-Path $PSScriptRoot "test-r2-audio-upload.ps1") -Bucket $Bucket -ManifestPath $manifestPath -All -VerifyHashes
}

if ($verifyPublicMediaBeforeRewrite) {
    $publicAudioArgs = @("-ManifestPath", $manifestPath, "-TimeoutSec", "20")
    if ($VerifyAllPublicMedia) {
        $publicAudioArgs += "-All"
    } else {
        $publicAudioArgs += @("-SampleCount", "$PodcastMediaSampleCount")
    }
    & (Join-Path $PSScriptRoot "test-r2-public-audio.ps1") @publicAudioArgs
}

& (Join-Path $PSScriptRoot "rewrite-podcast-audio-urls.ps1") -BaseAudioUrl $BaseAudioUrl -R2ManifestPath $manifestPath
& (Join-Path $PSScriptRoot "render-static-episodes.ps1")
& (Join-Path $PSScriptRoot "render-static-sermons.ps1")
& (Join-Path $PSScriptRoot "render-homepage-latest-sermon.ps1")

Push-Location $root
try {
    & npm run build
    if ($LASTEXITCODE -ne 0) {
        throw "npm run build failed."
    }
} finally {
    Pop-Location
}

$readinessArgs = @("-SkipRemote", "-RequireIndependentAudio")
if ($verifyPublicMediaBeforeRewrite) {
    $readinessArgs += "-VerifyPodcastMedia"
    if ($VerifyAllPublicMedia) {
        $readinessArgs += "-VerifyAllPodcastMedia"
    } else {
        $readinessArgs += @("-PodcastMediaSampleCount", "$PodcastMediaSampleCount")
    }
}

& (Join-Path $PSScriptRoot "test-migration-readiness.ps1") @readinessArgs
& (Join-Path $PSScriptRoot "test-cloudflare-pages-local.ps1")

Write-Host "Cloudflare audio migration prepared locally. Public audio URLs were verified before RSS rewrite unless SkipPublicMediaVerify was supplied. Review, commit, push, then run npm run deploy:cloudflare."
