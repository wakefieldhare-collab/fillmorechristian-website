param(
    [string]$Domain = "fillmorechristian.org",
    [string]$ProductionBaseUrl = "https://www.fillmorechristian.org",
    [string]$ApexBaseUrl = "https://fillmorechristian.org",
    [string[]]$ExpectedCloudflareNameservers = @("eric.ns.cloudflare.com", "sky.ns.cloudflare.com"),
    [switch]$WaitForDns,
    [int]$MaxAttempts = 30,
    [int]$DelaySeconds = 60,
    [switch]$VerifyAllPodcastMedia,
    [int]$PodcastMediaSampleCount = 5,
    [int]$TimeoutSec = 20,
    [string]$ReportDir = "exports\cutover",
    [int]$MaxReportOutputLines = 1200
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")

function Join-Url {
    param([string]$Base, [string]$Path)
    return $Base.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Format-CommandForReport {
    param([string]$ScriptPath, [string[]]$Arguments)

    $parts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $ScriptPath
    ) + @($Arguments)

    return ($parts | ForEach-Object { Format-ProcessArgument $_ }) -join " "
}

function Format-ProcessArgument {
    param([string]$Argument)

    $value = [string]$Argument
    if ($value -match '[\s"]') {
        return '"' + ($value -replace '"', '\"') + '"'
    }

    return $value
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)

    return "'" + ([string]$Value -replace "'", "''") + "'"
}

function ConvertTo-PowerShellValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-PowerShellValue $_ })
        return "@($($items -join ', '))"
    }

    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }

    if ($Value -is [int]) {
        return [string]$Value
    }

    return ConvertTo-PowerShellLiteral ([string]$Value)
}

function New-InvocationCommand {
    param(
        [string]$ScriptPath,
        [System.Collections.Specialized.OrderedDictionary]$Parameters
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Missing verifier script: $ScriptPath"
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("& $(ConvertTo-PowerShellLiteral $ScriptPath)")
    foreach ($entry in $Parameters.GetEnumerator()) {
        $parts.Add("-$($entry.Key)")
        if ($entry.Value -is [bool]) {
            if (-not $entry.Value) {
                $parts.RemoveAt($parts.Count - 1)
            }
            continue
        }
        $parts.Add((ConvertTo-PowerShellValue $entry.Value))
    }

    return ($parts -join " ")
}

function Invoke-VerificationStep {
    param(
        [string]$Name,
        [string]$CommandText
    )

    $startedAt = Get-Date
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $wrappedCommand = @"
`$ProgressPreference = 'SilentlyContinue'
try {
    & { $CommandText } *>&1
    if (`$LASTEXITCODE -is [int] -and `$LASTEXITCODE -ne 0) {
        exit `$LASTEXITCODE
    }
    exit 0
} catch {
    `$_ | Out-String
    exit 1
}
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrappedCommand))
        $process = Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-NonInteractive", "-OutputFormat", "Text", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $output = @()
        if (Test-Path -LiteralPath $stdoutPath) {
            $output += @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $stderrPath) {
            $stderrOutput = @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)
            if ($stderrOutput.Count -gt 0) {
                $output += @("--- STDERR ---")
                $output += $stderrOutput
            }
        }
        $exitCode = $process.ExitCode
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    $finishedAt = Get-Date
    $reportOutput = Limit-ReportOutput -Lines $output

    return [pscustomobject]@{
        Name = $Name
        Status = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
        ExitCode = $exitCode
        StartedAt = $startedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        FinishedAt = $finishedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        DurationSeconds = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 2)
        Command = "powershell -NoProfile -ExecutionPolicy Bypass -Command $(Format-ProcessArgument $CommandText)"
        Output = $reportOutput
        OutputLineCount = $output.Count
        OutputWasTruncated = $output.Count -gt $reportOutput.Count
    }
}

function Add-NameserverParameter {
    param([System.Collections.Specialized.OrderedDictionary]$Parameters)
    if ($ExpectedCloudflareNameservers.Count -gt 0) {
        $Parameters["ExpectedCloudflareNameservers"] = @($ExpectedCloudflareNameservers)
    }
}

function ConvertTo-MarkdownFenceText {
    param([string[]]$Lines)

    if ($Lines.Count -eq 0) {
        return "(no output)"
    }

    return ($Lines -join "`n")
}

function Limit-ReportOutput {
    param([string[]]$Lines)

    if ($MaxReportOutputLines -lt 50) {
        throw "MaxReportOutputLines must be at least 50."
    }

    if ($Lines.Count -le $MaxReportOutputLines) {
        return @($Lines)
    }

    $headCount = [Math]::Floor($MaxReportOutputLines / 2)
    $tailCount = $MaxReportOutputLines - $headCount - 1
    $omittedCount = $Lines.Count - $headCount - $tailCount

    return @(
        $Lines | Select-Object -First $headCount
        "[output truncated: $omittedCount line(s) omitted from the middle to keep this cutover report bounded]"
        $Lines | Select-Object -Last $tailCount
    )
}

$reportPath = if ([System.IO.Path]::IsPathRooted($ReportDir)) {
    $ReportDir
} else {
    Join-Path $root $ReportDir
}
New-Item -ItemType Directory -Force -Path $reportPath | Out-Null

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
$markdownReportPath = Join-Path $reportPath "$Domain-production-cutover-$timestamp.md"
$jsonReportPath = Join-Path $reportPath "$Domain-production-cutover-$timestamp.json"

$steps = New-Object System.Collections.Generic.List[object]
$overallStatus = "PASS"

$cutoverParameters = [ordered]@{
    Domain = $Domain
    ProductionBaseUrl = $ProductionBaseUrl
    MaxAttempts = $MaxAttempts
    DelaySeconds = $DelaySeconds
}
Add-NameserverParameter -Parameters $cutoverParameters
if ($WaitForDns) {
    $cutoverParameters["WaitForDns"] = $true
}

