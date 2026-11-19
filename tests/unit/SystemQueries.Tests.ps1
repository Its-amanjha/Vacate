# System query tests: the allow-list, the runner seam and the output parsers.
# Pester 5 runs It bodies in a scope that does not see the file body, so fixtures and
# helpers are loaded in BeforeAll. -Skip is evaluated at discovery time, which is why the
# runtime platform is computed here rather than in BeforeAll.

$script:runtimePlatform = 'linux'
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $script:runtimePlatform = 'windows'
}
else {
    $runtime = [System.Runtime.InteropServices.RuntimeInformation]
    if ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $script:runtimePlatform = 'windows' }
    elseif ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { $script:runtimePlatform = 'macos' }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    $script:projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:fixtureDir = (Resolve-Path (Join-Path $PSScriptRoot '../fixtures/systemqueries')).Path

    # Captured on Ubuntu 24.04 in WSL with the exact argument arrays from the table.
    $script:lsblkText = [IO.File]::ReadAllText((Join-Path $script:fixtureDir 'lsblk.json'))
    $script:lsblkNestedText = [IO.File]::ReadAllText((Join-Path $script:fixtureDir 'lsblk-nested.json'))
    $script:findmntText = [IO.File]::ReadAllText((Join-Path $script:fixtureDir 'findmnt.json'))
    $script:fdesetupOnText = [IO.File]::ReadAllText((Join-Path $script:fixtureDir 'fdesetup-on.txt'))
    $script:fdesetupOffText = [IO.File]::ReadAllText((Join-Path $script:fixtureDir 'fdesetup-off.txt'))
    $script:fdesetupUnknownText = [IO.File]::ReadAllText((Join-Path $script:fixtureDir 'fdesetup-unknown.txt'))

    function Get-TestQueryTable {
        return @(InModuleScope Vacate { Get-VacateSystemQueryTable })
    }

    function Get-TestQueryResult {
        param([string]$Name, [object]$Platform, [scriptblock]$Runner)
        $parameters = @{ P = $Platform; N = $Name; R = $Runner }
        return (InModuleScope Vacate -Parameters $parameters {
                param($P, $N, $R)
                if ($null -eq $R) { Invoke-VacateSystemQuery -Name $N -Platform $P }
                else { Invoke-VacateSystemQuery -Name $N -Platform $P -Runner $R }
            })
    }

    function Get-TestParserOutput {
        param([string]$Function, [string]$Text)
        return (InModuleScope Vacate -Parameters @{ F = $Function; T = $Text } {
                param($F, $T)
                switch ($F) {
                    'lsblk' { return (ConvertFrom-VacateLsblkJson -Text $T) }
                    'findmnt' { return (ConvertFrom-VacateFindmntJson -Text $T) }
                    default { return (ConvertFrom-VacateFdesetupStatus -Text $T) }
                }
            })
    }
}

Describe 'Get-VacateSystemQueryTable' {
    It 'has exactly the three allow-listed queries in order' {
        $table = Get-TestQueryTable
        $table.Count | Should -Be 3
        (($table | ForEach-Object { $_.Name }) -join ',') | Should -Be 'filevault-status,block-devices,mounts'
    }

    It 'matches the constants in Models.ps1' {
        $table = Get-TestQueryTable
        $names = @(InModuleScope Vacate { $script:VacateSystemQueryNames })
        (($table | ForEach-Object { $_.Name } | Sort-Object) -join ',') | Should -Be (($names | Sort-Object) -join ',')

        $platforms = InModuleScope Vacate { $script:VacateSystemQueryPlatforms }
        foreach ($entry in $table) {
            $entry.Platform | Should -Be $platforms[$entry.Name]
        }
    }

    It 'names an absolute binary for every query' {
        foreach ($entry in (Get-TestQueryTable)) {
            $entry.Binary.StartsWith('/', [StringComparison]::Ordinal) | Should -BeTrue -Because "$($entry.Name)"
            $entry.Binary.Contains(' ') | Should -BeFalse
            @($entry.Arguments).Count | Should -BeGreaterThan 0 -Because "$($entry.Name) needs fixed arguments"
            foreach ($argument in @($entry.Arguments)) {
                $argument | Should -BeOfType [string]
            }
        }
    }

    It 'pins the exact fixed argument arrays' {
        $table = Get-TestQueryTable
        $byName = @{}
        foreach ($entry in $table) { $byName[$entry.Name] = $entry }

        $byName['filevault-status'].Binary | Should -Be '/usr/bin/fdesetup'
        (@($byName['filevault-status'].Arguments) -join ' ') | Should -Be 'status'

        $byName['block-devices'].Binary | Should -Be '/usr/bin/lsblk'
        (@($byName['block-devices'].Arguments) -join ' ') | Should -Be '--json -o NAME,TYPE,FSTYPE,MOUNTPOINT'

        $byName['mounts'].Binary | Should -Be '/usr/bin/findmnt'
        (@($byName['mounts'].Arguments) -join ' ') | Should -Be '--json -o TARGET,SOURCE,FSTYPE'
    }

    It 'uses the contract property order' {
        foreach ($entry in (Get-TestQueryTable)) {
            (@($entry.PSObject.Properties.Name) -join ',') | Should -Be 'Name,Platform,Binary,Arguments'
        }
    }

    It 'hands out fresh objects so a caller cannot mutate the allow-list' {
        $first = Get-TestQueryTable
        $first[0].Binary = '/tmp/not-a-query'
        $second = Get-TestQueryTable
        $second[0].Binary | Should -Be '/usr/bin/fdesetup'
    }
}

