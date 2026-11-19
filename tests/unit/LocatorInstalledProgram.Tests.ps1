# Installed-program locator tests. Fakes only: the real registry provider is another partner's.
# Pester 5 runs It bodies in a scope that does not see the file body, so helpers live in BeforeAll.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestProfile {
        param([string]$Name = 'windows')
        return [pscustomobject][ordered]@{
            Name          = $Name
            CaseSensitive = $false
            Comparison    = [StringComparison]::OrdinalIgnoreCase
            Separator     = [char]'\'
            Roots         = [ordered]@{}
            HomePath      = 'C:\Users\ann'
            UsersRoot     = 'C:\Users'
            UserName      = 'ann'
        }
    }

    function Get-TestContext {
        param([object]$Registry = $null, [object]$Cim = $null, [object]$SystemQuery = $null, [string]$Platform = 'windows')
        return [pscustomobject][ordered]@{
            Platform    = (Get-TestProfile -Name $Platform)
            FileSystem  = $null
            Registry    = $Registry
            Cim         = $Cim
            SystemQuery = $SystemQuery
            Elevated    = $false
            MountPoints = @()
            Exclude     = @()
        }
    }

    function Get-TestRule {
        param(
            [string]$Scope = 'all',
            [string]$Id = 'programs.installed.all',
            [string]$Platform = 'windows'
        )
        return [pscustomobject][ordered]@{
            id                = $Id
            platforms         = @($Platform)
            category          = 'activity'
            title             = 'Installed programs'
            whyItMatters      = 'Unit test rule for a locator executor.'
            sensitivity       = 'low'
            locator           = [pscustomobject][ordered]@{ kind = 'installed-program'; scope = $Scope }
            measure           = @('exists')
            maxEntries        = 500
            requiresElevation = $false
            verifiedOn        = @()
            verified          = $false
            source            = 'Unit test source, not a real rule'
            notes             = $null
        }
    }

    function Get-TestEntry {
        param([object]$Name, [object]$Version, [object]$Publisher, [object]$InstallDate, [object]$SystemComponent = $null)
        return @{
            Values = @{
                DisplayName     = $Name
                DisplayVersion  = $Version
                Publisher       = $Publisher
                InstallDate     = $InstallDate
                SystemComponent = $SystemComponent
            }
        }
    }

    function Get-TestRegistryProvider {
        # Read-only fake exposing the two provider methods from CONTRACTS section 4.
        param(
            [object]$Machine64 = @(),
            [object]$Machine32 = @(),
            [object]$User = @(),
            [object]$FailWith = $null,
            [string]$FailOnHive = 'HKLM'
        )
        $provider = [pscustomobject]@{
            Name      = 'fake-registry'
            Machine64 = $Machine64
            Machine32 = $Machine32
            User      = $User
            FailWith  = $FailWith
            FailOnHive = $FailOnHive
            Calls     = (New-Object System.Collections.ArrayList)
        }
        $provider | Add-Member -MemberType ScriptMethod -Name 'GetKey' -Value {
            param($Hive, $Path, $View)
            if ([string]::IsNullOrWhiteSpace($Path)) { throw 'the provider was called without a key path' }
            [void]$this.Calls.Add(("GetKey:{0}|{1}" -f $Hive, $View))
            return $null
        }
        $provider | Add-Member -MemberType ScriptMethod -Name 'GetSubKeyValues' -Value {
            param($Hive, $Path, $View, $ValueNames)
            if ($Path -ne $script:uninstallKey) { throw ("unexpected key path '{0}'" -f $Path) }
            [void]$this.Calls.Add(("GetSubKeyValues:{0}|{1}|{2}" -f $Hive, $View, (@($ValueNames) -join ',')))
            if ($null -ne $this.FailWith -and $Hive -eq $this.FailOnHive) { throw $this.FailWith }
            if ($Hive -eq 'HKCU') { return $this.User }
            if ($View -eq 'Registry32') { return $this.Machine32 }
            return $this.Machine64
        }
        return $provider
    }

    function Get-TestDeadline {
        param([int]$Minutes = 5)
        return [datetime]::UtcNow.AddMinutes($Minutes)
    }

    function Invoke-TestProgramLocator {
        param([object]$Rule, [object]$Context, [datetime]$Deadline)
        return (InModuleScope Vacate -Parameters @{ R = $Rule; C = $Context; D = $Deadline } {
                param($R, $C, $D)
                Invoke-VacateInstalledProgramLocator -Rule $R -Context $C -Deadline $D
            })
    }

    $script:uninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
}

