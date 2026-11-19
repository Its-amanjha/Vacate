# Planner.ps1 - Phase 2: turns a report into a cleanup plan (dry-run, words only).
# PowerShell 5.1 compatible. ASCII only.
# The planner never touches the machine: its only inputs are a report object and the rule
# catalog, and its output is an object that Output.ps1 writes. (DECISIONS D44-D49)

$script:VacatePlanSchemaVersion = '1.0'

# Stage order (D49): export and sign out before anything that removes data.
$script:VacatePlanStages = @(
    @{ Name = 'export'; Action = 'export-then-remove'; Title = 'Save what you want to keep' }
    @{ Name = 'sign-out'; Action = 'sign-out-then-remove'; Title = 'Sign out and de-link accounts' }
    @{ Name = 'uninstall'; Action = 'uninstall'; Title = 'Uninstall apps' }
    @{ Name = 'remove'; Action = 'remove'; Title = 'Remove leftover data' }
    @{ Name = 'review'; Action = 'review'; Title = 'Decide yourself' }
    @{ Name = 'manual'; Action = ''; Title = 'No guidance yet - handle by hand' }
    @{ Name = 'no-action'; Action = 'none'; Title = 'No action needed' }
)

$script:VacateSensitivityRank = @{ 'critical' = 0; 'high' = 1; 'medium' = 2; 'low' = 3 }

function Get-VacateFullReset {
    # Built-in operating system reset (D46). vacate does not run it.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Platform)
    switch ($Platform) {
        'windows' {
            $title = 'Reset this PC'
            $steps = @(
                'If BitLocker is on, make sure you know where the recovery key is until the reset has finished.',
                'Open Settings > System > Recovery.',
                'Next to Reset this PC, choose Reset PC, then Remove everything.',
                'Choose Change settings and turn on Clean data, so removed files are much harder to recover.',
                'Follow the prompts and let the PC restart until setup shows the first-run screen.'
            )
            $source = 'Microsoft Support, Recovery options in Windows: https://support.microsoft.com/windows/recovery-options-in-windows-31ce2444-7de3-818c-d626-e3b5a3024da5'
        }
        'macos' {
            $title = 'Erase All Content and Settings'
            $steps = @(
                'Turn off Find My Mac and sign out of your Apple Account, or the next owner cannot activate the Mac.',
                'Open System Settings > General > Transfer or Reset.',
                'Choose Erase All Content and Settings and follow the steps.',
                'On a Mac without Apple silicon or the Apple T2 chip, erase the disk from macOS Recovery and reinstall macOS instead.'
            )
            $source = 'Apple Support, Erase your Mac and reset it to factory settings: https://support.apple.com/en-us/102664'
        }
        'linux' {
            $title = 'Reinstall over the whole disk'
            $steps = @(
                'Start the computer from your distribution installer.',
                'Choose the option that erases the whole disk and installs the system.',
                'If the disk used LUKS encryption, the old data cannot be read once the disk is erased and set up with a new passphrase.',
                'If you will not reinstall, follow your distribution documentation to destroy the LUKS header before handing the disk over.'
            )
            $source = 'Ubuntu, Install Ubuntu Desktop: https://ubuntu.com/tutorials/install-ubuntu-desktop'
        }
        default { throw "plan: unknown platform '$Platform'." }
    }
    return [pscustomobject][ordered]@{
        title  = $title
        when   = 'Only if you are giving the whole machine away. vacate does not erase anything; this is done with the operating system''s own tool.'
        steps  = $steps
        source = $source
    }
}

function Get-VacatePlanStage {
    # Stage index and name for a rule (or $null rule).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][object]$Rule)
    if ($null -eq $Rule) { return @{ Index = 5; Name = 'manual'; Kind = 'rule-missing' } }
    $c = Get-VacateRuleField $Rule 'cleanup'
    if (-not $c.Present -or $null -eq $c.Value) { return @{ Index = 5; Name = 'manual'; Kind = 'no-guidance' } }
    for ($i = 0; $i -lt $script:VacatePlanStages.Count; $i++) {
        if ($script:VacatePlanStages[$i].Action -ceq [string]$c.Value.action) { return @{ Index = $i; Name = $script:VacatePlanStages[$i].Name; Kind = 'guided' } }
    }
    return @{ Index = 5; Name = 'manual'; Kind = 'no-guidance' }
}