Describe 'Invoke-VacateSystemQuery' {
    It 'throws on a name that is not in the allow-list' {
        { Get-TestQueryResult -Name 'rm-rf' -Platform 'linux' } | Should -Throw "*unknown query 'rm-rf'*"
        { Get-TestQueryResult -Name '/usr/bin/env' -Platform 'linux' } | Should -Throw '*unknown query*'
    }

    It 'reports not-applicable on the wrong platform' {
        $result = Get-TestQueryResult -Name 'block-devices' -Platform 'macos'
        $result.Status | Should -Be 'not-applicable'
        $result.Value | Should -BeNullOrEmpty
        $result.Name | Should -Be 'block-devices'

        (Get-TestQueryResult -Name 'filevault-status' -Platform 'linux').Status | Should -Be 'not-applicable'
        (Get-TestQueryResult -Name 'mounts' -Platform 'windows').Status | Should -Be 'not-applicable'
    }

    It 'reports unavailable when the binary is not installed' -Skip:($script:runtimePlatform -eq 'macos') {
        # fdesetup only exists on macOS, so Windows and Linux must see it missing.
        $result = Get-TestQueryResult -Name 'filevault-status' -Platform 'macos'
        $result.Status | Should -Be 'unavailable'
        $result.Value | Should -BeNullOrEmpty
        $result.Message | Should -Match 'fdesetup'
    }

    It 'runs the default runner with no shell on this machine (filevault-status is never launched)' -Skip:($script:runtimePlatform -ne 'macos') {
        $result = Get-TestQueryResult -Name 'filevault-status' -Platform 'macos'
        $result.Status | Should -Be 'ok'
        @('On', 'Off', 'Unknown') | Should -Contain $result.Value.state
    }

    It 'reports timeout when the runner times out' {
        # A scriptblock runner with no parameters: the fixed binary and arguments are ignored.
        $runner = { @{ ExitCode = -1; StdOut = ''; TimedOut = $true } }
        $result = Get-TestQueryResult -Name 'mounts' -Platform 'linux' -Runner $runner
        $result.Status | Should -Be 'timeout'
        $result.Value | Should -BeNullOrEmpty
        $result.Message | Should -Match '5000'
    }

    It 'reports error on a non-zero exit code' {
        $runner = { @{ ExitCode = 2; StdOut = ''; TimedOut = $false } }
        $result = Get-TestQueryResult -Name 'block-devices' -Platform 'linux' -Runner $runner
        $result.Status | Should -Be 'error'
        $result.Message | Should -Match 'code 2'
    }

    It 'reports error instead of throwing when the output cannot be parsed' {
        $runner = { @{ ExitCode = 0; StdOut = 'not json at all'; TimedOut = $false } }
        $result = Get-TestQueryResult -Name 'block-devices' -Platform 'linux' -Runner $runner
        $result.Status | Should -Be 'error'
        $result.Value | Should -BeNullOrEmpty
    }

    It 'returns the parsed value, never raw output' {
        $result = InModuleScope Vacate -Parameters @{ T = $script:lsblkText } {
            param($T)
            $script:fakeOutput = $T
            $fixed = { @{ ExitCode = 0; StdOut = $script:fakeOutput; TimedOut = $false } }
            Invoke-VacateSystemQuery -Name 'block-devices' -Platform 'linux' -Runner $fixed
        }
        $result.Status | Should -Be 'ok'
        @($result.Value).Count | Should -Be 4
        $result.Value[0].name | Should -Be 'sda'
        $result.Message | Should -BeNullOrEmpty
    }

    It 'accepts a profile object as the platform' {
        $platformProfile = [pscustomobject]@{ Name = 'linux'; CaseSensitive = $true }
        $result = InModuleScope Vacate -Parameters @{ P = $platformProfile; T = $script:lsblkText } {
            param($P, $T)
            $script:fakeOutput = $T
            $fixed = { @{ ExitCode = 0; StdOut = $script:fakeOutput; TimedOut = $false } }
            Invoke-VacateSystemQuery -Name 'block-devices' -Platform $P -Runner $fixed
        }
        $result.Status | Should -Be 'ok'
    }

    It 'passes the fixed binary, the fixed argument array and the timeout to the runner' {
        $captured = InModuleScope Vacate {
            $script:seenInvocation = @{}
            $result = Invoke-VacateSystemQuery -Name 'mounts' -Platform 'linux' -Runner {
                $script:seenInvocation = @{ Binary = $args[0]; Arguments = @($args[1]); TimeoutMs = $args[2] }
                @{ ExitCode = 0; StdOut = '{"filesystems":[]}'; TimedOut = $false }
            }
            return @{ Seen = $script:seenInvocation; Status = $result.Status }
        }
        $captured.Seen['Binary'] | Should -Be '/usr/bin/findmnt'
        (@($captured.Seen['Arguments']) -join ' ') | Should -Be '--json -o TARGET,SOURCE,FSTYPE'
        $captured.Seen['TimeoutMs'] | Should -Be 5000
        $captured.Status | Should -Be 'ok'
    }

    It 'never runs a query for another platform' {
        $runner = { throw 'the runner must not be called' }
        $result = Get-TestQueryResult -Name 'mounts' -Platform 'macos' -Runner $runner
        $result.Status | Should -Be 'not-applicable'
    }
}