Describe 'Invoke-VacateInstalledProgramLocator' {
    It 'returns the name, publisher, version, install date and scope of each program' {
        $provider = Get-TestRegistryProvider -Machine64 @(
            (Get-TestEntry -Name 'Contoso Suite' -Version '4.1.2' -Publisher 'Contoso Ltd' -InstallDate '20240131')
        )
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Programs).Count | Should -Be 1
        $program = $result.Programs[0]
        $program.name | Should -Be 'Contoso Suite'
        $program.publisher | Should -Be 'Contoso Ltd'
        $program.version | Should -Be '4.1.2'
        $program.installDate | Should -Be '2024-01-31'
        $program.scope | Should -Be 'machine'

        @($result.Traces).Count | Should -Be 1
        $result.Traces[0].ruleId | Should -Be 'programs.installed.all'
        $result.Traces[0].locator.kind | Should -Be 'installed-program'
        $result.Traces[0].locator.resolved | Should -Be ('HKLM\' + $script:uninstallKey)
        $result.Traces[0].itemCount | Should -Be 1
        $result.Traces[0].confidence | Should -Be 'unverified'
    }

    It 'reads the 64-bit and 32-bit machine keys, then the user key' {
        $provider = Get-TestRegistryProvider -Machine64 @() -Machine32 @() -User @()
        $context = Get-TestContext -Registry $provider

        [void](Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline))

        $provider.Calls.Count | Should -Be 3
        $provider.Calls[0] | Should -Be ('GetSubKeyValues:HKLM|Registry64|DisplayName,Publisher,DisplayVersion,InstallDate,SystemComponent')
        $provider.Calls[1] | Should -Be ('GetSubKeyValues:HKLM|Registry32|DisplayName,Publisher,DisplayVersion,InstallDate,SystemComponent')
        $provider.Calls[2] | Should -Be ('GetSubKeyValues:HKCU|Default|DisplayName,Publisher,DisplayVersion,InstallDate,SystemComponent')
    }

    It 'reads only the machine keys for scope machine' {
        $provider = Get-TestRegistryProvider
        $context = Get-TestContext -Registry $provider

        [void](Invoke-TestProgramLocator -Rule (Get-TestRule -Scope 'machine') -Context $context -Deadline (Get-TestDeadline))

        $provider.Calls.Count | Should -Be 2
        ($provider.Calls -join ';') | Should -Not -Match 'HKCU'
    }

    It 'reads only the user key for scope user and labels it user' {
        $provider = Get-TestRegistryProvider -User @((Get-TestEntry -Name 'Notepad' -Version '1.0' -Publisher 'Me' -InstallDate '20230201'))
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule -Scope 'user') -Context $context -Deadline (Get-TestDeadline)

        $provider.Calls.Count | Should -Be 1
        $provider.Calls[0] | Should -Match 'HKCU'
        $result.Programs[0].scope | Should -Be 'user'
        $result.Traces[0].locator.resolved | Should -Be ('HKCU\' + $script:uninstallKey)
    }

    It 'drops entries without a display name' {
        $provider = Get-TestRegistryProvider -Machine64 @(
            (Get-TestEntry -Name $null -Version '9.9' -Publisher 'Somebody' -InstallDate '20240101'),
            (Get-TestEntry -Name '   ' -Version '9.9' -Publisher 'Somebody' -InstallDate '20240101'),
            (Get-TestEntry -Name 'Real App' -Version '1.0' -Publisher 'Somebody' -InstallDate '20240101')
        )
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Programs).Count | Should -Be 1
        $result.Programs[0].name | Should -Be 'Real App'
    }

    It 'drops system components and keeps ordinary entries' {
        $provider = Get-TestRegistryProvider -Machine64 @(
            (Get-TestEntry -Name 'Contoso Patch' -Version '1.0' -Publisher 'Contoso' -InstallDate '20240101' -SystemComponent '1'),
            (Get-TestEntry -Name 'Contoso Suite' -Version '1.0' -Publisher 'Contoso' -InstallDate '20240101' -SystemComponent '0')
        )
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Programs).Count | Should -Be 1
        $result.Programs[0].name | Should -Be 'Contoso Suite'
    }

    It 'removes a program listed in both machine views' {
        $entry = Get-TestEntry -Name 'Contoso Suite' -Version '1.0' -Publisher 'Contoso' -InstallDate '20240101'
        $provider = Get-TestRegistryProvider -Machine64 @($entry) -Machine32 @($entry)
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Programs).Count | Should -Be 1
        @($result.Traces).Count | Should -Be 1
        $result.Traces[0].itemCount | Should -Be 1
    }

    It 'sorts programs by name in ordinal order' {
        $provider = Get-TestRegistryProvider -Machine64 @(
            (Get-TestEntry -Name 'delta' -Version '1.0' -Publisher 'x' -InstallDate '20240101'),
            (Get-TestEntry -Name 'Zeta' -Version '1.0' -Publisher 'x' -InstallDate '20240101'),
            (Get-TestEntry -Name 'Beta' -Version '1.0' -Publisher 'x' -InstallDate '20240101')
        )
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        $names = @($result.Programs | ForEach-Object { $_.name })
        $names | Should -Be @('Beta', 'Zeta', 'delta')
    }

    It 'keeps a null install date when the value is not a date' {
        $provider = Get-TestRegistryProvider -Machine64 @(
            (Get-TestEntry -Name 'Dated' -Version '1.0' -Publisher 'x' -InstallDate '2024-01-31'),
            (Get-TestEntry -Name 'Stamped' -Version '1.0' -Publisher 'x' -InstallDate '20240131'),
            (Get-TestEntry -Name 'Garbled' -Version '1.0' -Publisher 'x' -InstallDate 'soon')
        )
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        $dates = [ordered]@{}
        foreach ($program in $result.Programs) { $dates[$program.name] = $program.installDate }
        $dates['Stamped'] | Should -Be '2024-01-31'
        $dates['Dated'] | Should -BeNullOrEmpty
        $dates['Garbled'] | Should -BeNullOrEmpty
    }

    It 'reports a skip when a key is denied and keeps the other scopes' {
        $denied = New-Object -TypeName 'System.UnauthorizedAccessException' -ArgumentList 'Access is denied.'
        $provider = Get-TestRegistryProvider -Machine64 @((Get-TestEntry -Name 'Visible' -Version '1.0' -Publisher 'x' -InstallDate '20240101')) -FailWith $denied -FailOnHive 'HKCU'
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 1
        $result.Skips[0].reason | Should -Be 'permission'
        @($result.Programs).Count | Should -Be 1
        $result.Programs[0].name | Should -Be 'Visible'
    }

    It 'returns nothing when every key is missing' {
        $provider = Get-TestRegistryProvider -Machine64 $null -Machine32 $null -User $null
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Programs).Count | Should -Be 0
        @($result.Traces).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
    }

    It 'skips with unavailable when the scan has no registry provider' {
        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context (Get-TestContext -Registry $null) -Deadline (Get-TestDeadline)

        @($result.Programs).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'unavailable'
    }

    It 'records an error for an unknown scope instead of guessing' {
        $provider = Get-TestRegistryProvider -Machine64 @((Get-TestEntry -Name 'Visible' -Version '1.0' -Publisher 'x' -InstallDate '20240101'))
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule -Scope 'everyone') -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Programs).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].type | Should -Be 'InvalidRule'
        $provider.Calls.Count | Should -Be 0
    }

    It 'returns only a timeout skip when the deadline has passed' {
        $provider = Get-TestRegistryProvider -Machine64 @((Get-TestEntry -Name 'Visible' -Version '1.0' -Publisher 'x' -InstallDate '20240101'))
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestProgramLocator -Rule (Get-TestRule) -Context $context -Deadline ([datetime]::UtcNow.AddMinutes(-1))

        @($result.Programs).Count | Should -Be 0
        @($result.Traces).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'timeout'
        $provider.Calls.Count | Should -Be 0
    }
}
