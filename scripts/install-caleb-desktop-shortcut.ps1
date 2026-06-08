$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$uploader = Join-Path $PSScriptRoot "caleb-sermon-upload.ps1"
$desktop = [Environment]::GetFolderPath("DesktopDirectory")
$shortcutPath = Join-Path $desktop "Upload FCC Sermon.lnk"
$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $uploader)) {
    throw "Uploader script not found: $uploader"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$uploader`""
$shortcut.WorkingDirectory = $root
$shortcut.WindowStyle = 1
$shortcut.Description = "Upload a Fillmore Christian Church sermon to the website and podcast feeds"
$shortcut.IconLocation = "$powershell,0"
$shortcut.Save()

Write-Host "Created desktop shortcut:"
Write-Host $shortcutPath
Write-Host ""
Write-Host "Double-click 'Upload FCC Sermon' on the desktop to run the guided uploader."
