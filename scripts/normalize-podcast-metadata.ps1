param(
    [string[]]$FeedPaths = @(
        "podcast-category\fillmore-christian\feed\podcast",
        "podcast.xml",
        "feed.xml"
    ),
    [string]$ArtworkUrl = "https://www.fillmorechristian.org/images/podcast-cover.jpg",
    [string]$CanonicalFeedUrl = "https://www.fillmorechristian.org/podcast-category/fillmore-christian/feed/podcast",
    [string]$PodcastTitle = "Fillmore Christian Church",
    [string]$PodcastDescription = "The Bible teaching archives of Fillmore Christian Church in Fillmore, Missouri.",
    [string]$OwnerName = "Fillmore Christian Church",
    [string]$OwnerEmail = "church@fillmorechristian.org",
    [string]$Generator = "Fillmore Christian Church static podcast feed"
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

function Get-AudioContentType {
    param([string]$Url)

    $lower = $Url.ToLowerInvariant()
    if ($lower.EndsWith(".m4a")) { return "audio/mp4" }
    if ($lower.EndsWith(".wav")) { return "audio/wav" }
    return "audio/mpeg"
}

function Set-PodcastArtwork {
    param(
        [System.Xml.XmlElement]$Parent,
        [string]$Url,
        [string]$Title = "",
        [string]$Link = ""
    )

    $changed = 0
    foreach ($child in @($Parent.ChildNodes)) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element -or $child.LocalName -ne "image") {
            continue
        }

        if ($child.HasAttribute("href")) {
            if ($child.GetAttribute("href") -ne $Url) {
                $child.SetAttribute("href", $Url)
                $changed++
            }
            continue
        }

        foreach ($imageChild in @($child.ChildNodes)) {
            if ($imageChild.NodeType -eq [System.Xml.XmlNodeType]::Element -and $imageChild.LocalName -eq "url") {
                if ($imageChild.InnerText -ne $Url) {
                    $imageChild.InnerText = $Url
                    $changed++
                }
            }
            if ($Title -and $imageChild.NodeType -eq [System.Xml.XmlNodeType]::Element -and $imageChild.LocalName -eq "title") {
                if ($imageChild.InnerText -ne $Title) {
                    $imageChild.InnerText = $Title
                    $changed++
                }
            }
            if ($Link -and $imageChild.NodeType -eq [System.Xml.XmlNodeType]::Element -and $imageChild.LocalName -eq "link") {
                if ($imageChild.InnerText -ne $Link) {
                    $imageChild.InnerText = $Link
                    $changed++
                }
            }
        }
    }

    return $changed
}

function Get-FirstChildElement {
    param(
        [System.Xml.XmlElement]$Parent,
        [string]$LocalName,
        [string]$NamespaceUri = ""
    )

    foreach ($child in @($Parent.ChildNodes)) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) {
            continue
        }
        if ($child.LocalName -ne $LocalName) {
            continue
        }
        if ($NamespaceUri -and $child.NamespaceURI -ne $NamespaceUri) {
            continue
        }
        if (-not $NamespaceUri -and $child.NamespaceURI) {
            continue
        }
        return $child
    }
    return $null
}

function Set-ChildElementText {
    param(
        [System.Xml.XmlDocument]$Document,
        [System.Xml.XmlElement]$Parent,
        [string]$LocalName,
        [string]$Value,
        [string]$NamespaceUri = "",
        [string]$Prefix = "",
        [System.Xml.XmlNode]$InsertBefore = $null
    )

    $child = Get-FirstChildElement -Parent $Parent -LocalName $LocalName -NamespaceUri $NamespaceUri
    $changed = 0
    if (-not $child) {
        if ($NamespaceUri) {
            $child = $Document.CreateElement($Prefix, $LocalName, $NamespaceUri)
        } else {
            $child = $Document.CreateElement($LocalName)
        }

        if ($InsertBefore) {
            [void]$Parent.InsertBefore($child, $InsertBefore)
        } else {
            [void]$Parent.AppendChild($child)
        }
        $changed++
    }

    if ($child.InnerText -ne $Value) {
        $child.InnerText = $Value
        $changed++
    }
    return $changed
}

