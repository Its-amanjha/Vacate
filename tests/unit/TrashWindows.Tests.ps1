# TrashWindows.Tests.ps1 - Windows Recycle Bin mover.
# Real moves, but only files and folders created under [IO.Path]::GetTempPath(). Every item
# moved to the Recycle Bin is restored (by the test, or by AfterAll as a safety net), then the
# temp folder is removed. Restore leaves the small $I record behind (no delete API is allowed in
# the mover). Skipped on non-Windows platforms. PowerShell 5.1 compatible. ASCII only.

$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

    $script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('vacate_trashwin_' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:tempRoot)
    if ($script:onWindows) {
        $script:tempRoot = InModuleScope Vacate -Parameters @{ P = $script:tempRoot } { param($P) Get-VacateTrashWindowsLongPath -FullPath $P }
    }

    function Invoke-TestMove {
        param([string]$Path)
        return (InModuleScope Vacate -Parameters @{ P = $Path } { param($P) Move-VacateItemToTrashWindows -Path $P })
    }

    function Invoke-TestRestore {
        param([AllowNull()][string]$TrashLocation, [string]$Path)
        return (InModuleScope Vacate -Parameters @{ P = $Path; T = $TrashLocation } {
                param($P, $T)
                Restore-VacateItemFromTrashWindows -TrashLocation $T -OriginalPath $P
            })
    }

    function Get-TestBinRecord {
        # The $I record behind a $R path, read with the mover's own parser.
        param([string]$TrashLocation)
        $leaf = [IO.Path]::GetFileName($TrashLocation)
        $info = Join-Path ([IO.Path]::GetDirectoryName($TrashLocation)) ('$I' + $leaf.Substring(2))
        return (InModuleScope Vacate -Parameters @{ I = $info } { param($I) Read-VacateTrashWindowsRecord -InfoPath $I })
    }

    function Restore-TestTrashLeftover {
        # Safety net: puts back anything from this test's temp folder that is still in the bin.
        if (-not $script:onWindows) { return }
        $prefix = $script:tempRoot.TrimEnd('\') + '\'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sidFolder = Join-Path (Join-Path ([IO.Path]::GetPathRoot($script:tempRoot)) '$Recycle.Bin') $sid
        $records = @(InModuleScope Vacate -Parameters @{ S = $sidFolder } { param($S) Get-VacateTrashWindowsRecord -SidFolder $S })
        foreach ($record in $records) {
            if (-not $record.originalPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not ([IO.File]::Exists($record.trashPath) -or [IO.Directory]::Exists($record.trashPath))) { continue }
            $parent = [IO.Path]::GetDirectoryName($record.originalPath)
            if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
            $null = Invoke-TestRestore -TrashLocation $record.trashPath -Path $record.originalPath
        }
    }
}

