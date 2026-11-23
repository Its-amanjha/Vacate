# SystemDisk.ps1 - identify the system disk and its encryption (D54-D57).
# PowerShell 5.1 compatible. ASCII only.
#
# Read-only by construction: the only reads are named CIM queries through the injected
# runner and allow-listed system queries (D54). This file never erases, resets, sanitizes
# or destroys a key (D57). A value that cannot be read is null in the result and is named
# in "problems": no serial, model or encryption state is ever guessed (D55).

function Get-VacateSystemDisk {
    # Identity of the disk holding the OS volume, plus its encryption state.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('windows', 'macos', 'linux')][string]$Platform,
        # Production passes New-VacateCimRunner; tests pass a fake scriptblock.
        [AllowNull()][object]$CimRunner,
        # Production passes the module system-query seam; tests pass a fake scriptblock.
        [AllowNull()][scriptblock]$SystemQuery
    )

    $problems = New-Object System.Collections.ArrayList

    $model = $null
    $serial = $null
    $sizeBytes = $null
    $busType = $null
    $osVolume = $null

    $kind = 'unknown'
    $protectionOn = $null
    $container = $null
    $source = $null

    if ($Platform -eq 'windows') {
        $source = 'cim'
        if ($null -eq $CimRunner) { $CimRunner = New-VacateCimRunner }

        $systemDrive = $null
        foreach ($instance in (Get-VacateSystemDiskCimItem -CimRunner $CimRunner -ClassName 'Win32_OperatingSystem' -Property @('SystemDrive') -Problems $problems)) {
            $systemDrive = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $instance -Name 'SystemDrive')
            if ($null -ne $systemDrive) { break }
        }
        if ($null -eq $systemDrive) {
            [void]$problems.Add('system drive could not be determined from Win32_OperatingSystem')
        }
        else {
            $osVolume = $systemDrive

            # The association class is read with Get-CimInstance, not with a raw WQL string.
            # DeviceID references carry the logical disk and partition names.
            $links = Get-VacateSystemDiskCimItem -CimRunner $CimRunner -ClassName 'Win32_LogicalDiskToPartition' -Property @('Antecedent', 'Dependent') -Problems $problems
            $partitionId = $null
            foreach ($link in $links) {
                $dependent = [string](Get-VacatePropertyValue -InputObject $link -Name 'Dependent')
                $logicalId = Get-VacateSystemDiskReferenceId -Reference $dependent -ClassName 'Win32_LogicalDisk'
                if ($null -ne $logicalId -and $logicalId -eq $systemDrive) {
                    $antecedent = [string](Get-VacatePropertyValue -InputObject $link -Name 'Antecedent')
                    $partitionId = Get-VacateSystemDiskReferenceId -Reference $antecedent -ClassName 'Win32_DiskPartition'
                    break
                }
            }

            if ($null -eq $partitionId) {
                [void]$problems.Add(("partition for system volume '{0}' could not be determined" -f $systemDrive))
            }
            else {
                $diskIndex = $null
                $partitions = Get-VacateSystemDiskCimItem -CimRunner $CimRunner -ClassName 'Win32_DiskPartition' -Property @('DeviceID', 'DiskIndex') -Problems $problems
                foreach ($partition in $partitions) {
                    $id = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $partition -Name 'DeviceID')
                    if ($null -ne $id -and $id -eq $partitionId) {
                        $diskIndex = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $partition -Name 'DiskIndex')
                        break
                    }
                }

                if ($null -eq $diskIndex) {
                    [void]$problems.Add(("disk index for partition '{0}' could not be determined" -f $partitionId))
                }
                else {
                    $diskFound = $false
                    $drives = Get-VacateSystemDiskCimItem -CimRunner $CimRunner -ClassName 'Win32_DiskDrive' -Property @('Index', 'Model', 'SerialNumber', 'Size', 'InterfaceType') -Problems $problems
                    foreach ($drive in $drives) {
                        $index = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $drive -Name 'Index')
                        if ($null -eq $index -or $index -ne $diskIndex) { continue }
                        $diskFound = $true
                        $model = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $drive -Name 'Model')
                        $serial = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $drive -Name 'SerialNumber')
                        $sizeBytes = Get-VacateSystemDiskInt64 -Value (Get-VacatePropertyValue -InputObject $drive -Name 'Size')
                        $busType = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $drive -Name 'InterfaceType')
                        break
                    }
                    if (-not $diskFound) {
                        [void]$problems.Add(("system disk with index '{0}' could not be determined" -f $diskIndex))
                    }
                    else {
                        if ($null -eq $model) { [void]$problems.Add('disk model could not be determined') }
                        if ($null -eq $serial) { [void]$problems.Add('disk serial number could not be determined') }
                        if ($null -eq $sizeBytes) { [void]$problems.Add('disk size could not be determined') }
                        if ($null -eq $busType) { [void]$problems.Add('disk bus type could not be determined') }
                    }
                }
            }
        }

        # BitLocker is queried only through CIM. A missing class (for example on Home)
        # is unknown, never "none": a claim of no encryption would be a guess.
        if ($null -eq $systemDrive) {
            [void]$problems.Add('BitLocker status could not be determined without the system volume')
        }
        else {
            $volumes = @()
            $queryError = $null
            try {
                $volumes = @(& $CimRunner 'root/CIMV2/Security/MicrosoftVolumeEncryption' 'Win32_EncryptableVolume' ([string[]]@('DeviceID', 'ProtectionStatus')))
            }
            catch {
                $queryError = $_.Exception.Message
            }
            if ($null -ne $queryError) {
                $kind = 'unknown'
                $protectionOn = $null
                [void]$problems.Add(("BitLocker status could not be determined: {0}" -f $queryError))
            }
            else {
                $encryptedVolume = $null
                foreach ($volume in $volumes) {
                    $id = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $volume -Name 'DeviceID')
                    if ($null -ne $id -and $id -eq $systemDrive) { $encryptedVolume = $volume; break }
                }
                if ($null -eq $encryptedVolume) {
                    $kind = 'none'
                    $protectionOn = $false
                }
                else {
                    $status = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $encryptedVolume -Name 'ProtectionStatus')
                    if ($status -eq '1') {
                        $kind = 'bitlocker'
                        $protectionOn = $true
                    }
                    elseif ($status -eq '0') {
                        $kind = 'bitlocker'
                        $protectionOn = $false
                    }
                    else {
                        $kind = 'unknown'
                        $protectionOn = $null
                        [void]$problems.Add('BitLocker protection status could not be determined')
                    }
                }
            }
        }
    }
    elseif ($Platform -eq 'linux') {
        $source = 'system-query:block-devices-detail'
        $query = Get-VacateSystemDiskQueryResult -Name 'block-devices-detail' -Platform $Platform -SystemQuery $SystemQuery
        $status = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $query -Name 'Status')
        if ($status -ne 'ok') {
            [void]$problems.Add(("block device query returned status '{0}'" -f $status))
        }
        else {
            $devices = @(Get-VacatePropertyValue -InputObject $query -Name 'Value')
            $byName = @{}
            foreach ($device in $devices) {
                $name = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $device -Name 'name')
                if ($null -ne $name -and -not $byName.ContainsKey($name)) { $byName[$name] = $device }
            }

            $root = $null
            foreach ($device in $devices) {
                $mount = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $device -Name 'mountpoint')
                if ($mount -eq '/') { $root = $device; break }
            }
            if ($null -eq $root) {
                [void]$problems.Add('root volume was not found in the block device list')
            }
            else {
                $osVolume = '/'

                # Walk up the parent chain from /. A crypto_LUKS ancestor is the container;
                # the disk ancestor supplies the identity. The chain is bounded by $seen.
                $current = $root
                $seen = @{}
                $disk = $null
                while ($null -ne $current) {
                    $name = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $current -Name 'name')
                    if ($null -eq $name -or $seen.ContainsKey($name)) { break }
                    $seen[$name] = $true

                    $fstype = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $current -Name 'fstype')
                    $type = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $current -Name 'type')
                    if ($null -eq $container -and $fstype -eq 'crypto_LUKS') {
                        $container = Get-VacateSystemDiskDevicePath -Name $name
                        $kind = 'luks'
                        $protectionOn = $true
                    }
                    if ($type -eq 'disk') { $disk = $current; break }

                    $parentName = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $current -Name 'pkname')
                    if ($null -eq $parentName) {
                        $parentName = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $current -Name 'parent')
                    }
                    if ($null -eq $parentName -or -not $byName.ContainsKey($parentName)) { break }
                    $current = $byName[$parentName]
                }

                if ($kind -eq 'unknown') {
                    # The whole chain was read and no LUKS container was present.
                    $kind = 'none'
                    $protectionOn = $false
                }

                if ($null -eq $disk) {
                    [void]$problems.Add('system disk could not be determined from the block device list')
                }
                else {
                    $model = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $disk -Name 'model')
                    $serial = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $disk -Name 'serial')
                    $sizeBytes = Get-VacateSystemDiskInt64 -Value (Get-VacatePropertyValue -InputObject $disk -Name 'size')
                    $busType = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $disk -Name 'tran')
                    if ($null -eq $model) { [void]$problems.Add('disk model could not be determined') }
                    if ($null -eq $serial) { [void]$problems.Add('disk serial number could not be determined') }
                    if ($null -eq $sizeBytes) { [void]$problems.Add('disk size could not be determined') }
                    if ($null -eq $busType) { [void]$problems.Add('disk bus type could not be determined') }
                }
            }
        }
    }
    else {
        # macOS: fdesetup for FileVault, diskutil for disk identity. Both are queries
        # with fixed arguments; nothing in this branch starts an erase (D57).
        $source = 'system-query:disk-info'

        $fileVault = Get-VacateSystemDiskQueryResult -Name 'filevault-status' -Platform $Platform -SystemQuery $SystemQuery
        $fileVaultStatus = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $fileVault -Name 'Status')
        if ($fileVaultStatus -ne 'ok') {
            [void]$problems.Add(("FileVault status query returned status '{0}'" -f $fileVaultStatus))
        }
        else {
            $value = Get-VacatePropertyValue -InputObject $fileVault -Name 'Value'
            $enabled = Get-VacatePropertyValue -InputObject $value -Name 'enabled'
            if ($null -eq $enabled) {
                [void]$problems.Add('FileVault state could not be determined')
            }
            elseif ($enabled -is [bool]) {
                $kind = 'filevault'
                $protectionOn = [bool]$enabled
            }
            else {
                $state = Get-VacateSystemDiskText -Value $enabled
                if ($state -eq 'True' -or $state -eq '1') {
                    $kind = 'filevault'
                    $protectionOn = $true
                }
                elseif ($state -eq 'False' -or $state -eq '0') {
                    $kind = 'filevault'
                    $protectionOn = $false
                }
                else {
                    [void]$problems.Add('FileVault state could not be determined')
                }
            }
        }

        $info = Get-VacateSystemDiskQueryResult -Name 'disk-info' -Platform $Platform -SystemQuery $SystemQuery
        $infoStatus = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $info -Name 'Status')
        if ($infoStatus -ne 'ok') {
            [void]$problems.Add(("disk info query returned status '{0}'" -f $infoStatus))
        }
        else {
            $value = Get-VacatePropertyValue -InputObject $info -Name 'Value'
            $model = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $value -Name 'model')
            $serial = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $value -Name 'serial')
            $sizeBytes = Get-VacateSystemDiskInt64 -Value (Get-VacatePropertyValue -InputObject $value -Name 'sizeBytes')
            $busType = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $value -Name 'busType')
            $osVolume = Get-VacateSystemDiskText -Value (Get-VacatePropertyValue -InputObject $value -Name 'mountPoint')
            if ($null -eq $model) { [void]$problems.Add('disk model could not be determined') }
            if ($null -eq $serial) { [void]$problems.Add('disk serial number could not be determined') }
            if ($null -eq $sizeBytes) { [void]$problems.Add('disk size could not be determined') }
            if ($null -eq $busType) { [void]$problems.Add('disk bus type could not be determined') }
            if ($null -eq $osVolume) { [void]$problems.Add('OS volume could not be determined') }
        }
    }

    return [pscustomobject][ordered]@{
        platform   = $Platform
        model      = $model
        serial     = $serial
        sizeBytes  = $sizeBytes
        busType    = $busType
        osVolume   = $osVolume
        encryption = [pscustomobject][ordered]@{
            kind         = $kind
            protectionOn = $protectionOn
            container    = $container
        }
        source     = $source
        problems   = @($problems.ToArray())
    }
}

