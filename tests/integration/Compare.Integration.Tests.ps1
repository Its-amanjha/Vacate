# Compare.Integration.Tests.ps1 - integration tests for vacate compare.
# PowerShell 5.1 compatible. ASCII only.

Set-StrictMode -Version Latest

BeforeAll {
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:cli = Join-Path $script:repo 'vacate.ps1'
    $script:exe = (Get-Process -Id $PID).Path
    Import-Module (Join-Path $script:repo 'src/Vacate/Vacate.psm1') -Force

    function Invoke-TestCli {
        param([string[]]$CliArgs)
        $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File $script:cli @CliArgs 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
    }

    $td = if (Test-Path TestDrive:\) { (Get-Item TestDrive:\).FullName } else { Join-Path ([IO.Path]::GetTempPath()) ('vacate-cmp-' + [guid]::NewGuid().ToString('N')) }
    $script:runsDir = Join-Path $td 'runs'
    [void][IO.Directory]::CreateDirectory($script:runsDir)

    function Get-IntegrationReportJson {
        param(
            [string]$Platform = 'windows',
            [string]$Machine = [Environment]::MachineName,
            [string]$FinishedAt = '2026-11-20T10:00:00Z',
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
        $rep = [ordered]@{
            schemaVersion = 1
            tool          = [ordered]@{ name = 'vacate'; version = '0.1.0' }
            scan          = [ordered]@{
                startedAt          = '2026-11-20T09:59:00Z'
                finishedAt         = $FinishedAt
                durationMs         = 60000
                platform           = $Platform
                elevated           = $false
                budgetSeconds      = 120
                ruleTimeoutSeconds = 10
                complete           = $true
                redacted           = $Redacted
                host               = [ordered]@{
                    name         = $Machine
                    os           = 'Windows 11'
                    version      = '10.0'
                    architecture = 'X64'
                    user         = 'tester'
                    volumes      = @()
                }
            }
            catalog       = [ordered]@{
                version      = '0.1.0'
                rulesLoaded  = $rules.Count
                unverified   = @()
                invalidFiles = 0
                rules        = $rules.ToArray()
            }
            summary       = [ordered]@{
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
            limitations   = @([ordered]@{ scope = 'all'; text = 'A limitation note here.' })
        }
        return ($rep | ConvertTo-Json -Depth 10)
    }

    function Get-IntegrationTrace {
        param([string]$RuleId, [string]$Path, [int]$SizeBytes = 100, [string]$LastWrite = '2026-11-20T10:00:00Z')
        return [ordered]@{
            ruleId            = $RuleId
            platform          = 'windows'
            category          = 'browser'
            title             = 'Trace Title'
            sensitivity       = 'medium'
            locator           = [ordered]@{ kind = 'path'; resolved = $Path }
            exists            = $true
            sizeBytes         = $SizeBytes
            itemCount         = 1
            lastWriteTime     = $LastWrite
            samples           = @()
            truncated         = $false
            confidence        = 'verified'
            requiresElevation = $false
            error             = $null
        }
    }
}

AfterAll {
    if ($script:runsDir -and [IO.Directory]::Exists($script:runsDir)) {
        [IO.Directory]::Delete($script:runsDir, $true)
    }
}

Describe 'Vacate Compare Integration Tests' {
    It 'fails with exit 2 when -Run or -Against is omitted' {
        $r1 = Invoke-TestCli @('compare')
        $r1.Code | Should -Be 2
        $r1.Text | Should -Match 'compare needs -Run <newer run> -Against <older run>\.'
        $r1.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'

        $r2 = Invoke-TestCli @('compare', '-Run', 'runs/foo')
        $r2.Code | Should -Be 2
        $r2.Text | Should -Match 'compare needs -Run <newer run> -Against <older run>\.'
    }

    It 'fails with exit 2 when a folder is missing report.json' {
        $runNew = Join-Path $script:runsDir 'missing-new'
        $runOld = Join-Path $script:runsDir 'missing-old'
        [void][IO.Directory]::CreateDirectory($runNew)
        [void][IO.Directory]::CreateDirectory($runOld)

        $r = Invoke-TestCli @('compare', '-Run', $runNew, '-Against', $runOld)
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'No report\.json in'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'fails with exit 2 when scans are from different platforms' {
        $runNew = Join-Path $script:runsDir 'plat-new'
        $runOld = Join-Path $script:runsDir 'plat-old'
        [void][IO.Directory]::CreateDirectory($runNew)
        [void][IO.Directory]::CreateDirectory($runOld)

        [IO.File]::WriteAllText((Join-Path $runNew 'report.json'), (Get-IntegrationReportJson -Platform 'windows' -FinishedAt '2026-11-20T12:00:00Z'))
        [IO.File]::WriteAllText((Join-Path $runOld 'report.json'), (Get-IntegrationReportJson -Platform 'linux' -FinishedAt '2026-11-20T10:00:00Z'))

        $r = Invoke-TestCli @('compare', '-Run', $runNew, '-Against', $runOld)
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'different platforms'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'fails with exit 2 when scans are from different machines' {
        $runNew = Join-Path $script:runsDir 'mach-new'
        $runOld = Join-Path $script:runsDir 'mach-old'
        [void][IO.Directory]::CreateDirectory($runNew)
        [void][IO.Directory]::CreateDirectory($runOld)

        [IO.File]::WriteAllText((Join-Path $runNew 'report.json'), (Get-IntegrationReportJson -Machine 'PC-ALPHA' -FinishedAt '2026-11-20T12:00:00Z'))
        [IO.File]::WriteAllText((Join-Path $runOld 'report.json'), (Get-IntegrationReportJson -Machine 'PC-BETA' -FinishedAt '2026-11-20T10:00:00Z'))

        $r = Invoke-TestCli @('compare', '-Run', $runNew, '-Against', $runOld)
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'different machines'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'fails with exit 2 when -Against is newer than -Run' {
        $runNew = Join-Path $script:runsDir 'time-new'
        $runOld = Join-Path $script:runsDir 'time-old'
        [void][IO.Directory]::CreateDirectory($runNew)
        [void][IO.Directory]::CreateDirectory($runOld)

        [IO.File]::WriteAllText((Join-Path $runNew 'report.json'), (Get-IntegrationReportJson -FinishedAt '2026-11-20T10:00:00Z'))
        [IO.File]::WriteAllText((Join-Path $runOld 'report.json'), (Get-IntegrationReportJson -FinishedAt '2026-11-20T12:00:00Z'))

        $r = Invoke-TestCli @('compare', '-Run', $runNew, '-Against', $runOld)
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'newer than -Run'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'fails with exit 2 when one scan is redacted and the other is not' {
        $runNew = Join-Path $script:runsDir 'redact-new'
        $runOld = Join-Path $script:runsDir 'redact-old'
        [void][IO.Directory]::CreateDirectory($runNew)
        [void][IO.Directory]::CreateDirectory($runOld)

        [IO.File]::WriteAllText((Join-Path $runNew 'report.json'), (Get-IntegrationReportJson -Redacted $true -FinishedAt '2026-11-20T12:00:00Z'))
        [IO.File]::WriteAllText((Join-Path $runOld 'report.json'), (Get-IntegrationReportJson -Redacted $false -FinishedAt '2026-11-20T10:00:00Z'))

        $r = Invoke-TestCli @('compare', '-Run', $runNew, '-Against', $runOld)
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'Cannot compare a redacted scan with an unredacted scan'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'compares two valid scans, writes compare.md and compare.json, and returns exit 0' {
        $runNew = Join-Path $script:runsDir 'valid-new'
        $runOld = Join-Path $script:runsDir 'valid-old'
        [void][IO.Directory]::CreateDirectory($runNew)
        [void][IO.Directory]::CreateDirectory($runOld)

        $rule1 = [ordered]@{ id = 'browser.chrome.history'; category = 'browser'; title = 'Chrome History' }
        $rule2 = [ordered]@{ id = 'dev.git.credentials'; category = 'dev'; title = 'Git Credentials' }
        $rule3 = [ordered]@{ id = 'system.recent'; category = 'system'; title = 'Recent Files' }

        # Trace 1 (rule1): in older and newer (still there)
        $t1Old = Get-IntegrationTrace -RuleId 'browser.chrome.history' -Path 'C:\Chrome\History' -SizeBytes 1000 -LastWrite '2026-11-20T08:00:00Z'
        $t1New = Get-IntegrationTrace -RuleId 'browser.chrome.history' -Path 'C:\Chrome\History' -SizeBytes 1500 -LastWrite '2026-11-20T11:00:00Z'

        # Trace 2 (rule2): in older only (gone)
        $t2Old = Get-IntegrationTrace -RuleId 'dev.git.credentials' -Path 'C:\git\credentials' -SizeBytes 200

        # Trace 3 (rule3): in newer only (new)
        $t3New = Get-IntegrationTrace -RuleId 'system.recent' -Path 'C:\recent\doc.lnk' -SizeBytes 50

        [IO.File]::WriteAllText((Join-Path $runOld 'report.json'), (Get-IntegrationReportJson -FinishedAt '2026-11-20T09:00:00Z' -CatalogRules @($rule1, $rule2, $rule3) -Traces @($t1Old, $t2Old)))
        [IO.File]::WriteAllText((Join-Path $runNew 'report.json'), (Get-IntegrationReportJson -FinishedAt '2026-11-20T12:00:00Z' -CatalogRules @($rule1, $rule2, $rule3) -Traces @($t1New, $t3New)))

        $r = Invoke-TestCli @('compare', '-Run', $runNew, '-Against', $runOld)
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Compare: 1 gone, 1 still there, 1 new, 0 not comparable\.'
        $r.Text | Should -Match 'Wrote .*compare\.md'
        $r.Text | Should -Match 'Wrote .*compare\.json'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'

        [IO.File]::Exists((Join-Path $runNew 'compare.md')) | Should -BeTrue
        [IO.File]::Exists((Join-Path $runNew 'compare.json')) | Should -BeTrue

        $mdContent = [IO.File]::ReadAllText((Join-Path $runNew 'compare.md'))
        $mdContent | Should -Match '## Gone \(1\)'
        $mdContent | Should -Match '## Still there \(1\)'
        $mdContent | Should -Match '## New \(1\)'
        $mdContent | Should -Match '## Not comparable \(0\)'

        $jsonContent = [IO.File]::ReadAllText((Join-Path $runNew 'compare.json'))
        $jsonContent | Should -Match '"schemaVersion":\s*"1\.0"'
    }
}
