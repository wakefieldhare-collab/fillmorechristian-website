param(
    [string]$BuildOutputDir = "dist",
    [int]$Port = 8788,
    [int]$TimeoutSeconds = 45,
    [string]$CompatibilityDate = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$buildOutputPath = Join-Path $root $BuildOutputDir
$wranglerConfigPath = Join-Path $root "wrangler.toml"
$wrangler = Get-Command wrangler -ErrorAction Stop
$logDir = Join-Path $env:TEMP "fillmore-cloudflare-pages-test"
$stdoutPath = Join-Path $logDir "wrangler-pages-dev.out.log"
$stderrPath = Join-Path $logDir "wrangler-pages-dev.err.log"
$persistPath = Join-Path $logDir "state"
$workspaceWranglerPath = Join-Path $root ".wrangler"
$hadWorkspaceWrangler = Test-Path -LiteralPath $workspaceWranglerPath

function Stop-ProcessTree {
    param([int]$ProcessId)

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-CloudflareDevByPort {
    param([int]$Port)

    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
        if ($processInfo -and $processInfo.CommandLine -match "wrangler|workerd") {
            Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-NoRedirect {
    param(
        [string]$Url,
        [string]$Method = "GET"
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Headers = $response.Headers
            ContentHeaders = $response.Content.Headers
            Location = $response.Headers.Location
            Content = $content
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Assert-Status {
    param(
        [object]$Response,
        [int[]]$Expected,
        [string]$Name
    )

    if ($Response.StatusCode -notin $Expected) {
        throw "$Name returned HTTP $($Response.StatusCode); expected $($Expected -join " or ")"
    }
}

if (-not (Test-Path -LiteralPath $buildOutputPath)) {
    throw "Build output not found: $buildOutputPath. Run npm run build first."
}

$existingListener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($existingListener.Count -gt 0) {
    throw "Port $Port is already in use. Re-run with a different -Port value."
}

if (-not $CompatibilityDate) {
    if (-not (Test-Path -LiteralPath $wranglerConfigPath)) {
        throw "wrangler.toml not found and no CompatibilityDate was provided."
    }

    $wranglerConfig = Get-Content -Raw -LiteralPath $wranglerConfigPath
    if ($wranglerConfig -notmatch '(?m)^compatibility_date\s*=\s*"([^"]+)"') {
        throw "Could not read compatibility_date from wrangler.toml."
    }

    $CompatibilityDate = $Matches[1]
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $persistPath -Recurse -Force -ErrorAction SilentlyContinue

$arguments = @(
    "pages",
    "dev",
    $buildOutputPath,
    "--ip",
    "127.0.0.1",
    "--port",
    $Port,
    "--compatibility-date",
    $CompatibilityDate,
    "--persist-to",
    $persistPath,
    "--show-interactive-dev-session",
    "false"
)

$launcher = $wrangler.Source
$launcherArguments = $arguments
if ([System.IO.Path]::GetExtension($launcher) -eq ".ps1") {
    $launcherArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $launcher
    ) + $arguments
    $launcher = (Get-Command powershell.exe -ErrorAction Stop).Source
}

$process = Start-Process `
    -FilePath $launcher `
    -ArgumentList $launcherArguments `
    -WorkingDirectory $root `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

try {
    $baseUrl = "http://127.0.0.1:$Port"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $ready = $false
    $lastReadyError = ""
    $lastReadyStatus = ""

    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { "" }
            throw "wrangler pages dev exited early. stdout: $stdout stderr: $stderr"
        }

        try {
            $response = Invoke-NoRedirect -Url "$baseUrl/"
            $lastReadyStatus = "HTTP $($response.StatusCode)"
            if ($response.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {
            $lastReadyError = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $ready) {
        throw "wrangler pages dev did not become ready within $TimeoutSeconds seconds. Last status: $lastReadyStatus. Last error: $lastReadyError"
    }

    $checks = New-Object System.Collections.Generic.List[object]

    $homeResponse = Invoke-NoRedirect -Url "$baseUrl/"
    Assert-Status -Response $homeResponse -Expected @(200) -Name "Home page"
    if ($homeResponse.Content -notmatch "Fillmore Christian Church") {
        throw "Home page did not include the church name"
    }
    $checks.Add([pscustomobject]@{ Check = "Home page"; Status = "OK"; Details = "HTTP 200" })

    $legacyQuery = Invoke-NoRedirect -Url "$baseUrl/?post_type=podcasts&p=603"
    Assert-Status -Response $legacyQuery -Expected @(301) -Name "Legacy podcast query redirect"
    if (-not $legacyQuery.Location -or $legacyQuery.Location.ToString() -ne "$baseUrl/episode/be-ready-luke-12/") {
        throw "Legacy podcast query redirect pointed to '$($legacyQuery.Location)'"
    }
    $checks.Add([pscustomobject]@{ Check = "Legacy podcast query redirect"; Status = "OK"; Details = "p=603 -> /episode/be-ready-luke-12/" })

    $prettySermons = Invoke-NoRedirect -Url "$baseUrl/sermons/"
    Assert-Status -Response $prettySermons -Expected @(301, 302, 308) -Name "Pretty sermons redirect"
    if (-not $prettySermons.Location -or $prettySermons.Location.ToString() -notmatch "/sermons\.html$") {
        throw "Pretty sermons redirect pointed to '$($prettySermons.Location)'"
    }
    $checks.Add([pscustomobject]@{ Check = "Pretty sermons redirect"; Status = "OK"; Details = "/sermons/ -> /sermons.html" })

    $feed = Invoke-NoRedirect -Url "$baseUrl/podcast-category/fillmore-christian/feed/podcast"
    Assert-Status -Response $feed -Expected @(200) -Name "Podcast feed"
    $contentType = [string]$feed.ContentHeaders.ContentType
    if ($contentType -notmatch "application/rss\+xml") {
        throw "Podcast feed returned unexpected content type '$contentType'"
    }
    if ($feed.Content -notmatch "<rss\b" -or $feed.Content -notmatch "Fillmore Christian") {
        throw "Podcast feed did not look like the Fillmore Christian RSS feed"
    }
    $checks.Add([pscustomobject]@{ Check = "Podcast feed"; Status = "OK"; Details = "RSS content type and XML body" })

    $episode = Invoke-NoRedirect -Url "$baseUrl/episode/be-ready-luke-12/"
    Assert-Status -Response $episode -Expected @(200) -Name "Static episode page"
    if ($episode.Content -notmatch "<audio\s+controls" -or $episode.Content -notmatch "Download Audio" -or $episode.Content -notmatch "All Sermons" -or $episode.Content -notmatch 'class="episode-nav"' -or $episode.Content -notmatch "Newer Message" -or $episode.Content -notmatch "Older Message") {
        throw "Static episode page is missing audio, download, archive navigation, or episode navigation"
    }
    $checks.Add([pscustomobject]@{ Check = "Static episode page"; Status = "OK"; Details = "Audio player, download, archive navigation, and episode navigation" })

    $checks | Format-Table -AutoSize
} finally {
    Stop-ProcessTree -ProcessId $process.Id
    Stop-CloudflareDevByPort -Port $Port
    Remove-Item -LiteralPath $persistPath -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $hadWorkspaceWrangler) {
        Remove-Item -LiteralPath $workspaceWranglerPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
