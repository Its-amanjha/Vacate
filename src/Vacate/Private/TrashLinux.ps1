# TrashLinux.ps1 - Linux Trash mover for the freedesktop.org Trash specification.
# PowerShell 5.1 compatible. ASCII only.
#
# D50: the only Linux code allowed to move user files. It moves them into the user's
# home trash, never deletes them permanently, and never overwrites an existing entry.
# D53: every move is recorded by the caller's undo log; the desktop file manager can
# also restore the entry because files/ and info/*.trashinfo follow the specification.
#
# Only .NET file APIs are used. No gio, no shell. The trash root can be injected so
# tests never touch the real ~/.local/share/Trash.

function Get-VacateTrashPathComparison {
    # Unix file systems are case-sensitive; Windows is not. The same file must behave
    # acceptably when its tests run on Windows.
    [CmdletBinding()]
    [OutputType([StringComparison])]
    param()
    if ([IO.Path]::DirectorySeparatorChar -eq [char]'\') { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-VacateTrashFullPath {
    # Absolute path with a normalized separator style and no trailing separator except
    # for a bare root. Raises on empty or malformed input.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'trash: path is empty' }
    $full = $null
    try {
        $full = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw ("trash: invalid path: $Path")
    }
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { throw ("trash: path has no root: $Path") }
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar))
    }
    return $full
}

function Test-VacateTrashPathEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$PathA,
        [Parameter(Mandatory)][string]$PathB
    )
    return [string]::Equals($PathA, $PathB, (Get-VacateTrashPathComparison))
}

function Test-VacateTrashPathInside {
    # True only for a strict descendant, never for the root itself.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $fullPath = Get-VacateTrashFullPath -Path $Path
    $fullRoot = Get-VacateTrashFullPath -Path $Root
    if (Test-VacateTrashPathEqual -PathA $fullPath -PathB $fullRoot) { return $false }
    $separator = [string][IO.Path]::DirectorySeparatorChar
    $prefix = $fullRoot
    if (-not $prefix.EndsWith($separator, [StringComparison]::Ordinal)) { $prefix = $prefix + $separator }
    return $fullPath.StartsWith($prefix, (Get-VacateTrashPathComparison))
}

function Test-VacateTrashEntryPresent {
    # File.Exists and Directory.Exists follow links; a dangling symlink is a real trash
    # entry and must still count as taken. GetAttributes checks the link itself.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { return $true }
    try {
        [void][IO.File]::GetAttributes($Path)
        return $true
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        if ($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException]) {
            return $false
        }
        # Unknown access error: treat the name as taken rather than risk an overwrite.
        return $true
    }
}

function Select-VacateTrashMountPoint {
    # Longest mount point that is an ancestor of -Path (or the path itself). Pure; the
    # mount list is injected so the rule is testable without a second file system.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MountPoint
    )

    $fullPath = Get-VacateTrashFullPath -Path $Path
    $best = $null
    foreach ($candidate in $MountPoint) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $mount = Get-VacateTrashFullPath -Path $candidate
        if (-not (Test-VacateTrashPathEqual -PathA $fullPath -PathB $mount)) {
            if (-not (Test-VacateTrashPathInside -Path $fullPath -Root $mount)) { continue }
        }
        if ($null -eq $best -or $mount.Length -gt $best.Length) { $best = $mount }
    }
    if ($null -eq $best) { throw ("trash: no mount point for: $fullPath") }
    return $best
}

