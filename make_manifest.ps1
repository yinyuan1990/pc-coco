# ============================================================================
# S43 manifest generator for differential updates (called by pack.bat)
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File make_manifest.ps1 `
#       -ReleaseDir D:\javafx\Acard\aic\Aifs\release -Version 8.2.1
#
# Output:
#   1. <ReleaseDir>\manifest.json      - per-file path/size/sha256 (client diff)
#   2. <script dir>\hjversion_new.json - template for updatesoft/hjversion.json
#
# Publish: upload the whole ReleaseDir (including manifest.json) to
#          aihj server /opt/yql/www/soft/v<Version>/
#          (public: https://update.cocoaihj.com/updatesoft/v<Version>/)
#          then update /opt/yql/www/soft/hjversion.json from hjversion_new.json
#          (2026-08-14: client switched from yqlversion.json to hjversion.json
#           because some CDN nodes cached a stale 8.3.7 copy and ignored ?v=)
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 parses BOM-less
#       UTF-8 as ANSI and non-ASCII chars break the script.
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$ReleaseDir,
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$BaseUrlTemplate = "https://update.cocoaihj.com/updatesoft/v{VERSION}"
)

$ErrorActionPreference = "Stop"
$baseUrl    = $BaseUrlTemplate.Replace("{VERSION}", $Version)
$releaseDir = (Resolve-Path $ReleaseDir).Path.TrimEnd('\')

Write-Host "[manifest] scanning $releaseDir ..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$files = New-Object System.Collections.ArrayList
$totalBytes = [long]0
Get-ChildItem -Path $releaseDir -Recurse -File |
    Where-Object { $_.Name -ne 'manifest.json' } |
    ForEach-Object {
        $rel  = $_.FullName.Substring($releaseDir.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLower()
        [void]$files.Add([ordered]@{ path = $rel; size = $_.Length; sha256 = $hash })
        $totalBytes += $_.Length
    }

if ($files.Count -eq 0) {
    Write-Error "[manifest] no files under $releaseDir"
    exit 1
}

$manifest = [ordered]@{
    version     = $Version
    baseUrl     = $baseUrl
    generatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    totalBytes  = $totalBytes
    files       = $files
}

$utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
$manifestPath = Join-Path $releaseDir 'manifest.json'
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), $utf8NoBom)

# hjversion.json template: keep downloadUrl/updateMode so old clients
# (that do not understand manifestUrl) fall back to legacy full-zip update.
$hj = [ordered]@{
    version     = $Version
    manifestUrl = "$baseUrl/manifest.json"
    changelog   = "1. TODO: fill in changelog"
    forceUpdate = $false
    downloadUrl = "https://update.cocoaihj.com/updatesoft/release.zip"
    updateMode  = 1
}
$hjPath = Join-Path $PSScriptRoot 'hjversion_new.json'
[System.IO.File]::WriteAllText($hjPath, ($hj | ConvertTo-Json), $utf8NoBom)

$sw.Stop()
Write-Host ("[manifest] done: {0} files, {1:N1} MB, {2:N1}s" -f $files.Count, ($totalBytes/1MB), $sw.Elapsed.TotalSeconds)
Write-Host "[manifest]   -> $manifestPath"
Write-Host "[manifest]   -> $hjPath (fill changelog, then overwrite server hjversion.json)"
Write-Host "[manifest] upload the whole ReleaseDir to $baseUrl/"
