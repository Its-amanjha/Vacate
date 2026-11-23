# HtmlAccessibility.Tests.ps1 - accessibility and offline audit of report.html and plan.html.
# PowerShell 5.1 compatible. ASCII only.
# These pages are read by non-developers, often on a phone, sometimes with a screen reader, and
# they must keep working with no network and with JavaScript off.

Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    $script:evil = '<script>alert("x")</script>'
    $script:evilPath = 'C:\Users\tester\Desktop\' + $script:evil + '.txt'

    function Get-TestA11yRule {
        param([string]$Id, [string]$Category)
        return [pscustomobject][ordered]@{
            id                = $Id
            platforms         = @('windows')
            category          = $Category
            title             = 'Title with ' + $script:evil
            whyItMatters      = 'Because it matters.'
            sensitivity       = 'high'
            locator           = [pscustomobject][ordered]@{ kind = 'path'; root = 'HOME'; path = 'x'; match = 'files'; recurse = $false }
            measure           = @('exists', 'sizeBytes')
            maxEntries        = 10
            requiresElevation = $false
            verifiedOn        = @()
            verified          = $false
            source            = 'Vendor help page: https://example.invalid/help'
            notes             = $null
            cleanup           = [pscustomobject][ordered]@{
                action = 'remove'; exportFirst = $null; signOut = $null
                steps = @('Delete the file with a "quote" and <b>markup</b> by hand.')
                risk = 'Removes the "thing".'; closeApps = @(); resetCovers = $true; reason = $null
                source = 'Vendor help page: https://example.invalid/help'
            }
        }
    }

    function Get-TestA11yTrace {
        param([object]$Rule)
        return [pscustomobject][ordered]@{
            ruleId            = $Rule.id
            platform          = 'windows'
            category          = $Rule.category
            title             = $Rule.title
            sensitivity       = 'high'
            locator           = [pscustomobject][ordered]@{ kind = 'path'; resolved = $script:evilPath }
            exists            = $true
            sizeBytes         = 2048
            itemCount         = 2
            lastWriteTime     = '2026-11-20T10:00:00Z'
            samples           = @($script:evil)
            truncated         = $false
            confidence        = 'unverified'
            requiresElevation = $false
            error             = $null
        }
    }

    $script:rules = @(
        (Get-TestA11yRule -Id 'browser.a.remove' -Category 'browsers')
        (Get-TestA11yRule -Id 'wallet.b.remove' -Category 'wallets')
    )
    $script:traces = @($script:rules | ForEach-Object { Get-TestA11yTrace -Rule $_ })

    $script:report = [pscustomobject][ordered]@{
        schemaVersion     = 1
        tool              = [pscustomobject][ordered]@{ name = 'vacate'; version = '0.1.0' }
        scan              = [pscustomobject][ordered]@{
            startedAt          = '2026-11-20T10:00:00Z'
            finishedAt         = '2026-11-20T10:00:05Z'
            durationMs         = 5000
            platform           = 'windows'
            elevated           = $false
            budgetSeconds      = 120
            ruleTimeoutSeconds = 10
            complete           = $true
            redacted           = $false
            host               = [pscustomobject][ordered]@{ name = 'TEST-PC'; os = 'Test OS'; version = '1.0'; architecture = 'X64'; user = 'tester'; volumes = @() }
        }
        catalog           = [pscustomobject][ordered]@{
            version      = '0.1.0'
            rulesLoaded  = 2
            unverified   = @('wallet.b.remove')
            invalidFiles = 0
            rules        = @($script:rules | ForEach-Object {
                    [pscustomobject][ordered]@{
                        id = $_.id; category = $_.category; title = $_.title; whyItMatters = $_.whyItMatters
                        sensitivity = $_.sensitivity; source = $_.source; verified = $false
                    }
                })
        }
        summary           = [pscustomobject][ordered]@{
            byCategory          = @([pscustomobject][ordered]@{ category = 'browsers'; traces = 1; sizeBytes = 2048; highestSensitivity = 'high' })
            totalRules          = 2
            rulesRun            = 2
            rulesSkipped        = 0
            rulesFailed         = 0
            rulesNotApplicable  = 0
            tracesFound         = 2
            totalBytes          = 4096
        }
        traces            = $script:traces
        installedPrograms = @([pscustomobject][ordered]@{ name = 'Tool <b>bold</b>'; publisher = 'ACME & Co'; version = '1.0'; installDate = '2026-01-01'; scope = 'machine' })
        skipped           = @([pscustomobject][ordered]@{ ruleId = 'network.wifi'; reason = 'requires-elevation'; detail = 'Needs admin: ' + $script:evil })
        errors            = @()
        limitations       = @(InModuleScope Vacate { Get-VacateLimitation -Platform 'windows' })
    }

    $script:htmlReport = InModuleScope Vacate -Parameters @{ R = $script:report } {
        param($R) ConvertTo-VacateReportHtml -Report $R -Checklist @(Get-VacateChecklist -Report $R)
    }
    $script:plan = InModuleScope Vacate -Parameters @{ R = $script:report; Ru = $script:rules } {
        param($R, $Ru) New-VacatePlan -Report $R -Rules $Ru -Now ([datetime]'2026-11-20T12:00:00Z')
    }
    $script:htmlPlan = InModuleScope Vacate -Parameters @{ P = $script:plan } { param($P) ConvertTo-VacatePlanHtml -Plan $P }
    $script:mdSummary = InModuleScope Vacate -Parameters @{ R = $script:report } { param($R) ConvertTo-VacateSummaryMarkdown -Report $R }
    $script:mdPlan = InModuleScope Vacate -Parameters @{ P = $script:plan } { param($P) ConvertTo-VacatePlanMarkdown -Plan $P }

    $script:docs = @(
        [pscustomobject]@{ Name = 'report.html'; Html = $script:htmlReport }
        [pscustomobject]@{ Name = 'plan.html'; Html = $script:htmlPlan }
    )

    function Get-TestHeadingLevel {
        param([string]$Html)
        return @([regex]::Matches($Html, '<h([1-6])[ >]') | ForEach-Object { [int]$_.Groups[1].Value })
    }

    function Get-TestHexLuminance {
        param([string]$Hex)
        $c = $Hex.TrimStart('#')
        $channels = @()
        for ($i = 0; $i -lt 3; $i++) {
            $v = [Convert]::ToInt32($c.Substring($i * 2, 2), 16) / 255.0
            if ($v -le 0.03928) { $v = $v / 12.92 } else { $v = [Math]::Pow(($v + 0.055) / 1.055, 2.4) }
            $channels += $v
        }
        return (0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2])
    }

    function Get-TestContrastRatio {
        param([string]$Foreground, [string]$Background)
        $a = Get-TestHexLuminance -Hex $Foreground
        $b = Get-TestHexLuminance -Hex $Background
        $hi = [Math]::Max($a, $b)
        $lo = [Math]::Min($a, $b)
        return (($hi + 0.05) / ($lo + 0.05))
    }

    function Get-TestCssVariable {
        param([string]$Block)
        $vars = @{}
        foreach ($m in [regex]::Matches($Block, '(--[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})')) { $vars[$m.Groups[1].Value] = $m.Groups[2].Value }
        return $vars
    }

    function Get-TestResourceUrl {
        # Anything the browser would load by itself must never point at a network URL or a file.
        param([string]$Html)
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($Html, '(?i)<(?:link|script|img|iframe|source|embed)\b[^>]*>')) { $bad.Add($m.Value) }
        if ($Html -match '(?i)@import') { $bad.Add('@import') }
        if ($Html -match '(?i)@font-face') { $bad.Add('@font-face') }
        if ($Html -match '(?i)url\s*\(') { $bad.Add('url()') }
        if ($Html -match '(?i)\ssrc\s*=') { $bad.Add('src=') }
        return $bad.ToArray()
    }

    # Parsed last: these lines call the helpers defined above.
    $script:css = [regex]::Match($script:htmlReport, '(?s)<style>(.*?)</style>').Groups[1].Value
    $script:darkCss = [regex]::Match($script:css, '(?s)@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{([^}]*)\}').Groups[1].Value
    $script:lightCss = [regex]::Replace($script:css, '(?s)@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{[^}]*\}\s*\}', '')
    $script:lightVars = Get-TestCssVariable -Block ([regex]::Match($script:lightCss, '(?s):root\s*\{([^}]*)\}').Groups[1].Value)
    $script:darkVars = Get-TestCssVariable -Block $script:darkCss
    $script:contrastPairs = @(
        @{ Fg = '--fg'; Bg = '--bg' }
        @{ Fg = '--fg'; Bg = '--card' }
        @{ Fg = '--muted'; Bg = '--bg' }
        @{ Fg = '--muted'; Bg = '--card' }
        @{ Fg = '--warn-fg'; Bg = '--warn-bg' }
        @{ Fg = '--crit'; Bg = '--bg' }
        @{ Fg = '--crit'; Bg = '--card' }
        @{ Fg = '--high'; Bg = '--bg' }
        @{ Fg = '--high'; Bg = '--card' }
        @{ Fg = '--med'; Bg = '--bg' }
        @{ Fg = '--med'; Bg = '--card' }
        @{ Fg = '--low'; Bg = '--bg' }
        @{ Fg = '--low'; Bg = '--card' }
    )
}

