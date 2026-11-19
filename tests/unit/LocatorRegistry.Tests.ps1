# Registry locator tests. Fakes only: the real provider belongs to another partner.
# Pester 5 runs It bodies in a scope that does not see the file body, so helpers live in BeforeAll.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestProfile {
        param([string]$Name = 'windows')
        $comparison = [StringComparison]::OrdinalIgnoreCase
        $separator = [char]'\'
        if ($Name -eq 'linux') {
            $comparison = [StringComparison]::Ordinal
            $separator = [char]'/'
        }
        return [pscustomobject][ordered]@{
            Name          = $Name
            CaseSensitive = ($Name -eq 'linux')
            Comparison    = $comparison
            Separator     = $separator
            Roots         = [ordered]@{}
            HomePath      = ''
            UsersRoot     = ''
            UserName      = 'ann'
        }
    }

    function Get-TestContext {
        param(
            [object]$Registry = $null,
            [object]$Cim = $null,
            [object]$SystemQuery = $null,
            [string]$Platform = 'windows'
        )
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
            [Parameter(Mandatory)][System.Collections.IDictionary]$Locator,
            [string]$Id = 'test.locator'
        )
        return [pscustomobject][ordered]@{
            id                = $Id
            platforms         = @('windows')
            category          = 'activity'
            title             = 'Test locator rule'
            whyItMatters      = 'Unit test rule for a locator executor.'
            sensitivity       = 'low'
            locator           = [pscustomobject]$Locator
            measure           = @('exists')
            maxEntries        = 100
            requiresElevation = $false
            verifiedOn        = @()
            verified          = $false
            source            = 'Unit test source, not a real rule'
            notes             = $null
        }
    }

    function Get-TestRegistryProvider {
        # Read-only fake exposing the two registry provider methods.
        # Values are held on the object because a ScriptMethod cannot see the caller's scope.
        param(
            [object]$Key = $null,
            [object]$SubKeyValues = $null,
            [object]$FailWith = $null
        )
        $provider = [pscustomobject]@{
            Name         = 'fake-registry'
            Key          = $Key
            SubKeyValues = $SubKeyValues
            FailWith     = $FailWith
            Calls        = (New-Object System.Collections.ArrayList)
        }
        $provider | Add-Member -MemberType ScriptMethod -Name 'GetKey' -Value {
            param($Hive, $Path, $View)
            if ([string]::IsNullOrWhiteSpace($Path)) { throw 'the provider was called without a key path' }
            [void]$this.Calls.Add(("GetKey:{0}|{1}|{2}" -f $Hive, $Path, $View))
            if ($null -ne $this.FailWith) { throw $this.FailWith }
            return $this.Key
        }
        $provider | Add-Member -MemberType ScriptMethod -Name 'GetSubKeyValues' -Value {
            param($Hive, $Path, $View, $ValueNames)
            if ([string]::IsNullOrWhiteSpace($Path)) { throw 'the provider was called without a key path' }
            [void]$this.Calls.Add(("GetSubKeyValues:{0}|{1}|{2}" -f $Hive, $View, ($ValueNames -join ',')))
            if ($null -ne $this.FailWith) { throw $this.FailWith }
            return $this.SubKeyValues
        }
        return $provider
    }

    function Get-TestDeadline {
        param([int]$Minutes = 5)
        return [datetime]::UtcNow.AddMinutes($Minutes)
    }

    function Invoke-TestRegistryLocator {
        param([object]$Rule, [object]$Context, [datetime]$Deadline)
        return (InModuleScope Vacate -Parameters @{ R = $Rule; C = $Context; D = $Deadline } {
                param($R, $C, $D)
                Invoke-VacateRegistryLocator -Rule $R -Context $C -Deadline $D
            })
    }

    $script:runMruLocator = [ordered]@{ kind = 'registry'; hive = 'HKCU'; key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU' }
    $script:presentKey = @{ ValueCount = 3; SubKeyCount = 2; SubKeyNames = @('a', 'b') }
}

