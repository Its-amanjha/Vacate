# Compare.Tests.ps1 - unit tests for compare logic, renderers and schema.
# PowerShell 5.1 compatible. ASCII only.

Set-StrictMode -Version Latest

BeforeAll {
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $script:repo 'src/Vacate/Vacate.psm1') -Force
    $script:CompareSchemaPath = Join-Path $script:repo 'schemas/compare.schema.json'

    function Get-TestReport {
        param(
            [string]$Platform = 'windows',
            [string]$Machine = 'TEST-PC',
            [datetime]$FinishedAt = [datetime]::UtcNow,
            [bool]$Redacted = $false,
            [object[]]$Traces = @(),
            [object[]]$CatalogRules = @(),
            [object[]]$Skipped = @(),
            [object[]]$Errors = @()
        )
        $rules = New-Object System.Collections.Generic.List[object]
        foreach ($r in $CatalogRules) {
            $rules.Add([pscustomobject][ordered]@{
                id           = [string]$r.id
                category     = [string]$r.category
                title        = [string]$r.title
                whyItMatters = 'why'
                sensitivity  = 'medium'
                source       = 'source'
                verified     = $true
            })
        }
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            tool          = [pscustomobject][ordered]@{ name = 'vacate'; version = '0.1.0' }
            scan          = [pscustomobject][ordered]@{
                startedAt          = (InModuleScope Vacate -Parameters @{ T = $FinishedAt.AddSeconds(-10) } { param($T) ConvertTo-VacateIsoTime $T })
                finishedAt         = (InModuleScope Vacate -Parameters @{ T = $FinishedAt } { param($T) ConvertTo-VacateIsoTime $T })
                durationMs         = 10000
                platform           = $Platform
                elevated           = $false
                budgetSeconds      = 120
                ruleTimeoutSeconds = 10
                complete           = $true
                redacted           = $Redacted
                host               = [pscustomobject][ordered]@{
                    name         = $Machine
                    os           = 'Windows 11'
                    version      = '10.0'
                    architecture = 'X64'
                    user         = 'tester'
                    volumes      = @()
                }
            }
            catalog       = [pscustomobject][ordered]@{
                version      = '0.1.0'
                rulesLoaded  = $rules.Count
                unverified   = @()
                invalidFiles = 0
                rules        = $rules.ToArray()
            }
            summary       = [pscustomobject][ordered]@{
                byCategory         = @()
                totalRules         = $rules.Count
                rulesRun           = $rules.Count
                rulesSkipped       = @($Skipped).Count
                rulesFailed        = @($Errors).Count
                rulesNotApplicable = 0
                tracesFound        = @($Traces).Count
                totalBytes         = 1000
            }
            traces        = @($Traces)
            skipped       = @($Skipped)
            errors        = @($Errors)
            limitations   = @([pscustomobject][ordered]@{ scope = 'all'; text = 'A limitation note here.' })
        }
    }

    function Get-TestTrace {
        param(
            [string]$RuleId,
            [string]$Path,
            [string]$Category = 'browser',
            [string]$Title = 'Title',
            [int]$SizeBytes = 100,
            [string]$LastWriteTime = '2026-11-20T10:00:00Z',
            [string]$Kind = 'path'
        )
        return [pscustomobject][ordered]@{
            ruleId            = $RuleId
            platform          = 'windows'
            category          = $Category
            title             = $Title
            sensitivity       = 'medium'
            locator           = [pscustomobject][ordered]@{ kind = $Kind; resolved = $Path }
            exists            = $true
            sizeBytes         = $SizeBytes
            itemCount         = 1
            lastWriteTime     = $LastWriteTime
            samples           = @()
            truncated         = $false
            confidence        = 'verified'
            requiresElevation = $false
            error             = $null
        }
    }
}

