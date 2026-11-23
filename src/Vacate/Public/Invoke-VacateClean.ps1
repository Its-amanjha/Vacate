# Invoke-VacateClean.ps1 - public: Phase 3 clean and undo (DECISIONS D50-D53).
# PowerShell 5.1 compatible. ASCII only.
# Dry run by default. Moving needs -Steps, -Execute and -Confirm <MACHINENAME>. Items only ever go
# to the Recycle Bin or Trash, every move is recorded in undo.json before the next one starts, and
# every path is checked again at execute time (Test-VacateCleanTarget), never trusted from a file.

function Read-VacateRunFile {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$Name, [switch]$Optional)
    $p = [IO.Path]::Combine($RunDir, $Name)
    if (-not [IO.File]::Exists($p)) {
        if ($Optional) { return $null }
        throw "No $Name in $RunDir. Run scan and plan first."
    }
    return (ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText($p)))
}

function Assert-VacateCleanRun {
    # Shared refusals for clean and undo: platform, redaction, confirm gate (D52).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$Platform,
        [bool]$Execute,
        [string]$ConfirmMachine
    )
    if ([string]$Report.scan.platform -cne $Platform) {
        throw ("This run was made on {0}; this machine is {1}. Clean only runs on the machine it scanned." -f $Report.scan.platform, $Platform)
    }
    if ([bool]$Report.scan.redacted) { throw 'This run is redacted (paths are hashes). Scan again without -Redact to clean.' }
    if ($Execute) {
        $machine = [Environment]::MachineName
        if ([string]::IsNullOrEmpty($ConfirmMachine) -or -not [string]::Equals($ConfirmMachine, $machine, [StringComparison]::OrdinalIgnoreCase)) {
            throw ("-Execute needs -Confirm with this machine's name ({0}). Nothing was moved." -f $machine)
        }
        if (Test-VacateElevated -Platform $Platform) {
            throw 'Run clean and undo as your normal user, not as administrator or root: elevated rights reach other users'' data.'
        }
    }
}

function Get-VacateCleanContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Platform, [object]$PlatformProfile)
    $envSnap = $null
    $vprofile = $PlatformProfile
    if ($null -eq $vprofile) {
        $envSnap = Get-VacateEnvironmentSnapshot
        $vprofile = Get-VacatePlatformProfile -Platform $Platform -Environment $envSnap
    }
    return [pscustomobject]@{ Profile = $vprofile; Roots = @(Get-VacateCleanRoot -PlatformProfile $vprofile); Environment = $envSnap }
}

