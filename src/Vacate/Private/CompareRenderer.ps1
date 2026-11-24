# CompareRenderer.ps1 - renders compare.md and compare.json (DECISIONS D60).
# PowerShell 5.1 compatible. ASCII only. Lines <= 100 characters.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-VacateCompareMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Compare)

    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    $add = {
        param([string]$Text, [string]$Indent = '')
        foreach ($l in (Format-VacateWrappedText -Text $Text -Indent $Indent -Width 96)) {
            [void]$sb.Append($l + $nl)
        }
    }

    [void]$sb.Append('# Scan comparison' + $nl + $nl)
    & $add ('Compared by vacate {0} on {1} ({2}).' -f $Compare.tool.version, $Compare.platform, $Compare.comparedAt)
    & $add ('Newer run: {0} ({1})' -f $Compare.newerRun.path, $Compare.newerRun.finishedAt)
    & $add ('Older run: {0} ({1})' -f $Compare.olderRun.path, $Compare.olderRun.finishedAt)
    if ($Compare.redacted) {
        & $add 'Note: both scans are redacted; paths are shown as hashes.'
    }
    [void]$sb.Append($nl)

    $s = $Compare.summary
    [void]$sb.Append('## Summary' + $nl + $nl)
    & $add ('Compare: {0} gone, {1} still there, {2} new, {3} not comparable.' -f $s.gone, $s.stillThere, $s.new, $s.notComparable)
    [void]$sb.Append($nl)

    # Gone
    [void]$sb.Append(('## Gone ({0})' -f $s.gone) + $nl + $nl)
    if (@($Compare.gone).Count -eq 0) {
        & $add 'No traces were removed between scans.'
    }
    else {
        & $add 'These traces were present in the older scan but are gone in the newer scan:'
        [void]$sb.Append($nl)
        foreach ($g in @($Compare.gone)) {
            $sz = Format-VacateByteSize $g.sizeBytes
            & $add ('- [{0}] {1} ({2})' -f $g.category, $g.title, $g.ruleId)
            & $add ('  Path: {0}' -f $g.locator.resolved)
            & $add ('  Size before: {0}' -f $sz)
        }
    }
    [void]$sb.Append($nl)

    # Still there
    [void]$sb.Append(('## Still there ({0})' -f $s.stillThere) + $nl + $nl)
    if (@($Compare.stillThere).Count -eq 0) {
        & $add 'No traces remained from the older scan.'
    }
    else {
        & $add 'These traces were found in both scans:'
        [void]$sb.Append($nl)
        foreach ($st in @($Compare.stillThere)) {
            $oldSz = Format-VacateByteSize $st.olderSizeBytes
            $newSz = Format-VacateByteSize $st.newerSizeBytes
            $deltaStr = ''
            if ($null -ne $st.sizeDeltaBytes) {
                if ($st.sizeDeltaBytes -gt 0) {
                    $deltaStr = ' (+' + (Format-VacateByteSize $st.sizeDeltaBytes) + ')'
                }
                elseif ($st.sizeDeltaBytes -lt 0) {
                    $deltaStr = ' (-' + (Format-VacateByteSize (-$st.sizeDeltaBytes)) + ')'
                }
                else {
                    $deltaStr = ' (unchanged)'
                }
            }
            & $add ('- [{0}] {1} ({2})' -f $st.category, $st.title, $st.ruleId)
            & $add ('  Path: {0}' -f $st.locator.resolved)
            & $add ('  Size: {0} -> {1}{2}' -f $oldSz, $newSz, $deltaStr)
            if ($st.newerLastWriteTime) {
                & $add ('  Last modified: {0}' -f $st.newerLastWriteTime)
            }
        }
    }
    [void]$sb.Append($nl)

    # New
    [void]$sb.Append(('## New ({0})' -f $s.new) + $nl + $nl)
    if (@($Compare.new).Count -eq 0) {
        & $add 'No new traces appeared in the newer scan.'
    }
    else {
        & $add 'These traces were not present in the older scan:'
        [void]$sb.Append($nl)
        foreach ($n in @($Compare.new)) {
            $sz = Format-VacateByteSize $n.sizeBytes
            & $add ('- [{0}] {1} ({2})' -f $n.category, $n.title, $n.ruleId)
            & $add ('  Path: {0}' -f $n.locator.resolved)
            & $add ('  Size: {0}' -f $sz)
        }
    }
    [void]$sb.Append($nl)

    # Not comparable
    [void]$sb.Append(('## Not comparable ({0})' -f $s.notComparable) + $nl + $nl)
    if (@($Compare.notComparable).Count -eq 0) {
        & $add 'All rules ran in both scans.'
    }
    else {
        & $add 'These rules ran in one scan but were skipped or failed in the other:'
        [void]$sb.Append($nl)
        foreach ($nc in @($Compare.notComparable)) {
            & $add ('- [{0}] {1} ({2})' -f $nc.category, $nc.title, $nc.ruleId)
            & $add ('  Older scan: {0}' -f $nc.olderStatus)
            & $add ('  Newer scan: {0}' -f $nc.newerStatus)
            & $add ('  Reason: {0}' -f $nc.reason)
        }
    }
    [void]$sb.Append($nl)

    return $sb.ToString()
}

function ConvertTo-VacateCompareJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Compare)

    return (($Compare | ConvertTo-Json -Depth 20) -replace "`r`n", "`n")
}
