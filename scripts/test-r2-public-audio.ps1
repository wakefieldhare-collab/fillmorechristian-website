param(
    [string]$ManifestPath = "exports\thechurchco-podcast\r2-audio-manifest.csv",
    [int]$SampleCount = 5,
    [switch]$All,
    [int]$TimeoutSec = 20,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifestFullPath = if ([System.IO.Path]::IsPathRooted($ManifestPath)) {
    $ManifestPath
} else {
    Join-Path $root $ManifestPath
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
        [string]$ObjectKey,
        [string]$Url,
        [string]$Details
    )

    $Results.Add([pscustomobject]@{
        Status = $Status
        ObjectKey = $ObjectKey
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

if (-not (Test-Path -LiteralPath $manifestFullPath)) {
    throw "R2 audio manifest not found: $manifestFullPath. Generate it first with scripts\build-r2-audio-manifest.ps1."
}
if ($SampleCount -lt 1) {
    throw "SampleCount must be at least 1."
}

$rows = @(Import-Csv -LiteralPath $manifestFullPath | Sort-Object ObjectKey)
if ($rows.Count -eq 0) {
    throw "R2 audio manifest has no rows: $manifestFullPath"
}

foreach ($row in $rows) {
    if (-not $row.ObjectKey -or -not $row.PublicUrl -or -not $row.ContentType -or -not $row.SizeBytes) {
        throw "R2 audio manifest row is missing ObjectKey, PublicUrl, ContentType, or SizeBytes."
    }
}

$selectedRows = if ($All) {
    $rows
} else {
    @($rows | Select-Object -First ([Math]::Max(1, $SampleCount)))
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($row in $selectedRows) {
    $url = [string]$row.PublicUrl
    if (-not $url.StartsWith("https://")) {
        Add-Result $results "FAIL" $row.ObjectKey $url "Public URL is not HTTPS"
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

        $expectedLength = [int64]$row.SizeBytes
        $issues = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]

        if ($statusCode -lt 200 -or $statusCode -ge 400) {
            $issues.Add("HTTP $statusCode")
        }

        if ($contentType -and $contentType -notmatch "^audio/") {
            $warnings.Add("content-type is $contentType")
        }

        if ($contentType -and (Normalize-AudioType $contentType) -ne (Normalize-AudioType $row.ContentType)) {
            $warnings.Add("manifest type $($row.ContentType) differs from response $contentType")
        }

        if ($contentLength -le 0) {
            $issues.Add("missing Content-Length")
        } elseif ($expectedLength -gt 0 -and $contentLength -ne $expectedLength) {
            $warnings.Add("manifest size $expectedLength differs from response $contentLength")
        }

        if ($acceptRanges -and $acceptRanges -notmatch "bytes") {
            $warnings.Add("Accept-Ranges is $acceptRanges")
        }

        $detailParts = @("HTTP $statusCode", "$contentType", "$contentLength bytes")
        if ([int]$row.FeedReferenceCount -gt 1) {
            $detailParts += "$($row.FeedReferenceCount) feed references"
        }
        if ($warnings.Count -gt 0) {
            $detailParts += "warnings: $($warnings -join '; ')"
        }

        if ($issues.Count -gt 0) {
            Add-Result $results "FAIL" $row.ObjectKey $url ($issues -join "; ")
        } elseif ($warnings.Count -gt 0) {
            Add-Result $results "WARN" $row.ObjectKey $url ($detailParts -join "; ")
        } else {
            Add-Result $results "OK" $row.ObjectKey $url ($detailParts -join "; ")
        }
    } catch {
        Add-Result $results "FAIL" $row.ObjectKey $url $_.Exception.Message
    }
}

if (-not $Quiet) {
    $results | Format-Table -AutoSize
}

$failed = @($results | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    throw "$($failed.Count) public R2 audio check(s) failed."
}

$warnings = @($results | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Warning "$($warnings.Count) public R2 audio warning(s) remain."
}

