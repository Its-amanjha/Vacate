# System-query locator tests. Fakes only: no binary is ever started.
# Pester 5 runs It bodies in a scope that does not see the file body, so helpers live in BeforeAll.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestProfile {
        param([string]$Name = 'linux')
        return [pscustomobject][ordered]@{
            Name          = $Name
            CaseSensitive = $true
            Comparison    = [StringComparison]::Ordinal
            Separator     = [char]'/'
            Roots         = [ordered]@{}
            HomePath      = '/home/ann'
            UsersRoot     = '/home'
            UserName      = 'ann'
        }
    }

    function Get-TestContext {
        param([object]$Registry = $null, [object]$Cim = $null, [object]$SystemQuery = $null, [string]$Platform = 'linux')
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
        param([string]$Name = 'mounts', [string]$Id = 'signals.devices.mounts', [string]$Platform = 'linux')
        return [pscustomobject][ordered]@{
            id                = $Id
            platforms         = @($Platform)
            category          = 'signals'
            title             = 'Mounted volumes'
            whyItMatters      = 'Unit test rule for a locator executor.'
            sensitivity       = 'low'
            locator           = [pscustomobject][ordered]@{ kind = 'system-query'; name = $Name }
            measure           = @('properties')
            maxEntries        = 200
            requiresElevation = $false
            verifiedOn        = @()
            verified          = $false
            source            = 'Unit test source, not a real rule'
            notes             = $null
        }
    }

    function Get-TestResult {
        param([string]$Status, [object]$Value = $null, [object]$Message = $null, [string]$Name = 'mounts')
        return [pscustomobject][ordered]@{
            Name    = $Name
            Status  = $Status
            Value   = $Value
            Message = $Message
        }
    }

    function Get-TestDeadline {
        param([int]$Minutes = 5)
        return [datetime]::UtcNow.AddMinutes($Minutes)
    }

    function Invoke-TestSystemQueryLocator {
        param([object]$Rule, [object]$Context, [datetime]$Deadline)
        return (InModuleScope Vacate -Parameters @{ R = $Rule; C = $Context; D = $Deadline } {
                param($R, $C, $D)
                Invoke-VacateSystemQueryLocator -Rule $R -Context $C -Deadline $D
            })
    }

    $script:mounts = @(
        [pscustomobject][ordered]@{ target = '/'; source = '/dev/sda1'; fstype = 'ext4' },
        [pscustomobject][ordered]@{ target = '/boot'; source = '/dev/sda2'; fstype = 'vfat' }
    )
}

Describe 'Invoke-VacateSystemQueryLocator' {
    It 'returns one trace carrying the parsed query value' {
        $calls = New-Object System.Collections.ArrayList
        $runner = {
            param($Name)
            [void]$calls.Add($Name)
            return (Get-TestResult -Status 'ok' -Value $script:mounts)
        }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 1
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0

        $trace = $result.Traces[0]
        $trace.ruleId | Should -Be 'signals.devices.mounts'
        $trace.platform | Should -Be 'linux'
        $trace.locator.kind | Should -Be 'system-query'
        $trace.locator.resolved | Should -Be '/usr/bin/findmnt --json -o TARGET,SOURCE,FSTYPE'
        $trace.itemCount | Should -Be 2
        $trace.properties.items[0].target | Should -Be '/'
        $trace.properties.items[1].fstype | Should -Be 'vfat'
        $trace.confidence | Should -Be 'unverified'

        $calls.Count | Should -Be 1
        $calls[0] | Should -Be 'mounts'
    }

    It 'resolves the allow-listed command for each query name' {
        $runner = { return (Get-TestResult -Status 'ok' -Value @([pscustomobject]@{ name = 'sda'; type = 'disk' })) }
        $context = Get-TestContext -SystemQuery $runner
        $rule = Get-TestRule -Name 'block-devices'

        $result = Invoke-TestSystemQueryLocator -Rule $rule -Context $context -Deadline (Get-TestDeadline)

        $result.Traces[0].locator.resolved | Should -Be '/usr/bin/lsblk --json -o NAME,TYPE,FSTYPE,MOUNTPOINT'
    }

    It 'keeps an object value as the trace properties' {
        $runner = { return (Get-TestResult -Status 'ok' -Value ([pscustomobject][ordered]@{ enabled = $true; state = 'On' })) }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        $result.Traces[0].properties.enabled | Should -BeTrue
        $result.Traces[0].properties.state | Should -Be 'On'
        $result.Traces[0].itemCount | Should -BeNullOrEmpty
    }

    It 'skips with unavailable when the binary is missing' {
        $runner = { return (Get-TestResult -Status 'unavailable' -Message 'findmnt is not installed') }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 1
        $result.Skips[0].reason | Should -Be 'unavailable'
        $result.Skips[0].detail | Should -Match 'findmnt'
        $result.Skips[0].ruleId | Should -Be 'signals.devices.mounts'
    }

    It 'skips with timeout when the query runs too long' {
        $runner = { return (Get-TestResult -Status 'timeout' -Message 'query exceeded 5s') }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'timeout'
        $result.Skips[0].detail | Should -Match '5s'
    }

    It 'skips with unavailable when the query does not apply to this platform' {
        $runner = { return (Get-TestResult -Status 'not-applicable' -Message 'block-devices is a linux query') }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 1
        $result.Skips[0].reason | Should -Be 'unavailable'
        $result.Skips[0].detail | Should -Match 'linux'
    }

    It 'records an error for an error status' {
        $runner = { return (Get-TestResult -Status 'error' -Message 'exit code 1') }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].ruleId | Should -Be 'signals.devices.mounts'
        $result.Errors[0].message | Should -Match 'exit code 1'
    }

    It 'records an error for an unknown status' {
        $runner = { return (Get-TestResult -Status 'partial' -Message 'half parsed') }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].message | Should -Match 'partial'
    }

    It 'records an error when the runner returns nothing' {
        $runner = { return $null }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].type | Should -Be 'SystemQuery'
    }

    It 'records an error when the runner itself fails' {
        $runner = { throw (New-Object -TypeName 'System.InvalidOperationException' -ArgumentList 'the query table is broken') }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].message | Should -Match 'broken'
    }

    It 'skips with unavailable when the scan has no system-query runner' {
        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context (Get-TestContext -SystemQuery $null) -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'unavailable'
    }

    It 'records an error when the rule names no query' {
        $calls = New-Object System.Collections.ArrayList
        $runner = { param($Name) [void]$calls.Add($Name); return (Get-TestResult -Status 'ok' -Value @()) }
        $context = Get-TestContext -SystemQuery $runner
        $rule = Get-TestRule
        $rule.locator = [pscustomobject][ordered]@{ kind = 'system-query'; name = '' }

        $result = Invoke-TestSystemQueryLocator -Rule $rule -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].type | Should -Be 'InvalidRule'
        $calls.Count | Should -Be 0
    }

    It 'returns only a timeout skip when the deadline has passed' {
        $calls = New-Object System.Collections.ArrayList
        $runner = { param($Name) [void]$calls.Add($Name); return (Get-TestResult -Status 'ok' -Value @()) }
        $context = Get-TestContext -SystemQuery $runner

        $result = Invoke-TestSystemQueryLocator -Rule (Get-TestRule) -Context $context -Deadline ([datetime]::UtcNow.AddMinutes(-1))

        @($result.Traces).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'timeout'
        $calls.Count | Should -Be 0 -Because 'nothing may be run after the deadline'
    }
}