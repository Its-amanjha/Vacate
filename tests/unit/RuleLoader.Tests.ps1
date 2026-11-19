BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestRule {
        param([hashtable]$Override = @{}, [hashtable]$Locator = $null)
        $rule = [ordered]@{
            id                = 'browser.chrome.history'
            platforms         = @('windows')
            category          = 'browsers'
            title             = 'Chrome history database'
            whyItMatters      = 'Lists every site visited and when.'
            sensitivity       = 'high'
            locator           = [ordered]@{ kind = 'path'; root = 'LOCALAPPDATA'; path = 'Google/Chrome/User Data/*/History'; match = 'files' }
            measure           = @('exists', 'sizeBytes')
            maxEntries        = 5000
            requiresElevation = $false
            verifiedOn        = @()
            verified          = $false
            source            = 'Chromium user data directory docs'
            notes             = $null
        }
        if ($null -ne $Locator) { $rule.locator = $Locator }
        foreach ($k in $Override.Keys) { $rule[$k] = $Override[$k] }
        return $rule
    }

    function ConvertTo-TestRuleObject {
        param([System.Collections.IDictionary]$Rule)
        return ($Rule | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    }

    function Get-RuleProblem {
        param([System.Collections.IDictionary]$Rule)
        $obj = ConvertTo-TestRuleObject $Rule
        return @(InModuleScope Vacate -Parameters @{ R = $obj } { param($R) Test-VacateRule -Rule $R })
    }

    function Get-TestRulesDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ('vacate-rules-' + [guid]::NewGuid().ToString('N'))
        foreach ($p in 'windows', 'macos', 'linux') { [void][IO.Directory]::CreateDirectory((Join-Path $d $p)) }
        return $d
    }

    function Write-TestRule {
        param([string]$Dir, [string]$Platform, [System.Collections.IDictionary]$Rule, [string]$FileName = $null)
        if (-not $FileName) { $FileName = $Rule.id + '.json' }
        $json = $Rule | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText((Join-Path (Join-Path $Dir $Platform) $FileName), $json, (New-Object Text.UTF8Encoding $false))
    }
}

