# Host info tests. CIM and system queries are faked; nothing is read from the real machine.
# Pester 5 runs It bodies in a scope that does not see the file body, so helpers live in BeforeAll.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestProfile {
        param([string]$Name = 'windows')
        $comparison = [StringComparison]::OrdinalIgnoreCase
        $separator = [char]'\'
        if ($Name -ne 'windows') {
            $comparison = [StringComparison]::Ordinal
            $separator = [char]'/'
        }
        return [pscustomobject][ordered]@{
            Name          = $Name
            CaseSensitive = ($Name -ne 'windows')
            Comparison    = $comparison
            Separator     = $separator
            Roots         = [ordered]@{}
            HomePath      = ''
            UsersRoot     = ''
            UserName      = 'ann'
        }
    }

    function Get-TestContext {
        param([object]$Cim = $null, [object]$SystemQuery = $null, [string]$Platform = 'windows')
        return [pscustomobject][ordered]@{
            Platform    = (Get-TestProfile -Name $Platform)
            FileSystem  = $null
            Registry    = $null
            Cim         = $Cim
            SystemQuery = $SystemQuery
            Elevated    = $false
            MountPoints = @()
            Exclude     = @()
        }
    }

    function Get-TestHostInfo {
        param([object]$Context, [hashtable]$Environment = @{})
        return (InModuleScope Vacate -Parameters @{ C = $Context; E = $Environment } {
                param($C, $E)
                Get-VacateHostInfo -Context $C -Environment $E
            })
    }

    function Get-TestMountsResult {
        param([string]$Status = 'ok', [object]$Value = $null)
        return [pscustomobject][ordered]@{ Name = 'mounts'; Status = $Status; Value = $Value; Message = $null }
    }
}

Describe 'Get-VacateHostInfo' {
    It 'reports the machine, the operating system and the user on Windows' {
        $cim = {
            param($Namespace, $ClassName, $Property)
            # The host reader must name a namespace and a property list, never a WQL string.
            if ($Namespace -ne 'root/CIMV2' -or @($Property).Count -eq 0) { throw 'unexpected CIM request' }
            if ($ClassName -eq 'Win32_OperatingSystem') {
                return @([pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100' })
            }
            return @(
                [pscustomobject]@{ DeviceID = 'C:'; FileSystem = 'NTFS'; Size = 500000000000; FreeSpace = 100000000000; DriveType = 3 },
                [pscustomobject]@{ DeviceID = 'D:'; FileSystem = 'NTFS'; Size = 1000; FreeSpace = 500; DriveType = 2 }
            )
        }
        $context = Get-TestContext -Cim $cim -Platform 'windows'

        $hostInfo = Get-TestHostInfo -Context $context -Environment @{ USERNAME = 'ann' }

        $hostInfo.name | Should -Be ([Environment]::MachineName)
        $hostInfo.os | Should -Be 'Microsoft Windows 11 Pro'
        $hostInfo.version | Should -Be '10.0.26100'
        $hostInfo.architecture | Should -Be ([string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture)
        $hostInfo.user | Should -Be 'ann'
        @($hostInfo.volumes).Count | Should -Be 1
        $hostInfo.volumes[0].name | Should -Be 'C:'
        $hostInfo.volumes[0].fileSystem | Should -Be 'NTFS'
        $hostInfo.volumes[0].sizeBytes | Should -Be 500000000000
        $hostInfo.volumes[0].freeBytes | Should -Be 100000000000
    }

    It 'always returns the schema fields in schema order' {
        $hostInfo = Get-TestHostInfo -Context (Get-TestContext -Platform 'linux')
        @($hostInfo.PSObject.Properties.Name) | Should -Be @('name', 'os', 'version', 'architecture', 'user', 'volumes')
    }

    It 'keeps text fields as strings when nothing is known' {
        $cim = { return @() }
        $hostInfo = Get-TestHostInfo -Context (Get-TestContext -Cim $cim -Platform 'windows') -Environment @{}

        $hostInfo.os | Should -BeOfType [string]
        $hostInfo.os | Should -Be ''
        $hostInfo.version | Should -BeOfType [string]
        $hostInfo.user | Should -BeOfType [string]
        $hostInfo.user | Should -Be ''
        @($hostInfo.volumes).Count | Should -Be 0
    }

    It 'survives a failing operating system query' {
        $cim = { throw 'Access is denied.' }
        $hostInfo = Get-TestHostInfo -Context (Get-TestContext -Cim $cim -Platform 'windows') -Environment @{ USERNAME = 'ann' }

        $hostInfo.os | Should -Be ''
        $hostInfo.version | Should -Be ''
        @($hostInfo.volumes).Count | Should -Be 0
        $hostInfo.user | Should -Be 'ann'
    }

    It 'reports the running operating system on Linux' {
        $mounts = @(
            [pscustomobject][ordered]@{ target = '/'; source = '/dev/sda1'; fstype = 'ext4' },
            [pscustomobject][ordered]@{ target = '/boot/efi'; source = '/dev/sda2'; fstype = 'vfat' }
        )
        $runner = { return (Get-TestMountsResult -Value $mounts) }
        $context = Get-TestContext -SystemQuery $runner -Platform 'linux'

        $hostInfo = Get-TestHostInfo -Context $context -Environment @{ USER = 'ann' }

        # The runtime description can carry a trailing space; the host field is trimmed.
        $hostInfo.os | Should -Be (([string][Runtime.InteropServices.RuntimeInformation]::OSDescription).Trim())
        $hostInfo.os | Should -Not -Match '^\s|\s$'
        $hostInfo.version | Should -Be ([Environment]::OSVersion.Version.ToString())
        $hostInfo.user | Should -Be 'ann'
        @($hostInfo.volumes).Count | Should -Be 2
        $hostInfo.volumes[0].name | Should -Be '/'
        $hostInfo.volumes[0].fileSystem | Should -Be 'ext4'
        $hostInfo.volumes[0].sizeBytes | Should -BeNullOrEmpty
        $hostInfo.volumes[1].name | Should -Be '/boot/efi'
        $hostInfo.volumes[1].freeBytes | Should -BeNullOrEmpty
    }

    It 'reports no volumes when the mount query cannot run' {
        $runner = { return (Get-TestMountsResult -Status 'unavailable') }
        $hostInfo = Get-TestHostInfo -Context (Get-TestContext -SystemQuery $runner -Platform 'linux') -Environment @{}

        @($hostInfo.volumes).Count | Should -Be 0
        $hostInfo.os | Should -Not -BeNullOrEmpty
    }

    It 'reports no volumes when the mount query fails' {
        $runner = { throw 'findmnt failed' }
        $hostInfo = Get-TestHostInfo -Context (Get-TestContext -SystemQuery $runner -Platform 'linux') -Environment @{}

        @($hostInfo.volumes).Count | Should -Be 0
    }

    It 'falls back through the user variable names in order' {
        $context = Get-TestContext -Platform 'linux'

        (Get-TestHostInfo -Context $context -Environment @{ USER = 'second'; LOGNAME = 'third' }).user | Should -Be 'second'
        (Get-TestHostInfo -Context $context -Environment @{ LOGNAME = 'third' }).user | Should -Be 'third'
        (Get-TestHostInfo -Context $context -Environment @{ USERNAME = 'first'; USER = 'second' }).user | Should -Be 'first'
    }
}