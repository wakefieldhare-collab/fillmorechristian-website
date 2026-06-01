param(
    [string[]]$FeedPaths = @(
        "podcast-category\fillmore-christian\feed\podcast",
        "podcast.xml",
        "feed.xml"
    )
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Normalize-SpeakerName {
    param([string]$Text)

    $speaker = ($Text -replace "\s+", " ").Trim()
    if (-not $speaker) { return "Fillmore Christian" }
    if ($speaker -match "^(?i:thechurchco)") { return "Fillmore Christian" }
    return $speaker
}

foreach ($relativePath in $FeedPaths) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Feed file not found: $path"
    }

    [xml]$feed = Get-Content -Raw -LiteralPath $path
    $changed = 0

    foreach ($item in @($feed.rss.channel.item)) {
        foreach ($child in @($item.ChildNodes)) {
            if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) {
                continue
            }

            if ($child.LocalName -ne "author" -and $child.LocalName -ne "creator") {
                continue
            }

            $normalized = Normalize-SpeakerName $child.InnerText
            if ($normalized -ne $child.InnerText) {
                $child.InnerText = $normalized
                $changed++
            }
        }
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($path, $settings)
    $feed.Save($writer)
    $writer.Close()

    Write-Host "Normalized $changed author fields in $relativePath"
}