Describe 'Vacate Compare Unit Tests' {
    It 'reports zero changes when both scans are empty' {
        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z')
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z')

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data.summary.gone | Should -Be 0
        $data.summary.stillThere | Should -Be 0
        $data.summary.new | Should -Be 0
        $data.summary.notComparable | Should -Be 0
    }

    It 'detects gone traces when older has trace and newer does not' {
        $rule = [pscustomobject]@{ id = 'rule.a'; category = 'browser'; title = 'Rule A' }
        $t1 = Get-TestTrace -RuleId 'rule.a' -Path 'C:\data\a.txt' -SizeBytes 200
        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z') -CatalogRules @($rule) -Traces @($t1)
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z') -CatalogRules @($rule) -Traces @()

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data.summary.gone | Should -Be 1
        $data.summary.stillThere | Should -Be 0
        $data.summary.new | Should -Be 0
        @($data.gone)[0].ruleId | Should -Be 'rule.a'
        @($data.gone)[0].sizeBytes | Should -Be 200
    }

    It 'detects still-there traces and computes size delta and dates' {
        $rule = [pscustomobject]@{ id = 'rule.a'; category = 'browser'; title = 'Rule A' }
        $t1 = Get-TestTrace -RuleId 'rule.a' -Path 'C:\data\a.txt' -SizeBytes 200 -LastWriteTime '2026-11-20T10:00:00Z'
        $t2 = Get-TestTrace -RuleId 'rule.a' -Path 'C:\data\a.txt' -SizeBytes 350 -LastWriteTime '2026-11-20T12:00:00Z'

        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z') -CatalogRules @($rule) -Traces @($t1)
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z') -CatalogRules @($rule) -Traces @($t2)

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data.summary.gone | Should -Be 0
        $data.summary.stillThere | Should -Be 1
        $data.summary.new | Should -Be 0
        $st = @($data.stillThere)[0]
        $st.olderSizeBytes | Should -Be 200
        $st.newerSizeBytes | Should -Be 350
        $st.sizeDeltaBytes | Should -Be 150
        $st.olderLastWriteTime | Should -Be '2026-11-20T10:00:00Z'
        $st.newerLastWriteTime | Should -Be '2026-11-20T12:00:00Z'
    }

    It 'detects new traces in newer scan' {
        $rule = [pscustomobject]@{ id = 'rule.a'; category = 'browser'; title = 'Rule A' }
        $t2 = Get-TestTrace -RuleId 'rule.a' -Path 'C:\data\new.txt' -SizeBytes 500

        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z') -CatalogRules @($rule) -Traces @()
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z') -CatalogRules @($rule) -Traces @($t2)

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data.summary.gone | Should -Be 0
        $data.summary.stillThere | Should -Be 0
        $data.summary.new | Should -Be 1
        @($data.new)[0].ruleId | Should -Be 'rule.a'
    }

    It 'does NOT count older traces as gone when a rule is skipped in newer scan (not comparable)' {
        $rule = [pscustomobject]@{ id = 'rule.skip'; category = 'system'; title = 'Rule Skip' }
        $t1 = Get-TestTrace -RuleId 'rule.skip' -Path 'C:\data\skipped.txt' -SizeBytes 100

        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z') -CatalogRules @($rule) -Traces @($t1)
        $skipItem = [pscustomobject]@{ ruleId = 'rule.skip'; reason = 'budget'; detail = 'timed out' }
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z') -CatalogRules @($rule) -Traces @() -Skipped @($skipItem)

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data.summary.gone | Should -Be 0
        $data.summary.notComparable | Should -Be 1
        @($data.notComparable)[0].ruleId | Should -Be 'rule.skip'
        @($data.notComparable)[0].reason | Should -Match 'budget'
    }

    It 'matches traces properly when both scans are redacted' {
        $rule = [pscustomobject]@{ id = 'rule.a'; category = 'browser'; title = 'Rule A' }
        $hashPath = 'h-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        $t1 = Get-TestTrace -RuleId 'rule.a' -Path $hashPath -SizeBytes 100
        $t2 = Get-TestTrace -RuleId 'rule.a' -Path $hashPath -SizeBytes 100

        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z') -CatalogRules @($rule) -Traces @($t1) -Redacted $true
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z') -CatalogRules @($rule) -Traces @($t2) -Redacted $true

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data.summary.stillThere | Should -Be 1
        $data.redacted | Should -BeTrue
    }

    It 'renders ASCII markdown containing all sections' {
        $rule = [pscustomobject]@{ id = 'rule.a'; category = 'browser'; title = 'Rule A' }
        $t1 = Get-TestTrace -RuleId 'rule.a' -Path 'C:\data\a.txt' -SizeBytes 200
        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z') -CatalogRules @($rule) -Traces @($t1)
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z') -CatalogRules @($rule) -Traces @()

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }

        $md = InModuleScope Vacate -Parameters @{ D = $data } { param($D) ConvertTo-VacateCompareMarkdown -Compare $D }
        $md | Should -Match '^# Scan comparison'
        $md | Should -Match '## Summary'
        $md | Should -Match '## Gone \(1\)'
        $md | Should -Match '## Still there \(0\)'
        $md | Should -Match '## New \(0\)'
        $md | Should -Match '## Not comparable \(0\)'

        # Check pure ASCII
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($md)
        $reconstructed = [System.Text.Encoding]::ASCII.GetString($bytes)
        $reconstructed | Should -Be $md
    }
}

