BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-PlanTestCleanup {
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

    function Get-PlanTestRule {
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

    function Get-PlanTestTrace {
        param([string]$RuleId, [string]$Path, [string]$Category = 'browsers', [string]$Sensitivity = 'medium')
        return [pscustomobject][ordered]@{
            ruleId = $RuleId; platform = 'windows'; category = $Category; title = "Title of $RuleId"; sensitivity = $Sensitivity
            locator = [pscustomobject]@{ kind = 'path'; resolved = $Path }; exists = $true; sizeBytes = 2048; itemCount = 3
            lastWriteTime = $null; samples = @(); truncated = $false; confidence = 'unverified'; requiresElevation = $false; error = ''
        }
    }

    function Get-PlanTestReport {
        param([object[]]$Traces, [bool]$Complete = $true, [bool]$Redacted = $false, [string]$Platform = 'windows')
        return [pscustomobject][ordered]@{
            tool = [pscustomobject]@{ name = 'vacate'; version = '0.1.0' }
            scan = [pscustomobject][ordered]@{ platform = $Platform; finishedAt = '2026-11-20T10:00:00Z'; complete = $Complete; redacted = $Redacted }
            traces = $Traces
        }
    }

    function Invoke-TestPlan {
        param([object]$Report, [object[]]$Rules)
        return InModuleScope Vacate -Parameters @{ Rep = $Report; Ru = $Rules } {
            param($Rep, $Ru)
            New-VacatePlan -Report $Rep -Rules $Ru -Now ([datetime]'2026-11-20T12:00:00Z')
        }
    }

    $script:Rules = @(
        (Get-PlanTestRule 'browser.a.remove' -Cleanup (Get-PlanTestCleanup 'remove' @('App B', 'App A')))
        (Get-PlanTestRule 'wallet.z.export' -Category 'wallets' -Sensitivity 'low' -Cleanup (Get-PlanTestCleanup 'export-then-remove' @('App A')))
        (Get-PlanTestRule 'wallet.y.export' -Category 'wallets' -Sensitivity 'critical' -Cleanup (Get-PlanTestCleanup 'export-then-remove'))
        (Get-PlanTestRule 'cloud.b.signout' -Cleanup (Get-PlanTestCleanup 'sign-out-then-remove'))
        (Get-PlanTestRule 'system.c.none' -Cleanup (Get-PlanTestCleanup 'none'))
        (Get-PlanTestRule 'app.d.noguide')
    )
    $script:Traces = @(
        (Get-PlanTestTrace 'browser.a.remove' 'C:\a1')
        (Get-PlanTestTrace 'browser.a.remove' 'C:\a2')
        (Get-PlanTestTrace 'system.c.none' 'C:\c')
        (Get-PlanTestTrace 'app.d.noguide' 'C:\d')
        (Get-PlanTestTrace 'gone.e.missing' 'C:\e')
        (Get-PlanTestTrace 'cloud.b.signout' 'C:\b')
        (Get-PlanTestTrace 'wallet.z.export' 'C:\z' 'wallets' 'low')
        (Get-PlanTestTrace 'wallet.y.export' 'C:\y' 'wallets' 'critical')
    )
}

Describe 'New-VacatePlan' {
    It 'covers every trace exactly once' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules
        $plan.summary.traces | Should -Be 8
        $plan.summary.tracesCovered | Should -Be 8
        $paths = @($plan.steps | ForEach-Object { $_.locations } | ForEach-Object { $_.resolved } | Sort-Object)
        $paths -join ',' | Should -Be 'C:\a1,C:\a2,C:\b,C:\c,C:\d,C:\e,C:\y,C:\z'
    }

    It 'makes one step per rule with all its locations' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules
        $plan.summary.steps | Should -Be 7
        $a = @($plan.steps | Where-Object { $_.ruleId -ceq 'browser.a.remove' })[0]
        @($a.locations).Count | Should -Be 2
    }

    It 'orders by stage, then sensitivity, then rule id' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules
        ($plan.steps | ForEach-Object { $_.ruleId }) -join ',' | Should -Be 'wallet.y.export,wallet.z.export,cloud.b.signout,browser.a.remove,app.d.noguide,gone.e.missing,system.c.none'
        ($plan.steps | ForEach-Object { $_.step }) -join ',' | Should -Be '1,2,3,4,5,6,7'
    }

    It 'marks rules without guidance and missing rules as manual with a reason' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules
        $d = @($plan.steps | Where-Object { $_.ruleId -ceq 'app.d.noguide' })[0]
        $d.stage | Should -Be 'manual'; $d.guidance | Should -Be 'no-guidance'; $d.reason | Should -Match 'no cleanup guidance'
        $e = @($plan.steps | Where-Object { $_.ruleId -ceq 'gone.e.missing' })[0]
        $e.guidance | Should -Be 'rule-missing'; $e.reason | Should -Match 'not in this version'
        $plan.summary.noGuidance | Should -Be 1
        $plan.summary.ruleMissing | Should -Be 1
    }

    It 'copies cleanup fields into the step' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules
        $y = @($plan.steps | Where-Object { $_.ruleId -ceq 'wallet.y.export' })[0]
        $y.action | Should -Be 'export-then-remove'
        $y.exportFirst | Should -Match 'Export'
        @($y.instructions).Count | Should -Be 1
        $y.resetCovers | Should -BeTrue
        $c = @($plan.steps | Where-Object { $_.ruleId -ceq 'system.c.none' })[0]
        $c.stage | Should -Be 'no-action'; $c.reason | Should -Match 'Nothing personal'
    }

    It 'collects apps to close once, sorted' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules
        @($plan.beforeYouStart.closeApps) -join ',' | Should -Be 'App A,App B'
    }

    It 'adds the wallet warning only when wallets were found' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules
        (@($plan.beforeYouStart.notes) -join ' ') | Should -Match 'recovery phrase'
        $plan2 = Invoke-TestPlan (Get-PlanTestReport @($script:Traces[0])) $script:Rules
        (@($plan2.beforeYouStart.notes) -join ' ') | Should -Not -Match 'recovery phrase'
    }

    It 'handles a report with no traces' {
        $plan = Invoke-TestPlan (Get-PlanTestReport @()) $script:Rules
        $plan.summary.steps | Should -Be 0
        @($plan.steps).Count | Should -Be 0
        $plan.fullReset.title | Should -Be 'Reset this PC'
    }

    It 'ends with the built-in reset for <P>' -ForEach @(
        @{ P = 'windows'; T = 'Reset this PC' }
        @{ P = 'macos'; T = 'Erase All Content and Settings' }
        @{ P = 'linux'; T = 'Reinstall over the whole disk' }
    ) {
        $plan = Invoke-TestPlan (Get-PlanTestReport @() -Platform $P) @()
        $plan.fullReset.title | Should -Be $T
        $plan.fullReset.when | Should -Match 'vacate does not erase'
    }

    It 'warns when the scan was incomplete or redacted' {
        $plan = Invoke-TestPlan (Get-PlanTestReport $script:Traces -Complete $false -Redacted $true) $script:Rules
        (@($plan.limitations) -join ' ') | Should -Match 'did not finish'
        (@($plan.limitations) -join ' ') | Should -Match 'redacted'
        $plan.report.redacted | Should -BeTrue
    }

    It 'is deterministic' {
        $a = InModuleScope Vacate -Parameters @{ P = (Invoke-TestPlan (Get-PlanTestReport $script:Traces) $script:Rules) } { param($P) ConvertTo-VacateReportJson -Report $P }
        $b = InModuleScope Vacate -Parameters @{ P = (Invoke-TestPlan (Get-PlanTestReport ([object[]]($script:Traces[7..0]))) $script:Rules) } { param($P) ConvertTo-VacateReportJson -Report $P }
        ($a -replace '"resolved":\s*"[^"]*"', '') | Should -Be ($b -replace '"resolved":\s*"[^"]*"', '')
    }
}

