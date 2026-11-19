# Platform.ps1 - platform detection, environment snapshot, profile dispatch, elevation.
# PowerShell 5.1 compatible. ASCII only.
#
# This file holds the only code in the module that is allowed to read the process
# environment. Everything else receives an -Environment hashtable, so tests can point
# the profiles at a fake environment.

function Get-VacatePlatform {
    # Returns 'windows', 'macos' or 'linux'. Never guesses: anything else throws.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Windows PowerShell 5.1 has no $IsWindows/$IsMacOS/$IsLinux and only runs on Windows.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'windows' }

    # Strict mode is on, so probe the automatic variables instead of reading them.
    $detectedWindows = Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue
    $detectedMacOS = Get-Variable -Name 'IsMacOS' -ValueOnly -ErrorAction SilentlyContinue
    $detectedLinux = Get-Variable -Name 'IsLinux' -ValueOnly -ErrorAction SilentlyContinue

    if ($detectedWindows -eq $true) { return 'windows' }
    if ($detectedMacOS -eq $true) { return 'macos' }
    if ($detectedLinux -eq $true) { return 'linux' }

    throw 'platform: unsupported'
}

function Get-VacateEnvironmentSnapshot {
    # The only reader of the process environment. Returns the variables the platform
    # profiles need, and nothing else. Missing and empty variables are left out.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $names = @(
        'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMDATA', 'SystemDrive', 'USERNAME',
        'HOME', 'USER', 'LOGNAME',
        'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME'
    )

    $snapshot = @{}
    foreach ($name in $names) {
        $item = Get-Item -LiteralPath ('env:' + $name) -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        $value = [string]$item.Value
        if ($value.Length -eq 0) { continue }
        $snapshot[$name] = $value
    }
    return $snapshot
}

function Get-VacatePlatformProfile {
    # Dispatches to the per-platform profile builder.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )

    switch ($Platform) {
        'windows' { return (Get-VacateWindowsProfile -Environment $Environment) }
        'macos' { return (Get-VacateMacOSProfile -Environment $Environment) }
        'linux' { return (Get-VacateLinuxProfile -Environment $Environment) }
        default { throw "platform: unsupported '$Platform'" }
    }
}

function Test-VacateElevated {
    # True when the current session is already elevated. Never elevates anything.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Platform)

    if ($script:VacatePlatforms -notcontains $Platform) { throw "platform: unsupported '$Platform'" }

    if ($Platform -eq 'windows') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object -TypeName 'Security.Principal.WindowsPrincipal' -ArgumentList $identity
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # DECISIONS D13: .NET resolves this from the effective uid, no binary needed.
    return ([Environment]::UserName -eq 'root')
}

function Get-VacateEnvironmentValue {
    # Reads one key from an injected environment snapshot. Missing or blank -> $null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Environment.Contains($Name)) { return $null }
    $raw = $Environment[$Name]
    if ($null -eq $raw) { return $null }
    $value = [string]$raw
    if ($value.Trim().Length -eq 0) { return $null }
    return $value
}

function Get-VacateEnvironmentUserName {
    # First non-empty name from the snapshot, in the given order. Empty string if none.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][string[]]$Name
    )

    foreach ($candidate in $Name) {
        $value = Get-VacateEnvironmentValue -Environment $Environment -Name $candidate
        if ($null -ne $value) { return $value }
    }
    return ''
}

function ConvertTo-VacateRootPath {
    # Normalizes a root path: one separator style, no repeated separators, and no
    # trailing separator except for a bare root ('/' or 'C:\').
    # Pure string work; touches no filesystem.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][char]$Separator
    )

    $text = $Path.Trim()
    if ($text.Length -eq 0) { throw 'platform: root path is empty' }

    $separatorText = [string]$Separator
    $otherText = '/'
    if ($Separator -eq [char]'/') { $otherText = '\' }
    $text = $text.Replace($otherText, $separatorText)

    # Keep a UNC prefix (\\server\share) intact, collapse repeats everywhere else.
    $uncPrefix = $separatorText + $separatorText
    $prefix = ''
    if ($text.Length -ge 2 -and $text.Substring(0, 2) -eq $uncPrefix) {
        $prefix = $uncPrefix
        $text = $text.Substring(2)
    }
    $repeats = [regex]::Escape($separatorText) + '{2,}'
    $text = [regex]::Replace($text, $repeats, $separatorText)
    $text = $prefix + $text

    $trimmed = $text.TrimEnd([char[]]@($Separator))
    if ($trimmed.Length -eq 0) { return $separatorText }
    if ($Separator -eq [char]'\' -and $trimmed.Length -eq 2 -and $trimmed[1] -eq [char]':') {
        return ($trimmed + $separatorText)
    }
    return $trimmed
}

function Join-VacateRootPath {
    # Joins a normalized base with a relative child, never doubling the separator.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Base,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Child,
        [Parameter(Mandatory)][char]$Separator
    )

    $separatorText = [string]$Separator
    $suffix = $Child
    while ($suffix.Length -gt 0 -and ($suffix[0] -eq [char]'/' -or $suffix[0] -eq [char]'\')) {
        $suffix = $suffix.Substring(1)
    }
    if ($suffix.Length -eq 0) { return $Base }
    if ($Base.EndsWith($separatorText, [StringComparison]::Ordinal)) { return ($Base + $suffix) }
    return ($Base + $separatorText + $suffix)
}

function Test-VacateUnixAbsolutePath {
    # XDG Base Directory spec: only an absolute $XDG_*_HOME value is honoured.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ($Path.Length -eq 0) { return $false }
    return $Path.StartsWith('/', [StringComparison]::Ordinal)
}
