# Invoke-VacateUndo.ps1 - public: Phase 3 undo (DECISIONS D53).
# PowerShell 5.1 compatible. ASCII only. Dry run by default; restoring needs -Execute -Confirm
# <MACHINENAME>. Helpers it uses live in Invoke-VacateClean.ps1.

function Invoke-VacateUndo {
    <#
    .SYNOPSIS
        Restores items recorded in undo.json. Dry run unless -Execute -Confirm.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Run,
        [switch]$Execute,
        [Alias('Confirm')][string]$ConfirmMachine,
        [string]$TrashRoot,
        [object]$PlatformProfile,
        [datetime]$Now = [datetime]::UtcNow
    )
    $runDir = [IO.Path]::GetFullPath($Run)
    $base = [IO.Path]::GetDirectoryName($runDir)
    $report = Read-VacateRunFile -RunDir $runDir -Name 'report.json'
    $platform = Get-VacatePlatform
    Assert-VacateCleanRun -Report $report -Platform $platform -Execute $Execute.IsPresent -ConfirmMachine $ConfirmMachine
    $undoPath = [IO.Path]::Combine($runDir, 'undo.json')
    if (-not [IO.File]::Exists($undoPath)) { throw "No undo.json in $runDir; nothing was moved from this run." }
    $log = ConvertFrom-VacateUndoJson -Json ([IO.File]::ReadAllText($undoPath))
    if ([string]$log.platform -cne $platform -or -not [string]::Equals([string]$log.machine, [Environment]::MachineName, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'undo.json was written on another machine or platform; it is not used here.'
    }
    $ctx = Get-VacateCleanContext -Platform $platform -PlatformProfile $PlatformProfile

    $rows = New-Object System.Collections.Generic.List[object]
    # Newest first, so a folder moved after one of its parents' siblings comes back in a sane order.
    $entries = @($log.entries)
    [Array]::Reverse($entries)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $row = [pscustomobject][ordered]@{ index = [int]$e.index; step = [int]$e.step; ruleId = [string]$e.ruleId; path = [string]$e.originalPath; status = ''; reason = '' }
        if ($null -ne $e.restoredAt) { $row.status = 'already-restored' }
        else {
            # The original place must be empty and inside this user's roots, with no link on the way.
            $chk = Test-VacateCleanTarget -Path $row.path -AllowedRoots $ctx.Roots
            if ($chk.code -cne 'missing') {
                $row.status = 'refused'
                if ($chk.ok) { $row.reason = 'Something already exists at the original path; it is not overwritten.' } else { $row.reason = $chk.reason }
            }
            elseif (-not $Execute) { $row.status = 'would-restore' }
            else {
            $r = Restore-VacateItemFromTrash -Record $e -Platform $platform -TrashRoot $TrashRoot
            if ($r.ok) {
                $row.status = 'restored'
                $log = (Set-VacateUndoRestored -Log $log -Index ([int]$e.index) -Now ([datetime]::UtcNow))
                Write-VacateTextFile -BaseDir $base -Path $undoPath -Text (ConvertTo-VacateUndoJson -Log $log)
            }
            else { $row.status = 'failed'; $row.reason = [string]$r.error }
            }
        }
        $rows.Add($row)
    }
    $result = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        mode          = $(if ($Execute) { 'execute' } else { 'dry-run' })
        at            = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        summary       = [pscustomobject][ordered]@{
            entries = $rows.Count
            restored = @($rows | Where-Object { $_.status -ceq 'restored' }).Count
            wouldRestore = @($rows | Where-Object { $_.status -ceq 'would-restore' }).Count
            failed = @($rows | Where-Object { $_.status -ceq 'failed' }).Count
            refused = @($rows | Where-Object { $_.status -ceq 'refused' }).Count
        }
        items         = $rows.ToArray()
    }
    $name = 'undo-preview'
    if ($Execute) { $name = 'undo-result' }
    Write-VacateTextFile -BaseDir $base -Path ([IO.Path]::Combine($runDir, $name + '.md')) -Text (ConvertTo-VacateUndoMarkdown -Result $result)
    return $result
}
