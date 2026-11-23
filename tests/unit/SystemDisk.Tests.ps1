# System disk tests. Every CIM runner and system query is a fake: no erase, reset,
# key operation or real disk is touched (D57). Canned JSON/plist text is parsed by the
# production parsers so the reader is exercised end to end.
# Pester 5 runs It bodies in a scope that does not see the file body, so helpers and
# fixtures live in BeforeAll.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestCimFake {
        param([Parameter(Mandatory)][hashtable]$Responses)
        return {
            param($Namespace, $ClassName, $Property)
            if ($Responses.ContainsKey($ClassName)) {
                $entry = $Responses[$ClassName]
                if ($entry -is [Exception]) { throw $entry }
                return @($entry)
            }
            return @()
        }.GetNewClosure()
    }

    function Get-TestQueryFake {
        param([hashtable]$Text = @{}, [hashtable]$Status = @{})
        return {
            param($Name)
            if ($Status.ContainsKey($Name)) {
                return [pscustomobject][ordered]@{ Name = $Name; Status = $Status[$Name]; Value = $null; Message = 'injected status' }
            }
            if (-not $Text.ContainsKey($Name)) {
                return [pscustomobject][ordered]@{ Name = $Name; Status = 'error'; Value = $null; Message = 'no canned text' }
            }
            $raw = $Text[$Name]
            # The parsers are module-private, so parse inside the module.
            $value = InModuleScope Vacate -Parameters @{ N = $Name; R = $raw } {
                param($N, $R)
                switch ($N) {
                    'block-devices-detail' { return (ConvertFrom-VacateLsblkJson -Text $R) }
                    'filevault-status' { return (ConvertFrom-VacateFdesetupStatus -Text $R) }
                    'disk-info' { return (ConvertFrom-VacateDiskInfoPlist -Text $R) }
                }
                return $null
            }
            return [pscustomobject][ordered]@{ Name = $Name; Status = 'ok'; Value = $value; Message = $null }
        }.GetNewClosure()
    }

    function Get-TestQueryResultFake {
        param([string]$Status = 'ok', [object]$Value = $null, [string]$Message = $null)
        return [pscustomobject][ordered]@{ Name = 'injected'; Status = $Status; Value = $Value; Message = $Message }
    }

    function Get-TestSystemDisk {
        param([string]$Platform, [object]$Cim = $null, [object]$Query = $null)
        return (InModuleScope Vacate -Parameters @{ P = $Platform; C = $Cim; Q = $Query } {
                param($P, $C, $Q)
                if ($null -eq $C -and $null -eq $Q) { Get-VacateSystemDisk -Platform $P }
                elseif ($null -eq $C) { Get-VacateSystemDisk -Platform $P -SystemQuery $Q }
                elseif ($null -eq $Q) { Get-VacateSystemDisk -Platform $P -CimRunner $C }
                else { Get-VacateSystemDisk -Platform $P -CimRunner $C -SystemQuery $Q }
            })
    }

    function Get-TestWindowsFixture {
        param(
            [object]$ProtectionStatus = 1,
            [object]$Serial = 'SERIAL123',
            [object]$EncryptError = $null,
            [string]$Model = 'Test SSD'
        )
        $responses = @{
            'Win32_OperatingSystem' = @([pscustomobject]@{ SystemDrive = 'C:' })
            'Win32_LogicalDiskToPartition' = @([pscustomobject]@{
                    Antecedent = '\\PC\root\CIMV2:Win32_DiskPartition.DeviceID="Disk #0, Partition #1"'
                    Dependent   = '\\PC\root\CIMV2:Win32_LogicalDisk.DeviceID="C:"'
                })
            'Win32_DiskPartition' = @([pscustomobject]@{ DeviceID = 'Disk #0, Partition #1'; DiskIndex = 0 })
            'Win32_DiskDrive' = @([pscustomobject]@{
                    Index = 0; Model = $Model; SerialNumber = $Serial
                    Size = 1000204886016; InterfaceType = 'SCSI'
                })
        }
        if ($null -ne $EncryptError) {
            $responses['Win32_EncryptableVolume'] = $EncryptError
        }
        else {
            $responses['Win32_EncryptableVolume'] = @([pscustomobject]@{ DeviceID = 'C:'; ProtectionStatus = $ProtectionStatus })
        }
        return $responses
    }

    $script:luksJson = @'
{"blockdevices":[
  {"name":"nvme0n1","type":"disk","fstype":null,"mountpoint":null,"model":"Samsung SSD 980 PRO","serial":"S5GXNX0R123456","size":"1000204886016","pkname":null,"tran":"nvme","children":[
    {"name":"nvme0n1p3","type":"part","fstype":"crypto_LUKS","mountpoint":null,"model":null,"serial":null,"size":"999994761216","pkname":"nvme0n1","tran":null,"children":[
      {"name":"dm-0","type":"crypt","fstype":"ext4","mountpoint":"/","model":null,"serial":null,"size":"999993435136","pkname":"nvme0n1p3","tran":null}
    ]}
  ]}
]}
'@

    $script:plainJson = @'
{"blockdevices":[
  {"name":"sda","type":"disk","fstype":null,"mountpoint":null,"model":"ST1000DM003","serial":"Z1D2ABC3","size":"1000204886016","pkname":null,"tran":"sata","children":[
    {"name":"sda1","type":"part","fstype":"ext4","mountpoint":"/","model":null,"serial":null,"size":"999990000000","pkname":"sda","tran":null}
  ]}
]}
'@

    $script:lvmJson = @'
{"blockdevices":[
  {"name":"nvme0n1","type":"disk","fstype":null,"mountpoint":null,"model":"WD Blue SSD","serial":"WD1234567890","size":"500107862016","pkname":null,"tran":"nvme","children":[
    {"name":"nvme0n1p3","type":"part","fstype":"crypto_LUKS","mountpoint":null,"pkname":"nvme0n1","size":"500106811392","children":[
      {"name":"dm-0","type":"crypt","fstype":"LVM2_member","mountpoint":null,"pkname":"nvme0n1p3","children":[
        {"name":"vg-root","type":"lvm","fstype":"ext4","mountpoint":"/","pkname":"dm-0"}
      ]}
    ]}
  ]}
]}
'@

    $script:fvOnText = 'FileVault is On.'
    $script:fvOffText = 'FileVault is Off.'
    $script:fvUnknownText = 'FileVault status could not be determined.'

    $script:diskInfoPlist = @'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>DeviceIdentifier</key><string>disk0s1</string>
  <key>DeviceModel</key><string>APPLE SSD AP1024R</string>
  <key>SerialNumber</key><string>C02ABCDEFGH</string>
  <key>TotalSize</key><integer>1000204886016</integer>
  <key>BusType</key><string>PCI-Express</string>
  <key>MountPoint</key><string>/</string>
