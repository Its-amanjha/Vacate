# LocatorRegistry.ps1 - registry locator executor, plus the helpers every locator shares.
# PowerShell 5.1 compatible. ASCII only.
#
# Executors never read environment variables, never touch disk except through the context
# providers, never write anything, and never throw for an expected condition: a missing key or
# a denied key comes back as a skip.

function New-VacateLocatorResult {
    # The result every locator executor returns. Shared with LocatorWmi, LocatorInstalledProgram,
    # LocatorSystemQuery and the path locator.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory result object; changes no state.')]
    param(
        [AllowEmptyCollection()][object[]]$Traces = @(),
        [AllowEmptyCollection()][object[]]$Skips = @(),
        [AllowEmptyCollection()][object[]]$Errors = @(),
        [AllowEmptyCollection()][object[]]$Programs = @()
    )

    return [pscustomobject][ordered]@{
        Traces   = @($Traces)
        Skips    = @($Skips)
        Errors   = @($Errors)
        Programs = @($Programs)
    }
}

function Get-VacatePropertyValue {
    # Reads one member of an object, hashtable, dictionary or CIM instance.
    # Missing members give $null instead of a strict-mode error.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $null }
        return $InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-VacateContextPlatformName {
    # The platform name from a scan context, or '' when it is missing.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Context)

    $platform = Get-VacatePropertyValue -InputObject $Context -Name 'Platform'
    $name = Get-VacatePropertyValue -InputObject $platform -Name 'Name'
    if ($null -eq $name) { return '' }
    return [string]$name
}

function Get-VacateLocatorFailure {
    # Classifies an error raised by a provider or a CIM call, without assuming one exception type
    # (CimException is not available on Linux, so the message is checked as well).
    # Kind: 'permission', 'unavailable' or 'error'.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()][object]$ErrorRecord)

    $type = 'Error'
    $message = 'locator failed'
    if ($null -ne $ErrorRecord) {
        $exception = Get-VacatePropertyValue -InputObject $ErrorRecord -Name 'Exception'
        if ($null -eq $exception) { $exception = $ErrorRecord }
        # A provider method or CIM cmdlet wraps the real failure; report the inner cause.
        $chain = New-Object System.Collections.ArrayList
        $current = $exception
        while ($null -ne $current -and $chain.Count -lt 4) {
            [void]$chain.Add($current)
            $current = Get-VacatePropertyValue -InputObject $current -Name 'InnerException'
        }
        $inner = $chain[$chain.Count - 1]
        $type = $inner.GetType().Name
        $message = [string](Get-VacatePropertyValue -InputObject $inner -Name 'Message')
        if ([string]::IsNullOrWhiteSpace($message)) {
            foreach ($candidate in $chain) {
                $candidateMessage = [string](Get-VacatePropertyValue -InputObject $candidate -Name 'Message')
                if (-not [string]::IsNullOrWhiteSpace($candidateMessage)) { $message = $candidateMessage; break }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'locator failed' }
    if ($message.Length -gt 200) { $message = $message.Substring(0, 200) }

    $kind = 'error'
    $denied = '(?i)unauthorized|requires elevation|insufficient privilege|access.*denied|\bdenied\b'
    $missing = '(?i)invalid class|invalid namespace|not found|does not exist|no such|cannot find|not supported|invalid object'
    if ($type -eq 'UnauthorizedAccessException' -or $type -eq 'SecurityException' -or $type -eq 'AccessViolationException') {
        $kind = 'permission'
    }
    elseif ($message -match $denied) { $kind = 'permission' }
    elseif ($message -match $missing) { $kind = 'unavailable' }

    return [pscustomobject][ordered]@{
        Kind    = $kind
        Type    = $type
        Message = $message
    }
}

function Invoke-VacateRegistryLocator {
    # a present key gives one trace with value/subkey counts, a missing key gives
    # nothing, and a denied key gives a permission skip.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][datetime]$Deadline
    )

    if ([datetime]::UtcNow -ge $Deadline) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'timeout' -Detail 'deadline reached before the registry locator ran'))
    }

    $registry = Get-VacatePropertyValue -InputObject $Context -Name 'Registry'
    if ($null -eq $registry) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail 'no registry provider on this platform'))
    }

    $locator = Get-VacatePropertyValue -InputObject $Rule -Name 'locator'
    $hive = [string](Get-VacatePropertyValue -InputObject $locator -Name 'hive')
    $keyPath = [string](Get-VacatePropertyValue -InputObject $locator -Name 'key')
    $view = [string](Get-VacatePropertyValue -InputObject $locator -Name 'view')
    if ([string]::IsNullOrWhiteSpace($view)) { $view = 'Default' }

    $key = $null
    try {
        $key = $registry.GetKey($hive, $keyPath, $view)
    }
    catch {
        $failure = Get-VacateLocatorFailure -ErrorRecord $_
        if ($failure.Kind -eq 'permission') {
            return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'permission' -Detail ("cannot read {0}\{1}" -f $hive, $keyPath)))
        }
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message $failure.Message -Type $failure.Type))
    }

    if ($null -eq $key) { return (New-VacateLocatorResult) }

    $valueCount = 0
    $subKeyCount = 0
    $rawValueCount = Get-VacatePropertyValue -InputObject $key -Name 'ValueCount'
    $rawSubKeyCount = Get-VacatePropertyValue -InputObject $key -Name 'SubKeyCount'
    if ($null -ne $rawValueCount) { $valueCount = [int]$rawValueCount }
    if ($null -ne $rawSubKeyCount) { $subKeyCount = [int]$rawSubKeyCount }

    $resolved = $hive + '\' + $keyPath
    if ($view -eq 'Registry32') { $resolved = $resolved + ' (32-bit)' }

    # D3: no last-write time, no size. Value data is never read, only counted.
    $trace = New-VacateTrace -Rule $Rule -Platform (Get-VacateContextPlatformName -Context $Context) `
        -Resolved $resolved -SizeBytes $null -ItemCount ([int64]($valueCount + $subKeyCount)) `
        -Properties ([ordered]@{ valueCount = $valueCount; subkeyCount = $subKeyCount })

    return (New-VacateLocatorResult -Traces @($trace))
}
