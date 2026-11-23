# TrashWindows.ps1 - Windows Recycle Bin mover (Phase 3, D50-D53).
# PowerShell 5.1 compatible. ASCII only.
# This is the only file allowed to recycle user files. It never deletes permanently (D50):
# - before the move it refuses every case where the shell is known to fall back to a permanent
#   delete (no bin on the drive, bin disabled, item larger than the bin, path too long);
# - after the move it reports ok only when the item is gone from its path AND this user's
#   $Recycle.Bin folder holds a $R item whose $I record names the original path.
# Restore moves that $R item back with [IO.File]::Move / [IO.Directory]::Move (D53). The $I
# record is left behind because no delete API is allowed here; without its $R item the
# Recycle Bin no longer lists it.
# No COM, no process launch, no environment reads.

$script:VacateTrashWindowsReady = $false

# Longest path the legacy SHFileOperation behind the Recycle Bin call accepts (MAX_PATH minus
# the terminating null).
$script:VacateTrashWindowsMaxPath = 259

# Largest $I record we read. Version 1 records are 544 bytes; version 2 hold at most 32767 chars.
$script:VacateTrashWindowsMaxRecordBytes = 65600

function Initialize-VacateTrashWindows {
    # Loads the Microsoft.VisualBasic assembly by name (never by compiling code). Windows only.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    if ($script:VacateTrashWindowsReady) { return $true }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    }
    catch {
        return $false
    }
    $script:VacateTrashWindowsReady = $true
    return $true
}

function ConvertTo-VacateTrashWindowsMoveResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$Ok,
        [AllowNull()][AllowEmptyString()][string]$TrashLocation = '',
        [AllowEmptyString()][string]$ErrorText = ''
    )
    $location = $null
    if (-not [string]::IsNullOrEmpty($TrashLocation)) { $location = $TrashLocation }
    return [pscustomobject][ordered]@{ ok = $Ok; trashLocation = $location; error = $ErrorText }
}

function ConvertTo-VacateTrashWindowsRestoreResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][bool]$Ok, [AllowEmptyString()][string]$ErrorText = '')
    return [pscustomobject][ordered]@{ ok = $Ok; error = $ErrorText }
}

function Get-VacateTrashWindowsLongPath {
    # Expands 8.3 short components (ADMINI~1) to their long names so the path compares equal to
    # the long path the Recycle Bin records. Components that do not exist are kept as given.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FullPath)

    if ($FullPath.IndexOf('~') -lt 0) { return $FullPath }
    $root = [IO.Path]::GetPathRoot($FullPath)
    $rest = $FullPath.Substring($root.Length)
    $current = $root
    foreach ($part in $rest.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $name = $part
        if ($part.IndexOf('~') -ge 0 -and [IO.Directory]::Exists($current)) {
            try {
                $found = @([IO.Directory]::GetFileSystemEntries($current, $part))
                if ($found.Count -eq 1) { $name = [IO.Path]::GetFileName([string]$found[0]) }
            }
            catch {
                $name = $part
            }
        }
        $current = Join-Path $current $name
    }
    return $current
}

