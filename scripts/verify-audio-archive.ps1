param(
    [string]$ArchiveDir = "J:\My Drive\Sermon Audio\Website Audio Archive",
    [string]$InventoryPath = "exports\thechurchco-podcast\audio-inventory.csv",
    [string]$R2ManifestPath = "exports\thechurchco-podcast\r2-audio-manifest.csv",
    # Hash every archive file against audio-inventory.csv (reads about 2.6 GB from Drive).
    [switch]$VerifyHashes,
    # Also confirm every public R2 URL serves the inventory size (HEAD requests only).
    [switch]$VerifyR2
)

# R2 is the official copy of the website sermon audio and audio-inventory.csv is
# its index. The church Google Drive folder above is the second copy. This script
# reports any file that is missing from, or different in, either copy.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
function Resolve-RepoPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $root $Path
}

$inventoryFile = Resolve-RepoPath $InventoryPath
if (-not (Test-Path -LiteralPath $inventoryFile)) {
    throw "Audio inventory not found: $inventoryFile"
}
if (-not (Test-Path -LiteralPath $ArchiveDir)) {
    throw "Audio archive folder not found: $ArchiveDir"
}

$rows = @(Import-Csv -LiteralPath $inventoryFile)
$problems = New-Object System.Collections.Generic.List[string]

foreach ($row in $rows) {
    $path = Join-Path $ArchiveDir $row.FileName
    if (-not (Test-Path -LiteralPath $path)) {
        $problems.Add("archive missing: $($row.FileName)")
        continue
    }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -ne [int64]$row.SizeBytes) {
        $problems.Add("archive size mismatch: $($row.FileName) has $($file.Length), inventory has $($row.SizeBytes)")
        continue
    }
    if ($VerifyHashes) {
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($hash -ne $row.SHA256) {
            $problems.Add("archive SHA-256 mismatch: $($row.FileName)")
        }
    }
}

if ($VerifyR2) {
    $r2File = Resolve-RepoPath $R2ManifestPath
    if (-not (Test-Path -LiteralPath $r2File)) {
        throw "R2 audio manifest not found: $r2File"
    }
    $urlByName = @{}
    foreach ($r in @(Import-Csv -LiteralPath $r2File)) { $urlByName[$r.FileName] = $r.PublicUrl }
    foreach ($row in $rows) {
        $url = $urlByName[$row.FileName]
        if (-not $url) {
            $problems.Add("R2 manifest has no PublicUrl: $($row.FileName)")
            continue
        }
        try {
            $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing
            $length = [int64]([string]$head.Headers["Content-Length"])
            if ($head.StatusCode -ne 200 -or $length -ne [int64]$row.SizeBytes) {
                $problems.Add("R2 size mismatch: $($row.FileName) served $length, inventory has $($row.SizeBytes)")
            }
        } catch {
            $problems.Add("R2 request failed: $($row.FileName): $($_.Exception.Message)")
        }
    }
}

$extra = @(Get-ChildItem -LiteralPath $ArchiveDir -File | Where-Object { $_.Name -notin $rows.FileName -and $_.Name -ne "desktop.ini" })
if ($extra.Count -gt 0) {
    Write-Warning "$($extra.Count) archive file(s) are not in the inventory: $($extra.Name -join ', ')"
}

$scope = @("archive sizes")
if ($VerifyHashes) { $scope += "archive SHA-256" }
if ($VerifyR2) { $scope += "R2 sizes" }

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "FAIL  $_" }
    throw "$($problems.Count) audio archive problem(s) across $($rows.Count) inventory files."
}

Write-Host "OK  $($rows.Count) inventory files verified ($($scope -join ', '))."
