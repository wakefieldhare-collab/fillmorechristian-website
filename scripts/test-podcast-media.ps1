param(
    [string]$FeedPath = "podcast-category\fillmore-christian\feed\podcast",
    [int]$SampleCount = 5,
    [switch]$All,
    [int]$TimeoutSec = 20,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$feedFile = if ([System.IO.Path]::IsPathRooted($FeedPath)) { $FeedPath } else { Join-Path $root $FeedPath }

if (-not (Test-Path -LiteralPath $feedFile)) {
    throw "Feed file not found: $feedFile"
}

function Get-HeaderValue {
    param(
        $Headers,
        [string]$Name
    )

    foreach ($key in $Headers.Keys) {
        if ($key -ieq $Name) {
            $value = $Headers[$key]
            if ($value -is [array]) {
                return [string]$value[0]
            }
            return [string]$value
        }
    }
    return ""
}

function Add-Result {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [ValidateSet("OK", "WARN", "FAIL")]
        [string]$Status,
        [string]$Title,
        [string]$Url,
        [string]$Details
    )

    $Results.Add([pscustomobject]@{
        Status = $Status
        Title = $Title
        Url = $Url
        Details = $Details
    })
}

function Normalize-AudioType {
    param([string]$ContentType)

    $type = $ContentType.Split(";")[0].Trim().ToLowerInvariant()
    if ($type -eq "audio/x-wav") { return "audio/wav" }
    if ($type -eq "audio/m4a") { return "audio/mp4" }
    return $type
}

[xml]$feed = Get-Content -Raw -LiteralPath $feedFile
$enclosures = @(
    foreach ($item in @($feed.rss.channel.item)) {
        if (-not $item.enclosure -or -not $item.enclosure.url) {
            continue
        }

        $length = 0L
        if ($item.enclosure.length -and [int64]::TryParse([string]$item.enclosure.length, [ref]$length)) {
            $expectedLength = $length
        } else {
            $expectedLength = 0L
        }

        [pscustomobject]@{
            Title = [string]$item.title
            Url = [string]$item.enclosure.url
            ExpectedType = [string]$item.enclosure.type
            ExpectedLength = $expectedLength
        }
    }
)

if ($enclosures.Count -eq 0) {
    throw "No audio enclosures found in $feedFile"
}

$referenceCounts = @{}
foreach ($enclosure in $enclosures) {
    if (-not $referenceCounts.ContainsKey($enclosure.Url)) {
        $referenceCounts[$enclosure.Url] = 0
    }
    $referenceCounts[$enclosure.Url]++
}

$seenUrls = @{}
$uniqueEnclosures = @(
    foreach ($enclosure in $enclosures) {
        if ($seenUrls.ContainsKey($enclosure.Url)) {
            continue
        }
        $seenUrls[$enclosure.Url] = $true

        [pscustomobject]@{
            Title = $enclosure.Title
            Url = $enclosure.Url
            ExpectedType = $enclosure.ExpectedType
            ExpectedLength = $enclosure.ExpectedLength
            FeedReferenceCount = $referenceCounts[$enclosure.Url]
        }
    }
)

$selected = if ($All) {
    $uniqueEnclosures
} else {
    $take = [Math]::Max(1, $SampleCount)
    @($uniqueEnclosures | Select-Object -First $take)
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($enclosure in $selected) {
    $url = $enclosure.Url
    if (-not $url.StartsWith("https://")) {
        Add-Result $results "FAIL" $enclosure.Title $url "Enclosure URL is not HTTPS"
        continue
    }

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -MaximumRedirection 5 -TimeoutSec $TimeoutSec
        $statusCode = [int]$response.StatusCode
        $contentType = Get-HeaderValue $response.Headers "Content-Type"
        $contentLengthText = Get-HeaderValue $response.Headers "Content-Length"
        $acceptRanges = Get-HeaderValue $response.Headers "Accept-Ranges"
        $contentLength = 0L
        [void][int64]::TryParse($contentLengthText, [ref]$contentLength)

        $issues = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]

        if ($statusCode -lt 200 -or $statusCode -ge 400) {
            $issues.Add("HTTP $statusCode")
        }

        if ($contentType -and $contentType -notmatch "^audio/") {
            $warnings.Add("content-type is $contentType")
        }

        if ($enclosure.ExpectedType -and $contentType -and (Normalize-AudioType $contentType) -ne (Normalize-AudioType $enclosure.ExpectedType)) {
            $warnings.Add("feed type $($enclosure.ExpectedType) differs from response $contentType")
        }

        if ($contentLength -le 0) {
            $issues.Add("missing Content-Length")
        } elseif ($enclosure.ExpectedLength -gt 0 -and $contentLength -ne $enclosure.ExpectedLength) {
            $warnings.Add("feed length $($enclosure.ExpectedLength) differs from response $contentLength")
        }

        if ($acceptRanges -and $acceptRanges -notmatch "bytes") {
            $warnings.Add("Accept-Ranges is $acceptRanges")
        }

        $detailParts = @("HTTP $statusCode", "$contentType", "$contentLength bytes")
        if ($enclosure.FeedReferenceCount -gt 1) {
            $detailParts += "$($enclosure.FeedReferenceCount) feed references"
        }
        if ($warnings.Count -gt 0) {
            $detailParts += "warnings: $($warnings -join '; ')"
        }

        if ($issues.Count -gt 0) {
            Add-Result $results "FAIL" $enclosure.Title $url ($issues -join "; ")
        } elseif ($warnings.Count -gt 0) {
            Add-Result $results "WARN" $enclosure.Title $url ($detailParts -join "; ")
        } else {
            Add-Result $results "OK" $enclosure.Title $url ($detailParts -join "; ")
        }
    } catch {
        Add-Result $results "FAIL" $enclosure.Title $url $_.Exception.Message
    }
}

if (-not $Quiet) {
    $results | Format-Table -AutoSize
}

$failed = @($results | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) podcast media check(s) failed."
}

$warnings = @($results | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) podcast media warning(s) remain."
}
