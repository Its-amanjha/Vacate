$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

    function Get-TestProfile {
        param([string]$Name, [string]$HomePath = $null, [string]$Users = $null)
        switch ($Name) {
            'windows' { $sep = '\'; $cs = $false; $cmp = [StringComparison]::OrdinalIgnoreCase; if (-not $HomePath) { $HomePath = 'C:\Users\a' }; if (-not $Users) { $Users = 'C:\Users' } }
            'macos' { $sep = '/'; $cs = $false; $cmp = [StringComparison]::OrdinalIgnoreCase; if (-not $HomePath) { $HomePath = '/Users/a' }; if (-not $Users) { $Users = '/Users' } }
            'linux' { $sep = '/'; $cs = $true; $cmp = [StringComparison]::Ordinal; if (-not $HomePath) { $HomePath = '/home/a' }; if (-not $Users) { $Users = '/home' } }
        }
        return [pscustomobject][ordered]@{ Name = $Name; CaseSensitive = $cs; Comparison = $cmp; Separator = [char]$sep; Roots = [ordered]@{ HOME = $HomePath; USERS = $Users }; HomePath = $HomePath; UsersRoot = $Users; UserName = 'a' }
    }

    function Get-TestFileSystem {
        # Minimal real-disk provider with the CONTRACTS section 4 shape (metadata only).
        $fs = [pscustomobject]@{ Calls = (New-Object System.Collections.Generic.List[string]) }
        $fs | Add-Member -MemberType ScriptMethod -Name GetItem -Value {
            param([string]$Path)
            $this.Calls.Add('GetItem ' + $Path)
            if ([IO.Directory]::Exists($Path)) { return (New-Object IO.DirectoryInfo $Path) }
            if ([IO.File]::Exists($Path)) { return (New-Object IO.FileInfo $Path) }
            return $null
        }
        $fs | Add-Member -MemberType ScriptMethod -Name GetChildren -Value {
            param([string]$Path)
            $this.Calls.Add('GetChildren ' + $Path)
            try {
                $items = @((New-Object IO.DirectoryInfo $Path).EnumerateFileSystemInfos())
                $keys = [string[]]@($items | ForEach-Object { $_.Name })
                $arr = [object[]]$items
                if ($arr.Length -gt 1) { [Array]::Sort([Array]$keys, [Array]$arr, [Collections.IComparer][StringComparer]::Ordinal) }
                return @{ Items = $arr; Denied = $false }
            }
            catch { return @{ Items = @(); Denied = $true } }
        }
        return $fs
    }

    function Get-TestTree {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('vacate-jail-' + [guid]::NewGuid().ToString('N'))
        foreach ($d in @('Users/a/AppData/Local/Google/Chrome/User Data/Default', 'Users/a/AppData/Local/Google/Chrome/User Data/Profile 1', 'Users/a/AppData/Local/Google/Chrome/User Data/Crashpad', 'Users/b/Desktop', 'Users/a/[a]', 'Users/a/xyz', 'outside/secret')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $root $d))
        }
        foreach ($f in @('Users/a/AppData/Local/Google/Chrome/User Data/Default/History', 'Users/a/AppData/Local/Google/Chrome/User Data/Profile 1/History', 'Users/a/AppData/Local/Google/Chrome/User Data/Local State', 'Users/b/Desktop/b.txt', 'outside/secret/s.txt')) {
            [IO.File]::WriteAllText((Join-Path $root $f), 'x')
        }
        return $root
    }

    function Get-TreeProfile {
        param([string]$Root)
        $name = 'linux'
        if ($script:onWindows) { $name = 'windows' }
        $p = Get-TestProfile -Name $name -HomePath (Join-Path (Join-Path $Root 'Users') 'a') -Users (Join-Path $Root 'Users')
        return $p
    }
}

Describe 'Split-VacateRulePath' {
    It 'rejects <Bad>' -ForEach @(
        @{ Bad = '..' }, @{ Bad = '.' }, @{ Bad = 'a/../b' }, @{ Bad = '/abs' }, @{ Bad = '\x' }, @{ Bad = 'C:/x' },
        @{ Bad = '\\server\s' }, @{ Bad = 'a\b' }, @{ Bad = '**' }, @{ Bad = 'a//b' }, @{ Bad = 'a<b' }, @{ Bad = ('a' + [char]7) }, @{ Bad = 'a/' }
    ) {
        { InModuleScope Vacate -Parameters @{ B = $Bad } { param($B) Split-VacateRulePath -Path $B } } | Should -Throw -ExpectedMessage 'jail:*'
    }
    It 'accepts a normal glob and the empty path' {
        InModuleScope Vacate {
            @(Split-VacateRulePath -Path 'Google/Chrome/User Data/*/History') | Should -Be @('Google', 'Chrome', 'User Data', '*', 'History')
            @(Split-VacateRulePath -Path '').Count | Should -Be 0
        }
    }
}