AfterAll {
    Restore-TestTrashLeftover
    if ([IO.Directory]::Exists($script:tempRoot)) {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Move-VacateItemToTrashWindows' {
    It 'moves a file to the Recycle Bin and Restore puts it back' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('file-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'vacate test file')

        $moved = Invoke-TestMove -Path $path
        $moved.PSObject.Properties.Name -join ',' | Should -Be 'ok,trashLocation,error'
        $moved.error | Should -Be ''
        $moved.ok | Should -BeTrue
        [IO.File]::Exists($path) | Should -BeFalse
        $moved.trashLocation | Should -Match '\\\$Recycle\.Bin\\S-[0-9-]+\\\$R[^\\]+\.txt$'
        [IO.File]::Exists($moved.trashLocation) | Should -BeTrue
        $record = Get-TestBinRecord -TrashLocation $moved.trashLocation
        $record | Should -Not -BeNullOrEmpty
        $record.originalPath | Should -Be $path
        $record.sizeBytes | Should -Be 16

        $restored = Invoke-TestRestore -TrashLocation $moved.trashLocation -Path $path
        $restored.PSObject.Properties.Name -join ',' | Should -Be 'ok,error'
        $restored.error | Should -Be ''
        $restored.ok | Should -BeTrue
        [IO.File]::ReadAllText($path) | Should -Be 'vacate test file'
        [IO.File]::Exists($moved.trashLocation) | Should -BeFalse
    }

    It 'moves a folder with contents and Restore puts the tree back' -Skip:(-not $script:onWindows) {
        $folder = Join-Path $script:tempRoot ('folder-' + [guid]::NewGuid().ToString('N'))
        $inner = Join-Path $folder 'inner'
        [void][IO.Directory]::CreateDirectory($inner)
        [IO.File]::WriteAllText((Join-Path $inner 'nested.txt'), 'nested file')

        $moved = Invoke-TestMove -Path $folder
        $moved.error | Should -Be ''
        $moved.ok | Should -BeTrue
        [IO.Directory]::Exists($folder) | Should -BeFalse
        [IO.Directory]::Exists($moved.trashLocation) | Should -BeTrue
        (Get-TestBinRecord -TrashLocation $moved.trashLocation).originalPath | Should -Be $folder

        $restored = Invoke-TestRestore -TrashLocation $moved.trashLocation -Path $folder
        $restored.error | Should -Be ''
        $restored.ok | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $inner 'nested.txt')) | Should -Be 'nested file'
        [IO.Directory]::Exists($moved.trashLocation) | Should -BeFalse
    }

    It 'restores by original path when no trash location is recorded' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('fallback-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'fallback')
        $moved = Invoke-TestMove -Path $path
        $moved.ok | Should -BeTrue

        $restored = Invoke-TestRestore -TrashLocation $null -Path $path
        $restored.error | Should -Be ''
        $restored.ok | Should -BeTrue
        [IO.File]::ReadAllText($path) | Should -Be 'fallback'
    }

    It 'restores by original path when the recorded trash location is wrong' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('stale-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'stale location')
        $moved = Invoke-TestMove -Path $path
        $moved.ok | Should -BeTrue

        $restored = Invoke-TestRestore -TrashLocation 'C:\$Recycle.Bin\does-not-exist\$R000000.txt' -Path $path
        $restored.ok | Should -BeTrue
        [IO.File]::Exists($path) | Should -BeTrue
    }

    It 'refuses a missing item' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('missing-' + [guid]::NewGuid().ToString('N') + '.txt')
        $result = Invoke-TestMove -Path $path
        $result.ok | Should -BeFalse
        $result.trashLocation | Should -BeNullOrEmpty
        $result.error | Should -Be 'item not found'
    }

    It 'refuses relative, network and root paths' -Skip:(-not $script:onWindows) {
        (Invoke-TestMove -Path 'relative\file.txt').error | Should -Be 'path is not absolute'
        (Invoke-TestMove -Path '\\server\share\file.txt').error | Should -Be 'network and device paths are not supported'
        (Invoke-TestMove -Path 'C:\').error | Should -Be 'refusing to move a volume root'
    }

    It 'refuses a path longer than the Recycle Bin accepts' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot (('x' * 250) + '.txt')
        $result = Invoke-TestMove -Path $path
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'too long'
    }

    It 'refuses a read-only file and leaves it in place' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('readonly-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'read only')
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::ReadOnly)
        try {
            $result = Invoke-TestMove -Path $path
            $result.ok | Should -BeFalse
            $result.error | Should -Be 'refusing to move a read-only file'
            [IO.File]::Exists($path) | Should -BeTrue
        }
        finally {
            [IO.File]::SetAttributes($path, [IO.FileAttributes]::Normal)
        }
    }

    It 'refuses an item not smaller than the Recycle Bin limit and leaves it in place' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('big-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'pretend this is huge')
        $result = InModuleScope Vacate -Parameters @{ P = $path } {
            param($P)
            Mock Get-VacateTrashWindowsBinSetting { [pscustomobject]@{ ok = $true; error = ''; capacityBytes = [int64]10 } }
            Move-VacateItemToTrashWindows -Path $P
        }
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'Recycle Bin limit'
        [IO.File]::Exists($path) | Should -BeTrue
    }

    It 'refuses when the Recycle Bin is set to delete immediately and leaves the item in place' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('nuke-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'keep')
        $result = InModuleScope Vacate -Parameters @{ P = $path } {
            param($P)
            Mock Get-VacateTrashWindowsRegistryValue { 1 } -ParameterFilter { $Name -eq 'NukeOnDelete' }
            Move-VacateItemToTrashWindows -Path $P
        }
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'NukeOnDelete'
        [IO.File]::Exists($path) | Should -BeTrue
    }

    It 'refuses a drive that is not a local fixed drive' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('usb-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'keep')
        $result = InModuleScope Vacate -Parameters @{ P = $path } {
            param($P)
            Mock Get-VacateTrashWindowsVolume { [pscustomobject]@{ ok = $false; error = 'only local fixed drives are supported'; root = $null; totalBytes = [int64]0; sidFolder = $null } }
            Move-VacateItemToTrashWindows -Path $P
        }
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'fixed'
        [IO.File]::Exists($path) | Should -BeTrue
    }
}

