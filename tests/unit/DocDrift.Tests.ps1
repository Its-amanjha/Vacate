# DocDrift.Tests.ps1 - catches documentation that drifts from the rule catalog.
# Pure file reads and module calls; no network. Works on Windows PowerShell 5.1, pwsh 7 and WSL.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $script:RepoRoot 'src/Vacate/Vacate.psm1') -Force
    $script:Module = Get-Module Vacate

    # Catalog facts, read once. The generator and the loader live in module scope.
    $ruleSet = & $script:Module { Import-VacateRuleSet -Path $script:VacateRulesRoot }
    $script:Rules = @($ruleSet.Rules)
    $script:PlatformNames = @('windows', 'macos', 'linux')
    $script:TotalRules = $script:Rules.Count
    $script:TotalVerified = @($script:Rules | Where-Object { $_.verified }).Count

    # Rule ids and the set of id prefixes (first dotted segment), for spotting rule references.
    $script:RuleIdSet = @{}
    $script:RulePrefixSet = @{}
    foreach ($r in $script:Rules) {
        $id = [string]$r.id
        $script:RuleIdSet[$id] = $true
        $script:RulePrefixSet[($id -split '\.')[0]] = $true
    }

    $script:ByPlatform = @{}
    foreach ($p in $script:PlatformNames) {
        $rp = @($script:Rules | Where-Object { @($_.platforms) -ccontains $p })
        $script:ByPlatform[$p] = [pscustomobject]@{
            Rules    = $rp.Count
            Verified = @($rp | Where-Object { $_.verified }).Count
        }
    }

    function Get-DocText {
        param([string]$RelPath)
        [IO.File]::ReadAllText((Join-Path $script:RepoRoot $RelPath))
    }

    function Get-DocLine {
        param([string]$RelPath)
        [IO.File]::ReadAllLines((Join-Path $script:RepoRoot $RelPath))
    }

    # The publish allow-list is the single source of truth for what becomes public.
    function Get-PublishedPath {
        $text = Get-DocText 'tools/Publish-Public.ps1'
        $block = [regex]::Match($text, '(?s)\$allow\s*=\s*@\((.*?)\)')
        if (-not $block.Success) { throw 'could not find the $allow list in tools/Publish-Public.ps1' }
        $paths = @()
        foreach ($m in [regex]::Matches($block.Groups[1].Value, "'([^']+)'")) {
            $paths += $m.Groups[1].Value
        }
        return $paths
    }

    $script:AllowList = @(Get-PublishedPath)
    # Public *docs* are the published Markdown files only.
    $script:PublicDocs = @($script:AllowList |
            Where-Object { $_ -like '*.md' } |
            Where-Object { Test-Path -LiteralPath (Join-Path $script:RepoRoot $_) })

    function Test-PublishedPath {
        param([string]$RelPath)
        foreach ($a in $script:AllowList) {
            if ($RelPath -eq $a) { return $true }
            if ($RelPath.StartsWith($a + '/')) { return $true }
        }
        return $false
    }

    # Collapse "docs/../README.md" style targets without touching the filesystem.
    function Resolve-DocRelativePath {
        param([string]$BaseDir, [string]$Target)
        $parts = @()
        if ($BaseDir) { $parts += ($BaseDir -split '/') }
        $parts += ($Target -replace '\\', '/' -split '/')
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($s in $parts) {
            if ($s -eq '' -or $s -eq '.') { continue }
            elseif ($s -eq '..') { if ($out.Count -gt 0) { $out.RemoveAt($out.Count - 1) } }
            else { [void]$out.Add($s) }
        }
        return ($out -join '/')
    }

    # A dated line is history, not a claim about the current catalog.
    function Test-DatedLine {
        param([string]$Line)
        return ($Line -match '\b(19|20)\d\d[-/]\d\d[-/]\d\d\b')
    }

    # Classify one "<n> ... rules/verified" hit and return the correct catalog number.
    function Get-ExpectedCount {
        param([int]$Number, [string]$Mid, [string]$Keyword, [string]$Rest, [string]$Line)
        $isVerified = ($Keyword -eq 'verified') -or
                      ($Mid -match '(?i)verified|confirmed') -or
                      ($Rest -match '(?i)^\s*(?:were|are|is|was|been)?\s*(?:verified|confirmed)')
        $plats = @()
        foreach ($p in $script:PlatformNames) { if ($Mid -match "(?i)\b$p\b") { $plats += $p } }
        if ($plats.Count -eq 0) {
            foreach ($p in $script:PlatformNames) { if ($Line -match "(?i)\b$p\b") { $plats += $p } }
        }
        if ($isVerified) {
            if ($plats.Count -eq 1) { return $script:ByPlatform[$plats[0]].Verified }
            return $script:TotalVerified
        }
        if ($plats.Count -eq 1) { return $script:ByPlatform[$plats[0]].Rules }
        return $script:TotalRules
    }
}

