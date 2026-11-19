BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestCleanup {
        param([hashtable]$Override = @{})
        $c = [ordered]@{
            action      = 'export-then-remove'
            exportFirst = 'Export saved passwords from the browser password settings.'
            signOut     = 'Turn off sync in the browser account settings.'
            steps       = @('Close every browser window.', 'Uninstall the browser from the system app list.')
            risk        = 'Removes history, saved logins and cookies.'
            closeApps   = @('Google Chrome')
            resetCovers = $true
            reason      = $null
            source      = 'Google Chrome Help, Sign in and sync: https://support.google.com/chrome/answer/185277'
        }
        foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
        return $c
    }

    function Get-CleanupProblem {
        param([System.Collections.IDictionary]$Cleanup)
        $rule = [ordered]@{
            id = 'browser.chrome.history'; platforms = @('windows'); category = 'browsers'
            title = 'Chrome history database'; whyItMatters = 'Lists every site visited and when.'
            sensitivity = 'high'
            locator = [ordered]@{ kind = 'path'; root = 'LOCALAPPDATA'; path = 'Google/Chrome/User Data/*/History'; match = 'files' }
            measure = @('exists'); maxEntries = 10; requiresElevation = $false; verifiedOn = @(); verified = $false
            source = 'Chromium user data directory docs'; notes = $null; cleanup = $Cleanup
        }
        $obj = ($rule | ConvertTo-Json -Depth 6) | ConvertFrom-Json
        return @(InModuleScope Vacate -Parameters @{ R = $obj } { param($R) Test-VacateRule -Rule $R })
    }
}

Describe 'Rule cleanup validation' {
    It 'accepts a rule without cleanup' {
        $rule = InModuleScope Vacate { $script:VacateRuleOptionalKeys }
        $rule | Should -Contain 'cleanup'
    }

    It 'accepts a valid cleanup object' {
        Get-CleanupProblem (Get-TestCleanup) | Should -BeNullOrEmpty
    }

    It 'accepts action none with a reason and no steps' {
        Get-CleanupProblem (Get-TestCleanup @{ action = 'none'; steps = @(); exportFirst = $null; signOut = $null; reason = 'Hardware status only; nothing personal is stored.' }) | Should -BeNullOrEmpty
    }

    It 'rejects a missing field' {
        $c = Get-TestCleanup; $c.Remove('risk')
        (Get-CleanupProblem $c) -join ';' | Should -Match "missing field 'risk'"
    }

    It 'rejects an unknown field' {
        (Get-CleanupProblem (Get-TestCleanup @{ command = 'x' })) -join ';' | Should -Match "unknown field 'command'"
    }

    It 'rejects an unknown action' {
        (Get-CleanupProblem (Get-TestCleanup @{ action = 'nuke' })) -join ';' | Should -Match 'cleanup.action must be one of'
    }

    It 'requires a reason for action none' {
        (Get-CleanupProblem (Get-TestCleanup @{ action = 'none'; steps = @() })) -join ';' | Should -Match "reason is required"
    }

    It 'rejects steps for action none' {
        (Get-CleanupProblem (Get-TestCleanup @{ action = 'none'; reason = 'Nothing personal is stored here.' })) -join ';' | Should -Match 'steps must be empty'
    }

    It 'rejects a reason for other actions' {
        (Get-CleanupProblem (Get-TestCleanup @{ reason = 'Nothing personal is stored here.' })) -join ';' | Should -Match "reason is only for action 'none'"
    }

    It 'requires steps for a removing action' {
        (Get-CleanupProblem (Get-TestCleanup @{ action = 'remove'; steps = @() })) -join ';' | Should -Match 'steps needs 1-6 items'
    }

    It 'rejects more than 6 steps' {
        $s = @(1..7 | ForEach-Object { "Step number $_ of the cleanup." })
        (Get-CleanupProblem (Get-TestCleanup @{ steps = $s })) -join ';' | Should -Match 'more than 6'
    }

    It 'requires exportFirst for export-then-remove' {
        (Get-CleanupProblem (Get-TestCleanup @{ exportFirst = $null })) -join ';' | Should -Match 'exportFirst is required'
    }

    It 'requires signOut for sign-out-then-remove' {
        (Get-CleanupProblem (Get-TestCleanup @{ action = 'sign-out-then-remove'; signOut = $null })) -join ';' | Should -Match 'signOut is required'
    }

    It 'rejects resetCovers that is not a boolean' {
        (Get-CleanupProblem (Get-TestCleanup @{ resetCovers = 'yes' })) -join ';' | Should -Match 'resetCovers must be true or false'
    }

    It 'rejects non-ASCII text' {
        (Get-CleanupProblem (Get-TestCleanup @{ risk = "Removes everything $([char]0x2014) history." })) -join ';' | Should -Match 'printable ASCII'
    }

    It 'rejects shell delete command <Text>' -ForEach @(
        @{ Text = 'Run rm -rf on the profile folder.' }
        @{ Text = 'Use Remove-Item on the folder.' }
        @{ Text = 'Run reg delete on the key.' }
        @{ Text = 'Run sudo to remove the file.' }
        @{ Text = 'Run del /q on the folder contents.' }
        @{ Text = 'Run rmdir on the leftover folder.' }
        @{ Text = 'Wipe free space with cipher /w on the drive.' }
        @{ Text = 'Type the name in `quotes` here.' }
    ) {
        (Get-CleanupProblem (Get-TestCleanup @{ steps = @($Text) })) -join ';' | Should -Match 'shell command or backtick'
    }

    It 'every shipped rule has cleanup guidance (D45)' {
        $root = Join-Path $PSScriptRoot '../../src/Vacate/rules'
        $missing = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' | Where-Object {
                $null -eq (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).PSObject.Properties['cleanup']
            } | ForEach-Object { $_.Directory.Name + '/' + $_.Name })
        $missing -join ', ' | Should -Be ''
    }

    It 'allows plain words like remove and delete' {
        Get-CleanupProblem (Get-TestCleanup @{ steps = @('Delete the folder named in the plan.', 'Remove the account from Settings > Accounts.') }) | Should -BeNullOrEmpty
    }
}
