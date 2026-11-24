# ConsoleGate.Tests.ps1 - the last human checks before an erase (D55, Phase 4 threat model).
# Every console fact combination, and every answer people actually type.
# PowerShell 5.1 compatible. ASCII only.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

Describe 'Test-VacateInteractiveConsole' {
    BeforeAll {
        $script:m = Get-Module Vacate

        # The module functions are private; call them the way vacate.ps1 does.
        function Invoke-Gate {
            param([bool]$In, [bool]$Out, [bool]$User)
            & $script:m { param($a, $b, $c) Test-VacateInteractiveConsole -InputRedirected $a -OutputRedirected $b -UserInteractive $c } $In $Out $User
        }
    }

    It 'is ok only without redirected streams in an interactive session (<In>/<Out>/<User>)' -ForEach @(
        @{ In = $false; Out = $false; User = $true; Ok = $true; Reason = 'interactive console' },
        @{ In = $false; Out = $false; User = $false; Ok = $false; Reason = 'the session is not interactive' },
        @{ In = $false; Out = $true; User = $true; Ok = $false; Reason = 'output is redirected' },
        @{ In = $false; Out = $true; User = $false; Ok = $false; Reason = 'output is redirected' },
        @{ In = $true; Out = $false; User = $true; Ok = $false; Reason = 'input is redirected' },
        @{ In = $true; Out = $false; User = $false; Ok = $false; Reason = 'input is redirected' },
        @{ In = $true; Out = $true; User = $true; Ok = $false; Reason = 'input is redirected' },
        @{ In = $true; Out = $true; User = $false; Ok = $false; Reason = 'input is redirected' }
    ) {
        $g = Invoke-Gate -In $In -Out $Out -User $User
        $g.ok | Should -Be $Ok
        $g.reason | Should -BeExactly $Reason
    }

    It 'returns exactly the two fields vacate.ps1 reads' {
        $g = Invoke-Gate -In $false -Out $false -User $true
        @($g.PSObject.Properties.Name) | Should -Be @('ok', 'reason')
        $g.ok | Should -BeOfType [bool]
        $g.reason | Should -BeOfType [string]
    }

    It 'reads the real console when no fact is passed' {
        $g = & $script:m { Test-VacateInteractiveConsole }
        $expected = ((-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) -and [Environment]::UserInteractive)
        $g.ok | Should -Be ([bool]$expected)
        $g.ok | Should -BeOfType [bool]
        $g.reason.Length | Should -BeGreaterThan 0
    }
}

Describe 'Read-VacateTypedConfirm' {
    BeforeAll {
        $script:m = Get-Module Vacate

        function Invoke-TypedConfirm {
            param([scriptblock]$Reader)
            & $script:m { param($r) Read-VacateTypedConfirm -Reader $r } $Reader
        }
        function Get-FixedReader {
            param($Answer)
            return { param($Prompt) $Answer }.GetNewClosure()
        }
    }

    It 'accepts the answer <Answer> as <Expected>' -ForEach @(
        @{ Answer = 'YES'; Expected = $true },
        @{ Answer = 'yes'; Expected = $false },
        @{ Answer = 'Yes'; Expected = $false },
        @{ Answer = ' YES'; Expected = $false },
        @{ Answer = 'YES '; Expected = $false },
        @{ Answer = 'Y'; Expected = $false },
        @{ Answer = ''; Expected = $false },
        @{ Answer = $null; Expected = $false },
        @{ Answer = 'YES!'; Expected = $false }
    ) {
        $reader = Get-FixedReader -Answer $Answer
        Invoke-TypedConfirm -Reader $reader | Should -Be $Expected
    }

    It 'agrees with the -TypedConfirmation gate in Invoke-VacateErase on all of them' {
        # The gate refuses with '-cne YES'; the prompt must return $true for exactly that set,
        # so the CLI can never hand the module an answer it would accept but the person did not type.
        foreach ($answer in @('YES', 'yes', 'Yes', ' YES', 'YES ', 'Y', '', $null, 'YES!')) {
            $reader = Get-FixedReader -Answer $answer
            $accepted = Invoke-TypedConfirm -Reader $reader
            $accepted | Should -Be ([string]$answer -ceq 'YES') -Because ("answer: '" + [string]$answer + "'")
        }
    }

    It 'passes the prompt text to the reader' {
        $script:seenPrompt = ''
        $reader = { param($Prompt) $script:seenPrompt = $Prompt; 'no' }
        Invoke-TypedConfirm -Reader $reader | Should -Be $false
        $script:seenPrompt | Should -BeExactly 'Type YES to continue'
    }

    It 'returns a bool, never the raw answer' {
        $reader = Get-FixedReader -Answer 'YES'
        $result = Invoke-TypedConfirm -Reader $reader
        $result | Should -BeOfType [bool]
        $result | Should -BeTrue
    }

    It 'would ask the console when no reader is given' {
        # Read-Host cannot be driven in the suite, so prove the default is a console read by
        # checking the function body still reads the console; every other case uses -Reader.
        $body = (& $script:m { (Get-Command Read-VacateTypedConfirm).Definition })
        $body | Should -Match 'Read-Host'
    }
}
