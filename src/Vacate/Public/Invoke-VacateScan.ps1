# Invoke-VacateScan.ps1 - public: scan this machine and re-render saved runs.
# PowerShell 5.1 compatible. ASCII only.

function New-VacateScanContext {
    # Production context. Fixed roots; there is no override flag.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Platform,
        [Parameter(Mandatory)][bool]$Elevated,
        [AllowEmptyCollection()][string[]]$Exclude = @()
    )
    $name = [string]$Platform.Name
    $registry = $null
    $cim = $null
    if ($name -ceq 'windows') {
        $registry = New-VacateRegistryProvider -RegistryBase @{ HKCU = @{ Hive = 'HKCU'; Prefix = '' }; HKLM = @{ Hive = 'HKLM'; Prefix = '' } }
        $cim = New-VacateCimRunner
    }
    # Bound to this module so it can call module-private functions. GetNewClosure() would lose the
    # module scope (it broke the first Linux scan). The platform name comes from the fixed detector.
    $sq = $ExecutionContext.SessionState.Module.NewBoundScriptBlock({ param([string]$QueryName) Invoke-VacateSystemQuery -Name $QueryName -Platform (Get-VacatePlatform) })
    $mounts = @()
    if ($name -ceq 'linux') {
        $m = & $sq 'mounts'
        if ($m.Status -ceq 'ok') { $mounts = @($m.Value | ForEach-Object { [string]$_.target } | Where-Object { $_ }) }
    }
    return [pscustomobject][ordered]@{
        Platform    = $Platform
        FileSystem  = (New-VacateFileSystemProvider)
        Registry    = $registry
        Cim         = $cim
        SystemQuery = $sq
        Elevated    = $Elevated
        MountPoints = $mounts
        Exclude     = $Exclude
    }
}

function Write-VacateRunOutput {
    # Writes report.json, report.html, summary.md, checklist.md and scan.log into RunDir.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][object]$Report,
        [AllowEmptyCollection()][string[]]$Log = @()
    )
    $checklist = @(Get-VacateChecklist -Report $Report)
    $files = [ordered]@{
        'report.json'  = (ConvertTo-VacateReportJson -Report $Report)
        'report.html'  = (ConvertTo-VacateReportHtml -Report $Report -Checklist $checklist)
        'summary.md'   = (ConvertTo-VacateSummaryMarkdown -Report $Report)
        'checklist.md' = (ConvertTo-VacateChecklistMarkdown -Report $Report -Checklist $checklist)
    }
    if (@($Log).Count -gt 0 -or -not [IO.File]::Exists([IO.Path]::Combine($RunDir, 'scan.log'))) {
        $files['scan.log'] = (($Log -join "`n") + "`n")
    }
    foreach ($k in $files.Keys) {
        if ($PSCmdlet.ShouldProcess($k, 'Write')) {
            Write-VacateTextFile -BaseDir $BaseDir -Path ([IO.Path]::Combine($RunDir, $k)) -Text $files[$k]
        }
    }
}