Describe 'HTML pages stay offline' {
    It 'loads no external resource and runs no script (<Name>)' {
        foreach ($d in $script:docs) {
            $bad = @(Get-TestResourceUrl -Html $d.Html)
            $bad.Count | Should -Be 0 -Because ("{0} must not load anything: {1}" -f $d.Name, ($bad -join ', '))
        }
    }

    It 'uses no web font and no URL in CSS' {
        $script:css | Should -Not -Match 'fonts\.(?:googleapis|gstatic)'
        $script:css | Should -Not -Match '@import'
        $script:css | Should -Not -Match 'url\s*\('
    }

    It 'puts href only on a plain anchor, never on a loader' {
        foreach ($d in $script:docs) {
            $rest = [regex]::Replace($d.Html, '(?s)<a\b[^>]*>.*?</a>', '')
            ($rest -match 'href=') | Should -BeFalse -Because $d.Name
        }
    }
}

Describe 'HTML document structure' {
    It 'declares language, encoding, viewport and title (<Name>)' {
        foreach ($d in $script:docs) {
            $d.Html | Should -Match '<html lang="en">'
            $d.Html | Should -Match '(?i)<meta charset="utf-8">'
            $d.Html | Should -Match '(?i)<meta name="viewport" content="width=device-width, initial-scale=1">'
            $d.Html | Should -Match '(?s)<title>[^<]+</title>'
        }
    }

    It 'has one h1 and no heading level jumps (<Name>)' {
        foreach ($d in $script:docs) {
            $levels = @(Get-TestHeadingLevel -Html $d.Html)
            ($levels | Where-Object { $_ -eq 1 }).Count | Should -Be 1 -Because $d.Name
            $levels[0] | Should -Be 1 -Because "$($d.Name) must start with its h1"
            for ($i = 1; $i -lt $levels.Count; $i++) {
                $levels[$i] | Should -BeLessOrEqual ($levels[$i - 1] + 1) -Because ("{0}: h{1} follows h{2}" -f $d.Name, $levels[$i], $levels[$i - 1])
            }
        }
    }

    It 'gives every table header a scope and every table a thead (<Name>)' {
        foreach ($d in $script:docs) {
            $headers = @([regex]::Matches($d.Html, '<th\b[^>]*>'))
            $headers.Count | Should -BeGreaterThan 0 -Because "$($d.Name) has no table"
            foreach ($h in $headers) { $h.Value | Should -Match 'scope="col"' }
            $tables = [regex]::Matches($d.Html, '<table\b[^>]*>').Count
            $theads = [regex]::Matches($d.Html, '<table><thead>').Count
            $theads | Should -Be $tables
        }
    }
}