Describe 'Plan rendering' {
    It 'Markdown keeps every line within 100 characters, even long paths' {
        $long = 'C:\' + ('x' * 250)
        $t = @($script:Traces) + @(Get-PlanTestTrace 'browser.a.remove' $long)
        $plan = Invoke-TestPlan (Get-PlanTestReport $t) $script:Rules
        $md = InModuleScope Vacate -Parameters @{ P = $plan } { param($P) ConvertTo-VacatePlanMarkdown -Plan $P }
        $max = ($md -split "`n" | Measure-Object -Property Length -Maximum).Maximum
        $max | Should -BeLessOrEqual 100
        $md | Should -Match '  - C:\\xxx'
        $md | Should -Match '## Last: Reset this PC'
    }

    It 'HTML encodes values and has no script' {
        $t = @(Get-PlanTestTrace 'browser.a.remove' 'C:\<script>alert(1)</script>')
        $plan = Invoke-TestPlan (Get-PlanTestReport $t) $script:Rules
        $html = InModuleScope Vacate -Parameters @{ P = $plan } { param($P) ConvertTo-VacatePlanHtml -Plan $P }
        $html | Should -Not -Match '<script'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Match 'Dry run'
    }
}

Describe 'Invoke-VacatePlan' {
    BeforeEach {
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ('vacate-plan-' + [guid]::NewGuid().ToString('N'))
        $script:RunDir = Join-Path $script:Base '20261120-100000'
        [void][IO.Directory]::CreateDirectory($script:RunDir)
    }
    AfterEach { if (Test-Path $script:Base) { Remove-Item -LiteralPath $script:Base -Recurse -Force } }

    It 'writes plan.json, plan.md and plan.html into the run folder only' {
        $rep = Get-PlanTestReport @(Get-PlanTestTrace 'browser.chrome.history' 'C:\h')
        [IO.File]::WriteAllText((Join-Path $script:RunDir 'report.json'), ($rep | ConvertTo-Json -Depth 8))
        $written = @(InModuleScope Vacate -Parameters @{ D = $script:RunDir } { param($D) Invoke-VacatePlan -Run $D })
        $written.Count | Should -Be 3
        @(Get-ChildItem -LiteralPath $script:RunDir | ForEach-Object Name | Sort-Object) -join ',' | Should -Be 'plan.html,plan.json,plan.md,report.json'
        @(Get-ChildItem -LiteralPath $script:Base).Count | Should -Be 1
        $plan = Get-Content (Join-Path $script:RunDir 'plan.json') -Raw | ConvertFrom-Json
        $plan.summary.tracesCovered | Should -Be 1
    }

    It 'fails clearly without report.json' {
        { InModuleScope Vacate -Parameters @{ D = $script:RunDir } { param($D) Invoke-VacatePlan -Run $D } } | Should -Throw '*No report.json*'
    }
}
