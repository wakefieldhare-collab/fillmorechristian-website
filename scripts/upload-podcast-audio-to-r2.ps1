param(
    [Parameter(Mandatory = $true)]
    [string]$Bucket,

    [string]$AudioDir = "exports\thechurchco-podcast\audio",

    [string]$Prefix = ""
)

$ErrorActionPreference = "Stop"

function Get-ContentType {
    param([string]$FileName)

    $lower = $FileName.ToLowerInvariant()
    if ($lower.EndsWith(".m4a")) { return "audio/mp4" }
    if ($lower.EndsWith(".wav")) { return "audio/wav" }
    return "audio/mpeg"
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$audioPath = Join-Path $root $AudioDir

if (-not (Test-Path -LiteralPath $audioPath)) {
    throw "Audio directory not found: $audioPath"
}

$wrangler = Get-Command wrangler -ErrorAction SilentlyContinue
if (-not $wrangler) {
    throw "wrangler is not installed or not on PATH."
}

$files = Get-ChildItem -LiteralPath $audioPath -File | Sort-Object Name
if ($files.Count -eq 0) {
    throw "No audio files found in $audioPath"
}

foreach ($file in $files) {
    $key = if ($Prefix) { ($Prefix.TrimEnd("/") + "/" + $file.Name) } else { $file.Name }
    Write-Host "Uploading $($file.Name) -> r2://$Bucket/$key"
    & wrangler r2 object put "$Bucket/$key" --file $file.FullName --content-type (Get-ContentType $file.Name)
    if ($LASTEXITCODE -ne 0) {
        throw "Upload failed for $($file.FullName)"
    }
}
