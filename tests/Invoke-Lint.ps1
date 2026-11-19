<#
.SYNOPSIS
    Runs PSScriptAnalyzer over the repo with the project settings. Exit 1 if any issue.
.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-Lint.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$issues = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings $settings)
foreach ($i in $issues) {
    Write-Output ('{0}:{1} {2} {3}' -f $i.ScriptName, $i.Line, $i.RuleName, $i.Message)
}
Write-Output ('LINT issues={0}' -f $issues.Count)
if ($issues.Count -gt 0) { exit 1 }
exit 0
