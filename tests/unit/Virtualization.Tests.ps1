# Virtualization.Tests.ps1 - VM / WSL / container detection for erase readiness. Fakes only.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    function Invoke-Virt {
        param([string]$Platform, [object]$Cim = $null, [object]$Disk = $null, [string]$Os = '', [hashtable]$Files = @{})
        $files = $Files
        $read = { param([string]$p) if ($files.ContainsKey($p)) { return $files[$p] } return $null }.GetNewClosure()
        return InModuleScope Vacate -Parameters @{ P = $Platform; C = $Cim; D = $Disk; O = $Os; R = $read } {
            param($P, $C, $D, $O, $R)
            $args2 = @{ Platform = $P; SystemDisk = $D; ReadSystemFile = $R }
            if ($null -ne $C) { $args2.CimRunner = $C }
            if ($O) { $args2.OsDescription = $O }
            Get-VacateVirtualization @args2
        }
    }
    function Get-FakeCim { param([string]$Manufacturer, [string]$Model)
        $m = $Manufacturer; $o = $Model
        return { param($ns, $cls, $props) [pscustomobject]@{ Manufacturer = $m; Model = $o } }.GetNewClosure()
    }
}

Describe 'Get-VacateVirtualization' {
    It 'Windows: <Text> -> <Expected>' -ForEach @(
        @{ Text = 'Dell Inc. XPS 15 9530'; Man = 'Dell Inc.'; Model = 'XPS 15 9530'; Expected = $false }
        @{ Text = 'Hyper-V VM'; Man = 'Microsoft Corporation'; Model = 'Virtual Machine'; Expected = $true }
        @{ Text = 'VMware'; Man = 'VMware, Inc.'; Model = 'VMware7,1'; Expected = $true }
        @{ Text = 'VirtualBox'; Man = 'innotek GmbH'; Model = 'VirtualBox'; Expected = $true }
    ) {
        (Invoke-Virt -Platform 'windows' -Cim (Get-FakeCim $Man $Model)).virtualized | Should -Be $Expected
    }
    It 'Windows without CIM is unknown' {
        (Invoke-Virt -Platform 'windows').virtualized | Should -BeNullOrEmpty
    }
    It 'Linux: WSL kernel is virtualized' {
        (Invoke-Virt -Platform 'linux' -Os 'Linux 5.15.167.4-microsoft-standard-WSL2').virtualized | Should -BeTrue
    }
    It 'Linux: container marker is virtualized' {
        (Invoke-Virt -Platform 'linux' -Os 'Linux 6.8.0' -Files @{ '/.dockerenv' = '' }).virtualized | Should -BeTrue
    }
    It 'Linux: QEMU DMI is virtualized, a laptop is not, no DMI is unknown' {
        (Invoke-Virt -Platform 'linux' -Os 'Linux 6.8.0' -Files @{ '/sys/class/dmi/id/sys_vendor' = 'QEMU'; '/sys/class/dmi/id/product_name' = 'Standard PC' }).virtualized | Should -BeTrue
        (Invoke-Virt -Platform 'linux' -Os 'Linux 6.8.0' -Files @{ '/sys/class/dmi/id/sys_vendor' = 'LENOVO'; '/sys/class/dmi/id/product_name' = '21HM' }).virtualized | Should -BeFalse
        (Invoke-Virt -Platform 'linux' -Os 'Linux 6.8.0').virtualized | Should -BeNullOrEmpty
    }
    It 'a hypervisor disk model is virtualized on any platform' {
        $d = [pscustomobject]@{ model = 'QEMU HARDDISK' }
        (Invoke-Virt -Platform 'macos' -Disk $d).virtualized | Should -BeTrue
        (Invoke-Virt -Platform 'linux' -Disk $d -Os 'Linux 6.8').virtualized | Should -BeTrue
    }
    It 'macOS: a real Apple disk model is not virtualized; unknown model is unknown' {
        (Invoke-Virt -Platform 'macos' -Disk ([pscustomobject]@{ model = 'APPLE SSD AP0512Z' })).virtualized | Should -BeFalse
        (Invoke-Virt -Platform 'macos' -Disk ([pscustomobject]@{ model = '' })).virtualized | Should -BeNullOrEmpty
    }
}