Describe 'Colour and contrast' {
    It 'keeps text contrast at 4.5:1 or better in light and dark mode' {
        foreach ($mode in @('light', 'dark')) {
            $vars = $script:lightVars
            if ($mode -eq 'dark') { $vars = $script:darkVars }
            foreach ($pair in $script:contrastPairs) {
                $fg = [string]$vars[$pair.Fg]
                $bg = [string]$vars[$pair.Bg]
                $fg | Should -Not -BeNullOrEmpty -Because "$mode needs $($pair.Fg)"
                $bg | Should -Not -BeNullOrEmpty -Because "$mode needs $($pair.Bg)"
                $ratio = Get-TestContrastRatio -Foreground $fg -Background $bg
                [Math]::Round($ratio, 2) | Should -BeGreaterOrEqual 4.5 -Because "$mode text $($pair.Fg) on $($pair.Bg) must stay readable"
            }
        }
    }

    It 'never relies on colour alone for severity or warnings' {
        foreach ($d in $script:docs) {
            $marks = @([regex]::Matches($d.Html, '<(?:td|span) class="sev-([a-z]+)">([^<]*)<'))
            $marks.Count | Should -BeGreaterThan 0 -Because "$($d.Name) shows no sensitivity text"
            foreach ($m in $marks) {
                $m.Groups[2].Value.Trim().ToLowerInvariant() | Should -Be $m.Groups[1].Value -Because 'the level is written out, not only coloured'
            }
        }
        $script:htmlReport | Should -Match '<p class="warn"><strong>Sensitive:</strong>'
        $script:htmlPlan | Should -Match '<p class="warn"><strong>Dry run\.</strong>'
    }

    It 'defines a dark mode for prefers-color-scheme' {
        $script:css | Should -Match '@media\s*\(prefers-color-scheme:\s*dark\)'
        @($script:darkVars.Keys).Count | Should -BeGreaterThan 5
        @($script:lightVars.Keys).Count | Should -Be @($script:darkVars.Keys).Count
    }
}

