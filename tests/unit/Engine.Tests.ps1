BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestRule {
        param([string]$Id, [string]$Kind = 'path', [string]$Category = 'browsers', [bool]$Elev = $false, [string]$Root = 'HOME', [bool]$Verified = $true)
        $loc = [pscustomobject]@{ kind = $Kind; root = $Root; path = 'x'; match = 'files' }
        return [pscustomobject]@{ id = $Id; platforms = @('windows'); category = $Category; title = "T $Id"; whyItMatters = 'Because it matters a lot.'; sensitivity = 'high'; locator = $loc; measure = @('exists'); maxEntries = 10; requiresElevation = $Elev; verifiedOn = @(); verified = $Verified; source = 'test source text'; notes = $null }
    }
    function Get-TestContext {
        param([bool]$Elevated = $false)
        $p = [pscustomobject]@{ Name = 'windows'; CaseSensitive = $false; Comparison = [StringComparison]::OrdinalIgnoreCase; Separator = [char]'\'; Roots = [ordered]@{ HOME = 'C:\Users\t' }; HomePath = 'C:\Users\t'; UsersRoot = 'C:\Users'; UserName = 't' }
        return [pscustomobject]@{ Platform = $p; FileSystem = $null; Registry = $null; Cim = $null; SystemQuery = $null; Elevated = $Elevated; MountPoints = @(); Exclude = @() }
    }
    function Get-TestClock {
        # Fake clock: advances by -Step seconds on every read.
        param([double]$Step = 0)
        $state = @{ t = [datetime]::SpecifyKind([datetime]'2026-11-19 10:00:00', [DateTimeKind]::Utc) }
        return { $state.t = $state.t.AddSeconds($Step); $state.t }.GetNewClosure()
    }
    $script:okExec = {
        param($Rule, $Context, $Deadline)
        $t = InModuleScope Vacate -Parameters @{ R = $Rule } { param($R) New-VacateTrace -Rule $R -Platform 'windows' -Resolved ('C:\x\' + $R.id) -SizeBytes 10 -ItemCount 1 }
        return [pscustomobject]@{ Traces = @($t); Skips = @(); Errors = @(); Programs = @() }
    }
}

Describe 'Invoke-VacateEngine' {
    It 'runs rules, sorts traces by category then id, and records the log' {
        $rules = @((Get-TestRule 'z.rule' -Category 'activity'), (Get-TestRule 'a.rule' -Category 'wallets'), (Get-TestRule 'b.rule' -Category 'activity'))
        $res = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        @($res.Traces | ForEach-Object { $_.ruleId }) | Should -Be @('b.rule', 'z.rule', 'a.rule')
        @($res.Log).Count | Should -Be 3
    }

    It 'skips elevation-only rules when not elevated and runs them when elevated' {
        $rules = @(Get-TestRule 'needs.admin' -Elev $true)
        $res = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        $res.Skips[0].reason | Should -Be 'requires-elevation'
        @($res.Traces).Count | Should -Be 0
        $res2 = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext -Elevated $true); E = @{ path = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        @($res2.Traces).Count | Should -Be 1
    }

    It 'marks a rule unavailable when its root is missing on this machine' {
        $rules = @(Get-TestRule 'no.root' -Root 'LOCALAPPDATA')
        $res = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        $res.Skips[0].reason | Should -Be 'unavailable'
    }

    It 'never aborts on a rule failure' {
        $boom = { param($Rule, $Context, $Deadline) throw [IO.IOException]'disk hiccup' }
        $rules = @((Get-TestRule 'a.fail'), (Get-TestRule 'b.ok' -Kind 'registry'))
        $res = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $boom; registry = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        $res.Errors[0].ruleId | Should -Be 'a.fail'
        $res.Errors[0].type | Should -Be 'IOException'
        @($res.Traces | ForEach-Object { $_.ruleId }) | Should -Be @('b.ok')
    }

    It 'records an error for a kind with no executor' {
        $rules = @(Get-TestRule 'w.rule' -Kind 'wmi')
        $res = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        $res.Errors[0].message | Should -Match "No executor for locator kind 'wmi'"
    }

    It 'stops starting rules when the budget is used up and labels the rest' {
        $rules = @(1..6 | ForEach-Object { Get-TestRule ('r.' + $_) })
        $clock = Get-TestClock -Step 1
        $res = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $okExec }; K = $clock } { param($R, $C, $E, $K) Invoke-VacateEngine -Rules $R -Context $C -Executors $E -BudgetSeconds 4 -Clock $K }
        @($res.Traces).Count | Should -BeLessThan 6
        @($res.Traces).Count | Should -BeGreaterThan 0
        @($res.Skips | Where-Object { $_.reason -eq 'budget' }).Count | Should -Be (6 - @($res.Traces).Count)
    }

    It 'gives each rule a deadline no later than the global budget' {
        $seen = New-Object System.Collections.Generic.List[datetime]
        $spy = { param($Rule, $Context, $Deadline) $seen.Add($Deadline); return [pscustomobject]@{ Traces = @(); Skips = @(); Errors = @(); Programs = @() } }.GetNewClosure()
        $clock = Get-TestClock -Step 0
        InModuleScope Vacate -Parameters @{ R = @(Get-TestRule 'd.rule'); C = (Get-TestContext); E = @{ path = $spy }; K = $clock } { param($R, $C, $E, $K) Invoke-VacateEngine -Rules $R -Context $C -Executors $E -BudgetSeconds 5 -RuleTimeoutSeconds 10 -Clock $K } | Out-Null
        ($seen[0] - [datetime]::SpecifyKind([datetime]'2026-11-19 10:00:00', [DateTimeKind]::Utc)).TotalSeconds | Should -Be 5
    }
}

