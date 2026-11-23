# SystemQueries.ps1 - the only external binaries vacate may run, and their parsers.
# PowerShell 5.1 compatible. ASCII only.
#
# Data is hard-coded here: a named query maps to one absolute binary and a fixed argument
# array. Nothing comes from rule files or from the user, there is no shell, no elevation
# and no credential prompt (SPEC non-negotiable 8).

$script:VacateSystemQueryTimeoutMs = 5000

function Get-VacateSystemQueryTable {
    # The allow-list. Fresh objects on every call so a caller cannot mutate shared state.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        [pscustomobject][ordered]@{
            Name      = 'filevault-status'
            Platform  = 'macos'
            Binary    = '/usr/bin/fdesetup'
            Arguments = @('status')
        },
        [pscustomobject][ordered]@{
            Name      = 'block-devices'
            Platform  = 'linux'
            Binary    = '/usr/bin/lsblk'
            Arguments = @('--json', '-o', 'NAME,TYPE,FSTYPE,MOUNTPOINT')
        },
        [pscustomobject][ordered]@{
            Name      = 'mounts'
            Platform  = 'linux'
            Binary    = '/usr/bin/findmnt'
            Arguments = @('--json', '-o', 'TARGET,SOURCE,FSTYPE')
        },
        # P4 system-disk identification (D54-D57): same read-only binary, more columns.
        # -b gives exact byte counts instead of rounded human-readable sizes.
        [pscustomobject][ordered]@{
            Name      = 'block-devices-detail'
            Platform  = 'linux'
            Binary    = '/usr/bin/lsblk'
            Arguments = @('--json', '-b', '-o', 'NAME,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,SIZE,PKNAME,TRAN')
        },
        # diskutil is read-only with 'info -plist /'; it never performs an erase (D57).
        [pscustomobject][ordered]@{
            Name      = 'disk-info'
            Platform  = 'macos'
            Binary    = '/usr/sbin/diskutil'
            Arguments = @('info', '-plist', '/')
        }
    )
}

function Invoke-VacateSystemQuery {
    # Runs one allow-listed query and returns its parsed value, never raw output.
    # -Platform accepts a platform name or a profile object.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][object]$Platform,
        [scriptblock]$Runner
    )

    $query = $null
    foreach ($entry in (Get-VacateSystemQueryTable)) {
        if ($entry.Name -eq $Name) { $query = $entry; break }
    }
    if ($null -eq $query) { throw "system-query: unknown query '$Name'" }

    $platformName = Get-VacateSystemQueryPlatformName -Platform $Platform
    if ($platformName -ne $query.Platform) {
        return [pscustomobject][ordered]@{
            Name    = $query.Name
            Status  = 'not-applicable'
            Value   = $null
            Message = ("query '{0}' is only available on '{1}'" -f $query.Name, $query.Platform)
        }
    }

    $arguments = [string[]]@($query.Arguments)
    $timeoutMs = $script:VacateSystemQueryTimeoutMs
    $useDefaultRunner = ($null -eq $Runner)

    # The existence gate protects the default runner: it may not try to launch a binary
    # that is not installed. An injected -Runner owns its own execution, so tests can
    # exercise the ok/timeout/error paths on any machine.
    if ($useDefaultRunner -and -not [IO.File]::Exists($query.Binary)) {
        return [pscustomobject][ordered]@{
            Name    = $query.Name
            Status  = 'unavailable'
            Value   = $null
            Message = ("binary '{0}' not found" -f $query.Binary)
        }
    }

    $run = $null
    try {
        if ($useDefaultRunner) {
            $run = Invoke-VacateSystemQueryProcess -Binary $query.Binary -Arguments $arguments -TimeoutMs $timeoutMs
        }
        else {
            $run = & $Runner $query.Binary $arguments $timeoutMs
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Name    = $query.Name
            Status  = 'error'
            Value   = $null
            Message = ("query '{0}': {1}" -f $query.Name, $_.Exception.Message)
        }
    }

    $timedOut = $false
    $exitCode = 0
    $stdout = ''
    if ($null -ne $run) {
        $timedOut = [bool]$run['TimedOut']
        if ($null -ne $run['ExitCode']) { $exitCode = [int]$run['ExitCode'] }
        if ($null -ne $run['StdOut']) { $stdout = [string]$run['StdOut'] }
    }

    if ($timedOut) {
        return [pscustomobject][ordered]@{
            Name    = $query.Name
            Status  = 'timeout'
            Value   = $null
            Message = ("query '{0}' timed out after {1} ms" -f $query.Name, $timeoutMs)
        }
    }

    if ($exitCode -ne 0) {
        return [pscustomobject][ordered]@{
            Name    = $query.Name
            Status  = 'error'
            Value   = $null
            Message = ("query '{0}' exited with code {1}" -f $query.Name, $exitCode)
        }
    }

    $value = $null
    try {
        switch ($query.Name) {
            'block-devices' { $value = ConvertFrom-VacateLsblkJson -Text $stdout }
            'block-devices-detail' { $value = ConvertFrom-VacateLsblkJson -Text $stdout }
            'mounts' { $value = ConvertFrom-VacateFindmntJson -Text $stdout }
            'filevault-status' { $value = ConvertFrom-VacateFdesetupStatus -Text $stdout }
            'disk-info' { $value = ConvertFrom-VacateDiskInfoPlist -Text $stdout }
            default { throw ("no parser for '{0}'" -f $query.Name) }
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Name    = $query.Name
            Status  = 'error'
            Value   = $null
            Message = ("query '{0}': could not parse output ({1})" -f $query.Name, $_.Exception.Message)
        }
    }

    return [pscustomobject][ordered]@{
        Name    = $query.Name
        Status  = 'ok'
        Value   = $value
        Message = $null
    }
}