function ConvertFrom-VacateTrashMountEscape {
    # findmnt prints some characters of a mount point as \xHH (for example \x20 for a
    # space) in its non-raw modes. Returns the decoded form, or $null when nothing changed.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.IndexOf('\x', [StringComparison]::Ordinal) -lt 0) { return $null }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $index = 0
    $changed = $false
    while ($index -lt $Value.Length) {
        if ($Value[$index] -eq [char]'\' -and ($index + 3) -lt $Value.Length -and $Value[$index + 1] -eq [char]'x') {
            $parsed = 0
            if ([int]::TryParse($Value.Substring($index + 2, 2), [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                $bytes.Add([byte]$parsed)
                $index += 4
                $changed = $true
                continue
            }
        }
        foreach ($oneByte in [Text.Encoding]::UTF8.GetBytes([string]$Value[$index])) { $bytes.Add($oneByte) }
        $index++
    }
    if (-not $changed) { return $null }
    return [Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function Get-VacateTrashMountList {
    # Mount points from the module's allow-listed 'mounts' system query (findmnt, the same
    # source the scan uses). No other system file is read. Throws when the list cannot be
    # obtained, so the caller refuses the move instead of guessing (D50).
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $query = Invoke-VacateSystemQuery -Name 'mounts' -Platform (Get-VacatePlatform)
    if ($query.Status -cne 'ok') {
        throw ('trash: cannot determine the file system of the item (mount list ' + $query.Status + '); refusing to move')
    }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($query.Value)) {
        if ($null -eq $entry) { continue }
        $target = [string]$entry.target
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $list.Add($target)
        # Keep the escaped and the decoded spelling: an extra candidate can only make
        # the comparison stricter, a missing one could hide a mount.
        $decoded = ConvertFrom-VacateTrashMountEscape -Value $target
        if ($null -ne $decoded) { $list.Add($decoded) }
    }
    if ($list.Count -eq 0) { throw 'trash: cannot determine the file system of the item (empty mount list); refusing to move' }
    return $list.ToArray()
}

function Test-VacateTrashSameDevice {
    # Same-filesystem check before a move. [IO.File]::Move copies and deletes across
    # devices on Unix instead of failing, so this check must happen first (D50).
    # Method: the longest mount point that is a path prefix of each side must be the same.
    # Callers also refuse links in either path chain, so the lexical prefix is the real one.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$PathA,
        [Parameter(Mandatory)][string]$PathB,
        [string[]]$MountPoint
    )
    $mounts = $MountPoint
    if ($null -eq $mounts) { $mounts = Get-VacateTrashMountList }
    $mountA = Select-VacateTrashMountPoint -Path $PathA -MountPoint $mounts
    $mountB = Select-VacateTrashMountPoint -Path $PathB -MountPoint $mounts
    return (Test-VacateTrashPathEqual -PathA $mountA -PathB $mountB)
}

function ConvertTo-VacateTrashInfoPath {
    # Percent-encodes the bytes of a file name as RFC 2396 requires for .trashinfo Path.
    # Unreserved characters and the separator stay readable; '%' is always encoded.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Path)
    $builder = New-Object System.Text.StringBuilder
    foreach ($value in $bytes) {
        $byte = [int]$value
        $safe = (($byte -ge 0x30 -and $byte -le 0x39) -or
            ($byte -ge 0x41 -and $byte -le 0x5A) -or
            ($byte -ge 0x61 -and $byte -le 0x7A) -or
            $byte -eq 0x2D -or $byte -eq 0x2E -or $byte -eq 0x5F -or $byte -eq 0x7E -or
            $byte -eq 0x2F)
        if ($safe) {
            [void]$builder.Append([char]$byte)
        }
        else {
            [void]$builder.Append('%' + $byte.ToString('X2', [Globalization.CultureInfo]::InvariantCulture))
        }
    }
    return $builder.ToString()
}

function ConvertFrom-VacateTrashInfoPath {
    # Decodes %HH byte sequences as UTF-8. A '%' that is not followed by two hex digits
    # is kept literally, so a hand-edited file cannot make the parser throw.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $bytes = New-Object System.Collections.Generic.List[byte]
    # Literal characters are collected in runs so a surrogate pair is encoded as one
    # sequence; encoding each [char] alone would turn it into replacement characters.
    $literal = New-Object System.Text.StringBuilder
    $index = 0
    while ($index -lt $Value.Length) {
        $character = $Value[$index]
        if ($character -eq [char]'%' -and ($index + 2) -lt $Value.Length) {
            $hex = $Value.Substring($index + 1, 2)
            $parsed = 0
            if ([int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                if ($literal.Length -gt 0) {
                    foreach ($oneByte in [Text.Encoding]::UTF8.GetBytes($literal.ToString())) { $bytes.Add($oneByte) }
                    [void]$literal.Clear()
                }
                $bytes.Add([byte]$parsed)
                $index += 3
                continue
            }
        }
        [void]$literal.Append($character)
        $index++
    }
    if ($literal.Length -gt 0) {
        foreach ($oneByte in [Text.Encoding]::UTF8.GetBytes($literal.ToString())) { $bytes.Add($oneByte) }
    }
    return [Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function ConvertTo-VacateTrashInfoText {
    # The .trashinfo content. DeletionDate is the user's local time, without a zone.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][datetime]$Now
    )

    $encoded = ConvertTo-VacateTrashInfoPath -Path $Path
    $date = $Now.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    return ('[Trash Info]' + "`n" + 'Path=' + $encoded + "`n" + 'DeletionDate=' + $date + "`n")
}

function Get-VacateTrashInfo {
    # Parses one of vacate's own information files. This is metadata written by the
    # mover, not user content (D53); it is read only to verify a restore.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-VacateTrashEntryPresent -Path $Path)) {
        throw ("trash: information file is missing: $Path")
    }
    if (Test-VacateReparse -Attributes ([IO.File]::GetAttributes($Path))) {
        throw ("trash: information file is a link: $Path")
    }
    $text = [IO.File]::ReadAllText($Path)
    $lines = [regex]::Split($text, '\r\n|\n|\r')
    if ($lines.Length -eq 0 -or $lines[0] -cne '[Trash Info]') {
        throw ("trash: information file does not start with [Trash Info]: $Path")
    }

    $pathValue = $null
    $dateValue = $null
    for ($index = 1; $index -lt $lines.Length; $index++) {
        $line = $lines[$index]
        if ($null -eq $pathValue -and $line.StartsWith('Path=', [StringComparison]::Ordinal)) {
            $pathValue = $line.Substring(5)
        }
        if ($null -eq $dateValue -and $line.StartsWith('DeletionDate=', [StringComparison]::Ordinal)) {
            $dateValue = $line.Substring(13)
        }
    }
    if ($null -eq $pathValue -or $pathValue.Length -eq 0) {
        throw ("trash: information file has no Path: $Path")
    }
    return [pscustomobject][ordered]@{
        path         = (ConvertFrom-VacateTrashInfoPath -Value $pathValue)
        deletionDate = $dateValue
    }
}

function Add-VacateTrashNameSuffix {
    # report.pdf -> report.2.pdf; notes -> notes.2; .bashrc -> .bashrc.2.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Number
    )

    $dot = $Name.LastIndexOf([char]'.')
    $suffix = $Number.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($dot -gt 0 -and $dot -lt ($Name.Length - 1)) {
        return ($Name.Substring(0, $dot) + '.' + $suffix + $Name.Substring($dot))
    }
    return ($Name + '.' + $suffix)
}

function Test-VacateTrashNameTaken {
    # Both sides of the pair must be free. A stale .trashinfo is kept, not reused.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$TrashRoot,
        [Parameter(Mandatory)][string]$Name
    )

    $filesDir = [IO.Path]::Combine($TrashRoot, 'files')
    $infoDir = [IO.Path]::Combine($TrashRoot, 'info')
    if (Test-VacateTrashEntryPresent -Path ([IO.Path]::Combine($filesDir, $Name))) { return $true }
    if (Test-VacateTrashEntryPresent -Path ([IO.Path]::Combine($infoDir, ($Name + '.trashinfo')))) { return $true }
    return $false
}

function Find-VacateTrashFreeName {
    # Unique name in files/ and info/. Never overwrites: a name is accepted only when
    # both files/<name> and info/<name>.trashinfo are absent.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TrashRoot,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrEmpty($Name)) { throw 'trash: item name is empty' }
    if ($Name.IndexOf('/') -ge 0 -or $Name.IndexOf('\') -ge 0) {
        throw ("trash: item name contains a separator: $Name")
    }
    if ($Name -eq '.' -or $Name -eq '..') { throw ("trash: invalid item name: $Name") }

    $candidate = $Name
    $number = 1
    while (Test-VacateTrashNameTaken -TrashRoot $TrashRoot -Name $candidate) {
        $number++
        if ($number -gt 100000) { throw ("trash: could not find a free name for: $Name") }
        $candidate = Add-VacateTrashNameSuffix -Name $Name -Number $number
    }
    return $candidate
}

function Get-VacateTrashRootPath {
    # Resolves the home trash without touching the file system. -Environment exists so
    # tests can inject XDG_DATA_HOME/HOME; normal callers use the platform snapshot.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$TrashRoot,
        [System.Collections.IDictionary]$Environment
    )

    if (-not [string]::IsNullOrWhiteSpace($TrashRoot)) {
        if (-not [IO.Path]::IsPathRooted($TrashRoot)) { throw ("trash: trash root is not absolute: $TrashRoot") }
        return (Get-VacateTrashFullPath -Path $TrashRoot)
    }

    if ($null -eq $Environment) { $Environment = Get-VacateEnvironmentSnapshot }
    $dataHome = Get-VacateEnvironmentValue -Environment $Environment -Name 'XDG_DATA_HOME'
    if ($null -ne $dataHome -and (Test-VacateUnixAbsolutePath -Path $dataHome)) {
        $base = ConvertTo-VacateRootPath -Path $dataHome -Separator '/'
        return (Join-VacateRootPath -Base $base -Child 'Trash' -Separator '/')
    }

    $homePath = Get-VacateEnvironmentValue -Environment $Environment -Name 'HOME'
    if ($null -eq $homePath -or -not (Test-VacateUnixAbsolutePath -Path $homePath)) {
        throw 'trash: cannot resolve the home trash; XDG_DATA_HOME and HOME are unset or not absolute'
    }
    $base = Join-VacateRootPath -Base (ConvertTo-VacateRootPath -Path $homePath -Separator '/') -Child '.local/share' -Separator '/'
    return (Join-VacateRootPath -Base $base -Child 'Trash' -Separator '/')
}

function Initialize-VacateTrashDirectory {
    # Creates Trash, files and info if needed. Refuses a file or a symbolic link in any
    # of the three positions so a move cannot be redirected outside the Trash.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TrashRoot)

    $root = Get-VacateTrashFullPath -Path $TrashRoot
    foreach ($name in @('', 'files', 'info')) {
        $directory = $root
        if ($name.Length -gt 0) { $directory = [IO.Path]::Combine($root, $name) }
        if ([IO.Directory]::Exists($directory)) {
            if (Test-VacateReparse -Attributes ([IO.File]::GetAttributes($directory))) {
                throw ("trash: refusing a link in the Trash: $directory")
            }
            continue
        }
        if (Test-VacateTrashEntryPresent -Path $directory) {
            throw ("trash: not a folder: $directory")
        }
        if ((Get-VacatePlatform) -eq 'linux') {
            $mode = [enum]::Parse([type]'System.IO.UnixFileMode', 'UserRead, UserWrite, UserExecute')
            [void][IO.Directory]::CreateDirectory($directory, $mode)
        }
        else {
            [void][IO.Directory]::CreateDirectory($directory)
        }
    }
}

function Get-VacateTrashRootFromLocation {
    # The Trash directory from a files/<name> location. Rejects anything that is not
    # directly inside a folder named files.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$TrashLocation)

    $filesDir = [IO.Path]::GetDirectoryName($TrashLocation)
    if ([string]::IsNullOrEmpty($filesDir)) { throw ("trash: invalid trash location: $TrashLocation") }
    if ([IO.Path]::GetFileName($filesDir) -cne 'files') {
        throw ("trash: not inside a files folder: $TrashLocation")
    }
    $root = [IO.Path]::GetDirectoryName($filesDir)
    if ([string]::IsNullOrEmpty($root)) { throw ("trash: invalid trash location: $TrashLocation") }
    return $root
}

function Get-VacateTrashErrorMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$ErrorRecord)

    $exception = $ErrorRecord
    if ($ErrorRecord.PSObject.Properties.Match('Exception').Count -gt 0) { $exception = $ErrorRecord.Exception }
    while ($null -ne $exception -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }

    $message = 'unknown error'
    if ($null -ne $exception -and -not [string]::IsNullOrWhiteSpace($exception.Message)) {
        $message = $exception.Message
    }
    if (-not $message.StartsWith('trash:', [StringComparison]::Ordinal)) { $message = 'trash: ' + $message }
    return $message
}

