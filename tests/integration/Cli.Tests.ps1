BeforeAll {
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:cli = Join-Path $script:repo 'vacate.ps1'
    $script:exe = (Get-Process -Id $PID).Path
    Import-Module (Join-Path $script:repo 'src/Vacate/Vacate.psm1') -Force
    $script:m = Get-Module Vacate

    function Invoke-TestCli {
        param(
            [string[]]$CliArgs,
            [string]$Engine = $script:exe
        )
        $out = & $Engine -NoProfile -ExecutionPolicy Bypass -File $script:cli @CliArgs 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
    }

    $script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('vacate-cli-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:tempRoot)

    $script:missingRunDir = Join-Path $script:tempRoot 'does-not-exist'

    $script:emptyRunDir = Join-Path $script:tempRoot 'empty-folder'
    [void][IO.Directory]::CreateDirectory($script:emptyRunDir)

    $curPlat = & $script:m { Get-VacatePlatform }
    $otherPlat = if ($curPlat -eq 'windows') { 'linux' } else { 'windows' }

    function Get-TestReportJson {
        param([string]$Platform, [string]$Machine = [Environment]::MachineName, [bool]$Redacted = $false)
        $rep = [ordered]@{
            schemaVersion = 1
            tool = @{ name = 'vacate'; version = '0.1.0' }
            scan = [ordered]@{
                startedAt = '2026-11-19T10:00:00Z'
                finishedAt = '2026-11-19T10:00:01Z'
                durationMs = 1000
                platform = $Platform
                elevated = $false
                budgetSeconds = 120
                ruleTimeoutSeconds = 10
                complete = $true
                redacted = $Redacted
                host = [ordered]@{
                    name = $Machine
                    os = 'TestOS'
                    version = '1.0'
                    architecture = 'X64'
                    user = 'testuser'
                    volumes = @()
                }
            }
            catalog = [ordered]@{ version = '0.1.0'; rulesLoaded = 0; unverified = @(); invalidFiles = 0; rules = @() }
            summary = [ordered]@{ byCategory = @(); totalRules = 0; rulesRun = 0; rulesSkipped = 0; rulesFailed = 0; rulesNotApplicable = 0; tracesFound = 0; totalBytes = 0 }
            traces = @(); installedPrograms = @(); skipped = @(); errors = @()
            limitations = @([ordered]@{ scope = 'all'; text = 'SSD spare area is not visible.' })
        }
        return ($rep | ConvertTo-Json -Depth 10)
    }

    function Get-TestPlanJson {
        param([string]$Platform)
        $pj = [ordered]@{
            schemaVersion = 1
            tool = @{ name = 'vacate'; version = '0.1.0' }
            plan = [ordered]@{
                generatedAt = '2026-11-19T10:05:00Z'
                reportFinishedAt = '2026-11-19T10:00:01Z'
                platform = $Platform
            }
            summary = [ordered]@{
                steps = 0
                tracesCovered = 0
                tracesNotCovered = 0
                withGuidance = 0
                noGuidance = 0
                ruleMissing = 0
            }
            steps = @()
        }
        return ($pj | ConvertTo-Json -Depth 10)
    }

    $script:otherPlatRunDir = Join-Path $script:tempRoot 'other-platform'
    [void][IO.Directory]::CreateDirectory($script:otherPlatRunDir)
    [IO.File]::WriteAllText((Join-Path $script:otherPlatRunDir 'report.json'), (Get-TestReportJson -Platform $otherPlat), (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $script:otherPlatRunDir 'plan.json'), (Get-TestPlanJson -Platform $otherPlat), (New-Object Text.UTF8Encoding $false))

    $script:redactedRunDir = Join-Path $script:tempRoot 'redacted-run'
    [void][IO.Directory]::CreateDirectory($script:redactedRunDir)
    [IO.File]::WriteAllText((Join-Path $script:redactedRunDir 'report.json'), (Get-TestReportJson -Platform $curPlat -Redacted $true), (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $script:redactedRunDir 'plan.json'), (Get-TestPlanJson -Platform $curPlat), (New-Object Text.UTF8Encoding $false))

    $script:noUndoRunDir = Join-Path $script:tempRoot 'no-undo-run'
    [void][IO.Directory]::CreateDirectory($script:noUndoRunDir)
    [IO.File]::WriteAllText((Join-Path $script:noUndoRunDir 'report.json'), (Get-TestReportJson -Platform $curPlat), (New-Object Text.UTF8Encoding $false))
}

AfterAll {
    if ($script:tempRoot -and [IO.Directory]::Exists($script:tempRoot)) {
        [IO.Directory]::Delete($script:tempRoot, $true)
    }
}

Describe 'vacate.ps1 CLI' {
    It 'prints the version' {
        $r = Invoke-TestCli @('version')
        $r.Code | Should -Be 0
        $r.Text | Should -Match '^vacate \d+\.\d+\.\d+'
    }

    It 'validates the shipped catalog' {
        $r = Invoke-TestCli @('rules', 'validate')
        $r.Code | Should -Be 0
        $r.Text | Should -Match '0 invalid'
    }

    It 'shows a rule and fails cleanly for an unknown id' {
        (Invoke-TestCli @('rules', 'show', 'browser.chrome.history')).Text | Should -Match '"id":\s+"browser.chrome.history"'
        $bad = Invoke-TestCli @('rules', 'show', 'no.such.rule')
        $bad.Code | Should -Be 1
        $bad.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'returns usage with exit 2 for an unknown command' {
        $r = Invoke-TestCli @('explode')
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'Usage:'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 're-renders HTML, summary and checklist from a saved report.json' {
        $runs = Join-Path ([IO.Path]::GetTempPath()) ('vacate-cli-' + [guid]::NewGuid().ToString('N'))
        $run = Join-Path $runs '20261119-100000'
        [void][IO.Directory]::CreateDirectory($run)
        try {
            $rep = [ordered]@{
                schemaVersion = 1; tool = @{ name = 'vacate'; version = '0.1.0' }
                scan = [ordered]@{ startedAt = '2026-11-19T10:00:00Z'; finishedAt = '2026-11-19T10:00:01Z'; durationMs = 1000; platform = 'linux'; elevated = $false; budgetSeconds = 120; ruleTimeoutSeconds = 10; complete = $true; redacted = $false; host = [ordered]@{ name = 'box'; os = 'Ubuntu'; version = '24.04'; architecture = 'X64'; user = 'u'; volumes = @() } }
                catalog = [ordered]@{ version = '0.1.0'; rulesLoaded = 0; unverified = @(); invalidFiles = 0; rules = @() }
                summary = [ordered]@{ byCategory = @(); totalRules = 0; rulesRun = 0; rulesSkipped = 0; rulesFailed = 0; rulesNotApplicable = 0; tracesFound = 0; totalBytes = 0 }
                traces = @(); installedPrograms = @(); skipped = @(); errors = @()
                limitations = @([ordered]@{ scope = 'all'; text = 'SSD spare area is not visible.' })
            }
            [IO.File]::WriteAllText((Join-Path $run 'report.json'), ($rep | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
            $r = Invoke-TestCli @('report', '-Run', $run)
            $r.Code | Should -Be 0
            [IO.File]::Exists((Join-Path $run 'report.html')) | Should -BeTrue
            [IO.File]::Exists((Join-Path $run 'summary.md')) | Should -BeTrue
            (Invoke-TestCli @('checklist', '-Run', $run)).Code | Should -Be 0
            [IO.File]::ReadAllText((Join-Path $run 'checklist.md')) | Should -Match 'Handover checklist'
            $missing = Invoke-TestCli @('report', '-Run', (Join-Path $runs 'nothing-here'))
            $missing.Code | Should -Be 1
            $missing.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
        }
        finally { [IO.Directory]::Delete($runs, $true) }
    }

    It 'help command lists every command that exists' {
        $r = Invoke-TestCli @('help')
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Usage:'
        foreach ($cmd in @('scan', 'rules', 'report', 'checklist', 'plan', 'clean', 'undo', 'erase', 'version', 'help')) {
            $r.Text | Should -Match ("\bvacate\.ps1\s+{0}\b" -f $cmd)
        }
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'bare invocation without arguments prints help and exits 0' {
        $r = Invoke-TestCli @()
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'Usage:'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'returns usage with exit 2 and no stack trace for an unknown rules subcommand' {
        $r = Invoke-TestCli @('rules', 'invalid')
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'Usage:'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'returns usage with exit 2 and no stack trace for bare rules command' {
        $r = Invoke-TestCli @('rules')
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'Usage:'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'rules show without an id fails with exit 2 naming what is needed' {
        $r = Invoke-TestCli @('rules', 'show')
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'rules show needs a rule id\.'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'rules list prints all rules with exit 0' {
        $r = Invoke-TestCli @('rules', 'list')
        $r.Code | Should -Be 0
        $r.Text | Should -Match '\d+ rules'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'scan -Elevated in a non-elevated session exits 1 with action message' {
        $curPlat = & $script:m { Get-VacatePlatform }
        $elevated = & $script:m { param($p) Test-VacateElevated -Platform $p } $curPlat
        if (-not $elevated) {
            $r = Invoke-TestCli @('scan', '-Elevated')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'start an elevated shell first'
            $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
        }
    }

    It '<Cmd> fails with exit 2 naming what to do when -Run is omitted' -ForEach @(
        @{ Cmd = 'report' },
        @{ Cmd = 'checklist' },
        @{ Cmd = 'plan' },
        @{ Cmd = 'clean' },
        @{ Cmd = 'undo' },
        @{ Cmd = 'erase' }
    ) {
        $r = Invoke-TestCli @($Cmd)
        $r.Code | Should -Be 2
        $r.Text | Should -Match ("{0} needs -Run <dir>\." -f $Cmd)
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It '<Cmd> fails with exit 1 when -Run points to a missing folder' -ForEach @(
        @{ Cmd = 'report' },
        @{ Cmd = 'checklist' },
        @{ Cmd = 'plan' },
        @{ Cmd = 'clean' },
        @{ Cmd = 'undo' },
        @{ Cmd = 'erase' }
    ) {
        $r = Invoke-TestCli @($Cmd, '-Run', $script:missingRunDir)
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'No report\.json'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It '<Cmd> fails with exit 1 when -Run points to a folder that is not a vacate run' -ForEach @(
        @{ Cmd = 'report' },
        @{ Cmd = 'checklist' },
        @{ Cmd = 'plan' },
        @{ Cmd = 'clean' },
        @{ Cmd = 'undo' },
        @{ Cmd = 'erase' }
    ) {
        $r = Invoke-TestCli @($Cmd, '-Run', $script:emptyRunDir)
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'No report\.json'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    Context 'runs from another platform' {
        It 'clean refuses a run from another platform' {
            $r = Invoke-TestCli @('clean', '-Run', $script:otherPlatRunDir)
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'Clean only runs on the machine it scanned'
            $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
        }

        It 'undo refuses a run from another platform' {
            $r = Invoke-TestCli @('undo', '-Run', $script:otherPlatRunDir)
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'Clean only runs on the machine it scanned'
            $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
        }

        It 'erase reports NOT READY for a run from another platform in dry-run' {
            $r = Invoke-TestCli @('erase', '-Run', $script:otherPlatRunDir)
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'Erase readiness: NOT READY'
            $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
        }

        It 'erase -Execute exits 1 when not ready due to another platform' {
            $r = Invoke-TestCli @('erase', '-Run', $script:otherPlatRunDir, '-Execute')
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'Not ready to erase\. See erase-readiness\.md'
            $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
        }
    }

    It 'clean refuses a redacted run with exit 1 naming the fix' {
        $r = Invoke-TestCli @('clean', '-Run', $script:redactedRunDir)
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'Scan again without -Redact to clean'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'undo fails with exit 1 when undo.json is missing' {
        $r = Invoke-TestCli @('undo', '-Run', $script:noUndoRunDir)
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'No undo\.json in'
        $r.Text | Should -Not -Match '(At line:|CategoryInfo|FullyQualifiedErrorId|ScriptStackTrace)'
    }

    It 'returns real exit codes from both pwsh and powershell when available' {
        $engines = @($script:exe)
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if ([IO.File]::Exists($winPs)) { $engines += $winPs }
        } else {
            $pwshCmd = Get-Command 'pwsh' -ErrorAction SilentlyContinue
            if ($pwshCmd) { $engines += $pwshCmd.Source }
        }
        foreach ($eng in $engines) {
            $ok = Invoke-TestCli -CliArgs @('version') -Engine $eng
            $ok.Code | Should -Be 0
            $err = Invoke-TestCli -CliArgs @('explode') -Engine $eng
            $err.Code | Should -Be 2
        }
    }
}
