BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:EraseRecordSchemaPath = Join-Path $PSScriptRoot '../../schemas/erase-record.schema.json'

    function Get-EraseRecordTestDisk {
        param(
            [string]$Platform = 'windows',
            [string]$Model = 'Samsung SSD 980 PRO 1TB',
            [string]$Serial = 'S5GXNF0R123456',
            [long]$SizeBytes = 1000204886016,
            [string]$BusType = 'NVMe',
            [string]$EncKind = 'bitlocker',
            [object]$ProtectionOn = $true
        )
        return [pscustomobject][ordered]@{
            platform   = $Platform
            model      = $Model
            serial     = $Serial
            sizeBytes  = $SizeBytes
            busType    = $BusType
            osVolume   = 'C:'
            encryption = [pscustomobject][ordered]@{
                kind         = $EncKind
                protectionOn = $ProtectionOn
                container    = $null
            }
            source     = 'CIM Win32_DiskDrive'
            problems   = @()
        }
    }

    function Get-EraseRecordTestReport {
        param(
            [string]$Platform = 'windows',
            [string]$Machine = 'WORKSTATION-01',
            [int]$TraceCount = 5
        )
        $traces = @(1..$TraceCount | ForEach-Object {
            [pscustomobject][ordered]@{
                ruleId   = "test.rule.$_"
                platform = $Platform
            }
        })
        return [pscustomobject][ordered]@{
            tool  = [pscustomobject][ordered]@{ name = 'vacate'; version = '0.1.0' }
            scan  = [pscustomobject][ordered]@{
                platform   = $Platform
                finishedAt = '2026-11-23T20:00:00Z'
                complete   = $true
                redacted   = $false
                host       = [pscustomobject][ordered]@{
                    name         = $Machine
                    os           = 'Microsoft Windows 11 Pro'
                    version      = '10.0.26100'
                    architecture = 'X64'
                    user         = 'operator1'
                    volumes      = @()
                }
            }
            traces = $traces
        }
    }

    function Get-EraseRecordTestReadiness {
        param([bool]$Ready = $true)
        $checks = @(
            [pscustomobject][ordered]@{ id = 'elevated'; ok = $true; severity = 'block'; message = 'Elevated session verified.' }
            [pscustomobject][ordered]@{ id = 'same-platform'; ok = $true; severity = 'block'; message = 'Platform matches scan.' }
            [pscustomobject][ordered]@{ id = 'same-machine'; ok = $true; severity = 'block'; message = 'Machine matches scan.' }
            [pscustomobject][ordered]@{ id = 'not-redacted'; ok = $true; severity = 'block'; message = 'Report is unredacted.' }
            [pscustomobject][ordered]@{ id = 'scan-complete'; ok = $true; severity = 'block'; message = 'Scan finished completely.' }
            [pscustomobject][ordered]@{ id = 'scan-recent'; ok = $true; severity = 'block'; message = 'Scan is within 24h.' }
            [pscustomobject][ordered]@{ id = 'plan-present'; ok = $true; severity = 'block'; message = 'Cleanup plan is present.' }
            [pscustomobject][ordered]@{ id = 'disk-identified'; ok = $true; severity = 'block'; message = 'Disk identified.' }
            [pscustomobject][ordered]@{ id = 'disk-encrypted'; ok = $true; severity = 'block'; message = 'Disk is BitLocker encrypted.' }
            [pscustomobject][ordered]@{ id = 'protection-on'; ok = $true; severity = 'block'; message = 'Protection is enabled.' }
            [pscustomobject][ordered]@{ id = 'wallets'; ok = $true; severity = 'block'; message = 'No unconfirmed wallet traces.' }
            [pscustomobject][ordered]@{ id = 'cloud-sync'; ok = $true; severity = 'warn'; message = 'Cloud sync traces detected.' }
            [pscustomobject][ordered]@{ id = 'account-sign-out'; ok = $true; severity = 'warn'; message = 'Manual sign-out required.' }
            [pscustomobject][ordered]@{ id = 'power'; ok = $true; severity = 'warn'; message = 'Mains power connected.' }
        )
        return [pscustomobject][ordered]@{
            ready  = $Ready
            checks = $checks
        }
    }

    function Test-EraseRecordSchemaSkipped {
        # Test-Json -SchemaFile requires PowerShell 7 (same pattern as PlanSchema.Tests.ps1).
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Test-Json requires PowerShell 7'
            return $true
        }
        return $false
    }
}

