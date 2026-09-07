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

# Pinned version AND pinned checksum. tools/fetch-arch-iso.sh verifies the ISO
# it downloads; a linter binary that gates every commit deserves the same
# treatment. Override the version and you must supply the matching hash - there
# is deliberately no way to skip the check.
$version = if ($env:ARCHWRIGHT_SHELLCHECK_VERSION) { $env:ARCHWRIGHT_SHELLCHECK_VERSION } else { 'v0.10.0' }
$expected = if ($env:ARCHWRIGHT_SHELLCHECK_SHA256) { $env:ARCHWRIGHT_SHELLCHECK_SHA256 } else { 'eb6cd53a54ea97a56540e9d296ce7e2fa68715aa507ff23574646c1e12b2e143' }

if ($env:ARCHWRIGHT_SHELLCHECK_VERSION -and -not $env:ARCHWRIGHT_SHELLCHECK_SHA256) {
  throw "ARCHWRIGHT_SHELLCHECK_VERSION was set without ARCHWRIGHT_SHELLCHECK_SHA256. Pin the checksum for the version you are asking for."
}

$url = "https://github.com/koalaman/shellcheck/releases/download/$version/shellcheck-$version.zip"

Write-Host "Downloading shellcheck $version ..."
$zip = Join-Path $tools 'shellcheck.zip'
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
if ($actual -ne $expected.ToLower()) {
  Remove-Item $zip -Force
  throw "CHECKSUM MISMATCH for shellcheck ${version}: expected $expected, got $actual"
}
Write-Host "sha256 verified"

Expand-Archive -Path $zip -DestinationPath $dest -Force
Remove-Item $zip -Force

$found = Get-ChildItem -Path $dest -Recurse -Filter 'shellcheck.exe' | Select-Object -First 1
if (-not $found) { throw "archive did not contain shellcheck.exe" }
if ($found.FullName -ne $exe) { Move-Item $found.FullName $exe -Force }

& $exe --version
Write-Host "OK: $exe"
