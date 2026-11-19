<#
.SYNOPSIS
    Quick checker for rule JSON files. PowerShell 7 only (uses Test-Json).
    The real loader (Private/RuleLoader.ps1) does the full validation; this is for rule authors.
.EXAMPLE
    pwsh -NoProfile -File tests/Test-RuleFiles.ps1 -Platform windows
#>
[CmdletBinding()]
param(
    [ValidateSet('windows', 'macos', 'linux')][string]$Platform = 'windows'
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core') { Write-Output 'Run this with pwsh (PowerShell 7).'; exit 2 }

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$schema = Join-Path $root 'schemas/rule.schema.json'
$dir = Join-Path $root ('src/Vacate/rules/' + $Platform)
Import-Module (Join-Path $root 'src/Vacate/Vacate.psm1') -Force
$tokens = & (Get-Module Vacate) { $script:VacateRootTokens }

$files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name)
$bad = 0
$ids = @{}
foreach ($f in $files) {
    $problems = New-Object System.Collections.Generic.List[string]
    $text = [IO.File]::ReadAllText($f.FullName)
    if ($text -match '[^\x00-\x7F]') { $problems.Add('non-ASCII characters') }
    $ok = $false
    try { $ok = Test-Json -Json $text -SchemaFile $schema -ErrorAction Stop } catch { $problems.Add('schema: ' + $_.Exception.Message) }
    if ($ok) {
        $r = $text | ConvertFrom-Json
        if ($f.BaseName -cne $r.id) { $problems.Add("file name must equal id '$($r.id)'") }
        if ($ids.ContainsKey($r.id)) { $problems.Add('duplicate id') } else { $ids[$r.id] = $true }
        if (@($r.platforms) -notcontains $Platform) { $problems.Add("platforms must include '$Platform'") }
        if ($r.locator.kind -eq 'path') {
            foreach ($p in @($r.platforms)) {
                if ($tokens[$p] -notcontains $r.locator.root) { $problems.Add("root '$($r.locator.root)' not defined for $p") }
            }
            foreach ($seg in ($r.locator.path -split '/')) {
                if ($seg -eq '..' -or $seg -eq '.' -or $seg -eq '**') { $problems.Add("bad segment '$seg'") }
            }
        }
        if ($r.verified -and @($r.verifiedOn).Count -eq 0) { $problems.Add('verified=true needs verifiedOn') }
    }
    if ($problems.Count -gt 0) {
        $bad++
        Write-Output ('FAIL {0}: {1}' -f $f.Name, ($problems -join '; '))
    }
}
Write-Output ('RULES platform={0} files={1} failed={2}' -f $Platform, $files.Count, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