function Invoke-VacateScan {
    <#
    .SYNOPSIS
        Scans this machine (read-only) and writes a run folder. Returns the run folder path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [int]$BudgetSeconds = $script:VacateDefaultBudgetSeconds,
        [switch]$Redact,
        [switch]$Elevated,
        [switch]$AllowRoot,
        [Parameter(Mandatory)][string]$ToolRoot
    )
    $started = [datetime]::UtcNow
    $platformName = Get-VacatePlatform
    $envSnap = Get-VacateEnvironmentSnapshot
    $vprofile = Get-VacatePlatformProfile -Platform $platformName -Environment $envSnap
    $isAdmin = Test-VacateElevated -Platform $platformName

    if ($platformName -cne 'windows' -and $isAdmin -and -not $AllowRoot) {
        throw 'vacate refuses to run as root: root can read other users'' data. Run as your normal user, or pass -AllowRoot if you really mean it.'
    }
    if ($Elevated -and -not $isAdmin) {
        throw '-Elevated was passed but this session is not elevated. vacate never elevates itself; start an elevated shell first.'
    }
    $useElevated = ($Elevated -and $isAdmin)
    if ($platformName -cne 'windows' -and $isAdmin -and $AllowRoot) { $useElevated = $true }

    $toolFull = [IO.Path]::GetFullPath($ToolRoot)
    $runsBase = [IO.Path]::Combine($toolFull, 'runs')
    $exclude = @($toolFull, $runsBase)
    $ctx = New-VacateScanContext -Platform $vprofile -Elevated $useElevated -Exclude $exclude

    $set = Import-VacateRuleSet -Path $script:VacateRulesRoot -Platform $platformName
    $log = New-Object System.Collections.Generic.List[string]
    $log.Add(('vacate {0} scan on {1}; elevated={2}; rules={3}; not-applicable={4}; invalid-files={5}' -f $script:VacateToolVersion, $platformName, $useElevated, @($set.Rules).Count, @($set.NotApplicable).Count, @($set.Errors).Count))
    foreach ($e in @($set.Errors)) { $log.Add('invalid rule file ' + [IO.Path]::GetFileName($e.File) + ': ' + ($e.Problems -join '; ')) }

    $result = Invoke-VacateEngine -Rules @($set.Rules) -Context $ctx -BudgetSeconds $BudgetSeconds -RuleTimeoutSeconds $script:VacateDefaultRuleTimeoutSeconds
    foreach ($l in @($result.Log)) { $log.Add($l) }
    $hostInfo = Get-VacateHostInfo -Context $ctx -Environment $envSnap
    $finished = [datetime]::UtcNow

    $report = New-VacateReport -EngineResult $result -Rules @($set.Rules) -NotApplicable @($set.NotApplicable).Count -InvalidFiles @($set.Errors).Count -Platform $platformName -HostInfo $hostInfo -StartedAt $started -FinishedAt $finished -Elevated $useElevated -BudgetSeconds $BudgetSeconds -RuleTimeoutSeconds $script:VacateDefaultRuleTimeoutSeconds
    $logLines = $log.ToArray()
    if ($Redact) {
        $report = Protect-VacateReport -Report $report
        # The log can contain raw paths and names; a redacted run keeps only the first summary line.
        $logLines = @($logLines[0], 'log details omitted because -Redact was used')
    }

    # New-VacateRunFolder (Output.ps1, the only writer) creates runs/ and the run folder together.
    $runDir = New-VacateRunFolder -BaseDir $runsBase -Now $finished
    Write-VacateRunOutput -BaseDir $runsBase -RunDir $runDir -Report $report -Log $logLines
    return $runDir
}

function Export-VacateRun {
    <#
    .SYNOPSIS
        Re-renders report.html, summary.md and checklist.md from a run folder's report.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Run,
        [ValidateSet('report', 'checklist')][string]$What = 'report'
    )
    $runDir = [IO.Path]::GetFullPath($Run)
    $jsonPath = [IO.Path]::Combine($runDir, 'report.json')
    if (-not [IO.File]::Exists($jsonPath)) { throw "No report.json in $runDir" }
    $report = ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText($jsonPath))
    $base = [IO.Path]::GetDirectoryName($runDir)
    $checklist = @(Get-VacateChecklist -Report $report)
    $written = New-Object System.Collections.Generic.List[string]
    $targets = [ordered]@{}
    if ($What -ceq 'report') {
        $targets['report.html'] = (ConvertTo-VacateReportHtml -Report $report -Checklist $checklist)
        $targets['summary.md'] = (ConvertTo-VacateSummaryMarkdown -Report $report)
    }
    $targets['checklist.md'] = (ConvertTo-VacateChecklistMarkdown -Report $report -Checklist $checklist)
    foreach ($k in $targets.Keys) {
        $p = [IO.Path]::Combine($runDir, $k)
        if ($PSCmdlet.ShouldProcess($p, 'Write')) { Write-VacateTextFile -BaseDir $base -Path $p -Text $targets[$k]; $written.Add($p) }
    }
    return $written.ToArray()
}
