BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:UndoSchemaPath = Join-Path $PSScriptRoot '../../schemas/undo.schema.json'
    $script:T0 = [datetime]::SpecifyKind([datetime]'2026-11-23 10:00:00', [DateTimeKind]::Utc)

    function Get-UndoTestLog {
        param([int]$Entries = 0)
        return InModuleScope Vacate -Parameters @{ N = $Entries; T = $script:T0 } {
            param($N, $T)
            $log = New-VacateUndoLog -Platform 'windows' -Machine 'TESTPC' -Run 'vacate-run-20261123-100000' -Now $T
            for ($i = 1; $i -le $N; $i++) {
                $trash = 'C:\$Recycle.Bin\S-1-5-21\$R00000' + $i
                $size = [long](1024 * $i)
                if ($i -eq 2) { $trash = $null; $size = $null }
                $log = Add-VacateUndoEntry -Log $log -Step $i -RuleId "browser.test.r$i" -OriginalPath "C:\Users\t\AppData\Local\App$i" `
                    -TrashLocation $trash -IsDirectory ($i % 2 -eq 1) -SizeBytes $size -Now $T.AddMinutes($i)
            }
            $log
        }
    }

    function ConvertTo-UndoTestJson {
        param([object]$Log)
        return InModuleScope Vacate -Parameters @{ L = $Log } { param($L) ConvertTo-VacateUndoJson -Log $L }
    }

    function ConvertFrom-UndoTestJson {
        param([string]$Json)
        return InModuleScope Vacate -Parameters @{ J = $Json } { param($J) ConvertFrom-VacateUndoJson -Json $J }
    }

    # Parses JSON into a mutable object for sabotage; dates stay strings on 5.1 and 7.
    function Get-UndoTestMutable {
        param([object]$Log)
        $json = ConvertTo-UndoTestJson -Log $Log
        return InModuleScope Vacate -Parameters @{ J = $json } { param($J) ConvertFrom-VacateJson -Json $J }
    }

    function Test-UndoSchemaSkipped {
        # Test-Json -SchemaFile needs PowerShell 7 (same skip as the plan schema tests).
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Test-Json requires PowerShell 7'
            return $true
        }
        return $false
    }
}

Describe 'New-VacateUndoLog' {
    It 'builds an empty log with the fixed fields and UTC time' {
        $log = Get-UndoTestLog
        @($log.PSObject.Properties.Name) -join ',' | Should -Be 'schemaVersion,tool,platform,machine,run,createdAt,entries'
        $log.schemaVersion | Should -Be '1.0'
        $log.tool.name | Should -Be 'vacate'
        $log.tool.version | Should -Be (InModuleScope Vacate { $script:VacateToolVersion })
        $log.createdAt | Should -Be '2026-11-23T10:00:00Z'
        @($log.entries).Count | Should -Be 0
    }

    It 'refuses an unknown platform and a run that is a path' {
        { InModuleScope Vacate { New-VacateUndoLog -Platform 'bsd' -Machine 'M' -Run 'r' -Now (Get-Date) } } | Should -Throw '*platform*'
        { InModuleScope Vacate { New-VacateUndoLog -Platform 'linux' -Machine 'M' -Run 'a/b' -Now (Get-Date) } } | Should -Throw '*run*'
    }
}

Describe 'Add-VacateUndoEntry' {
    It 'appends entries with indexes 1..n in the fixed property order' {
        $log = Get-UndoTestLog -Entries 3
        $entries = @($log.entries)
        $entries.Count | Should -Be 3
        ($entries | ForEach-Object { $_.index }) -join ',' | Should -Be '1,2,3'
        @($entries[0].PSObject.Properties.Name) -join ',' |
            Should -Be 'index,step,ruleId,originalPath,trashLocation,isDirectory,sizeBytes,movedAt,restoredAt'
        $entries[0].movedAt | Should -Be '2026-11-23T10:01:00Z'
        $entries[0].sizeBytes | Should -Be 1024
        $entries[0].isDirectory | Should -BeTrue
        $entries[1].trashLocation | Should -BeNullOrEmpty
        $null -eq $entries[1].trashLocation | Should -BeTrue
        $null -eq $entries[1].sizeBytes | Should -BeTrue
        $null -eq $entries[2].restoredAt | Should -BeTrue
    }

    It 'does not change the log it was given' {
        $log = Get-UndoTestLog -Entries 1
        $null = InModuleScope Vacate -Parameters @{ L = $log } {
            param($L)
            Add-VacateUndoEntry -Log $L -Step 9 -RuleId 'x.y' -OriginalPath 'C:\x' -TrashLocation 'C:\t' -IsDirectory $false -SizeBytes 1 -Now (Get-Date)
        }
        @($log.entries).Count | Should -Be 1
    }
}

Describe 'Set-VacateUndoRestored' {
    It 'marks one entry restored and leaves the input alone' {
        $log = Get-UndoTestLog -Entries 2
        $after = InModuleScope Vacate -Parameters @{ L = $log; T = $script:T0 } {
            param($L, $T) Set-VacateUndoRestored -Log $L -Index 2 -Now $T.AddHours(1)
        }
        @($after.entries)[1].restoredAt | Should -Be '2026-11-23T11:00:00Z'
        $null -eq @($after.entries)[0].restoredAt | Should -BeTrue
        $null -eq @($log.entries)[1].restoredAt | Should -BeTrue
    }

    It 'refuses an unknown index, a second restore, and a time before the move' {
        $log = Get-UndoTestLog -Entries 2
        { InModuleScope Vacate -Parameters @{ L = $log; T = $script:T0 } { param($L, $T) Set-VacateUndoRestored -Log $L -Index 5 -Now $T.AddHours(1) } } |
            Should -Throw '*no entry*'
        $done = InModuleScope Vacate -Parameters @{ L = $log; T = $script:T0 } { param($L, $T) Set-VacateUndoRestored -Log $L -Index 1 -Now $T.AddHours(1) }
        { InModuleScope Vacate -Parameters @{ L = $done; T = $script:T0 } { param($L, $T) Set-VacateUndoRestored -Log $L -Index 1 -Now $T.AddHours(2) } } |
            Should -Throw '*already restored*'
        { InModuleScope Vacate -Parameters @{ L = $log; T = $script:T0 } { param($L, $T) Set-VacateUndoRestored -Log $L -Index 1 -Now $T } } |
            Should -Throw '*earlier than movedAt*'
    }
}

Describe 'ConvertTo-VacateUndoJson / ConvertFrom-VacateUndoJson' {
    It 'round-trips a log byte for byte' {
        $log = Get-UndoTestLog -Entries 3
        $log = InModuleScope Vacate -Parameters @{ L = $log; T = $script:T0 } { param($L, $T) Set-VacateUndoRestored -Log $L -Index 3 -Now $T.AddDays(1) }
        $json = ConvertTo-UndoTestJson -Log $log
        $back = ConvertFrom-UndoTestJson -Json $json
        (ConvertTo-UndoTestJson -Log $back) | Should -BeExactly $json
        @($back.entries)[2].restoredAt | Should -Be '2026-11-24T10:00:00Z'
        @($back.entries)[0].sizeBytes | Should -Be 1024
        $null -eq @($back.entries)[1].trashLocation | Should -BeTrue
        $json | Should -Not -Match "`r"
    }

    It 'round-trips an empty log and a log with one entry' {
        foreach ($n in 0, 1) {
            $json = ConvertTo-UndoTestJson -Log (Get-UndoTestLog -Entries $n)
            $back = ConvertFrom-UndoTestJson -Json $json
            @($back.entries).Count | Should -Be $n
            (ConvertTo-UndoTestJson -Log $back) | Should -BeExactly $json
        }
    }

    It 'writes the same JSON whatever the input property order' {
        $log = Get-UndoTestLog -Entries 1
        $e = @($log.entries)[0]
        $shuffled = [pscustomobject][ordered]@{
            entries = @([pscustomobject][ordered]@{
                    restoredAt = $null; movedAt = $e.movedAt; sizeBytes = $e.sizeBytes; isDirectory = $e.isDirectory
                    trashLocation = $e.trashLocation; originalPath = $e.originalPath; ruleId = $e.ruleId; step = $e.step; index = 1
                })
            createdAt = $log.createdAt; run = $log.run; machine = $log.machine; platform = $log.platform
            tool = [pscustomobject][ordered]@{ version = $log.tool.version; name = 'vacate' }; schemaVersion = '1.0'
        }
        (ConvertTo-UndoTestJson -Log $shuffled) | Should -BeExactly (ConvertTo-UndoTestJson -Log $log)
    }

    It 'rejects a wrong schemaVersion' {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 1)
        $m.schemaVersion = '2.0'
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw '*schemaVersion*'
    }

    It 'rejects a missing top-level field: <_>' -ForEach @('schemaVersion', 'tool', 'platform', 'machine', 'run', 'createdAt', 'entries') {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 1)
        $m.PSObject.Properties.Remove($_)
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw "*missing the field '$_'*"
    }

    It 'rejects a missing entry field: <_>' -ForEach @('index', 'step', 'ruleId', 'originalPath', 'trashLocation', 'isDirectory', 'sizeBytes', 'movedAt', 'restoredAt') {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 2)
        @($m.entries)[1].PSObject.Properties.Remove($_)
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw "*entry 2 is missing the field '$_'*"
    }

    It 'rejects a missing tool field' {
        $m = Get-UndoTestMutable (Get-UndoTestLog)
        $m.tool.PSObject.Properties.Remove('version')
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw "*tool is missing the field 'version'*"
    }

    It 'rejects an unknown field' {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 1)
        @($m.entries)[0] | Add-Member -NotePropertyName 'command' -NotePropertyValue 'x'
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw '*unknown field*'
    }

    It 'rejects indexes out of order' {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 3)
        @($m.entries)[1].index = 3
        @($m.entries)[2].index = 2
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw '*index 3*in order*'
    }

    It 'rejects indexes that do not start at 1' {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 1)
        @($m.entries)[0].index = 0
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw '*in order*'
    }

    It 'rejects a restoredAt earlier than movedAt' {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 1)
        @($m.entries)[0].restoredAt = '2026-11-23T09:59:59Z'
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw '*earlier than movedAt*'
    }

    It 'rejects bad values: <Name>' -ForEach @(
        @{ Name = 'non-UTC movedAt'; Field = 'movedAt'; Value = '2026-11-23 10:01:00' }
        @{ Name = 'string sizeBytes'; Field = 'sizeBytes'; Value = '12' }
        @{ Name = 'negative sizeBytes'; Field = 'sizeBytes'; Value = -1 }
        @{ Name = 'string isDirectory'; Field = 'isDirectory'; Value = 'true' }
        @{ Name = 'step zero'; Field = 'step'; Value = 0 }
        @{ Name = 'empty originalPath'; Field = 'originalPath'; Value = '' }
        @{ Name = 'empty trashLocation'; Field = 'trashLocation'; Value = '' }
    ) {
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 1)
        @($m.entries)[0].$Field = $Value
        { ConvertFrom-UndoTestJson -Json ($m | ConvertTo-Json -Depth 10) } | Should -Throw "*$Field*"
    }

    It 'rejects empty text and text that is not JSON' {
        { ConvertFrom-UndoTestJson -Json '' } | Should -Throw '*empty*'
        { ConvertFrom-UndoTestJson -Json 'not json {' } | Should -Throw '*not valid JSON*'
        { ConvertFrom-UndoTestJson -Json '42' } | Should -Throw '*must be an object*'
        { ConvertFrom-UndoTestJson -Json '[1,2]' } | Should -Throw 'undo log:*'
    }
}