function Test-VacateTrashLinkInChain {
    # True when an existing directory from -Path up to (but not including) the file
    # system root is a link. Restore refuses rather than create or move through it.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $full = Get-VacateTrashFullPath -Path $Path
    $root = [IO.Path]::GetPathRoot($full)
    $probe = $full
    while (-not [string]::IsNullOrEmpty($probe) -and $probe.Length -gt $root.Length) {
        if ([IO.Directory]::Exists($probe)) {
            if (Test-VacateReparse -Attributes ([IO.File]::GetAttributes($probe))) { return $true }
        }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
    return $false
}

function Move-VacateItemToTrashLinux {
    # Moves one file or directory into the freedesktop home trash.
    # Returns { ok; trashLocation; error } in that field order (D50, D53).
    # -TrashRoot is a test seam; normal callers omit it and get ~/.local/share/Trash.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrashRoot
    )

    $infoPath = $null
    try {
        if (-not [IO.Path]::IsPathRooted($Path)) { throw ("trash: path is not absolute: $Path") }
        $fullPath = Get-VacateTrashFullPath -Path $Path
        $root = Get-VacateTrashRootPath -TrashRoot $TrashRoot

        if (-not (Test-VacateTrashEntryPresent -Path $fullPath)) { throw ("trash: item not found: $fullPath") }
        if (Test-VacateTrashPathEqual -PathA $fullPath -PathB $root) {
            throw 'trash: refusing to trash the Trash folder'
        }
        if (Test-VacateTrashPathInside -Path $fullPath -Root $root) {
            throw 'trash: refusing to trash an item inside the Trash folder'
        }
        if (Test-VacateTrashPathInside -Path $root -Root $fullPath) {
            throw 'trash: refusing to trash a folder that contains the Trash'
        }
        $parent = [IO.Path]::GetDirectoryName($fullPath)
        if ([string]::IsNullOrEmpty($parent) -or (Test-VacateTrashPathEqual -PathA $parent -PathB $fullPath)) {
            throw 'trash: refusing to trash a file system root'
        }
        # A link in either chain would make the lexical mount comparison below describe
        # the wrong file system, so the device could not be determined reliably.
        if (Test-VacateTrashLinkInChain -Path $parent) {
            throw ("trash: refusing an item below a link (cannot determine its file system): $fullPath")
        }
        if (Test-VacateTrashLinkInChain -Path $root) {
            throw ("trash: refusing a link in the Trash path (cannot determine its file system): $root")
        }
        if (-not (Test-VacateTrashSameDevice -PathA $fullPath -PathB $root)) {
            throw ("trash: the item and the home trash are on different file systems: $fullPath")
        }

        Initialize-VacateTrashDirectory -TrashRoot $root
        $name = [IO.Path]::GetFileName($fullPath)
        $candidate = Find-VacateTrashFreeName -TrashRoot $root -Name $name
        $filesDir = [IO.Path]::Combine($root, 'files')
        $infoDir = [IO.Path]::Combine($root, 'info')
        $trashPath = [IO.Path]::Combine($filesDir, $candidate)
        $candidateInfo = [IO.Path]::Combine($infoDir, ($candidate + '.trashinfo'))

        # The specification requires the information file before the move. The allow-list
        # has no exclusive-create call (O_EXCL), so the name is checked again immediately
        # before writing. A file manager creating the same .trashinfo in the microseconds
        # between this check and WriteAllText could still be overwritten; that window is
        # the documented remaining race (single vacate process is the supported case).
        $text = ConvertTo-VacateTrashInfoText -Path $fullPath -Now ([datetime]::Now)
        if (Test-VacateTrashNameTaken -TrashRoot $root -Name $candidate) {
            throw ("trash: the Trash name was taken while preparing the move, try again: $candidate")
        }
        $infoPath = $candidateInfo
        [IO.File]::WriteAllText($infoPath, $text, (New-Object Text.UTF8Encoding $false))

        $attributes = [IO.File]::GetAttributes($fullPath)
        if (Test-VacateReparse -Attributes $attributes) {
            # Move the link itself; never follow it. Both calls rename the link entry on
            # Unix; File.Move rejects a link whose target is a folder, Directory.Move
            # rejects a link to a file or a dangling link, so pick by the target kind.
            if ([IO.Directory]::Exists($fullPath)) { [IO.Directory]::Move($fullPath, $trashPath) }
            else { [IO.File]::Move($fullPath, $trashPath) }
        }
        elseif (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            [IO.Directory]::Move($fullPath, $trashPath)
        }
        else {
            [IO.File]::Move($fullPath, $trashPath)
        }

        $infoPath = $null
        return [pscustomobject][ordered]@{
            ok            = $true
            trashLocation = $trashPath
            error         = $null
        }
    }
    catch {
        if ($null -ne $infoPath -and (Test-VacateTrashEntryPresent -Path $infoPath)) {
            try {
                [IO.File]::Delete($infoPath)
            }
            catch {
                Write-Verbose ('trash: could not remove the information file: ' + $infoPath)
            }
        }
        return [pscustomobject][ordered]@{
            ok            = $false
            trashLocation = $null
            error         = (Get-VacateTrashErrorMessage -ErrorRecord $_)
        }
    }
}