function Get-VacateSystemDiskQueryResult {
    # Runs one named query through the injected seam, or through the production seam.
    # A thrown query becomes an error result, never an aborted system-disk check.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Platform,
        [AllowNull()][scriptblock]$SystemQuery
    )

    try {
        if ($null -eq $SystemQuery) {
            $result = Invoke-VacateSystemQuery -Name $Name -Platform $Platform
        }
        else {
            $result = & $SystemQuery $Name
        }
        if ($null -eq $result) {
            return [pscustomobject][ordered]@{
                Name = $Name; Status = 'error'; Value = $null; Message = 'query returned nothing'
            }
        }
        return $result
    }
    catch {
        return [pscustomobject][ordered]@{
            Name = $Name; Status = 'error'; Value = $null; Message = $_.Exception.Message
        }
    }
}

function Get-VacateSystemDiskCimItem {
    # One read-only CIM query. A failed class query is reported as a problem and returns
    # no instances; it never stops the scan (D55).
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][object]$CimRunner,
        [Parameter(Mandatory)][string]$ClassName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Property,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$Problems
    )

    try {
        return @(& $CimRunner 'root/CIMV2' $ClassName $Property)
    }
    catch {
        [void]$Problems.Add(("CIM query {0} failed: {1}" -f $ClassName, $_.Exception.Message))
        return @()
    }
}