function Get-VacateTrashWindowsFullPath {
    # One normal form for both movers: rooted local drive path, long names, no trailing
    # separator, not a volume root, short enough for SHFileOperation.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return [pscustomobject][ordered]@{ ok = $false; fullPath = $null; error = 'path is empty' }
    }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) {
        return [pscustomobject][ordered]@{ ok = $false; fullPath = $null; error = 'network and device paths are not supported' }
    }
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.Length -lt 3 -or $Path[1] -ne ':') {
        return [pscustomobject][ordered]@{ ok = $false; fullPath = $null; error = 'path is not absolute' }
    }

    $full = ''
    try {
        $full = [IO.Path]::GetFullPath($Path)
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; fullPath = $null; error = 'path is not valid: ' + $_.Exception.Message }
    }

    $trimmed = $full.TrimEnd([char[]]@('\', '/'))
    if ($trimmed.Length -le 2) {
        return [pscustomobject][ordered]@{ ok = $false; fullPath = $null; error = 'refusing to move a volume root' }
    }
    $trimmed = Get-VacateTrashWindowsLongPath -FullPath $trimmed
    if ($trimmed.Length -gt $script:VacateTrashWindowsMaxPath) {
        return [pscustomobject][ordered]@{ ok = $false; fullPath = $null; error = 'path is too long for the Recycle Bin (more than 259 characters); the shell could delete it permanently' }
    }
    return [pscustomobject][ordered]@{ ok = $true; fullPath = $trimmed; error = '' }
}

function Get-VacateTrashWindowsVolume {
    # Recycle Bin facts for the volume that holds FullPath. Fails closed: only a ready, local,
    # fixed NTFS or ReFS volume is accepted (removable, network, optical and FAT volumes may have
    # no Recycle Bin, and the shell then deletes permanently).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$FullPath)

    $fail = {
        param($Message)
        return [pscustomobject][ordered]@{ ok = $false; error = $Message; root = $null; totalBytes = [int64]0; sidFolder = $null }
    }

    $root = [IO.Path]::GetPathRoot($FullPath)
    if ([string]::IsNullOrEmpty($root)) { return (& $fail 'path has no volume root') }

    $driveType = [IO.DriveType]::Unknown
    $format = ''
    $total = [int64]0
    try {
        $drive = New-Object System.IO.DriveInfo -ArgumentList $root
        if (-not $drive.IsReady) { return (& $fail 'the volume is not ready') }
        $driveType = $drive.DriveType
        $format = [string]$drive.DriveFormat
        $total = [int64]$drive.TotalSize
    }
    catch {
        return (& $fail ('cannot inspect the volume: ' + $_.Exception.Message))
    }
    if ($driveType -ne [IO.DriveType]::Fixed) {
        return (& $fail ('only local fixed drives are supported (this drive is ' + $driveType + '); it may have no Recycle Bin and the item would be deleted permanently'))
    }
    if ($format -ne 'NTFS' -and $format -ne 'ReFS') {
        return (& $fail ('only NTFS and ReFS drives are supported (this drive is ' + $format + ')'))
    }

    $sid = ''
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        return (& $fail ('cannot read the current user SID: ' + $_.Exception.Message))
    }
    if ([string]::IsNullOrEmpty($sid)) { return (& $fail 'cannot read the current user SID') }

    return [pscustomobject][ordered]@{
        ok         = $true
        error      = ''
        root       = $root
        totalBytes = $total
        sidFolder  = (Join-Path (Join-Path $root '$Recycle.Bin') $sid)
    }
}