Describe 'undo.schema.json' {
    It 'accepts the JSON of a log with moved, restored and Trash-less entries' {
        if (Test-UndoSchemaSkipped) { return }
        $log = Get-UndoTestLog -Entries 3
        $log = InModuleScope Vacate -Parameters @{ L = $log; T = $script:T0 } { param($L, $T) Set-VacateUndoRestored -Log $L -Index 1 -Now $T.AddHours(1) }
        Test-Json -Json (ConvertTo-UndoTestJson -Log $log) -SchemaFile $script:UndoSchemaPath | Should -BeTrue
    }

    It 'accepts the JSON of an empty log' {
        if (Test-UndoSchemaSkipped) { return }
        Test-Json -Json (ConvertTo-UndoTestJson -Log (Get-UndoTestLog)) -SchemaFile $script:UndoSchemaPath | Should -BeTrue
    }

    It 'rejects an entry with an unknown property' {
        if (Test-UndoSchemaSkipped) { return }
        $m = Get-UndoTestMutable (Get-UndoTestLog -Entries 1)
        @($m.entries)[0] | Add-Member -NotePropertyName 'deleteCommand' -NotePropertyValue 'nothing runs this'
        $threw = $false
        try { $null = Test-Json -Json ($m | ConvertTo-Json -Depth 10) -SchemaFile $script:UndoSchemaPath -ErrorAction Stop } catch { $threw = $true }
        $threw | Should -BeTrue
    }

    It 'rejects a wrong schemaVersion' {
        if (Test-UndoSchemaSkipped) { return }
        $m = Get-UndoTestMutable (Get-UndoTestLog)
        $m.schemaVersion = '2.0'
        $threw = $false
        try { $null = Test-Json -Json ($m | ConvertTo-Json -Depth 10) -SchemaFile $script:UndoSchemaPath -ErrorAction Stop } catch { $threw = $true }
        $threw | Should -BeTrue
    }
}
