<#
.SYNOPSIS
    Runs the release ZIP smoke test (tests/release/ReleaseSmoke.Tests.ps1) on this machine.
.DESCRIPTION
    Wrapper so the same single-file command works on Windows PowerShell 5.1, pwsh 7 and WSL:
    -File cannot carry arrays, and Pester cannot take a container parameter, so the ZIP path
    travels in VACATE_RELEASE_ZIP (set from -ZipPath when given). Build one ZIP with pwsh and
    pass it to all three engines so they test the same bytes.
.EXAMPLE
    pwsh -NoProfile -File tests/release/Invoke-ReleaseSmoke.ps1 -ZipPath dist/vacate-0.1.0.zip
.EXAMPLE
    wsl -d Ubuntu-24.04 -- env VACATE_RELEASE_ZIP=/mnt/f/vacate/dist/vacate-0.1.0.zip /snap/bin/pwsh -NoProfile -File /mnt/f/vacate/tests/release/Invoke-ReleaseSmoke.ps1
#>
[CmdletBinding()]
param(
    # Release ZIP to test. Defaults to $env:VACATE_RELEASE_ZIP; with neither, the test builds one.
    [string]$ZipPath,
    [string]$Output = 'Normal'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($ZipPath) {
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "release ZIP not found: $ZipPath" }
    $env:VACATE_RELEASE_ZIP = (Resolve-Path -LiteralPath $ZipPath).Path
}

Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Force

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $here 'ReleaseSmoke.Tests.ps1'
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.Output.Verbosity = $Output

$result = Invoke-Pester -Configuration $config
Write-Output ('SUMMARY [{0} {1}] passed={2} failed={3} skipped={4}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion.ToString(), $result.PassedCount, $result.FailedCount, $result.SkippedCount)
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
exit 0