function Get-VacateTrashWindowsRegistryValue {
    # Reads one registry value read-only. $null when the key or value is missing or unreadable.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$Hive,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Name
    )
    $key = $null
    try {
        $key = $Hive.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return $null }
        return $key.GetValue($Name, $null)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Get-VacateTrashWindowsBinSetting {
    # Recycle Bin settings that decide whether the shell recycles or deletes permanently.
    # The per-volume keys under BitBucket\Volume are named by a shell volume id that cannot be
    # mapped to a drive letter without COM, so this fails closed across all volumes: any volume
    # with NukeOnDelete=1 refuses, and the smallest MaxCapacity of any volume is the limit.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][int64]$VolumeTotalBytes)

    $hku = [Microsoft.Win32.Registry]::CurrentUser
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $policy = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $bucket = 'Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket'

    foreach ($hive in @($hku, $hklm)) {
        $value = Get-VacateTrashWindowsRegistryValue -Hive $hive -SubKey $policy -Name 'NoRecycleFiles'
        if ($null -ne $value -and [int64]$value -ne 0) {
            return [pscustomobject][ordered]@{ ok = $false; error = 'the Recycle Bin is turned off by policy (NoRecycleFiles); the item would be deleted permanently'; capacityBytes = [int64]0 }
        }
    }
    foreach ($hive in @($hku, $hklm)) {
        $value = Get-VacateTrashWindowsRegistryValue -Hive $hive -SubKey $bucket -Name 'NukeOnDelete'
        if ($null -ne $value -and [int64]$value -ne 0) {
            return [pscustomobject][ordered]@{ ok = $false; error = 'the Recycle Bin is set to delete immediately (NukeOnDelete); the item would be deleted permanently'; capacityBytes = [int64]0 }
        }
    }

    $limits = New-Object System.Collections.ArrayList
    $volumeKey = $null
    try {
        $volumeKey = $hku.OpenSubKey($bucket + '\Volume', $false)
        if ($null -ne $volumeKey) {
            foreach ($name in $volumeKey.GetSubKeyNames()) {
                $sub = $bucket + '\Volume\' + $name
                $nuke = Get-VacateTrashWindowsRegistryValue -Hive $hku -SubKey $sub -Name 'NukeOnDelete'
                if ($null -ne $nuke -and [int64]$nuke -ne 0) {
                    return [pscustomobject][ordered]@{ ok = $false; error = 'a drive has its Recycle Bin set to delete immediately (NukeOnDelete) and vacate cannot tell which drive; turn that setting off to continue'; capacityBytes = [int64]0 }
                }
                $maxMb = Get-VacateTrashWindowsRegistryValue -Hive $hku -SubKey $sub -Name 'MaxCapacity'
                if ($null -ne $maxMb) { [void]$limits.Add([int64]$maxMb * 1MB) }
            }
        }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; error = 'cannot read the Recycle Bin settings: ' + $_.Exception.Message; capacityBytes = [int64]0 }
    }
    finally {
        if ($null -ne $volumeKey) { $volumeKey.Close() }
    }

    foreach ($hive in @($hku, $hklm)) {
        $percent = Get-VacateTrashWindowsRegistryValue -Hive $hive -SubKey $policy -Name 'RecycleBinSize'
        if ($null -ne $percent) { [void]$limits.Add([int64]([double]$VolumeTotalBytes * [int64]$percent / 100)) }
    }
    if ($limits.Count -eq 0) {
        # No recorded size: assume a conservative 5 percent of the volume.
        [void]$limits.Add([int64]([double]$VolumeTotalBytes * 0.05))
    }

    $capacity = [int64]::MaxValue
    foreach ($limit in $limits) { if ([int64]$limit -lt $capacity) { $capacity = [int64]$limit } }
    return [pscustomobject][ordered]@{ ok = $true; error = ''; capacityBytes = $capacity }
}

function Get-VacateTrashWindowsTreeFact {
    # Total size and path-length check for a file or a folder tree, from metadata only. Does not
    # descend into links. Fails closed when any part cannot be read.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][bool]$IsDirectory,
        [Parameter(Mandatory)][string]$SidFolder
    )

    # The item is renamed to <sid folder>\$Rxxxxxx<ext>; descendants keep their relative path.
    $binPrefixLength = $SidFolder.Length + 9 + [IO.Path]::GetExtension($FullPath).Length
    $max = $script:VacateTrashWindowsMaxPath
    if ($binPrefixLength -gt $max) {
        return [pscustomobject][ordered]@{ ok = $false; error = 'the Recycle Bin path would be too long'; sizeBytes = [int64]0 }
    }
    if (-not $IsDirectory) {
        try {
            $length = [int64](New-Object System.IO.FileInfo -ArgumentList $FullPath).Length
            return [pscustomobject][ordered]@{ ok = $true; error = ''; sizeBytes = $length }
        }
        catch {
            return [pscustomobject][ordered]@{ ok = $false; error = 'cannot read the file size: ' + $_.Exception.Message; sizeBytes = [int64]0 }
        }
    }

    $total = [int64]0
    $stack = New-Object System.Collections.Stack
    $stack.Push((New-Object System.IO.DirectoryInfo -ArgumentList $FullPath))
    try {
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($entry in $dir.GetFileSystemInfos()) {
                $entryPath = $entry.FullName
                $relative = $entryPath.Length - $FullPath.Length
                if ($entryPath.Length -gt $max -or ($binPrefixLength + $relative) -gt $max) {
                    return [pscustomobject][ordered]@{ ok = $false; error = 'a path inside the folder is too long for the Recycle Bin: ' + $entryPath; sizeBytes = [int64]0 }
                }
                $isLink = Test-VacateReparse -Attributes ([int64]$entry.Attributes)
                if ($entry -is [IO.DirectoryInfo]) {
                    if (-not $isLink) { $stack.Push($entry) }
                }
                elseif (-not $isLink) {
                    $total += [int64]$entry.Length
                }
            }
        }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; error = 'cannot read the folder contents: ' + $_.Exception.Message; sizeBytes = [int64]0 }
    }
    return [pscustomobject][ordered]@{ ok = $true; error = ''; sizeBytes = $total }
}

