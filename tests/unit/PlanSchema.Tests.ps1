BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:PlanSchemaPath = Join-Path $PSScriptRoot '../../schemas/plan.schema.json'

    # Fixtures copied from Planner.Tests.ps1 so this file stands alone.
    function Get-PlanSchemaCleanup {
        param([string]$Action, [string[]]$Apps = @())
        $c = [ordered]@{
            action = $Action; exportFirst = $null; signOut = $null
            steps = @('Do the first manual thing.'); risk = 'Something is lost when you do this.'
            closeApps = $Apps; resetCovers = $true; reason = $null; source = 'Vendor help page: https://example.invalid/help'
        }
        if ($Action -ceq 'export-then-remove') { $c.exportFirst = 'Export the data you want to keep.' }
        if ($Action -ceq 'sign-out-then-remove') { $c.signOut = 'Sign out in the account settings.' }
        if ($Action -ceq 'none') { $c.steps = @(); $c.reason = 'Nothing personal is stored here.'; $c.resetCovers = $false }
        return $c
    }

    function Get-PlanSchemaRule {
        param([string]$Id, [string]$Category = 'browsers', [string]$Sensitivity = 'medium', [object]$Cleanup = $null)
        $r = [ordered]@{
            id = $Id; platforms = @('windows'); category = $Category; title = "Title of $Id"
            whyItMatters = 'Because it matters a lot.'; sensitivity = $Sensitivity
            locator = [ordered]@{ kind = 'path'; root = 'HOME'; path = 'x'; match = 'any' }
            measure = @('exists'); maxEntries = 10; requiresElevation = $false; verifiedOn = @(); verified = $false
            source = 'Some vendor documentation'; notes = $null
        }
        if ($null -ne $Cleanup) { $r.cleanup = $Cleanup }
        return (($r | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
    }

    function Get-PlanSchemaTrace {
        param([string]$RuleId, [string]$Path, [string]$Category = 'browsers', [string]$Sensitivity = 'medium')
        return [pscustomobject][ordered]@{
            ruleId = $RuleId; platform = 'windows'; category = $Category; title = "Title of $RuleId"; sensitivity = $Sensitivity
            locator = [pscustomobject]@{ kind = 'path'; resolved = $Path }; exists = $true; sizeBytes = 2048; itemCount = 3
            lastWriteTime = $null; samples = @(); truncated = $false; confidence = 'unverified'; requiresElevation = $false; error = ''
        }
    }

    function Get-PlanSchemaReport {
        param([object[]]$Traces, [bool]$Complete = $true, [bool]$Redacted = $false, [string]$Platform = 'windows')
        return [pscustomobject][ordered]@{
            tool = [pscustomobject]@{ name = 'vacate'; version = '0.1.0' }
            scan = [pscustomobject][ordered]@{ platform = $Platform; finishedAt = '2026-11-20T10:00:00Z'; complete = $Complete; redacted = $Redacted }
            traces = $Traces
        }
    }

    function Get-PlanSchemaPlan {
        param([object]$Report, [object[]]$Rules)
        return InModuleScope Vacate -Parameters @{ Rep = $Report; Ru = $Rules } {
            param($Rep, $Ru)
            New-VacatePlan -Report $Rep -Rules $Ru -Now ([datetime]'2026-11-20T12:00:00Z')
        }
    }

    # Same serialization the tool uses to write plan.json.
    function ConvertTo-PlanSchemaJson {
        param([object]$Plan)
        return InModuleScope Vacate -Parameters @{ P = $Plan } { param($P) ConvertTo-VacateReportJson -Report $P }
    }

    function Test-PlanSchemaSkipped {
        # Test-Json -SchemaFile needs PowerShell 7 (same skip as the report schema tests).
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Test-Json requires PowerShell 7'
            return $true
        }
        return $false
    }

    $script:Rules = @(
        (Get-PlanSchemaRule 'browser.a.export' -Cleanup (Get-PlanSchemaCleanup 'export-then-remove' @('App A')))
        (Get-PlanSchemaRule 'cloud.b.signout' -Cleanup (Get-PlanSchemaCleanup 'sign-out-then-remove'))
        (Get-PlanSchemaRule 'app.c.uninstall' -Cleanup (Get-PlanSchemaCleanup 'uninstall'))
        (Get-PlanSchemaRule 'activity.d.remove' -Cleanup (Get-PlanSchemaCleanup 'remove' @('App B')))
        (Get-PlanSchemaRule 'files.e.review' -Cleanup (Get-PlanSchemaCleanup 'review'))
        (Get-PlanSchemaRule 'system.f.none' -Cleanup (Get-PlanSchemaCleanup 'none'))
        (Get-PlanSchemaRule 'app.g.noguide')
    )
    $script:Traces = @(
        (Get-PlanSchemaTrace 'browser.a.export' 'C:\a')
        (Get-PlanSchemaTrace 'cloud.b.signout' 'C:\b')
        (Get-PlanSchemaTrace 'app.c.uninstall' 'C:\c')
        (Get-PlanSchemaTrace 'activity.d.remove' 'C:\d')
        (Get-PlanSchemaTrace 'files.e.review' 'C:\e')
        (Get-PlanSchemaTrace 'system.f.none' 'C:\f')
        (Get-PlanSchemaTrace 'app.g.noguide' 'C:\g')
        (Get-PlanSchemaTrace 'gone.h.missing' 'C:\h')
    )
}

