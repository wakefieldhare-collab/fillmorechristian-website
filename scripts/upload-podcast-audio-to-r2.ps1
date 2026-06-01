param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,

    [string]$AudioDir = "exports\thechurchco-podcast\audio",

    [string]$ManifestPath = "exports\thechurchco-podcast\r2-audio-manifest.csv",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $root $Path
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$audioPath = Resolve-RepoPath $AudioDir
$r2ManifestPath = Resolve-RepoPath $ManifestPath

if (-not (Test-Path -LiteralPath $audioPath)) {
    throw "Audio directory not found: $audioPath"
}

if (-not (Test-Path -LiteralPath $r2ManifestPath)) {
    throw "R2 audio manifest not found: $r2ManifestPath. Generate it first with scripts\build-r2-audio-manifest.ps1."
}

if (-not $DryRun -and -not (Get-Command wrangler -ErrorAction SilentlyContinue)) {
    throw "wrangler is not installed or not on PATH."
}

$rows = @(Import-Csv -LiteralPath $r2ManifestPath | Sort-Object ObjectKey)
if ($rows.Count -eq 0) {
    throw "R2 audio manifest has no rows: $r2ManifestPath"
}

$seenKeys = @{}
foreach ($row in $rows) {
    if (-not $row.ObjectKey -or -not $row.FileName -or -not $row.ContentType) {
        throw "R2 audio manifest row is missing ObjectKey, FileName, or ContentType."
    }
    if ($seenKeys.ContainsKey($row.ObjectKey)) {
        throw "Duplicate R2 object key in manifest: $($row.ObjectKey)"
    }
    $seenKeys[$row.ObjectKey] = $true

    $filePath = Join-Path $audioPath $row.FileName
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Audio file listed in manifest was not found: $filePath"
    }

    $file = Get-Item -LiteralPath $filePath
    if ($row.SizeBytes -and [int64]$row.SizeBytes -ne $file.Length) {
        throw "Audio size mismatch for $($row.FileName): manifest has $($row.SizeBytes), local file has $($file.Length)"
    }
}

if ($DryRun) {
    $totalBytes = ($rows | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host "Dry run: would upload $($rows.Count) objects ($totalBytes bytes) to r2://$Bucket from $r2ManifestPath"
    return
}

foreach ($row in $rows) {
    $filePath = Join-Path $audioPath $row.FileName
    Write-Host "Uploading $($row.FileName) -> r2://$Bucket/$($row.ObjectKey)"
    & wrangler r2 object put "$Bucket/$($row.ObjectKey)" --file $filePath --content-type $row.ContentType
    if ($LASTEXITCODE -ne 0) {
        throw "Upload failed for $filePath"
    }
}