Describe 'Test-VacateRule' {
    It 'accepts a valid rule' {
        Get-RuleProblem (Get-TestRule) | Should -BeNullOrEmpty
    }

    It 'rejects unknown category' {
        (Get-RuleProblem (Get-TestRule @{ category = 'snacks' })) -join ';' | Should -Match 'unknown category'
    }

    It 'rejects missing source' {
        $r = Get-TestRule; $r.Remove('source')
        (Get-RuleProblem $r) -join ';' | Should -Match "missing field 'source'"
    }

    It 'rejects a too-short source' {
        (Get-RuleProblem (Get-TestRule @{ source = 'x' })) -join ';' | Should -Match 'source must be'
    }

    It 'rejects an empty locator' {
        (Get-RuleProblem (Get-TestRule -Locator ([ordered]@{}))) -join ';' | Should -Match 'unknown locator kind'
    }

    It 'rejects an unknown locator kind' {
        (Get-RuleProblem (Get-TestRule -Locator ([ordered]@{ kind = 'shell'; command = 'rm' }))) -join ';' | Should -Match "unknown locator kind 'shell'"
    }

    It 'rejects an unknown root token' {
        $loc = [ordered]@{ kind = 'path'; root = 'TEMPDIR'; path = 'x'; match = 'files' }
        (Get-RuleProblem (Get-TestRule -Locator $loc)) -join ';' | Should -Match "unknown root token 'TEMPDIR'"
    }

    It 'rejects a token not defined for a declared platform' {
        $r = Get-TestRule @{ platforms = @('windows', 'linux') }
        (Get-RuleProblem $r) -join ';' | Should -Match "root token 'LOCALAPPDATA' is not defined for platform 'linux'"
    }

    It 'rejects .. in the path' {
        $loc = [ordered]@{ kind = 'path'; root = 'HOME'; path = 'a/../b'; match = 'files' }
        (Get-RuleProblem (Get-TestRule -Locator $loc)) -join ';' | Should -Match "'\.\.' segment"
    }

    It 'rejects absolute paths, drive letters and backslashes' {
        foreach ($bad in @('/etc/passwd', 'C:/Windows', 'a\b', 'a//b', 'a/', 'x/**/y', 'a:b')) {
            $loc = [ordered]@{ kind = 'path'; root = 'HOME'; path = $bad; match = 'files' }
            @(Get-RuleProblem (Get-TestRule -Locator $loc)).Count | Should -BeGreaterThan 0 -Because "path '$bad' must be rejected"
        }
    }

    It 'accepts an empty path (the root itself)' {
        $loc = [ordered]@{ kind = 'path'; root = 'HOME'; path = ''; match = 'directories' }
        Get-RuleProblem (Get-TestRule -Locator $loc) | Should -BeNullOrEmpty
    }

    It 'rejects oversized and non-integer maxEntries' {
        (Get-RuleProblem (Get-TestRule @{ maxEntries = 50001 })) -join ';' | Should -Match 'maxEntries must be 1-50000'
        (Get-RuleProblem (Get-TestRule @{ maxEntries = 0 })) -join ';' | Should -Match 'maxEntries must be 1-50000'
        (Get-RuleProblem (Get-TestRule @{ maxEntries = 10.5 })) -join ';' | Should -Match 'maxEntries must be an integer'
    }

    It 'rejects unknown fields' {
        (Get-RuleProblem (Get-TestRule @{ script = 'Remove-Item' })) -join ';' | Should -Match "unknown field 'script'"
    }

    It 'rejects unknown locator fields' {
        $loc = [ordered]@{ kind = 'path'; root = 'HOME'; path = 'x'; match = 'files'; command = 'x' }
        (Get-RuleProblem (Get-TestRule -Locator $loc)) -join ';' | Should -Match 'locator.command is not allowed'
    }

    It 'rejects bad ids' {
        foreach ($bad in @('Browser.Chrome', 'nodot', 'a..b', 'a.b c')) {
            (Get-RuleProblem (Get-TestRule @{ id = $bad })) -join ';' | Should -Match 'id must be' -Because "id '$bad'"
        }
    }

    It 'rejects verified=true without verifiedOn' {
        (Get-RuleProblem (Get-TestRule @{ verified = $true })) -join ';' | Should -Match 'verified=true requires verifiedOn'
        Get-RuleProblem (Get-TestRule @{ verified = $true; verifiedOn = @('Windows 11 Pro 26300') }) | Should -BeNullOrEmpty
    }

    It 'rejects Windows-only kinds on other platforms' {
        $loc = [ordered]@{ kind = 'registry'; hive = 'HKCU'; key = 'Software\Test' }
        $r = Get-TestRule @{ platforms = @('linux') } -Locator $loc
        $r.measure = @('exists')
        (Get-RuleProblem $r) -join ';' | Should -Match "Windows-only"
    }

    It 'validates registry keys' {
        foreach ($bad in @('\Software\X', 'Software\X\', 'HKCU\Software', 'Software/X', 'Software\\X')) {
            $loc = [ordered]@{ kind = 'registry'; hive = 'HKCU'; key = $bad }
            $r = Get-TestRule -Locator $loc; $r.measure = @('exists')
            @(Get-RuleProblem $r).Count | Should -BeGreaterThan 0 -Because "key '$bad'"
        }
        $ok = Get-TestRule -Locator ([ordered]@{ kind = 'registry'; hive = 'HKCU'; key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU' })
        $ok.measure = @('exists', 'valueCount')
        Get-RuleProblem $ok | Should -BeNullOrEmpty
    }

    It 'rejects measures that do not fit the kind' {
        $loc = [ordered]@{ kind = 'registry'; hive = 'HKCU'; key = 'Software\Test' }
        $r = Get-TestRule -Locator $loc; $r.measure = @('exists', 'lastWriteTime')
        (Get-RuleProblem $r) -join ';' | Should -Match "measure 'lastWriteTime' not valid for locator kind 'registry'"
    }

    It 'ties system queries to their platform' {
        $loc = [ordered]@{ kind = 'system-query'; name = 'filevault-status' }
        $r = Get-TestRule @{ platforms = @('linux'); measure = @('properties') } -Locator $loc
        (Get-RuleProblem $r) -join ';' | Should -Match 'only exists on macos'
        $r2 = Get-TestRule @{ platforms = @('linux'); measure = @('properties') } -Locator ([ordered]@{ kind = 'system-query'; name = 'mounts' })
        Get-RuleProblem $r2 | Should -BeNullOrEmpty
        $r3 = Get-TestRule @{ platforms = @('linux'); measure = @('properties') } -Locator ([ordered]@{ kind = 'system-query'; name = 'rm -rf' })
        (Get-RuleProblem $r3) -join ';' | Should -Match 'unknown system query'
    }

    It 'requires include to come with recurse and excludeHome with USERS' {
        $loc = [ordered]@{ kind = 'path'; root = 'HOME'; path = ''; match = 'directories'; include = '.DS_Store' }
        (Get-RuleProblem (Get-TestRule -Locator $loc)) -join ';' | Should -Match 'include requires recurse'
        $loc2 = [ordered]@{ kind = 'path'; root = 'HOME'; path = '*'; match = 'directories'; excludeHome = $true }
        (Get-RuleProblem (Get-TestRule -Locator $loc2)) -join ';' | Should -Match 'excludeHome is only valid with root USERS'
    }

    It 'rejects non-object input' {
        @(InModuleScope Vacate { Test-VacateRule -Rule 'text' }) -join ';' | Should -Match 'must be a JSON object'
    }
}

Describe 'Import-VacateRuleSet' {
    BeforeEach { $script:dir = Get-TestRulesDir }
    AfterEach { if ($script:dir -and [IO.Directory]::Exists($script:dir)) { [IO.Directory]::Delete($script:dir, $true) } }

    It 'loads valid rules sorted ordinal by id and splits by platform' {
        Write-TestRule $dir 'windows' (Get-TestRule @{ id = 'zeta.rule' })
        Write-TestRule $dir 'windows' (Get-TestRule @{ id = 'Alpha.rule'.ToLower() })
        Write-TestRule $dir 'windows' (Get-TestRule @{ id = 'beta.rule' })
        $lin = Get-TestRule @{ id = 'linux.only'; platforms = @('linux') } -Locator ([ordered]@{ kind = 'path'; root = 'HOME'; path = '.ssh'; match = 'directories' })
        Write-TestRule $dir 'linux' $lin

        $res = InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D -Platform 'windows' }
        @($res.Errors).Count | Should -Be 0
        @($res.Rules | ForEach-Object { $_.id }) | Should -Be @('alpha.rule', 'beta.rule', 'zeta.rule')
        @($res.NotApplicable | ForEach-Object { $_.id }) | Should -Be @('linux.only')
        $res.FileCount | Should -Be 4
    }

    It 'rejects the same id twice for the same platform' {
        $win = Get-TestRule @{ id = 'dup.rule'; platforms = @('windows', 'linux') } -Locator ([ordered]@{ kind = 'path'; root = 'HOME'; path = 'x'; match = 'files' })
        Write-TestRule $dir 'windows' $win
        $lin = Get-TestRule @{ id = 'dup.rule'; platforms = @('linux') } -Locator ([ordered]@{ kind = 'path'; root = 'HOME'; path = 'x'; match = 'files' })
        Write-TestRule $dir 'linux' $lin
        $res = InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D }
        (@($res.Errors | ForEach-Object { $_.Problems }) -join ';') | Should -Match "duplicate id 'dup.rule' for platform 'linux'"
    }

    It 'allows the same id once per platform' {
        Write-TestRule $dir 'windows' (Get-TestRule @{ id = 'browser.chrome.history' })
        $lin = Get-TestRule @{ id = 'browser.chrome.history'; platforms = @('linux') } -Locator ([ordered]@{ kind = 'path'; root = 'XDG_CONFIG'; path = 'google-chrome/*/History'; match = 'files' })
        Write-TestRule $dir 'linux' $lin
        $res = InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D -Platform 'linux' }
        @($res.Errors).Count | Should -Be 0
        @($res.Rules).Count | Should -Be 1
        $res.Rules[0].platforms | Should -Be @('linux')
    }

    It 'rejects a file name that differs from the id' {
        Write-TestRule $dir 'windows' (Get-TestRule @{ id = 'real.id' }) -FileName 'other.id.json'
        $res = InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D }
        (@($res.Errors | ForEach-Object { $_.Problems }) -join ';') | Should -Match 'file name must equal id'
        @($res.Rules).Count | Should -Be 0
    }

    It 'rejects a rule whose platforms exclude its folder' {
        $r = Get-TestRule @{ id = 'wrong.folder'; platforms = @('linux') } -Locator ([ordered]@{ kind = 'path'; root = 'HOME'; path = 'x'; match = 'files' })
        Write-TestRule $dir 'windows' $r
        $res = InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D }
        (@($res.Errors | ForEach-Object { $_.Problems }) -join ';') | Should -Match "platforms must include 'windows'"
    }

    It 'reports broken JSON, BOM and non-ASCII without throwing' {
        [IO.File]::WriteAllText((Join-Path $dir 'windows/broken.rule.json'), '{ "id": ', (New-Object Text.UTF8Encoding $false))
        $json = (Get-TestRule @{ id = 'bom.rule' }) | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText((Join-Path $dir 'windows/bom.rule.json'), $json, (New-Object Text.UTF8Encoding $true))
        $json2 = (Get-TestRule @{ id = 'uni.rule'; title = ('Caf' + [char]0x00E9 + ' data') }) | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText((Join-Path $dir 'windows/uni.rule.json'), $json2, (New-Object Text.UTF8Encoding $false))
        $res = InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D }
        $all = (@($res.Errors | ForEach-Object { $_.Problems }) -join ';')
        $all | Should -Match 'invalid JSON'
        $all | Should -Match 'BOM'
        $all | Should -Match 'non-ASCII'
        @($res.Rules).Count | Should -Be 0
    }

    It 'rejects files in a folder that is not a platform' {
        [void][IO.Directory]::CreateDirectory((Join-Path $dir 'android'))
        Write-TestRule $dir 'android' (Get-TestRule @{ id = 'phone.rule' })
        $res = InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D }
        (@($res.Errors | ForEach-Object { $_.Problems }) -join ';') | Should -Match "not a platform"
    }

    It 'throws on an unknown platform or missing folder' {
        { InModuleScope Vacate -Parameters @{ D = $dir } { param($D) Import-VacateRuleSet -Path $D -Platform 'beos' } } | Should -Throw
        { InModuleScope Vacate { Import-VacateRuleSet -Path (Join-Path ([IO.Path]::GetTempPath()) 'nope-vacate-xyz') } } | Should -Throw
    }

    It 'loads the shipped catalog without errors' {
        $shipped = InModuleScope Vacate { $script:VacateRulesRoot }
        $res = InModuleScope Vacate -Parameters @{ D = $shipped } { param($D) Import-VacateRuleSet -Path $D }
        $why = (@($res.Errors | ForEach-Object { $_.File + ': ' + ($_.Problems -join '; ') }) -join [Environment]::NewLine)
        @($res.Errors).Count | Should -Be 0 -Because $why
    }
}