function Set-AtomSelfLink {
    param(
        [System.Xml.XmlDocument]$Document,
        [System.Xml.XmlElement]$Channel,
        [string]$Url
    )

    $atomNs = "http://www.w3.org/2005/Atom"
    $changed = 0
    $selfLink = $null
    foreach ($child in @($Channel.ChildNodes)) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and
            $child.LocalName -eq "link" -and
            $child.NamespaceURI -eq $atomNs -and
            $child.GetAttribute("rel") -eq "self") {
            $selfLink = $child
            break
        }
    }

    if (-not $selfLink) {
        $title = Get-FirstChildElement -Parent $Channel -LocalName "title"
        $selfLink = $Document.CreateElement("atom", "link", $atomNs)
        [void]$Channel.InsertAfter($selfLink, $title)
        $changed++
    }

    $expected = @{
        href = $Url
        rel = "self"
        type = "application/rss+xml"
    }
    foreach ($name in $expected.Keys) {
        if ($selfLink.GetAttribute($name) -ne $expected[$name]) {
            $selfLink.SetAttribute($name, $expected[$name])
            $changed++
        }
    }

    return $changed
}

function Set-PodcastChannelMetadata {
    param(
        [xml]$Feed,
        [string]$ArtworkUrl,
        [string]$CanonicalFeedUrl,
        [string]$PodcastTitle,
        [string]$PodcastDescription,
        [string]$OwnerName,
        [string]$OwnerEmail,
        [string]$Generator
    )

    $channel = $Feed.rss.channel
    $itunesNs = "http://www.itunes.com/dtds/podcast-1.0.dtd"
    $googleNs = "http://www.google.com/schemas/play-podcasts/1.0"
    $changed = 0

    $changed += Set-AtomSelfLink -Document $Feed -Channel $channel -Url $CanonicalFeedUrl
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "title" -Value $PodcastTitle
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "description" -Value $PodcastDescription
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "link" -Value "https://www.fillmorechristian.org"
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "generator" -Value $Generator
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "subtitle" -NamespaceUri $itunesNs -Prefix "itunes" -Value $PodcastDescription
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "author" -NamespaceUri $itunesNs -Prefix "itunes" -Value $OwnerName
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "author" -NamespaceUri $googleNs -Prefix "googleplay" -Value $OwnerName
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "email" -NamespaceUri $googleNs -Prefix "googleplay" -Value $OwnerEmail
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "summary" -NamespaceUri $itunesNs -Prefix "itunes" -Value $PodcastDescription
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "description" -NamespaceUri $googleNs -Prefix "googleplay" -Value $PodcastDescription
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "explicit" -NamespaceUri $itunesNs -Prefix "itunes" -Value "no"
    $changed += Set-ChildElementText -Document $Feed -Parent $channel -LocalName "explicit" -NamespaceUri $googleNs -Prefix "googleplay" -Value "no"

    $owner = Get-FirstChildElement -Parent $channel -LocalName "owner" -NamespaceUri $itunesNs
    if (-not $owner) {
        $explicit = Get-FirstChildElement -Parent $channel -LocalName "explicit" -NamespaceUri $itunesNs
        $owner = $Feed.CreateElement("itunes", "owner", $itunesNs)
        if ($explicit) {
            [void]$channel.InsertBefore($owner, $explicit)
        } else {
            [void]$channel.AppendChild($owner)
        }
        $changed++
    }
    $changed += Set-ChildElementText -Document $Feed -Parent $owner -LocalName "name" -NamespaceUri $itunesNs -Prefix "itunes" -Value $OwnerName
    $changed += Set-ChildElementText -Document $Feed -Parent $owner -LocalName "email" -NamespaceUri $itunesNs -Prefix "itunes" -Value $OwnerEmail

    $changed += Set-PodcastArtwork $channel $ArtworkUrl $PodcastTitle "https://www.fillmorechristian.org"
    return $changed
}

foreach ($relativePath in $FeedPaths) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Feed file not found: $path"
    }

    [xml]$feed = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    $changed = 0
    $changed += Set-PodcastChannelMetadata `
        -Feed $feed `
        -ArtworkUrl $ArtworkUrl `
        -CanonicalFeedUrl $CanonicalFeedUrl `
        -PodcastTitle $PodcastTitle `
        -PodcastDescription $PodcastDescription `
        -OwnerName $OwnerName `
        -OwnerEmail $OwnerEmail `
        -Generator $Generator

    foreach ($item in @($feed.rss.channel.item)) {
        $changed += Set-PodcastArtwork $item $ArtworkUrl

        if ($item.enclosure -and $item.enclosure.url) {
            $audioType = Get-AudioContentType ([string]$item.enclosure.url)
            if ($item.enclosure.type -ne $audioType) {
                $item.enclosure.SetAttribute("type", $audioType)
                $changed++
            }
        }

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

    Write-Host "Normalized $changed podcast metadata field(s) in $relativePath"
}
