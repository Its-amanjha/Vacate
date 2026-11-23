# LuksLoop.ps1 - a disposable LUKS container inside a loop FILE, for the Phase 4 erase test.
# PowerShell 5.1 compatible. ASCII only.
#
# D57: an erase is unrecoverable, so development and tests only ever touch a disposable target.
# This file is the only place that makes one: a 64 MB file under /tmp, attached with
# `losetup --find --show`, formatted with `cryptsetup luksFormat --batch-mode` and a key file
# written next to it. Every command is argv-style (no shell, no interpolation) and every
# command is pointed at a device this process just created: the loop path must match
# /dev/loopN and the device's BACK-FILE must be the file made here, or nothing runs.
#
# On Windows every function that needs a device throws; the integration test skips itself.

Set-StrictMode -Version Latest

function Get-VacateLuksTool {
    # Runs one named program with a fixed argument array and returns its exit code plus the
    # combined output lines. No shell, no string concatenation of arguments, no user input.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $exitCode = -1
    try {
        foreach ($line in @(& $Name @ArgumentList 2>&1)) {
            $lines.Add([string]$line)
        }
        $exitCode = $LASTEXITCODE
    }
    catch {
        $lines.Add([string]$_.Exception.Message)
        $exitCode = -1
    }

    return [pscustomobject][ordered]@{
        exitCode = $exitCode
        output   = [string[]]$lines.ToArray()
    }
}

function Test-VacateLuksLinuxHost {
    # True on a Linux host: '/' separator and the /proc the Linux kernel provides.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ([IO.Path]::DirectorySeparatorChar -ne [char]'/') { return $false }
    return (Test-Path -LiteralPath '/proc/self/status' -PathType Leaf)
}

function Test-VacateLuksLoopPrerequisite {
    # Whether this host can host a disposable LUKS loop file, and why not when it cannot.
    # Linux plus root plus cryptsetup plus losetup plus a loop driver (D57).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not (Test-VacateLuksLinuxHost)) {
        return [pscustomobject][ordered]@{
            available = $false
            reason    = 'a disposable LUKS loop file needs a Linux host (D57)'
        }
    }
    if ([Environment]::UserName -ne 'root') {
        return [pscustomobject][ordered]@{
            available = $false
            reason    = 'losetup and cryptsetup need root'
        }
    }
    foreach ($tool in @('losetup', 'cryptsetup')) {
        $found = Get-Command -Name $tool -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $found) {
            return [pscustomobject][ordered]@{
                available = $false
                reason    = ("{0} is not installed (apt-get install -y cryptsetup-bin)" -f $tool)
            }
        }
    }
    if (-not (Test-Path -LiteralPath '/dev/loop-control')) {
        return [pscustomobject][ordered]@{
            available = $false
            reason    = 'the kernel offers no loop devices (/dev/loop-control is missing)'
        }
    }

    return [pscustomobject][ordered]@{
        available = $true
        reason    = ''
    }
}

function Get-VacateLuksBackingFile {
    # The file a loop device is attached to, as losetup reports it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Loop
    )

    if ($Loop -notmatch '^/dev/loop[0-9]+$') {
        throw ("luks-loop: refusing to inspect a device that is not /dev/loopN: " + $Loop)
    }
    $result = Get-VacateLuksTool -Name 'losetup' -ArgumentList @('--noheadings', '--output', 'BACK-FILE', '--raw', $Loop)
    if ($result.exitCode -ne 0) {
        throw ("luks-loop: losetup could not report the backing file of {0}: {1}" -f $Loop, ($result.output -join ' '))
    }
    $backing = (@($result.output) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($backing)) {
        throw ("luks-loop: losetup reported no backing file for " + $Loop)
    }
    return $backing
}

