# Detector for the sabotage mutation "force exists = $true" (SPEC "Harness self-test").
# New-VacateTrace carries the exists flag of the trace; nothing else in the suite passed
# -Exists $false, so forcing the flag to $true used to leave the suite green.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestTraceRule {
        param()
        return [pscustomobject][ordered]@{
            id                = 'safety.trace.exists'
            platforms         = @('windows', 'macos', 'linux')
            category          = 'activity'
            title             = 'Trace exists flag'
            whyItMatters      = 'Detector for the sabotage harness.'
            sensitivity       = 'low'
            locator           = [pscustomobject][ordered]@{ kind = 'path'; root = 'HOME'; path = 'Somewhere' }
            measure           = @('exists')
            maxEntries        = 10
            requiresElevation = $false
            verifiedOn        = @()
            verified          = $false
            source            = 'Sabotage detector, not a real rule'
            notes             = $null
        }
    }
}

Describe 'trace exists flag' {
    It 'keeps exists = $false instead of claiming the data is there' {
        $trace = InModuleScope Vacate -Parameters @{ R = (Get-TestTraceRule) } {
            param($R)
            New-VacateTrace -Rule $R -Platform 'linux' -Resolved '/home/a/Somewhere' -Exists $false
        }
        $trace.exists | Should -BeFalse
    }

    It 'defaults exists to $true' {
        $trace = InModuleScope Vacate -Parameters @{ R = (Get-TestTraceRule) } {
            param($R)
            New-VacateTrace -Rule $R -Platform 'linux' -Resolved '/home/a/Somewhere'
        }
        $trace.exists | Should -BeTrue
    }

    It 'reports exists = $false for a locator that only saw an absence' {
        $rule = Get-TestTraceRule
        $trace = InModuleScope Vacate -Parameters @{ R = $rule } {
            param($R)
            New-VacateTrace -Rule $R -Platform 'windows' -Resolved 'C:\Users\a\Somewhere' -Exists $false -ItemCount 0
        }
        $trace.exists | Should -BeFalse
        $trace.itemCount | Should -Be 0
        $trace.confidence | Should -Be 'unverified'
    }
}