Describe 'ConvertTo-VacateNormalizedPath' {
    It 'normalizes Windows paths' {
        InModuleScope Vacate -Parameters @{ P = (Get-TestProfile 'windows') } {
            param($P)
            ConvertTo-VacateNormalizedPath -Path 'C:/Users//a\\Desktop\' -Platform $P | Should -Be 'C:\Users\a\Desktop'
            ConvertTo-VacateNormalizedPath -Path 'C:' -Platform $P | Should -Be 'C:\'
            ConvertTo-VacateNormalizedPath -Path 'C:\' -Platform $P | Should -Be 'C:\'
        }
    }
    It 'normalizes Unix paths and keeps backslashes as name characters' {
        InModuleScope Vacate -Parameters @{ P = (Get-TestProfile 'linux') } {
            param($P)
            ConvertTo-VacateNormalizedPath -Path '/home//a/x/' -Platform $P | Should -Be '/home/a/x'
            ConvertTo-VacateNormalizedPath -Path '/' -Platform $P | Should -Be '/'
            ConvertTo-VacateNormalizedPath -Path '/home/a/odd\name' -Platform $P | Should -Be '/home/a/odd\name'
            ConvertTo-VacateNormalizedPath -Path '/private/var/x' -Platform $P | Should -Be '/private/var/x'
        }
    }
    It 'treats /private/var as /var on macOS' {
        InModuleScope Vacate -Parameters @{ P = (Get-TestProfile 'macos') } {
            param($P)
            ConvertTo-VacateNormalizedPath -Path '/private/var/folders/x' -Platform $P | Should -Be '/var/folders/x'
            ConvertTo-VacateNormalizedPath -Path '/private/tmp' -Platform $P | Should -Be '/tmp'
            ConvertTo-VacateNormalizedPath -Path '/privatevar/x' -Platform $P | Should -Be '/privatevar/x'
            Test-VacatePathUnderRoot -Path '/private/var/log/a' -Root '/var/log' -Platform $P | Should -BeTrue
        }
    }
}

Describe 'Test-VacatePathUnderRoot' {
    It 'does not confuse a sibling prefix with a child' {
        InModuleScope Vacate -Parameters @{ P = (Get-TestProfile 'windows') } {
            param($P)
            Test-VacatePathUnderRoot -Path 'C:\Users\ab' -Root 'C:\Users\a' -Platform $P | Should -BeFalse
            Test-VacatePathUnderRoot -Path 'C:\Users\a\x' -Root 'C:\Users\a' -Platform $P | Should -BeTrue
            Test-VacatePathUnderRoot -Path 'C:\Users\a' -Root 'C:\Users\a\' -Platform $P | Should -BeTrue
            Test-VacatePathUnderRoot -Path 'D:\x' -Root 'C:\' -Platform $P | Should -BeFalse
        }
    }
    It 'matches wrong case on Windows and macOS but not on Linux' {
        InModuleScope Vacate -Parameters @{ W = (Get-TestProfile 'windows'); M = (Get-TestProfile 'macos'); L = (Get-TestProfile 'linux') } {
            param($W, $M, $L)
            Test-VacatePathUnderRoot -Path 'c:\USERS\A\x' -Root 'C:\Users\a' -Platform $W | Should -BeTrue
            Test-VacatePathUnderRoot -Path '/users/A/x' -Root '/Users/a' -Platform $M | Should -BeTrue
            Test-VacatePathUnderRoot -Path '/home/A/x' -Root '/home/a' -Platform $L | Should -BeFalse
        }
    }
    It 'handles paths longer than 260 characters' {
        InModuleScope Vacate -Parameters @{ P = (Get-TestProfile 'windows') } {
            param($P)
            $long = 'C:\Users\a\' + ((1..40 | ForEach-Object { 'segment' + $_ }) -join '\')
            $long.Length | Should -BeGreaterThan 260
            Test-VacatePathUnderRoot -Path $long -Root 'C:\Users\a' -Platform $P | Should -BeTrue
        }
    }
}

Describe 'Test-VacateOtherUserPath and Test-VacateCrossesMount' {
    It 'allows profile names but not their contents' {
        InModuleScope Vacate -Parameters @{ P = (Get-TestProfile 'windows') } {
            param($P)
            Test-VacateOtherUserPath -Path 'C:\Users\bob' -Platform $P | Should -BeFalse
            Test-VacateOtherUserPath -Path 'C:\Users\bob\Desktop' -Platform $P | Should -BeTrue
            Test-VacateOtherUserPath -Path 'C:\Users\a\Desktop' -Platform $P | Should -BeFalse
            Test-VacateOtherUserPath -Path 'C:\Windows\x' -Platform $P | Should -BeFalse
        }
    }
    It 'detects a mount crossing' {
        InModuleScope Vacate -Parameters @{ P = (Get-TestProfile 'linux') } {
            param($P)
            $m = @('/', '/home/a/mnt/usb')
            Test-VacateCrossesMount -Path '/home/a/mnt/usb/x' -Root '/home/a' -MountPoints $m -Platform $P | Should -BeTrue
            Test-VacateCrossesMount -Path '/home/a/docs' -Root '/home/a' -MountPoints $m -Platform $P | Should -BeFalse
            Test-VacateCrossesMount -Path '/home/a/mnt/usbx' -Root '/home/a' -MountPoints $m -Platform $P | Should -BeFalse
            Test-VacateCrossesMount -Path '/home/a/x' -Root '/home/a' -MountPoints @() -Platform $P | Should -BeFalse
        }
    }
}

