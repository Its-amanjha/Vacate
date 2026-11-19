# Models.ps1 - shared constants and object constructors.
# Owner: Claude. PowerShell 5.1 compatible. ASCII only.

$script:VacateToolName = 'vacate'
$script:VacateToolVersion = '0.1.0'
$script:VacateSchemaVersion = 1
$script:VacateDefaultMaxEntries = 5000
$script:VacateMaxMaxEntries = 50000
$script:VacateDefaultRuleTimeoutSeconds = 10
$script:VacateDefaultBudgetSeconds = 120
$script:VacateSampleCap = 3

$script:VacatePlatforms = @('windows', 'macos', 'linux')

$script:VacateCategories = @(
    'browsers', 'credentials', 'developer-secrets', 'network', 'activity',
    'personal-files', 'cloud-sync', 'messaging', 'email', 'wallets',
    'installed-programs', 'user-profiles', 'disk-encryption', 'system-traces',
    'autostart', 'containers-vms', 'games-licenses', 'ai-assistants'
)

# Ascending order. Index is the rank.
$script:VacateSensitivities = @('low', 'medium', 'high', 'critical')

$script:VacateLocatorKinds = @('path', 'registry', 'wmi', 'installed-program', 'system-query')

$script:VacateWindowsOnlyKinds = @('registry', 'wmi', 'installed-program')

$script:VacateMeasures = @('exists', 'sizeBytes', 'lastWriteTime', 'itemCount', 'valueCount', 'subkeyCount', 'properties')

$script:VacateSkipReasons = @('requires-elevation', 'budget', 'permission', 'unavailable', 'timeout')

$script:VacateSystemQueryNames = @('filevault-status', 'block-devices', 'mounts')

$script:VacateSystemQueryPlatforms = @{
    'filevault-status' = 'macos'
    'block-devices'    = 'linux'
    'mounts'           = 'linux'
}

# Root tokens defined per platform (SPEC "Platform roots").
$script:VacateRootTokens = @{
    windows = @('HOME', 'USERS', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMDATA', 'SYSTEMDRIVE')
    macos   = @('HOME', 'USERS', 'LIBRARY', 'APPLICATIONS', 'SYSTEM')
    linux   = @('HOME', 'USERS', 'APPLICATIONS', 'SYSTEM', 'XDG_CONFIG', 'XDG_DATA', 'XDG_STATE', 'ETC', 'VAR')
}

function Get-VacateSensitivityRank {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Sensitivity)
    $rank = [array]::IndexOf($script:VacateSensitivities, $Sensitivity)
    if ($rank -lt 0) { throw "Unknown sensitivity '$Sensitivity'." }
    return $rank
}

function ConvertTo-VacateIsoTime {
    # Returns an ISO-8601 UTC string with second precision, or $null.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $dt = [datetime]$Value
    if ($dt.Kind -eq [DateTimeKind]::Local) { $dt = $dt.ToUniversalTime() }
    elseif ($dt.Kind -eq [DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
    return $dt.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-VacateJson {
    # ConvertFrom-Json that behaves the same on 5.1 and 7: PowerShell 7 turns ISO date strings into
    # [datetime], which would change report text on a round trip. Every [datetime] is turned back
    # into the ISO-8601 UTC string the report uses (DECISIONS D26).
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    $obj = $Json | ConvertFrom-Json
    return (ConvertTo-VacateDateString -Value $obj)
}

function ConvertTo-VacateDateString {
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return (ConvertTo-VacateIsoTime $Value) }
    if ($Value -is [pscustomobject]) {
        foreach ($p in @($Value.PSObject.Properties)) { $p.Value = ConvertTo-VacateDateString -Value $p.Value }
        return $Value
    }
    if ($Value -is [array]) {
        for ($i = 0; $i -lt $Value.Length; $i++) { $Value[$i] = ConvertTo-VacateDateString -Value $Value[$i] }
        return , $Value
    }
    return $Value
}

function New-VacateTrace {
    # Builds a trace with the fixed property order from SPEC "Trace".
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$Resolved,
        [bool]$Exists = $true,
        [AllowNull()][Nullable[long]]$SizeBytes = $null,
        [AllowNull()][Nullable[long]]$ItemCount = $null,
        [AllowNull()][object]$LastWriteTime = $null,
        [string[]]$Samples = @(),
        [bool]$Truncated = $false,
        [AllowNull()][object]$Properties = $null,
        [AllowNull()][string]$ErrorMessage = $null
    )
    if ([string]::IsNullOrWhiteSpace($Resolved)) { throw 'A trace needs a concrete locator.' }

    $cap = @($Samples | Select-Object -First $script:VacateSampleCap)
    $confidence = 'unverified'
    if ($Rule.verified -eq $true) { $confidence = 'verified' }

    $trace = [ordered]@{
        ruleId            = [string]$Rule.id
        platform          = $Platform
        category          = [string]$Rule.category
        title             = [string]$Rule.title
        sensitivity       = [string]$Rule.sensitivity
        locator           = [ordered]@{ kind = [string]$Rule.locator.kind; resolved = $Resolved }
        exists            = $Exists
        sizeBytes         = $SizeBytes
        itemCount         = $ItemCount
        lastWriteTime     = (ConvertTo-VacateIsoTime $LastWriteTime)
        samples           = $cap
        truncated         = $Truncated
        confidence        = $confidence
        requiresElevation = [bool]$Rule.requiresElevation
        error             = $ErrorMessage
    }
    if ($null -ne $Properties) { $trace['properties'] = $Properties }
    return [pscustomobject]$trace
}

function New-VacateSkip {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$Reason,
        [AllowNull()][string]$Detail = $null
    )
    if ($script:VacateSkipReasons -notcontains $Reason) { throw "Unknown skip reason '$Reason'." }
    return [pscustomobject][ordered]@{ ruleId = $RuleId; reason = $Reason; detail = $Detail }
}

function New-VacateError {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Type
    )
    return [pscustomobject][ordered]@{ ruleId = $RuleId; message = $Message; type = $Type }
}