Describe 'Invoke-VacateRegistryLocator' {
    It 'returns one trace for a present key' {
        $context = Get-TestContext -Registry (Get-TestRegistryProvider -Key $script:presentKey)
        $rule = Get-TestRule -Locator $script:runMruLocator

        $result = Invoke-TestRegistryLocator -Rule $rule -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 1
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        @($result.Programs).Count | Should -Be 0

        $trace = $result.Traces[0]
        $trace.ruleId | Should -Be 'test.locator'
        $trace.platform | Should -Be 'windows'
        $trace.locator.kind | Should -Be 'registry'
        $trace.locator.resolved | Should -Be 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
        $trace.exists | Should -BeTrue
        $trace.itemCount | Should -Be 5
        $trace.sizeBytes | Should -BeNullOrEmpty
        $trace.lastWriteTime | Should -BeNullOrEmpty
        $trace.properties.valueCount | Should -Be 3
        $trace.properties.subkeyCount | Should -Be 2
        $trace.confidence | Should -Be 'unverified'
    }

    It 'asks the provider for the rule hive, key and view' {
        $provider = Get-TestRegistryProvider -Key $script:presentKey
        $context = Get-TestContext -Registry $provider

        [void](Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $script:runMruLocator) -Context $context -Deadline (Get-TestDeadline))

        $provider.Calls.Count | Should -Be 1
        $provider.Calls[0] | Should -Be 'GetKey:HKCU|Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU|Default'
    }

    It 'returns no trace for a missing key' {
        $provider = Get-TestRegistryProvider -Key $null
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $script:runMruLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        $provider.Calls.Count | Should -Be 1
    }

    It 'marks the 32-bit view in the resolved path' {
        $provider = Get-TestRegistryProvider -Key @{ ValueCount = 1; SubKeyCount = 0; SubKeyNames = @() }
        $context = Get-TestContext -Registry $provider
        $locator = [ordered]@{ kind = 'registry'; hive = 'HKLM'; key = 'SOFTWARE\WOW6432Node\Test'; view = 'Registry32' }

        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $locator) -Context $context -Deadline (Get-TestDeadline)

        $result.Traces[0].locator.resolved | Should -Be 'HKLM\SOFTWARE\WOW6432Node\Test (32-bit)'
        $provider.Calls[0] | Should -Be 'GetKey:HKLM|SOFTWARE\WOW6432Node\Test|Registry32'
    }

    It 'does not label the default view as 32-bit' {
        $context = Get-TestContext -Registry (Get-TestRegistryProvider -Key @{ ValueCount = 1; SubKeyCount = 1; SubKeyNames = @('x') })
        $locator = [ordered]@{ kind = 'registry'; hive = 'HKLM'; key = 'SOFTWARE\Test'; view = 'Registry64' }

        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $locator) -Context $context -Deadline (Get-TestDeadline)

        $result.Traces[0].locator.resolved | Should -Be 'HKLM\SOFTWARE\Test'
    }

    It 'skips with permission when the key is denied' {
        $denied = New-Object -TypeName 'System.UnauthorizedAccessException' -ArgumentList 'Access to the registry key is denied.'
        $context = Get-TestContext -Registry (Get-TestRegistryProvider -FailWith $denied)

        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $script:runMruLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 1
        $result.Skips[0].reason | Should -Be 'permission'
        $result.Skips[0].ruleId | Should -Be 'test.locator'
        $result.Skips[0].detail | Should -Match 'RunMRU'
    }

    It 'skips with permission when the provider text says access is denied' {
        $context = Get-TestContext -Registry (Get-TestRegistryProvider -FailWith (New-Object -TypeName 'System.Exception' -ArgumentList 'Access is denied.'))

        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $script:runMruLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'permission'
    }

    It 'records an error for an unexpected provider failure' {
        $broken = New-Object -TypeName 'System.InvalidOperationException' -ArgumentList 'the hive handle is corrupt'
        $context = Get-TestContext -Registry (Get-TestRegistryProvider -FailWith $broken)

        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $script:runMruLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].ruleId | Should -Be 'test.locator'
        $result.Errors[0].type | Should -Be 'InvalidOperationException'
        $result.Errors[0].message | Should -Match 'corrupt'
    }

    It 'skips with unavailable when the scan has no registry provider' {
        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $script:runMruLocator) -Context (Get-TestContext -Registry $null) -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'unavailable'
    }

    It 'returns only a timeout skip when the deadline has passed' {
        $provider = Get-TestRegistryProvider -Key $script:presentKey
        $context = Get-TestContext -Registry $provider

        $result = Invoke-TestRegistryLocator -Rule (Get-TestRule -Locator $script:runMruLocator) -Context $context -Deadline ([datetime]::UtcNow.AddMinutes(-1))

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 1
        $result.Skips[0].reason | Should -Be 'timeout'
        $provider.Calls.Count | Should -Be 0 -Because 'nothing may be read after the deadline'
    }
}
