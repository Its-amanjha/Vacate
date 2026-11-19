# LocatorInstalledProgram.ps1 - installed-program locator executor.
# PowerShell 5.1 compatible. ASCII only.
#
# Reads the uninstall keys through the context registry provider, which exposes only the named
# values. Nothing is opened, no program file is touched, nothing is installed or removed.

$script:VacateUninstallKeyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$script:VacateUninstallValueNames = @('DisplayName', 'Publisher', 'DisplayVersion', 'InstallDate', 'SystemComponent')

function Invoke-VacateInstalledProgramLocator {
    # HKLM 64-bit and 32-bit plus HKCU per scope; entries without a display name and
    # system components are dropped, duplicates are removed, and the result is sorted ordinal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][datetime]$Deadline
    )

    if ([datetime]::UtcNow -ge $Deadline) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'timeout' -Detail 'deadline reached before the installed-program locator ran'))
    }

    $registry = Get-VacatePropertyValue -InputObject $Context -Name 'Registry'
    if ($null -eq $registry) {
        return (New-VacateLocatorResult -Skips @(New-VacateSkip -RuleId $Rule.id -Reason 'unavailable' -Detail 'no registry provider on this platform'))
    }

    $locator = Get-VacatePropertyValue -InputObject $Rule -Name 'locator'
    $scope = [string](Get-VacatePropertyValue -InputObject $locator -Name 'scope')
    if ([string]::IsNullOrWhiteSpace($scope)) { $scope = 'all' }
    if ($scope -ne 'user' -and $scope -ne 'machine' -and $scope -ne 'all') {
        return (New-VacateLocatorResult -Errors @(New-VacateError -RuleId $Rule.id -Message ("unknown installed-program scope '{0}'" -f $scope) -Type 'InvalidRule'))
    }

    # Fixed, deterministic source order: machine 64-bit, machine 32-bit, then the user hive.
    $sources = New-Object System.Collections.ArrayList
    if ($scope -eq 'machine' -or $scope -eq 'all') {
        [void]$sources.Add(@{ Hive = 'HKLM'; View = 'Registry64'; Scope = 'machine' })
        [void]$sources.Add(@{ Hive = 'HKLM'; View = 'Registry32'; Scope = 'machine' })
    }
    if ($scope -eq 'user' -or $scope -eq 'all') {
        [void]$sources.Add(@{ Hive = 'HKCU'; View = 'Default'; Scope = 'user' })
    }

    $programs = New-Object System.Collections.ArrayList
    $skips = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $seen = @{}
    $scopeSeen = @{}
    $keyPath = $script:VacateUninstallKeyPath
    $valueNames = [string[]]$script:VacateUninstallValueNames

    foreach ($source in $sources) {
        if ([datetime]::UtcNow -ge $Deadline) {
            [void]$skips.Add((New-VacateSkip -RuleId $Rule.id -Reason 'timeout' -Detail 'deadline reached while reading uninstall keys'))
            break
        }

        $entries = $null
        try {
            $entries = $registry.GetSubKeyValues($source['Hive'], $keyPath, $source['View'], $valueNames)
        }
        catch {
            $failure = Get-VacateLocatorFailure -ErrorRecord $_
            if ($failure.Kind -eq 'permission') {
                [void]$skips.Add((New-VacateSkip -RuleId $Rule.id -Reason 'permission' -Detail ("cannot read {0}\{1}" -f $source['Hive'], $keyPath)))
            }
            else {
                [void]$errors.Add((New-VacateError -RuleId $Rule.id -Message $failure.Message -Type $failure.Type))
            }
            continue
        }

        if ($null -eq $entries) { continue }
        $scopeSeen[$source['Scope']] = $true

        foreach ($entry in @($entries)) {
            $values = Get-VacatePropertyValue -InputObject $entry -Name 'Values'
            $name = ConvertTo-VacateOptionalText -Value (Get-VacatePropertyValue -InputObject $values -Name 'DisplayName')
            if ($null -eq $name) { continue }

            $systemComponent = ConvertTo-VacateOptionalText -Value (Get-VacatePropertyValue -InputObject $values -Name 'SystemComponent')
            if ($systemComponent -eq '1') { continue }

            $version = ConvertTo-VacateOptionalText -Value (Get-VacatePropertyValue -InputObject $values -Name 'DisplayVersion')
            $publisher = ConvertTo-VacateOptionalText -Value (Get-VacatePropertyValue -InputObject $values -Name 'Publisher')
            $installDate = ConvertTo-VacateProgramInstallDate -Text (Get-VacatePropertyValue -InputObject $values -Name 'InstallDate')

            $dedupeKey = $name.ToLowerInvariant() + '|' + [string]$version + '|' + $source['Scope']
            if ($seen.ContainsKey($dedupeKey)) { continue }
            $seen[$dedupeKey] = $true

            [void]$programs.Add([pscustomobject][ordered]@{
                    name        = $name
                    publisher   = $publisher
                    version     = $version
                    installDate = $installDate
                    scope       = $source['Scope']
                })
        }
    }

    $sorted = @(Select-VacateProgramInOrder -Programs $programs.ToArray())
    $countByScope = @{ machine = 0; user = 0 }
    foreach ($program in $sorted) {
        $countByScope[$program.scope] = $countByScope[$program.scope] + 1
    }

    $platformName = Get-VacateContextPlatformName -Context $Context
    $traces = New-Object System.Collections.ArrayList
    foreach ($scopeName in @('machine', 'user')) {
        if (-not $scopeSeen.ContainsKey($scopeName)) { continue }
        $hive = 'HKCU'
        if ($scopeName -eq 'machine') { $hive = 'HKLM' }
        $trace = New-VacateTrace -Rule $Rule -Platform $platformName -Resolved ($hive + '\' + $keyPath) `
            -SizeBytes $null -ItemCount ([int64]($countByScope[$scopeName]))
        [void]$traces.Add($trace)
    }

    return (New-VacateLocatorResult -Traces $traces.ToArray() -Skips $skips.ToArray() -Errors $errors.ToArray() -Programs $sorted)
}

function ConvertTo-VacateOptionalText {
    # Trimmed string, or $null when the value is missing or blank.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    return $text
}

function ConvertTo-VacateProgramInstallDate {
    # Uninstall keys store yyyyMMdd. Anything else is reported as $null, never guessed.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Text)

    if ($null -eq $Text) { return $null }
    $raw = ([string]$Text).Trim()
    if ($raw -notmatch '^[0-9]{8}$') { return $null }

    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::None
    $ok = [datetime]::TryParseExact($raw, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)
    if (-not $ok) { return $null }
    return $parsed.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Select-VacateProgramInOrder {
    # Ordinal sort by name. The key carries the version and scope so equal names never tie.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]]$Programs = @())

    if ($Programs.Count -lt 2) { return $Programs }

    $keys = New-Object System.Collections.ArrayList
    $items = New-Object System.Collections.ArrayList
    foreach ($program in $Programs) {
        if ($null -eq $program) { continue }
        [void]$keys.Add(([string]$program.name + [char]0 + [string]$program.version + [char]0 + [string]$program.scope))
        [void]$items.Add($program)
    }

    $keyArray = [string[]]$keys.ToArray()
    $itemArray = [object[]]$items.ToArray()
    [array]::Sort($keyArray, $itemArray, [System.Collections.IComparer][System.StringComparer]::Ordinal)
    return $itemArray
}