Describe 'Readable at 360px' {
    It 'has no fixed width wider than 360px' {
        foreach ($m in [regex]::Matches($script:css, '(?<![-\w])width\s*:\s*([0-9]+)px')) {
            [int]$m.Groups[1].Value | Should -BeLessOrEqual 360 -Because "fixed width $($m.Value) would overflow a phone"
        }
        foreach ($d in $script:docs) {
            foreach ($m in [regex]::Matches($d.Html, '(?i)\swidth="([0-9]+)"')) {
                [int]$m.Groups[1].Value | Should -BeLessOrEqual 360 -Because $d.Name
            }
        }
    }

    It 'wraps long paths and ids instead of overflowing' {
        foreach ($d in $script:docs) {
            $d.Html | Should -Match 'overflow-wrap:\s*anywhere'
            $encodedPath = [System.Net.WebUtility]::HtmlEncode($script:evilPath)
            $d.Html.Contains($encodedPath) | Should -BeTrue -Because "$($d.Name) shows the long path"
        }
        $script:css | Should -Match '(?s)code\s*\{[^}]*overflow-wrap:\s*anywhere'
        $script:css | Should -Match '(?s)(?<![-\w])td\b[^{]*\{[^}]*overflow-wrap:\s*anywhere'
    }

    It 'stacks label and value pairs on a narrow screen' {
        $m = [regex]::Match($script:css, '@media\s*\(max-width:\s*([0-9]+)px\)')
        $m.Success | Should -BeTrue -Because 'a narrow-screen media query is needed to stack the grid'
        [int]$m.Groups[1].Value | Should -BeLessOrEqual 480
        $script:css | Should -Match '(?s)@media[^{]*\{.*?grid-template-columns:\s*1fr'
    }
}

Describe 'HTML encoding' {
    It 'encodes every user and rule string, including markup and quotes' {
        foreach ($d in $script:docs) {
            $d.Html | Should -Not -Match '<script'
            $d.Html | Should -Not -Match '<b>'
            $d.Html | Should -Match '&lt;script&gt;alert\(&quot;x&quot;\)&lt;/script&gt;'
            $d.Html | Should -Not -Match '&amp;lt;' -Because 'encoding twice changes what the reader sees'
        }
        $script:htmlReport | Should -Match 'ACME &amp; Co'
        $script:htmlReport | Should -Match 'Tool &lt;b&gt;bold&lt;/b&gt;'
        $script:htmlPlan | Should -Match '&lt;b&gt;markup&lt;/b&gt;'
        $script:htmlReport.Contains($script:evilPath) | Should -BeFalse
        $script:htmlPlan.Contains($script:evilPath) | Should -BeFalse
    }
}

Describe 'Markdown outputs still agree with the HTML' {
    It 'keeps every Markdown line within 100 characters' {
        foreach ($md in @($script:mdSummary, $script:mdPlan)) {
            foreach ($line in ($md -split "`n")) { $line.Length | Should -BeLessOrEqual 100 }
        }
    }

    It 'renders the same summary sentence as the HTML report' {
        $sentence = InModuleScope Vacate -Parameters @{ R = $script:report } { param($R) Get-VacateSummarySentence -Report $R }
        $script:htmlReport.Contains([System.Net.WebUtility]::HtmlEncode($sentence)) | Should -BeTrue
        # Markdown wraps the same sentence at 100 columns, so compare with whitespace collapsed.
        $flatMd = [regex]::Replace($script:mdSummary, '\s+', ' ')
        $flatSentence = [regex]::Replace($sentence, '\s+', ' ')
        $flatMd.Contains($flatSentence) | Should -BeTrue
    }

    It 'keeps the plan structure in Markdown' {
        $script:mdPlan | Should -Match '## Last: Reset this PC'
        $script:mdPlan | Should -Match '## Limits'
        $script:mdPlan | Should -Match 'Before you start'
    }
}
