# Detector for the sabotage mutation "drop a rule" (SPEC "Harness self-test").
# The rest of the suite loads rule fixtures, not the shipped catalog, so deleting a shipped rule
# JSON used to leave the suite green. These counts are a floor: adding rules is fine, losing one
# is not. Values live in tests/fixtures/catalog-counts.json.
# Nothing here is needed at Pester discovery time, so the paths and the fixture live in BeforeAll.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:ruleRoot = Join-Path $script:repoRoot 'src/Vacate/rules'
    $script:countsPath = Join-Path $script:repoRoot 'tests/fixtures/catalog-counts.json'
    $script:catalogCounts = [IO.File]::ReadAllText($script:countsPath) | ConvertFrom-Json
    $script:platformNames = @('windows', 'macos', 'linux')

    # One full load of the shipped catalog, through the real loader.
    $script:catalog = InModuleScope Vacate -Parameters @{ P = $script:ruleRoot } {
        param($P)
        Import-VacateRuleSet -Path $P
    }
}

Describe 'shipped rule catalog floor' {
    It 'has a usable fixture' {
        Test-Path -LiteralPath $script:countsPath -PathType Leaf | Should -BeTrue
        ([int]$script:catalogCounts.files) | Should -BeGreaterThan 0
        foreach ($platform in $script:platformNames) {
            ([int]$script:catalogCounts.platforms.$platform) | Should -BeGreaterThan 0 -Because "the fixture needs a floor for $platform"
        }
    }

    It 'loads a rule for every shipped rule file' {
        @($script:catalog.Errors).Count | Should -Be 0 -Because 'every shipped rule must stay valid'
        ([int]$script:catalog.FileCount) | Should -BeGreaterOrEqual ([int]$script:catalogCounts.files) -Because 'a missing rule file means a dropped rule'
        @($script:catalog.Rules).Count | Should -BeGreaterOrEqual ([int]$script:catalogCounts.files) -Because 'a rule that no longer loads is a dropped rule'
    }

    It 'keeps at least the recorded number of rules for every platform' {
        foreach ($platform in $script:platformNames) {
            $expected = [int]$script:catalogCounts.platforms.$platform
            $actual = @($script:catalog.Rules | Where-Object { @($_.platforms) -ccontains $platform }).Count
            $actual | Should -BeGreaterOrEqual $expected -Because "dropping a $platform rule must fail the suite (floor is $expected)"
        }
    }

    It 'still resolves each platform to its own folder' {
        foreach ($platform in $script:platformNames) {
            $folderFiles = @([IO.Directory]::GetFiles((Join-Path $script:ruleRoot $platform), '*.json'))
            $expected = [int]$script:catalogCounts.platforms.$platform
            $folderFiles.Count | Should -BeGreaterOrEqual $expected -Because "the $platform folder must keep its rule files"
        }
    }
}