Describe 'Select-VacateMeasure' {
    It 'keeps only the metadata the rule asks for' {
        $r = Get-TestRule 'm.rule'
        $r.measure = @('exists', 'lastWriteTime')
        $res = InModuleScope Vacate -Parameters @{ R = @($r); C = (Get-TestContext); E = @{ path = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        $t = $res.Traces[0]
        $t.sizeBytes | Should -BeNullOrEmpty
        $t.itemCount | Should -BeNullOrEmpty
        $t.exists | Should -BeTrue
        $t.locator.resolved | Should -Not -BeNullOrEmpty
    }

    It 'keeps size and count when they are declared' {
        $r = Get-TestRule 'm.full'
        $r.measure = @('exists', 'sizeBytes', 'itemCount')
        $res = InModuleScope Vacate -Parameters @{ R = @($r); C = (Get-TestContext); E = @{ path = $okExec } } { param($R, $C, $E) Invoke-VacateEngine -Rules $R -Context $C -Executors $E }
        $res.Traces[0].sizeBytes | Should -Be 10
        $res.Traces[0].itemCount | Should -Be 1
    }

    It 'filters registry counts and drops undeclared properties' {
        InModuleScope Vacate {
            $reg = [pscustomobject]@{ locator = [pscustomobject]@{ kind = 'registry' }; measure = @('exists', 'valueCount') }
            $t = [pscustomobject]@{ sizeBytes = $null; lastWriteTime = $null; itemCount = 5; properties = [pscustomobject]@{ valueCount = 3; subkeyCount = 2 } }
            $o = Select-VacateMeasure -Trace $t -Rule $reg
            $o.itemCount | Should -Be 5
            @($o.properties.PSObject.Properties.Name) | Should -Be @('valueCount')
            $wmi = [pscustomobject]@{ locator = [pscustomobject]@{ kind = 'wmi' }; measure = @('exists') }
            $t2 = [pscustomobject]@{ sizeBytes = $null; lastWriteTime = $null; itemCount = $null; properties = [pscustomobject]@{ DriveLetter = 'C:' } }
            (Select-VacateMeasure -Trace $t2 -Rule $wmi).PSObject.Properties['properties'] | Should -BeNullOrEmpty
        }
    }
}

Describe 'Summary and report assembly' {
    It 'computes rule status exactly as documented' {
        $traces = @([pscustomobject]@{ ruleId = 'a'; category = 'browsers'; sizeBytes = 100; sensitivity = 'high' }, [pscustomobject]@{ ruleId = 'a'; category = 'browsers'; sizeBytes = $null; sensitivity = 'critical' }, [pscustomobject]@{ ruleId = 'c'; category = 'activity'; sizeBytes = 5; sensitivity = 'low' })
        $skips = @([pscustomobject]@{ ruleId = 'a'; reason = 'permission' }, [pscustomobject]@{ ruleId = 'b'; reason = 'budget' }, [pscustomobject]@{ ruleId = 'd'; reason = 'timeout' })
        $errs = @([pscustomobject]@{ ruleId = 'd'; message = 'x'; type = 'y' })
        $s = InModuleScope Vacate -Parameters @{ T = $traces; S = $skips; E = $errs } { param($T, $S, $E) Get-VacateSummary -Traces $T -Skipped $S -Errors $E -TotalRules 5 -NotApplicable 7 }
        $s.rulesFailed | Should -Be 1
        $s.rulesSkipped | Should -Be 1
        $s.rulesRun | Should -Be 3
        $s.tracesFound | Should -Be 3
        $s.totalBytes | Should -Be 105
        @($s.byCategory | ForEach-Object { $_.category }) | Should -Be @('activity', 'browsers')
        ($s.byCategory | Where-Object { $_.category -eq 'browsers' }).highestSensitivity | Should -Be 'critical'
        InModuleScope Vacate -Parameters @{ S = $skips } { param($S) Test-VacateScanComplete -Skipped $S } | Should -BeFalse
        InModuleScope Vacate { Test-VacateScanComplete -Skipped @([pscustomobject]@{ reason = 'permission' }) } | Should -BeTrue
    }

    It 'builds a report that validates against the schema (PowerShell 7)' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        $rules = @((Get-TestRule 'b.rule' -Verified $false), (Get-TestRule 'a.rule'))
        $schema = Join-Path $PSScriptRoot '../../schemas/report.schema.json'
        $json = InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $okExec } } {
            param($R, $C, $E)
            $res = Invoke-VacateEngine -Rules $R -Context $C -Executors $E
            $hostInfo = [pscustomobject][ordered]@{ name = 'PC'; os = 'Windows'; version = '10'; architecture = 'X64'; user = 't'; volumes = @() }
            $t0 = [datetime]::SpecifyKind([datetime]'2026-11-19 10:00:00', [DateTimeKind]::Utc)
            $rep = New-VacateReport -EngineResult $res -Rules $R -NotApplicable 3 -InvalidFiles 0 -Platform 'windows' -HostInfo $hostInfo -StartedAt $t0 -FinishedAt $t0.AddSeconds(2) -Elevated $false -BudgetSeconds 120 -RuleTimeoutSeconds 10
            ConvertTo-VacateReportJson -Report $rep
        }
        Test-Json -Json $json -SchemaFile $schema | Should -BeTrue
        $o = $json | ConvertFrom-Json
        @($o.catalog.unverified) | Should -Be @('b.rule')
        $o.summary.tracesFound | Should -Be @($o.traces).Count
        $o.scan.durationMs | Should -Be 2000
        $o.catalog.rulesLoaded | Should -Be 5
    }

    It 'produces identical JSON for identical input (determinism)' {
        $rules = @((Get-TestRule 'b.rule'), (Get-TestRule 'a.rule'))
        $run = {
            InModuleScope Vacate -Parameters @{ R = $rules; C = (Get-TestContext); E = @{ path = $okExec } } {
                param($R, $C, $E)
                $res = Invoke-VacateEngine -Rules $R -Context $C -Executors $E
                $hostInfo = [pscustomobject][ordered]@{ name = 'PC'; os = 'W'; version = '1'; architecture = 'X64'; user = 't'; volumes = @() }
                $t0 = [datetime]::SpecifyKind([datetime]'2026-11-19 10:00:00', [DateTimeKind]::Utc)
                ConvertTo-VacateReportJson -Report (New-VacateReport -EngineResult $res -Rules $R -NotApplicable 0 -InvalidFiles 0 -Platform 'windows' -HostInfo $hostInfo -StartedAt $t0 -FinishedAt $t0 -Elevated $false -BudgetSeconds 120 -RuleTimeoutSeconds 10)
            }
        }
        (& $run) | Should -Be (& $run)
    }
}