function Read-VacateTrashWindowsRecord {
    # Parses one $I record (Recycle Bin metadata, not user content): version, original size,
    # deletion time, original path. Version 1 (Vista to 8.1): fixed 260-char path at offset 24.
    # Version 2 (10 and later): path length in chars at offset 24, path at offset 28.
    # Returns $null for anything that is not a well-formed record.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$InfoPath)

    $bytes = $null
    try {
        $info = New-Object System.IO.FileInfo -ArgumentList $InfoPath
        if (-not $info.Exists -or $info.Length -lt 28 -or $info.Length -gt $script:VacateTrashWindowsMaxRecordBytes) { return $null }
        $bytes = [IO.File]::ReadAllBytes($InfoPath)
    }
    catch {
        return $null
    }
    if ($bytes.Length -lt 28) { return $null }

    $version = [BitConverter]::ToInt64($bytes, 0)
    $size = [BitConverter]::ToInt64($bytes, 8)
    $fileTime = [BitConverter]::ToInt64($bytes, 16)
    $text = ''
    if ($version -eq 1) {
        if ($bytes.Length -lt 544) { return $null }
        $text = [Text.Encoding]::Unicode.GetString($bytes, 24, 520)
    }
    elseif ($version -eq 2) {
        $chars = [BitConverter]::ToInt32($bytes, 24)
        if ($chars -le 0 -or (28 + [int64]$chars * 2) -gt $bytes.Length) { return $null }
        $text = [Text.Encoding]::Unicode.GetString($bytes, 28, $chars * 2)
    }
    else {
        return $null
    }
    $nul = $text.IndexOf([char]0)
    if ($nul -ge 0) { $text = $text.Substring(0, $nul) }
    if ([string]::IsNullOrEmpty($text)) { return $null }

    $deletedAt = [DateTime]::MinValue
    try {
        $deletedAt = [DateTime]::FromFileTimeUtc($fileTime)
    }
    catch {
        $deletedAt = [DateTime]::MinValue
    }

    $folder = [IO.Path]::GetDirectoryName($InfoPath)
    $leaf = [IO.Path]::GetFileName($InfoPath)
    return [pscustomobject][ordered]@{
        version      = $version
        sizeBytes    = $size
        deletedAt    = $deletedAt
        originalPath = $text.TrimEnd([char[]]@('\', '/'))
        infoPath     = $InfoPath
        trashPath    = (Join-Path $folder ('$R' + $leaf.Substring(2)))
    }
}

function Get-VacateTrashWindowsRecord {
    # Every readable $I record in this user's Recycle Bin folder on one volume.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string]$SidFolder)

    if (-not [IO.Directory]::Exists($SidFolder)) { return @() }
    $names = @()
    try {
        $names = @([IO.Directory]::GetFiles($SidFolder, '$I*'))
    }
    catch {
        return @()
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($name in $names) {
        $record = Read-VacateTrashWindowsRecord -InfoPath $name
        if ($null -ne $record) { [void]$list.Add($record) }
    }
    return $list.ToArray()
}

function Find-VacateTrashWindowsEntry {
    # Recycle Bin entries recorded for OriginalFullPath whose $R item still exists, newest first.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$SidFolder,
        [Parameter(Mandatory)][string]$OriginalFullPath
    )

    $matched = New-Object System.Collections.ArrayList
    foreach ($record in @(Get-VacateTrashWindowsRecord -SidFolder $SidFolder)) {
        if (-not [string]::Equals($record.originalPath, $OriginalFullPath, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not ([IO.File]::Exists($record.trashPath) -or [IO.Directory]::Exists($record.trashPath))) { continue }
        [void]$matched.Add($record)
    }
    return @($matched.ToArray() | Sort-Object -Property deletedAt -Descending)
}

function Move-VacateItemToTrashWindows {
    # Moves one file or folder to the Recycle Bin (D50). Returns ok=$false instead of ever risking
    # a permanent delete. trashLocation is the $R path that now holds the item.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Initialize-VacateTrashWindows)) {
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText 'the Windows Recycle Bin is not available on this platform')
    }

    $resolved = Get-VacateTrashWindowsFullPath -Path $Path
    if (-not $resolved.ok) { return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText $resolved.error) }
    $full = [string]$resolved.fullPath

    $isDirectory = [IO.Directory]::Exists($full)
    $isFile = [IO.File]::Exists($full)
    if (-not $isDirectory -and -not $isFile) {
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText 'item not found')
    }

    $attributes = [int64]0
    try {
        $attributes = [int64][IO.File]::GetAttributes($full)
    }
    catch {
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText ('cannot read the item attributes: ' + $_.Exception.Message))
    }
    if (Test-VacateReparse -Attributes $attributes) {
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText 'refusing to move a link')
    }
    if (Test-VacateCloudPlaceholder -Attributes $attributes) {
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText 'refusing to move a cloud placeholder')
    }
    if ($isFile -and (($attributes -band [int64][IO.FileAttributes]::ReadOnly) -ne 0)) {
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText 'refusing to move a read-only file')
    }

    $volume = Get-VacateTrashWindowsVolume -FullPath $full
    if (-not $volume.ok) { return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText $volume.error) }

    $settings = Get-VacateTrashWindowsBinSetting -VolumeTotalBytes $volume.totalBytes
    if (-not $settings.ok) { return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText $settings.error) }

    $facts = Get-VacateTrashWindowsTreeFact -FullPath $full -IsDirectory $isDirectory -SidFolder $volume.sidFolder
    if (-not $facts.ok) { return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText $facts.error) }
    if ([int64]$facts.sizeBytes -ge [int64]$settings.capacityBytes) {
        $message = 'the item ({0} bytes) is not smaller than the Recycle Bin limit ({1} bytes); the shell would delete it permanently' -f $facts.sizeBytes, $settings.capacityBytes
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText $message)
    }

    if (-not [Environment]::UserInteractive) {
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText 'the session is not interactive; the Recycle Bin cannot be used safely')
    }

    $before = @{}
    foreach ($record in @(Get-VacateTrashWindowsRecord -SidFolder $volume.sidFolder)) {
        $before[$record.infoPath.ToUpperInvariant()] = $record.deletedAt
    }
    $startedAt = [DateTime]::UtcNow.AddSeconds(-5)

    # SendToRecycleBin only; ThrowException turns a cancelled operation into an error, never UI.
    $moveError = ''
    try {
        if ($isDirectory) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $full,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
        }
        else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $full,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
        }
    }
    catch {
        $moveError = $_.Exception.Message
    }

    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        if ([string]::IsNullOrEmpty($moveError)) { $moveError = 'the item is still at its original path' }
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText ('could not move the item to the Recycle Bin: ' + $moveError))
    }

    # Confirm the Recycle Bin really holds it: a new $I record naming this path, with its $R item.
    $entry = $null
    for ($attempt = 0; $attempt -lt 15 -and $null -eq $entry; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Milliseconds 200 }
        foreach ($candidate in @(Find-VacateTrashWindowsEntry -SidFolder $volume.sidFolder -OriginalFullPath $full)) {
            $key = $candidate.infoPath.ToUpperInvariant()
            $isNew = (-not $before.ContainsKey($key)) -or ($before[$key] -ne $candidate.deletedAt)
            if (-not $isNew -or $candidate.deletedAt -lt $startedAt) { continue }
            if ($isDirectory -ne [IO.Directory]::Exists($candidate.trashPath)) { continue }
            $entry = $candidate
            break
        }
    }
    if ($null -eq $entry) {
        $message = 'the item is gone from its path but no matching Recycle Bin entry was found in ' + $volume.sidFolder + '; check the Recycle Bin by hand'
        if (-not [string]::IsNullOrEmpty($moveError)) { $message = $message + ' (' + $moveError + ')' }
        return (ConvertTo-VacateTrashWindowsMoveResult -Ok $false -ErrorText $message)
    }
    return (ConvertTo-VacateTrashWindowsMoveResult -Ok $true -TrashLocation $entry.trashPath -ErrorText '')
}