$domainTransferParameters = [ordered]@{
    Domain = $Domain
    ProductionBaseUrl = $ProductionBaseUrl
    ApexBaseUrl = $ApexBaseUrl
    ExpectedFeedUrl = (Join-Url $ProductionBaseUrl "podcast-category/fillmore-christian/feed/podcast")
    TimeoutSec = $TimeoutSec
}
Add-NameserverParameter -Parameters $domainTransferParameters

$dnsCacheParameters = [ordered]@{
    Domain = $Domain
    WriteReport = $true
    FailOnStale = $true
}
Add-NameserverParameter -Parameters $dnsCacheParameters

$audioHost = try { ([Uri]$ProductionBaseUrl).Host } catch { "www.$Domain" }
$cancellationParameters = [ordered]@{
    Domain = $Domain
    ProductionBaseUrl = $ProductionBaseUrl
    ApexBaseUrl = $ApexBaseUrl
    ExpectedAudioHost = $audioHost
    PodcastMediaSampleCount = $PodcastMediaSampleCount
    TimeoutSec = $TimeoutSec
}
Add-NameserverParameter -Parameters $cancellationParameters
if ($VerifyAllPodcastMedia) {
    $cancellationParameters["VerifyAllPodcastMedia"] = $true
}

$stepDefinitions = @(
    @{
        Name = "Complete Cloudflare Cutover"
        ScriptPath = Join-Path $PSScriptRoot "complete-cloudflare-cutover.ps1"
        Parameters = $cutoverParameters
    },
    @{
        Name = "Domain Transfer Readiness"
        ScriptPath = Join-Path $PSScriptRoot "test-domain-transfer-readiness.ps1"
        Parameters = $domainTransferParameters
    },
    @{
        Name = "Recursive DNS Cache Drainage"
        ScriptPath = Join-Path $PSScriptRoot "show-dns-cache-status.ps1"
        Parameters = $dnsCacheParameters
    },
    @{
        Name = "TheChurchCo Cancellation Readiness"
        ScriptPath = Join-Path $PSScriptRoot "test-thechurchco-cancellation-readiness.ps1"
        Parameters = $cancellationParameters
    }
)

foreach ($definition in $stepDefinitions) {
    $commandText = New-InvocationCommand -ScriptPath $definition.ScriptPath -Parameters $definition.Parameters
    $result = Invoke-VerificationStep -Name $definition.Name -CommandText $commandText
    $steps.Add($result)
    if ($result.Status -ne "PASS") {
        $overallStatus = "FAIL"
        break
    }
}

$nextAction = if ($overallStatus -eq "PASS") {
    "Production cutover, registrar-transfer safety, recursive DNS cache drainage, and TheChurchCo cancellation gates passed. Keep Squarespace active until the Cloudflare Registrar transfer is visibly underway or complete, then revoke temporary Cloudflare API tokens."
} else {
    "Do not cancel TheChurchCo or disable Squarespace auto-renew yet. Resolve the first failed verifier step, wait for stale recursive DNS caches if needed, and rerun this command."
}

$report = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Domain = $Domain
    ProductionBaseUrl = $ProductionBaseUrl
    ApexBaseUrl = $ApexBaseUrl
    ExpectedCloudflareNameservers = @($ExpectedCloudflareNameservers)
    VerifyAllPodcastMedia = [bool]$VerifyAllPodcastMedia
    OverallStatus = $overallStatus
    NextAction = $nextAction
    Steps = @($steps.ToArray())
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonReportPath -Encoding UTF8

$markdown = New-Object System.Collections.Generic.List[string]
$markdown.Add("# Fillmore Christian Production Cutover Report")
$markdown.Add("")
$markdown.Add("- Generated: $($report.GeneratedAt)")
$markdown.Add("- Domain: $Domain")
$markdown.Add("- Production base URL: $ProductionBaseUrl")
$markdown.Add("- Apex base URL: $ApexBaseUrl")
$markdown.Add("- Expected Cloudflare nameservers: $($ExpectedCloudflareNameservers -join ', ')")
$markdown.Add("- Verify all podcast media: $([bool]$VerifyAllPodcastMedia)")
$markdown.Add("- Overall status: $overallStatus")
$markdown.Add("")
$markdown.Add("## Next Action")
$markdown.Add("")
$markdown.Add($report.NextAction)
$markdown.Add("")
foreach ($step in $steps) {
    $markdown.Add("## $($step.Name)")
    $markdown.Add("")
    $markdown.Add("- Status: $($step.Status)")
    $markdown.Add("- Exit code: $($step.ExitCode)")
    $markdown.Add("- Started: $($step.StartedAt)")
    $markdown.Add("- Finished: $($step.FinishedAt)")
    $markdown.Add("- Duration: $($step.DurationSeconds) seconds")
    $markdown.Add("- Output lines captured: $($step.Output.Count) of $($step.OutputLineCount)")
    $markdown.Add("")
    $markdown.Add('```powershell')
    $markdown.Add($step.Command)
    $markdown.Add('```')
    $markdown.Add("")
    $markdown.Add('```text')
    $markdown.Add((ConvertTo-MarkdownFenceText -Lines $step.Output))
    $markdown.Add('```')
    $markdown.Add("")
}
$markdown | Set-Content -LiteralPath $markdownReportPath -Encoding UTF8

Write-Host "Production cutover report written:"
Write-Host "  $markdownReportPath"
Write-Host "  $jsonReportPath"

if ($overallStatus -ne "PASS") {
    throw "Production cutover verification failed. See report: $markdownReportPath"
}

Write-Host "Production cutover verification passed. Use this report as the final pre-cancellation receipt."
