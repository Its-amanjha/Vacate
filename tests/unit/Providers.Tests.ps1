# Providers.Tests.ps1 - unit tests for read-only filesystem/registry providers and walker.
# Owner: Gemini. PowerShell 5.1 compatible. ASCII only.

$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop')
if (-not $script:onWindows) {
    $runtime = [System.Runtime.InteropServices.RuntimeInformation]
    if ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        $script:onWindows = $true
    }
}

$script:onLinux = $false
if (-not $script:onWindows) {
    $runtime = [System.Runtime.InteropServices.RuntimeInformation]
    if ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
        $script:onLinux = $true
    }
}

$script:isRoot = ([Environment]::UserName -eq 'root')

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('vacate_prov_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tempRoot | Out-Null

    $onWin = ($PSVersionTable.PSEdition -eq 'Desktop' -or (Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

    $script:testProfile = [pscustomobject][ordered]@{
        Name          = if ($onWin) { 'windows' } else { 'linux' }
        CaseSensitive = (-not $onWin)
        Comparison    = if ($onWin) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        Separator     = if ($onWin) { [char]'\' } else { [char]'/' }
        Roots         = [ordered]@{ HOME = $script:tempRoot }
        HomePath      = $script:tempRoot
        UsersRoot     = $script:tempRoot
        UserName      = 'geminitester'
    }
}

AfterAll {
    if ($null -ne $script:winDeniedAcl -and $null -ne $script:winDeniedRule -and (Test-Path -LiteralPath $script:winDeniedPath)) {
        try {
            $script:winDeniedAcl.RemoveAccessRule($script:winDeniedRule)
            Set-Acl -Path $script:winDeniedPath -AclObject $script:winDeniedAcl
        }
        catch {
            $null = $_
        }
    }

    if ($null -ne $script:linuxDeniedPath -and (Test-Path -LiteralPath $script:linuxDeniedPath)) {
        try {
            [System.IO.File]::SetUnixFileMode($script:linuxDeniedPath, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        catch {
            $null = $_
        }
    }

    if (Test-Path -LiteralPath $script:tempRoot) {
        Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-VacateFileSystemProvider' {
    It 'exposes exactly two ScriptMethods: GetItem and GetChildren' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $methods = @($fs.PSObject.Methods | Where-Object { $_.MemberType -eq 'ScriptMethod' } | Select-Object -ExpandProperty Name)
        $methods.Length | Should -Be 2
        $methods | Should -Contain 'GetItem'
        $methods | Should -Contain 'GetChildren'
    }

    It 'GetItem returns FileInfo for file, DirectoryInfo for directory, null for missing' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }

        $f = Join-Path $script:tempRoot 'item_file.txt'
        [System.IO.File]::WriteAllText($f, 'item test')
        $itemFile = $fs.GetItem($f)
        $itemFile | Should -Not -BeNullOrEmpty
        $itemFile -is [System.IO.FileInfo] | Should -BeTrue
        $itemFile.Length | Should -Be 9

        $d = Join-Path $script:tempRoot 'item_dir'
        New-Item -ItemType Directory -Path $d | Out-Null
        $itemDir = $fs.GetItem($d)
        $itemDir | Should -Not -BeNullOrEmpty
        $itemDir -is [System.IO.DirectoryInfo] | Should -BeTrue

        $missing = Join-Path $script:tempRoot 'item_missing.txt'
        $itemMissing = $fs.GetItem($missing)
        $itemMissing | Should -BeNullOrEmpty
    }

    It 'GetChildren returns items sorted ordinal by Name with Denied = false' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $d = Join-Path $script:tempRoot 'children_dir'
        New-Item -ItemType Directory -Path $d | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $d 'z_file.txt'), 'z')
        [System.IO.File]::WriteAllText((Join-Path $d 'a_file.txt'), 'a')
        New-Item -ItemType Directory -Path (Join-Path $d 'm_dir') | Out-Null

        $res = $fs.GetChildren($d)
        $res.Denied | Should -BeFalse
        $res.Items.Count | Should -Be 3
        $res.Items[0].Name | Should -Be 'a_file.txt'
        $res.Items[1].Name | Should -Be 'm_dir'
        $res.Items[2].Name | Should -Be 'z_file.txt'
    }

    It 'GetChildren returns Denied = true on non-existent directory' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $missing = Join-Path $script:tempRoot 'nonexistent_folder'
        $res = $fs.GetChildren($missing)
        $res.Denied | Should -BeTrue
        $res.Items.Count | Should -Be 0
    }
}

