#requires -Version 5.1
<#
.SYNOPSIS
    Sabotage self-test: breaks one component at a time in a throwaway copy of the repo and
    confirms the Pester suite fails (SPEC "Harness self-test").

.DESCRIPTION
    Copies src/, tests/, schemas/, vacate.ps1 and PSScriptAnalyzerSettings.psd1 into a fresh
    folder under [IO.Path]::GetTempPath(). For each mutation it restores the copy's target file
    from the real worktree, applies one exact string replacement (or deletes one rule file),
    runs the copy's tests/Run-Tests.ps1 in a child process of the current host (pwsh or
    powershell), records pass/fail, then restores the copy again. The real worktree is never
    written: file hashes of src/, tests/, schemas/ and the two root files are compared before
    and after, and a difference fails the run.

    Writes docs/SABOTAGE.md and exits 0 only when every mutation made the suite fail.

.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-SabotageTest.ps1

.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-SabotageTest.ps1 -Mutation budget -KeepCopy
#>
[CmdletBinding()]
param(
    # Runs only the mutations whose name contains this text. Used while developing the harness.
    [string]$Mutation,
    # Leaves the mutated copy behind for inspection instead of deleting it.
    [switch]$KeepCopy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$copyNames = @('src', 'tests', 'schemas', 'vacate.ps1', 'PSScriptAnalyzerSettings.psd1')
$hashNames = @('src', 'tests', 'schemas', 'vacate.ps1', 'PSScriptAnalyzerSettings.psd1')
# The suite is started with the host that is running this script, so pwsh tests pwsh and
# PowerShell 5.1 tests 5.1 (same trick as tests/integration/Cli.Tests.ps1).
$hostExe = (Get-Process -Id $PID).Path
$docPath = Join-Path $repoRoot 'docs/SABOTAGE.md'

# The six mutations from SPEC "Harness self-test". Every anchor must match exactly once, so a
# refactor makes the harness throw instead of silently running a mutation that no longer applies.
$mutations = @(
    [pscustomobject][ordered]@{
        Name    = 'force exists = $true'
        File    = 'src/Vacate/Models.ps1'
        Kind    = 'replace'
        Anchor  = '        exists            = $Exists'
        Replace = '        exists            = $true'
        Expect  = 'New-VacateTrace must honour -Exists'
    },
    [pscustomobject][ordered]@{
        Name    = 'drop a rule'
        File    = 'src/Vacate/rules/windows/activity.wordwheelquery.json'
        Kind    = 'delete'
        Anchor  = '"id": "activity.wordwheelquery"'
        Replace = ''
        Expect  = 'the catalog must keep every shipped rule'
    },
    [pscustomobject][ordered]@{
        Name    = 'skip the junction/symlink guard'
        File    = 'src/Vacate/Private/Primitives.ps1'
        Kind    = 'replace'
        Anchor  = '    return (($Attributes -band 0x400) -ne 0)'
        Replace = '    return $false'
        Expect  = 'Test-VacateReparse must report reparse points'
    },
    [pscustomobject][ordered]@{
        Name    = 'ignore the budget'
        File    = 'src/Vacate/Private/Engine.ps1'
        Kind    = 'replace'
        Anchor  = '        if ($budgetHit -or $now -ge $globalDeadline) {'
        Replace = '        if ($false) {'
        Expect  = 'Invoke-VacateEngine must stop and label rules once the budget is gone'
    },
    [pscustomobject][ordered]@{
        Name    = 'disable redaction'
        File    = 'src/Vacate/Private/Redaction.ps1'
        Kind    = 'replace'
        Anchor  = '    $r = ConvertFrom-VacateJson -Json ($Report | ConvertTo-Json -Depth 20)'
        Replace = @'
    $r = ConvertFrom-VacateJson -Json ($Report | ConvertTo-Json -Depth 20)
    $r.scan.redacted = $true
    return $r
'@
        Expect  = 'Protect-VacateReport must hash every path, name and sample'
    },
    [pscustomobject][ordered]@{
        Name    = 'let a wrong-platform rule run'
        File    = 'src/Vacate/Private/RuleLoader.ps1'
        Kind    = 'replace'
        Anchor  = '        if (-not $Platform -or @($r.platforms) -ccontains $Platform) { $rules.Add($r) } else { $na.Add($r) }'
        Replace = '        $rules.Add($r)'
        Expect  = 'Import-VacateRuleSet must park other platforms in NotApplicable'
    }
)

function Get-VacateTreeHash {
    # Relative path + SHA256 for every file under the given names, ordinal sorted.
    # Read-only: hashes are computed from the real worktree and nothing is written.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Names
    )

    $lines = New-Object System.Collections.ArrayList
    $prefix = $Root.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    foreach ($name in $Names) {
        $path = Join-Path $Root $name
        $files = @()
        if ([IO.File]::Exists($path)) { $files = @($path) }
        elseif ([IO.Directory]::Exists($path)) { $files = @([IO.Directory]::GetFiles($path, '*', [IO.SearchOption]::AllDirectories)) }
        else { throw "hash: not found: $path" }
        foreach ($file in $files) {
            $relative = $file
            if ($file.StartsWith($prefix, [StringComparison]::Ordinal)) { $relative = $file.Substring($prefix.Length) }
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            [void]$lines.Add($relative.Replace('\', '/') + ' ' + $hash)
        }
    }
    $result = [string[]]$lines.ToArray()
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
}

function Copy-VacateTree {
    # Copies the shipped tree into a fresh folder. Nothing is read except file metadata.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ([IO.Directory]::Exists($Destination)) { throw "copy: destination already exists: $Destination" }
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($name in $Names) {
        $source = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $source)) { throw "copy: missing $source" }
        Copy-Item -LiteralPath $source -Destination $Destination -Recurse -Force
    }
}

