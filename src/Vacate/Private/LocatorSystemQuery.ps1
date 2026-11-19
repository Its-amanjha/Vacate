# LocatorSystemQuery.ps1 - system-query locator executor.
# Owner: Pi. PowerShell 5.1 compatible. ASCII only.
#
# The query name comes from the rule; the binary and arguments come from the allow-list in
# Private/SystemQueries.ps1, never from data. No shell, no elevation, no user input.

function Invoke-VacateSystemQueryLocator {
    # CONTRACTS 9: ok gives one trace carrying the parsed value; unavailable, timeout and
    # not-applicable give a skip; error gives an error entry. Raw output is never reported.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][datetime]$Deadline
    )

    if ([datetime]::UtcNow -ge $Deadline) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'timeout' -Detail 'deadline reached before the system-query locator ran'))
    }

    $runQuery = Get-VacatePropertyValue -InputObject $Context -Name 'SystemQuery'
    if ($null -eq $runQuery) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail 'no system-query runner in this scan'))
    }

    $locator = Get-VacatePropertyValue -InputObject $Rule -Name 'locator'
    $name = [string](Get-VacatePropertyValue -InputObject $locator -Name 'name')
    if ([string]::IsNullOrWhiteSpace($name)) {
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message 'system-query locator names no query' -Type 'InvalidRule'))
    }

    $result = $null
    try {
        $result = & $runQuery $name
    }
    catch {
        $failure = Get-VacateLocatorFailure -ErrorRecord $_
        if ($failure.Kind -eq 'permission') {
            return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'permission' -Detail ("cannot run query '{0}'" -f $name)))
        }
        if ($failure.Kind -eq 'unavailable') {
            return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail ("query '{0}' is not available" -f $name)))
        }
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message $failure.Message -Type $failure.Type))
    }

    if ($null -eq $result) {
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message ("query '{0}' returned nothing" -f $name) -Type 'SystemQuery'))
    }

    $status = [string](Get-VacatePropertyValue -InputObject $result -Name 'Status')
    $message = ConvertTo-VacateOptionalText -Value (Get-VacatePropertyValue -InputObject $result -Name 'Message')
    $value = Get-VacatePropertyValue -InputObject $result -Name 'Value'

    if ($status -eq 'unavailable') {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail $message))
    }
    if ($status -eq 'timeout') {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'timeout' -Detail $message))
    }
    if ($status -eq 'not-applicable') {
        # No not-applicable skip reason exists; the query cannot run here, which is unavailable.
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail $message))
    }
    if ($status -ne 'ok') {
        $detail = "query '{0}' returned status '{1}'" -f $name, $status
        if ($null -ne $message) { $detail = $detail + ': ' + $message }
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message $detail -Type 'SystemQuery'))
    }

    $properties = $null
    $itemCount = $null
    if ($null -ne $value) {
        if ($value -is [System.Collections.IDictionary] -or $value -is [System.Management.Automation.PSCustomObject]) {
            $properties = $value
        }
        else {
            # The report schema needs an object here, so a list is wrapped, not dropped.
            $properties = [ordered]@{ items = @($value) }
            $itemCount = [int64](@($value).Count)
        }
    }

    $resolved = Get-VacateSystemQueryCommand -Name $name
    $trace = New-VacateTrace -Rule $Rule -Platform (Get-VacateContextPlatformName -Context $Context) `
        -Resolved $resolved -SizeBytes $null -ItemCount $itemCount -Properties $properties

    return (New-VacateLocatorResult -Traces @($trace))
}

function Get-VacateSystemQueryCommand {
    # The fixed binary and arguments for a query, so a trace names what was actually run.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    foreach ($entry in (Get-VacateSystemQueryTable)) {
        if ($entry.Name -eq $Name) {
            return ($entry.Binary + ' ' + (@($entry.Arguments) -join ' '))
        }
    }
    return $Name
}
