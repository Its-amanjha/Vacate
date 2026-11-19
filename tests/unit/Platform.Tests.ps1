# Platform profile tests. Pester 5 runs It bodies in a scope that does not see the file body,
# so every helper and value lives in BeforeAll; -Skip and -ForEach use inline values only.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    $script:projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

    # Independent of Get-VacatePlatform: the expected value comes from the runtime itself.
    # $PSVersionTable.OS is not reliable (a WSL build reports 'Ubuntu 24.04.5 LTS').
    $script:expectedPlatform = 'windows'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $runtime = [System.Runtime.InteropServices.RuntimeInformation]
        $script:expectedPlatform = 'linux'
        if ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $script:expectedPlatform = 'windows' }
        elseif ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { $script:expectedPlatform = 'macos' }
    }

    $script:contractProperties = @('Name', 'CaseSensitive', 'Comparison', 'Separator', 'Roots', 'HomePath', 'UsersRoot', 'UserName')

    function Get-TestWinEnv {
        return @{
            USERPROFILE  = 'C:\Users\ann'
            APPDATA      = 'C:\Users\ann\AppData\Roaming'
            LOCALAPPDATA = 'C:\Users\ann\AppData\Local'
            PROGRAMDATA  = 'C:\ProgramData'
            SystemDrive  = 'C:'
            USERNAME     = 'ann'
        }
    }

    function Get-TestProfileEnvironment {
        param([string]$Platform, [switch]$TrailingSeparator)
        $trailing = ''
        if ($TrailingSeparator) { $trailing = '/' }
        switch ($Platform) {
            'windows' { return (Get-TestWinEnv) }
            'macos' { return @{ HOME = ('/Users/ann' + $trailing); USER = 'ann' } }
            default { return @{ HOME = ('/home/ann' + $trailing); USER = 'ann' } }
        }
    }

    function Get-TestProfile {
        param([string]$Platform, [System.Collections.IDictionary]$Environment)
        return (InModuleScope Vacate -Parameters @{ P = $Platform; E = $Environment } {
                param($P, $E)
                Get-VacatePlatformProfile -Platform $P -Environment $E
            })
    }

    function Get-TestRootToken {
        param([string]$Platform)
        return @(InModuleScope Vacate -Parameters @{ P = $Platform } { param($P) $script:VacateRootTokens[$P] })
    }
}

Describe 'Get-VacatePlatform' {
    It 'detects the platform of the current runtime' {
        $detected = InModuleScope Vacate { Get-VacatePlatform }
        $detected | Should -Be $script:expectedPlatform
        InModuleScope Vacate { $script:VacatePlatforms } | Should -Contain $detected
    }

    It 'throws when the runtime is neither Windows, macOS nor Linux' -Skip:($PSVersionTable.PSEdition -eq 'Desktop') {
        { InModuleScope Vacate { Mock Get-Variable { $null }; Get-VacatePlatform } } | Should -Throw '*platform: unsupported*'
    }
}