function Invoke-VacateMutation {
    # Restores the copy's target file, then applies exactly one mutation to it.
    # Throws when the anchor text is absent or ambiguous, so a refactor cannot disable a mutation.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Mutation,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Copy
    )

    $relative = [string]$Mutation.File
    $source = Join-Path $Root $relative
    $target = Join-Path $Copy $relative
    if (-not [IO.File]::Exists($source)) { throw ("sabotage: source file missing: {0}.ps1 was refactored?" -f $relative) }
    [void][IO.File]::Copy($source, $target, $true)

    $text = [IO.File]::ReadAllText($target)
    $anchor = [string]$Mutation.Anchor
    $hits = ([regex]::Matches($text, [regex]::Escape($anchor))).Count
    if ($hits -ne 1) {
        throw ("sabotage: mutation '{0}' expects its anchor exactly once in {1}, found {2} times" -f $Mutation.Name, $relative, $hits)
    }

    if ($Mutation.Kind -eq 'delete') {
        # Deliberate deletion inside the throwaway copy only; the real worktree is hashed after.
        Remove-Item -LiteralPath $target -Force
        return
    }
    $mutated = $text.Replace($anchor, [string]$Mutation.Replace)
    [IO.File]::WriteAllText($target, $mutated, (New-Object Text.UTF8Encoding $false))
}

function Invoke-VacateSuite {
    # Runs the copy's own test entry point in a child process and reads its SUMMARY line.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Copy
    )

    $runner = Join-Path $Copy 'tests/Run-Tests.ps1'
    if (-not [IO.File]::Exists($runner)) { throw "suite: missing $runner" }
    $started = Get-Date
    $raw = & $Exe -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1
    $code = $LASTEXITCODE
    $seconds = [int]((Get-Date) - $started).TotalSeconds

    $summary = ''
    $failures = New-Object System.Collections.ArrayList
    foreach ($item in @($raw)) {
        # ANSI colour is stripped so the captured names stay readable in the markdown table.
        $line = ([string]$item) -replace "\x1b\[[0-9;]*[A-Za-z]", ''
        if ($line -match '^SUMMARY \[') { $summary = $line.Trim() }
        if ($line -match '^\s*\[-\]\s+(.+)$') {
            $name = $Matches[1]
            $name = ($name -replace '\s+\d+(\.\d+)?\s*m?s\s+\(\d+.*\)\s*$', '').Trim()
            if ($name.Length -gt 0 -and -not $failures.Contains($name)) { [void]$failures.Add($name) }
        }
    }

    $passed = -1
    $failed = -1
    $skipped = -1
    if ($summary -match 'passed=(\d+)\s+failed=(\d+)\s+skipped=(\d+)') {
        $passed = [int]$Matches[1]
        $failed = [int]$Matches[2]
        $skipped = [int]$Matches[3]
    }

    return [pscustomobject][ordered]@{
        Code     = $code
        Passed   = $passed
        Failed   = $failed
        Skipped  = $skipped
        Summary  = $summary
        Failures = $failures.ToArray()
        Seconds  = $seconds
    }
}

