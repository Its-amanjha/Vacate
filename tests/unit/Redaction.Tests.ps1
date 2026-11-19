BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestReport {
        $json = @{
            schemaVersion = 1; tool = @{ name = 'vacate'; version = '0.1.0' }
            scan = [ordered]@{ startedAt = '2026-11-19T10:00:00Z'; finishedAt = '2026-11-19T10:00:05Z'; durationMs = 5000; platform = 'windows'; elevated = $false; budgetSeconds = 120; ruleTimeoutSeconds = 10; complete = $true; redacted = $false
                host = [ordered]@{ name = 'ALICE-LAPTOP'; os = 'Windows 11'; version = '10.0'; architecture = 'X64'; user = 'alice'; volumes = @([ordered]@{ name = 'C:'; fileSystem = 'NTFS'; sizeBytes = 100; freeBytes = 40 }) } }
            catalog = [ordered]@{ version = '0.1.0'; rulesLoaded = 2; unverified = @(); invalidFiles = 0; rules = @() }
            summary = [ordered]@{ byCategory = @([ordered]@{ category = 'personal-files'; traces = 2; sizeBytes = 300; highestSensitivity = 'medium' }); totalRules = 2; rulesRun = 2; rulesSkipped = 1; rulesFailed = 1; rulesNotApplicable = 0; tracesFound = 2; totalBytes = 300 }
            traces = @(
                [ordered]@{ ruleId = 'files.desktop'; platform = 'windows'; category = 'personal-files'; title = 'Desktop'; sensitivity = 'medium'; locator = @{ kind = 'path'; resolved = 'C:\Users\alice\Desktop' }; exists = $true; sizeBytes = 100; itemCount = 3; lastWriteTime = '2026-11-01T12:00:00Z'; samples = @('tax-return-2025.pdf', 'divorce-letter.docx'); truncated = $false; confidence = 'verified'; requiresElevation = $false; error = $null }
                [ordered]@{ ruleId = 'network.rdp.mru'; platform = 'windows'; category = 'personal-files'; title = 'RDP'; sensitivity = 'medium'; locator = @{ kind = 'registry'; resolved = 'HKCU\Software\Microsoft\Terminal Server Client\Default' }; exists = $true; sizeBytes = 200; itemCount = 2; lastWriteTime = $null; samples = @(); truncated = $false; confidence = 'verified'; requiresElevation = $false; error = 'could not read C:\Users\alice\secret'; properties = @{ valueCount = 2; subkeyCount = 0 } })
            installedPrograms = @()
            skipped = @([ordered]@{ ruleId = 'x.y'; reason = 'permission'; detail = 'denied: C:\Users\alice\AppData\Local\Private Thing' })
            errors = @([ordered]@{ ruleId = 'a.b'; message = 'failed on /home/alice/.ssh for alice'; type = 'IOException' })
            limitations = @([ordered]@{ scope = 'all'; text = 'SSD spare area is not visible.' })
        } | ConvertTo-Json -Depth 10
        return ($json | ConvertFrom-Json)
    }
}

Describe 'Redaction' {
    BeforeAll {
        $script:orig = Get-TestReport
        $script:red = InModuleScope Vacate -Parameters @{ R = $script:orig } { param($R) Protect-VacateReport -Report $R }
        $script:text = $script:red | ConvertTo-Json -Depth 20
    }

    It 'leaves no raw user, machine, volume or file names anywhere' {
        foreach ($raw in @('alice', 'ALICE-LAPTOP', 'tax-return-2025', 'divorce-letter', 'Desktop\\', 'Private Thing', 'secret', '.ssh')) {
            $text.Contains($raw) | Should -BeFalse -Because "'$raw' must be redacted"
        }
        $red.scan.host.volumes[0].name | Should -Match '^h-[0-9a-f]{10}$'
    }

    It 'keeps counts, sizes, times and rule ids' {
        $red.summary.tracesFound | Should -Be $orig.summary.tracesFound
        $red.summary.totalBytes | Should -Be $orig.summary.totalBytes
        $red.traces[0].sizeBytes | Should -Be 100
        $red.traces[0].itemCount | Should -Be 3
        $red.traces[0].lastWriteTime | Should -Be '2026-11-01T12:00:00Z'
        $red.traces[0].ruleId | Should -Be 'files.desktop'
        @($red.traces[0].samples).Count | Should -Be 2
        $red.traces[1].properties.valueCount | Should -Be 2
    }

    It 'keeps structure: drive letter, hive and segment count' {
        $red.traces[0].locator.resolved | Should -Match '^C:\\h-[0-9a-f]{10}\\h-[0-9a-f]{10}\\h-[0-9a-f]{10}$'
        $red.traces[1].locator.resolved | Should -Match '^HKCU\\h-'
    }

    It 'hashes the same name the same way within one report' {
        $userInPath = ($red.traces[0].locator.resolved -split '\\')[2]
        $red.scan.host.user | Should -Be $userInPath
    }

    It 'uses a fresh key each time so reports cannot be cross-matched' {
        $red2 = InModuleScope Vacate -Parameters @{ R = $orig } { param($R) Protect-VacateReport -Report $R }
        $red2.scan.host.user | Should -Not -Be $red.scan.host.user
    }

    It 'is deterministic for a fixed key' {
        $k = [byte[]](1..32)
        $a = InModuleScope Vacate -Parameters @{ R = $orig; K = $k } { param($R, $K) Protect-VacateReport -Report $R -Key $K }
        $b = InModuleScope Vacate -Parameters @{ R = $orig; K = $k } { param($R, $K) Protect-VacateReport -Report $R -Key $K }
        ($a | ConvertTo-Json -Depth 20) | Should -Be ($b | ConvertTo-Json -Depth 20)
    }

    It 'marks the report redacted and leaves the input untouched' {
        $red.scan.redacted | Should -BeTrue
        $orig.scan.redacted | Should -BeFalse
        $orig.scan.host.user | Should -Be 'alice'
    }

    It 'produces HTML and Markdown with no raw names' {
        $html = InModuleScope Vacate -Parameters @{ R = $red } { param($R) ConvertTo-VacateReportHtml -Report $R -Checklist @(Get-VacateChecklist -Report $R) }
        $md = InModuleScope Vacate -Parameters @{ R = $red } { param($R) ConvertTo-VacateSummaryMarkdown -Report $R }
        foreach ($raw in @('alice', 'ALICE-LAPTOP', 'tax-return', 'divorce')) {
            $html.Contains($raw) | Should -BeFalse -Because "HTML leaked '$raw'"
            $md.Contains($raw) | Should -BeFalse -Because "Markdown leaked '$raw'"
        }
    }
}
