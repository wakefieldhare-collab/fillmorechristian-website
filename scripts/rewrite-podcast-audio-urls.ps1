param(
    [Parameter(Mandatory = $true)]
    [string]$BaseAudioUrl,

    [string[]]$FeedPaths = @(
        "podcast-category\fillmore-christian\feed\podcast",
        "podcast.xml",
        "feed.xml"
    )
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$base = $BaseAudioUrl.TrimEnd("/")

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

        $uri = [Uri]([string]$enclosure.url)
        $fileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        if (-not $fileName) {
            continue
        }

        $enclosure.SetAttribute("url", "$base/$fileName")
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