function Restore-VacateItemFromTrashWindows {
    # Moves an item back from the Recycle Bin to OriginalPath (D53). Uses the recorded $R path
    # when its $I record names OriginalPath, else the newest entry recorded for OriginalPath.
    # Never overwrites. The $I record stays behind (see the file header).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TrashLocation = '',
        [Parameter(Mandatory)][string]$OriginalPath
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText 'the Windows Recycle Bin is not available on this platform')
    }

    $resolved = Get-VacateTrashWindowsFullPath -Path $OriginalPath
    if (-not $resolved.ok) { return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText $resolved.error) }
    $full = [string]$resolved.fullPath

    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText 'the original path already exists; refusing to overwrite it')
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrEmpty($parent) -or -not [IO.Directory]::Exists($parent)) {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText 'the original folder no longer exists; restore it by hand from the Recycle Bin')
    }

    $sid = ''
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText ('cannot read the current user SID: ' + $_.Exception.Message))
    }
    $sidFolder = Join-Path (Join-Path ([IO.Path]::GetPathRoot($full)) '$Recycle.Bin') $sid

    $entries = @(Find-VacateTrashWindowsEntry -SidFolder $sidFolder -OriginalFullPath $full)
    if ($entries.Count -eq 0) {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText 'not found in the Recycle Bin')
    }
    $pick = $entries[0]
    if (-not [string]::IsNullOrEmpty($TrashLocation)) {
        $wanted = $TrashLocation.TrimEnd([char[]]@('\', '/'))
        foreach ($candidate in $entries) {
            if ([string]::Equals($candidate.trashPath, $wanted, [StringComparison]::OrdinalIgnoreCase)) {
                $pick = $candidate
                break
            }
        }
    }

    $source = [string]$pick.trashPath
    $wasDirectory = [IO.Directory]::Exists($source)
    if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText 'the original path already exists; refusing to overwrite it')
    }
    try {
        if ($wasDirectory) { [IO.Directory]::Move($source, $full) }
        else { [IO.File]::Move($source, $full) }
    }
    catch {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText ('could not move the item back from the Recycle Bin: ' + $_.Exception.Message))
    }

    $back = ($wasDirectory -and [IO.Directory]::Exists($full)) -or ((-not $wasDirectory) -and [IO.File]::Exists($full))
    if (-not $back) {
        return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $false -ErrorText 'the item is not at its original path after the restore')
    }
    return (ConvertTo-VacateTrashWindowsRestoreResult -Ok $true -ErrorText '')
}
