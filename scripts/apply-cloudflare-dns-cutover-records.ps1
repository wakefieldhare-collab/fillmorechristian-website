param(
    [string]$Domain = "fillmorechristian.org",
    [string]$AccountId = "377eaebfa77447d2f7906a1e0c1b788c",
    [string]$PreserveCsvPath = "exports\dns\fillmorechristian.org-cloudflare-preserve-records.csv",
    [string]$PagesTarget = "fillmorechristian-website.pages.dev",
    [string]$DmarcRecordValue = "v=DMARC1; p=none; rua=mailto:church@fillmorechristian.org",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$preserveCsvFullPath = if ([System.IO.Path]::IsPathRooted($PreserveCsvPath)) {
    $PreserveCsvPath
} else {
    Join-Path $root $PreserveCsvPath
}

function Assert-PersonalGitHubRemote {
    $originUrl = (& git -C $root remote get-url origin 2>$null).Trim()
    if ($originUrl -match "wake-byte") {
        throw "Refusing Cloudflare DNS cutover from the work GitHub owner: $originUrl"
    }
    if ($originUrl -notmatch "github\.com[:/]wakefieldhare-collab/fillmorechristian-website(\.git)?$") {
        throw "Unexpected origin remote. Expected wakefieldhare-collab/fillmorechristian-website, found: $originUrl"
    }
}

function Get-ApiToken {
    foreach ($name in @("CLOUDFLARE_API_TOKEN", "CF_API_TOKEN")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) {
            return $value
        }
    }

    return ""
}

function Invoke-CloudflareApi {
    param(
        [ValidateSet("GET", "POST", "PATCH", "DELETE")]
        [string]$Method,
        [string]$Path,
        [string]$Token,
        [object]$Body = $null
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $uri = "https://api.cloudflare.com/client/v4/" + $Path.TrimStart("/")
    $parameters = @{
        Method = $Method
        Headers = $headers
        Uri = $uri
    }

    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        $response = Invoke-RestMethod @parameters
    } catch {
        $message = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $message = $_.ErrorDetails.Message
        }

        if ($message -match "Authentication error|Unauthorized|Forbidden") {
            throw "Cloudflare DNS API authorization failed. Create a token at https://dash.cloudflare.com/profile/api-tokens with Zone:Read and Zone:DNS Edit for $Domain, then set CLOUDFLARE_API_TOKEN."
        }

        throw
    }
    if ($response.PSObject.Properties.Name -contains "success" -and -not $response.success) {
        $errors = @($response.errors | ForEach-Object { $_.message })
        throw "Cloudflare API failed: $($errors -join '; ')"
    }
    return $response
}

function Get-ZoneId {
    param([string]$Token)

    $response = Invoke-CloudflareApi -Method GET -Token $Token -Path "zones?name=$Domain&account.id=$AccountId"
    $zone = @($response.result | Where-Object { $_.name -eq $Domain } | Select-Object -First 1)
    if ($zone.Count -eq 0) {
        throw "$Domain was not found in Cloudflare account $AccountId."
    }
    return [string]$zone[0].id
}

function Get-DnsRecords {
    param(
        [string]$Token,
        [string]$ZoneId
    )

    $records = New-Object System.Collections.Generic.List[object]
    $page = 1
    do {
        $response = Invoke-CloudflareApi -Method GET -Token $Token -Path "zones/$ZoneId/dns_records?per_page=100&page=$page"
        foreach ($record in @($response.result)) {
            $records.Add($record)
        }
        $totalPages = [int]$response.result_info.total_pages
        $page += 1
    } while ($page -le $totalPages)

    return @($records)
}

function New-DesiredRecord {
    param(
        [string]$Name,
        [string]$Type,
        [string]$Content,
        [string]$Priority = "",
        [bool]$Proxied = $false
    )

    $body = [ordered]@{
        type = $Type
        name = $Name
        content = $Content
        ttl = 1
    }
    if ($Type -eq "MX") {
        $body.priority = [int]$Priority
    }
    if ($Type -in @("A", "AAAA", "CNAME")) {
        $body.proxied = $Proxied
    }

    return [pscustomobject]@{
        Name = $Name
        Type = $Type
        Content = $Content
        Priority = $Priority
        Proxied = $Proxied
        Body = $body
    }
}

function Test-SameRecord {
    param(
        [object]$Existing,
        [object]$Desired
    )

    if ($Existing.type -ne $Desired.Type) { return $false }
    if ($Existing.name -ne $Desired.Name) { return $false }
    if ($Existing.content -ne $Desired.Content) { return $false }
    if ($Desired.Type -eq "MX" -and [string]$Existing.priority -ne [string]$Desired.Priority) { return $false }
    if ($Desired.Type -in @("A", "AAAA", "CNAME") -and [bool]$Existing.proxied -ne [bool]$Desired.Proxied) { return $false }
    return $true
}

if (-not (Test-Path -LiteralPath $preserveCsvFullPath)) {
    throw "Preserve CSV not found: $preserveCsvFullPath"
}

Assert-PersonalGitHubRemote

$preserveRows = @(Import-Csv -LiteralPath $preserveCsvFullPath)
if ($preserveRows.Count -eq 0) {
    throw "Preserve CSV has no records: $preserveCsvFullPath"
}