Describe 'Output writer' {
    BeforeAll { $script:base = Join-Path ([IO.Path]::GetTempPath()) ('vacate-runs-' + [guid]::NewGuid().ToString('N')) ; [void][IO.Directory]::CreateDirectory($script:base) }
    AfterAll { if ([IO.Directory]::Exists($script:base)) { [IO.Directory]::Delete($script:base, $true) } }

    It 'creates unique timestamped run folders' {
        $now = [datetime]::SpecifyKind([datetime]'2026-11-19 10:00:00', [DateTimeKind]::Utc)
        $a = InModuleScope Vacate -Parameters @{ B = $base; N = $now } { param($B, $N) New-VacateRunFolder -BaseDir $B -Now $N }
        $b = InModuleScope Vacate -Parameters @{ B = $base; N = $now } { param($B, $N) New-VacateRunFolder -BaseDir $B -Now $N }
        [IO.Path]::GetFileName($a) | Should -Be '20261119-100000'
        [IO.Path]::GetFileName($b) | Should -Be '20261119-100000-2'
    }

    It 'writes UTF-8 without BOM inside the base and refuses to write outside it' {
        $p = Join-Path $base 'x.txt'
        InModuleScope Vacate -Parameters @{ B = $base; P = $p } { param($B, $P) Write-VacateTextFile -BaseDir $B -Path $P -Text ('caf' + [char]0x00E9) }
        $bytes = [IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Not -Be 0xEF
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Be ('caf' + [char]0x00E9)
        $outside = Join-Path ([IO.Path]::GetTempPath()) ('vacate-evil-' + [guid]::NewGuid().ToString('N') + '.txt')
        { InModuleScope Vacate -Parameters @{ B = $base; P = $outside } { param($B, $P) Write-VacateTextFile -BaseDir $B -Path $P -Text 'x' } } | Should -Throw -ExpectedMessage 'output:*'
        [IO.File]::Exists($outside) | Should -BeFalse
        $sneaky = Join-Path $base '..\escape.txt'
        { InModuleScope Vacate -Parameters @{ B = $base; P = $sneaky } { param($B, $P) Write-VacateTextFile -BaseDir $B -Path $P -Text 'x' } } | Should -Throw -ExpectedMessage 'output:*'
    }
}
