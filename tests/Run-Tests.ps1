<#
.SYNOPSIS
    Runs the Pester 5 suite. Works on Windows PowerShell 5.1 and PowerShell 7 (Windows/Linux/macOS).
.EXAMPLE
    powershell -NoProfile -File tests/Run-Tests.ps1
    pwsh -NoProfile -File tests/Run-Tests.ps1 -Path tests/unit/PathJail.Tests.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$Output = 'Normal'
)

$ErrorActionPreference = 'Stop'
# 5.1: $PSScriptRoot is empty inside param() defaults, so resolve here.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Path) { $Path = @((Join-Path $here 'unit'), (Join-Path $here 'integration'), (Join-Path $here 'safety')) }
Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Force

$existing = @($Path | Where-Object { Test-Path -LiteralPath $_ })
if ($existing.Count -eq 0) { Write-Output 'No test paths found.'; exit 1 }

$config = New-PesterConfiguration
$config.Run.Path = $existing
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.Output.Verbosity = $Output
# tests/release/ smoke-tests a built ZIP and needs one (or pwsh 7 to build it). It is tagged
# Release so a broad -Path (for example tests) cannot pull it into the normal suite. Run it
# with tests/release/Invoke-ReleaseSmoke.ps1.
$config.Filter.ExcludeTag = 'Release'

$result = Invoke-Pester -Configuration $config
$edition = $PSVersionTable.PSEdition
$ver = $PSVersionTable.PSVersion.ToString()
Write-Output ("SUMMARY [{0} {1}] passed={2} failed={3} skipped={4}" -f $edition, $ver, $result.PassedCount, $result.FailedCount, $result.SkippedCount)
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
exit 0
