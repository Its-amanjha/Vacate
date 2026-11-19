<#
.SYNOPSIS
    Runs PSScriptAnalyzer over the repo with the project settings. Exit 1 if any issue.
.DESCRIPTION
    Source code gets every rule. Test files additionally allow PSReviewUnusedParameter, because
    fakes must accept the same parameters as the real function even when they ignore some.
.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-Lint.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$testsDir = Join-Path $root 'tests'

$issues = New-Object System.Collections.Generic.List[object]
foreach ($i in @(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings $settings)) {
    $isTest = $i.ScriptPath -and $i.ScriptPath.StartsWith($testsDir, [StringComparison]::OrdinalIgnoreCase)
    if ($isTest -and $i.RuleName -eq 'PSReviewUnusedParameter') { continue }
    $issues.Add($i)
}
foreach ($i in $issues) {
    Write-Output ('{0}:{1} {2} {3}' -f $i.ScriptName, $i.Line, $i.RuleName, $i.Message)
}
Write-Output ('LINT issues={0}' -f $issues.Count)
if ($issues.Count -gt 0) { exit 1 }
exit 0