function New-VacateLuksLoopContainer {
    # Creates the disposable container: a sparse file, a key file, a loop device and a
    # LUKS2 header with one key slot. Returns { file; loop; keyFile }. Always cleans up
    # after itself when a step fails, so a half-built container is never left behind.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a disposable loop file that only this call owns; cleanup is in Remove-VacateLuksLoopContainer (D57).')]
    param(
        [ValidateRange(16, 512)][int]$SizeMb = 64,
        [string]$TempRoot = '/tmp'
    )

    $prereq = Test-VacateLuksLoopPrerequisite
    if (-not $prereq.available) {
        throw ("luks-loop: cannot create a disposable container: " + $prereq.reason)
    }
    if (-not (Test-Path -LiteralPath $TempRoot -PathType Container)) {
        throw ("luks-loop: temp root is not a directory: " + $TempRoot)
    }

    # A unique name per call, so two runs can never touch each other's container.
    $token = [guid]::NewGuid().ToString('N')
    $file = Join-Path $TempRoot ('vacate-luks-' + $token + '.img')
    $keyFile = Join-Path $TempRoot ('vacate-luks-' + $token + '.key')

    # Sparse 64 MB backing file: enough for a LUKS2 header and a data segment.
    $stream = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.SetLength([int64]$SizeMb * 1MB)
    }
    finally {
        $stream.Dispose()
    }

    # Key file: 64 hex characters from the OS random source, never printed, deleted by cleanup.
    [IO.File]::WriteAllText($keyFile, ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')))

    $loop = $null
    try {
        $attach = Get-VacateLuksTool -Name 'losetup' -ArgumentList @('--find', '--show', $file)
        if ($attach.exitCode -ne 0) {
            throw ("luks-loop: losetup failed: " + ($attach.output -join ' '))
        }
        $loop = (@($attach.output) -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($loop)) {
            throw 'luks-loop: losetup returned no device'
        }
        # D57: only a loop device, and only one that backs the file made two lines ago.
        if ($loop -notmatch '^/dev/loop[0-9]+$') {
            throw ("luks-loop: refusing a device that is not /dev/loopN: " + $loop)
        }
        $backing = Get-VacateLuksBackingFile -Loop $loop
        if ($backing -cne $file) {
            throw ("luks-loop: refusing {0}: it backs {1}, not the file this call created ({2})" -f $loop, $backing, $file)
        }

        # pbkdf2 with few iterations keeps the disposable container fast to format; this key
        # protects nothing and dies with the file.
        $format = Get-VacateLuksTool -Name 'cryptsetup' -ArgumentList @(
            'luksFormat', '--batch-mode', '--type', 'luks2',
            '--pbkdf', 'pbkdf2', '--pbkdf-force-iterations', '1000',
            '--key-file', $keyFile, $loop
        )
        if ($format.exitCode -ne 0) {
            throw ("luks-loop: cryptsetup luksFormat failed: " + ($format.output -join ' '))
        }

        return [pscustomobject][ordered]@{
            file    = $file
            loop    = $loop
            keyFile = $keyFile
        }
    }
    catch {
        # Never leave a loop device attached to a half-built container.
        if ($null -ne $loop) {
            try {
                Remove-VacateLuksLoopContainer -Container ([pscustomobject][ordered]@{
                        file    = $file
                        loop    = $loop
                        keyFile = $keyFile
                    })
            }
            catch {
                $null = $_
            }
        }
        foreach ($leftover in @($file, $keyFile)) {
            if ([IO.File]::Exists($leftover)) {
                try { [IO.File]::Delete($leftover) } catch { $null = $_ }
            }
        }
        throw
    }
}

