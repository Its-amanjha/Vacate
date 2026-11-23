# LuksErase.Tests.ps1 - the only real erase allowed in Phase 4.
# PowerShell 5.1 compatible. ASCII only.
#
# D57: no code or test may run an erase against a real disk. This test builds a disposable
# LUKS container inside a loop FILE under /tmp (tests/helpers/LuksLoop.ps1), proves luksDump
# shows a key slot and that its key file opens the container, hands the loop device to
# Start-VacateOsErase as the fake system disk's encryption container, and proves afterwards
# that no key slot is left and the key no longer opens it. D54: the Linux erase is the LUKS
# key erase, which is why the container is the assertion target.
#
# It runs only on Linux as root with cryptsetup installed and always cleans up, even when an
# assertion fails. It never names a device it did not create.

Set-StrictMode -Version Latest

$script:container = $null
$script:wrongKeyFile = $null
$script:eraseCommand = $null

. (Join-Path $PSScriptRoot '../helpers/LuksLoop.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

BeforeDiscovery {
    # Pester 5 evaluates -Skip at discovery, before BeforeAll (D24).
    . (Join-Path $PSScriptRoot '../helpers/LuksLoop.ps1')
    $script:luksPrereq = Test-VacateLuksLoopPrerequisite
}

Describe 'LUKS key erase on a disposable loop file (D57)' -Skip:(-not $script:luksPrereq.available) {
    BeforeAll {
        . (Join-Path $PSScriptRoot '../helpers/LuksLoop.ps1')
        Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

        $script:container = New-VacateLuksLoopContainer -SizeMb 64

        # A second key file that must not open the container: the negative half of the
        # "the key opens it" proof, so a green result cannot come from a broken check.
        $script:wrongKeyFile = $script:container.keyFile + '.wrong'
        [IO.File]::WriteAllText($script:wrongKeyFile, [guid]::NewGuid().ToString('N'))

        # Fake system disk in the shape Get-VacateSystemDisk returns (D54, D55). Only the
        # encryption container matters here, and it is the loop device this test created.
        $script:fakeDisk = [pscustomobject][ordered]@{
            platform   = 'linux'
            model      = 'vacate disposable loop file'
            serial     = 'VACATE-LOOP-FILE'
            sizeBytes  = [int64](64 * 1MB)
            busType    = 'loop'
            osVolume   = '/'
            encryption = [pscustomobject][ordered]@{
                kind         = 'luks'
                protectionOn = $true
                container    = $script:container.loop
            }
            source     = 'tests/integration/LuksErase.Tests.ps1 (D57)'
            problems   = @()
        }

        # Start-VacateOsErase lives in Private/EraseLauncher.ps1 and the module exports only
        # Public/*, so look for it both outside and inside the module.
        $script:eraseCommand = Get-Command -Name 'Start-VacateOsErase' -ErrorAction SilentlyContinue
        if ($null -eq $script:eraseCommand) {
            $script:eraseCommand = InModuleScope Vacate { Get-Command -Name 'Start-VacateOsErase' -ErrorAction SilentlyContinue }
        }
    }

    AfterAll {
        # D57: the container never outlives the test.
        if ($null -ne $script:wrongKeyFile -and [IO.File]::Exists($script:wrongKeyFile)) {
            [IO.File]::Delete($script:wrongKeyFile)
        }
        if ($null -ne $script:container) {
            Remove-VacateLuksLoopContainer -Container $script:container
        }
        $script:container = $null
        $script:wrongKeyFile = $null
    }

    It 'builds a LUKS2 container in a loop file whose key slot and key file both check out (D57)' {
        $script:container.loop | Should -Match '^/dev/loop[0-9]+$'
        $script:container.file | Should -Match '^/tmp/vacate-luks-[0-9a-f]{32}\.img$'
        (Test-Path -LiteralPath $script:container.file) | Should -BeTrue
        (Test-Path -LiteralPath $script:container.keyFile) | Should -BeTrue

        # luksDump shows exactly one key slot.
        $slots = @(Get-VacateLuksKeySlotNumber -Device $script:container.loop)
        $slots.Count | Should -Be 1

        # The key opens it; a different key does not.
        (Test-VacateLuksKeyFile -Device $script:container.loop -KeyFile $script:container.keyFile) | Should -BeTrue
        (Test-VacateLuksKeyFile -Device $script:container.loop -KeyFile $script:wrongKeyFile) | Should -BeFalse
    }

    It 'erases every key slot through Start-VacateOsErase and the key stops working (D54, D57)' {
        if ($null -eq $script:eraseCommand) {
            Set-ItResult -Skipped -Because 'Start-VacateOsErase does not exist in this worktree yet (Private/EraseLauncher.ps1, D54); the key-erase assertions run as soon as it lands'
            return
        }

        $result = $null
        if ($null -ne (Get-Command -Name 'Start-VacateOsErase' -ErrorAction SilentlyContinue)) {
            $result = Start-VacateOsErase -Platform 'linux' -SystemDisk $script:fakeDisk
        }
        else {
            $result = InModuleScope Vacate -Parameters @{ Disk = $script:fakeDisk } {
                param($Disk) Start-VacateOsErase -Platform 'linux' -SystemDisk $Disk
            }
        }

        $result.started | Should -BeTrue
        $result.method | Should -Be 'linux-luks-key-erase'

        # Proof of the erase: no key slot left, and the key file no longer opens the container.
        @(Get-VacateLuksKeySlotNumber -Device $script:container.loop).Count | Should -Be 0
        (Test-VacateLuksKeyFile -Device $script:container.loop -KeyFile $script:container.keyFile) | Should -BeFalse
    }
}
