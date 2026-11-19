$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $script:tree = Join-Path ([IO.Path]::GetTempPath()) ('vacate-lp-' + [guid]::NewGuid().ToString('N'))
    $users = Join-Path $script:tree 'Users'
    $script:homeDir = Join-Path $users 'me'
    # Each platform's own built-in profile names (Models.ps1 VacateSystemProfileNames).
    $builtIns = @('lost+found')
    if ($script:onWindows) { $builtIns = @('Public', 'Default') }
    foreach ($d in (@('me/Recent/sub', 'me/Big', 'me/outside-target', 'bob') + $builtIns)) { [void][IO.Directory]::CreateDirectory((Join-Path $users $d)) }
    foreach ($f in @('me/Recent/a.lnk', 'me/Recent/b.lnk', 'me/Recent/c.txt', 'me/Recent/sub/d.lnk', 'me/note.txt', 'me/outside-target/secret.lnk')) {
        [IO.File]::WriteAllText((Join-Path $users $f), 'hello')
    }
    foreach ($i in 1..30) { [IO.File]::WriteAllText((Join-Path $script:homeDir ('Big/f' + $i + '.bin')), 'x') }
    $link = Join-Path $script:homeDir 'Recent/linked'
    if ($script:onWindows) { New-Item -ItemType Junction -Path $link -Target (Join-Path $script:homeDir 'outside-target') | Out-Null }
    else { New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $script:homeDir 'outside-target') | Out-Null }

    $name = 'linux'; $sep = '/'; $cs = $true; $cmp = [StringComparison]::Ordinal
    if ($script:onWindows) { $name = 'windows'; $sep = '\'; $cs = $false; $cmp = [StringComparison]::OrdinalIgnoreCase }
    $prof = [pscustomobject][ordered]@{ Name = $name; CaseSensitive = $cs; Comparison = $cmp; Separator = [char]$sep; Roots = [ordered]@{ HOME = $script:homeDir; USERS = $users }; HomePath = $script:homeDir; UsersRoot = $users; UserName = 'me' }
    $fs = InModuleScope Vacate { New-VacateFileSystemProvider }
    $script:ctx = [pscustomobject]@{ Platform = $prof; FileSystem = $fs; Registry = $null; Cim = $null; SystemQuery = $null; Elevated = $false; MountPoints = @(); Exclude = @() }

    function Get-TestRule {
        param([hashtable]$Locator, [int]$Max = 100)
        $loc = [pscustomobject]@{ kind = 'path'; root = 'HOME'; path = ''; match = 'directories' }
        foreach ($k in $Locator.Keys) { $loc | Add-Member -NotePropertyName $k -NotePropertyValue $Locator[$k] -Force }
        return [pscustomobject]@{ id = 'test.rule'; platforms = @($name); category = 'activity'; title = 'Test'; whyItMatters = 'Because tests.'; sensitivity = 'medium'; locator = $loc; measure = @('exists'); maxEntries = $Max; requiresElevation = $false; verifiedOn = @(); verified = $false; source = 'unit test source'; notes = $null }
    }
    function Invoke-TestLocator {
        param($Rule, [datetime]$Deadline = ([datetime]::UtcNow.AddSeconds(30)))
        return (InModuleScope Vacate -Parameters @{ R = $Rule; C = $script:ctx; D = $Deadline } { param($R, $C, $D) Invoke-VacatePathLocator -Rule $R -Context $C -Deadline $D })
    }
}

AfterAll {
    $link = Join-Path $script:homeDir 'Recent/linked'
    if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link) }
    if ([IO.Directory]::Exists($script:tree)) { [IO.Directory]::Delete($script:tree, $true) }
}

Describe 'Invoke-VacatePathLocator' {
    It 'summarises a recursed folder as one trace, filtered by include, without following links' {
        $res = Invoke-TestLocator (Get-TestRule @{ path = 'Recent'; recurse = $true; include = '*.lnk' })
        @($res.Traces).Count | Should -Be 1
        $t = $res.Traces[0]
        $t.itemCount | Should -Be 3
        $t.sizeBytes | Should -Be 15
        @($t.samples).Count | Should -BeLessOrEqual 3
        @($t.samples) | Should -Not -Contain 'secret.lnk'
        $t.truncated | Should -BeFalse
    }

    It 'emits no trace when include matches nothing' {
        $res = Invoke-TestLocator (Get-TestRule @{ path = 'Recent'; recurse = $true; include = '*.docx' })
        @($res.Traces).Count | Should -Be 0
    }

    It 'measures a single file target' {
        $res = Invoke-TestLocator (Get-TestRule @{ path = 'note.txt'; match = 'files' })
        $res.Traces[0].sizeBytes | Should -Be 5
        $res.Traces[0].itemCount | Should -Be 1
        @($res.Traces[0].samples) | Should -Be @('note.txt')
    }

    It 'marks truncation when maxEntries is reached' {
        $res = Invoke-TestLocator (Get-TestRule @{ path = 'Big'; recurse = $true } -Max 10)
        $res.Traces[0].truncated | Should -BeTrue
        $res.Traces[0].itemCount | Should -BeLessOrEqual 10
    }

    It 'lists other profiles by name only, without the current user or built-in profiles' {
        $r = Get-TestRule @{ root = 'USERS'; path = '*'; excludeHome = $true }
        $res = Invoke-TestLocator $r
        @($res.Traces | ForEach-Object { $_.samples[0] }) | Should -Be @('bob')
        $res.Traces[0].sizeBytes | Should -BeNullOrEmpty
    }

    It 'returns a timeout skip when the deadline has passed' {
        $res = Invoke-TestLocator (Get-TestRule @{ path = 'Recent'; recurse = $true }) -Deadline ([datetime]::UtcNow.AddSeconds(-1))
        $res.Skips[0].reason | Should -Be 'timeout'
        @($res.Traces).Count | Should -Be 0
    }

    It 'leaves the scanned tree unchanged (write-spy)' {
        . (Join-Path $PSScriptRoot '../helpers/WriteSpy.ps1')
        $before = Get-VacateTreeSnapshot -Path $script:tree
        Invoke-TestLocator (Get-TestRule @{ path = ''; recurse = $true }) | Out-Null
        Invoke-TestLocator (Get-TestRule @{ root = 'USERS'; path = '*'; excludeHome = $true }) | Out-Null
        $after = Get-VacateTreeSnapshot -Path $script:tree
        @(Compare-VacateTreeSnapshot -Before $before -After $after).Count | Should -Be 0
    }
}
