# Clean.Integration.Tests.ps1 - integration tests for Phase 3 clean and undo.
# PowerShell 5.1 compatible. ASCII only.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

BeforeDiscovery {
    $script:HasClean = [bool](Get-Command Invoke-VacateClean -ErrorAction SilentlyContinue)
}

Describe 'Vacate Clean and Undo Integration' -Skip:(-not $script:HasClean) {
    BeforeAll {
        # Pester 5 runs top-level code only during discovery, so helpers load here.
        Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
        . (Join-Path $PSScriptRoot '../helpers/WriteSpy.ps1')
        $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
        # clean refuses administrator/root sessions; GitHub's Windows runners are administrators.
        $script:elevated = InModuleScope Vacate { Test-VacateElevated -Platform (Get-VacatePlatform) }
        # ConvertFrom-VacateJson is module-private; call it inside the module.
        function script:Read-TestJson { param([string]$Path) InModuleScope Vacate -Parameters @{ P = $Path } { param($P) ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText($P)) } }
        $script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('vacate-clean-' + [guid]::NewGuid().ToString('N'))
        $script:tree = Join-Path $script:tempRoot 'profile'
        $script:users = Join-Path $script:tree 'Users'
        $script:homeDir = Join-Path $script:users 'tester'
        $script:outsideTarget = Join-Path $script:tempRoot 'outside-target'
        $script:trashRoot = Join-Path $script:tempRoot 'trash'
        $script:runsRoot = Join-Path $script:tempRoot 'runs'

        [void][IO.Directory]::CreateDirectory($script:homeDir)
        [void][IO.Directory]::CreateDirectory($script:outsideTarget)
        [void][IO.Directory]::CreateDirectory($script:trashRoot)
        [void][IO.Directory]::CreateDirectory($script:runsRoot)

        # Profile fixture files
        $script:eligibleFilePath = Join-Path $script:homeDir 'clean_file.txt'
        $script:eligibleDirPath = Join-Path $script:homeDir 'clean_tree'
        $script:eligibleSubDirPath = Join-Path $script:eligibleDirPath 'sub'
        [void][IO.Directory]::CreateDirectory($script:eligibleSubDirPath)
        $script:treeFile1 = Join-Path $script:eligibleDirPath 'file1.txt'
        $script:treeFile2 = Join-Path $script:eligibleSubDirPath 'file2.txt'

        $script:walletFilePath = Join-Path $script:homeDir 'wallet.dat'
        $script:swappedDirPath = Join-Path $script:homeDir 'swapped_target'
        [void][IO.Directory]::CreateDirectory($script:swappedDirPath)
        $script:swappedFile = Join-Path $script:swappedDirPath 'original.txt'

        $script:secretOutsideFile = Join-Path $script:outsideTarget 'secret-outside.txt'
        [IO.File]::WriteAllText($script:secretOutsideFile, 'secret outside data')

        [IO.File]::WriteAllText($script:eligibleFilePath, 'test eligible file content')
        [IO.File]::WriteAllText($script:treeFile1, 'tree file 1')
        [IO.File]::WriteAllText($script:treeFile2, 'tree file 2')
        [IO.File]::WriteAllText($script:walletFilePath, 'crypto wallet private key material')
        [IO.File]::WriteAllText($script:swappedFile, 'original file before swap')

        # Setup context and platform profile
        $script:platformName = 'linux'; $sep = '/'; $cs = $true; $cmp = [StringComparison]::Ordinal
        if ($script:onWindows) {
            $script:platformName = 'windows'; $sep = '\'; $cs = $false; $cmp = [StringComparison]::OrdinalIgnoreCase
        }
        $prof = [pscustomobject][ordered]@{
            Name          = $script:platformName
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

        # Override rules root to point to Phase 3 clean fixture rules
        $script:cleanFixturesPath = Join-Path $PSScriptRoot '../fixtures/clean'
        $script:origRulesRoot = InModuleScope Vacate { $script:VacateRulesRoot }
        InModuleScope Vacate -Parameters @{ P = $script:cleanFixturesPath } {
            param($P) $script:VacateRulesRoot = $P
        }

        function script:New-TestCleanRun {
            [CmdletBinding()]
            param([switch]$Redact)

            $runDir = Join-Path $script:runsRoot ('run-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($runDir)

            $ruleSet = InModuleScope Vacate -Parameters @{ P = $script:cleanFixturesPath; Pl = $script:platformName } {
                param($P, $Pl) Import-VacateRuleSet -Path $P -Platform $Pl
            }
            $rules = @($ruleSet.Rules)

            $engineResult = InModuleScope Vacate -Parameters @{ R = $rules; C = $script:ctx } {
                param($R, $C) Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 30 -RuleTimeoutSeconds 5
            }

            $machine = [Environment]::MachineName
            $report = InModuleScope Vacate -Parameters @{
                Res = $engineResult
                R   = $rules
                NA  = @($ruleSet.NotApplicable).Count
                Inv = @($ruleSet.Errors).Count
                Pl  = $script:platformName
                H   = [pscustomobject]@{ name = $machine; os = 'TestOS'; version = '1.0'; architecture = 'X64'; user = 'tester'; volumes = @() }
                St  = [datetime]::UtcNow
                Fn  = [datetime]::UtcNow
                Red = [bool]$Redact
            } {
                param($Res, $R, $NA, $Inv, $Pl, $H, $St, $Fn, $Red)
                $rep = New-VacateReport -EngineResult $Res -Rules $R -NotApplicable $NA -InvalidFiles $Inv -Platform $Pl -HostInfo $H -StartedAt $St -FinishedAt $Fn -Elevated $false -BudgetSeconds 30 -RuleTimeoutSeconds 5
                if ($Red) {
                    $rep = Protect-VacateReport -Report $rep
                }
                return $rep
            }

            InModuleScope Vacate -Parameters @{ B = $script:tempRoot; D = $runDir; Rep = $report } {
                param($B, $D, $Rep) Write-VacateRunOutput -BaseDir $B -RunDir $D -Report $Rep
            }

            $plan = InModuleScope Vacate -Parameters @{ Rep = $report; R = $rules; N = [datetime]::UtcNow } {
                param($Rep, $R, $N) New-VacatePlan -Report $Rep -Rules $R -Now $N
            }

            $planJson = InModuleScope Vacate -Parameters @{ P = $plan } { param($P) ConvertTo-VacateReportJson -Report $P }
            $planMd   = InModuleScope Vacate -Parameters @{ P = $plan } { param($P) ConvertTo-VacatePlanMarkdown -Plan $P }
            $planHtml = InModuleScope Vacate -Parameters @{ P = $plan } { param($P) ConvertTo-VacatePlanHtml -Plan $P }

            [IO.File]::WriteAllText((Join-Path $runDir 'plan.json'), $planJson)
            [IO.File]::WriteAllText((Join-Path $runDir 'plan.md'), $planMd)
            [IO.File]::WriteAllText((Join-Path $runDir 'plan.html'), $planHtml)

            return $runDir
        }
    }

    AfterAll {
        # Restore module rules root
        if ($null -ne $script:origRulesRoot) {
            InModuleScope Vacate -Parameters @{ P = $script:origRulesRoot } {
                param($P) $script:VacateRulesRoot = $P
            }
        }
        # Cleanup temporary test directory
        if ([IO.Directory]::Exists($script:tempRoot)) {
            try { [IO.Directory]::Delete($script:tempRoot, $true) } catch { $null = $_ }
        }
    }

    Context 'Dry run preview (D52)' {
        It 'leaves the scanned profile tree completely unchanged during dry run (write-spy)' {
            $runDir = script:New-TestCleanRun
            $planObj = (Read-TestJson -Path ((Join-Path $runDir 'plan.json')))
            $fileStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.file' }).step

            # Warm-up read: the first traversal can update NTFS folder metadata (see Scan.Integration).
            $null = Get-VacateTreeSnapshot -Path $script:tree
            $before = Get-VacateTreeSnapshot -Path $script:tree
            Invoke-VacateClean -Run $runDir -Steps @($fileStep) -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform

            $after = Get-VacateTreeSnapshot -Path $script:tree
            $diff = Compare-VacateTreeSnapshot -Before $before -After $after -Ignore @($runDir)
            @($diff).Count | Should -Be 0

            Test-Path (Join-Path $runDir 'clean-preview.md') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:trashRoot).Count | Should -Be 0
        }
    }

    Context 'Confirmation and machine safety (D50, D52)' {
        It 'refuses execution without -Confirm (D52)' {
            $runDir = script:New-TestCleanRun
            $planObj = (Read-TestJson -Path ((Join-Path $runDir 'plan.json')))
            $fileStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.file' }).step

            { Invoke-VacateClean -Run $runDir -Steps @($fileStep) -Execute -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform } | Should -Throw
            Test-Path $script:eligibleFilePath | Should -BeTrue
        }

        It 'refuses execution when -Confirm does not match current machine name (D52)' {
            $runDir = script:New-TestCleanRun
            $planObj = (Read-TestJson -Path ((Join-Path $runDir 'plan.json')))
            $fileStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.file' }).step

            $wrongMachine = 'DEFINITELY-WRONG-MACHINE-NAME-99'
            { Invoke-VacateClean -Run $runDir -Steps @($fileStep) -Execute -Confirm $wrongMachine -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform } | Should -Throw
            Test-Path $script:eligibleFilePath | Should -BeTrue
        }

        It 'refuses -Execute in an administrator or root session' {
            if (-not $script:elevated) { Set-ItResult -Skipped -Because 'only meaningful in an elevated session'; return }
            $runDir = script:New-TestCleanRun
            $planObj = (Read-TestJson -Path ((Join-Path $runDir 'plan.json')))
            $fileStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.file' }).step
            { Invoke-VacateClean -Run $runDir -Steps @($fileStep) -Execute -Confirm ([Environment]::MachineName) -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform } | Should -Throw '*not as administrator or root*'
            Test-Path $script:eligibleFilePath | Should -BeTrue
        }

        It 'refuses execution without -Steps (D52)' {
            $runDir = script:New-TestCleanRun
            $machine = [Environment]::MachineName
            { Invoke-VacateClean -Run $runDir -Execute -Confirm $machine -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform } | Should -Throw
        }

        It 'refuses clean execution and dry run on a redacted run (D50)' {
            $redactedRunDir = script:New-TestCleanRun -Redact

            $repObj = (Read-TestJson -Path ((Join-Path $redactedRunDir 'report.json')))
            $repObj.scan.redacted | Should -BeTrue

            $planObj = (Read-TestJson -Path ((Join-Path $redactedRunDir 'plan.json')))
            $fileStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.file' }).step

            $machine = [Environment]::MachineName
            { Invoke-VacateClean -Run $redactedRunDir -Steps @($fileStep) -Execute -Confirm $machine -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform } | Should -Throw
            { Invoke-VacateClean -Run $redactedRunDir -Steps @($fileStep) -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform } | Should -Throw

            Test-Path $script:eligibleFilePath | Should -BeTrue
        }

        It 'refuses execution when run folder is missing report.json or plan.json' {
            $missingRunDir = Join-Path $script:runsRoot ('run-missing-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($missingRunDir)
            $machine = [Environment]::MachineName
            { Invoke-VacateClean -Run $missingRunDir -Steps @(1) -Execute -Confirm $machine -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform } | Should -Throw
        }
    }

    Context 'Step eligibility and selective execution (D51)' {
        It 'refuses ineligible wallet step while an eligible step in the same call proceeds (D51)' {
            if ($script:elevated) { Set-ItResult -Skipped -Because 'clean refuses elevated sessions (this one is elevated)'; return }
            # Ensure fresh files
            [IO.File]::WriteAllText($script:eligibleFilePath, 'test eligible file content')
            [IO.File]::WriteAllText($script:walletFilePath, 'crypto wallet private key material')

            $runDir = script:New-TestCleanRun
            $planObj = (Read-TestJson -Path ((Join-Path $runDir 'plan.json')))
            $fileStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.file' }).step
            $walletStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.wallet' }).step

            $machine = [Environment]::MachineName
            Invoke-VacateClean -Run $runDir -Steps @($fileStep, $walletStep) -Execute -Confirm $machine -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform

            # Eligible file was moved to trash
            Test-Path $script:eligibleFilePath | Should -BeFalse
            # Ineligible wallet was refused and remains in user profile
            Test-Path $script:walletFilePath | Should -BeTrue

            # Reports written to run folder
            Test-Path (Join-Path $runDir 'clean.json') | Should -BeTrue
            Test-Path (Join-Path $runDir 'clean-report.md') | Should -BeTrue
        }
    }

    Context 'Reparse point swap detection at execute time (D50)' {
        It 'refuses to clean a target swapped for a junction or symlink after planning (D50)' {
            if ($script:elevated) { Set-ItResult -Skipped -Because 'clean refuses elevated sessions (this one is elevated)'; return }
            if (-not [IO.Directory]::Exists($script:swappedDirPath)) {
                [void][IO.Directory]::CreateDirectory($script:swappedDirPath)
                [IO.File]::WriteAllText($script:swappedFile, 'original content')
            }

            $runDir = script:New-TestCleanRun
            $planObj = (Read-TestJson -Path ((Join-Path $runDir 'plan.json')))
            $swappedStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.swapped' }).step

            # Replace normal directory with junction/symlink pointing to outside target
            [IO.Directory]::Delete($script:swappedDirPath, $true)
            if ($script:onWindows) {
                New-Item -ItemType Junction -Path $script:swappedDirPath -Value $script:outsideTarget | Out-Null
            } else {
                New-Item -ItemType SymbolicLink -Path $script:swappedDirPath -Target $script:outsideTarget | Out-Null
            }

            try {
                $machine = [Environment]::MachineName
                Invoke-VacateClean -Run $runDir -Steps @($swappedStep) -Execute -Confirm $machine -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform

                # Outside target must be untouched
                Test-Path $script:secretOutsideFile | Should -BeTrue
                [IO.File]::ReadAllText($script:secretOutsideFile) | Should -Be 'secret outside data'
            }
            finally {
                if ([IO.Directory]::Exists($script:swappedDirPath)) {
                    try { [IO.Directory]::Delete($script:swappedDirPath) } catch { $null = $_ }
                }
            }
        }
    }

    Context 'Undo log and complete restoration (D53)' {
        It 'writes undo.json after each move and restores all moved files and directories (D53)' {
            if ($script:elevated) { Set-ItResult -Skipped -Because 'clean refuses elevated sessions (this one is elevated)'; return }
            [IO.File]::WriteAllText($script:eligibleFilePath, 'test eligible file content')
            if (-not [IO.Directory]::Exists($script:eligibleSubDirPath)) {
                [void][IO.Directory]::CreateDirectory($script:eligibleSubDirPath)
            }
            [IO.File]::WriteAllText($script:treeFile1, 'tree file 1')
            [IO.File]::WriteAllText($script:treeFile2, 'tree file 2')

            $runDir = script:New-TestCleanRun
            $planObj = (Read-TestJson -Path ((Join-Path $runDir 'plan.json')))
            $fileStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.file' }).step
            $treeStep = ($planObj.steps | Where-Object { $_.ruleId -eq 'clean.test.tree' }).step

            $profileSnapshotBefore = Get-VacateTreeSnapshot -Path $script:homeDir

            $machine = [Environment]::MachineName
            Invoke-VacateClean -Run $runDir -Steps @($fileStep, $treeStep) -Execute -Confirm $machine -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform

            Test-Path $script:eligibleFilePath | Should -BeFalse
            Test-Path $script:eligibleDirPath | Should -BeFalse

            # undo.json written
            $undoJsonPath = Join-Path $runDir 'undo.json'
            Test-Path $undoJsonPath | Should -BeTrue
            $undoObj = (Read-TestJson -Path ($undoJsonPath))
            $undoObj.schemaVersion | Should -Be '1.0'
            $undoObj.platform | Should -Be $script:platformName
            $undoObj.entries.Count | Should -BeGreaterThan 0

            # Dry-run undo preview
            Invoke-VacateUndo -Run $runDir -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform
            Test-Path (Join-Path $runDir 'undo-preview.md') | Should -BeTrue
            Test-Path $script:eligibleFilePath | Should -BeFalse

            # Undo without -Confirm or with wrong machine refuses
            { Invoke-VacateUndo -Run $runDir -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform -Execute } | Should -Throw
            { Invoke-VacateUndo -Run $runDir -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform -Execute -Confirm 'WRONG-MACHINE' } | Should -Throw

            # Execute undo
            Invoke-VacateUndo -Run $runDir -TrashRoot $script:trashRoot -PlatformProfile $script:ctx.Platform -Execute -Confirm $machine

            # Restores file and directory
            Test-Path $script:eligibleFilePath | Should -BeTrue
            Test-Path $script:eligibleDirPath | Should -BeTrue
            Test-Path $script:treeFile1 | Should -BeTrue
            Test-Path $script:treeFile2 | Should -BeTrue

            $profileSnapshotAfter = Get-VacateTreeSnapshot -Path $script:homeDir
            $diff = Compare-VacateTreeSnapshot -Before $profileSnapshotBefore -After $profileSnapshotAfter -Ignore @($script:swappedDirPath)
            @($diff).Count | Should -Be 0
        }
    }
}