Describe 'Resolve-VacateRuleTargets on a real temp tree' {
    BeforeAll {
        $script:tree = Get-TestTree
        $script:prof = Get-TreeProfile -Root $script:tree
        $script:fs = Get-TestFileSystem
        $script:homeDir = Join-Path (Join-Path $script:tree 'Users') 'a'
    }
    AfterAll {
        foreach ($l in @('Users/a/linkout', 'Users/a/AppData/Local/Google/Chrome/User Data/Linked')) {
            $p = Join-Path $script:tree $l
            if ([IO.Directory]::Exists($p)) { [IO.Directory]::Delete($p) }
        }
        if ($script:tree -and [IO.Directory]::Exists($script:tree)) { [IO.Directory]::Delete($script:tree, $true) }
    }

    It 'matches * as exactly one segment and filters files vs directories' {
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath 'AppData/Local/Google/Chrome/User Data/*/History' -Match 'files' -Platform $P }
        @($r.Targets | ForEach-Object { $_.Directory.Name }) | Should -Be @('Default', 'Profile 1')
        $d = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath 'AppData/Local/Google/Chrome/User Data/*' -Match 'directories' -Platform $P }
        @($d.Targets | ForEach-Object { $_.Name }) | Should -Be @('Crashpad', 'Default', 'Profile 1')
        $none = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '*/History' -Match 'files' -Platform $P }
        @($none.Targets).Count | Should -Be 0
    }

    It 'returns the root itself for an empty rule path' {
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '' -Match 'directories' -Platform $P }
        @($r.Targets).Count | Should -Be 1
    }

    It 'treats regex metacharacters in a segment literally' {
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '[a]*' -Match 'directories' -Platform $P }
        @($r.Targets | ForEach-Object { $_.Name }) | Should -Be @('[a]')
        $r2 = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '.+' -Match 'any' -Platform $P }
        @($r2.Targets).Count | Should -Be 0
    }

    It 'lists other profiles by name only and never their contents' {
        $users = Join-Path $tree 'Users'
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = $users; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '*' -Match 'directories' -Platform $P -ExcludeHome }
        @($r.Targets | ForEach-Object { $_.Name }) | Should -Be @('b')
        $c = InModuleScope Vacate -Parameters @{ F = $fs; R = $users; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '*/Desktop' -Match 'directories' -Platform $P }
        @($c.Targets).Count | Should -Be 0
        @($c.Rejected | Where-Object { $_.Reason -eq 'other-user' }).Count | Should -Be 1
    }

    It 'refuses excluded folders' {
        $ex = Join-Path $homeDir 'xyz'
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof; X = $ex } { param($F, $R, $P, $X) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '*' -Match 'directories' -Platform $P -Exclude @($X) }
        @($r.Targets | ForEach-Object { $_.Name }) | Should -Not -Contain 'xyz'
        @($r.Rejected | Where-Object { $_.Reason -eq 'excluded' }).Count | Should -Be 1
    }

    It 'never follows a junction or symlink, even one pointing outside the root' {
        $link = Join-Path $homeDir 'linkout'
        $target = Join-Path $tree 'outside'
        if ($script:onWindows) { New-Item -ItemType Junction -Path $link -Target $target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null }
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath 'linkout/secret/*' -Match 'any' -Platform $P }
        @($r.Targets).Count | Should -Be 0
        @($r.Rejected | Where-Object { $_.Reason -eq 'link' }).Count | Should -Be 1
        $w = InModuleScope Vacate -Parameters @{ F = $fs; R = $homeDir; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '*' -Match 'any' -Platform $P }
        @($w.Targets | ForEach-Object { $_.Name }) | Should -Not -Contain 'linkout'
        $fs.Calls | Where-Object { $_ -like '*secret*' } | Should -BeNullOrEmpty
    }

    It 'refuses a root that is itself a link' {
        $link = Join-Path $tree 'Users/a/AppData/Local/Google/Chrome/User Data/Linked'
        $target = Join-Path $tree 'outside'
        if ($script:onWindows) { New-Item -ItemType Junction -Path $link -Target $target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null }
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = $link; P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '*' -Match 'any' -Platform $P }
        @($r.Targets).Count | Should -Be 0
        $r.Rejected[0].Reason | Should -Be 'link'
    }

    It 'returns nothing when the root does not exist' {
        $r = InModuleScope Vacate -Parameters @{ F = $fs; R = (Join-Path $tree 'nope'); P = $prof } { param($F, $R, $P) Resolve-VacateRuleTargets -FileSystem $F -Root $R -RulePath '*' -Match 'any' -Platform $P }
        @($r.Targets).Count | Should -Be 0
    }
}
