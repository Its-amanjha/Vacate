# CleanRenderer.ps1 - Markdown for clean and undo results (Phase 3).
# PowerShell 5.1 compatible. ASCII only. Lines at most 100 characters.

$script:VacateCleanStatusText = [ordered]@{
    'moved'        = 'Moved to the Recycle Bin / Trash'
    'would-move'   = 'Would be moved (dry run)'
    'refused'      = 'Refused by the safety check'
    'not-eligible' = 'Not eligible for automatic cleaning - do it by hand from the plan'
    'failed'       = 'Move failed - nothing was changed for this item'
}

function ConvertTo-VacateCleanMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Result)
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    $add = { param([string]$Text, [string]$Indent = '') foreach ($l in (Format-VacateWrappedText -Text $Text -Indent $Indent)) { [void]$sb.Append($l + $nl) } }
    $title = 'Clean preview (dry run)'
    if ($Result.mode -ceq 'execute') { $title = 'Clean result' }
    [void]$sb.Append('# ' + $title + $nl + $nl)
    $s = $Result.summary
    if ($Result.mode -ceq 'execute') {
        & $add ('{0} items moved to the Recycle Bin or Trash, {1} refused, {2} failed, {3} not eligible. Nothing was deleted permanently. To put everything back: vacate.ps1 undo -Run <this folder> -Execute -Confirm <machine name>.' -f $s.moved, $s.refused, $s.failed, $s.notEligible)
    }
    else {
        & $add ('Nothing was moved. {0} items would be moved, {1} would be refused by the safety check, {2} are not eligible. To move them: vacate.ps1 clean -Run <this folder> -Steps <numbers> -Execute -Confirm <machine name>.' -f $s.wouldMove, $s.refused, $s.notEligible)
    }
    [void]$sb.Append($nl)
    foreach ($status in $script:VacateCleanStatusText.Keys) {
        $group = @($Result.items | Where-Object { $_.status -ceq $status })
        if ($group.Count -eq 0) { continue }
        [void]$sb.Append('## ' + $script:VacateCleanStatusText[$status] + $nl + $nl)
        foreach ($it in $group) {
            & $add ('- Step {0}, {1} ({2})' -f $it.step, $it.title, $it.ruleId)
            foreach ($l in (Format-VacatePlanLocationLine -Text $it.path)) { [void]$sb.Append($l + $nl) }
            if ($it.reason) { & $add ('Why: ' + $it.reason) '    ' }
        }
        [void]$sb.Append($nl)
    }
    if ($Result.mode -ceq 'execute') {
        [void]$sb.Append('## Checked again after cleaning' + $nl + $nl)
        if (@($Result.stillPresent).Count -eq 0) { & $add 'A new scan of the cleaned rules found nothing left.' }
        else {
            & $add 'A new scan of the cleaned rules still found these (an app may have recreated them):'
            foreach ($p in @($Result.stillPresent)) { foreach ($l in (Format-VacatePlanLocationLine -Text ($p.path + ' (' + $p.ruleId + ')'))) { [void]$sb.Append($l + $nl) } }
        }
        [void]$sb.Append($nl)
    }
    & $add 'Items in the Recycle Bin or Trash still take space and can be restored by anyone using this account until it is emptied. Empty it, or use the full reset in the plan, before the machine changes hands.'
    return $sb.ToString()
}

function ConvertTo-VacateUndoMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Result)
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    $title = 'Undo preview (dry run)'
    if ($Result.mode -ceq 'execute') { $title = 'Undo result' }
    [void]$sb.Append('# ' + $title + $nl + $nl)
    $s = $Result.summary
    foreach ($l in (Format-VacateWrappedText -Text ('{0} entries: {1} restored, {2} would be restored, {3} failed.' -f $s.entries, $s.restored, $s.wouldRestore, $s.failed))) { [void]$sb.Append($l + $nl) }
    [void]$sb.Append($nl)
    foreach ($it in @($Result.items)) {
        foreach ($l in (Format-VacateWrappedText -Text ('- {0}: step {1}, {2}' -f $it.status, $it.step, $it.ruleId))) { [void]$sb.Append($l + $nl) }
        foreach ($l in (Format-VacatePlanLocationLine -Text $it.path)) { [void]$sb.Append($l + $nl) }
        if ($it.reason) { foreach ($l in (Format-VacateWrappedText -Text ('Why: ' + $it.reason) -Indent '    ')) { [void]$sb.Append($l + $nl) } }
    }
    return $sb.ToString()
}