function Format-VacateCell {
    # One markdown table cell: pipes escaped, newlines flattened, length capped.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$Value,
        [int]$MaxLength = 160
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '(none)' }
    $text = ($text -replace '\s*[\r\n]+\s*', ' ').Trim()
    $text = $text.Replace('|', '\|')
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength - 3) + '...' }
    return $text
}

function Get-VacateSabotageMarkdown {
    # The docs/SABOTAGE.md body: date, runtime, baseline, one row per mutation, RESULT line.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][int]$HashedFiles
    )

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# Sabotage self-test')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('Generated by `tools/Invoke-SabotageTest.ps1` (SPEC "Harness self-test"). Each mutation')
    [void]$builder.AppendLine('is applied to a throwaway copy of the repo, the copy runs the full Pester suite, and the')
    [void]$builder.AppendLine('result is recorded here. The real worktree is hashed before and after; a mutation that')
    [void]$builder.AppendLine('leaves the suite green is a hole in the tests, not a pass.')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine(('- Date: {0}' -f $Date))
    [void]$builder.AppendLine(('- Runtime: {0}' -f $Runtime))
    [void]$builder.AppendLine(('- Baseline (unmutated copy): {0}' -f $Baseline.Summary))
    [void]$builder.AppendLine(('- Worktree unchanged: {0} files hashed before and after, identical' -f $HashedFiles))
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('| # | Mutation | File | Anchor | Suite result | Tests that failed |')
    [void]$builder.AppendLine('|---|---|---|---|---|---|')

    $index = 0
    $green = New-Object System.Collections.ArrayList
    foreach ($result in $Results) {
        $index = $index + 1
        $outcome = 'caught'
        if ($result.Caught -ne $true) {
            $outcome = '**STAYED GREEN**'
            [void]$green.Add([string]$result.Mutation.Name)
        }
        $suite = '{0} (exit {1}, passed={2} failed={3}, {4}s)' -f $outcome, $result.Run.Code, $result.Run.Passed, $result.Run.Failed, $result.Run.Seconds
        $failed = '(none)'
        if (@($result.Run.Failures).Count -gt 0) {
            $shown = @($result.Run.Failures | Select-Object -First 4)
            $failed = $shown -join '; '
            if (@($result.Run.Failures).Count -gt $shown.Count) { $failed = $failed + ('; +{0} more' -f (@($result.Run.Failures).Count - $shown.Count)) }
        }
        [void]$builder.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $index, (Format-VacateCell -Value $result.Mutation.Name), (Format-VacateCell -Value $result.Mutation.File), (Format-VacateCell -Value $result.Mutation.Anchor), (Format-VacateCell -Value $suite), (Format-VacateCell -Value $failed -MaxLength 300)))
    }
    [void]$builder.AppendLine('')

    if ($green.Count -eq 0) {
        [void]$builder.AppendLine(('RESULT: all {0} mutations caught' -f @($Results).Count))
    }
    else {
        [void]$builder.AppendLine('RESULT: stayed green: ' + ($green -join '; '))
    }
    return $builder.ToString()
}

# ---------------------------------------------------------------------------------------------
# Main

