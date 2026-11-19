# Get-VacateRule.ps1 - public: list, show and validate the rule catalog.
# PowerShell 5.1 compatible. ASCII only.

function Get-VacateRule {
    <#
    .SYNOPSIS
        Lists rules (all platforms, or one), or shows one rule by id.
    .EXAMPLE
        Get-VacateRule -Platform windows
        Get-VacateRule -Id browser.chrome.history
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$Id,
        [ValidateSet('windows', 'macos', 'linux')][string]$Platform,
        [string]$RulesPath = $script:VacateRulesRoot
    )
    $set = Import-VacateRuleSet -Path $RulesPath
    $rules = @($set.Rules)
    if ($Platform) { $rules = @($rules | Where-Object { @($_.platforms) -ccontains $Platform }) }
    if ($Id) { $rules = @($rules | Where-Object { $_.id -ceq $Id }) }
    return $rules
}

function Test-VacateRuleCatalog {
    <#
    .SYNOPSIS
        Validates every rule file. Returns a result object; Passed is $true only with zero errors.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$RulesPath = $script:VacateRulesRoot)
    $set = Import-VacateRuleSet -Path $RulesPath
    $counts = [ordered]@{}
    foreach ($p in $script:VacatePlatforms) {
        $counts[$p] = @($set.Rules | Where-Object { @($_.platforms) -ccontains $p }).Count
    }
    $unverified = @($set.Rules | Where-Object { -not $_.verified }).Count
    return [pscustomobject][ordered]@{
        Passed     = (@($set.Errors).Count -eq 0)
        Files      = $set.FileCount
        Valid      = @($set.Rules).Count
        Invalid    = @($set.Errors).Count
        ByPlatform = [pscustomobject]$counts
        Unverified = $unverified
        Errors     = @($set.Errors)
    }
}

function ConvertTo-VacateRulesMarkdown {
    <#
    .SYNOPSIS
        Generates RULES.md text from the catalog (one table per platform, sorted by id).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RulesPath = $script:VacateRulesRoot)
    $set = Import-VacateRuleSet -Path $RulesPath
    $nl = "`n"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('# Rule catalog' + $nl + $nl)
    [void]$sb.Append('Generated from `src/Vacate/rules/` by `tools/Update-RulesDoc.ps1`. Do not edit by hand.' + $nl + $nl)
    [void]$sb.Append('`verified` means the location was confirmed on a real machine of that platform. Unverified rules still run; the report lists them.' + $nl + $nl)
    $names = @{ windows = 'Windows'; macos = 'macOS'; linux = 'Linux' }
    foreach ($p in $script:VacatePlatforms) {
        $rules = @($set.Rules | Where-Object { @($_.platforms) -ccontains $p })
        $ver = @($rules | Where-Object { $_.verified }).Count
        [void]$sb.Append(('## {0} ({1} rules, {2} verified)' -f $names[$p], $rules.Count, $ver) + $nl + $nl)
        if ($rules.Count -eq 0) { [void]$sb.Append('_No rules yet._' + $nl + $nl); continue }
        [void]$sb.Append('| id | category | sensitivity | locator | elevation | verified |' + $nl)
        [void]$sb.Append('|---|---|---|---|---|---|' + $nl)
        foreach ($r in $rules) {
            $l = $r.locator
            switch ([string]$l.kind) {
                'path' { $loc = '`' + $l.root + '/' + $l.path + '`' }
                'registry' { $loc = '`' + $l.hive + '\' + $l.key + '`' }
                'wmi' { $loc = '`' + $l.namespace + ':' + $l.className + '`' }
                'installed-program' { $loc = 'uninstall keys (' + $l.scope + ')' }
                'system-query' { $loc = 'system query `' + $l.name + '`' }
                default { $loc = [string]$l.kind }
            }
            $elev = 'no'; if ($r.requiresElevation) { $elev = 'yes' }
            $v = 'no'; if ($r.verified) { $v = 'yes (' + (@($r.verifiedOn) -join ', ') + ')' }
            [void]$sb.Append(('| `{0}` | {1} | {2} | {3} | {4} | {5} |' -f $r.id, $r.category, $r.sensitivity, $loc.Replace('|', '\|'), $elev, $v) + $nl)
        }
        [void]$sb.Append($nl)
    }
    if (@($set.Errors).Count -gt 0) {
        [void]$sb.Append('## Invalid files' + $nl + $nl)
        foreach ($e in $set.Errors) { [void]$sb.Append('- `' + [IO.Path]::GetFileName($e.File) + '`: ' + ($e.Problems -join '; ') + $nl) }
    }
    return $sb.ToString()
}