function Get-VacateSystemQueryPlatformName {
    # Accepts 'linux' or a profile object with a Name property.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Platform)

    if ($null -eq $Platform) { throw 'system-query: platform is required' }
    if ($Platform -is [string]) { return [string]$Platform }
    $property = $Platform.PSObject.Properties['Name']
    if ($null -eq $property) { throw 'system-query: platform must be a name or a profile object' }
    return [string]$property.Value
}

function Invoke-VacateSystemQueryProcess {
    # Default runner: in-process Process, no shell, fixed arguments, hard timeout.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Binary,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    $startInfo = New-Object -TypeName 'System.Diagnostics.ProcessStartInfo'
    $startInfo.FileName = $Binary
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        # PowerShell 7: each fixed argument is passed verbatim.
        foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    }
    else {
        # Windows PowerShell 5.1: one command line, every argument quoted by us.
        $quoted = @()
        foreach ($argument in $Arguments) { $quoted += ('"' + $argument.Replace('"', '\"') + '"') }
        $startInfo.Arguments = ($quoted -join ' ')
    }

    $stdout = ''
    $timedOut = $false
    $exitCode = 0
    $process = New-Object -TypeName 'System.Diagnostics.Process'
    try {
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if ($process.WaitForExit($TimeoutMs)) {
            $exitCode = $process.ExitCode
            if ($stdoutTask.Wait(1000) -and -not $stdoutTask.IsFaulted) {
                $stdout = [string]$stdoutTask.Result
            }
            [void]$stderrTask.Wait(1000)
        }
        else {
            $timedOut = $true
            try { [void]$process.Kill() }
            catch { Write-Verbose ('system-query: could not stop ' + $Binary) }
        }
    }
    finally {
        $process.Dispose()
    }

    return @{ ExitCode = $exitCode; StdOut = $stdout; TimedOut = $timedOut }
}

function ConvertFrom-VacateLsblkJson {
    # lsblk --json -o NAME,TYPE,FSTYPE,MOUNTPOINT. Nested children are flattened, each
    # entry naming its parent.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'system-query: empty output' }
    $parsed = ConvertFrom-Json -InputObject $Text
    if ($null -eq $parsed) { return @() }
    if ($null -eq $parsed.PSObject.Properties['blockdevices']) { return @() }

    $list = New-Object System.Collections.ArrayList
    foreach ($device in @($parsed.blockdevices)) {
        Add-VacateBlockDevice -Device $device -Parent $null -List $list
    }
    return $list.ToArray()
}

function Add-VacateBlockDevice {
    # Depth-first append: the device, then its children.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Device,
        [AllowNull()][string]$Parent = $null,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$List
    )

    if ($null -eq $Device) { return }
    $name = Get-VacateJsonField -InputObject $Device -Name 'name'
    [void]$List.Add([pscustomobject][ordered]@{
            name       = $name
            type       = (Get-VacateJsonField -InputObject $Device -Name 'type')
            fstype     = (Get-VacateJsonField -InputObject $Device -Name 'fstype')
            mountpoint = (Get-VacateJsonField -InputObject $Device -Name 'mountpoint')
            parent     = $Parent
            # Extra columns used by the P4 system-disk query (D54-D57). Missing fields
            # stay null; the disk reader reports a problem instead of guessing.
            model      = (Get-VacateJsonField -InputObject $Device -Name 'model')
            serial     = (Get-VacateJsonField -InputObject $Device -Name 'serial')
            size       = (Get-VacateJsonField -InputObject $Device -Name 'size')
            pkname     = (Get-VacateJsonField -InputObject $Device -Name 'pkname')
            tran       = (Get-VacateJsonField -InputObject $Device -Name 'tran')
        })

    if ($null -eq $Device.PSObject.Properties['children']) { return }
    if ($null -eq $Device.children) { return }
    foreach ($child in @($Device.children)) {
        Add-VacateBlockDevice -Device $child -Parent $name -List $List
    }
}

