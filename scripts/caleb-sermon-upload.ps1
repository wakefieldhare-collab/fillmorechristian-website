param(
    [switch]$SkipGitPush,
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$bucket = "fillmore-christian-sermons"
$baseAudioUrl = "https://www.fillmorechristian.org/media"
$productionFeedUrl = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast"
$logDir = Join-Path $root "logs"
$logPath = Join-Path $logDir ("caleb-sermon-upload-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function ConvertTo-Slug {
    param([string]$Text)
    $slugText = $Text.ToLowerInvariant()
    $slugText = $slugText -replace "'", ""
    $slugText = $slugText -replace "[^a-z0-9]+", "-"
    $slugText = $slugText.Trim("-")
    if (-not $slugText) {
        throw "Could not create an episode URL slug from title: $Text"
    }
    return $slugText
}

function Get-DefaultTitle {
    param([string]$AudioPath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($AudioPath)
    $name = $name -replace "[-_]+", " "
    $name = $name -replace "\s+", " "
    return $name.Trim()
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = "FCC Sermon Upload",
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}

function Prompt-Input {
    param(
        [string]$Prompt,
        [string]$Title,
        [string]$Default = ""
    )
    return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $Default)
}

function Assert-CleanTree {
    $dirty = @(& git -C $root status --porcelain)
    if ($dirty.Count -gt 0) {
        throw "The website folder has uncommitted changes. Ask Wake or Codex to clean this up before uploading a new sermon."
    }
}

function Invoke-Checked {
    param(
        [string]$Label,
        [scriptblock]$Script
    )

    Write-Step $Label
    $global:LASTEXITCODE = 0
    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed."
    }
}

function Test-ProductionSermon {
    param(
        [string]$EpisodeUrl,
        [string]$Title,
        [string]$AudioFileName
    )

    $pageOk = $false
    $feedOk = $false

    for ($i = 0; $i -lt 12; $i++) {
        try {
            $page = Invoke-WebRequest -UseBasicParsing -Uri $EpisodeUrl -TimeoutSec 20
            $pageOk = $page.StatusCode -eq 200 -and $page.Content -match [regex]::Escape($Title)
        } catch {
            $pageOk = $false
        }

        try {
            $feed = Invoke-WebRequest -UseBasicParsing -Uri $productionFeedUrl -TimeoutSec 20
            $feedOk = $feed.Content -match [regex]::Escape($Title) -and $feed.Content -match [regex]::Escape($AudioFileName)
        } catch {
            $feedOk = $false
        }

        if ($pageOk -and $feedOk) {
            return $true
        }

        Start-Sleep -Seconds 10
    }

    return $false
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path $logPath | Out-Null

try {
    Set-Location $root
    Write-Host "Fillmore Christian Church sermon uploader"
    Write-Host "Repo: $root"
    Write-Host "Log:  $logPath"

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select sermon audio file"
    $dialog.Filter = "Audio files (*.mp3;*.m4a;*.wav)|*.mp3;*.m4a;*.wav|All files (*.*)|*.*"
    $dialog.Multiselect = $false

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "Canceled before selecting audio."
        return
    }

    $audioPath = $dialog.FileName
    $defaultTitle = Get-DefaultTitle $audioPath
    $title = Prompt-Input "Enter the sermon title exactly as it should appear on the website." "Sermon title" $defaultTitle
    if (-not $title.Trim()) {
        throw "A sermon title is required."
    }
    $title = $title.Trim()

    $dateText = Prompt-Input "Enter the sermon date as YYYY-MM-DD." "Sermon date" (Get-Date -Format "yyyy-MM-dd")
    $dateValue = [datetime]::ParseExact($dateText.Trim(), "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)

    $description = Prompt-Input "Optional: enter Scripture reference or short description." "Description" ""
    $description = $description.Trim()

    $speaker = Prompt-Input "Speaker/author label." "Speaker" "Fillmore Christian"
    if (-not $speaker.Trim()) {
        $speaker = "Fillmore Christian"
    }
    $speaker = $speaker.Trim()

    $audioFileName = [System.IO.Path]::GetFileName($audioPath) -replace "[^\w\.\-]+", "-"
    $slug = ConvertTo-Slug $title
    $episodeUrl = "https://www.fillmorechristian.org/episode/$slug/"

    $summary = @"
Audio: $audioPath
Title: $title
Date:  $($dateValue.ToString("yyyy-MM-dd"))
Description: $description
Speaker: $speaker

This will upload audio, update the website and podcast feeds, commit/push the change, deploy Cloudflare Pages, and verify production.
"@

    $confirm = [System.Windows.Forms.MessageBox]::Show($summary, "Confirm sermon upload", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Host "Canceled at confirmation."
        return
    }

    Invoke-Checked "Checking Git status" {
        Assert-CleanTree
    }

    Invoke-Checked "Pulling latest website source" {
        git -C $root pull --ff-only origin main
    }

    Invoke-Checked "Adding sermon and uploading audio to R2" {
        & (Join-Path $PSScriptRoot "add-podcast-episode.ps1") `
            -AudioPath $audioPath `
            -FileName $audioFileName `
            -Title $title `
            -Date $dateValue `
            -Description $description `
            -Speaker $speaker `
            -BaseAudioUrl $baseAudioUrl `
            -UploadR2 `
            -Bucket $bucket
    }

    Invoke-Checked "Running local readiness check" {
        & (Join-Path $PSScriptRoot "test-migration-readiness.ps1") -RequireIndependentAudio -SkipRemote
    }

    if (-not $SkipGitPush) {
        Invoke-Checked "Committing and pushing source changes" {
            git -C $root add .
            git -C $root diff --cached --quiet
            if ($LASTEXITCODE -eq 0) {
                Write-Host "No source changes to commit."
                $global:LASTEXITCODE = 0
            } else {
                git -C $root commit -m ("Add {0} sermon audio" -f $dateValue.ToString("yyyy-MM-dd"))
                if ($LASTEXITCODE -ne 0) { throw "Git commit failed." }
                git -C $root push origin main
            }
        }
    }

    if (-not $SkipDeploy) {
        Invoke-Checked "Deploying Cloudflare Pages" {
            npm run deploy:cloudflare
        }
    }

    Write-Step "Verifying production website and podcast feed"
    $productionOk = Test-ProductionSermon -EpisodeUrl $episodeUrl -Title $title -AudioFileName $audioFileName
    if (-not $productionOk) {
        throw "Deployment finished, but production did not show the new sermon/feed within two minutes. Open Codex and ask it to verify or troubleshoot the deployment."
    }

    Show-Message "Sermon upload complete.`n`nLive sermon page:`n$episodeUrl" "FCC Sermon Upload Complete"
    Start-Process $episodeUrl
} catch {
    $message = $_.Exception.Message
    Write-Host ""
    Write-Host "FAILED: $message" -ForegroundColor Red
    Write-Host "Log file: $logPath"
    Show-Message "Sermon upload failed:`n`n$message`n`nLog file:`n$logPath`n`nAsk Wake or Codex for help and include this log." "FCC Sermon Upload Failed" ([System.Windows.Forms.MessageBoxIcon]::Error)
} finally {
    Stop-Transcript | Out-Null
    Write-Host ""
    Read-Host "Press Enter to close"
}
