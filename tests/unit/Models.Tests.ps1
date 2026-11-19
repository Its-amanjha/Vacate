BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
}

Describe 'Models' {
    It 'defines root tokens for exactly the three platforms' {
        InModuleScope Vacate {
            @($script:VacateRootTokens.Keys | Sort-Object) | Should -Be @('linux', 'macos', 'windows')
            $script:VacateRootTokens.windows | Should -Contain 'LOCALAPPDATA'
            $script:VacateRootTokens.linux | Should -Not -Contain 'LOCALAPPDATA'
        }
    }

    It 'ranks sensitivities in ascending order' {
        InModuleScope Vacate {
            (Get-VacateSensitivityRank 'low') | Should -BeLessThan (Get-VacateSensitivityRank 'critical')
            { Get-VacateSensitivityRank 'extreme' } | Should -Throw
        }
    }

    It 'formats times as UTC ISO-8601' {
        InModuleScope Vacate {
            $t = [datetime]::SpecifyKind([datetime]'2026-11-01 12:00:00', [DateTimeKind]::Utc)
            ConvertTo-VacateIsoTime $t | Should -Be '2026-11-01T12:00:00Z'
            ConvertTo-VacateIsoTime $null | Should -BeNullOrEmpty
        }
    }

    It 'builds a trace with fixed key order and a 3-sample cap' {
        InModuleScope Vacate {
            $rule = [pscustomobject]@{
                id = 'browser.chrome.history'; category = 'browsers'; title = 'Chrome history'
                sensitivity = 'high'; verified = $false; requiresElevation = $false
                locator = [pscustomobject]@{ kind = 'path' }
            }
            $t = New-VacateTrace -Rule $rule -Platform 'windows' -Resolved 'C:\x\History' -Samples @('a', 'b', 'c', 'd')
            @($t.PSObject.Properties.Name) | Should -Be @('ruleId', 'platform', 'category', 'title', 'sensitivity', 'locator', 'exists', 'sizeBytes', 'itemCount', 'lastWriteTime', 'samples', 'truncated', 'confidence', 'requiresElevation', 'error')
            $t.samples.Count | Should -Be 3
            $t.confidence | Should -Be 'unverified'
        }
    }

    It 'refuses a trace without a locator' {
        InModuleScope Vacate {
            $rule = [pscustomobject]@{ id = 'x.y'; category = 'browsers'; title = 't'; sensitivity = 'low'; verified = $true; requiresElevation = $false; locator = [pscustomobject]@{ kind = 'path' } }
            { New-VacateTrace -Rule $rule -Platform 'windows' -Resolved ' ' } | Should -Throw
        }
    }

    It 'rejects unknown skip reasons' {
        InModuleScope Vacate {
            (New-VacateSkip -RuleId 'a.b' -Reason 'budget').reason | Should -Be 'budget'
            { New-VacateSkip -RuleId 'a.b' -Reason 'bored' } | Should -Throw
        }
    }
}
