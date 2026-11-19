<#
.SYNOPSIS
    Regenerates RULES.md from the rule catalog. Development helper; writes only RULES.md.
.EXAMPLE
    pwsh -NoProfile -File tools/Update-RulesDoc.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'src/Vacate/Vacate.psm1') -Force
$md = & (Get-Module Vacate) { ConvertTo-VacateRulesMarkdown }
[IO.File]::WriteAllText((Join-Path $root 'RULES.md'), $md, (New-Object Text.UTF8Encoding $false))
Write-Output 'RULES.md updated'