$desiredRecords = New-Object System.Collections.Generic.List[object]
foreach ($row in $preserveRows) {
    $desiredRecords.Add((New-DesiredRecord -Name $row.Name -Type $row.Type -Content $row.Value -Priority $row.Priority -Proxied:$false))
}
$dmarcName = "_dmarc.$Domain"
$hasDmarc = @($desiredRecords | Where-Object { $_.Name -eq $dmarcName -and $_.Type -eq "TXT" }).Count -gt 0
if (-not $hasDmarc) {
    $desiredRecords.Add((New-DesiredRecord -Name $dmarcName -Type "TXT" -Content $DmarcRecordValue -Proxied:$false))
}
$desiredRecords.Add((New-DesiredRecord -Name $Domain -Type "CNAME" -Content $PagesTarget -Proxied:$true))
$desiredRecords.Add((New-DesiredRecord -Name "www.$Domain" -Type "CNAME" -Content $PagesTarget -Proxied:$true))

Write-Host "Cloudflare DNS cutover record plan for $Domain"
Write-Host "Preserve/import records:"
foreach ($record in @($desiredRecords | Where-Object { $_.Content -ne $PagesTarget })) {
    $priorityText = if ($record.Priority) { " priority $($record.Priority)" } else { "" }
    Write-Host ("  keep {0} {1}{2} -> {3}" -f $record.Type, $record.Name, $priorityText, $record.Content)
}
Write-Host "Website records:"
Write-Host "  replace apex website DNS with CNAME $Domain -> $PagesTarget (proxied)"
Write-Host "  replace www website DNS with CNAME www.$Domain -> $PagesTarget (proxied)"
Write-Host "  remove old A $Domain -> 77.83.141.16 when applying"

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run only. Rerun with -Apply and a CLOUDFLARE_API_TOKEN or CF_API_TOKEN with Zone:Read and Zone:DNS Edit permission to write records."
    return
}

$token = Get-ApiToken
if (-not $token) {
    throw "Set CLOUDFLARE_API_TOKEN or CF_API_TOKEN to a Cloudflare token with Zone:Read and Zone:DNS Edit permission, then rerun with -Apply. Token URL: https://dash.cloudflare.com/profile/api-tokens"
}

$zoneId = Get-ZoneId -Token $token
$existingRecords = @(Get-DnsRecords -Token $token -ZoneId $zoneId)

$oldWebsiteRecords = @(
    $existingRecords | Where-Object {
        ($_.type -eq "A" -and $_.name -eq $Domain -and $_.content -eq "77.83.141.16") -or
        ($_.type -eq "AAAA" -and $_.name -eq $Domain) -or
        ($_.type -eq "CNAME" -and $_.name -eq "www.$Domain" -and $_.content -eq "ssl.thechurchco.com")
    }
)
foreach ($record in $oldWebsiteRecords) {
    Write-Host "Deleting old website record: $($record.type) $($record.name) -> $($record.content)"
    Invoke-CloudflareApi -Method DELETE -Token $token -Path "zones/$zoneId/dns_records/$($record.id)" | Out-Null
}

$existingRecords = @(Get-DnsRecords -Token $token -ZoneId $zoneId)
foreach ($desired in $desiredRecords) {
    $sameTypeAndName = @($existingRecords | Where-Object { $_.type -eq $desired.Type -and $_.name -eq $desired.Name })
    $sameTypeNameAndContent = @($sameTypeAndName | Where-Object { $_.content -eq $desired.Content })
    $alreadyCorrect = @($sameTypeAndName | Where-Object { Test-SameRecord -Existing $_ -Desired $desired })

    if ($alreadyCorrect.Count -gt 0) {
        Write-Host "Already correct: $($desired.Type) $($desired.Name) -> $($desired.Content)"
        continue
    }

    if ($sameTypeNameAndContent.Count -eq 1) {
        Write-Host "Updating settings: $($desired.Type) $($desired.Name) -> $($desired.Content)"
        Invoke-CloudflareApi -Method PATCH -Token $token -Path "zones/$zoneId/dns_records/$($sameTypeNameAndContent[0].id)" -Body $desired.Body | Out-Null
    } elseif ($sameTypeNameAndContent.Count -gt 1) {
        throw "Duplicate $($desired.Type) records already exist for $($desired.Name) -> $($desired.Content). Resolve duplicates in Cloudflare before applying."
    } elseif ($desired.Type -in @("A", "AAAA", "CNAME") -and $sameTypeAndName.Count -eq 1) {
        Write-Host "Replacing: $($desired.Type) $($desired.Name) -> $($desired.Content)"
        Invoke-CloudflareApi -Method PATCH -Token $token -Path "zones/$zoneId/dns_records/$($sameTypeAndName[0].id)" -Body $desired.Body | Out-Null
    } elseif ($desired.Type -in @("A", "AAAA", "CNAME") -and $sameTypeAndName.Count -gt 1) {
        throw "Multiple $($desired.Type) records already exist for $($desired.Name). Resolve duplicates in Cloudflare before applying."
    } else {
        Write-Host "Creating: $($desired.Type) $($desired.Name) -> $($desired.Content)"
        Invoke-CloudflareApi -Method POST -Token $token -Path "zones/$zoneId/dns_records" -Body $desired.Body | Out-Null
    }

    $existingRecords = @(Get-DnsRecords -Token $token -ZoneId $zoneId)
}

Write-Host "Cloudflare DNS records are prepared. Now set Squarespace nameservers to eric.ns.cloudflare.com and sky.ns.cloudflare.com, then run:"
Write-Host "  .\scripts\complete-cloudflare-cutover.ps1 -WaitForDns"