</dict></plist>
'@

    $script:diskInfoNoSerial = @'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>DeviceIdentifier</key><string>disk0s1</string>
  <key>DeviceModel</key><string>APPLE SSD AP1024R</string>
  <key>TotalSize</key><integer>1000204886016</integer>
  <key>MountPoint</key><string>/</string>
</dict></plist>
'@
}

Describe 'Get-VacateSystemDisk - result shape' {
    It 'returns the contract fields in order on every platform' {
        $windows = Get-TestSystemDisk -Platform 'windows' -Cim (Get-TestCimFake -Responses (Get-TestWindowsFixture))
        $linux = Get-TestSystemDisk -Platform 'linux' -Query (Get-TestQueryFake -Text @{ 'block-devices-detail' = $script:plainJson })
        $macos = Get-TestSystemDisk -Platform 'macos' -Query (Get-TestQueryFake -Text @{ 'filevault-status' = $script:fvOnText; 'disk-info' = $script:diskInfoPlist })

        foreach ($disk in @($windows, $linux, $macos)) {
            (@($disk.PSObject.Properties.Name) -join ',') | Should -Be 'platform,model,serial,sizeBytes,busType,osVolume,encryption,source,problems'
            (@($disk.encryption.PSObject.Properties.Name) -join ',') | Should -Be 'kind,protectionOn,container'
            $disk.PSObject.Properties['problems'].Value.GetType().FullName | Should -Be 'System.Object[]'
        }
    }

    It 'rejects a platform outside the three known names' {
        { Get-TestSystemDisk -Platform 'haiku' } | Should -Throw
    }
}