Describe 'EraseRecord construction and canonical serialization' {
    It 'creates an erase record with all required fields in the exact contract order' {
        $report = Get-EraseRecordTestReport
        $disk = Get-EraseRecordTestDisk
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        $record = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'WORKSTATION-01' -Operator 'admin' -Now $N
        }

        $record.schemaVersion | Should -Be '1.0'
        $record.kind | Should -Be 'vacate-erase-record'
        $record.signed | Should -BeFalse
        $record.tool.name | Should -Be 'vacate'
        $record.createdAt | Should -Be '2026-11-23T22:00:00Z'
        $record.machine | Should -Be 'WORKSTATION-01'
        $record.operator | Should -Be 'admin'
        $record.platform | Should -Be 'windows'
        $record.os.name | Should -Be 'Microsoft Windows 11 Pro'
        $record.os.version | Should -Be '10.0.26100'
        $record.disk.model | Should -Be 'Samsung SSD 980 PRO 1TB'
        $record.disk.serial | Should -Be 'S5GXNF0R123456'
        $record.disk.sizeBytes | Should -Be 1000204886016
        $record.disk.busType | Should -Be 'NVMe'
        $record.encryption.kind | Should -Be 'bitlocker'
        $record.encryption.protectionOn | Should -BeTrue
        $record.method | Should -Be 'windows-reset-this-pc'
        $record.standard | Should -Be 'NIST SP 800-88 Rev. 2 cryptographic erase via the operating system (not independently verified)'
        @($record.readiness).Count | Should -Be 14
        $record.sourceRun.finishedAt | Should -Be '2026-11-23T20:00:00Z'
        $record.sourceRun.traces | Should -Be 5
        @($record.notes).Count | Should -BeGreaterThan 0
        $record.sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'produces a deterministic hash across two builds with identical inputs' {
        $report = Get-EraseRecordTestReport
        $disk = Get-EraseRecordTestDisk
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        $record1 = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'WORKSTATION-01' -Operator 'admin' -Now $N
        }

        $record2 = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'WORKSTATION-01' -Operator 'admin' -Now $N
        }

        $json1 = InModuleScope Vacate -Parameters @{ Rec = $record1 } { param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec }
        $json2 = InModuleScope Vacate -Parameters @{ Rec = $record2 } { param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec }

        $record1.sha256 | Should -Be $record2.sha256
        $json1 | Should -Be $json2
    }

    It 'rejects an invalid erase method' {
        $report = Get-EraseRecordTestReport
        $disk = Get-EraseRecordTestDisk
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        {
            InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
                param($Rep, $D, $R, $N)
                New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'unsupported-erase-command' `
                    -Machine 'WORKSTATION-01' -Operator 'admin' -Now $N
            }
        } | Should -Throw '*invalid erase method*'
    }

    It 'supports all three contract erase methods' {
        $now = [datetime]'2026-11-23T22:00:00Z'

        $methods = @(
            @{ Platform = 'windows'; Method = 'windows-reset-this-pc'; Enc = 'bitlocker' }
            @{ Platform = 'macos'; Method = 'macos-erase-all-content-and-settings'; Enc = 'filevault' }
            @{ Platform = 'linux'; Method = 'linux-luks-key-erase'; Enc = 'luks' }
        )

        foreach ($m in $methods) {
            $report = Get-EraseRecordTestReport -Platform $m.Platform
            $disk = Get-EraseRecordTestDisk -Platform $m.Platform -EncKind $m.Enc
            $readiness = Get-EraseRecordTestReadiness

            $rec = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; Meth = $m.Method; N = $now } {
                param($Rep, $D, $R, $Meth, $N)
                New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method $Meth `
                    -Machine 'TEST-HOST' -Operator 'ops' -Now $N
            }

            $rec.method | Should -Be $m.Method
            $rec.platform | Should -Be $m.Platform
            $rec.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
    }
}