function Remove-VacateLuksLoopContainer {
    # Detaches the loop device and deletes the two temp files. Detaching is refused when the
    # device does not back the recorded file, and deleting is refused outside /tmp with the
    # generated name, so a mistake cannot reach anything but this container.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes only the disposable container this test created (D57).')]
    param(
        [Parameter(Mandatory)][AllowNull()][pscustomobject]$Container
    )

    if ($null -eq $Container) { return }

    $loop = ''
    $file = ''
    $keyFile = ''
    if ($null -ne $Container.PSObject.Properties['loop']) { $loop = [string]$Container.loop }
    if ($null -ne $Container.PSObject.Properties['file']) { $file = [string]$Container.file }
    if ($null -ne $Container.PSObject.Properties['keyFile']) { $keyFile = [string]$Container.keyFile }

    $problems = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrWhiteSpace($loop)) {
        if ($loop -notmatch '^/dev/loop[0-9]+$') {
            $problems.Add(("refusing to detach {0}: not a /dev/loopN device" -f $loop))
        }
        elseif ([string]::IsNullOrWhiteSpace($file)) {
            $problems.Add(("refusing to detach {0}: no backing file recorded" -f $loop))
        }
        else {
            $backing = ''
            try {
                $backing = Get-VacateLuksBackingFile -Loop $loop
            }
            catch {
                $backing = ''
            }
            if ($backing -cne $file) {
                $problems.Add(("refusing to detach {0}: it backs {1}, not {2}" -f $loop, $backing, $file))
            }
            else {
                $detach = Get-VacateLuksTool -Name 'losetup' -ArgumentList @('--detach', $loop)
                if ($detach.exitCode -ne 0) {
                    $problems.Add(("losetup --detach {0} failed: {1}" -f $loop, ($detach.output -join ' ')))
                }
            }
        }
    }

    foreach ($path in @($file, $keyFile)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not [IO.File]::Exists($path)) { continue }
        $name = [IO.Path]::GetFileName($path)
        $parent = [IO.Path]::GetDirectoryName($path)
        if ($name -notmatch '^vacate-luks-[0-9a-f]{32}\.(img|key)$') {
            $problems.Add(("refusing to delete {0}: not a container file name" -f $path))
            continue
        }
        if ($parent -ne '/tmp') {
            $problems.Add(("refusing to delete {0}: not under /tmp" -f $path))
            continue
        }
        try {
            [IO.File]::Delete($path)
        }
        catch {
            $problems.Add(("could not delete {0}: {1}" -f $path, $_.Exception.Message))
        }
    }

    if ($problems.Count -gt 0) {
        throw ('luks-loop: cleanup refused: ' + ($problems -join '; '))
    }
}

function Get-VacateLuksKeySlotNumber {
    # Key slot numbers cryptsetup luksDump reports for the device. Empty means no key slot,
    # which is the state a Linux key erase must leave behind (D54).
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)][string]$Device
    )

    if ($Device -notmatch '^/dev/loop[0-9]+$') {
        throw ("luks-loop: refusing to dump a device that is not /dev/loopN: " + $Device)
    }
    $dump = Get-VacateLuksTool -Name 'cryptsetup' -ArgumentList @('luksDump', $Device)
    if ($dump.exitCode -ne 0) {
        throw ("luks-loop: cryptsetup luksDump failed: " + ($dump.output -join ' '))
    }
    $text = ($dump.output -join "`n")

    $slots = New-Object 'System.Collections.Generic.List[int]'
    # LUKS2 prints one "  N: luks2" line per key slot under "Keyslots:".
    foreach ($match in [regex]::Matches($text, '(?m)^[ \t]+(\d+):[ \t]+luks2[ \t]*$')) {
        $number = [int]$match.Groups[1].Value
        if (-not $slots.Contains($number)) { $slots.Add($number) }
    }
    # LUKS1 prints "Key Slot N: ENABLED".
    foreach ($match in [regex]::Matches($text, '(?m)^Key Slot (\d+): ENABLED')) {
        $number = [int]$match.Groups[1].Value
        if (-not $slots.Contains($number)) { $slots.Add($number) }
    }

    return [int[]]$slots.ToArray()
}

function Test-VacateLuksKeyFile {
    # True when the key file opens the container. cryptsetup tests the passphrase without
    # mapping anything, so no device-mapper name and no mounted file system is involved.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Device,
        [Parameter(Mandatory)][string]$KeyFile
    )

    if ($Device -notmatch '^/dev/loop[0-9]+$') {
        throw ("luks-loop: refusing to open a device that is not /dev/loopN: " + $Device)
    }
    if (-not [IO.File]::Exists($KeyFile)) {
        throw ("luks-loop: key file is missing: " + $KeyFile)
    }
    $check = Get-VacateLuksTool -Name 'cryptsetup' -ArgumentList @(
        'open', '--test-passphrase', '--batch-mode', '--key-file', $KeyFile, $Device
    )
    return ($check.exitCode -eq 0)
}
