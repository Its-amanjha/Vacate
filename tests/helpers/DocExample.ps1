# DocExample.ps1 - test helper: the command examples in the user docs.
# PowerShell 5.1 compatible. ASCII only.
# Used by tests/integration/DocExamples.Tests.ps1 in both the discovery phase (for -ForEach data)
# and the run phase, because Pester 5 does not carry discovery variables into BeforeAll.

function Get-TestDocCommandExample {
    <#
    .SYNOPSIS
        Every line inside a fenced powershell/bash block of the given docs that calls vacate.ps1.
    .DESCRIPTION
        CanRun is a coarse, deliberate classification used only to pick the -ForEach data for the
        run test: the command must be on the read-only list, and the line must have neither
        -Execute nor a <placeholder>. The test re-checks the parsed line before any child process
        starts, so a wrong answer here cannot start a machine-changing example.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$RelativePath,
        [string[]]$ReadOnlyCommand = @('version', 'help', 'scan', 'rules', 'report', 'checklist', 'plan', 'clean', 'undo', 'erase'),
        # The guide shows several commands in their Windows form. Those are parse-only off Windows,
        # because a backslash is not a path separator there.
        [bool]$WindowsPathAllowed = $true
    )

    $examples = New-Object System.Collections.Generic.List[object]
    foreach ($relative in $RelativePath) {
        $path = Join-Path $Root $relative
        if (-not [IO.File]::Exists($path)) { continue }
        $lines = [IO.File]::ReadAllLines($path)
        $language = ''
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $text = $lines[$index]
            if ($language -eq '') {
                $open = [regex]::Match($text, '^```(powershell|bash)\s*$')
                if ($open.Success) { $language = $open.Groups[1].Value }
                continue
            }
            if ($text -match '^```\s*$') { $language = ''; continue }
            # vacate.cmd passes every argument unchanged to vacate.ps1 (D62), so check it as vacate.ps1.
            $text = $text -replace 'vacate\.cmd\b', 'vacate.ps1'
            if ($text -notmatch 'vacate\.ps1') { continue }
            $command = ''
            $named = [regex]::Match($text, 'vacate\.ps1\s+([A-Za-z]+)')
            if ($named.Success) { $command = $named.Groups[1].Value }
            $needsWindowsPath = ($text -match '\.\\') -or ($text -match '(^|\s)[A-Za-z]:\\')
            $canRun = ($ReadOnlyCommand -contains $command) -and ($text -notmatch '-Execute') -and ($text -notmatch '<[^<>]*>') -and ($WindowsPathAllowed -or -not $needsWindowsPath)
            $examples.Add([pscustomobject][ordered]@{
                    File     = $relative
                    Line     = $index + 1
                    Language = $language
                    Command  = $command
                    Text     = $text.Trim()
                    CanRun   = $canRun
                })
        }
    }
    return $examples.ToArray()
}