function ConvertFrom-VacateFindmntJson {
    # findmnt --json -o TARGET,SOURCE,FSTYPE. Nested children are flattened.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'system-query: empty output' }
    $parsed = ConvertFrom-Json -InputObject $Text
    if ($null -eq $parsed) { return @() }
    if ($null -eq $parsed.PSObject.Properties['filesystems']) { return @() }

    $list = New-Object System.Collections.ArrayList
    foreach ($entry in @($parsed.filesystems)) {
        Add-VacateMountEntry -Entry $entry -List $list
    }
    return $list.ToArray()
}

function Add-VacateMountEntry {
    # Depth-first append: the mount, then the mounts nested under it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Entry,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$List
    )

    if ($null -eq $Entry) { return }
    [void]$List.Add([pscustomobject][ordered]@{
            target = (Get-VacateJsonField -InputObject $Entry -Name 'target')
            source = (Get-VacateJsonField -InputObject $Entry -Name 'source')
            fstype = (Get-VacateJsonField -InputObject $Entry -Name 'fstype')
        })

    if ($null -eq $Entry.PSObject.Properties['children']) { return }
    if ($null -eq $Entry.children) { return }
    foreach ($child in @($Entry.children)) {
        Add-VacateMountEntry -Entry $child -List $List
    }
}

function ConvertFrom-VacateFdesetupStatus {
    # fdesetup status prints 'FileVault is On.' or 'FileVault is Off.'. Anything else is
    # reported as unknown, never guessed.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $enabled = $null
    $state = 'Unknown'
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $match = [regex]::Match($Text, 'FileVault is (On|Off)\.')
        if ($match.Success) {
            if ($match.Groups[1].Value -eq 'On') {
                $enabled = $true
                $state = 'On'
            }
            else {
                $enabled = $false
                $state = 'Off'
            }
        }
    }

    return [pscustomobject][ordered]@{
        enabled = $enabled
        state   = $state
    }
}

function ConvertFrom-VacateDiskInfoPlist {
    # Parses only the flat scalar keys vacate needs from 'diskutil info -plist /'.
    # Nested dicts and arrays are ignored and raw output is never returned (D57).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'system-query: empty output' }

    return [pscustomobject][ordered]@{
        name       = (Get-VacatePlistScalar -Text $Text -Key @('DeviceIdentifier', 'Device Identifier'))
        model      = (Get-VacatePlistScalar -Text $Text -Key @('DeviceModel', 'Device Model'))
        serial     = (Get-VacatePlistScalar -Text $Text -Key @('SerialNumber', 'Serial Number'))
        sizeBytes  = (Get-VacatePlistInteger -Text $Text -Key @('TotalSize', 'Total Size', 'DiskSize', 'Disk Size'))
        busType    = (Get-VacatePlistScalar -Text $Text -Key @('BusType', 'Bus Type'))
        mountPoint = (Get-VacatePlistScalar -Text $Text -Key @('MountPoint', 'Mount Point'))
    }
}

function Get-VacatePlistScalar {
    # First non-empty <string> value for any of the given keys, or $null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Key
    )

    foreach ($keyName in $Key) {
        $pattern = '<key>\s*' + [regex]::Escape($keyName) + '\s*</key>\s*<string>(?<v>[\s\S]*?)</string>'
        $match = [regex]::Match($Text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $value = ([string]$match.Groups['v'].Value).Trim()
            if ($value.Length -gt 0) { return $value }
        }
    }
    return $null
}

function Get-VacatePlistInteger {
    # First integer value for any of the given keys, or $null when none parses.
    [CmdletBinding()]
    [OutputType([Nullable[long]])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Key
    )

    foreach ($keyName in $Key) {
        $pattern = '<key>\s*' + [regex]::Escape($keyName) + '\s*</key>\s*<integer>\s*(?<v>-?\d+)\s*</integer>'
        $match = [regex]::Match($Text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $parsed = [int64]0
            if ([int64]::TryParse($match.Groups['v'].Value, [ref]$parsed)) { return $parsed }
        }
    }
    return $null
}

function Get-VacateJsonField {
    # Reads one field from a ConvertFrom-Json object. Missing and null both give $null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($null -eq $property.Value) { return $null }
    return [string]$property.Value
}
