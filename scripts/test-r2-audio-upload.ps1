param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,

    [string]$ManifestPath = "exports\thechurchco-podcast\r2-audio-manifest.csv",

    [string]$AudioDir = "exports\thechurchco-podcast\audio",

    [int]$SampleCount = 5,

    [switch]$All,

    [switch]$VerifyHashes,

    [switch]$DryRun,

    [switch]$KeepDownloads
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $root $Path
}

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

function Assert-CloudflareAuth {
    param([object]$Wrangler)

    $whoamiOutput = & $Wrangler.Command @($Wrangler.PrefixArgs) whoami 2>&1
    if ($LASTEXITCODE -ne 0 -or ($whoamiOutput -join "`n") -match "not authenticated") {
        throw "Cloudflare is not authenticated. Run npx wrangler login first."
    }
}

$manifestFullPath = Resolve-RepoPath $ManifestPath
$audioPath = Resolve-RepoPath $AudioDir

if (-not (Test-Path -LiteralPath $manifestFullPath)) {
    throw "R2 audio manifest not found: $manifestFullPath. Generate it first with scripts\build-r2-audio-manifest.ps1."
}
if (-not (Test-Path -LiteralPath $audioPath)) {
    throw "Audio directory not found: $audioPath"
}
if ($SampleCount -lt 1) {
    throw "SampleCount must be at least 1."
}

$rows = @(Import-Csv -LiteralPath $manifestFullPath | Sort-Object ObjectKey)
if ($rows.Count -eq 0) {
    throw "R2 audio manifest has no rows: $manifestFullPath"
}

$selectedRows = if ($All) { $rows } else { @($rows | Select-Object -First $SampleCount) }
foreach ($row in $selectedRows) {
    if (-not $row.ObjectKey -or -not $row.FileName -or -not $row.SizeBytes) {
        throw "R2 audio manifest row is missing ObjectKey, FileName, or SizeBytes."
    }

    $localFilePath = Join-Path $audioPath $row.FileName
    if (-not (Test-Path -LiteralPath $localFilePath)) {
        throw "Local source audio file is missing: $localFilePath"
    }
}

if ($DryRun) {
    $scope = if ($All) { "all $($selectedRows.Count)" } else { "$($selectedRows.Count) sampled" }
    Write-Host "Dry run: would download and verify $scope R2 object(s) from r2://$Bucket using $manifestFullPath"
    return
}

$wrangler = Get-WranglerInvocation
Assert-CloudflareAuth -Wrangler $wrangler
$downloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fcc-r2-audio-verify-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $downloadRoot | Out-Null

try {
    foreach ($row in $selectedRows) {
        $downloadPath = Join-Path $downloadRoot $row.FileName
        Write-Host "Verifying r2://$Bucket/$($row.ObjectKey)"
        & $wrangler.Command @($wrangler.PrefixArgs) r2 object get "$Bucket/$($row.ObjectKey)" --file $downloadPath --remote
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed for r2://$Bucket/$($row.ObjectKey)"
        }

        if (-not (Test-Path -LiteralPath $downloadPath)) {
            throw "Downloaded file was not created: $downloadPath"
        }

        $download = Get-Item -LiteralPath $downloadPath
        if ([int64]$row.SizeBytes -ne $download.Length) {
            throw "Size mismatch for $($row.ObjectKey): manifest has $($row.SizeBytes), downloaded file has $($download.Length)"
        }

        if ($VerifyHashes) {
            $hash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
            if ($hash -ne $row.SHA256) {
                throw "SHA-256 mismatch for $($row.ObjectKey)"
            }
        }
    }
} finally {
    if ($KeepDownloads) {
        Write-Host "Kept downloaded verification files in $downloadRoot"
    } elseif (Test-Path -LiteralPath $downloadRoot) {
        $resolvedDownloadRoot = (Resolve-Path -LiteralPath $downloadRoot).Path
        $resolvedTempRoot = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path.TrimEnd("\")
        if (-not $resolvedDownloadRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove verification downloads outside the temp folder: $resolvedDownloadRoot"
        }
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force
    }
}

$hashNote = if ($VerifyHashes) { " with SHA-256 hashes" } else { "" }
$scopeLabel = if ($All) { "all $($selectedRows.Count)" } else { "$($selectedRows.Count) sampled" }
Write-Host "Verified $scopeLabel R2 audio object(s)$hashNote from r2://$Bucket"
