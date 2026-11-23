BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-ReadinessReport {
        # A report.json as Invoke-VacateScan writes it, round-tripped through JSON like the real one.
        param(
            [string]$Machine = 'TESTBOX',
            [string]$Platform = 'windows',
            [object]$Complete = $true,
            [object]$Redacted = $false,
            [object]$FinishedAt = '2026-11-20T10:00:00Z',
            [object[]]$Traces = @()
        )
        $report = [ordered]@{
            tool  = [ordered]@{ name = 'vacate'; version = '0.1.0' }
            scan  = [ordered]@{
                platform   = $Platform
                finishedAt = $FinishedAt
                complete   = $Complete
                redacted   = $Redacted
                host       = [ordered]@{ name = $Machine }
            }
            traces = @($Traces)
        }
        return (($report | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
    }

    function Get-ReadinessTrace {
        param([string]$RuleId = 'wallet.test.data', [string]$Category = 'wallets')
        return [pscustomobject][ordered]@{ ruleId = $RuleId; category = $Category }
    }

    function Get-ReadinessDisk {
        # The shape Get-VacateSystemDisk returns.
        param(
            [object]$Serial = 'SN-0123456789',
            [object]$Model = 'TestDisk 9000',
            [object]$Kind = 'bitlocker',
            [object]$ProtectionOn = $true
        )
        return [pscustomobject][ordered]@{
            platform   = 'windows'
            model      = $Model
            serial     = $Serial
            sizeBytes  = 512110190592
            busType    = 'NVMe'
            osVolume   = 'C:'
            source     = 'cim'
            problems   = @()
            encryption = [pscustomobject][ordered]@{ kind = $Kind; protectionOn = $ProtectionOn; container = $null }
        }
    }

    function Invoke-Readiness {
        param(
            [object]$Report,
            [object]$Plan = $null,
            [switch]$NoPlan,
            [object]$Disk = $null,
            [switch]$NoDisk,
            [object]$Elevated = $true,
            [string]$Platform = 'windows',
            [string]$Machine = 'TESTBOX',
            [object]$Now = $null,
            [object]$WalletsBackedUp = $false,
            [object]$Virtualized = $false
        )
        if (-not $NoPlan -and $null -eq $Plan) { $Plan = [pscustomobject]@{ steps = @(); stages = @() } }
        if (-not $NoDisk -and $null -eq $Disk) { $Disk = Get-ReadinessDisk }
        if ($null -eq $Now) { $Now = [datetime]::SpecifyKind([datetime]'2026-11-20T12:00:00', [System.DateTimeKind]::Utc) }
        return InModuleScope Vacate -Parameters @{
            Rep = $Report; Pln = $Plan; Dsk = $Disk; Elv = [bool]$Elevated; Plt = $Platform
            Mch = $Machine; Nw = [datetime]$Now; Wbk = [bool]$WalletsBackedUp; Vrt = $Virtualized
        } {
            param($Rep, $Pln, $Dsk, $Elv, $Plt, $Mch, $Nw, $Wbk, $Vrt)
            Get-VacateEraseReadiness -Report $Rep -Plan $Pln -SystemDisk $Dsk -Elevated $Elv -Platform $Plt -Machine $Mch -Now $Nw -WalletsBackedUp $Wbk -Virtualized $Vrt
        }
    }

    function Get-ReadinessCheck {
        param([object]$Readiness, [string]$Id)
        return @($Readiness.checks | Where-Object { $_.id -ceq $Id })[0]
    }

    function Get-FailedBlockId {
        param([object]$Readiness)
        return @($Readiness.checks | Where-Object { $_.severity -ceq 'block' -and -not $_.ok } | ForEach-Object { $_.id })
    }

    $script:AlwaysManualWarnIds = @('account-sign-out', 'power')
}

Describe 'Get-VacateEraseReadiness' {
    It 'lists every check in the contract order with its severity' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -WalletsBackedUp $true
        @($readiness.PSObject.Properties.Name) | Should -Be @('ready', 'checks')
        @($readiness.checks.id) | Should -Be @(
            'elevated', 'same-platform', 'same-machine', 'not-redacted', 'scan-complete', 'scan-recent',
            'plan-present', 'disk-identified', 'disk-complete', 'not-virtualized', 'disk-encrypted', 'protection-on', 'wallets',
            'cloud-sync', 'account-sign-out', 'power'
        )
        @($readiness.checks[0].PSObject.Properties.Name) | Should -Be @('id', 'ok', 'severity', 'message')
        @($readiness.checks | Where-Object { $_.severity -ceq 'warn' } | ForEach-Object { $_.id }) |
            Should -Be @('cloud-sync', 'account-sign-out', 'power')
        foreach ($check in $readiness.checks) {
            $check.ok | Should -BeOfType [bool]
            $check.message | Should -Not -BeNullOrEmpty
        }
    }

    It 'is ready when every blocking check passes, whatever the warnings say' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -WalletsBackedUp $true
        $readiness.ready | Should -BeTrue
        @(Get-FailedBlockId -Readiness $readiness).Count | Should -Be 0
        # The manual steps are always listed and never pass on their own.
        foreach ($id in $script:AlwaysManualWarnIds) {
            $check = Get-ReadinessCheck -Readiness $readiness -Id $id
            $check.severity | Should -Be 'warn'
            $check.ok | Should -BeFalse
        }
    }

    It 'compares the machine name case-insensitively' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -Machine 'TestBox') -Machine 'TESTBOX'
        (Get-ReadinessCheck -Readiness $readiness -Id 'same-machine').ok | Should -BeTrue
        $readiness.ready | Should -BeTrue
    }

    It 'compares the platform case-insensitively' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -Platform 'Windows') -Platform 'windows'
        (Get-ReadinessCheck -Readiness $readiness -Id 'same-platform').ok | Should -BeTrue
        $readiness.ready | Should -BeTrue
    }

    It 'blocks when the session is not elevated' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -Elevated $false
        (Get-ReadinessCheck -Readiness $readiness -Id 'elevated').ok | Should -BeFalse
        (Get-ReadinessCheck -Readiness $readiness -Id 'elevated').severity | Should -Be 'block'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('elevated')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the report came from another platform' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -Platform 'macos') -Platform 'windows'
        $check = Get-ReadinessCheck -Readiness $readiness -Id 'same-platform'
        $check.ok | Should -BeFalse
        $check.message | Should -Match 'macos'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('same-platform')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the report came from another machine' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -Machine 'OTHERBOX')
        $check = Get-ReadinessCheck -Readiness $readiness -Id 'same-machine'
        $check.ok | Should -BeFalse
        $check.message | Should -Match 'OTHERBOX'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('same-machine')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the report is redacted' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -Redacted $true)
        (Get-ReadinessCheck -Readiness $readiness -Id 'not-redacted').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('not-redacted')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the scan did not finish' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -Complete $false)
        (Get-ReadinessCheck -Readiness $readiness -Id 'scan-complete').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('scan-complete')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the scan finished more than 24 hours ago' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -FinishedAt '2026-11-19T11:00:00Z')
        (Get-ReadinessCheck -Readiness $readiness -Id 'scan-recent').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('scan-recent')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks for <Name>' -TestCases @(
        @{ Name = 'a scan finished a moment ago'; FinishedAt = '2026-11-20T11:59:00Z'; Expected = $true }
        @{ Name = 'a scan finished 48 hours ago'; FinishedAt = '2026-11-18T12:00:00Z'; Expected = $false }
    ) {
        param($Name, $FinishedAt, $Expected)
        # -Now is 2026-11-20T12:00:00Z for every case.
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -FinishedAt $FinishedAt)
        $check = Get-ReadinessCheck -Readiness $readiness -Id 'scan-recent'
        $check.ok | Should -Be $Expected
        $readiness.ready | Should -Be $Expected
    }

    It 'keeps a scan finished exactly 24 hours ago recent' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -FinishedAt '2026-11-19T12:00:00Z')
        (Get-ReadinessCheck -Readiness $readiness -Id 'scan-recent').ok | Should -BeTrue
        $readiness.ready | Should -BeTrue
    }

    It 'blocks when the scan finished exactly 24 hours and 1 second ago' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -FinishedAt '2026-11-19T12:00:00Z') `
            -Now ([datetime]::SpecifyKind([datetime]'2026-11-20T12:00:01', [System.DateTimeKind]::Utc))
        (Get-ReadinessCheck -Readiness $readiness -Id 'scan-recent').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('scan-recent')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the scan time cannot be read' -TestCases @(
        @{ FinishedAt = $null }, @{ FinishedAt = '' }, @{ FinishedAt = 'yesterday' }
    ) {
        param($FinishedAt)
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport -FinishedAt $FinishedAt)
        (Get-ReadinessCheck -Readiness $readiness -Id 'scan-recent').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('scan-recent')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when this run has no plan' {
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -NoPlan -WalletsBackedUp $true
        (Get-ReadinessCheck -Readiness $readiness -Id 'plan-present').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('plan-present')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the system disk <Missing> cannot be read' -TestCases @(
        @{ Missing = 'serial'; Serial = $null; Model = 'TestDisk 9000' }
        @{ Missing = 'model'; Serial = 'SN-0123456789'; Model = $null }
        @{ Missing = 'serial and model'; Serial = $null; Model = $null }
        @{ Missing = 'serial (blank)'; Serial = '  '; Model = 'TestDisk 9000' }
    ) {
        param($Missing, $Serial, $Model)
        $disk = Get-ReadinessDisk -Serial $Serial -Model $Model
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -Disk $disk -WalletsBackedUp $true
        $check = Get-ReadinessCheck -Readiness $readiness -Id 'disk-identified'
        $check.ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('disk-identified')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the system disk is not encrypted (<Kind>)' -TestCases @(
        @{ Kind = 'none' }, @{ Kind = 'unknown' }, @{ Kind = '' }, @{ Kind = $null }, @{ Kind = 'bitlocker-suspended' }
    ) {
        param($Kind)
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -Disk (Get-ReadinessDisk -Kind $Kind) -WalletsBackedUp $true
        (Get-ReadinessCheck -Readiness $readiness -Id 'disk-encrypted').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('disk-encrypted')
        $readiness.ready | Should -BeFalse
    }

    It 'accepts <Kind> as encryption' -TestCases @(
        @{ Kind = 'bitlocker' }, @{ Kind = 'filevault' }, @{ Kind = 'luks' }, @{ Kind = 'BitLocker' }
    ) {
        param($Kind)
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -Disk (Get-ReadinessDisk -Kind $Kind) -WalletsBackedUp $true
        (Get-ReadinessCheck -Readiness $readiness -Id 'disk-encrypted').ok | Should -BeTrue
        $readiness.ready | Should -BeTrue
    }

    It 'blocks when encryption exists but protection is not on (<ProtectionOn>)' -TestCases @(
        @{ ProtectionOn = $false }, @{ ProtectionOn = $null }
    ) {
        param($ProtectionOn)
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -Disk (Get-ReadinessDisk -ProtectionOn $ProtectionOn) -WalletsBackedUp $true
        (Get-ReadinessCheck -Readiness $readiness -Id 'protection-on').ok | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('protection-on')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks when the report has wallet traces and the person has not confirmed a backup' {
        $report = Get-ReadinessReport -Traces @((Get-ReadinessTrace 'wallet.electrum.data' 'wallets'), (Get-ReadinessTrace 'wallet.exodus.data' 'wallets'))
        $readiness = Invoke-Readiness -Report $report
        $check = Get-ReadinessCheck -Readiness $readiness -Id 'wallets'
        $check.ok | Should -BeFalse
        $check.message | Should -Match '2 wallet'
        $check.message | Should -Match 'WalletsBackedUp'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('wallets')
        $readiness.ready | Should -BeFalse
    }

    It 'passes the wallet check with -WalletsBackedUp' {
        $report = Get-ReadinessReport -Traces @((Get-ReadinessTrace 'wallet.electrum.data' 'wallets'))
        $readiness = Invoke-Readiness -Report $report -WalletsBackedUp $true
        (Get-ReadinessCheck -Readiness $readiness -Id 'wallets').ok | Should -BeTrue
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @()
        $readiness.ready | Should -BeTrue
    }

    It 'passes the wallet check without -WalletsBackedUp when there are no wallet traces' {
        $report = Get-ReadinessReport -Traces @((Get-ReadinessTrace 'browser.chrome.history' 'browsers'))
        $readiness = Invoke-Readiness -Report $report
        (Get-ReadinessCheck -Readiness $readiness -Id 'wallets').ok | Should -BeTrue
        $readiness.ready | Should -BeTrue
    }

    It 'warns about cloud-sync traces without blocking the erase' {
        $report = Get-ReadinessReport -Traces @((Get-ReadinessTrace 'cloud.onedrive.folder' 'cloud-sync'))
        $readiness = Invoke-Readiness -Report $report -WalletsBackedUp $true
        $check = Get-ReadinessCheck -Readiness $readiness -Id 'cloud-sync'
        $check.ok | Should -BeFalse
        $check.severity | Should -Be 'warn'
        $check.message | Should -Match 'cloud'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @()
        $readiness.ready | Should -BeTrue
    }

    It 'never blocks on a warning, even when every warning is outstanding' {
        $report = Get-ReadinessReport -Traces @((Get-ReadinessTrace 'cloud.onedrive.folder' 'cloud-sync'))
        $readiness = Invoke-Readiness -Report $report -WalletsBackedUp $true
        @($readiness.checks | Where-Object { $_.severity -ceq 'warn' -and $_.ok }).Count | Should -Be 0
        $readiness.ready | Should -BeTrue
    }

    It 'blocks when a block check fails even if the warnings were resolved' {
        $report = Get-ReadinessReport -Traces @()
        $readiness = Invoke-Readiness -Report $report -WalletsBackedUp $true -Elevated $false
        $readiness.ready | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('elevated')
    }

    It 'does not throw on a report with no scan block' {
        $readiness = Invoke-Readiness -Report ([pscustomobject]@{}) -NoPlan -NoDisk -Elevated $false -Platform '' -Machine ''
        $readiness.ready | Should -BeFalse
        @(Get-FailedBlockId -Readiness $readiness) | Should -Contain 'same-platform'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Contain 'same-machine'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Contain 'scan-complete'
        @(Get-FailedBlockId -Readiness $readiness) | Should -Contain 'scan-recent'
        @($readiness.checks).Count | Should -Be 16
    }

    It 'blocks when the disk details are incomplete (disk-complete)' {
        $d = Get-ReadinessDisk
        $d.problems = @('BitLocker conversion status unknown')
        $readiness = Invoke-Readiness -Report (Get-ReadinessReport) -Disk $d
        @(Get-FailedBlockId -Readiness $readiness) | Should -Be @('disk-complete')
        $readiness.ready | Should -BeFalse
    }

    It 'blocks inside a VM or WSL, and when it cannot tell (not-virtualized)' {
        @(Get-FailedBlockId -Readiness (Invoke-Readiness -Report (Get-ReadinessReport) -Virtualized $true)) | Should -Be @('not-virtualized')
        @(Get-FailedBlockId -Readiness (Invoke-Readiness -Report (Get-ReadinessReport) -Virtualized $null)) | Should -Be @('not-virtualized')
        (Invoke-Readiness -Report (Get-ReadinessReport) -Virtualized $false).ready | Should -BeTrue
    }

    It 'treats an Apple internal SSD as hardware-encrypted on macOS even with FileVault off' {
        $d = Get-ReadinessDisk -Model 'APPLE SSD AP0512Z' -Kind 'filevault' -ProtectionOn $false
        $r = Invoke-Readiness -Report (Get-ReadinessReport -Platform 'macos') -Disk $d -Platform 'macos'
        (Get-ReadinessCheck -Readiness $r -Id 'disk-encrypted').ok | Should -BeTrue
        (Get-ReadinessCheck -Readiness $r -Id 'protection-on').ok | Should -BeTrue
        $w = Invoke-Readiness -Report (Get-ReadinessReport) -Disk (Get-ReadinessDisk -Model 'APPLE SSD AP0512Z' -Kind 'none' -ProtectionOn $false)
        (Get-ReadinessCheck -Readiness $w -Id 'disk-encrypted').ok | Should -BeFalse
    }
}