Describe 'Test-VacateEraseRecord validation and tampering detection' {
    BeforeAll {
        $report = Get-EraseRecordTestReport
        $disk = Get-EraseRecordTestDisk
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        $script:ValidRecord = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'WORKSTATION-01' -Operator 'admin' -Now $N
        }
        $script:ValidJson = InModuleScope Vacate -Parameters @{ Rec = $script:ValidRecord } {
            param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec
        }
    }

    It 'validates an untampered erase record JSON' {
        $result = InModuleScope Vacate -Parameters @{ J = $script:ValidJson } {
            param($J) Test-VacateEraseRecord -Json $J
        }
        $result.valid | Should -BeTrue
        @($result.problems).Count | Should -Be 0
    }

    It 'detects a changed serial' {
        $tamperedJson = $script:ValidJson.Replace('S5GXNF0R123456', 'TAMPERED_SERIAL_999')
        $result = InModuleScope Vacate -Parameters @{ J = $tamperedJson } {
            param($J) Test-VacateEraseRecord -Json $J
        }
        $result.valid | Should -BeFalse
        $shaProblem = @($result.problems | Where-Object { $_ -like '*sha256 mismatch*' })
        $shaProblem.Count | Should -BeGreaterThan 0
    }

    It 'detects a changed check in readiness' {
        $tamperedJson = $script:ValidJson.Replace('"id": "protection-on",`n      "ok": true', '"id": "protection-on",`n      "ok": false')
        if ($tamperedJson -eq $script:ValidJson) {
            # In case line breaks or spaces differ:
            $tamperedJson = $script:ValidJson.Replace('"protection-on"', '"protection-on"').Replace('Elevated session verified.', 'Altered check text.')
        }
        $result = InModuleScope Vacate -Parameters @{ J = $tamperedJson } {
            param($J) Test-VacateEraseRecord -Json $J
        }
        $result.valid | Should -BeFalse
        $shaProblem = @($result.problems | Where-Object { $_ -like '*sha256 mismatch*' })
        $shaProblem.Count | Should -BeGreaterThan 0
    }

    It 'detects a removed field' {
        # Remove the operator field from JSON
        $lines = @($script:ValidJson -split "`n" | Where-Object { $_ -notmatch '^\s*"operator":' })
        $tamperedJson = $lines -join "`n"

        $result = InModuleScope Vacate -Parameters @{ J = $tamperedJson } {
            param($J) Test-VacateEraseRecord -Json $J
        }
        $result.valid | Should -BeFalse
        $fieldProblem = @($result.problems | Where-Object { $_ -like "*missing required field 'operator'*" })
        $fieldProblem.Count | Should -BeGreaterThan 0
    }

    It 'detects a wrong hash' {
        $fakeHash = '0000000000000000000000000000000000000000000000000000000000000000'
        $tamperedJson = $script:ValidJson -replace '"sha256": "[0-9a-f]{64}"', ('"sha256": "' + $fakeHash + '"')

        $result = InModuleScope Vacate -Parameters @{ J = $tamperedJson } {
            param($J) Test-VacateEraseRecord -Json $J
        }
        $result.valid | Should -BeFalse
        $shaProblem = @($result.problems | Where-Object { $_ -like '*sha256 mismatch*' })
        $shaProblem.Count | Should -BeGreaterThan 0
    }

    It 'detects unexpected extra properties' {
        $lines = @($script:ValidJson -split "`n")
        $tampered = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $tampered.Add($lines[$i])
            if ($lines[$i] -match '^\s*"schemaVersion":') {
                $tampered.Add('  "unexpectedField": "intruder",')
            }
        }
        $tamperedJson = $tampered -join "`n"

        $result = InModuleScope Vacate -Parameters @{ J = $tamperedJson } {
            param($J) Test-VacateEraseRecord -Json $J
        }
        $result.valid | Should -BeFalse
        $extraProblem = @($result.problems | Where-Object { $_ -like "*unexpected field 'unexpectedField'*" })
        $extraProblem.Count | Should -BeGreaterThan 0
    }

    It 'detects empty or malformed JSON' {
        $r1 = InModuleScope Vacate { Test-VacateEraseRecord -Json '' }
        $r1.valid | Should -BeFalse

        $r2 = InModuleScope Vacate { Test-VacateEraseRecord -Json '{ not valid json }' }
        $r2.valid | Should -BeFalse
    }
}

