# Engine.ps1 - runs the rules and assembles the report.
# PowerShell 5.1 compatible. ASCII only.
#
# Rule status (DECISIONS D27), recomputable from report.json alone:
#   failed  = distinct ruleIds in errors[]
#   skipped = distinct ruleIds in skipped[] that are not failed and produced no trace
#   run     = totalRules - failed - skipped
#   complete = no skip has reason 'budget' or 'timeout'

$script:VacateExecutorNames = @{
    'path'              = 'Invoke-VacatePathLocator'
    'registry'          = 'Invoke-VacateRegistryLocator'
    'wmi'               = 'Invoke-VacateWmiLocator'
    'installed-program' = 'Invoke-VacateInstalledProgramLocator'
    'system-query'      = 'Invoke-VacateSystemQueryLocator'
}

function Get-VacateDefaultExecutor {
    # kind -> function name. A name whose function is not loaded maps to $null so the engine
    # records a clear error instead of crashing. Tests pass scriptblocks param($Rule,$Context,$Deadline).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $map = @{}
    foreach ($k in $script:VacateExecutorNames.Keys) {
        $name = $script:VacateExecutorNames[$k]
        if ($null -eq (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) { $map[$k] = $null }
        else { $map[$k] = $name }
    }
    return $map
}

function Invoke-VacateEngine {
    # Runs rules in the given (already sorted) order. Never throws for a rule failure.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][object]$Context,
        [int]$BudgetSeconds = $script:VacateDefaultBudgetSeconds,
        [int]$RuleTimeoutSeconds = $script:VacateDefaultRuleTimeoutSeconds,
        [hashtable]$Executors,
        [scriptblock]$Clock = { [datetime]::UtcNow }
    )
    if ($BudgetSeconds -lt 1) { throw 'engine: BudgetSeconds must be at least 1.' }
    if ($RuleTimeoutSeconds -lt 1) { throw 'engine: RuleTimeoutSeconds must be at least 1.' }
    if ($null -eq $Executors) { $Executors = Get-VacateDefaultExecutor }

    $traces = New-Object System.Collections.Generic.List[object]
    $skips = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $programs = New-Object System.Collections.Generic.List[object]
    $log = New-Object System.Collections.Generic.List[string]

    $start = & $Clock
    $globalDeadline = $start.AddSeconds($BudgetSeconds)
    $platformName = [string]$Context.Platform.Name
    $budgetHit = $false

    foreach ($rule in $Rules) {
        $id = [string]$rule.id
        $now = & $Clock
        if ($budgetHit -or $now -ge $globalDeadline) {
            if (-not $budgetHit) { $log.Add('budget exhausted; remaining rules skipped') }
            $budgetHit = $true
            $skips.Add((New-VacateSkip -RuleId $id -Reason 'budget' -Detail ('Scan time budget of {0} s used up before this rule started.' -f $BudgetSeconds)))
            continue
        }
        if ($rule.requiresElevation -eq $true -and -not $Context.Elevated) {
            $skips.Add((New-VacateSkip -RuleId $id -Reason 'requires-elevation' -Detail 'Needs administrator/root rights; run from an elevated session with -Elevated to include it.'))
            $log.Add("skip $id requires-elevation")
            continue
        }
        $kind = [string]$rule.locator.kind
        if ($kind -ceq 'path') {
            $tok = [string]$rule.locator.root
            if (-not $Context.Platform.Roots.Contains($tok)) {
                $skips.Add((New-VacateSkip -RuleId $id -Reason 'unavailable' -Detail "Root '$tok' is not available on this machine."))
                $log.Add("skip $id unavailable root $tok")
                continue
            }
        }
        $exec = $null
        if ($Executors.ContainsKey($kind)) { $exec = $Executors[$kind] }
        if ($null -eq $exec) {
            $errors.Add((New-VacateError -RuleId $id -Message "No executor for locator kind '$kind'." -Type 'EngineError'))
            $log.Add("error $id no executor for $kind")
            continue
        }

        $ruleDeadline = $now.AddSeconds($RuleTimeoutSeconds)
        if ($ruleDeadline -gt $globalDeadline) { $ruleDeadline = $globalDeadline }
        try {
            if ($exec -is [scriptblock]) { $res = & $exec $rule $Context $ruleDeadline }
            else { $res = & $exec -Rule $rule -Context $Context -Deadline $ruleDeadline }
            foreach ($t in @($res.Traces)) { if ($null -ne $t) { $traces.Add((Select-VacateMeasure -Trace $t -Rule $rule)) } }
            foreach ($s in @($res.Skips)) { if ($null -ne $s) { $skips.Add($s) } }
            foreach ($e in @($res.Errors)) { if ($null -ne $e) { $errors.Add($e) } }
            foreach ($p in @($res.Programs)) { if ($null -ne $p) { $programs.Add($p) } }
            $log.Add(('ran {0}: {1} traces, {2} skips, {3} errors' -f $id, @($res.Traces).Count, @($res.Skips).Count, @($res.Errors).Count))
        }
        catch {
            $errors.Add((New-VacateError -RuleId $id -Message $_.Exception.Message -Type $_.Exception.GetType().Name))
            $log.Add("error $id " + $_.Exception.GetType().Name)
        }
        $after = & $Clock
        if ($after -ge $globalDeadline) { $budgetHit = $true; $log.Add('budget exhausted after ' + $id) }
    }

    # Keep only traces for the current platform's rules; set trace.platform consistently.
    foreach ($t in $traces) { if ($t.platform -cne $platformName) { $t.platform = $platformName } }

    return [pscustomobject][ordered]@{
        Traces   = (Get-VacateOrderedTrace -Trace $traces.ToArray())
        Skips    = (Get-VacateOrderedItem -Item $skips.ToArray() -Key { param($x) [string]$x.ruleId + "`t" + [string]$x.reason + "`t" + [string]$x.detail })
        Errors   = (Get-VacateOrderedItem -Item $errors.ToArray() -Key { param($x) [string]$x.ruleId + "`t" + [string]$x.message })
        Programs = (Get-VacateOrderedItem -Item $programs.ToArray() -Key { param($x) [string]$x.name + "`t" + [string]$x.version + "`t" + [string]$x.scope })
        Log      = $log.ToArray()
    }
}

