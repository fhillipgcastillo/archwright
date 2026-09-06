#!/usr/bin/env pwsh
# Portable shellcheck into .tools/. Nothing installed system-wide, nothing
# added to PATH. Delete .tools/ to undo completely.
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root '.tools'
$dest  = Join-Path $tools 'shellcheck'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$exe = Join-Path $dest 'shellcheck.exe'
if (Test-Path $exe) { Write-Host "shellcheck already present: $exe"; exit 0 }

$version = if ($env:ARCHWRIGHT_SHELLCHECK_VERSION) { $env:ARCHWRIGHT_SHELLCHECK_VERSION } else { 'v0.10.0' }
$url = "https://github.com/koalaman/shellcheck/releases/download/$version/shellcheck-$version.zip"

Write-Host "Downloading shellcheck $version ..."
$zip = Join-Path $tools 'shellcheck.zip'
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $dest -Force
Remove-Item $zip -Force

$found = Get-ChildItem -Path $dest -Recurse -Filter 'shellcheck.exe' | Select-Object -First 1
if (-not $found) { throw "archive did not contain shellcheck.exe" }
if ($found.FullName -ne $exe) { Move-Item $found.FullName $exe -Force }

& $exe --version
Write-Host "OK: $exe"
