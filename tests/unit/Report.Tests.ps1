BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestReport {
        param([string]$Platform = 'windows', [bool]$Redacted = $false, [bool]$Complete = $true)
        $evil = '<script>alert(1)</script>.txt'
        $json = @{
            schemaVersion = 1
            tool = @{ name = 'vacate'; version = '0.1.0' }
            scan = [ordered]@{ startedAt = '2026-11-19T10:00:00Z'; finishedAt = '2026-11-19T10:00:05Z'; durationMs = 5000; platform = $Platform; elevated = $false; budgetSeconds = 120; ruleTimeoutSeconds = 10; complete = $Complete; redacted = $Redacted
                host = [ordered]@{ name = 'TEST-PC'; os = 'Test OS'; version = '1.0'; architecture = 'X64'; user = 'tester'; volumes = @() } }
            catalog = [ordered]@{ version = '0.1.0'; rulesLoaded = 3; unverified = @('msg.signal'); invalidFiles = 0
                rules = @(
                    [ordered]@{ id = 'browser.chrome.history'; category = 'browsers'; title = 'Chrome history'; whyItMatters = 'Lists every site visited.'; sensitivity = 'high'; source = 'Chromium docs'; verified = $true }
                    [ordered]@{ id = 'msg.signal'; category = 'messaging'; title = 'Signal data'; whyItMatters = 'Holds a live chat session.'; sensitivity = 'critical'; source = 'Signal support'; verified = $false }
                    [ordered]@{ id = 'files.desktop'; category = 'personal-files'; title = 'Desktop'; whyItMatters = 'Your files.'; sensitivity = 'medium'; source = 'Known folders'; verified = $true }
                ) }
            summary = [ordered]@{ byCategory = @(
                    [ordered]@{ category = 'browsers'; traces = 1; sizeBytes = 2048; highestSensitivity = 'high' }
                    [ordered]@{ category = 'messaging'; traces = 1; sizeBytes = 1048576; highestSensitivity = 'critical' }
                    [ordered]@{ category = 'personal-files'; traces = 1; sizeBytes = 10; highestSensitivity = 'medium' })
                totalRules = 3; rulesRun = 3; rulesSkipped = 1; rulesFailed = 0; rulesNotApplicable = 5; tracesFound = 3; totalBytes = 1050634 }
            traces = @(
                [ordered]@{ ruleId = 'browser.chrome.history'; platform = $Platform; category = 'browsers'; title = 'Chrome history'; sensitivity = 'high'; locator = @{ kind = 'path'; resolved = 'C:\Users\tester\AppData\Local\Google\Chrome\User Data\Default\History' }; exists = $true; sizeBytes = 2048; itemCount = 1; lastWriteTime = '2026-11-01T12:00:00Z'; samples = @('History'); truncated = $false; confidence = 'verified'; requiresElevation = $false; error = $null }
                [ordered]@{ ruleId = 'msg.signal'; platform = $Platform; category = 'messaging'; title = 'Signal data'; sensitivity = 'critical'; locator = @{ kind = 'path'; resolved = 'C:\Users\tester\AppData\Roaming\Signal' }; exists = $true; sizeBytes = 1048576; itemCount = 40; lastWriteTime = $null; samples = @($evil, 'b', 'c'); truncated = $true; confidence = 'unverified'; requiresElevation = $false; error = $null }
                [ordered]@{ ruleId = 'files.desktop'; platform = $Platform; category = 'personal-files'; title = 'Desktop'; sensitivity = 'medium'; locator = @{ kind = 'path'; resolved = ('C:\Users\tester\Desktop\' + $evil) }; exists = $true; sizeBytes = 10; itemCount = 1; lastWriteTime = $null; samples = @(); truncated = $false; confidence = 'verified'; requiresElevation = $false; error = $null })
            installedPrograms = @([ordered]@{ name = 'Tool <b>bold</b>'; publisher = 'ACME & Co'; version = '1.0'; installDate = '2026-01-01'; scope = 'machine' })
            skipped = @([ordered]@{ ruleId = 'network.wifi.profiles'; reason = 'requires-elevation'; detail = 'Needs administrator rights.' })
            errors = @()
            limitations = @(InModuleScope Vacate -Parameters @{ P = $Platform } { param($P) Get-VacateLimitation -Platform $P })
        } | ConvertTo-Json -Depth 10
        return ($json | ConvertFrom-Json)
    }
}

Describe 'Limitations and text helpers' {
    It 'returns shared limits plus only the platform own limits' {
        InModuleScope Vacate {
            foreach ($p in 'windows', 'macos', 'linux') {
                $l = @(Get-VacateLimitation -Platform $p)
                @($l | Where-Object { $_.scope -eq 'all' }).Count | Should -BeGreaterThan 5
                @($l | Where-Object { $_.scope -eq $p }).Count | Should -BeGreaterThan 2
                @($l | Where-Object { $_.scope -ne 'all' -and $_.scope -ne $p }).Count | Should -Be 0
            }
            { Get-VacateLimitation -Platform 'amiga' } | Should -Throw
        }
    }

    It 'has a meaning for every category' {
        InModuleScope Vacate {
            foreach ($c in $script:VacateCategories) { (Get-VacateCategoryMeaning $c).Length | Should -BeGreaterThan 10 -Because $c }
        }
    }

    It 'formats byte sizes with invariant culture' {
        InModuleScope Vacate {
            Format-VacateByteSize 0 | Should -Be '0 B'
            Format-VacateByteSize 1536 | Should -Be '1.5 KB'
            Format-VacateByteSize 1048576 | Should -Be '1.0 MB'
            Format-VacateByteSize $null | Should -Be '-'
        }
    }

    It 'wraps text at the width and hard-splits long words' {
        InModuleScope Vacate {
            $lines = @(Format-VacateWrappedText -Text (('word ' * 60) + ('x' * 250)) -Width 100 -Indent '   ')
            foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 100 }
            ($lines -join '').Replace(' ', '').Length | Should -Be (240 + 250)
        }
    }
}

Describe 'Checklist' {
    It 'covers every category on every platform' {
        InModuleScope Vacate {
            foreach ($p in 'windows', 'macos', 'linux') {
                $covered = @(Get-VacateChecklistTemplate -Platform $p | ForEach-Object { $_.Categories }) | Select-Object -Unique
                foreach ($c in $script:VacateCategories) { $covered | Should -Contain $c -Because "$p must place '$c' traces in some step" }
            }
        }
    }

    It 'puts backup first, erase last, and sign-out before uninstall' {
        InModuleScope Vacate {
            foreach ($p in 'windows', 'macos', 'linux') {
                $ids = @(Get-VacateChecklistTemplate -Platform $p | ForEach-Object { $_.Id })
                $ids[0] | Should -Be 'backup'
                $ids[-1] | Should -Be 'erase'
                [array]::IndexOf($ids, 'browsers') | Should -BeLessThan ([array]::IndexOf($ids, 'uninstall'))
                [array]::IndexOf($ids, 'cloud') | Should -BeLessThan ([array]::IndexOf($ids, 'uninstall'))
            }
            $mac = @(Get-VacateChecklistTemplate -Platform 'macos' | ForEach-Object { $_.Id })
            [array]::IndexOf($mac, 'find-my') | Should -BeLessThan ([array]::IndexOf($mac, 'apple-id'))
            [array]::IndexOf($mac, 'filevault') | Should -BeLessThan ([array]::IndexOf($mac, 'apple-id'))
            $win = @(Get-VacateChecklistTemplate -Platform 'windows' | ForEach-Object { $_.Id })
            [array]::IndexOf($win, 'bitlocker') | Should -BeLessThan ([array]::IndexOf($win, 'erase'))
        }
    }

    It 'includes a step only when it has traces or is always shown, and names the traces' {
        $r = Get-TestReport
        $steps = @(InModuleScope Vacate -Parameters @{ R = $r } { param($R) Get-VacateChecklist -Report $R })
        $ids = @($steps | ForEach-Object { $_.id })
        $ids | Should -Contain 'backup'
        $ids | Should -Contain 'erase'
        $ids | Should -Contain 'uninstall'
        $ids | Should -Not -Contain 'network'
        @($steps | ForEach-Object { $_.step }) | Should -Be (1..$steps.Count)
        $named = @($steps | ForEach-Object { $_.traces } | ForEach-Object { $_.ruleId }) | Select-Object -Unique
        foreach ($t in $r.traces) { $named | Should -Contain $t.ruleId }
        ($steps | Where-Object { $_.id -eq 'erase' }).outOfScope | Should -BeTrue
    }

    It 'renders Markdown with no line over 100 characters' {
        $r = Get-TestReport
        $md = InModuleScope Vacate -Parameters @{ R = $r } { param($R) ConvertTo-VacateChecklistMarkdown -Report $R -Checklist @(Get-VacateChecklist -Report $R) }
        foreach ($l in ($md -split "`n")) { $l.Length | Should -BeLessOrEqual 100 }
        $md | Should -Match 'msg\.signal'
    }
}

Describe 'HTML report' {
    BeforeAll {
        $script:r = Get-TestReport
        $script:html = InModuleScope Vacate -Parameters @{ R = $script:r } { param($R) ConvertTo-VacateReportHtml -Report $R -Checklist @(Get-VacateChecklist -Report $R) }
    }

    It 'has the nine sections in the required order' {
        $order = @('<h1>Handover report', '<h2>Summary', '<h2>By category', '<h2>Details', '<h2>De-link checklist', '<h2>Installed programs', '<h2>Skipped and failed', '<h2>What this does not see', '<h2>Methodology')
        $last = -1
        foreach ($m in $order) {
            $i = $html.IndexOf($m)
            $i | Should -BeGreaterThan $last -Because "$m must come after the previous section"
            $last = $i
        }
    }

    It 'escapes every user-controlled string' {
        $html | Should -Not -Match '<script'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Not -Match '<b>bold</b>'
        $html | Should -Match 'ACME &amp; Co'
    }

    It 'is self-contained and needs no JavaScript' {
        foreach ($bad in @('<script', '<link', ' src=', '@import', 'url(', 'http://', 'https://', '<iframe', 'onload=', 'onerror=')) {
            $html.Contains($bad) | Should -BeFalse -Because "found '$bad'"
        }
        $html | Should -Match '@media print'
    }

    It 'shows the sensitivity warning only when not redacted' {
        $html | Should -Match 'Treat it like a password'
        $red = Get-TestReport -Redacted $true
        $h2 = InModuleScope Vacate -Parameters @{ R = $red } { param($R) ConvertTo-VacateReportHtml -Report $R -Checklist @() }
        $h2 | Should -Not -Match 'Treat it like a password'
        $h2 | Should -Match 'redacted'
    }

    It 'flags truncation, unverified rules and incomplete scans' {
        $html | Should -Match 'stopped at the limit'
        $html | Should -Match 'not yet verified'
        $inc = Get-TestReport -Complete $false
        $h3 = InModuleScope Vacate -Parameters @{ R = $inc } { param($R) ConvertTo-VacateReportHtml -Report $R -Checklist @() }
        $h3 | Should -Match 'did NOT finish'
    }

    It 'lists every limitation and the legal footer' {
        foreach ($l in $r.limitations) { $html | Should -Match ([regex]::Escape([System.Net.WebUtility]::HtmlEncode($l.text))) }
        $html | Should -Match 'legal hold'
    }
}

Describe 'Markdown summary' {
    It 'agrees with the JSON counts and keeps lines within 100 characters' {
        $r = Get-TestReport
        $md = InModuleScope Vacate -Parameters @{ R = $r } { param($R) ConvertTo-VacateSummaryMarkdown -Report $R }
        foreach ($l in ($md -split "`n")) { $l.Length | Should -BeLessOrEqual 100 }
        $md | Should -Match ('Traces found: {0}\b' -f $r.summary.tracesFound)
        $md | Should -Match ('\({0} bytes\)' -f $r.summary.totalBytes)
        $md | Should -Match ('{0} total, {1} ran, {2} skipped, {3} failed, {4} not applicable' -f $r.summary.totalRules, $r.summary.rulesRun, $r.summary.rulesSkipped, $r.summary.rulesFailed, $r.summary.rulesNotApplicable)
        $md | Should -Match 'requires-elevation: 1'
    }

    It 'contains no file paths' {
        $r = Get-TestReport
        $md = InModuleScope Vacate -Parameters @{ R = $r } { param($R) ConvertTo-VacateSummaryMarkdown -Report $R }
        $md | Should -Not -Match 'AppData'
        $md | Should -Not -Match '<script'
    }
}
