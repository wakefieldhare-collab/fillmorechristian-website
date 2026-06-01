param(
    [Parameter(Mandatory = $true)]
    [string]$BaseAudioUrl,

    [string]$R2ManifestPath = "exports\thechurchco-podcast\r2-audio-manifest.csv",

    [string[]]$FeedPaths = @(
        "podcast-category\fillmore-christian\feed\podcast",
        "podcast.xml",
        "feed.xml"
    )
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$base = $BaseAudioUrl.TrimEnd("/")
$r2ManifestFullPath = if ([System.IO.Path]::IsPathRooted($R2ManifestPath)) {
    $R2ManifestPath
} else {
    Join-Path $root $R2ManifestPath
}

function ConvertTo-LocalAudioFileName {
    param([string]$Url)

    $uri = [Uri]$Url
    $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    return $fileName -replace '[^\w\.\-]+', '-'
}

$publicUrlBySourceUrl = @{}
if (Test-Path -LiteralPath $r2ManifestFullPath) {
    foreach ($row in @(Import-Csv -LiteralPath $r2ManifestFullPath)) {
        if (-not $row.SourceUrls -or -not $row.ObjectKey) {
            continue
        }

        $publicUrl = if ($row.PublicUrl) { $row.PublicUrl } else { "$base/$($row.ObjectKey)" }
        $publicUrlBySourceUrl[$publicUrl] = $publicUrl
        foreach ($sourceUrl in @($row.SourceUrls -split "\s+\|\s+")) {
            if ($sourceUrl) {
                $publicUrlBySourceUrl[$sourceUrl] = $publicUrl
            }
        }
    }
}

foreach ($relativePath in $FeedPaths) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Feed file not found: $path"
    }

    [xml]$feed = Get-Content -Raw -LiteralPath $path
    $items = @($feed.rss.channel.item)
    $rewritten = 0

    foreach ($item in $items) {
        $enclosure = $item.enclosure
        if (-not $enclosure -or -not $enclosure.url) {
            continue
        }

        $fileName = ConvertTo-LocalAudioFileName ([string]$enclosure.url)
        if (-not $fileName) {
            continue
        }

        $newUrl = if ($publicUrlBySourceUrl.ContainsKey([string]$enclosure.url)) {
            $publicUrlBySourceUrl[[string]$enclosure.url]
        } else {
            "$base/$fileName"
        }

        $enclosure.SetAttribute("url", $newUrl)
        $rewritten++
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($path, $settings)
    $feed.Save($writer)
    $writer.Close()

    Write-Host "Rewrote $rewritten enclosure URLs in $relativePath"
}