Describe 'Invoke-VacateWalk' {
    It '1. counts files, directories, total bytes and max LastWriteTimeUtc exactly' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $dir = Join-Path $script:tempRoot 'walk_exact'
        New-Item -ItemType Directory -Path $dir | Out-Null

        $f1 = Join-Path $dir 'file1.txt'
        [System.IO.File]::WriteAllText($f1, '1234567890') # 10 bytes
        $t1 = [DateTime]::SpecifyKind([DateTime]'2026-01-01T10:00:00', [System.DateTimeKind]::Utc)
        [System.IO.File]::SetLastWriteTimeUtc($f1, $t1)

        $f2 = Join-Path $dir 'file2.txt'
        [System.IO.File]::WriteAllText($f2, '12345678901234567890') # 20 bytes
        $t2 = [DateTime]::SpecifyKind([DateTime]'2026-01-02T10:00:00', [System.DateTimeKind]::Utc)
        [System.IO.File]::SetLastWriteTimeUtc($f2, $t2)

        $sub = Join-Path $dir 'sub'
        New-Item -ItemType Directory -Path $sub | Out-Null
        $f3 = Join-Path $sub 'file3.txt'
        [System.IO.File]::WriteAllText($f3, '123456789012345678901234567890') # 30 bytes
        $t3 = [DateTime]::SpecifyKind([DateTime]'2026-01-03T10:00:00', [System.DateTimeKind]::Utc)
        [System.IO.File]::SetLastWriteTimeUtc($f3, $t3)

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $dir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.Files | Should -Be 3
        $res.Directories | Should -Be 1
        $res.SizeBytes | Should -Be 60
        $res.LastWriteTimeUtc | Should -Be $t3
        $res.Truncated | Should -BeFalse
        $res.TimedOut | Should -BeFalse
        $res.SkippedLinks | Should -Be 0
    }

    It 'describes a single file when -Path is a file' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $f = Join-Path $script:tempRoot 'single_file.txt'
        [System.IO.File]::WriteAllText($f, 'hello world') # 11 bytes

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $f; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $false -Include $null -MaxEntries 10 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.Files | Should -Be 1
        $res.Directories | Should -Be 0
        $res.SizeBytes | Should -Be 11
        $res.Samples | Should -Be @('single_file.txt')
    }

    It '2. caps samples at max 3 and is deterministic across two runs' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $dir = Join-Path $script:tempRoot 'walk_samples'
        New-Item -ItemType Directory -Path $dir | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $dir 'alpha.txt'), 'a')
        [System.IO.File]::WriteAllText((Join-Path $dir 'bravo.txt'), 'b')
        [System.IO.File]::WriteAllText((Join-Path $dir 'charlie.txt'), 'c')
        [System.IO.File]::WriteAllText((Join-Path $dir 'delta.txt'), 'd')
        [System.IO.File]::WriteAllText((Join-Path $dir 'echo.txt'), 'e')

        $run1 = InModuleScope Vacate -Parameters @{ FS = $fs; P = $dir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $run2 = InModuleScope Vacate -Parameters @{ FS = $fs; P = $dir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $run1.Samples.Length | Should -Be 3
        $run1.Samples[0] | Should -Be 'alpha.txt'
        $run1.Samples[1] | Should -Be 'bravo.txt'
        $run1.Samples[2] | Should -Be 'charlie.txt'

        $run2.Samples.Length | Should -Be 3
        $run2.Samples[0] | Should -Be 'alpha.txt'
        $run2.Samples[1] | Should -Be 'bravo.txt'
        $run2.Samples[2] | Should -Be 'charlie.txt'
    }

    It '3. sets Truncated = true when MaxEntries = 5 on a 20-entry tree' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $dir = Join-Path $script:tempRoot 'walk_trunc'
        New-Item -ItemType Directory -Path $dir | Out-Null

        for ($i = 1; $i -le 20; $i++) {
            $name = ('file_{0:D2}.txt' -f $i)
            [System.IO.File]::WriteAllText((Join-Path $dir $name), 'x')
        }

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $dir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 5 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.Truncated | Should -BeTrue
        $res.Files | Should -BeLessOrEqual 5
        $res.Files | Should -Be 5
        ($res.Files + $res.Directories) | Should -BeLessOrEqual 5
    }

    It '4. sets TimedOut = true and counts nothing when Deadline is already in the past' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $dir = Join-Path $script:tempRoot 'walk_timeout'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'test.txt'), 'data')

        $past = [DateTime]::UtcNow.AddSeconds(-10)

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $dir; Pl = $script:testProfile; D = $past } {
            param($FS, $P, $Pl, $D)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline $D -Platform $Pl
        }

        $res.TimedOut | Should -BeTrue
        $res.Files | Should -Be 0
        $res.Directories | Should -Be 0
        $res.SizeBytes | Should -Be 0
        $res.Samples.Length | Should -Be 0
    }

    It '5. counts junction or symlink in SkippedLinks and does not count target files' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $treeDir = Join-Path $script:tempRoot 'walk_link_tree'
        New-Item -ItemType Directory -Path $treeDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $treeDir 'local.txt'), 'local')

        $targetDir = Join-Path $script:tempRoot 'walk_link_target'
        New-Item -ItemType Directory -Path $targetDir | Out-Null
        for ($i = 1; $i -le 10; $i++) {
            [System.IO.File]::WriteAllText((Join-Path $targetDir ('target_{0}.txt' -f $i)), 'data')
        }

        $linkPath = Join-Path $treeDir 'link_folder'
        $onWin = ($PSVersionTable.PSEdition -eq 'Desktop' -or (Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
        if ($onWin) {
            New-Item -ItemType Junction -Path $linkPath -Value $targetDir | Out-Null
        }
        else {
            New-Item -ItemType SymbolicLink -Path $linkPath -Value $targetDir | Out-Null
        }

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $treeDir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.SkippedLinks | Should -Be 1
        $res.Files | Should -Be 1
        $res.Samples | Should -Be @('local.txt')
    }

    It 'returns SkippedLinks = 1 and zeros if -Path itself is a reparse point' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $targetDir = Join-Path $script:tempRoot 'direct_link_target'
        New-Item -ItemType Directory -Path $targetDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $targetDir 'inside.txt'), 'inside')

        $linkPath = Join-Path $script:tempRoot 'direct_link'
        $onWin = ($PSVersionTable.PSEdition -eq 'Desktop' -or (Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
        if ($onWin) {
            New-Item -ItemType Junction -Path $linkPath -Value $targetDir | Out-Null
        }
        else {
            New-Item -ItemType SymbolicLink -Path $linkPath -Value $targetDir | Out-Null
        }

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $linkPath; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.SkippedLinks | Should -Be 1
        $res.Files | Should -Be 0
        $res.Directories | Should -Be 0
        $res.SizeBytes | Should -Be 0
    }

    It '6. records permission-denied directory in DeniedPaths without throwing (Windows)' -Skip:(-not $script:onWindows) {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $treeDir = Join-Path $script:tempRoot 'perm_win'
        New-Item -ItemType Directory -Path $treeDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $treeDir 'ok.txt'), 'ok')

        $sub = Join-Path $treeDir 'forbidden'
        New-Item -ItemType Directory -Path $sub | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sub 'hidden.txt'), 'hidden')

        $script:winDeniedPath = $sub
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $script:winDeniedRule = New-Object Security.AccessControl.FileSystemAccessRule($user, 'ListDirectory', 'Deny')
        $script:winDeniedAcl = Get-Acl -LiteralPath $sub
        $aclCopy = Get-Acl -LiteralPath $sub
        $aclCopy.AddAccessRule($script:winDeniedRule)
        Set-Acl -Path $sub -AclObject $aclCopy

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $treeDir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.DeniedPaths | Should -Contain $sub
        $res.Files | Should -Be 1
        $res.Samples | Should -Be @('ok.txt')
    }

    It '6. records permission-denied directory in DeniedPaths without throwing (Linux)' -Skip:(-not $script:onLinux -or $script:isRoot) {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $treeDir = Join-Path $script:tempRoot 'perm_linux'
        New-Item -ItemType Directory -Path $treeDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $treeDir 'ok.txt'), 'ok')

        $sub = Join-Path $treeDir 'forbidden'
        New-Item -ItemType Directory -Path $sub | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sub 'hidden.txt'), 'hidden')

        $script:linuxDeniedPath = $sub
        [System.IO.File]::SetUnixFileMode($sub, [System.IO.UnixFileMode]::None)

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $treeDir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include $null -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.DeniedPaths | Should -Contain $sub
        $res.Files | Should -Be 1
    }

    It '7. -Include *.json counts only matching files' {
        $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
        $treeDir = Join-Path $script:tempRoot 'walk_include'
        New-Item -ItemType Directory -Path $treeDir | Out-Null

        [System.IO.File]::WriteAllText((Join-Path $treeDir 'app.json'), '12345') # 5 bytes
        [System.IO.File]::WriteAllText((Join-Path $treeDir 'notes.txt'), '12345678901234567890') # 20 bytes

        $sub = Join-Path $treeDir 'sub'
        New-Item -ItemType Directory -Path $sub | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sub 'config.json'), '1234567890') # 10 bytes
        [System.IO.File]::WriteAllText((Join-Path $sub 'debug.log'), '123456789012345678901234567890') # 30 bytes

        $res = InModuleScope Vacate -Parameters @{ FS = $fs; P = $treeDir; Pl = $script:testProfile } {
            param($FS, $P, $Pl)
            Invoke-VacateWalk -FileSystem $FS -Path $P -Recurse $true -Include '*.json' -MaxEntries 100 -Deadline ([DateTime]::UtcNow.AddMinutes(1)) -Platform $Pl
        }

        $res.Files | Should -Be 2
        $res.Directories | Should -Be 1
        $res.SizeBytes | Should -Be 15
        $res.Samples.Length | Should -Be 2
        $res.Samples | Should -Contain 'app.json'
        $res.Samples | Should -Contain 'config.json'
    }
}

