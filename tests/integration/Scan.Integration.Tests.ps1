# Scan.Integration.Tests.ps1 - integration tests for full scan lifecycle.
# PowerShell 5.1 compatible. ASCII only.

$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    . (Join-Path $PSScriptRoot '../helpers/WriteSpy.ps1')

    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $script:platformName = InModuleScope Vacate { Get-VacatePlatform }
    # The fixture profile uses POSIX paths on every non-Windows host, so a macOS host runs the
    # linux fixture rules; test.macos.only then stays the "other platform" rule (CI macOS job).
    if ($script:platformName -eq 'macos') { $script:platformName = 'linux' }

    # Setup fixture tree under [IO.Path]::GetTempPath()
    $script:tree = Join-Path ([IO.Path]::GetTempPath()) ('vacate-int-' + [guid]::NewGuid().ToString('N'))
    $script:users = Join-Path $script:tree 'Users'
    $script:homeDir = Join-Path $script:users 'tester'
    $script:outsideTarget = Join-Path $script:tree 'outside-target'
    $script:otherUser = Join-Path $script:users 'otheruser'

    [void][IO.Directory]::CreateDirectory($script:homeDir)
    [void][IO.Directory]::CreateDirectory($script:outsideTarget)
    [void][IO.Directory]::CreateDirectory($script:otherUser)

    # Built-in profile directories per platform (dropped by excludeHome)
    $builtIns = @('lost+found')
    if ($script:onWindows) { $builtIns = @('Public', 'Default') }
    foreach ($b in $builtIns) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:users $b))
    }

    # Fixture directories inside home
    $logsDir = Join-Path $script:homeDir 'logs'
    $docsDir = Join-Path $script:homeDir 'documents'
    $docsSubDir = Join-Path $docsDir 'sub'
    [void][IO.Directory]::CreateDirectory($logsDir)
    [void][IO.Directory]::CreateDirectory($docsDir)
    [void][IO.Directory]::CreateDirectory($docsSubDir)

    # Fixture files:
    # 1. Single activity file: 12 bytes
    $script:activityFilePath = Join-Path $script:homeDir 'activity_file.txt'
    [IO.File]::WriteAllText($script:activityFilePath, 'hello world!')

    # 2. Logs directory with include *.log:
    # app.log (10 bytes), debug.log (10 bytes), ignored.txt (12 bytes - should not match *.log)
    $script:logFile1 = Join-Path $logsDir 'app.log'
    $script:logFile2 = Join-Path $logsDir 'debug.log'
    $script:ignoredLog = Join-Path $logsDir 'ignored.txt'
    [IO.File]::WriteAllText($script:logFile1, '0123456789')
    [IO.File]::WriteAllText($script:logFile2, 'abcdefghij')
    [IO.File]::WriteAllText($script:ignoredLog, 'ignored text')

    # 3. Documents directory with recurse: true:
    # doc1.txt (9 bytes), sub/doc2.txt (9 bytes) -> total 18 bytes, 2 items
    $script:docFile1 = Join-Path $docsDir 'doc1.txt'
    $script:docFile2 = Join-Path $docsSubDir 'doc2.txt'
    [IO.File]::WriteAllText($script:docFile1, 'doc1 test')
    [IO.File]::WriteAllText($script:docFile2, 'doc2 test')

    # 4. Outside target with secret file:
    $script:secretFile = Join-Path $script:outsideTarget 'secret-outside.txt'
    [IO.File]::WriteAllText($script:secretFile, 'secret outside data')

    # 5. Junction or Symlink inside documents pointing outside the fixture tree:
    $script:linkPath = Join-Path $docsDir 'linked_outside'
    if ($script:onWindows) {
        New-Item -ItemType Junction -Path $script:linkPath -Value $script:outsideTarget | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $script:linkPath -Target $script:outsideTarget | Out-Null
    }

    # 6. Other user file:
    $script:otherUserFile = Join-Path $script:otherUser 'other_info.txt'
    [IO.File]::WriteAllText($script:otherUserFile, 'other user info')

    # 7. Denied directory for permission testing
    $script:deniedDir = Join-Path $script:homeDir 'denied_folder'
    [void][IO.Directory]::CreateDirectory($script:deniedDir)
    $script:deniedFile = Join-Path $script:deniedDir 'secret_denied.txt'
    [IO.File]::WriteAllText($script:deniedFile, 'hidden content')
    $script:deniedAclApplied = $false
    $script:deniedAccessRule = $null
    $script:deniedUnixMode = $null

    # Settle NTFS directory metadata by performing a warm-up snapshot traversal
    $null = Get-VacateTreeSnapshot -Path $script:tree

    # Setup context
    $name = 'linux'; $sep = '/'; $cs = $true; $cmp = [StringComparison]::Ordinal
    if ($script:onWindows) {
        $name = 'windows'; $sep = '\'; $cs = $false; $cmp = [StringComparison]::OrdinalIgnoreCase
    }
    $prof = [pscustomobject][ordered]@{
        Name          = $name
        CaseSensitive = $cs
        Comparison    = $cmp
        Separator     = [char]$sep
        Roots         = [ordered]@{ HOME = $script:homeDir; USERS = $script:users }
        HomePath      = $script:homeDir
        UsersRoot     = $script:users
        UserName      = 'tester'
    }
    $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
    $script:ctx = [pscustomobject]@{
        Platform    = $prof
        FileSystem  = $fs
        Registry    = $null
        Cim         = $null
        SystemQuery = $null
        Elevated    = $false
        MountPoints = @()
        Exclude     = @()
    }

    # Host info
    $script:hostInfo = [pscustomobject][ordered]@{
        name         = 'TEST-HOST'
        os           = 'TestOS'
        version      = '1.0'
        architecture = 'X64'
        user         = 'tester'
        volumes      = @()
    }

    # Load fixture rules
    $rulesRoot = Join-Path $PSScriptRoot '../fixtures/rules'
    $script:ruleSet = InModuleScope Vacate -Parameters @{ P = $rulesRoot; Pl = $script:platformName } {
        param($P, $Pl)
        Import-VacateRuleSet -Path $P -Platform $Pl
    }
    $script:rules = @($script:ruleSet.Rules)

    # Run Invoke-VacateEngine then New-VacateReport for the main baseline run (Test 1)
    $script:started1 = [datetime]::UtcNow
    $script:engineResult1 = InModuleScope Vacate -Parameters @{ R = $script:rules; C = $script:ctx } {
        param($R, $C)
        Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 30 -RuleTimeoutSeconds 5
    }
    $script:finished1 = [datetime]::UtcNow

    $script:report1 = InModuleScope Vacate -Parameters @{
        Res = $script:engineResult1
        R   = $script:rules
        NA  = @($script:ruleSet.NotApplicable).Count
        Inv = @($script:ruleSet.Errors).Count
        Pl  = $script:platformName
        H   = $script:hostInfo
        St  = $script:started1
        Fn  = $script:finished1
    } {
        param($Res, $R, $NA, $Inv, $Pl, $H, $St, $Fn)
        New-VacateReport -EngineResult $Res -Rules $R -NotApplicable $NA -InvalidFiles $Inv -Platform $Pl -HostInfo $H -StartedAt $St -FinishedAt $Fn -Elevated $false -BudgetSeconds 30 -RuleTimeoutSeconds 5
    }
}

