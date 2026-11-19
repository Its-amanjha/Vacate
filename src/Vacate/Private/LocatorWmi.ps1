# LocatorWmi.ps1 - WMI/CIM locator executor and the production CIM runner.
# PowerShell 5.1 compatible. ASCII only.
#
# Read-only by construction: the only CIM command in the module is Get-CimInstance with an
# explicit namespace, class and property list. No method is invoked, nothing is created,
# changed or removed (SPEC non-negotiable 8, SPEC "System queries").

function New-VacateCimRunner {
    # The production scriptblock for $Context.Cim. Read-only query of named properties only.
    [CmdletBinding()]
    [OutputType([scriptblock])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a read-only query scriptblock; changes no state.')]
    param()

    return {
        param([string]$Namespace, [string]$ClassName, [string[]]$Property)
        return (Get-CimInstance -Namespace $Namespace -ClassName $ClassName -Property $Property -ErrorAction Stop)
    }
}

function Invoke-VacateWmiLocator {
    # one trace per returned instance, properties limited to the rule's named list.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][datetime]$Deadline
    )

    if ([datetime]::UtcNow -ge $Deadline) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'timeout' -Detail 'deadline reached before the WMI locator ran'))
    }

    $cim = Get-VacatePropertyValue -InputObject $Context -Name 'Cim'
    if ($null -eq $cim) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail 'no CIM provider on this platform'))
    }

    $locator = Get-VacatePropertyValue -InputObject $Rule -Name 'locator'
    $namespace = [string](Get-VacatePropertyValue -InputObject $locator -Name 'namespace')
    $className = [string](Get-VacatePropertyValue -InputObject $locator -Name 'className')
    $names = New-Object System.Collections.ArrayList
    foreach ($rawName in @(Get-VacatePropertyValue -InputObject $locator -Name 'properties')) {
        if ($null -eq $rawName) { continue }
        $name = [string]$rawName
        if ($name.Trim().Length -eq 0) { continue }
        [void]$names.Add($name.Trim())
    }
    if ($names.Count -eq 0) {
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message 'wmi locator names no properties' -Type 'InvalidRule'))
    }

    $instances = @()
    try {
        $instances = @(& $cim $namespace $className ([string[]]$names.ToArray()))
    }
    catch {
        $failure = Get-VacateLocatorFailure -ErrorRecord $_
        if ($failure.Kind -eq 'permission') {
            return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'permission' -Detail ("cannot query {0}:{1}" -f $namespace, $className)))
        }
        if ($failure.Kind -eq 'unavailable') {
            return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail ("{0}:{1} is not available" -f $namespace, $className)))
        }
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message $failure.Message -Type $failure.Type))
    }

    $platformName = Get-VacateContextPlatformName -Context $Context
    $traces = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($instance in $instances) {
        if ([datetime]::UtcNow -ge $Deadline) {
            return (New-VacateLocatorResult -Traces $traces.ToArray() -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'timeout' -Detail 'deadline reached while recording WMI instances'))
        }
        if ($null -eq $instance) { continue }

        # Only the rule's own property names are kept; nothing else on the instance is read.
        $properties = [ordered]@{}
        foreach ($name in $names) {
            $value = Get-VacatePropertyValue -InputObject $instance -Name $name
            if ($null -eq $value) { $properties[$name] = $null }
            elseif ($value -is [array]) { $properties[$name] = (($value | ForEach-Object { [string]$_ }) -join ', ') }
            else { $properties[$name] = [string]$value }
        }

        $resolved = ("{0}:{1}[{2}]" -f $namespace, $className, $index)
        $trace = New-VacateTrace -Rule $Rule -Platform $platformName -Resolved $resolved `
            -SizeBytes $null -ItemCount ([int64]1) -Properties $properties
        [void]$traces.Add($trace)
        $index = $index + 1
    }

    return (New-VacateLocatorResult -Traces $traces.ToArray())
}
