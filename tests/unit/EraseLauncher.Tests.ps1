# EraseLauncher.Tests.ps1 - the OS erase launcher. Every test uses a stub launcher (D57):
# nothing here ever starts systemreset.exe, open or cryptsetup.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    function Get-TestDisk {
        param([string]$Kind = 'luks', [object]$Container = '/dev/nvme0n1p3')
        return [pscustomobject]@{ model = 'Test Disk'; serial = 'SER123'; encryption = [pscustomobject]@{ kind = $Kind; protectionOn = $true; container = $Container } }
    }
    function Invoke-TestLaunch {
        param([string]$Platform, [object]$Disk, [object]$Result)
        $calls = New-Object System.Collections.Generic.List[object]
        $stub = { param($c) $calls.Add($c); return $Result }.GetNewClosure()
        $out = InModuleScope Vacate -Parameters @{ P = $Platform; D = $Disk; L = $stub } { param($P, $D, $L) Start-VacateOsErase -Platform $P -SystemDisk $D -Launcher $L }
        return [pscustomobject]@{ Out = $out; Calls = $calls }
    }
}

Describe 'Get-VacateEraseCommand' {
    It 'uses Reset this PC on Windows without waiting' {
        $c = InModuleScope Vacate { Get-VacateEraseCommand -Platform 'windows' -SystemDisk ([pscustomobject]@{ encryption = $null }) }
        # systemreset.exe where it exists; Settings > Recovery on Windows 11 24H2+ where it does not.
        if ([IO.File]::Exists('C:\Windows\System32\systemreset.exe')) {
            $c.Binary | Should -Be 'C:\Windows\System32\systemreset.exe'
            @($c.Arguments) -join ' ' | Should -Be '-factoryreset'
        }
        else {
            $c.Binary | Should -Be 'C:\Windows\explorer.exe'
            @($c.Arguments) -join ' ' | Should -Be 'ms-settings:recovery'
        }
        $c.Wait | Should -BeFalse
    }
    It 'opens the Transfer or Reset pane on macOS' {
        $c = InModuleScope Vacate { Get-VacateEraseCommand -Platform 'macos' -SystemDisk ([pscustomobject]@{ encryption = $null }) }
        $c.Binary | Should -Be '/usr/bin/open'
        @($c.Arguments)[0] | Should -Match 'Transfer-Reset'
    }
    It 'erases the LUKS key slots of the root container on Linux and waits' {
        $d = Get-TestDisk
        $c = InModuleScope Vacate -Parameters @{ D = $d } { param($D) Get-VacateEraseCommand -Platform 'linux' -SystemDisk $D }
        $c.Binary | Should -Be '/usr/sbin/cryptsetup'
        @($c.Arguments) -join ' ' | Should -Be 'luksErase --batch-mode /dev/nvme0n1p3'
        $c.Wait | Should -BeTrue
    }
    It 'refuses a Linux target <Why>' -ForEach @(
        @{ Why = 'with no container'; Container = $null; Kind = 'luks' }
        @{ Why = 'outside /dev'; Container = '/tmp/x'; Kind = 'luks' }
        @{ Why = 'with ..'; Container = '/dev/../etc/passwd'; Kind = 'luks' }
        @{ Why = 'with shell characters'; Container = '/dev/sda; rm'; Kind = 'luks' }
        @{ Why = 'that is not LUKS'; Container = '/dev/sda2'; Kind = 'none' }
    ) {
        $d = Get-TestDisk -Kind $Kind -Container $Container
        { InModuleScope Vacate -Parameters @{ D = $d } { param($D) Get-VacateEraseCommand -Platform 'linux' -SystemDisk $D } } | Should -Throw
    }
}

Describe 'Start-VacateOsErase' {
    It 'calls the launcher once and reports the method on Windows' {
        $r = Invoke-TestLaunch -Platform 'windows' -Disk (Get-TestDisk -Kind 'bitlocker' -Container $null) -Result ([pscustomobject]@{ started = $true; exitCode = $null })
        $r.Calls.Count | Should -Be 1
        $r.Out.started | Should -BeTrue
        $r.Out.method | Should -Be 'windows-reset-this-pc'
    }
    It 'reports success on Linux only for exit code 0' {
        $ok = Invoke-TestLaunch -Platform 'linux' -Disk (Get-TestDisk) -Result ([pscustomobject]@{ started = $true; exitCode = 0 })
        $ok.Out.started | Should -BeTrue
        $ok.Out.detail | Should -Match 'key slots erased'
        $bad = Invoke-TestLaunch -Platform 'linux' -Disk (Get-TestDisk) -Result ([pscustomobject]@{ started = $true; exitCode = 1 })
        $bad.Out.started | Should -BeFalse
        $bad.Out.detail | Should -Match 'code 1'
        $slow = Invoke-TestLaunch -Platform 'linux' -Disk (Get-TestDisk) -Result ([pscustomobject]@{ started = $true; exitCode = $null })
        $slow.Out.started | Should -BeFalse
    }
    It 'never calls the launcher for a refused Linux target' {
        $calls = New-Object System.Collections.Generic.List[object]
        $stub = { param($c) $calls.Add($c); return [pscustomobject]@{ started = $true; exitCode = 0 } }.GetNewClosure()
        $d = Get-TestDisk -Container '/tmp/not-a-device'
        { InModuleScope Vacate -Parameters @{ D = $d; L = $stub } { param($D, $L) Start-VacateOsErase -Platform 'linux' -SystemDisk $D -Launcher $L } } | Should -Throw
        $calls.Count | Should -Be 0
    }
}