Describe 'compare.schema.json validation' {
    It 'validates a full comparison object' {
        if ($PSVersionTable.PSEdition -ne 'Core') { return }
        if (-not (Get-Command 'Test-Json' -ErrorAction SilentlyContinue)) { return }

        $rule = [pscustomobject]@{ id = 'rule.a'; category = 'browser'; title = 'Rule A' }
        $t1 = Get-TestTrace -RuleId 'rule.a' -Path 'C:\data\a.txt' -SizeBytes 200
        $t2 = Get-TestTrace -RuleId 'rule.a' -Path 'C:\data\b.txt' -SizeBytes 300
        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z') -CatalogRules @($rule) -Traces @($t1)
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z') -CatalogRules @($rule) -Traces @($t2)

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }

        $json = InModuleScope Vacate -Parameters @{ D = $data } { param($D) ConvertTo-VacateCompareJson -Compare $D }
        Test-Json -Json $json -SchemaFile $script:CompareSchemaPath | Should -BeTrue
    }

    It 'rejects unknown properties' {
        if ($PSVersionTable.PSEdition -ne 'Core') { return }
        if (-not (Get-Command 'Test-Json' -ErrorAction SilentlyContinue)) { return }

        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z')
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z')

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data | Add-Member -NotePropertyName 'invalidProperty' -NotePropertyValue 'bad'
        $json = InModuleScope Vacate -Parameters @{ D = $data } { param($D) ConvertTo-VacateCompareJson -Compare $D }
        $threw = $false
        try { $null = Test-Json -Json $json -SchemaFile $script:CompareSchemaPath -ErrorAction Stop } catch { $threw = $true }
        $threw | Should -BeTrue
    }

    It 'rejects bad schemaVersion' {
        if ($PSVersionTable.PSEdition -ne 'Core') { return }
        if (-not (Get-Command 'Test-Json' -ErrorAction SilentlyContinue)) { return }

        $older = Get-TestReport -FinishedAt ([datetime]'2026-11-20T10:00:00Z')
        $newer = Get-TestReport -FinishedAt ([datetime]'2026-11-20T12:00:00Z')

        $data = InModuleScope Vacate -Parameters @{ N = $newer; O = $older } {
            param($N, $O) Get-VacateComparisonData -NewerReport $N -OlderReport $O -NewerRunPath 'runs/new' -OlderRunPath 'runs/old' -Now ([datetime]'2026-11-20T13:00:00Z')
        }
        $data.schemaVersion = '2.0'
        $json = InModuleScope Vacate -Parameters @{ D = $data } { param($D) ConvertTo-VacateCompareJson -Compare $D }
        $threw = $false
        try { $null = Test-Json -Json $json -SchemaFile $script:CompareSchemaPath -ErrorAction Stop } catch { $threw = $true }
        $threw | Should -BeTrue
    }
}