Describe 'ConvertFrom-VacateLsblkJson' {
    It 'parses the captured WSL output' {
        $entries = @(Get-TestParserOutput -Function 'lsblk' -Text $script:lsblkText)
        $entries.Count | Should -Be 4
        (@($entries[0].PSObject.Properties.Name) -join ',') | Should -Be 'name,type,fstype,mountpoint,parent'
        $entries[0].name | Should -Be 'sda'
        $entries[0].type | Should -Be 'disk'
        $entries[0].fstype | Should -Be 'ext4'
        $entries[0].mountpoint | Should -BeNullOrEmpty
        $entries[0].parent | Should -BeNullOrEmpty
        $entries[2].name | Should -Be 'sdc'
        $entries[2].fstype | Should -Be 'swap'
        $entries[2].mountpoint | Should -Be '[SWAP]'
    }

    It 'flattens nested children and records the parent' {
        $entries = @(Get-TestParserOutput -Function 'lsblk' -Text $script:lsblkNestedText)
        $entries.Count | Should -Be 7
        (($entries | ForEach-Object { $_.name }) -join ',') | Should -Be 'nvme0n1,nvme0n1p1,nvme0n1p2,nvme0n1p3,cryptroot,sda,sda1'
        $entries[1].name | Should -Be 'nvme0n1p1'
        $entries[1].parent | Should -Be 'nvme0n1'
        $entries[1].mountpoint | Should -Be '/boot/efi'
        $entries[4].name | Should -Be 'cryptroot'
        $entries[4].parent | Should -Be 'nvme0n1p3'
        $entries[6].name | Should -Be 'sda1'
        $entries[6].parent | Should -Be 'sda'
    }

    It 'returns an empty list for an empty blockdevices array' {
        $entries = @(Get-TestParserOutput -Function 'lsblk' -Text '{"blockdevices": []}')
        $entries.Count | Should -Be 0
    }

    It 'throws on empty or non-JSON output' {
        { Get-TestParserOutput -Function 'lsblk' -Text '   ' } | Should -Throw '*empty output*'
        { Get-TestParserOutput -Function 'lsblk' -Text 'no devices' } | Should -Throw
    }
}

