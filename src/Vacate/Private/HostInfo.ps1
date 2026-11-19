# HostInfo.ps1 - the report scan.host object (machine, OS, architecture, user, volumes).
# Owner: Pi. PowerShell 5.1 compatible. ASCII only.
#
# Read-only and defensive: a failing CIM query or system query empties that field instead of
# aborting the scan. No environment reads outside the injected snapshot.

function Get-VacateHostInfo {
    # CONTRACTS 9: name, os, version, architecture, user, volumes (report schema order).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )

    $name = ''
    try { $name = ConvertTo-VacateHostText -Value ([Environment]::MachineName) }
    catch { $name = '' }

    $user = ''
    try { $user = ConvertTo-VacateHostText -Value (Get-VacateEnvironmentUserName -Environment $Environment -Name @('USERNAME', 'USER', 'LOGNAME')) }
    catch { $user = '' }

    $architecture = ''
    try { $architecture = ConvertTo-VacateHostText -Value ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) }
    catch { $architecture = '' }

    $platformName = Get-VacateContextPlatformName -Context $Context
    $os = ''
    $version = ''
    $volumes = @()

    if ($platformName -eq 'windows') {
        $cim = Get-VacatePropertyValue -InputObject $Context -Name 'Cim'
        if ($null -ne $cim) {
            try {
                $operatingSystems = @(& $cim 'root/CIMV2' 'Win32_OperatingSystem' ([string[]]@('Caption', 'Version')))
                foreach ($instance in $operatingSystems) {
                    if ($null -eq $instance) { continue }
                    $os = ConvertTo-VacateHostText -Value (Get-VacatePropertyValue -InputObject $instance -Name 'Caption')
                    $version = ConvertTo-VacateHostText -Value (Get-VacatePropertyValue -InputObject $instance -Name 'Version')
                    break
                }
            }
            catch {
                $os = ''
                $version = ''
            }

            try {
                $disks = @(& $cim 'root/CIMV2' 'Win32_LogicalDisk' ([string[]]@('DeviceID', 'FileSystem', 'Size', 'FreeSpace', 'DriveType')))
                $volumeList = New-Object System.Collections.ArrayList
                foreach ($disk in $disks) {
                    if ($null -eq $disk) { continue }
                    # Fixed local disks only (DriveType 3). Filtered here, never in a WQL string.
                    $driveType = Get-VacatePropertyValue -InputObject $disk -Name 'DriveType'
                    if ($null -eq $driveType -or [string]$driveType -ne '3') { continue }
                    [void]$volumeList.Add([pscustomobject][ordered]@{
                            name       = (ConvertTo-VacateHostText -Value (Get-VacatePropertyValue -InputObject $disk -Name 'DeviceID'))
                            fileSystem = (ConvertTo-VacateOptionalText -Value (Get-VacatePropertyValue -InputObject $disk -Name 'FileSystem'))
                            sizeBytes  = (ConvertTo-VacateOptionalInt64 -Value (Get-VacatePropertyValue -InputObject $disk -Name 'Size'))
                            freeBytes  = (ConvertTo-VacateOptionalInt64 -Value (Get-VacatePropertyValue -InputObject $disk -Name 'FreeSpace'))
                        })
                }
                $volumes = @($volumeList.ToArray())
            }
            catch {
                $volumes = @()
            }
        }
    }
    else {
        try { $os = ConvertTo-VacateHostText -Value ([Runtime.InteropServices.RuntimeInformation]::OSDescription) }
        catch { $os = '' }
        try { $version = ConvertTo-VacateHostText -Value (([Environment]::OSVersion.Version).ToString()) }
        catch { $version = '' }

        try {
            $runQuery = Get-VacatePropertyValue -InputObject $Context -Name 'SystemQuery'
            if ($null -ne $runQuery) {
                $result = & $runQuery 'mounts'
                $status = [string](Get-VacatePropertyValue -InputObject $result -Name 'Status')
                if ($status -eq 'ok') {
                    $mountList = New-Object System.Collections.ArrayList
                    foreach ($entry in @(Get-VacatePropertyValue -InputObject $result -Name 'Value')) {
                        if ($null -eq $entry) { continue }
                        [void]$mountList.Add([pscustomobject][ordered]@{
                                name       = (ConvertTo-VacateHostText -Value (Get-VacatePropertyValue -InputObject $entry -Name 'target'))
                                fileSystem = (ConvertTo-VacateOptionalText -Value (Get-VacatePropertyValue -InputObject $entry -Name 'fstype'))
                                sizeBytes  = $null
                                freeBytes  = $null
                            })
                    }
                    $volumes = @($mountList.ToArray())
                }
            }
        }
        catch {
            $volumes = @()
        }
    }

    return [pscustomobject][ordered]@{
        name         = $name
        os           = $os
        version      = $version
        architecture = $architecture
        user         = $user
        volumes      = @($volumes)
    }
}

function ConvertTo-VacateHostText {
    # A host field is always a string: missing or blank becomes ''.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    $text = ConvertTo-VacateOptionalText -Value $Value
    if ($null -eq $text) { return '' }
    return $text
}

function ConvertTo-VacateOptionalInt64 {
    # A numeric host field, or $null when the value is missing or not a number.
    [CmdletBinding()]
    [OutputType([Nullable[long]])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    try {
        return [int64]$Value
    }
    catch {
        return $null
    }
}