AfterAll {
    # Restore permissions if denied
    if ($script:deniedAclApplied -and $script:onWindows -and [IO.Directory]::Exists($script:deniedDir)) {
        try {
            $acl = Get-Acl -LiteralPath $script:deniedDir
            $acl.RemoveAccessRule($script:deniedAccessRule) | Out-Null
            Set-Acl -LiteralPath $script:deniedDir -AclObject $acl
        } catch { $null = $_ }
    }
    if ($null -ne $script:deniedUnixMode -and -not $script:onWindows -and [IO.Directory]::Exists($script:deniedDir)) {
        try {
            [IO.File]::SetUnixFileMode($script:deniedDir, $script:deniedUnixMode)
        } catch { $null = $_ }
    }

    # Remove junction / symlink
    if ([IO.Directory]::Exists($script:linkPath)) {
        try {
            [IO.Directory]::Delete($script:linkPath)
        } catch { $null = $_ }
    }
    # Remove fixture tree
    if ([IO.Directory]::Exists($script:tree)) {
        try {
            [IO.Directory]::Delete($script:tree, $true)
        } catch { $null = $_ }
    }
}

Describe 'Vacate Scan Integration' {
    It 'produces exactly expected trace set in documented order' {
        $traces = @($script:report1.traces)
        $traces.Count | Should -Be 4

        # Trace 0: test.activity.file
        $t0 = $traces[0]
        $t0.category | Should -Be 'activity'
        $t0.ruleId | Should -Be 'test.activity.file'
        $expectedFileResolved = InModuleScope Vacate -Parameters @{ P = $script:activityFilePath; C = $script:ctx } {
            param($P, $C) ConvertTo-VacateNormalizedPath -Path $P -Platform $C.Platform
        }
        $t0.locator.resolved | Should -Be $expectedFileResolved
        $t0.itemCount | Should -Be 1
        $t0.sizeBytes | Should -Be 12

        # Trace 1: test.activity.include
        $t1 = $traces[1]
        $t1.category | Should -Be 'activity'
        $t1.ruleId | Should -Be 'test.activity.include'
        $expectedLogsResolved = InModuleScope Vacate -Parameters @{ P = (Join-Path $script:homeDir 'logs'); C = $script:ctx } {
            param($P, $C) ConvertTo-VacateNormalizedPath -Path $P -Platform $C.Platform
        }
        $t1.locator.resolved | Should -Be $expectedLogsResolved
        $t1.itemCount | Should -Be 2
        $t1.sizeBytes | Should -Be 20

        # Trace 2: test.personal.tree
        $t2 = $traces[2]
        $t2.category | Should -Be 'personal-files'
        $t2.ruleId | Should -Be 'test.personal.tree'
        $expectedDocsResolved = InModuleScope Vacate -Parameters @{ P = (Join-Path $script:homeDir 'documents'); C = $script:ctx } {
            param($P, $C) ConvertTo-VacateNormalizedPath -Path $P -Platform $C.Platform
        }
        $t2.locator.resolved | Should -Be $expectedDocsResolved
        $t2.itemCount | Should -Be 2
        $t2.sizeBytes | Should -Be 18

        # Trace 3: test.profiles.users
        $t3 = $traces[3]
        $t3.category | Should -Be 'user-profiles'
        $t3.ruleId | Should -Be 'test.profiles.users'
        $expectedOtherUserResolved = InModuleScope Vacate -Parameters @{ P = $script:otherUser; C = $script:ctx } {
            param($P, $C) ConvertTo-VacateNormalizedPath -Path $P -Platform $C.Platform
        }
        $t3.locator.resolved | Should -Be $expectedOtherUserResolved
        $t3.itemCount | Should -BeNullOrEmpty
        $t3.sizeBytes | Should -BeNullOrEmpty

        # Documented sort order: category, ruleId, resolved
        $keys = @($traces | ForEach-Object { [string]$_.category + "`t" + [string]$_.ruleId + "`t" + [string]$_.locator.resolved })
        $sortedKeys = [string[]]@($keys)
        [Array]::Sort($sortedKeys, [Collections.IComparer][StringComparer]::Ordinal)
        $keys | Should -Be $sortedKeys
    }

    It 'produces zero traces and every rule counted as run on clean fixture' {
        $cleanTree = Join-Path ([IO.Path]::GetTempPath()) ('vacate-clean-' + [guid]::NewGuid().ToString('N'))
        $cleanUsers = Join-Path $cleanTree 'Users'
        $cleanHome = Join-Path $cleanUsers 'cleanuser'
        [void][IO.Directory]::CreateDirectory($cleanHome)
        try {
            $name = 'linux'; $sep = '/'; $cs = $true; $cmp = [StringComparison]::Ordinal
            if ($script:onWindows) {
                $name = 'windows'; $sep = '\'; $cs = $false; $cmp = [StringComparison]::OrdinalIgnoreCase
            }
            $cleanProf = [pscustomobject][ordered]@{
                Name          = $name
                CaseSensitive = $cs
                Comparison    = $cmp
                Separator     = [char]$sep
                Roots         = [ordered]@{ HOME = $cleanHome; USERS = $cleanUsers }
                HomePath      = $cleanHome
                UsersRoot     = $cleanUsers
                UserName      = 'cleanuser'
            }
            $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
            $cleanCtx = [pscustomobject]@{
                Platform    = $cleanProf
                FileSystem  = $fs
                Registry    = $null
                Cim         = $null
                SystemQuery = $null
                Elevated    = $false
                MountPoints = @()
                Exclude     = @()
            }
            $cleanResult = InModuleScope Vacate -Parameters @{ R = $script:rules; C = $cleanCtx } {
                param($R, $C)
                Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 30 -RuleTimeoutSeconds 5
            }
            $start = [datetime]::UtcNow
            $cleanReport = InModuleScope Vacate -Parameters @{
                Res = $cleanResult
                R   = $script:rules
                NA  = @($script:ruleSet.NotApplicable).Count
                Inv = @($script:ruleSet.Errors).Count
                Pl  = $script:platformName
                H   = $script:hostInfo
                St  = $start
                Fn  = $start.AddSeconds(1)
            } {
                param($Res, $R, $NA, $Inv, $Pl, $H, $St, $Fn)
                New-VacateReport -EngineResult $Res -Rules $R -NotApplicable $NA -InvalidFiles $Inv -Platform $Pl -HostInfo $H -StartedAt $St -FinishedAt $Fn -Elevated $false -BudgetSeconds 30 -RuleTimeoutSeconds 5
            }

            @($cleanReport.traces).Count | Should -Be 0
            $cleanReport.summary.tracesFound | Should -Be 0
            $cleanReport.summary.rulesRun | Should -Be @($script:rules).Count
            $cleanReport.summary.rulesSkipped | Should -Be 0
            $cleanReport.summary.rulesFailed | Should -Be 0
        }
        finally {
            if ([IO.Directory]::Exists($cleanTree)) {
                [IO.Directory]::Delete($cleanTree, $true)
            }
        }
    }

    It 'skips junction or symlink pointing outside fixture and does not follow target' {
        $traces = @($script:report1.traces)
        foreach ($t in $traces) {
            $t.locator.resolved | Should -Not -Match 'outside-target'
            @($t.samples) | Should -Not -Contain 'secret-outside.txt'
        }
        $treeTrace = @($traces | Where-Object { $_.ruleId -eq 'test.personal.tree' })[0]
        $treeTrace.itemCount | Should -Be 2
        $treeTrace.sizeBytes | Should -Be 18
        @($treeTrace.samples) | Should -Not -Contain 'secret-outside.txt'
    }

    It 'records a permission skip for an unreadable folder without error or crash' {
        if (-not $script:onWindows -and [Environment]::UserName -eq 'root') {
            Set-ItResult -Skipped -Because 'Permission deny test skipped when running as root on Linux'
            return
        }

        if ($script:onWindows) {
            $acl = Get-Acl -LiteralPath $script:deniedDir
            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $script:deniedAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $id,
                [System.Security.AccessControl.FileSystemRights]::ListDirectory,
                [System.Security.AccessControl.AccessControlType]::Deny
            )
            $acl.AddAccessRule($script:deniedAccessRule)
            Set-Acl -LiteralPath $script:deniedDir -AclObject $acl
            $script:deniedAclApplied = $true
        } else {
            $script:deniedUnixMode = [IO.File]::GetUnixFileMode($script:deniedDir)
            [IO.File]::SetUnixFileMode($script:deniedDir, [IO.UnixFileMode]::None)
        }

        try {
            $deniedRule = [pscustomobject]@{
                id                = 'test.personal.denied'
                platforms         = @($script:platformName)
                category          = 'personal-files'
                title             = 'Denied folder test'
                whyItMatters      = 'Testing permission deny skip.'
                sensitivity       = 'medium'
                locator           = [pscustomobject]@{
                    kind    = 'path'
                    root    = 'HOME'
                    path    = 'denied_folder'
                    match   = 'directories'
                    recurse = $true
                }
                measure           = @('exists', 'sizeBytes', 'itemCount')
                maxEntries        = 100
                requiresElevation = $false
                verifiedOn        = @()
                verified          = $false
                source            = 'Integration test fixture rule'
                notes             = $null
            }

            $res = InModuleScope Vacate -Parameters @{ R = @($deniedRule); C = $script:ctx } {
                param($R, $C)
                Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 30 -RuleTimeoutSeconds 5
            }

            @($res.Errors).Count | Should -Be 0
            $permSkips = @($res.Skips | Where-Object { $_.reason -eq 'permission' })
            $permSkips.Count | Should -BeGreaterThan 0
            $permSkips[0].ruleId | Should -Be 'test.personal.denied'
        }
        finally {
            if ($script:onWindows -and $script:deniedAclApplied) {
                try {
                    $acl = Get-Acl -LiteralPath $script:deniedDir
                    $acl.RemoveAccessRule($script:deniedAccessRule) | Out-Null
                    Set-Acl -LiteralPath $script:deniedDir -AclObject $acl
                    $script:deniedAclApplied = $false
                } catch { $null = $_ }
            }
            if (-not $script:onWindows -and $null -ne $script:deniedUnixMode) {
                try {
                    [IO.File]::SetUnixFileMode($script:deniedDir, $script:deniedUnixMode)
                    $script:deniedUnixMode = $null
                } catch { $null = $_ }
            }
        }
    }

    It 'marks scan incomplete and records budget skips when budget is exhausted' {
        $clockState = [pscustomobject]@{ Count = 0 }
        $t0 = [datetime]::UtcNow
        $fakeClock = {
            $clockState.Count++
            if ($clockState.Count -le 2) { return $t0 }
            return $t0.AddSeconds(100)
        }

        $resBudget = InModuleScope Vacate -Parameters @{ R = $script:rules; C = $script:ctx; Clk = $fakeClock } {
            param($R, $C, $Clk)
            Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 10 -RuleTimeoutSeconds 5 -Clock $Clk
        }

        $budgetReport = InModuleScope Vacate -Parameters @{
            Res = $resBudget
            R   = $script:rules
            NA  = @($script:ruleSet.NotApplicable).Count
            Inv = @($script:ruleSet.Errors).Count
            Pl  = $script:platformName
            H   = $script:hostInfo
            St  = $t0
            Fn  = $t0.AddSeconds(100)
        } {
            param($Res, $R, $NA, $Inv, $Pl, $H, $St, $Fn)
            New-VacateReport -EngineResult $Res -Rules $R -NotApplicable $NA -InvalidFiles $Inv -Platform $Pl -HostInfo $H -StartedAt $St -FinishedAt $Fn -Elevated $false -BudgetSeconds 10 -RuleTimeoutSeconds 5
        }

        $budgetReport.scan.complete | Should -BeFalse
        $budgetSkips = @($budgetReport.skipped | Where-Object { $_.reason -eq 'budget' })
        $budgetSkips.Count | Should -BeGreaterThan 0
    }

    It 'leaves the scanned tree completely unchanged (write-spy)' {
        $before = Get-VacateTreeSnapshot -Path $script:tree
        $null = InModuleScope Vacate -Parameters @{ R = $script:rules; C = $script:ctx } {
            param($R, $C)
            Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 30 -RuleTimeoutSeconds 5
        }
        $after = Get-VacateTreeSnapshot -Path $script:tree
        $diff = Compare-VacateTreeSnapshot -Before $before -After $after
        @($diff).Count | Should -Be 0
    }

    It 'counts other-platform rule in NotApplicable and never executes it' {
        @($script:ruleSet.NotApplicable | Where-Object { $_.id -eq 'test.macos.only' }).Count | Should -Be 1

        $executedRuleIds = New-Object System.Collections.Generic.List[string]
        $defaultExecutors = InModuleScope Vacate { Get-VacateDefaultExecutor }
        $spyExecutors = @{}
        foreach ($k in $defaultExecutors.Keys) {
            $origName = $defaultExecutors[$k]
            $spyExecutors[$k] = {
                param($Rule, $Context, $Deadline)
                $executedRuleIds.Add([string]$Rule.id)
                if ($origName -is [scriptblock]) {
                    return (& $origName $Rule $Context $Deadline)
                } else {
                    return (& $origName -Rule $Rule -Context $Context -Deadline $Deadline)
                }
            }
        }

        $null = InModuleScope Vacate -Parameters @{ R = @($script:ruleSet.Rules); C = $script:ctx; E = $spyExecutors } {
            param($R, $C, $E)
            Invoke-VacateEngine -Rules $R -Context $C -Executors $E
        }

        $executedRuleIds | Should -Not -Contain 'test.macos.only'
    }

    It 'validates test 1 report against report.schema.json (PowerShell 7 only)' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Set-ItResult -Skipped -Because 'Test-Json requires PowerShell 7'
            return
        }
        $schemaPath = Join-Path $PSScriptRoot '../../schemas/report.schema.json'
        $json = InModuleScope Vacate -Parameters @{ R = $script:report1 } {
            param($R)
            ConvertTo-VacateReportJson -Report $R
        }
        Test-Json -Json $json -SchemaFile $schemaPath | Should -BeTrue
    }

    It 'produces identical JSON when run twice with time fields blanked' {
        $started2 = [datetime]::UtcNow
        $engineResult2 = InModuleScope Vacate -Parameters @{ R = $script:rules; C = $script:ctx } {
            param($R, $C)
            Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 30 -RuleTimeoutSeconds 5
        }
        $finished2 = [datetime]::UtcNow

        $report2 = InModuleScope Vacate -Parameters @{
            Res = $engineResult2
            R   = $script:rules
            NA  = @($script:ruleSet.NotApplicable).Count
            Inv = @($script:ruleSet.Errors).Count
            Pl  = $script:platformName
            H   = $script:hostInfo
            St  = $started2
            Fn  = $finished2
        } {
            param($Res, $R, $NA, $Inv, $Pl, $H, $St, $Fn)
            New-VacateReport -EngineResult $Res -Rules $R -NotApplicable $NA -InvalidFiles $Inv -Platform $Pl -HostInfo $H -StartedAt $St -FinishedAt $Fn -Elevated $false -BudgetSeconds 30 -RuleTimeoutSeconds 5
        }

        $json1 = InModuleScope Vacate -Parameters @{ R = $script:report1 } {
            param($R) ConvertTo-VacateReportJson -Report $R
        }
        $json2 = InModuleScope Vacate -Parameters @{ R = $report2 } {
            param($R) ConvertTo-VacateReportJson -Report $R
        }

        $blank1 = $json1 -replace '"startedAt":\s*"[^"]*"', '"startedAt": ""'
        $blank1 = $blank1 -replace '"finishedAt":\s*"[^"]*"', '"finishedAt": ""'
        $blank1 = $blank1 -replace '"durationMs":\s*[0-9]+', '"durationMs": 0'

        $blank2 = $json2 -replace '"startedAt":\s*"[^"]*"', '"startedAt": ""'
        $blank2 = $blank2 -replace '"finishedAt":\s*"[^"]*"', '"finishedAt": ""'
        $blank2 = $blank2 -replace '"durationMs":\s*[0-9]+', '"durationMs": 0'

        $blank1 | Should -Be $blank2
    }
}
