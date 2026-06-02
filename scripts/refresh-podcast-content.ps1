param(
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Assert-PersonalGitHubRemote {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    if ($originUrl -match "wake-byte") {
        throw "Refusing podcast content refresh from the work GitHub owner: $originUrl"
    }
    if ($originUrl -notmatch "github\.com[:/]wakefieldhare-collab/fillmorechristian-website(\.git)?$") {
        throw "Unexpected origin remote. Expected wakefieldhare-collab/fillmorechristian-website, found: $originUrl"
    }
}

function Invoke-Step {
    param(
        [string]$Label,
        [scriptblock]$Script
    )

    Write-Host ""
    Write-Host "==> $Label"
    & $Script
}

Assert-PersonalGitHubRemote

Invoke-Step "Normalize podcast metadata" {
    & (Join-Path $PSScriptRoot "normalize-podcast-metadata.ps1")
}

Invoke-Step "Update podcast durations" {
    & (Join-Path $PSScriptRoot "update-podcast-durations.ps1")
}

Invoke-Step "Render static episode pages" {
    & (Join-Path $PSScriptRoot "render-static-episodes.ps1")
}

Invoke-Step "Render sermon archive" {
    & (Join-Path $PSScriptRoot "render-static-sermons.ps1")
}

Invoke-Step "Render homepage latest sermon" {
    & (Join-Path $PSScriptRoot "render-homepage-latest-sermon.ps1")
}

Invoke-Step "Render podcast latest messages" {
    & (Join-Path $PSScriptRoot "render-podcast-latest.ps1")
}

if (-not $SkipBuild) {
    Invoke-Step "Build publish output" {
        Push-Location $root
        try {
            npm run build
        } finally {
            Pop-Location
        }
    }
}

Write-Host ""
Write-Host "Podcast content refresh complete. Review changes, then run scripts\test-migration-readiness.ps1 -RequireIndependentAudio before deploying."
