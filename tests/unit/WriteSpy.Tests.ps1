# WriteSpy.Tests.ps1 - unit tests for tree snapshot, compare, and spy provider.
# Owner: Gemini. PowerShell 5.1 compatible. ASCII only.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    . (Join-Path $PSScriptRoot '../helpers/WriteSpy.ps1')

    $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('vacate_spy_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tempRoot | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:tempRoot) {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-VacateTreeSnapshot and Compare-VacateTreeSnapshot' {
    It 'returns empty snapshot for non-existent path' {
        $nonExistent = Join-Path $script:tempRoot 'missing_dir'
        $snap = Get-VacateTreeSnapshot -Path $nonExistent
        $snap.Count | Should -Be 0
    }

    It 'snapshots a temp tree and detects zero changes on identical trees' {
        $treeDir = Join-Path $script:tempRoot 'tree1'
        New-Item -ItemType Directory -Path $treeDir | Out-Null
        $f1 = Join-Path $treeDir 'file1.txt'
        [System.IO.File]::WriteAllText($f1, 'hello')

        $snap1 = Get-VacateTreeSnapshot -Path $treeDir
        $snap2 = Get-VacateTreeSnapshot -Path $treeDir

        $diff = Compare-VacateTreeSnapshot -Before $snap1 -After $snap2
        $diff.Count | Should -Be 0
    }

    It 'detects added, changed and removed files' {
        $treeDir = Join-Path $script:tempRoot 'tree2'
        New-Item -ItemType Directory -Path $treeDir | Out-Null
        $f1 = Join-Path $treeDir 'f1.txt'
        $f2 = Join-Path $treeDir 'f2.txt'
        [System.IO.File]::WriteAllText($f1, 'one')
        [System.IO.File]::WriteAllText($f2, 'two')

        $snapBefore = Get-VacateTreeSnapshot -Path $treeDir

        # Change f1, remove f2, add f3
        [System.IO.File]::WriteAllText($f1, 'one modified')
        Remove-Item -LiteralPath $f2 -Force
        $f3 = Join-Path $treeDir 'f3.txt'
        [System.IO.File]::WriteAllText($f3, 'three')

        $snapAfter = Get-VacateTreeSnapshot -Path $treeDir

        $diff = Compare-VacateTreeSnapshot -Before $snapBefore -After $snapAfter
        $diff | Should -Contain $f1
        $diff | Should -Contain $f2
        $diff | Should -Contain $f3
        $diff.Count | Should -Be 3
    }

    It 'ignores paths matching -Ignore prefix' {
        $treeDir = Join-Path $script:tempRoot 'tree3'
        $ignoreDir = Join-Path $treeDir 'ignored'
        New-Item -ItemType Directory -Path $ignoreDir | Out-Null
        $f1 = Join-Path $treeDir 'keep.txt'
        [System.IO.File]::WriteAllText($f1, 'keep')

        $snapBefore = Get-VacateTreeSnapshot -Path $treeDir

        $fIgnored = Join-Path $ignoreDir 'secret.txt'
        [System.IO.File]::WriteAllText($fIgnored, 'secret')

        $snapAfter = Get-VacateTreeSnapshot -Path $treeDir

        $diff = Compare-VacateTreeSnapshot -Before $snapBefore -After $snapAfter -Ignore @($ignoreDir)
        $diff.Count | Should -Be 0
    }
}

Describe 'New-VacateSpyFileSystemProvider' {
    It 'spy provider throws spy: write attempted on mutation methods' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $spy = New-VacateSpyFileSystemProvider -Inner $fs

        { $spy.Delete() } | Should -Throw '*spy: write attempted*'
        { $spy.Move() } | Should -Throw '*spy: write attempted*'
        { $spy.Write() } | Should -Throw '*spy: write attempted*'
        { $spy.Create() } | Should -Throw '*spy: write attempted*'
    }

    It 'snapshots tree, runs walk, verifies zero changes, records calls, detects new file' {
        $treeDir = Join-Path $script:tempRoot 'tree_walk'
        New-Item -ItemType Directory -Path $treeDir | Out-Null
        $f1 = Join-Path $treeDir 'data.txt'
        [System.IO.File]::WriteAllText($f1, 'read only data')

        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $spy = New-VacateSpyFileSystemProvider -Inner $fs

        $snapBefore = Get-VacateTreeSnapshot -Path $treeDir

        $platform = [pscustomobject]@{
            Name          = 'test'
            CaseSensitive = $false
            Comparison    = [System.StringComparison]::OrdinalIgnoreCase
            Separator     = [char]'\'
            Roots         = [ordered]@{}
            HomePath      = ''
            UsersRoot     = ''
            UserName      = ''
        }

        $walkRes = InModuleScope Vacate -Parameters @{ S = $spy; P = $treeDir; Pl = $platform } {
            param($S, $P, $Pl)
            Invoke-VacateWalk -FileSystem $S -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $walkRes.Files | Should -Be 1

        $snapAfter = Get-VacateTreeSnapshot -Path $treeDir
        $diff = Compare-VacateTreeSnapshot -Before $snapBefore -After $snapAfter
        $diff.Count | Should -Be 0

        # Spy recorded calls
        $spy.Calls.Count | Should -BeGreaterThan 0
        $spy.Calls[0].Method | Should -Be 'GetItem'

        # After creating a file, compare reports it
        $fNew = Join-Path $treeDir 'new.txt'
        [System.IO.File]::WriteAllText($fNew, 'new content')
        $snapLater = Get-VacateTreeSnapshot -Path $treeDir
        $diffNew = Compare-VacateTreeSnapshot -Before $snapAfter -After $snapLater
        $diffNew | Should -Contain $fNew
    }
}