function New-VacatePlan {
    <#
    .SYNOPSIS
        Builds a plan object from a report and the rules for its platform. Pure: no I/O.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [Parameter(Mandatory)][datetime]$Now
    )
    $platform = [string]$Report.scan.platform
    $ruleMap = @{}
    foreach ($r in $Rules) { $ruleMap[[string]$r.id] = $r }

    # Group traces by rule id, keeping report order inside each group.
    $groups = @{}
    $order = New-Object System.Collections.Generic.List[string]
    $traces = @($Report.traces)
    foreach ($t in $traces) {
        $id = [string]$t.ruleId
        if (-not $groups.ContainsKey($id)) { $groups[$id] = New-Object System.Collections.Generic.List[object]; $order.Add($id) }
        $groups[$id].Add($t)
    }

    $built = New-Object System.Collections.Generic.List[object]
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($id in $order) {
        $rule = $null
        if ($ruleMap.ContainsKey($id)) { $rule = $ruleMap[$id] }
        $stage = Get-VacatePlanStage -Rule $rule
        $first = $groups[$id][0]

        $sens = [string]$first.sensitivity
        if ($null -ne $rule) { $sens = [string]$rule.sensitivity }
        $rank = 9
        if ($script:VacateSensitivityRank.ContainsKey($sens)) { $rank = $script:VacateSensitivityRank[$sens] }

        $action = $null; $exportFirst = $null; $signOut = $null; $instructions = @(); $risk = $null
        $closeApps = @(); $resetCovers = $null; $reason = $null; $source = $null
        if ($stage.Kind -ceq 'guided') {
            $c = $rule.cleanup
            $action = [string]$c.action
            $exportFirst = $c.exportFirst; $signOut = $c.signOut
            $instructions = @($c.steps | Where-Object { $null -ne $_ })
            $risk = [string]$c.risk
            $closeApps = @($c.closeApps | Where-Object { $null -ne $_ })
            $resetCovers = [bool]$c.resetCovers
            $reason = $c.reason
            $source = [string]$c.source
        }
        elseif ($stage.Kind -ceq 'no-guidance') {
            $reason = 'This version of vacate has no cleanup guidance for this rule yet. Use the report entry (what it is and why it matters) and the app''s own help.'
        }
        else {
            $reason = 'The rule that found this is not in this version''s rule catalog (the report came from a different version). Rescan with this version, or handle it by hand.'
        }

        $locations = New-Object System.Collections.Generic.List[object]
        foreach ($t in $groups[$id]) {
            $locations.Add([pscustomobject][ordered]@{
                    kind      = [string]$t.locator.kind
                    resolved  = [string]$t.locator.resolved
                    exists    = [bool]$t.exists
                    sizeBytes = $t.sizeBytes
                    itemCount = $t.itemCount
                })
        }

        $built.Add([pscustomobject][ordered]@{
                step         = 0
                stage        = $stage.Name
                guidance     = $stage.Kind
                ruleId       = $id
                title        = [string]$first.title
                category     = [string]$first.category
                sensitivity  = $sens
                action       = $action
                exportFirst  = $exportFirst
                signOut      = $signOut
                instructions = [string[]]$instructions
                risk         = $risk
                closeApps    = [string[]]$closeApps
                resetCovers  = $resetCovers
                reason       = $reason
                source       = $source
                locations    = $locations.ToArray()
            })
        $keys.Add(('{0}|{1}|{2}' -f $stage.Index, $rank, $id))
    }

    # Deterministic ordinal sort (non-generic overload, DECISIONS D29).
    $keyArr = $keys.ToArray(); $stepArr = $built.ToArray()
    if ($stepArr.Count -gt 1) { [Array]::Sort([Array]$keyArr, [Array]$stepArr, [Collections.IComparer][StringComparer]::Ordinal) }
    for ($i = 0; $i -lt $stepArr.Count; $i++) { $stepArr[$i].step = $i + 1 }

    # Coverage invariant (D45): every trace is in exactly one step.
    $covered = 0
    foreach ($s in $stepArr) { $covered += @($s.locations).Count }
    if ($covered -ne $traces.Count) { throw "plan: internal error, $covered of $($traces.Count) traces covered." }

    # Before you start: apps to close, and the wallet warning when wallets were found.
    $apps = New-Object System.Collections.Generic.List[string]
    foreach ($s in $stepArr) { foreach ($a in $s.closeApps) { if (-not $apps.Contains($a)) { $apps.Add($a) } } }
    $appArr = $apps.ToArray()
    if ($appArr.Count -gt 1) { [Array]::Sort([Array]$appArr, [Collections.IComparer][StringComparer]::Ordinal) }
    $notes = New-Object System.Collections.Generic.List[string]
    if (@($stepArr | Where-Object { $_.category -ceq 'wallets' }).Count -gt 0) {
        $notes.Add('Crypto wallets were found. Confirm you have every recovery phrase or backup before you change anything. Never type a recovery phrase into a website or a chat.')
    }
    $notes.Add('Work top to bottom. Saving and signing out come first because removing an app can remove the session you need to sign out of.')
    $notes.Add('vacate has not changed anything on this machine. Every step here is done by you.')

    $byStage = New-Object System.Collections.Generic.List[object]
    foreach ($st in $script:VacatePlanStages) {
        $n = @($stepArr | Where-Object { $_.stage -ceq $st.Name }).Count
        $byStage.Add([pscustomobject][ordered]@{ stage = $st.Name; title = $st.Title; steps = $n })
    }

    $limitations = New-Object System.Collections.Generic.List[string]
    $limitations.Add('This plan is advice only (dry run). vacate deletes nothing; removal tools are a later phase.')
    $limitations.Add('The plan only covers what the scan found. A short plan does not mean the machine is clean.')
    if (-not [bool]$Report.scan.complete) { $limitations.Add('The scan did not finish, so this plan is incomplete. Rescan with a larger -BudgetSeconds.') }
    if ([bool]$Report.scan.redacted) { $limitations.Add('The report was redacted, so locations are shown as hashes. Run the plan on an unredacted report to see real paths.') }

    return [pscustomobject][ordered]@{
        schemaVersion  = $script:VacatePlanSchemaVersion
        tool           = [pscustomobject][ordered]@{ name = 'vacate'; version = $script:VacateToolVersion }
        generatedAt    = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        report         = [pscustomobject][ordered]@{
            platform   = $platform
            finishedAt = [string]$Report.scan.finishedAt
            complete   = [bool]$Report.scan.complete
            redacted   = [bool]$Report.scan.redacted
            traces     = $traces.Count
            tool       = [string]$Report.tool.version
        }
        summary        = [pscustomobject][ordered]@{
            steps         = $stepArr.Count
            traces        = $traces.Count
            tracesCovered = $covered
            withGuidance  = @($stepArr | Where-Object { $_.guidance -ceq 'guided' }).Count
            noGuidance    = @($stepArr | Where-Object { $_.guidance -ceq 'no-guidance' }).Count
            ruleMissing   = @($stepArr | Where-Object { $_.guidance -ceq 'rule-missing' }).Count
            resetCovers   = @($stepArr | Where-Object { $_.resetCovers -eq $true }).Count
            byStage       = $byStage.ToArray()
        }
        beforeYouStart = [pscustomobject][ordered]@{ closeApps = [string[]]$appArr; notes = $notes.ToArray() }
        steps          = $stepArr
        fullReset      = (Get-VacateFullReset -Platform $platform)
        limitations    = $limitations.ToArray()
    }
}
