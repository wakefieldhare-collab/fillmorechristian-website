param(
    [Parameter(Mandatory = $true)]
    [string]$ServiceConfigPath,
    [switch]$Publish
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$config = Resolve-Path -LiteralPath $ServiceConfigPath
$expected = Get-Content -Raw -LiteralPath $config | ConvertFrom-Json

if (-not $expected.service_date) {
    throw "The service config does not contain service_date."
}

$originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
if ($originUrl -notmatch "github\.com[:/]wakefieldhare-collab/fillmorechristian-website(\.git)?$") {
    throw "Unexpected website repository origin: $originUrl"
}

$existingTrackedChanges = @(& git -C $root status --porcelain --untracked-files=no)
if ($existingTrackedChanges.Count -gt 0) {
    throw "The website repository has other tracked changes. Finish or set them aside before publishing announcements."
}

Push-Location $root
try {
    $updateArgs = @("scripts/update-announcements.mjs", $config)
    if (-not $Publish) {
        $updateArgs += "--check"
    }
    & node @updateArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Announcement validation or update failed."
    }

    & npm run build
    if ($LASTEXITCODE -ne 0) {
        throw "Website build failed."
    }

    & (Join-Path $PSScriptRoot "test-cloudflare-pages-local.ps1") -BuildOutputDir "dist"
    if ($LASTEXITCODE -ne 0) {
        throw "Local website validation failed."
    }

    if (-not $Publish) {
        Write-Host "Dry run complete. Re-run with -Publish to commit, deploy, and verify the live announcements page."
        return
    }

    & git add -- announcements.json
    $staged = @(& git diff --cached --name-only)
    if ($staged.Count -ne 1 -or $staged[0] -ne "announcements.json") {
        throw "Only announcements.json may be committed by this workflow."
    }

    & git commit -m "Update weekly announcements for $($expected.service_date)"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not commit the weekly announcement update."
    }

    & git push origin main
    if ($LASTEXITCODE -ne 0) {
        throw "Could not push the weekly announcement update."
    }

    & (Join-Path $PSScriptRoot "deploy-cloudflare-pages.ps1") -AllowDirty
    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare Pages deployment failed."
    }

    $verified = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $live = Invoke-RestMethod -Uri "https://www.fillmorechristian.org/announcements.json?v=$cacheBust" -Headers @{ "Cache-Control" = "no-cache" }
            if ($live.service_date -eq $expected.service_date -and $live.announcements.Count -eq $expected.announcements.Count) {
                $page = Invoke-WebRequest -Uri "https://www.fillmorechristian.org/announcements.html?v=$cacheBust" -UseBasicParsing
                if ($page.StatusCode -eq 200 -and $page.Content -match "Weekly Announcements") {
                    $verified = $true
                    break
                }
            }
        } catch {
            # The new deployment may still be propagating.
        }

        Start-Sleep -Seconds 5
    }

    if (-not $verified) {
        throw "The deployment completed, but the live announcement update could not be verified within 50 seconds."
    }

    Write-Host "Published and verified $($expected.announcements.Count) announcements for $($expected.service_date)."
} finally {
    Pop-Location
}