Describe 'ConvertFrom-VacateFindmntJson' {
    It 'flattens the captured WSL output into target, source and fstype' {
        $entries = @(Get-TestParserOutput -Function 'findmnt' -Text $script:findmntText)
        $entries.Count | Should -Be 42
        (@($entries[0].PSObject.Properties.Name) -join ',') | Should -Be 'target,source,fstype'
        $entries[0].target | Should -Be '/'
        $entries[0].source | Should -Be '/dev/sdd'
        $entries[0].fstype | Should -Be 'ext4'
    }

    It 'includes mounts that were nested under another mount' {
        $entries = @(Get-TestParserOutput -Function 'findmnt' -Text $script:findmntText)
        $targets = @($entries | ForEach-Object { $_.target })
        $targets | Should -Contain '/mnt/wslg/distro'
        $targets | Should -Contain '/snap/powershell/456'
        $entries[1].target | Should -Be '/usr/lib/modules/6.18.58.1-microsoft-standard-WSL2'
    }

    It 'throws on empty output' {
        { Get-TestParserOutput -Function 'findmnt' -Text '' } | Should -Throw '*empty output*'
    }
}

Describe 'ConvertFrom-VacateFdesetupStatus' {
    It 'reads FileVault is On.' {
        $value = Get-TestParserOutput -Function 'fdesetup' -Text $script:fdesetupOnText
        (@($value.PSObject.Properties.Name) -join ',') | Should -Be 'enabled,state'
        $value.enabled | Should -BeTrue
        $value.state | Should -Be 'On'
    }

    It 'reads FileVault is Off.' {
        $value = Get-TestParserOutput -Function 'fdesetup' -Text $script:fdesetupOffText
        $value.enabled | Should -BeFalse
        $value.state | Should -Be 'Off'
    }

    It 'reports unknown rather than guessing' {
        $value = Get-TestParserOutput -Function 'fdesetup' -Text $script:fdesetupUnknownText
        $value.enabled | Should -BeNullOrEmpty
        $value.state | Should -Be 'Unknown'
    }
}

Describe 'SystemQueries.ps1 static checks' {
    It 'contains no shell, no dynamic code and no elevation' {
        $path = Join-Path $script:projectRoot 'src/Vacate/Private/SystemQueries.ps1'
        $text = [IO.File]::ReadAllText($path)
        $patterns = @(
            'Invoke-Expression',
            'Add-Type',
            'Start-Process',
            '\bcmd(\.exe)?\b',
            '\bbash\b',
            'sh\s+-c',
            '\bsudo\b',
            'UseShellExecute\s*=\s*\$true'
        )
        foreach ($pattern in $patterns) {
            $text | Should -Not -Match $pattern -Because "pattern '$pattern' must not appear"
        }
    }

    It 'allows only the three hard-coded binaries' {
        $path = Join-Path $script:projectRoot 'src/Vacate/Private/SystemQueries.ps1'
        $text = [IO.File]::ReadAllText($path)
        $binaries = @([regex]::Matches($text, "/usr/bin/[A-Za-z0-9_.\-]+") | ForEach-Object { $_.Value } | Sort-Object -Unique)
        ($binaries -join ',') | Should -Be '/usr/bin/fdesetup,/usr/bin/findmnt,/usr/bin/lsblk'
    }
}

Describe 'live system queries' {
    It 'returns real block devices and mounts from this machine' -Tag 'Live' -Skip:($script:runtimePlatform -ne 'linux') {
        $results = @(InModuleScope Vacate {
                $platformProfile = Get-VacatePlatformProfile -Platform (Get-VacatePlatform) -Environment (Get-VacateEnvironmentSnapshot)
                @(
                    (Invoke-VacateSystemQuery -Name 'block-devices' -Platform $platformProfile),
                    (Invoke-VacateSystemQuery -Name 'mounts' -Platform $platformProfile)
                )
            })
        $results.Count | Should -Be 2
        foreach ($result in $results) {
            $result.Status | Should -Be 'ok' -Because $result.Message
            @($result.Value).Count | Should -BeGreaterThan 0
        }
    }
}
