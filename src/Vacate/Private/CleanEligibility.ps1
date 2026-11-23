# CleanEligibility.ps1 - Phase 3: decides whether one plan step may be moved to the Trash.
# PowerShell 5.1 compatible. ASCII only.
# Pure function: no file system access. Its inputs are a plan step, the rule that found it and
# the person's export confirmation; its output is a verdict with a stable code. (DECISIONS D50, D51)

# User roots (D50): only folders inside the person's own profile. Every other root token
# (USERS, PROGRAMDATA, SYSTEMDRIVE, SYSTEM, APPLICATIONS, ETC, VAR, or anything unknown) is refused.
$script:VacateCleanUserRoots = @('HOME', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG', 'XDG_DATA', 'XDG_STATE', 'LIBRARY')

# Rules that are never moved, whatever their action or root (D51).
$script:VacateCleanManualOnly = @(
    'system.temp.user', 'credentials.windows.vault', 'credentials.windows.credentials-local',
    'credentials.windows.credentials-roaming', 'credentials.keyrings', 'activity.saved-app-state',
    'autostart.launch-agents', 'system.caches'
)

function New-VacateCleanVerdict {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Reason)
    return [pscustomobject][ordered]@{
        eligible = ($Code -ceq 'ok')
        code     = $Code
        reason   = $Reason
    }
}

function Get-VacateCleanEligibility {
    <#
    .SYNOPSIS
        Returns { eligible; code; reason } for one plan step (D51). The first failing check wins.
    .DESCRIPTION
        Checks, in this order: the rule exists (and matches the step), its cleanup action is
        'remove', it is not a wallet, it is not a personal-folder rule (id 'files.*'), the plan
        step itself says 'remove', the locator kind is 'path', the locator root is a user root
        (D50), the locator names the exact target (no include, no recurse), the rule is not on the
        manual-only list, the rule does not need elevation, and any exportFirst was confirmed by the person.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Step,
        [AllowNull()][object]$Rule,
        [Parameter(Mandatory)][bool]$ExportConfirmed
    )

    # 1. The rule must exist and be the rule this step was built from.
    if ($null -eq $Rule) {
        return (New-VacateCleanVerdict 'rule-missing' 'The rule for this step is not in this version''s catalog. Rescan and make a new plan, or handle it by hand.')
    }
    $stepRuleId = [string](Get-VacateRuleField $Step 'ruleId').Value
    $ruleId = [string](Get-VacateRuleField $Rule 'id').Value
    if ([string]::IsNullOrEmpty($ruleId) -or $ruleId -cne $stepRuleId) {
        return (New-VacateCleanVerdict 'rule-missing' "The rule given ('$ruleId') is not the rule of this step ('$stepRuleId').")
    }

    # 2. Only 'remove' rules are eligible (D51). Compared case-sensitively.
    $cleanup = (Get-VacateRuleField $Rule 'cleanup').Value
    $action = (Get-VacateRuleField $cleanup 'action').Value
    if (-not ($action -is [string]) -or $action -cne 'remove') {
        return (New-VacateCleanVerdict 'not-remove-action' "The rule's cleanup action is '$action', not 'remove'. vacate only moves leftover data; this step is done by you.")
    }

    # 3. Wallets are never eligible (D51), whichever side (rule or plan) says so.
    $ruleCategory = [string](Get-VacateRuleField $Rule 'category').Value
    $stepCategory = [string](Get-VacateRuleField $Step 'category').Value
    if ($ruleCategory -ieq 'wallets' -or $stepCategory -ieq 'wallets') {
        return (New-VacateCleanVerdict 'wallet' 'Crypto wallet data is never moved by vacate. Handle it yourself after checking your recovery phrase or backup.')
    }

    # 4. Personal-folder rules (files.*) are never eligible (D51).
    if ($ruleId.StartsWith('files.', [StringComparison]::OrdinalIgnoreCase)) {
        return (New-VacateCleanVerdict 'personal-folder' 'This is one of your personal folders. vacate never moves personal files; copy what you want to keep and remove them yourself.')
    }

    # 5. The plan step must agree: a step the plan put under 'review' (or any other action, e.g. a
    #    plan made with a different rule version) needs a person's judgement, not a move (D51).
    $stepAction = (Get-VacateRuleField $Step 'action').Value
    if (-not ($stepAction -is [string]) -or $stepAction -cne 'remove') {
        return (New-VacateCleanVerdict 'review' "The plan says '$stepAction' for this step, not 'remove'. Decide yourself, or make a new plan with this version.")
    }

    # 6. Only file system locations can go to the Recycle Bin or Trash (D50).
    $locator = (Get-VacateRuleField $Rule 'locator').Value
    $kind = (Get-VacateRuleField $locator 'kind').Value
    if (-not ($kind -is [string]) -or $kind -cne 'path') {
        return (New-VacateCleanVerdict 'kind-not-path' "This step's locations are of kind '$kind', not files or folders. They cannot go to the Recycle Bin or Trash; handle them by hand.")
    }

    # 7. Only user roots (D50).
    $root = (Get-VacateRuleField $locator 'root').Value
    if (-not ($root -is [string]) -or $script:VacateCleanUserRoots -cnotcontains $root) {
        return (New-VacateCleanVerdict 'root-not-user' "The locations sit under '$root', which is outside your own profile. vacate only moves files in your profile.")
    }

    # 7a. The locator must name the exact target. A rule with 'include' or recurse=true reports the
    #     CONTAINING folder (e.g. Desktop for .DS_Store files), so moving it would trash the whole folder (D51).
    $include = Get-VacateRuleField $locator 'include'
    $recurse = (Get-VacateRuleField $locator 'recurse').Value
    if ($include.Present -or $recurse -eq $true) {
        return (New-VacateCleanVerdict 'not-exact-target' 'This rule reports the folder that contains the matches, not the matches themselves. Moving it would move the whole folder, so remove the items yourself.')
    }

    # 7b. Rules that must stay manual even though they look like plain user files (D51):
    #     shared temp, credential stores, keyrings, saved app state, launch agents, shared caches.
    if ($script:VacateCleanManualOnly -ccontains $ruleId) {
        return (New-VacateCleanVerdict 'manual-only' 'This location is in use by the system or holds credentials. vacate leaves it to you; follow the plan step by hand.')
    }

    # 8. Anything that needs elevation is outside the user's own data (D50). Only an explicit false passes.
    $elev = (Get-VacateRuleField $Rule 'requiresElevation').Value
    if (-not ($elev -is [bool]) -or $elev) {
        return (New-VacateCleanVerdict 'requires-elevation' 'This rule needs administrator rights. vacate does not move data that needs elevation.')
    }

    # 9. exportFirst needs the person's explicit confirmation for this step (D51).
    $exportFirst = (Get-VacateRuleField $cleanup 'exportFirst').Value
    if ($null -ne $exportFirst -and -not $ExportConfirmed) {
        return (New-VacateCleanVerdict 'export-not-confirmed' "Save what you want to keep first ($exportFirst), then confirm it with -ExportDone for this step.")
    }

    return (New-VacateCleanVerdict 'ok' 'Eligible: leftover data in your profile that can go to the Recycle Bin or Trash.')
}