function Select-VacateMeasure {
    # Applies the rule's `measure` list to a trace (DECISIONS D42): metadata the rule did not ask
    # for is set to $null / removed, so the report only carries what the rule declares.
    # `exists`, the locator and sample names are always kept.
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][object]$Trace, [Parameter(Mandatory)][object]$Rule)
    $m = @($Rule.measure)
    $kind = [string]$Rule.locator.kind
    if ($m -cnotcontains 'sizeBytes') { $Trace.sizeBytes = $null }
    if ($m -cnotcontains 'lastWriteTime') { $Trace.lastWriteTime = $null }
    $keepCount = ($m -ccontains 'itemCount') -or ($kind -ceq 'registry' -and (($m -ccontains 'valueCount') -or ($m -ccontains 'subkeyCount')))
    if (-not $keepCount) { $Trace.itemCount = $null }
    if ($Trace.PSObject.Properties['properties'] -and $null -ne $Trace.properties) {
        if ($kind -ceq 'registry') {
            $props = $Trace.properties
            foreach ($k in @('valueCount', 'subkeyCount')) {
                if ($m -ccontains $k) { continue }
                if ($props -is [Collections.IDictionary]) { if ($props.Contains($k)) { $props.Remove($k) } }
                elseif ($props.PSObject.Properties[$k]) { $props.PSObject.Properties.Remove($k) }
            }
        }
        elseif ($m -cnotcontains 'properties') { $Trace.PSObject.Properties.Remove('properties') }
    }
    return $Trace
}

function Get-VacateOrderedItem {
    # Stable ordinal sort by a computed string key.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]]$Item = @(), [Parameter(Mandatory)][scriptblock]$Key)
    $arr = [object[]]@($Item)
    if ($arr.Length -le 1) { return , $arr }
    $keys = New-Object 'string[]' $arr.Length
    for ($i = 0; $i -lt $arr.Length; $i++) { $keys[$i] = (& $Key $arr[$i]) + "`t" + $i.ToString('D8') }
    [Array]::Sort([Array]$keys, [Array]$arr, [Collections.IComparer][StringComparer]::Ordinal)
    return , $arr
}

function Get-VacateOrderedTrace {
    # SPEC: sort traces by category then rule id (then resolved path for a stable total order).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]]$Trace = @())
    return (Get-VacateOrderedItem -Item $Trace -Key { param($t) [string]$t.category + "`t" + [string]$t.ruleId + "`t" + [string]$t.locator.resolved })
}