Describe 'RULES.md is generated from the catalog' {
    It 'matches ConvertTo-VacateRulesMarkdown exactly' {
        $generated = (& $script:Module { ConvertTo-VacateRulesMarkdown }) -replace "`r`n", "`n"
        $onDisk = (Get-DocText 'RULES.md') -replace "`r`n", "`n"
        if ($generated -cne $onDisk) {
            $gl = $generated -split "`n"
            $cl = $onDisk -split "`n"
            $i = 0
            while ($i -lt $gl.Count -and $i -lt $cl.Count -and $gl[$i] -ceq $cl[$i]) { $i++ }
            $fileLine = if ($i -lt $cl.Count) { $cl[$i] } else { '<end of file>' }
            $genLine = if ($i -lt $gl.Count) { $gl[$i] } else { '<end of file>' }
            throw ("RULES.md is stale: run tools/Update-RulesDoc.ps1 (first difference at line {0}:`n  file: {1}`n  generated: {2})" -f ($i + 1), $fileLine, $genLine)
        }
        $true | Should -BeTrue
    }
}

Describe 'Rule counts in the user docs match the catalog' {
    It 'reports the right number of rules and verified rules in README, FAQ and GUIDE' {
        $problems = @()
        foreach ($doc in @('README.md', 'docs/FAQ.md', 'docs/GUIDE.md')) {
            $lines = Get-DocLine $doc
            $inCode = $false
            for ($n = 0; $n -lt $lines.Count; $n++) {
                $line = $lines[$n]
                if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
                if ($inCode) { continue }
                if (Test-DatedLine $line) { continue }
                foreach ($m in [regex]::Matches($line, '(?i)(?<num>\d+)\s+(?<mid>[A-Za-z\- ]{0,30}?)\b(?<kw>rules?|verified)\b')) {
                    $num = [int]$m.Groups['num'].Value
                    $mid = $m.Groups['mid'].Value
                    $kw = $m.Groups['kw'].Value.ToLowerInvariant()
                    $rest = $line.Substring($m.Index + $m.Length)
                    $expected = Get-ExpectedCount -Number $num -Mid $mid -Keyword $kw -Rest $rest -Line $line
                    if ($num -ne $expected) {
                        $problems += ('{0}:{1}: "{2}" should be {3}' -f $doc, ($n + 1), $m.Value.Trim(), $expected)
                    }
                }
            }
        }
        $problems | Should -BeNullOrEmpty -Because ("the catalog has {0} rules ({1} verified); fix stale counts" -f $script:TotalRules, $script:TotalVerified)
    }

    It 'keeps the HANDOFF per-platform table in step with the catalog' {
        $lines = Get-DocLine 'docs/HANDOFF.md'
        $expected = [ordered]@{
            'Rules'             = @($script:ByPlatform['windows'].Rules, $script:ByPlatform['linux'].Rules, $script:ByPlatform['macos'].Rules)
            'Verified on a real machine' = @($script:ByPlatform['windows'].Verified, $script:ByPlatform['linux'].Verified, $script:ByPlatform['macos'].Verified)
            'Not yet verified'  = @(($script:ByPlatform['windows'].Rules - $script:ByPlatform['windows'].Verified), ($script:ByPlatform['linux'].Rules - $script:ByPlatform['linux'].Verified), ($script:ByPlatform['macos'].Rules - $script:ByPlatform['macos'].Verified))
        }
        foreach ($key in $expected.Keys) {
            $row = $lines | Where-Object { $_ -match ('^\|\s*' + [regex]::Escape($key) + '\s*\|') } | Select-Object -First 1
            $row | Should -Not -BeNullOrEmpty -Because "docs/HANDOFF.md should have a '$key' table row"
            $cells = @($row -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            $numbers = @(1..3 | ForEach-Object { [int]([regex]::Match($cells[$_], '\d+').Value) })
            $numbers -join ',' | Should -Be ($expected[$key] -join ',') -Because "the '$key' row (Windows, Linux, macOS) must match the catalog"
        }
    }

    It 'states the right unverified total in HANDOFF' {
        $text = Get-DocText 'docs/HANDOFF.md'
        $m = [regex]::Match($text, '(?i)(\d+)\s+of\s+(\d+)\s+rules?\s+are\s+unverified')
        $m.Success | Should -BeTrue -Because 'docs/HANDOFF.md should summarise how many rules are unverified'
        $statedUnverified = [int]$m.Groups[1].Value
        $statedTotal = [int]$m.Groups[2].Value
        $actualUnverified = $script:TotalRules - $script:TotalVerified
        $statedUnverified | Should -Be $actualUnverified -Because "the catalog has $actualUnverified unverified rules"
        $statedTotal | Should -Be $script:TotalRules -Because "the catalog has $script:TotalRules rules"
    }
}

Describe 'The help text and the README command table agree' {
    It 'lists the same set of commands in both places' {
        $subcommands = @('list', 'show', 'validate')
        $usage = Get-DocText 'vacate.ps1'
        $help = @{}
        foreach ($m in [regex]::Matches($usage, 'vacate\.ps1\s+([a-z][a-z0-9-]*)(?:\s+([a-z][a-z0-9-]*))?')) {
            $verb = $m.Groups[1].Value
            $sub = $m.Groups[2].Value
            if ($sub -and ($subcommands -contains $sub)) { $help["$verb $sub"] = $true }
            else { $help[$verb] = $true }
        }

        $readme = @{}
        $inCommands = $false
        foreach ($line in Get-DocLine 'README.md') {
            if ($line -match '^##\s+Commands\s*$') { $inCommands = $true; continue }
            if ($inCommands -and $line -match '^##\s') { break }
            if (-not $inCommands) { continue }
            $cell = [regex]::Match($line, '^\|\s*`([^`]+)`')
            if (-not $cell.Success) { continue }
            $tokens = @($cell.Groups[1].Value -split '\s+')
            $verb = $tokens[0]
            if ($tokens.Count -ge 2 -and ($subcommands -contains $tokens[1])) { $readme["$verb $($tokens[1])"] = $true }
            else { $readme[$verb] = $true }
        }

        $onlyHelp = @($help.Keys | Where-Object { -not $readme.ContainsKey($_) } | Sort-Object)
        $onlyReadme = @($readme.Keys | Where-Object { -not $help.ContainsKey($_) } | Sort-Object)
        $onlyHelp -join ', ' | Should -Be '' -Because 'commands in the help text are missing from the README command table'
        $onlyReadme -join ', ' | Should -Be '' -Because 'commands in the README table are missing from the help text'
    }
}

Describe 'Rule ids in the public docs exist in the catalog' {
    It 'only names rules that are actually in the catalog' {
        $missing = @()
        foreach ($doc in $script:PublicDocs) {
            $lines = Get-DocLine $doc
            $inCode = $false
            for ($n = 0; $n -lt $lines.Count; $n++) {
                $line = $lines[$n]
                if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
                if ($inCode) { continue }
                # Authoring docs show sample ids after "e.g." / "like"; those are not references.
                if ($line -match '(?i)\b(e\.g\.|for example|such as|\blike\b)') { continue }
                foreach ($m in [regex]::Matches($line, '`([a-z][a-z0-9-]*(?:\.[a-z0-9-]+)+)`')) {
                    $tok = $m.Groups[1].Value
                    $prefix = ($tok -split '\.')[0]
                    if ($script:RulePrefixSet.ContainsKey($prefix) -and -not $script:RuleIdSet.ContainsKey($tok)) {
                        $missing += ('{0}:{1}: {2}' -f $doc, ($n + 1), $tok)
                    }
                }
            }
        }
        $missing | Should -BeNullOrEmpty -Because 'a public doc names a rule id that is not in the catalog'
    }
}

Describe 'Relative links in the public docs stay inside the published set' {
    It 'points only at files that exist and are published' {
        $problems = @()
        foreach ($doc in $script:PublicDocs) {
            $baseDir = Split-Path -Parent $doc
            if ($baseDir -eq $null) { $baseDir = '' }
            $lines = Get-DocLine $doc
            $inCode = $false
            for ($n = 0; $n -lt $lines.Count; $n++) {
                $line = $lines[$n]
                if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
                if ($inCode) { continue }
                foreach ($m in [regex]::Matches($line, '\[[^\]]*\]\(([^)]+)\)')) {
                    $target = $m.Groups[1].Value.Trim()
                    if ($target -match '^[a-z]+://' -or $target -match '^mailto:' -or $target.StartsWith('#')) { continue }
                    $target = ($target -replace '^<', '') -replace '>$', ''
                    $target = ($target -split '#')[0]
                    $target = ($target -split '\s+')[0]
                    if (-not $target) { continue }
                    $rel = Resolve-DocRelativePath -BaseDir $baseDir -Target $target
                    $full = Join-Path $script:RepoRoot $rel
                    if (-not (Test-Path -LiteralPath $full)) {
                        $problems += ('{0}:{1}: link target does not exist: {2}' -f $doc, ($n + 1), $target)
                    }
                    elseif (-not (Test-PublishedPath $rel)) {
                        $problems += ('{0}:{1}: link target is not published: {2}' -f $doc, ($n + 1), $target)
                    }
                }
            }
        }
        $problems | Should -BeNullOrEmpty -Because 'a public doc must not link to a missing or internal file'
    }
}