function Invoke-VacateClean {
    <#
    .SYNOPSIS
        Moves eligible plan items to the Recycle Bin or Trash. Dry run unless -Execute -Confirm.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Run,
        [int[]]$Steps = @(),
        [int[]]$ExportDone = @(),
        [switch]$Execute,
        [Alias('Confirm')][string]$ConfirmMachine,
        [string]$TrashRoot,
        [string]$ToolRoot,
        # Tests only: a fake user profile instead of this machine's real one (like -TrashRoot).
        [object]$PlatformProfile,
        [datetime]$Now = [datetime]::UtcNow
    )
    $runDir = [IO.Path]::GetFullPath($Run)
    $base = [IO.Path]::GetDirectoryName($runDir)
    $report = Read-VacateRunFile -RunDir $runDir -Name 'report.json'
    $plan = Read-VacateRunFile -RunDir $runDir -Name 'plan.json'
    $platform = Get-VacatePlatform
    Assert-VacateCleanRun -Report $report -Platform $platform -Execute $Execute.IsPresent -ConfirmMachine $ConfirmMachine
    if ($Execute -and @($Steps).Count -eq 0) { throw '-Execute needs -Steps with the step numbers to clean, for example -Steps 3,5. There is no "all steps" option.' }

    $allSteps = @($plan.steps)
    $known = @($allSteps | ForEach-Object { [int]$_.step })
    foreach ($n in $Steps) { if ($known -notcontains $n) { throw "Step $n is not in this plan." } }
    $selected = $allSteps
    if (@($Steps).Count -gt 0) { $selected = @($allSteps | Where-Object { $Steps -contains [int]$_.step }) }

    $ctx = Get-VacateCleanContext -Platform $platform -PlatformProfile $PlatformProfile
    $set = Import-VacateRuleSet -Path $script:VacateRulesRoot -Platform $platform
    $ruleMap = @{}
    foreach ($r in @($set.Rules)) { $ruleMap[[string]$r.id] = $r }
    $fs = New-VacateFileSystemProvider
    # vacate's own folder (src/Vacate is two levels below it) and the runs folder are never cleaned.
    $tool = $ToolRoot
    if (-not $tool) { $tool = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($script:VacateModuleRoot)) }
    $exclude = @([IO.Path]::GetFullPath($tool), $base)

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($s in $selected) {
        $rule = $null
        if ($ruleMap.ContainsKey([string]$s.ruleId)) { $rule = $ruleMap[[string]$s.ruleId] }
        $elig = Get-VacateCleanEligibility -Step $s -Rule $rule -ExportConfirmed ($ExportDone -contains [int]$s.step)
        # Tie every target to the rule as it resolves NOW (threat model: an edited or stale plan.json
        # must not reach other files). Only the rule's own root is allowed for its targets.
        $ruleRoot = @(); $ruleTargets = @{}
        if ($elig.eligible) {
            $ruleRoot = @(Get-VacateRuleCleanRoot -Rule $rule -PlatformProfile $ctx.Profile -Roots $ctx.Roots)
            if ($ruleRoot.Count -gt 0) {
                $excludeHome = $false
                if ($null -ne $rule.locator.PSObject.Properties['excludeHome']) { $excludeHome = [bool]$rule.locator.excludeHome }
                $res = Resolve-VacateRuleTargets -FileSystem $fs -Root $ruleRoot[0] -RulePath ([string]$rule.locator.path) -Match ([string]$rule.locator.match) -Platform $ctx.Profile -Exclude $exclude -ExcludeHome:$excludeHome
                foreach ($x in @($res.Targets)) { $ruleTargets[(ConvertTo-VacateCleanKey -Path $x.FullName -PlatformProfile $ctx.Profile)] = $true }
            }
        }
        foreach ($loc in @($s.locations)) {
            $item = [pscustomobject][ordered]@{
                step = [int]$s.step; ruleId = [string]$s.ruleId; title = [string]$s.title
                path = [string]$loc.resolved; status = ''; code = ''; reason = ''; trashLocation = $null
            }
            if (-not $elig.eligible) { $item.status = 'not-eligible'; $item.code = $elig.code; $item.reason = $elig.reason }
            elseif (-not $ruleTargets.ContainsKey((ConvertTo-VacateCleanKey -Path $item.path -PlatformProfile $ctx.Profile))) {
                $item.status = 'refused'; $item.code = 'not-in-rule'
                $item.reason = 'The rule does not find this path now (the plan may be old or edited). Scan and plan again.'
            }
            else {
                $chk = Test-VacateCleanTarget -Path $item.path -AllowedRoots $ruleRoot
                if ($chk.ok) { $item.status = 'would-move'; $item.code = 'ok'; $item.path = $chk.fullPath; $item | Add-Member -NotePropertyName allowedRoot -NotePropertyValue $ruleRoot[0] }
                else { $item.status = 'refused'; $item.code = $chk.code; $item.reason = $chk.reason }
            }
            $items.Add($item)
        }
    }

    $undoLog = $null
    $cleanedRules = New-Object System.Collections.Generic.List[string]
    if ($Execute) {
        $existing = $null
        $undoPath = [IO.Path]::Combine($runDir, 'undo.json')
        if ([IO.File]::Exists($undoPath)) { $existing = ConvertFrom-VacateUndoJson -Json ([IO.File]::ReadAllText($undoPath)) }
        if ($null -ne $existing) { $undoLog = $existing }
        else { $undoLog = New-VacateUndoLog -Platform $platform -Machine ([Environment]::MachineName) -Run ([IO.Path]::GetFileName($runDir)) -Now $Now }
        foreach ($item in $items) {
            if ($item.status -cne 'would-move') { continue }
            # Check again immediately before the move: the tree may have changed since the dry pass.
            $chk = Test-VacateCleanTarget -Path $item.path -AllowedRoots @($item.allowedRoot)
            if (-not $chk.ok) { $item.status = 'refused'; $item.code = $chk.code; $item.reason = $chk.reason; continue }
            $size = $null
            $loc = @($selected | Where-Object { [int]$_.step -eq $item.step })[0].locations | Where-Object { [string]$_.resolved -eq $item.path } | Select-Object -First 1
            if ($null -ne $loc) { $size = $loc.sizeBytes }
            $res = Move-VacateItemToTrash -Path $chk.fullPath -Platform $platform -TrashRoot $TrashRoot
            if ($res.ok) {
                $item.status = 'moved'; $item.trashLocation = $res.trashLocation
                $undoLog = (Add-VacateUndoEntry -Log $undoLog -Step $item.step -RuleId $item.ruleId -OriginalPath $chk.fullPath -TrashLocation $res.trashLocation -IsDirectory $chk.isDirectory -SizeBytes $size -Now ([datetime]::UtcNow))
                Write-VacateTextFile -BaseDir $base -Path $undoPath -Text (ConvertTo-VacateUndoJson -Log $undoLog)
                if (-not $cleanedRules.Contains($item.ruleId)) { $cleanedRules.Add($item.ruleId) }
            }
            else { $item.status = 'failed'; $item.code = 'move-failed'; $item.reason = [string]$res.error }
        }
    }

    # Verification (Execute only): scan just the cleaned rules again and list what is still there.
    $stillPresent = New-Object System.Collections.Generic.List[object]
    if ($Execute -and $cleanedRules.Count -gt 0) {
        $scanCtx = New-VacateScanContext -Platform $ctx.Profile -Elevated $false -Exclude $exclude
        $subset = @($set.Rules | Where-Object { $cleanedRules.Contains([string]$_.id) })
        $res = Invoke-VacateEngine -Rules $subset -Context $scanCtx -BudgetSeconds 60 -RuleTimeoutSeconds $script:VacateDefaultRuleTimeoutSeconds
        foreach ($t in @($res.Traces)) { if ($t.exists) { $stillPresent.Add([pscustomobject][ordered]@{ ruleId = [string]$t.ruleId; path = [string]$t.locator.resolved }) } }
    }

    $count = { param($st) @($items | Where-Object { $_.status -ceq $st }).Count }
    $result = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        tool          = [pscustomobject][ordered]@{ name = 'vacate'; version = $script:VacateToolVersion }
        mode          = $(if ($Execute) { 'execute' } else { 'dry-run' })
        at            = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        steps         = [int[]]@($selected | ForEach-Object { [int]$_.step })
        summary       = [pscustomobject][ordered]@{
            items = $items.Count; wouldMove = (& $count 'would-move'); moved = (& $count 'moved')
            notEligible = (& $count 'not-eligible'); refused = (& $count 'refused'); failed = (& $count 'failed')
            stillPresent = $stillPresent.Count
        }
        items         = $items.ToArray()
        stillPresent  = $stillPresent.ToArray()
    }
    $name = 'clean-preview'
    if ($Execute) { $name = 'clean' }
    Write-VacateTextFile -BaseDir $base -Path ([IO.Path]::Combine($runDir, $name + '.json')) -Text (ConvertTo-VacateReportJson -Report $result)
    $mdName = 'clean-preview.md'
    if ($Execute) { $mdName = 'clean-report.md' }
    Write-VacateTextFile -BaseDir $base -Path ([IO.Path]::Combine($runDir, $mdName)) -Text (ConvertTo-VacateCleanMarkdown -Result $result)
    return $result
}