$selected = @($mutations)
if ($Mutation) {
    $selected = @($mutations | Where-Object { $_.Name -like ('*' + $Mutation + '*') })
    if ($selected.Count -eq 0) { throw "sabotage: no mutation name contains '$Mutation'" }
}

Write-Output ('sabotage: hashing the worktree ({0} names)' -f $hashNames.Count)
$before = Get-VacateTreeHash -Root $repoRoot -Names $hashNames
$beforeCount = @($before).Count

$copyRoot = Join-Path ([IO.Path]::GetTempPath()) ('vacate-sabotage-' + [guid]::NewGuid().ToString('N'))
$results = New-Object System.Collections.ArrayList
$baseline = $null
$exitCode = 1
try {
    Write-Output ('sabotage: copying the repo to {0}' -f $copyRoot)
    Copy-VacateTree -Root $repoRoot -Destination $copyRoot -Names $copyNames

    Write-Output 'sabotage: baseline run on the unmutated copy'
    $baseline = Invoke-VacateSuite -Exe $hostExe -Copy $copyRoot
    Write-Output ('sabotage: baseline {0}' -f $baseline.Summary)
    if ($baseline.Code -ne 0 -or $baseline.Failed -ne 0) {
        throw ('sabotage: the unmutated copy does not pass ({0}); mutations cannot be judged' -f $baseline.Summary)
    }

    foreach ($mutation in $selected) {
        Write-Output ('sabotage: applying "{0}" to {1}' -f $mutation.Name, $mutation.File)
        Invoke-VacateMutation -Mutation $mutation -Root $repoRoot -Copy $copyRoot
        $run = Invoke-VacateSuite -Exe $hostExe -Copy $copyRoot
        $caught = ($run.Code -ne 0 -or $run.Failed -gt 0)
        Write-Output ('sabotage: "{0}" -> {1} ({2})' -f $mutation.Name, $(if ($caught) { 'caught' } else { 'STAYED GREEN' }), $run.Summary)
        [void]$results.Add([pscustomobject][ordered]@{
                Mutation = $mutation
                Run      = $run
                Caught   = $caught
            })
        # Restore the copy's file so the next mutation starts from pristine source.
        $original = Join-Path $repoRoot ([string]$mutation.File)
        [void][IO.File]::Copy($original, (Join-Path $copyRoot ([string]$mutation.File)), $true)
    }

    $after = Get-VacateTreeHash -Root $repoRoot -Names $hashNames
    $diff = @(Compare-Object -ReferenceObject $before -DifferenceObject $after)
    if ($diff.Count -gt 0) {
        $changed = @($diff | ForEach-Object { $_.InputObject -replace ' .*$', '' })
        throw ('sabotage: the real worktree changed during the run: ' + ($changed -join ', '))
    }
    Write-Output ('sabotage: worktree unchanged ({0} files)' -f $beforeCount)

    $edition = [string]$PSVersionTable.PSEdition
    $version = $PSVersionTable.PSVersion.ToString()
    $runtime = '{0} {1} via {2} on {3}' -f $edition, $version, (Split-Path -Leaf $hostExe), [Environment]::OSVersion.VersionString
    $markdown = Get-VacateSabotageMarkdown -Date ((Get-Date).ToString('yyyy-MM-dd')) -Runtime $runtime -Baseline $baseline -Results $results.ToArray() -HashedFiles $beforeCount
    [IO.File]::WriteAllText($docPath, $markdown, (New-Object Text.UTF8Encoding $false))
    Write-Output ('sabotage: wrote {0}' -f $docPath)

    $green = @($results | Where-Object { $_.Caught -ne $true })
    if ($green.Count -eq 0) { $exitCode = 0 }
    Write-Output ('sabotage: RESULT caught={0} stayedGreen={1}' -f (@($results).Count - $green.Count), $green.Count)
}
finally {
    if ($KeepCopy) { Write-Output ('sabotage: kept the copy at {0}' -f $copyRoot) }
    elseif ([IO.Directory]::Exists($copyRoot)) { Remove-Item -LiteralPath $copyRoot -Recurse -Force }
}

exit $exitCode