Describe 'erase-record.schema.json validation' {
    It 'validates a full Windows erase record against the JSON Schema' {
        if (Test-EraseRecordSchemaSkipped) { return }

        $report = Get-EraseRecordTestReport -Platform 'windows'
        $disk = Get-EraseRecordTestDisk -Platform 'windows' -EncKind 'bitlocker'
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        $record = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'WIN-WORKSTATION' -Operator 'secadmin' -Now $N
        }
        $json = InModuleScope Vacate -Parameters @{ Rec = $record } {
            param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec
        }

        Test-Json -Json $json -SchemaFile $script:EraseRecordSchemaPath | Should -BeTrue
    }

    It 'validates macOS and Linux records against the JSON Schema' {
        if (Test-EraseRecordSchemaSkipped) { return }

        $macReport = Get-EraseRecordTestReport -Platform 'macos'
        $macDisk = Get-EraseRecordTestDisk -Platform 'macos' -EncKind 'filevault' -BusType 'PCIe'
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        $macRecord = InModuleScope Vacate -Parameters @{ Rep = $macReport; D = $macDisk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'macos-erase-all-content-and-settings' `
                -Machine 'MAC-PRO' -Operator 'macadmin' -Now $N
        }
        $macJson = InModuleScope Vacate -Parameters @{ Rec = $macRecord } {
            param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec
        }
        Test-Json -Json $macJson -SchemaFile $script:EraseRecordSchemaPath | Should -BeTrue

        $linuxReport = Get-EraseRecordTestReport -Platform 'linux'
        $linuxDisk = Get-EraseRecordTestDisk -Platform 'linux' -EncKind 'luks' -BusType 'SATA'
        $linuxRecord = InModuleScope Vacate -Parameters @{ Rep = $linuxReport; D = $linuxDisk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'linux-luks-key-erase' `
                -Machine 'SRV-UBUNTU' -Operator 'sysadmin' -Now $N
        }
        $linuxJson = InModuleScope Vacate -Parameters @{ Rec = $linuxRecord } {
            param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec
        }
        Test-Json -Json $linuxJson -SchemaFile $script:EraseRecordSchemaPath | Should -BeTrue
    }

    It 'rejects records with extra properties in schema' {
        if (Test-EraseRecordSchemaSkipped) { return }

        $report = Get-EraseRecordTestReport
        $disk = Get-EraseRecordTestDisk
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        $record = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'WORKSTATION-01' -Operator 'admin' -Now $N
        }
        $json = InModuleScope Vacate -Parameters @{ Rec = $record } {
            param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec
        }
        $badJson = $json.Replace('"schemaVersion": "1.0",', '"schemaVersion": "1.0",`n  "unauthorizedProperty": "forbidden",')

        $threw = $false
        try {
            $null = Test-Json -Json $badJson -SchemaFile $script:EraseRecordSchemaPath -ErrorAction Stop
        }
        catch {
            $threw = $true
        }
        $threw | Should -BeTrue
    }

    It 'rejects records with missing required properties in schema' {
        if (Test-EraseRecordSchemaSkipped) { return }

        $report = Get-EraseRecordTestReport
        $disk = Get-EraseRecordTestDisk
        $readiness = Get-EraseRecordTestReadiness
        $now = [datetime]'2026-11-23T22:00:00Z'

        $record = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now } {
            param($Rep, $D, $R, $N)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'WORKSTATION-01' -Operator 'admin' -Now $N
        }
        $json = InModuleScope Vacate -Parameters @{ Rec = $record } {
            param($Rec) ConvertTo-VacateEraseRecordJson -Record $Rec
        }
        $lines = @($json -split "`n" | Where-Object { $_ -notmatch '^\s*"operator":' })
        $badJson = $lines -join "`n"

        $threw = $false
        try {
            $null = Test-Json -Json $badJson -SchemaFile $script:EraseRecordSchemaPath -ErrorAction Stop
        }
        catch {
            $threw = $true
        }
        $threw | Should -BeTrue
    }
}