function Restore-VacateItemFromTrashLinux {
    # Moves one trashed item back and removes its .trashinfo (D53).
    # Returns { ok; error } in that field order.
    # -TrashRoot is a test seam; without it the location must be in the home trash.
    # The original path is checked right before the move. [IO.File]::Move refuses an
    # existing destination itself; [IO.Directory]::Move checks first and then renames, so
    # a folder created at the original path in between is the remaining race.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TrashLocation,
        [Parameter(Mandatory)][string]$OriginalPath,
        [string]$TrashRoot
    )

    try {
        if (-not [IO.Path]::IsPathRooted($TrashLocation)) { throw ("trash: trash location is not absolute: $TrashLocation") }
        if (-not [IO.Path]::IsPathRooted($OriginalPath)) { throw ("trash: original path is not absolute: $OriginalPath") }

        $location = Get-VacateTrashFullPath -Path $TrashLocation
        $original = Get-VacateTrashFullPath -Path $OriginalPath
        if (-not (Test-VacateTrashEntryPresent -Path $location)) {
            throw ("trash: trashed item is missing: $location")
        }

        # Only items in the home trash (or the injected test root) are restored, so a
        # forged undo entry cannot move arbitrary files/<name> folders around.
        $derivedRoot = Get-VacateTrashRootFromLocation -TrashLocation $location
        $expectedRoot = Get-VacateTrashRootPath -TrashRoot $TrashRoot
        if (-not (Test-VacateTrashPathEqual -PathA $derivedRoot -PathB $expectedRoot)) {
            throw ("trash: trash location is outside the expected trash root: $location")
        }
        if (Test-VacateTrashLinkInChain -Path $derivedRoot) {
            throw ("trash: refusing a link in the Trash path (cannot determine its file system): $derivedRoot")
        }
        if ((Test-VacateTrashPathEqual -PathA $original -PathB $derivedRoot) -or
            (Test-VacateTrashPathInside -Path $original -Root $derivedRoot)) {
            throw 'trash: refusing to restore into the Trash folder'
        }

        $filesDir = [IO.Path]::Combine($derivedRoot, 'files')
        $infoDir = [IO.Path]::Combine($derivedRoot, 'info')
        foreach ($directory in @($filesDir, $infoDir)) {
            if (-not [IO.Directory]::Exists($directory)) { throw ("trash: trash folder is missing: $directory") }
            if (Test-VacateReparse -Attributes ([IO.File]::GetAttributes($directory))) {
                throw ("trash: refusing a link in the Trash: $directory")
            }
        }

        $name = [IO.Path]::GetFileName($location)
        $infoPath = [IO.Path]::Combine($infoDir, ($name + '.trashinfo'))
        $info = Get-VacateTrashInfo -Path $infoPath
        if (-not [IO.Path]::IsPathRooted($info.path)) {
            throw ("trash: the information file Path is not absolute: $($info.path)")
        }
        $infoOriginal = Get-VacateTrashFullPath -Path $info.path
        if (-not (Test-VacateTrashPathEqual -PathA $infoOriginal -PathB $original)) {
            throw ("trash: the information file names a different original path: $($info.path)")
        }
        if (Test-VacateTrashEntryPresent -Path $original) {
            throw ("trash: the original path already exists: $original")
        }

        $parent = [IO.Path]::GetDirectoryName($original)
        if ([string]::IsNullOrEmpty($parent) -or (Test-VacateTrashPathEqual -PathA $parent -PathB $original)) {
            throw 'trash: refusing to restore to a file system root'
        }
        if (Test-VacateTrashLinkInChain -Path $parent) {
            throw ("trash: refusing to restore through a link: $parent")
        }
        if (-not (Test-VacateTrashSameDevice -PathA $location -PathB $parent)) {
            throw ("trash: the Trash and the original folder are on different file systems: $original")
        }
        if (-not [IO.Directory]::Exists($parent)) {
            if (Test-VacateTrashEntryPresent -Path $parent) {
                throw ("trash: the original parent is not a folder: $parent")
            }
            [void][IO.Directory]::CreateDirectory($parent)
        }

        $attributes = [IO.File]::GetAttributes($location)
        if (Test-VacateReparse -Attributes $attributes) {
            if ([IO.Directory]::Exists($location)) { [IO.Directory]::Move($location, $original) }
            else { [IO.File]::Move($location, $original) }
        }
        elseif (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            [IO.Directory]::Move($location, $original)
        }
        else {
            [IO.File]::Move($location, $original)
        }

        try {
            [IO.File]::Delete($infoPath)
        }
        catch {
            return [pscustomobject][ordered]@{
                ok    = $true
                error = ('restored, but could not remove the information file: ' + (Get-VacateTrashErrorMessage -ErrorRecord $_))
            }
        }
        return [pscustomobject][ordered]@{
            ok    = $true
            error = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            ok    = $false
            error = (Get-VacateTrashErrorMessage -ErrorRecord $_)
        }
    }
}