Describe 'Get-VacateSystemDisk - Windows' {
    It 'finds the system disk and reports BitLocker on' {
        $cim = Get-TestCimFake -Responses (Get-TestWindowsFixture)
        $disk = Get-TestSystemDisk -Platform 'windows' -Cim $cim

        $disk.platform | Should -Be 'windows'
        $disk.model | Should -Be 'Test SSD'
        $disk.serial | Should -Be 'SERIAL123'
        $disk.sizeBytes | Should -BeOfType [int64]
        $disk.sizeBytes | Should -Be 1000204886016
        $disk.busType | Should -Be 'SCSI'
        $disk.osVolume | Should -Be 'C:'
        $disk.encryption.kind | Should -Be 'bitlocker'
        $disk.encryption.protectionOn | Should -BeTrue
        $disk.encryption.container | Should -BeNullOrEmpty
        $disk.source | Should -Be 'cim'
        @($disk.problems).Count | Should -Be 0
    }

    It 'reads the Get-CimInstance reference format for the system partition' {
        $responses = Get-TestWindowsFixture
        $responses['Win32_LogicalDiskToPartition'] = @([pscustomobject]@{
                Antecedent = 'Win32_DiskPartition (DeviceID = "Disk #0, Partition #1")'
                Dependent   = 'Win32_LogicalDisk (DeviceID = "C:")'
            })
        $disk = Get-TestSystemDisk -Platform 'windows' -Cim (Get-TestCimFake -Responses $responses)

        $disk.osVolume | Should -Be 'C:'
        $disk.model | Should -Be 'Test SSD'
        $disk.serial | Should -Be 'SERIAL123'
        @($disk.problems).Count | Should -Be 0
    }

    It 'reports BitLocker present but protection off' {
        $responses = Get-TestWindowsFixture -ProtectionStatus 0
        $disk = Get-TestSystemDisk -Platform 'windows' -Cim (Get-TestCimFake -Responses $responses)

        $disk.encryption.kind | Should -Be 'bitlocker'
        $disk.encryption.protectionOn | Should -BeFalse
        @($disk.problems).Count | Should -Be 0
    }

    It 'reports unknown when the BitLocker class is absent (Home edition)' {
        $responses = Get-TestWindowsFixture -EncryptError ([Exception]::new('Invalid class Win32_EncryptableVolume'))
        $disk = Get-TestSystemDisk -Platform 'windows' -Cim (Get-TestCimFake -Responses $responses)

        $disk.encryption.kind | Should -Be 'unknown'
        $disk.encryption.protectionOn | Should -BeNullOrEmpty
        (@($disk.problems) -join ' ') | Should -Match 'BitLocker'
    }

    It 'reports a missing serial as null with a problem instead of guessing' {
        $responses = Get-TestWindowsFixture -Serial ''
        $disk = Get-TestSystemDisk -Platform 'windows' -Cim (Get-TestCimFake -Responses $responses)

        $disk.serial | Should -BeNullOrEmpty
        $disk.model | Should -Be 'Test SSD'
        (@($disk.problems) -join ' ') | Should -Match 'serial'
    }

    It 'reports an unreadable CIM class as unknown, not as a clean result' {
        $responses = Get-TestWindowsFixture
        $responses['Win32_OperatingSystem'] = [Exception]::new('Access denied')
        $disk = Get-TestSystemDisk -Platform 'windows' -Cim (Get-TestCimFake -Responses $responses)

        $disk.serial | Should -BeNullOrEmpty
        $disk.osVolume | Should -BeNullOrEmpty
        $disk.encryption.kind | Should -Be 'unknown'
        (@($disk.problems) -join ' ') | Should -Match 'CIM query Win32_OperatingSystem failed'
    }
}

Describe 'Get-VacateSystemDisk - Linux' {
    It 'finds LUKS on an NVMe root and names the container' {
        $disk = Get-TestSystemDisk -Platform 'linux' -Query (Get-TestQueryFake -Text @{ 'block-devices-detail' = $script:luksJson })

        $disk.osVolume | Should -Be '/'
        $disk.model | Should -Be 'Samsung SSD 980 PRO'
        $disk.serial | Should -Be 'S5GXNX0R123456'
        $disk.sizeBytes | Should -Be 1000204886016
        $disk.busType | Should -Be 'nvme'
        $disk.encryption.kind | Should -Be 'luks'
        $disk.encryption.protectionOn | Should -BeTrue
        $disk.encryption.container | Should -Be '/dev/nvme0n1p3'
        @($disk.problems).Count | Should -Be 0
    }

    It 'reports a plain ext4 root as unencrypted' {
        $disk = Get-TestSystemDisk -Platform 'linux' -Query (Get-TestQueryFake -Text @{ 'block-devices-detail' = $script:plainJson })

        $disk.encryption.kind | Should -Be 'none'
        $disk.encryption.protectionOn | Should -BeFalse
        $disk.encryption.container | Should -BeNullOrEmpty
        $disk.serial | Should -Be 'Z1D2ABC3'
        @($disk.problems).Count | Should -Be 0
    }

    It 'walks through LVM on LUKS to the container and the physical disk' {
        $disk = Get-TestSystemDisk -Platform 'linux' -Query (Get-TestQueryFake -Text @{ 'block-devices-detail' = $script:lvmJson })

        $disk.encryption.kind | Should -Be 'luks'
        $disk.encryption.container | Should -Be '/dev/nvme0n1p3'
        $disk.model | Should -Be 'WD Blue SSD'
        $disk.serial | Should -Be 'WD1234567890'
        @($disk.problems).Count | Should -Be 0
    }

    It 'reports unknown when the block device query is unavailable' {
        $fake = { return (Get-TestQueryResultFake -Status 'unavailable' -Message 'lsblk is missing') }
        $disk = Get-TestSystemDisk -Platform 'linux' -Query $fake

        $disk.encryption.kind | Should -Be 'unknown'
        $disk.encryption.protectionOn | Should -BeNullOrEmpty
        $disk.serial | Should -BeNullOrEmpty
        (@($disk.problems) -join ' ') | Should -Match 'unavailable'
    }

    It 'never claims a root that is absent from the device list' {
        $disk = Get-TestSystemDisk -Platform 'linux' -Query (Get-TestQueryFake -Text @{ 'block-devices-detail' = '{"blockdevices":[]}' })

        $disk.osVolume | Should -BeNullOrEmpty
        $disk.encryption.kind | Should -Be 'unknown'
        (@($disk.problems) -join ' ') | Should -Match 'root volume'
    }
}

