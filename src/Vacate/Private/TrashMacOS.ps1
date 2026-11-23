# TrashMacOS.ps1 - macOS Trash mover (D50, D52, D53).
# PowerShell 5.1 compatible. ASCII only.
#
# The only code allowed to move user files is a Trash mover. This one never deletes, never
# overwrites, never launches a process and never reads file contents. It performs a same-volume
# rename into the user Trash. The clean CLI owns the -Execute -Confirm gate (D52) and the undo
# log owns the restore record (D53); Finder's undocumented "Put Back" metadata is not faked.

function Get-VacateMacOSVolumeKey {
    # Pure string helper: which volume does this path live on?
    # Windows: the drive letter or UNC share. macOS: everything is the startup volume except
    # /Volumes/<name>, which is a separate mounted filesystem. No filesystem access, so the
    # tests can exercise the cross-volume rule on any platform.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $p = $Path.Replace('\', '/')
    if ($p.Length -ge 2 -and $p[1] -eq ':') { return $p.Substring(0, 2).ToUpperInvariant() }
    if ($p.StartsWith('//', [StringComparison]::Ordinal)) {
        $parts = $p.TrimStart('/').Split('/')
        if ($parts.Length -ge 2) { return ('//' + $parts[0] + '/' + $parts[1]) }
        return '//'
    }
    $marker = '/Volumes/'
    if ($p.StartsWith($marker, [StringComparison]::OrdinalIgnoreCase)) {
        $rest = $p.Substring($marker.Length)
        $separator = $rest.IndexOf('/')
        if ($separator -gt 0) { return ($marker + $rest.Substring(0, $separator)) }
        return ($marker + $rest)
    }
    return '/'
}

function Get-VacateMacOSTrashRootPath {
    # Default Trash root for production: <user profile>/.Trash. Tests inject a temporary root
    # instead. Uses the framework API, not an environment variable read (Phase 1 rule: only
    # Get-VacateEnvironmentSnapshot reads the environment).
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrEmpty($userProfile)) {
        throw 'vacate: cannot locate the user profile folder for the Trash.'
    }
    return [IO.Path]::Combine($userProfile, '.Trash')
}

function Move-VacateItemToTrashMacOS {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The clean CLI gates every move behind -Execute -Confirm (D52).')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrashRoot = ''
    )

    $source = [IO.Path]::GetFullPath($Path)
    $root = $TrashRoot
    if ([string]::IsNullOrEmpty($root)) { $root = Get-VacateMacOSTrashRootPath }
    $root = [IO.Path]::GetFullPath($root)

    $isDirectory = [IO.Directory]::Exists($source)
    if (-not $isDirectory -and -not [IO.File]::Exists($source)) {
        return [pscustomobject][ordered]@{
            ok = $false
            trashLocation = $null
            error = 'source-missing'
        }
    }

    # A cross-filesystem rename would fail or fall back to copy-then-delete. Refuse it (D50).
    $sourceVolume = Get-VacateMacOSVolumeKey -Path $source
    $trashVolume = Get-VacateMacOSVolumeKey -Path $root
    if (-not [string]::Equals($sourceVolume, $trashVolume, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject][ordered]@{
            ok = $false
            trashLocation = $null
            error = 'cross-volume'
        }
    }

    try {
        [void][IO.Directory]::CreateDirectory($root)
    } catch {
        return [pscustomobject][ordered]@{
            ok = $false
            trashLocation = $null
            error = 'trash-unavailable: ' + $_.Exception.Message
        }
    }

    $trimmed = $source.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $name = [IO.Path]::GetFileName($trimmed)
    $dot = $name.LastIndexOf('.')
    if ($dot -gt 0) {
        $base = $name.Substring(0, $dot)
        $extension = $name.Substring($dot)
    } else {
        $base = $name
        $extension = ''
    }

    # Never overwrite: Finder-style numeric suffix before the extension.
    $candidate = $name
    $suffix = 2
    while ([IO.File]::Exists([IO.Path]::Combine($root, $candidate)) -or
           [IO.Directory]::Exists([IO.Path]::Combine($root, $candidate))) {
        $candidate = $base + ' ' + $suffix + $extension
        $suffix++
        if ($suffix -gt 100000) {
            return [pscustomobject][ordered]@{
                ok = $false
                trashLocation = $null
                error = 'collision-limit'
            }
        }
    }
    $destination = [IO.Path]::Combine($root, $candidate)

    try {
        if ($isDirectory) { [IO.Directory]::Move($source, $destination) }
        else { [IO.File]::Move($source, $destination) }
    } catch {
        return [pscustomobject][ordered]@{
            ok = $false
            trashLocation = $null
            error = 'move-failed: ' + $_.Exception.Message
        }
    }

    return [pscustomobject][ordered]@{
        ok = $true
        trashLocation = $destination
        error = ''
    }
}

function Restore-VacateItemFromTrashMacOS {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The undo CLI gates every move behind -Execute -Confirm (D52).')]
    param(
        [Parameter(Mandatory)][string]$TrashLocation,
        [Parameter(Mandatory)][string]$OriginalPath
    )

    $source = [IO.Path]::GetFullPath($TrashLocation)
    $destination = [IO.Path]::GetFullPath($OriginalPath)

    $isDirectory = [IO.Directory]::Exists($source)
    if (-not $isDirectory -and -not [IO.File]::Exists($source)) {
        return [pscustomobject][ordered]@{ ok = $false; error = 'trash-item-missing' }
    }
    if ([IO.File]::Exists($destination) -or [IO.Directory]::Exists($destination)) {
        return [pscustomobject][ordered]@{ ok = $false; error = 'destination-exists' }
    }

    try {
        if ($isDirectory) { [IO.Directory]::Move($source, $destination) }
        else { [IO.File]::Move($source, $destination) }
    } catch {
        return [pscustomobject][ordered]@{ ok = $false; error = 'restore-failed: ' + $_.Exception.Message }
    }
    return [pscustomobject][ordered]@{ ok = $true; error = '' }
}
