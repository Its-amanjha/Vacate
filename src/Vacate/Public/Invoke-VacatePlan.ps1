# Invoke-VacatePlan.ps1 - public: Phase 2 cleanup plan from a saved run (DECISIONS D48).
# PowerShell 5.1 compatible. ASCII only. Reads report.json; writes plan.* into the same run
# folder through Output.ps1. Never scans, never changes anything else.

function Invoke-VacatePlan {
    <#
    .SYNOPSIS
        Writes plan.json, plan.md and plan.html into a run folder. Returns the written paths.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Run,
        [datetime]$Now = [datetime]::UtcNow
    )
    $runDir = [IO.Path]::GetFullPath($Run)
    $jsonPath = [IO.Path]::Combine($runDir, 'report.json')
    if (-not [IO.File]::Exists($jsonPath)) { throw "No report.json in $runDir" }
    $report = ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText($jsonPath))
    $platform = [string]$report.scan.platform
    if ($script:VacatePlatforms -cnotcontains $platform) { throw "report.json has an unknown platform '$platform'." }

    $set = Import-VacateRuleSet -Path $script:VacateRulesRoot -Platform $platform
    $plan = New-VacatePlan -Report $report -Rules @($set.Rules) -Now $Now

    $base = [IO.Path]::GetDirectoryName($runDir)
    $targets = [ordered]@{
        'plan.json' = (ConvertTo-VacateReportJson -Report $plan)
        'plan.md'   = (ConvertTo-VacatePlanMarkdown -Plan $plan)
        'plan.html' = (ConvertTo-VacatePlanHtml -Plan $plan)
    }
    $written = New-Object System.Collections.Generic.List[string]
    foreach ($k in $targets.Keys) {
        $p = [IO.Path]::Combine($runDir, $k)
        if ($PSCmdlet.ShouldProcess($p, 'Write')) { Write-VacateTextFile -BaseDir $base -Path $p -Text $targets[$k]; $written.Add($p) }
    }
    return $written.ToArray()
}