Describe 'Get-VacateSystemDisk - macOS' {
    It 'finds the disk and reports FileVault on' {
        $text = @{ 'filevault-status' = $script:fvOnText; 'disk-info' = $script:diskInfoPlist }
        $disk = Get-TestSystemDisk -Platform 'macos' -Query (Get-TestQueryFake -Text $text)

        $disk.osVolume | Should -Be '/'
        $disk.model | Should -Be 'APPLE SSD AP1024R'
        $disk.serial | Should -Be 'C02ABCDEFGH'
        $disk.sizeBytes | Should -Be 1000204886016
        $disk.busType | Should -Be 'PCI-Express'
        $disk.encryption.kind | Should -Be 'filevault'
        $disk.encryption.protectionOn | Should -BeTrue
        $disk.encryption.container | Should -BeNullOrEmpty
        $disk.source | Should -Be 'system-query:disk-info'
        @($disk.problems).Count | Should -Be 0
    }

    It 'reports FileVault off as a known state with protection off' {
        $text = @{ 'filevault-status' = $script:fvOffText; 'disk-info' = $script:diskInfoPlist }
        $disk = Get-TestSystemDisk -Platform 'macos' -Query (Get-TestQueryFake -Text $text)

        $disk.encryption.kind | Should -Be 'filevault'
        $disk.encryption.protectionOn | Should -BeFalse
        @($disk.problems).Count | Should -Be 0
    }

    It 'reports an unknown FileVault state without guessing' {
        $text = @{ 'filevault-status' = $script:fvUnknownText; 'disk-info' = $script:diskInfoPlist }
        $disk = Get-TestSystemDisk -Platform 'macos' -Query (Get-TestQueryFake -Text $text)

        $disk.encryption.kind | Should -Be 'unknown'
        $disk.encryption.protectionOn | Should -BeNullOrEmpty
        (@($disk.problems) -join ' ') | Should -Match 'FileVault'
    }

    It 'reports a missing serial as null with a problem' {
        $text = @{ 'filevault-status' = $script:fvOnText; 'disk-info' = $script:diskInfoNoSerial }
        $disk = Get-TestSystemDisk -Platform 'macos' -Query (Get-TestQueryFake -Text $text)

        $disk.serial | Should -BeNullOrEmpty
        (@($disk.problems) -join ' ') | Should -Match 'serial'
    }

    It 'reports a failing disk-info query instead of inventing a disk' {
        $fake = {
            if ($args[0] -eq 'filevault-status') { return (Get-TestQueryResultFake -Value ([pscustomobject]@{ enabled = $true; state = 'On' })) }
            return (Get-TestQueryResultFake -Status 'error' -Message 'diskutil failed')
        }
        $disk = Get-TestSystemDisk -Platform 'macos' -Query $fake

        $disk.serial | Should -BeNullOrEmpty
        $disk.encryption.kind | Should -Be 'filevault'
        (@($disk.problems) -join ' ') | Should -Match 'disk info query returned status'
    }
}

Describe 'SystemDisk.ps1 static checks' {
    It 'contains no erase, reset, sanitize or key-erase call' {
        $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'src/Vacate/Private/SystemDisk.ps1'
        $text = [IO.File]::ReadAllText($path)
        $patterns = @(
            'systemreset\.exe',
            'diskutil\s+eraseDisk',
            'cryptsetup',
            'Invoke-CimMethod',
            'Start-Process',
            'Invoke-Expression',
            'DeletePermanently'
        )
        foreach ($pattern in $patterns) {
            $text | Should -Not -Match $pattern -Because "'$pattern' must never appear"
        }
    }
}