Describe 'plan.schema.json' {
    It 'accepts a plan that uses every stage' {
        if (Test-PlanSchemaSkipped) { return }
        $plan = Get-PlanSchemaPlan (Get-PlanSchemaReport $script:Traces) $script:Rules
        $json = ConvertTo-PlanSchemaJson -Plan $plan
        Test-Json -Json $json -SchemaFile $script:PlanSchemaPath | Should -BeTrue
        $plan.summary.withGuidance | Should -Be 6
        $plan.summary.noGuidance | Should -Be 1
        $plan.summary.ruleMissing | Should -Be 1
    }

    It 'accepts a plan with no traces' {
        if (Test-PlanSchemaSkipped) { return }
        $plan = Get-PlanSchemaPlan (Get-PlanSchemaReport @()) $script:Rules
        @($plan.steps).Count | Should -Be 0
        Test-Json -Json (ConvertTo-PlanSchemaJson -Plan $plan) -SchemaFile $script:PlanSchemaPath | Should -BeTrue
    }

    It 'accepts a plan for a rule that is missing from the catalog' {
        if (Test-PlanSchemaSkipped) { return }
        $traces = @((Get-PlanSchemaTrace 'gone.h.missing' 'C:\h'))
        $plan = Get-PlanSchemaPlan (Get-PlanSchemaReport $traces) $script:Rules
        $step = @($plan.steps)[0]
        $step.guidance | Should -Be 'rule-missing'
        $step.action | Should -BeNullOrEmpty
        Test-Json -Json (ConvertTo-PlanSchemaJson -Plan $plan) -SchemaFile $script:PlanSchemaPath | Should -BeTrue
    }

    It 'accepts a plan for a rule without cleanup guidance' {
        if (Test-PlanSchemaSkipped) { return }
        $traces = @((Get-PlanSchemaTrace 'app.g.noguide' 'C:\g'))
        $plan = Get-PlanSchemaPlan (Get-PlanSchemaReport $traces) $script:Rules
        $step = @($plan.steps)[0]
        $step.guidance | Should -Be 'no-guidance'
        @($step.instructions).Count | Should -Be 0
        Test-Json -Json (ConvertTo-PlanSchemaJson -Plan $plan) -SchemaFile $script:PlanSchemaPath | Should -BeTrue
    }

    It 'accepts a plan built from an incomplete, redacted report' {
        if (Test-PlanSchemaSkipped) { return }
        $plan = Get-PlanSchemaPlan (Get-PlanSchemaReport $script:Traces -Complete $false -Redacted $true -Platform 'linux') $script:Rules
        @($plan.limitations).Count | Should -BeGreaterThan 3
        Test-Json -Json (ConvertTo-PlanSchemaJson -Plan $plan) -SchemaFile $script:PlanSchemaPath | Should -BeTrue
    }

    It 'rejects a plan with an unknown top-level property' {
        if (Test-PlanSchemaSkipped) { return }
        $plan = Get-PlanSchemaPlan (Get-PlanSchemaReport $script:Traces) $script:Rules
        $plan | Add-Member -NotePropertyName 'unexpected' -NotePropertyValue 'extra'
        $json = ConvertTo-PlanSchemaJson -Plan $plan
        $threw = $false
        try { $null = Test-Json -Json $json -SchemaFile $script:PlanSchemaPath -ErrorAction Stop } catch { $threw = $true }
        $threw | Should -BeTrue
    }

    It 'rejects a plan whose step has an unknown property' {
        if (Test-PlanSchemaSkipped) { return }
        $plan = Get-PlanSchemaPlan (Get-PlanSchemaReport $script:Traces) $script:Rules
        $step = @($plan.steps)[0]
        $step | Add-Member -NotePropertyName 'deleteCommand' -NotePropertyValue 'nothing runs this'
        $json = ConvertTo-PlanSchemaJson -Plan $plan
        $threw = $false
        try { $null = Test-Json -Json $json -SchemaFile $script:PlanSchemaPath -ErrorAction Stop } catch { $threw = $true }
        $threw | Should -BeTrue
    }
}