Describe 'ConvertTo-VacateEraseRecordMarkdown' {
    BeforeAll {
        $report = Get-EraseRecordTestReport
        $disk = Get-EraseRecordTestDisk
        # Include long messages to test word wrapping
        $readiness = Get-EraseRecordTestReadiness
        $readiness.checks[0].message = 'This is an extremely long message for testing line wrapping to ensure that no line ever exceeds one hundred characters under any circumstances whatsoever.'

        $longNote = 'Note with significant length that must be wrapped across multiple lines cleanly so that a buyer or IT administrator can comfortably read the certificate.'
        $now = [datetime]'2026-11-23T22:00:00Z'

        $script:Record = InModuleScope Vacate -Parameters @{ Rep = $report; D = $disk; R = $readiness; N = $now; Note = $longNote } {
            param($Rep, $D, $R, $N, $Note)
            New-VacateEraseRecord -Report $Rep -SystemDisk $D -Readiness $R -Method 'windows-reset-this-pc' `
                -Machine 'CORP-DESKTOP-2026' -Operator 'security-officer-jane' -Now $N -Notes @($Note)
        }
        $script:Markdown = InModuleScope Vacate -Parameters @{ Rec = $script:Record } {
            param($Rec) ConvertTo-VacateEraseRecordMarkdown -Record $Rec
        }
    }

    It 'ensures all markdown lines are <= 100 characters' {
        $lines = @($script:Markdown -split "`n")
        $lines.Count | Should -BeGreaterThan 10
        foreach ($line in $lines) {
            $line.Length | Should -BeLessOrEqual 100
        }
    }

    It 'leads with machine, disk serial, method, date and unsigned notice' {
        $lines = @($script:Markdown -split "`n")

        # Plain statement in top lines
        $noticeFound = $false
        for ($i = 0; $i -lt 5; $i++) {
            if ($lines[$i] -like '*not signed*' -and $lines[$i] -like '*not an independent verification*') {
                $noticeFound = $true
                break
            }
        }
        $noticeFound | Should -BeTrue

        # Machine, serial, method, date in summary header
        $script:Markdown | Should -Match '(?m)^\- \*\*Machine:\*\* CORP-DESKTOP-2026'
        $script:Markdown | Should -Match '(?m)^\- \*\*Disk Serial:\*\* S5GXNF0R123456'
        $script:Markdown | Should -Match '(?m)^\- \*\*Erase Method:\*\* windows-reset-this-pc'
        $script:Markdown | Should -Match '(?m)^\- \*\*Date:\*\* 2026-11-23T22:00:00Z'
    }

    It 'contains disk details, encryption state, readiness checks, and SHA-256 fingerprint' {
        $script:Markdown | Should -Match 'Samsung SSD 980 PRO 1TB'
        $script:Markdown | Should -Match 'NVMe'
        $script:Markdown | Should -Match 'bitlocker'
        $script:Markdown | Should -Match '\[PASS\] elevated'
        $script:Markdown | Should -Match $script:Record.sha256
    }
}
