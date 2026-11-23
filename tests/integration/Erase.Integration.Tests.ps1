# Erase.Integration.Tests.ps1 - Phase 4 erase integration tests (DECISIONS D54-D57).
# PowerShell 5.1 compatible. ASCII only.
# These are contract tests written before Invoke-VacateErase exists: the whole file skips until
# that function is exported. D57: nothing here can start a real erase. The disk comes from
# -SystemDisk, the launch from -Launcher (a recording stub), the elevation answer from -Elevated,
# and the typed YES is replaced by -SkipTypedConfirm because typing is a CLI step.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

BeforeDiscovery {
    $script:HasErase = [bool](Get-Command Invoke-VacateErase -ErrorAction SilentlyContinue)
}

Describe 'Vacate Erase Integration' -Skip:(-not $script:HasErase) {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

        $script:platform = InModuleScope Vacate { Get-VacatePlatform }
        $script:machine = [Environment]::MachineName
        $script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('vacate-erase-' + [guid]::NewGuid().ToString('N'))
        $script:runsRoot = Join-Path $script:tempRoot 'runs'
        [void][IO.Directory]::CreateDirectory($script:runsRoot)

        # The erase method and the disk encryption kind follow the platform (D54).
        if ($script:platform -ceq 'windows') {
            $script:encryptionKind = 'bitlocker'
            $script:eraseMethod = 'windows-reset-this-pc'
            $script:otherVolumeRoot = 'Z:'
        }
        elseif ($script:platform -ceq 'macos') {
            $script:encryptionKind = 'filevault'
            $script:eraseMethod = 'macos-erase-all-content-and-settings'
            $script:otherVolumeRoot = '/Volumes/VacateTestOther'
        }
        else {
            $script:encryptionKind = 'luks'
            $script:eraseMethod = 'linux-luks-key-erase'
            $script:otherVolumeRoot = '/mnt/vacate-test-other-volume'
        }

        $script:launcherCalls = New-Object System.Collections.Generic.List[object]
        $script:launcherSawRecord = $false
        $script:launcherRunDir = $null
        $script:launcherRecordTo = $null

        function script:Get-TestEraseRule {
            # A valid rule shape for report/plan fixtures; not a real rule (no rule files needed).
            param([string]$Id, [string]$Category)
            $sensitivity = 'medium'
            if ($Category -ceq 'wallets') { $sensitivity = 'critical' }
            return [pscustomobject][ordered]@{
                id                = $Id
                platforms         = @($script:platform)
                category          = $Category
                title             = 'Erase integration test fixture'
                whyItMatters      = 'Phase 4 integration test fixture, not a real rule.'
                sensitivity       = $sensitivity
                locator           = [pscustomobject][ordered]@{ kind = 'path'; root = 'HOME'; path = 'fixture/item'; match = 'files'; recurse = $false }
                measure           = @('exists', 'sizeBytes')
                maxEntries        = 10
                requiresElevation = $false
                verifiedOn        = @()
                verified          = $false
                source            = 'Phase 4 integration test fixture: https://example.com'
                notes             = $null
            }
        }

        function script:Get-TestErasePath {
            param([string]$Name)
            if ($script:platform -ceq 'windows') { return ('C:\Users\tester\' + $Name) }
            return ('/home/tester/' + $Name)
        }

        function script:Get-TestEraseDisk {
            # Get-VacateSystemDisk output shape, faked (D57: tests never read the real disk).
            param(
                [string]$Kind = $script:encryptionKind,
                [bool]$ProtectionOn = $true,
                [string]$Serial = 'TEST-SERIAL-0001',
                [object]$Model = 'Vacate Test Disk',
                [string]$OsVolume = $script:otherVolumeRoot
            )
            $container = $null
            if ($Kind -ceq 'luks') { $container = '/dev/mapper/vacate-test-root' }
            return [pscustomobject][ordered]@{
                platform   = $script:platform
                model      = $Model
                serial     = $Serial
                sizeBytes  = [long]1000000000000
                busType    = 'NVMe'
                osVolume   = $OsVolume
                encryption = [pscustomobject][ordered]@{ kind = $Kind; protectionOn = $ProtectionOn; container = $container }
                source     = 'test-fixture'
                problems   = @()
            }
        }

        function script:Get-TestVolumeRoot {
            # Drive letter form on Windows ('C:'), mount root on POSIX ('/').
            param([string]$Path)
            $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
            if ($root.Length -gt 1) { return $root.TrimEnd([char[]]@([char]'\', [char]'/')) }
            return $root
        }

        function script:New-TestEraseRun {
            # A run folder with a fake report.json and plan.json, built through the real
            # constructors like the clean integration tests do.
            [CmdletBinding()]
            param(
                [switch]$Redact,
                [switch]$WalletTrace,
                [switch]$CloudTrace,
                [int]$AgeHours = 0,
                [switch]$IncompleteScan,
                [switch]$NoPlan
            )

            $runDir = Join-Path $script:runsRoot ('run-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($runDir)

            $rules = @(
                (Get-TestEraseRule -Id 'erase.test.activity' -Category 'activity'),
                (Get-TestEraseRule -Id 'erase.test.cloud' -Category 'cloud-sync'),
                (Get-TestEraseRule -Id 'erase.test.wallet' -Category 'wallets')
            )

            $traces = InModuleScope Vacate -Parameters @{
                Rules        = $rules
                P            = $script:platform
                Wallet       = [bool]$WalletTrace
                Cloud        = [bool]$CloudTrace
                ActivityPath = (Get-TestErasePath 'activity.txt')
                WalletPath   = (Get-TestErasePath 'wallet.dat')
                CloudPath    = (Get-TestErasePath 'Cloud')
            } {
                param($Rules, $P, $Wallet, $Cloud, $ActivityPath, $WalletPath, $CloudPath)
                $list = New-Object System.Collections.Generic.List[object]
                $list.Add((New-VacateTrace -Rule $Rules[0] -Platform $P -Resolved $ActivityPath -SizeBytes 1024))
                if ($Cloud) { $list.Add((New-VacateTrace -Rule $Rules[1] -Platform $P -Resolved $CloudPath -ItemCount 3)) }
                if ($Wallet) { $list.Add((New-VacateTrace -Rule $Rules[2] -Platform $P -Resolved $WalletPath -SizeBytes 2048)) }
                return $list.ToArray()
            }

            $skips = @()
            if ($IncompleteScan) {
                # A budget skip makes report.scan.complete false (scan-complete is a block).
                $skips = @(InModuleScope Vacate { New-VacateSkip -RuleId 'erase.test.activity' -Reason 'budget' })
            }

            $engineResult = [pscustomobject][ordered]@{
                Traces   = @($traces)
                Skips    = @($skips)
                Errors   = @()
                Programs = @()
                Log      = @()
            }
            $finished = [datetime]::UtcNow.AddHours(-$AgeHours)
            $started = $finished.AddMinutes(-1)
            $hostInfo = [pscustomobject][ordered]@{
                name = $script:machine; os = 'TestOS'; version = '1.0'; architecture = 'X64'; user = 'tester'; volumes = @()
            }

            $report = InModuleScope Vacate -Parameters @{
                ER = $engineResult; R = $rules; P = $script:platform; H = $hostInfo
                S = $started; F = $finished; Red = [bool]$Redact
            } {
                param($ER, $R, $P, $H, $S, $F, $Red)
                $rep = New-VacateReport -EngineResult $ER -Rules $R -NotApplicable 0 -InvalidFiles 0 -Platform $P -HostInfo $H -StartedAt $S -FinishedAt $F -Elevated:$false -BudgetSeconds 30 -RuleTimeoutSeconds 5
                if ($Red) { $rep = Protect-VacateReport -Report $rep }
                return $rep
            }

            $reportJson = InModuleScope Vacate -Parameters @{ Rep = $report } { param($Rep) ConvertTo-VacateReportJson -Report $Rep }
            [IO.File]::WriteAllText((Join-Path $runDir 'report.json'), $reportJson, (New-Object Text.UTF8Encoding $false))

            if (-not $NoPlan) {
                $plan = InModuleScope Vacate -Parameters @{ Rep = $report; R = $rules; N = [datetime]::UtcNow } {
                    param($Rep, $R, $N) New-VacatePlan -Report $Rep -Rules $R -Now $N
                }
                $planJson = InModuleScope Vacate -Parameters @{ Pl = $plan } { param($Pl) ConvertTo-VacateReportJson -Report $Pl }
                [IO.File]::WriteAllText((Join-Path $runDir 'plan.json'), $planJson, (New-Object Text.UTF8Encoding $false))
            }

            return $runDir
        }

        function script:Get-TestRecordDir {
            $path = Join-Path $script:tempRoot ('record-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($path)
            return $path
        }

        function script:Get-TestLauncher {
            # Records each launch and checks the erase record is already in both places (D56).
            return {
                param($Platform, $SystemDisk)
                $serial = ''
                if ($null -ne $SystemDisk) { $serial = [string]$SystemDisk.serial }
                [void]$script:launcherCalls.Add([pscustomobject][ordered]@{ platform = $Platform; serial = $serial })

                $script:launcherSawRecord = $false
                if (-not [string]::IsNullOrEmpty($script:launcherRunDir) -and -not [string]::IsNullOrEmpty($script:launcherRecordTo)) {
                    $script:launcherSawRecord = ([IO.File]::Exists((Join-Path $script:launcherRunDir 'erase-record.json')) -and
                        [IO.File]::Exists((Join-Path $script:launcherRunDir 'erase-record.md')) -and
                        (@(Get-ChildItem -LiteralPath $script:launcherRecordTo -Filter 'vacate-erase-record-*.json').Count -eq 1) -and
                        (@(Get-ChildItem -LiteralPath $script:launcherRecordTo -Filter 'vacate-erase-record-*.md').Count -eq 1))
                }

                return [pscustomobject][ordered]@{
                    started  = $true
                    # Exit code 0 so the Linux path (which waits for cryptsetup) reports success.
                    exitCode = 0
                    method   = 'stub'
                    detail  = 'stub launcher; no erase was started (D57)'
                }
            }
        }

        function script:Reset-TestLauncher {
            $script:launcherCalls.Clear()
            $script:launcherSawRecord = $false
            $script:launcherRunDir = $null
            $script:launcherRecordTo = $null
        }

        function script:Test-EraseRecordAbsent {
            param([string]$Run, [string]$RecordTo)
            [IO.File]::Exists((Join-Path $Run 'erase-record.json')) | Should -BeFalse
            [IO.File]::Exists((Join-Path $Run 'erase-record.md')) | Should -BeFalse
            if (-not [string]::IsNullOrEmpty($RecordTo)) {
                @(Get-ChildItem -LiteralPath $RecordTo -Filter '*erase-record*' -ErrorAction SilentlyContinue).Count | Should -Be 0
                }
        }

        function script:Read-TestEraseRecord {
            param([string]$Path)
            $json = [IO.File]::ReadAllText($Path)
            return (InModuleScope Vacate -Parameters @{ J = $json } { param($J) ConvertFrom-VacateJson -Json $J })
        }

        function script:Get-TestEraseRecordValidation {
            param([string]$Path)
            $json = [IO.File]::ReadAllText($Path)
            return (InModuleScope Vacate -Parameters @{ J = $json } { param($J) Test-VacateEraseRecord -Json $J })
        }

        $script:disk = Get-TestEraseDisk
    }

    AfterAll {
        if ([IO.Directory]::Exists($script:tempRoot)) {
            try { [IO.Directory]::Delete($script:tempRoot, $true) } catch { $null = $_ }
        }
    }

    Context 'Dry run (D55)' {
        It 'writes erase-readiness.md and never starts the launcher' {
            $runDir = New-TestEraseRun
            Reset-TestLauncher

            Invoke-VacateErase -Run $runDir -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher)

            $script:launcherCalls.Count | Should -Be 0
            $readinessPath = Join-Path $runDir 'erase-readiness.md'
            (Test-Path -LiteralPath $readinessPath -PathType Leaf) | Should -BeTrue
            ([IO.File]::ReadAllText($readinessPath)).Length | Should -BeGreaterThan 0
            Test-EraseRecordAbsent -Run $runDir
        }
    }

    Context 'Execute gate refusals (D55)' {
        It 'refuses without an elevated session' {
            $runDir = New-TestEraseRun
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$false -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses when -Confirm is not this machine name' {
            $runDir = New-TestEraseRun
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm 'DEFINITELY-NOT-THIS-MACHINE-99' -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses when -DiskSerial is not the system disk serial' {
            $runDir = New-TestEraseRun
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial 'NOT-THE-SYSTEM-DISK-SERIAL' -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses when the system disk is not encrypted' {
            $runDir = New-TestEraseRun
            $recordTo = Get-TestRecordDir
            $disk = Get-TestEraseDisk -Kind 'none'
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses when encryption is present but protection is off' {
            $runDir = New-TestEraseRun
            $recordTo = Get-TestRecordDir
            $disk = Get-TestEraseDisk -ProtectionOn $false
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses a redacted run' {
            $runDir = New-TestEraseRun -Redact
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses a scan older than 24 hours' {
            $runDir = New-TestEraseRun -AgeHours 25
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses an incomplete scan' {
            $runDir = New-TestEraseRun -IncompleteScan
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses a run without plan.json' {
            $runDir = New-TestEraseRun -NoPlan
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses wallets unless -WalletsBackedUp is given' {
            $runDir = New-TestEraseRun -WalletTrace
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }

        It 'refuses when -RecordTo does not exist' {
            $runDir = New-TestEraseRun
            $missing = Join-Path $script:tempRoot ('missing-' + [guid]::NewGuid().ToString('N'))
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $missing -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            [IO.Directory]::Exists($missing) | Should -BeFalse
            Test-EraseRecordAbsent -Run $runDir
        }

        It 'refuses -RecordTo on the same volume as the system disk' {
            $runDir = New-TestEraseRun
            $recordTo = Get-TestRecordDir
            $disk = Get-TestEraseDisk -OsVolume (Get-TestVolumeRoot -Path $recordTo)
            Reset-TestLauncher

            { Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $disk -Virtualized $false -Launcher (Get-TestLauncher) } | Should -Throw

            $script:launcherCalls.Count | Should -Be 0
            Test-EraseRecordAbsent -Run $runDir -RecordTo $recordTo
        }
    }

    Context 'Erase record before the launch (D56)' {
        It 'writes and validates the erase record in the run folder and -RecordTo before launching' {
            $runDir = New-TestEraseRun -CloudTrace
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher
            $script:launcherRunDir = $runDir
            $script:launcherRecordTo = $recordTo

            Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $script:disk.serial -RecordTo $recordTo -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher)

            $script:launcherCalls.Count | Should -Be 1
            $script:launcherSawRecord | Should -BeTrue

            $runJson = Join-Path $runDir 'erase-record.json'
            # The -RecordTo copy has a dated name so several machines' records can share one USB stick.
            $toJson = @(Get-ChildItem -LiteralPath $recordTo -Filter 'vacate-erase-record-*.json')[0].FullName
            (Test-Path -LiteralPath $runJson -PathType Leaf) | Should -BeTrue
            (Test-Path -LiteralPath $toJson -PathType Leaf) | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $runDir 'erase-record.md') -PathType Leaf) | Should -BeTrue
            @(Get-ChildItem -LiteralPath $recordTo -Filter 'vacate-erase-record-*.md').Count | Should -Be 1
            [IO.File]::ReadAllText($runJson) | Should -Be ([IO.File]::ReadAllText($toJson))

            $check = Get-TestEraseRecordValidation -Path $toJson
            ([bool]$check.valid) | Should -BeTrue
            @($check.problems).Count | Should -Be 0

            $record = Read-TestEraseRecord -Path $toJson
            ([string]$record.kind) | Should -Be 'vacate-erase-record'
            ([bool]$record.signed) | Should -BeFalse
            ([string]$record.machine) | Should -Be $script:machine
            ([string]$record.method) | Should -Be $script:eraseMethod
            ([string]$record.disk.serial) | Should -Be $script:disk.serial
            ([string]$record.encryption.kind) | Should -Be $script:encryptionKind
            ([string]$record.createdAt).Length | Should -BeGreaterThan 0
            ([string]$record.standard) | Should -Match 'NIST SP 800-88'
            ([string]$record.sha256).Length | Should -Be 64

            # Every check is recorded; no block check may still be failing in a launched erase.
            @($record.readiness).Count | Should -BeGreaterThan 0
            @($record.readiness | Where-Object { [string]$_.id -ceq 'disk-encrypted' -and [bool]$_.ok }).Count | Should -Be 1
            @($record.readiness | Where-Object { [bool]$_.ok -eq $false -and [string]$_.severity -ceq 'block' }).Count | Should -Be 0
        }

        It 'accepts wallets once -WalletsBackedUp is given and trims/cases the disk serial' {
            $runDir = New-TestEraseRun -WalletTrace
            $recordTo = Get-TestRecordDir
            Reset-TestLauncher
            $script:launcherRunDir = $runDir
            $script:launcherRecordTo = $recordTo
            $serial = '  ' + $script:disk.serial.ToLowerInvariant() + '  '

            Invoke-VacateErase -Run $runDir -Execute -Confirm $script:machine -DiskSerial $serial -RecordTo $recordTo -WalletsBackedUp -Elevated:$true -SkipTypedConfirm -SystemDisk $script:disk -Virtualized $false -Launcher (Get-TestLauncher)

            $script:launcherCalls.Count | Should -Be 1
            $script:launcherSawRecord | Should -BeTrue

            # The -RecordTo copy has a dated name so several machines' records can share one USB stick.
            $toJson = @(Get-ChildItem -LiteralPath $recordTo -Filter 'vacate-erase-record-*.json')[0].FullName
            $check = Get-TestEraseRecordValidation -Path $toJson
            ([bool]$check.valid) | Should -BeTrue

            $record = Read-TestEraseRecord -Path $toJson
            # The record keeps the disk's own serial, not the typed, lower-cased copy.
            ([string]$record.disk.serial) | Should -Be $script:disk.serial
            @($record.readiness | Where-Object { [string]$_.id -ceq 'wallets' -and [bool]$_.ok }).Count | Should -Be 1
        }
    }
}