Describe 'Get-VacateEnvironmentSnapshot' {
    It 'returns only the environment variables the profiles need' {
        $snapshot = InModuleScope Vacate { Get-VacateEnvironmentSnapshot }
        $snapshot | Should -BeOfType [hashtable]

        $allowed = @(
            'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMDATA', 'SystemDrive', 'USERNAME',
            'HOME', 'USER', 'LOGNAME',
            'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME'
        )
        foreach ($key in $snapshot.Keys) {
            $allowed | Should -Contain $key -Because "the snapshot may not carry '$key'"
        }
        $snapshot.ContainsKey('PATH') | Should -BeFalse

        if ($script:expectedPlatform -eq 'windows') {
            $snapshot.ContainsKey('USERPROFILE') | Should -BeTrue
            $snapshot.ContainsKey('SystemDrive') | Should -BeTrue
        }
        else {
            $snapshot.ContainsKey('HOME') | Should -BeTrue
        }
    }

    It 'omits variables that are empty' {
        $snapshot = InModuleScope Vacate { Get-VacateEnvironmentSnapshot }
        foreach ($key in $snapshot.Keys) {
            ([string]$snapshot[$key]).Length | Should -BeGreaterThan 0
        }
    }

    It 'is the only place in src that reads the process environment' {
        $src = Join-Path $script:projectRoot 'src'
        $offenders = @()
        foreach ($file in @(Get-ChildItem -LiteralPath $src -Recurse -Filter '*.ps1' -File)) {
            $relative = $file.FullName.Substring($script:projectRoot.Length).Replace([IO.Path]::DirectorySeparatorChar, '/')
            if ($relative -like '*/Private/Platform.ps1') { continue }
            $text = [IO.File]::ReadAllText($file.FullName)
            if ($text.Contains('$env:') -or $text.Contains('GetEnvironmentVariable')) { $offenders += $relative }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }
}

Describe 'profile object shape' {
    It 'returns the CONTRACTS section 2 properties in order (<Platform>)' -ForEach @(@{ Platform = 'windows' }, @{ Platform = 'macos' }, @{ Platform = 'linux' }) {
        $platformProfile = Get-TestProfile -Platform $Platform -Environment (Get-TestProfileEnvironment -Platform $Platform)

        (@($platformProfile.PSObject.Properties.Name) -join ',') | Should -Be ($script:contractProperties -join ',')
        $platformProfile.Name | Should -Be $Platform
        $platformProfile.HomePath | Should -Be $platformProfile.Roots['HOME']
        if ($platformProfile.Roots.Contains('USERS')) {
            $platformProfile.UsersRoot | Should -Be $platformProfile.Roots['USERS']
        }
    }

    It 'uses the case rules of the platform (<Platform>)' -ForEach @(@{ Platform = 'windows' }, @{ Platform = 'macos' }, @{ Platform = 'linux' }) {
        $platformProfile = Get-TestProfile -Platform $Platform -Environment (Get-TestProfileEnvironment -Platform $Platform)
        $comparison = $platformProfile.Comparison.ToString()
        if ($Platform -eq 'linux') {
            $platformProfile.CaseSensitive | Should -BeTrue
            $comparison | Should -Be 'Ordinal'
        }
        else {
            $platformProfile.CaseSensitive | Should -BeFalse
            $comparison | Should -Be 'OrdinalIgnoreCase'
        }
    }

    It 'defines exactly the SPEC root tokens (<Platform>)' -ForEach @(@{ Platform = 'windows' }, @{ Platform = 'macos' }, @{ Platform = 'linux' }) {
        $platformProfile = Get-TestProfile -Platform $Platform -Environment (Get-TestProfileEnvironment -Platform $Platform)
        (@($platformProfile.Roots.Keys) -join ',') | Should -Be ((Get-TestRootToken $Platform) -join ',')
    }

    It 'normalizes every root with no trailing separator (<Platform>)' -ForEach @(@{ Platform = 'windows' }, @{ Platform = 'macos' }, @{ Platform = 'linux' }) {
        $platformProfile = Get-TestProfile -Platform $Platform -Environment (Get-TestProfileEnvironment -Platform $Platform -TrailingSeparator)
        $separator = [string]$platformProfile.Separator
        foreach ($key in $platformProfile.Roots.Keys) {
            $value = [string]$platformProfile.Roots[$key]
            if ($platformProfile.Separator -eq [char]'\') {
                $value | Should -Match '^[A-Za-z]:\\' -Because "$key must be an absolute drive path"
            }
            else {
                $value.StartsWith('/', [StringComparison]::Ordinal) | Should -BeTrue -Because "$key must be absolute"
            }
            $value.Contains('//') | Should -BeFalse -Because "$key must not repeat separators"
            $bareRoot = ($value -eq '/') -or ($value -match '^[A-Za-z]:\\$')
            if (-not $bareRoot) {
                $value.EndsWith($separator) | Should -BeFalse -Because "$key must not end with a separator"
            }
            if ($platformProfile.Separator -eq [char]'\') {
                $value.Contains('/') | Should -BeFalse -Because "$key must use backslashes only"
            }
        }
        $platformProfile.HomePath | Should -Be $platformProfile.Roots['HOME']
    }

    It 'never invents a root for a missing variable (<Platform>)' -ForEach @(@{ Platform = 'windows' }, @{ Platform = 'macos' }, @{ Platform = 'linux' }) {
        $environment = @{}
        $platformProfile = $null
        $threw = $false
        try { $platformProfile = Get-TestProfile -Platform $Platform -Environment $environment }
        catch { $threw = $true }
        $threw | Should -BeTrue -Because 'HOME is required on every platform'
        $platformProfile | Should -BeNullOrEmpty
    }
}

Describe 'Get-VacateWindowsProfile' {
    It 'resolves the SPEC table roots' {
        $platformProfile = Get-TestProfile -Platform 'windows' -Environment (Get-TestWinEnv)
        $platformProfile.Roots['HOME'] | Should -Be 'C:\Users\ann'
        $platformProfile.Roots['USERS'] | Should -Be 'C:\Users'
        $platformProfile.Roots['APPDATA'] | Should -Be 'C:\Users\ann\AppData\Roaming'
        $platformProfile.Roots['LOCALAPPDATA'] | Should -Be 'C:\Users\ann\AppData\Local'
        $platformProfile.Roots['PROGRAMDATA'] | Should -Be 'C:\ProgramData'
        $platformProfile.Roots['SYSTEMDRIVE'] | Should -Be 'C:\'
        $platformProfile.HomePath | Should -Be 'C:\Users\ann'
        $platformProfile.UsersRoot | Should -Be 'C:\Users'
        $platformProfile.UserName | Should -Be 'ann'
        $platformProfile.Separator | Should -Be ([char]'\')
    }

    It 'takes USERS from the profile parent rather than a hard-coded C:\Users' {
        $environment = Get-TestWinEnv
        $environment['USERPROFILE'] = 'D:\Profiles\ann'
        $platformProfile = Get-TestProfile -Platform 'windows' -Environment $environment
        $platformProfile.Roots['USERS'] | Should -Be 'D:\Profiles'
    }

    It 'normalizes mixed separators and a trailing separator' {
        $environment = Get-TestWinEnv
        $environment['USERPROFILE'] = 'C:/Users//ann/'
        $platformProfile = Get-TestProfile -Platform 'windows' -Environment $environment
        $platformProfile.Roots['HOME'] | Should -Be 'C:\Users\ann'
    }

    It 'accepts a SystemDrive that already ends in a separator' {
        $environment = Get-TestWinEnv
        $environment['SystemDrive'] = 'C:\'
        $platformProfile = Get-TestProfile -Platform 'windows' -Environment $environment
        $platformProfile.Roots['SYSTEMDRIVE'] | Should -Be 'C:\'
    }

    It 'leaves out a root whose variable is missing, without throwing' {
        $environment = Get-TestWinEnv
        [void]$environment.Remove('LOCALAPPDATA')
        [void]$environment.Remove('SystemDrive')
        $platformProfile = Get-TestProfile -Platform 'windows' -Environment $environment
        $platformProfile.Roots.Contains('LOCALAPPDATA') | Should -BeFalse
        $platformProfile.Roots.Contains('SYSTEMDRIVE') | Should -BeFalse
        (@($platformProfile.Roots.Keys) -join ',') | Should -Be 'HOME,USERS,APPDATA,PROGRAMDATA'
    }

    It 'throws when USERPROFILE is missing or blank' {
        { Get-TestProfile -Platform 'windows' -Environment @{ APPDATA = 'C:\x' } } | Should -Throw '*platform: HOME not available*'
        { Get-TestProfile -Platform 'windows' -Environment @{ USERPROFILE = '   ' } } | Should -Throw '*platform: HOME not available*'
    }
}

Describe 'Get-VacateMacOSProfile' {
    It 'resolves the SPEC table roots' {
        $platformProfile = Get-TestProfile -Platform 'macos' -Environment @{ HOME = '/Users/ann'; USER = 'ann' }
        $platformProfile.Roots['HOME'] | Should -Be '/Users/ann'
        $platformProfile.Roots['USERS'] | Should -Be '/Users'
        $platformProfile.Roots['LIBRARY'] | Should -Be '/Users/ann/Library'
        $platformProfile.Roots['APPLICATIONS'] | Should -Be '/Applications'
        $platformProfile.Roots['SYSTEM'] | Should -Be '/'
        $platformProfile.UsersRoot | Should -Be '/Users'
        $platformProfile.UserName | Should -Be 'ann'
        $platformProfile.Separator | Should -Be ([char]'/')
    }

    It 'falls back to LOGNAME for the user name' {
        $platformProfile = Get-TestProfile -Platform 'macos' -Environment @{ HOME = '/Users/ann'; LOGNAME = 'ann2' }
        $platformProfile.UserName | Should -Be 'ann2'
    }

    It 'throws when HOME is missing' {
        { Get-TestProfile -Platform 'macos' -Environment @{ USER = 'ann' } } | Should -Throw '*platform: HOME not available*'
    }
}

Describe 'Get-VacateLinuxProfile' {
    It 'resolves the SPEC table roots and the XDG defaults' {
        $platformProfile = Get-TestProfile -Platform 'linux' -Environment @{ HOME = '/home/ann'; USER = 'ann' }
        $platformProfile.Roots['HOME'] | Should -Be '/home/ann'
        $platformProfile.Roots['USERS'] | Should -Be '/home'
        $platformProfile.Roots['APPLICATIONS'] | Should -Be '/usr/share/applications'
        $platformProfile.Roots['SYSTEM'] | Should -Be '/'
        $platformProfile.Roots['XDG_CONFIG'] | Should -Be '/home/ann/.config'
        $platformProfile.Roots['XDG_DATA'] | Should -Be '/home/ann/.local/share'
        $platformProfile.Roots['XDG_STATE'] | Should -Be '/home/ann/.local/state'
        $platformProfile.Roots['ETC'] | Should -Be '/etc'
        $platformProfile.Roots['VAR'] | Should -Be '/var'
        $platformProfile.UserName | Should -Be 'ann'
    }

    It 'honours an absolute XDG variable' {
        $environment = @{
            HOME            = '/home/ann'
            XDG_CONFIG_HOME = '/data/config/'
            XDG_DATA_HOME   = '/data/share'
            XDG_STATE_HOME  = '/data/state'
        }
        $platformProfile = Get-TestProfile -Platform 'linux' -Environment $environment
        $platformProfile.Roots['XDG_CONFIG'] | Should -Be '/data/config'
        $platformProfile.Roots['XDG_DATA'] | Should -Be '/data/share'
        $platformProfile.Roots['XDG_STATE'] | Should -Be '/data/state'
    }

    It 'ignores a relative XDG variable (XDG Base Directory spec)' {
        $environment = @{
            HOME            = '/home/ann'
            XDG_CONFIG_HOME = 'relative/config'
            XDG_DATA_HOME   = './share'
            XDG_STATE_HOME  = 'state'
        }
        $platformProfile = Get-TestProfile -Platform 'linux' -Environment $environment
        $platformProfile.Roots['XDG_CONFIG'] | Should -Be '/home/ann/.config'
        $platformProfile.Roots['XDG_DATA'] | Should -Be '/home/ann/.local/share'
        $platformProfile.Roots['XDG_STATE'] | Should -Be '/home/ann/.local/state'
    }

    It 'defaults to HOME when the XDG variables are unset' {
        $platformProfile = Get-TestProfile -Platform 'linux' -Environment @{ HOME = '/root' }
        $platformProfile.Roots['XDG_CONFIG'] | Should -Be '/root/.config'
        $platformProfile.Roots['XDG_DATA'] | Should -Be '/root/.local/share'
        $platformProfile.Roots['XDG_STATE'] | Should -Be '/root/.local/state'
    }

    It 'throws when HOME is missing' {
        { Get-TestProfile -Platform 'linux' -Environment @{ USER = 'ann' } } | Should -Throw '*platform: HOME not available*'
    }
}

Describe 'Get-VacatePlatformProfile' {
    It 'dispatches to the platform profile' {
        $environment = @{ USERPROFILE = 'C:\Users\ann'; HOME = '/home/ann'; USER = 'ann'; USERNAME = 'ann' }
        foreach ($platform in @('windows', 'macos', 'linux')) {
            $platformProfile = Get-TestProfile -Platform $platform -Environment $environment
            $platformProfile.Name | Should -Be $platform
        }
    }

    It 'rejects an unknown platform name' {
        { Get-TestProfile -Platform 'beos' -Environment @{ HOME = '/x' } } | Should -Throw '*platform: unsupported*'
    }
}

Describe 'Test-VacateElevated' {
    It 'answers for the current platform without throwing' {
        $result = InModuleScope Vacate -Parameters @{ P = $script:expectedPlatform } { param($P) Test-VacateElevated -Platform $P }
        $result | Should -BeOfType [bool]
    }

    It 'rejects an unknown platform name' {
        { InModuleScope Vacate { Test-VacateElevated -Platform 'beos' } } | Should -Throw '*platform: unsupported*'
    }
}
