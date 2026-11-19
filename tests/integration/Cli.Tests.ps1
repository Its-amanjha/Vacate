BeforeAll {
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:cli = Join-Path $script:repo 'vacate.ps1'
    $script:exe = (Get-Process -Id $PID).Path

    function Invoke-TestCli {
        param([string[]]$CliArgs)
        $out = & $script:exe -NoProfile -ExecutionPolicy Bypass -File $script:cli @CliArgs 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
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
    }

    It 'returns usage with exit 2 for an unknown command' {
        $r = Invoke-TestCli @('explode')
        $r.Code | Should -Be 2
        $r.Text | Should -Match 'Usage:'
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
        }
        finally { [IO.Directory]::Delete($runs, $true) }
    }
}
