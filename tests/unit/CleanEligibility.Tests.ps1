BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-EligTestRule {
        param(
            [string]$Id = 'browser.test.cache',
            [string]$Category = 'browsers',
            [string]$Action = 'remove',
            [object]$ExportFirst = $null,
            [string]$Kind = 'path',
            [string]$Root = 'HOME',
            [object]$Elevation = $false,
            [string[]]$Include = $null,
            [object]$Recurse = $null,
            [switch]$NoCleanup
        )
        $locator = [ordered]@{ kind = $Kind; root = $Root; path = 'x'; match = 'any' }
        if ($null -ne $Include) { $locator.include = $Include }
        if ($null -ne $Recurse) { $locator.recurse = $Recurse }
        if ($Kind -cne 'path') { $locator = [ordered]@{ kind = $Kind; hive = 'HKCU'; key = 'Software\X' } }
        $r = [ordered]@{
            id = $Id; platforms = @('windows'); category = $Category; title = "Title of $Id"
            whyItMatters = 'Because it matters.'; sensitivity = 'medium'; locator = $locator
            measure = @('exists'); maxEntries = 10; requiresElevation = $Elevation; verifiedOn = @(); verified = $false
            source = 'Vendor docs'; notes = $null
        }
        if (-not $NoCleanup) {
            $r.cleanup = [ordered]@{
                action = $Action; exportFirst = $ExportFirst; signOut = $null; steps = @('Do it.')
                risk = 'Something is lost.'; closeApps = @(); resetCovers = $true; reason = $null; source = 'Vendor help'
            }
        }
        return (($r | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
    }

    function Get-EligTestStep {
        # A plan step as New-VacatePlan builds it from a rule (round-tripped through JSON like plan.json).
        param([object]$Rule, [string]$RuleId, [object]$Action = 'remove', [string]$Category = 'browsers')
        if ($null -ne $Rule) {
            $RuleId = [string]$Rule.id; $Category = [string]$Rule.category
            $c = $Rule.PSObject.Properties['cleanup']
            if ($null -ne $c -and $null -ne $c.Value) { $Action = [string]$c.Value.action } else { $Action = $null }
        }
        $s = [ordered]@{
            step = 1; stage = 'remove'; guidance = 'guided'; ruleId = $RuleId; title = "Title of $RuleId"
            category = $Category; sensitivity = 'medium'; action = $Action; exportFirst = $null; locations = @()
        }
        return (($s | ConvertTo-Json -Depth 6) | ConvertFrom-Json)
    }

    function Invoke-Elig {
        param([object]$Step, [object]$Rule, [bool]$ExportConfirmed = $false)
        return InModuleScope Vacate -Parameters @{ S = $Step; R = $Rule; E = $ExportConfirmed } {
            param($S, $R, $E)
            Get-VacateCleanEligibility -Step $S -Rule $R -ExportConfirmed $E
        }
    }
}

Describe 'Get-VacateCleanEligibility' {
    It 'returns ok for a remove rule under a user root' {
        $r = Get-EligTestRule
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r
        $v.eligible | Should -BeTrue
        $v.code | Should -Be 'ok'
        $v.reason | Should -Not -BeNullOrEmpty
        @($v.PSObject.Properties.Name) | Should -Be @('eligible', 'code', 'reason')
    }

    It 'rule-missing when the rule is null' {
        $v = Invoke-Elig -Step (Get-EligTestStep -RuleId 'gone.rule') -Rule $null
        $v.eligible | Should -BeFalse
        $v.code | Should -Be 'rule-missing'
    }

    It 'rule-missing when the rule is not the rule of the step' {
        $r = Get-EligTestRule
        $v = Invoke-Elig -Step (Get-EligTestStep -RuleId 'other.rule') -Rule $r
        $v.code | Should -Be 'rule-missing'
    }

    It 'not-remove-action for <Action>' -TestCases @(
        @{ Action = 'review' }, @{ Action = 'export-then-remove' }, @{ Action = 'sign-out-then-remove' },
        @{ Action = 'uninstall' }, @{ Action = 'none' }, @{ Action = 'Remove' }
    ) {
        param($Action)
        $r = Get-EligTestRule -Action $Action
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $true
        $v.code | Should -Be 'not-remove-action'
        $v.eligible | Should -BeFalse
    }

    It 'not-remove-action when the rule has no cleanup guidance' {
        $r = Get-EligTestRule -NoCleanup
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r
        $v.code | Should -Be 'not-remove-action'
    }

    It 'wallet for a wallet rule with action remove' {
        $r = Get-EligTestRule -Id 'wallet.test.data' -Category 'wallets'
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $true
        $v.code | Should -Be 'wallet'
    }

    It 'wallet when only the plan step says wallets' {
        $r = Get-EligTestRule -Id 'wallet.test.data'
        $v = Invoke-Elig -Step (Get-EligTestStep -RuleId 'wallet.test.data' -Category 'wallets') -Rule $r
        $v.code | Should -Be 'wallet'
    }

    It 'personal-folder for a files.* rule' {
        $r = Get-EligTestRule -Id 'files.downloads' -Category 'files'
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $true
        $v.code | Should -Be 'personal-folder'
    }

    It 'review when the plan step does not say remove (plan from another rule version)' {
        $r = Get-EligTestRule
        $v = Invoke-Elig -Step (Get-EligTestStep -RuleId $r.id -Action 'review') -Rule $r
        $v.code | Should -Be 'review'
        $v = Invoke-Elig -Step (Get-EligTestStep -RuleId $r.id -Action $null) -Rule $r
        $v.code | Should -Be 'review'
    }

    It 'kind-not-path for a registry rule' {
        $r = Get-EligTestRule -Kind 'registry'
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r
        $v.code | Should -Be 'kind-not-path'
    }

    It 'root-not-user for <Root>' -TestCases @(
        @{ Root = 'USERS' }, @{ Root = 'PROGRAMDATA' }, @{ Root = 'SYSTEMDRIVE' }, @{ Root = 'SYSTEM' },
        @{ Root = 'APPLICATIONS' }, @{ Root = 'ETC' }, @{ Root = 'VAR' }, @{ Root = 'home' }, @{ Root = 'UNKNOWN' }
    ) {
        param($Root)
        $r = Get-EligTestRule -Root $Root
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r
        $v.code | Should -Be 'root-not-user'
    }

    It 'accepts every user root <Root>' -TestCases @(
        @{ Root = 'HOME' }, @{ Root = 'APPDATA' }, @{ Root = 'LOCALAPPDATA' }, @{ Root = 'XDG_CONFIG' },
        @{ Root = 'XDG_DATA' }, @{ Root = 'XDG_STATE' }, @{ Root = 'LIBRARY' }
    ) {
        param($Root)
        $r = Get-EligTestRule -Root $Root
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'ok'
    }

    It 'not-exact-target when the locator has include' {
        $r = Get-EligTestRule -Include @('.DS_Store')
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'not-exact-target'
    }

    It 'not-exact-target when recurse is true, ok when recurse is false' {
        $r = Get-EligTestRule -Recurse $true
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'not-exact-target'
        $r = Get-EligTestRule -Recurse $false
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'ok'
    }

    It 'manual-only for <Id>' -TestCases @(
        @{ Id = 'system.temp.user' }, @{ Id = 'credentials.windows.vault' }, @{ Id = 'credentials.windows.credentials-local' },
        @{ Id = 'credentials.windows.credentials-roaming' }, @{ Id = 'credentials.keyrings' }, @{ Id = 'activity.saved-app-state' },
        @{ Id = 'autostart.launch-agents' }, @{ Id = 'system.caches' }
    ) {
        param($Id)
        $r = Get-EligTestRule -Id $Id
        $v = Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $true
        $v.code | Should -Be 'manual-only'
        $v.eligible | Should -BeFalse
    }

    It 'requires-elevation when requiresElevation is true or not a boolean false' {
        $r = Get-EligTestRule -Elevation $true
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'requires-elevation'
        $r = Get-EligTestRule -Elevation 'false'
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'requires-elevation'
    }

    It 'export-not-confirmed without confirmation, ok with it' {
        $r = Get-EligTestRule -ExportFirst 'Export your bookmarks first.'
        $s = Get-EligTestStep -Rule $r
        $off = Invoke-Elig -Step $s -Rule $r -ExportConfirmed $false
        $off.code | Should -Be 'export-not-confirmed'
        $off.eligible | Should -BeFalse
        $on = Invoke-Elig -Step $s -Rule $r -ExportConfirmed $true
        $on.code | Should -Be 'ok'
        $on.eligible | Should -BeTrue
    }

    It 'export confirmation does not matter when there is no exportFirst' {
        $r = Get-EligTestRule
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $false).code | Should -Be 'ok'
        (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $true).code | Should -Be 'ok'
    }

    Context 'ordering: the first failing check wins' {
        It 'a wallet rule with action review is not-remove-action' {
            $r = Get-EligTestRule -Id 'wallet.test.data' -Category 'wallets' -Action 'review'
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $true).code | Should -Be 'not-remove-action'
        }
        It 'a wallet files.* rule is wallet before personal-folder' {
            $r = Get-EligTestRule -Id 'files.wallet' -Category 'wallets'
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'wallet'
        }
        It 'a files.* rule under PROGRAMDATA is personal-folder before root-not-user' {
            $r = Get-EligTestRule -Id 'files.shared' -Root 'PROGRAMDATA' -Elevation $true
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'personal-folder'
        }
        It 'a registry rule needing elevation is kind-not-path before requires-elevation' {
            $r = Get-EligTestRule -Kind 'registry' -Elevation $true
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'kind-not-path'
        }
        It 'a non-user root needing elevation is root-not-user before requires-elevation' {
            $r = Get-EligTestRule -Root 'SYSTEMDRIVE' -Elevation $true
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'root-not-user'
        }
        It 'a non-user root with include is root-not-user before not-exact-target' {
            $r = Get-EligTestRule -Root 'USERS' -Include @('*.tmp')
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'root-not-user'
        }
        It 'a manual-only rule with recurse is not-exact-target before manual-only' {
            $r = Get-EligTestRule -Id 'system.caches' -Recurse $true
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'not-exact-target'
        }
        It 'a manual-only rule needing elevation is manual-only before requires-elevation' {
            $r = Get-EligTestRule -Id 'credentials.keyrings' -Elevation $true
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'manual-only'
        }
        It 'include with elevation is not-exact-target before requires-elevation' {
            $r = Get-EligTestRule -Include @('x') -Elevation $true
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r).code | Should -Be 'not-exact-target'
        }
        It 'elevation with an unconfirmed export is requires-elevation before export-not-confirmed' {
            $r = Get-EligTestRule -Elevation $true -ExportFirst 'Export first.'
            (Invoke-Elig -Step (Get-EligTestStep -Rule $r) -Rule $r -ExportConfirmed $false).code | Should -Be 'requires-elevation'
        }
    }

    Context 'the real rule catalog' {
        It 'never makes a wallet, files.* or non-user-root rule eligible; prints counts per platform' {
            $rulesDir = Join-Path $PSScriptRoot '../../src/Vacate/rules'
            $userRoots = @('HOME', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG', 'XDG_DATA', 'XDG_STATE', 'LIBRARY')
            $manualOnly = @(
                'system.temp.user', 'credentials.windows.vault', 'credentials.windows.credentials-local',
                'credentials.windows.credentials-roaming', 'credentials.keyrings', 'activity.saved-app-state',
                'autostart.launch-agents', 'system.caches'
            )
            $total = 0
            $dsStore = 0
            # Load the whole catalog once (every platform), then split it per platform.
            $set = InModuleScope Vacate -Parameters @{ P = $rulesDir } { param($P) Import-VacateRuleSet -Path $P }
            @($set.Errors).Count | Should -Be 0
            foreach ($pl in @('windows', 'macos', 'linux')) {
                $rules = @($set.Rules | Where-Object { @($_.platforms) -ccontains $pl })
                $rules.Count | Should -BeGreaterThan 0
                $steps = @($rules | ForEach-Object { Get-EligTestStep -Rule $_ })
                # One module-scope call per platform: evaluate every rule with and without -ExportDone.
                $verdicts = InModuleScope Vacate -Parameters @{ Ss = $steps; Rs = $rules } {
                    param($Ss, $Rs)
                    for ($i = 0; $i -lt $Rs.Count; $i++) {
                        , @(
                            (Get-VacateCleanEligibility -Step $Ss[$i] -Rule $Rs[$i] -ExportConfirmed $false),
                            (Get-VacateCleanEligibility -Step $Ss[$i] -Rule $Rs[$i] -ExportConfirmed $true)
                        )
                    }
                }
                $verdicts = @($verdicts)
                $verdicts.Count | Should -Be $rules.Count
                $eligibleConfirmed = 0; $eligibleUnconfirmed = 0
                for ($i = 0; $i -lt $rules.Count; $i++) {
                    $r = $rules[$i]
                    $a = $verdicts[$i][0]; $b = $verdicts[$i][1]
                    if ($a.eligible) { $eligibleUnconfirmed++ }
                    if (([string]$r.id).StartsWith('activity.ds-store.', [StringComparison]::Ordinal)) {
                        $dsStore++
                        $b.eligible | Should -BeFalse -Because "$($r.id) reports the containing folder"
                    }
                    if ($b.eligible) {
                        $eligibleConfirmed++
                        [string]$r.category | Should -Not -Be 'wallets'
                        ([string]$r.id).StartsWith('files.', [StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
                        [string]$r.locator.kind | Should -BeExactly 'path'
                        $userRoots -ccontains [string]$r.locator.root | Should -BeTrue
                        $r.requiresElevation | Should -BeFalse
                        [string]$r.cleanup.action | Should -BeExactly 'remove'
                        ([string]$r.id).StartsWith('activity.ds-store.', [StringComparison]::Ordinal) | Should -BeFalse
                        $null -eq $r.locator.PSObject.Properties['include'] | Should -BeTrue
                        $rec = $r.locator.PSObject.Properties['recurse']
                        ($null -eq $rec -or $rec.Value -ne $true) | Should -BeTrue
                        $manualOnly -ccontains [string]$r.id | Should -BeFalse
                    }
                }
                $total += $eligibleConfirmed
                Write-Information -MessageData ('ELIGIBLE [{0}] rules={1} eligible={2} (with -ExportDone: {3})' -f $pl, $rules.Count, $eligibleUnconfirmed, $eligibleConfirmed) -InformationAction Continue
            }
            $total | Should -BeGreaterThan 0
            $dsStore | Should -BeGreaterThan 0
        }
    }
}