Describe 'New-VacateRegistryProvider' {
    BeforeAll {
        $onWin = ($PSVersionTable.PSEdition -eq 'Desktop' -or (Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
        if ($onWin) {
            $guid = [System.Guid]::NewGuid().ToString('N')
            $script:testRegKeyPath = 'Software\VacateTest\' + $guid
            $hkcu = [Microsoft.Win32.Registry]::CurrentUser
            $k = $hkcu.CreateSubKey($script:testRegKeyPath)
            $k.SetValue('testVal1', 'hello')
            $k.SetValue('testVal2', 99)
            $child = $k.CreateSubKey('childSubKey')
            $child.Dispose()
            $k.Dispose()
        }
    }

    AfterAll {
        $onWin = ($PSVersionTable.PSEdition -eq 'Desktop' -or (Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
        if ($onWin -and $null -ne $script:testRegKeyPath) {
            try {
                $hkcu = [Microsoft.Win32.Registry]::CurrentUser
                $hkcu.DeleteSubKeyTree($script:testRegKeyPath)
            }
            catch {
                $null = $_
            }
        }
    }

    It '8. reads keys and values via -RegistryBase, missing key returns null (Windows)' -Skip:(-not $script:onWindows) {
        $regBase = @{
            HKCU = @{ Hive = 'HKCU'; Prefix = $script:testRegKeyPath }
        }

        $provider = InModuleScope Vacate -Parameters @{ RB = $regBase } {
            param($RB)
            New-VacateRegistryProvider -RegistryBase $RB
        }

        $keyInfo = $provider.GetKey('HKCU', '', 'Default')
        $keyInfo | Should -Not -BeNullOrEmpty
        $keyInfo.ValueCount | Should -Be 2
        $keyInfo.SubKeyCount | Should -Be 1
        $keyInfo.SubKeyNames | Should -Be @('childSubKey')

        $missingInfo = $provider.GetKey('HKCU', 'non_existent_key', 'Default')
        $missingInfo | Should -BeNullOrEmpty
    }

    It '8. throws provider: registry is Windows-only on non-Windows platforms' -Skip:($script:onWindows) {
        {
            InModuleScope Vacate {
                New-VacateRegistryProvider -RegistryBase @{}
            }
        } | Should -Throw '*provider: registry is Windows-only*'
    }
}

Describe 'Providers.ps1 static check' {
    It '10. contains none of the 10 banned tokens' {
        $file = Join-Path $PSScriptRoot '../../src/Vacate/Private/Providers.ps1'
        $text = [System.IO.File]::ReadAllText($file)
        $banned = @(
            'Get-Content',
            'OpenRead',
            'ReadAll',
            'OpenWrite',
            'SetValue',
            'CreateSubKey',
            'Delete',
            'Remove-Item',
            'Invoke-Expression',
            'Add-Type'
        )
        foreach ($b in $banned) {
            $text | Should -Not -Match [regex]::Escape($b)
        }
    }
}