function Get-VacateSystemDiskReferenceId {
    # Reads a DeviceID out of either CIM reference spelling:
    # \\HOST\root\CIMV2:Win32_DiskPartition.DeviceID="Disk #0, Partition #1" or the
    # Get-CimInstance form Win32_DiskPartition (DeviceID = "Disk #0, Partition #1").
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory)][string]$ClassName
    )

    $ignoreCase = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    $escaped = [regex]::Escape($ClassName)

    # A WMI reference string: Class.DeviceID="value".
    $pattern = $escaped + '\.DeviceId="(?<v>[^"]+)"'
    $match = [regex]::Match($Reference, $pattern, $ignoreCase)
    if ($match.Success) { return [string]$match.Groups['v'].Value }

    # Get-CimInstance renders an association reference as: Class (DeviceID = "value").
    $pattern = $escaped + '\s*\(\s*DeviceId\s*=\s*"(?<v>[^"]+)"\s*\)'
    $match = [regex]::Match($Reference, $pattern, $ignoreCase)
    if ($match.Success) { return [string]$match.Groups['v'].Value }

    $pattern = 'DeviceId\s*=\s*"(?<v>[^"]+)"'
    $match = [regex]::Match($Reference, $pattern, $ignoreCase)
    if ($match.Success) { return [string]$match.Groups['v'].Value }
    return $null
}

function Get-VacateSystemDiskText {
    # Trimmed string metadata, or $null when missing or blank.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    return $text
}

function Get-VacateSystemDiskInt64 {
    # Exact int64 metadata, or $null when the value is missing or not a number.
    [CmdletBinding()]
    [OutputType([Nullable[long]])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    $parsed = [int64]0
    if ([int64]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-VacateSystemDiskDevicePath {
    # A kernel device name becomes a /dev path without ever touching the device.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    if ($Name.StartsWith('/dev/', [StringComparison]::Ordinal)) { return $Name }
    return ('/dev/' + $Name)
}