Describe 'Restore-VacateItemFromTrashWindows' {
    It 'refuses to overwrite an existing original path' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('exists-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'keep me')
        $result = Invoke-TestRestore -TrashLocation $null -Path $path
        $result.ok | Should -BeFalse
        $result.error | Should -Be 'the original path already exists; refusing to overwrite it'
        [IO.File]::ReadAllText($path) | Should -Be 'keep me'
    }

    It 'returns ok=false when the item is not in the Recycle Bin' -Skip:(-not $script:onWindows) {
        $path = Join-Path $script:tempRoot ('absent-' + [guid]::NewGuid().ToString('N') + '.txt')
        $result = Invoke-TestRestore -TrashLocation $null -Path $path
        $result.ok | Should -BeFalse
        $result.error | Should -Be 'not found in the Recycle Bin'
    }
}

Describe 'Read-VacateTrashWindowsRecord' {
    BeforeAll {
        function Get-TestRecordByte {
            param([int64]$Version, [string]$Original)
            $stream = New-Object System.IO.MemoryStream
            $writer = New-Object System.IO.BinaryWriter -ArgumentList $stream
            $writer.Write([int64]$Version)
            $writer.Write([int64]1234)
            $writer.Write((New-Object DateTime -ArgumentList 2026, 1, 2, 3, 4, 5, ([DateTimeKind]::Utc)).ToFileTimeUtc())
            $text = [Text.Encoding]::Unicode.GetBytes($Original + [char]0)
            if ($Version -eq 2) {
                $writer.Write([int32]($Original.Length + 1))
                $writer.Write($text)
            }
            else {
                $padded = New-Object byte[] 520
                [Array]::Copy($text, $padded, $text.Length)
                $writer.Write($padded)
            }
            $writer.Flush()
            return , $stream.ToArray()
        }
    }

    It 'parses version 1 and version 2 records' -Skip:(-not $script:onWindows) {
        $expected = New-Object DateTime -ArgumentList 2026, 1, 2, 3, 4, 5, ([DateTimeKind]::Utc)
        foreach ($version in @(1, 2)) {
            $info = Join-Path $script:tempRoot ('$IABC12' + $version + '.txt')
            [IO.File]::WriteAllBytes($info, (Get-TestRecordByte -Version $version -Original 'C:\Users\x\old.txt'))
            $record = InModuleScope Vacate -Parameters @{ I = $info } { param($I) Read-VacateTrashWindowsRecord -InfoPath $I }
            $record.version | Should -Be $version
            $record.sizeBytes | Should -Be 1234
            $record.originalPath | Should -Be 'C:\Users\x\old.txt'
            $record.deletedAt | Should -Be $expected
            $record.trashPath | Should -Be (Join-Path $script:tempRoot ('$RABC12' + $version + '.txt'))
        }
    }

    It 'returns null for a malformed record' -Skip:(-not $script:onWindows) {
        $info = Join-Path $script:tempRoot '$IBAD000.txt'
        $bytes = New-Object byte[] 48
        $bytes[0] = 9
        [IO.File]::WriteAllBytes($info, $bytes)
        $record = InModuleScope Vacate -Parameters @{ I = $info } { param($I) Read-VacateTrashWindowsRecord -InfoPath $I }
        $record | Should -BeNullOrEmpty
    }
}