function Get-VacateSummary {
    # Computes report.summary from traces/skipped/errors exactly as documented at the top of this file.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()][object[]]$Traces = @(),
        [AllowEmptyCollection()][object[]]$Skipped = @(),
        [AllowEmptyCollection()][object[]]$Errors = @(),
        [Parameter(Mandatory)][int]$TotalRules,
        [Parameter(Mandatory)][int]$NotApplicable
    )
    $failed = @{}
    foreach ($e in $Errors) { $failed[[string]$e.ruleId] = $true }
    $withTrace = @{}
    foreach ($t in $Traces) { $withTrace[[string]$t.ruleId] = $true }
    # NB: PowerShell variable names are case-insensitive, so never name a local $skipped here.
    $skipSet = @{}
    foreach ($s in $Skipped) {
        $id = [string]$s.ruleId
        if (-not $failed.ContainsKey($id) -and -not $withTrace.ContainsKey($id)) { $skipSet[$id] = $true }
    }

    $cats = @{}
    [long]$total = 0
    foreach ($t in $Traces) {
        $c = [string]$t.category
        if (-not $cats.ContainsKey($c)) { $cats[$c] = @{ traces = 0; size = [long]0; rank = -1; sens = 'low' } }
        $cats[$c].traces++
        if ($null -ne $t.sizeBytes) { $cats[$c].size += [long]$t.sizeBytes; $total += [long]$t.sizeBytes }
        $rank = Get-VacateSensitivityRank -Sensitivity ([string]$t.sensitivity)
        if ($rank -gt $cats[$c].rank) { $cats[$c].rank = $rank; $cats[$c].sens = [string]$t.sensitivity }
    }
    $names = [string[]]@($cats.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $by = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        $by.Add([pscustomobject][ordered]@{ category = $n; traces = $cats[$n].traces; sizeBytes = $cats[$n].size; highestSensitivity = $cats[$n].sens })
    }

    return [pscustomobject][ordered]@{
        byCategory         = $by.ToArray()
        totalRules         = $TotalRules
        rulesRun           = ($TotalRules - $failed.Count - $skipSet.Count)
        rulesSkipped       = $skipSet.Count
        rulesFailed        = $failed.Count
        rulesNotApplicable = $NotApplicable
        tracesFound        = @($Traces).Count
        totalBytes         = $total
    }
}

function Test-VacateScanComplete {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()][object[]]$Skipped = @())
    foreach ($s in $Skipped) { if ($s.reason -ceq 'budget' -or $s.reason -ceq 'timeout') { return $false } }
    return $true
}

function New-VacateReport {
    # Assembles the full report object (schema order) from an engine result.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$EngineResult,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][int]$NotApplicable,
        [Parameter(Mandatory)][int]$InvalidFiles,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][object]$HostInfo,
        [Parameter(Mandatory)][datetime]$StartedAt,
        [Parameter(Mandatory)][datetime]$FinishedAt,
        [Parameter(Mandatory)][bool]$Elevated,
        [Parameter(Mandatory)][int]$BudgetSeconds,
        [Parameter(Mandatory)][int]$RuleTimeoutSeconds
    )
    $traces = @($EngineResult.Traces)
    $skips = @($EngineResult.Skips)
    $errs = @($EngineResult.Errors)

    $catalogRules = New-Object System.Collections.Generic.List[object]
    $unverified = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Rules) {
        $catalogRules.Add([pscustomobject][ordered]@{
                id = [string]$r.id; category = [string]$r.category; title = [string]$r.title
                whyItMatters = [string]$r.whyItMatters; sensitivity = [string]$r.sensitivity
                source = [string]$r.source; verified = [bool]$r.verified
            })
        if (-not $r.verified) { $unverified.Add([string]$r.id) }
    }

    $durationMs = [long][Math]::Max(0, ($FinishedAt - $StartedAt).TotalMilliseconds)
    return [pscustomobject][ordered]@{
        schemaVersion     = $script:VacateSchemaVersion
        tool              = [pscustomobject][ordered]@{ name = $script:VacateToolName; version = $script:VacateToolVersion }
        scan              = [pscustomobject][ordered]@{
            startedAt          = (ConvertTo-VacateIsoTime $StartedAt)
            finishedAt         = (ConvertTo-VacateIsoTime $FinishedAt)
            durationMs         = $durationMs
            platform           = $Platform
            elevated           = $Elevated
            budgetSeconds      = $BudgetSeconds
            ruleTimeoutSeconds = $RuleTimeoutSeconds
            complete           = (Test-VacateScanComplete -Skipped $skips)
            redacted           = $false
            host               = $HostInfo
        }
        catalog           = [pscustomobject][ordered]@{
            version      = $script:VacateToolVersion
            rulesLoaded  = @($Rules).Count + $NotApplicable
            unverified   = $unverified.ToArray()
            invalidFiles = $InvalidFiles
            rules        = $catalogRules.ToArray()
        }
        summary           = (Get-VacateSummary -Traces $traces -Skipped $skips -Errors $errs -TotalRules @($Rules).Count -NotApplicable $NotApplicable)
        traces            = $traces
        installedPrograms = @($EngineResult.Programs)
        skipped           = $skips
        errors            = $errs
        limitations       = @(Get-VacateLimitation -Platform $Platform)
    }
}
