# Trash.ps1 - Phase 3 dispatcher to the per-platform Trash movers (DECISIONS D50, D53).
# PowerShell 5.1 compatible. ASCII only. This file moves nothing itself: it only chooses the
# mover. The movers (TrashWindows.ps1, TrashLinux.ps1, TrashMacOS.ps1) are the only code allowed
# to move user files, and only into the Recycle Bin or Trash.

$script:VacateUserRootTokens = @('HOME', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG', 'XDG_DATA', 'XDG_STATE', 'LIBRARY')

function Get-VacateCleanRoot {
    # Absolute user root folders a clean may touch (D50), from the platform profile.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object]$PlatformProfile)
    $out = New-Object System.Collections.Generic.List[string]
    $roots = $PlatformProfile.Roots
    foreach ($token in $script:VacateUserRootTokens) {
        $value = $null
        if ($roots -is [System.Collections.IDictionary]) { if ($roots.Contains($token)) { $value = $roots[$token] } }
        elseif ($null -ne $roots -and $null -ne $roots.PSObject.Properties[$token]) { $value = $roots.PSObject.Properties[$token].Value }
        if ($null -eq $value -or [string]$value -eq '' -or $out.Contains([string]$value)) { continue }
        # A root taken from an environment variable must still sit inside the real home folder, so
        # APPDATA=C:\ or XDG_DATA_HOME=/ cannot turn the whole disk into a clean root.
        $homeDir = [string]$PlatformProfile.HomePath
        if ($homeDir -eq '' -or -not (Test-VacatePathUnderRoot -Path ([string]$value) -Root $homeDir -Platform $PlatformProfile)) { continue }
        $out.Add([string]$value)
    }
    return $out.ToArray()
}

function Get-VacateRuleCleanRoot {
    # The one root a rule's targets may be cleaned under: its own locator root, when that root is
    # a user root that passed Get-VacateCleanRoot. Empty when the rule's root is not allowed.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object]$Rule, [Parameter(Mandatory)][object]$PlatformProfile, [AllowEmptyCollection()][string[]]$Roots = @())
    $token = [string]$Rule.locator.root
    if ($script:VacateUserRootTokens -cnotcontains $token) { return @() }
    $value = $null
    $r = $PlatformProfile.Roots
    if ($r -is [System.Collections.IDictionary]) { if ($r.Contains($token)) { $value = [string]$r[$token] } }
    elseif ($null -ne $r -and $null -ne $r.PSObject.Properties[$token]) { $value = [string]$r.PSObject.Properties[$token].Value }
    if ([string]::IsNullOrEmpty($value) -or $Roots -notcontains $value) { return @() }
    return @($value)
}

function ConvertTo-VacateCleanKey {
    # Comparison key for a path: normalised, and lower-cased where the platform ignores case.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$PlatformProfile)
    $n = ConvertTo-VacateNormalizedPath -Path $Path -Platform $PlatformProfile
    if (-not [bool]$PlatformProfile.CaseSensitive) { $n = $n.ToUpperInvariant() }
    return $n
}

function Move-VacateItemToTrash {
    # -TrashRoot is for tests: it sends items to a plain folder with the platform-neutral
    # folder-Trash mover, so no test ever touches a real Recycle Bin or Trash.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Platform,
        [string]$TrashRoot
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Move to Trash')) {
        return [pscustomobject][ordered]@{ ok = $false; trashLocation = $null; error = 'skipped (WhatIf)' }
    }
    if ($TrashRoot) { return (Move-VacateItemToTrashMacOS -Path $Path -TrashRoot $TrashRoot) }
    switch ($Platform) {
        'windows' { return (Move-VacateItemToTrashWindows -Path $Path) }
        'linux' { return (Move-VacateItemToTrashLinux -Path $Path) }
        'macos' { return (Move-VacateItemToTrashMacOS -Path $Path) }
        default { throw "trash: unknown platform '$Platform'." }
    }
}

function Restore-VacateItemFromTrash {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$Platform,
        [string]$TrashRoot
    )
    $loc = [string]$Record.trashLocation
    $orig = [string]$Record.originalPath
    if (-not $PSCmdlet.ShouldProcess($orig, 'Restore from Trash')) {
        return [pscustomobject][ordered]@{ ok = $false; error = 'skipped (WhatIf)' }
    }
    if ($TrashRoot) { return (Restore-VacateItemFromTrashMacOS -TrashLocation $loc -OriginalPath $orig) }
    switch ($Platform) {
        'windows' { return (Restore-VacateItemFromTrashWindows -TrashLocation $loc -OriginalPath $orig) }
        'linux' { return (Restore-VacateItemFromTrashLinux -TrashLocation $loc -OriginalPath $orig) }
        'macos' { return (Restore-VacateItemFromTrashMacOS -TrashLocation $loc -OriginalPath $orig) }
        default { throw "trash: unknown platform '$Platform'." }
    }
}
