# DocExamples.Tests.ps1 - every command example in the user docs must actually work (P4d).
# PowerShell 5.1 compatible. ASCII only.
#
# What this checks: each line in a ```powershell / ```bash block of README.md, docs/GUIDE.md and
# docs/FAQ.md that calls vacate.ps1 must name a real command, use parameters that exist on
# vacate.ps1 with the right value type, and - when it is read-only - run with exit code 0 and
# write the files the docs promise.
#
# SAFETY. An example that can act is never run. Only these run, and only when the line has no
# -Execute and no <placeholder>: scan, rules list/show/validate, report, checklist, plan, clean
# (dry run), erase (readiness), undo (dry run), version, help. Everything else is parsed only.
# Invoke-TestDocRun refuses -Execute, -Confirm, -DiskSerial, -RecordTo and -WalletsBackedUp even if
# a future doc line tries it. The run happens in a copy of vacate.ps1 + src/ under $TestDrive, so
# runs/ and every generated file land there - never in the repo and never in the real home folder.
# Scan.Integration.Tests.ps1 / Clean.Integration.Tests.ps1 use the same idea (own temp folder,
# test seams); here the seam is the copied tool root, because the CLI has no -Run for scan output.
#
# Off Windows, an example that uses a Windows path (`.\runs\...`) is parse-only: the guide writes
# those in its Windows form, and a backslash is not a path separator on macOS or Linux.

Set-StrictMode -Version Latest

BeforeDiscovery {
    . (Join-Path $PSScriptRoot '../helpers/DocExample.ps1')
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:docRelativePath = @('README.md', 'docs/GUIDE.md', 'docs/FAQ.md')
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $script:docExamples = @(Get-TestDocCommandExample -Root $script:repoRoot -RelativePath $script:docRelativePath -WindowsPathAllowed $script:onWindows)
    $script:docRunExamples = @($script:docExamples | Where-Object { $_.CanRun })
}

Describe 'user doc command examples' {
    BeforeAll {
        $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $script:cli = Join-Path $script:repo 'vacate.ps1'
        $script:exe = (Get-Process -Id $PID).Path
        $script:docRelativePath = @('README.md', 'docs/GUIDE.md', 'docs/FAQ.md')
        $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
        # Pester 5 does not carry BeforeDiscovery variables into the run phase: read the docs again.
        . (Join-Path $PSScriptRoot '../helpers/DocExample.ps1')
        $script:docExamples = @(Get-TestDocCommandExample -Root $script:repo -RelativePath $script:docRelativePath -WindowsPathAllowed $script:onWindows)

        # The docs tell the reader to work inside the unzipped vacate folder. The sandbox is a
        # copy of it under $TestDrive, so `.\runs\...` resolves there and a scan writes there.
        $script:sandbox = Join-Path $TestDrive 'vacate'
        [void][IO.Directory]::CreateDirectory($script:sandbox)
        [IO.File]::Copy($script:cli, (Join-Path $script:sandbox 'vacate.ps1'))
        Copy-Item -Path (Join-Path $script:repo 'src') -Destination (Join-Path $script:sandbox 'src') -Recurse -Force
        $script:sandboxCli = Join-Path $script:sandbox 'vacate.ps1'

        # The commands vacate.ps1 really has, read from its own switch statement.
        function Get-TestVacateCommandName {
            [CmdletBinding()]
            [OutputType([string[]])]
            param([Parameter(Mandatory)][string]$Path)

            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
            $switches = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] -and ($node.Condition.Extent.Text -eq '$Command') }, $true))
            if ($switches.Count -eq 0) { throw 'vacate.ps1 has no switch on $Command' }
            $names = New-Object System.Collections.Generic.List[string]
            foreach ($clause in @($switches[0].Clauses)) {
                foreach ($match in [regex]::Matches($clause.Item1.Extent.Text, "'([A-Za-z]+)'")) {
                    $name = $match.Groups[1].Value
                    if (-not $names.Contains($name)) { $names.Add($name) }
                }
            }
            return $names.ToArray()
        }

        function Get-TestScriptParameter {
            # Parameter metadata of vacate.ps1, looked up the way PowerShell binds it (ignore case).
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Name)

            foreach ($key in @($script:scriptParameters.Keys)) {
                if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $script:scriptParameters[$key] }
            }
            return $null
        }

        function ConvertTo-TestDocArgText {
            # The argument as text for the child process. A value that is not a constant keeps its
            # source text so the message can quote it; the runner refuses to run it.
            [CmdletBinding()]
            [OutputType([string])]
            param([object]$Value, [Parameter(Mandatory)][object]$Element)

            if ($null -eq $Value) { return ([string]$Element.Extent.Text).Trim([char[]]@("'", '"')) }
            if ($Value -is [array]) { return (($Value | ForEach-Object { [string]$_ }) -join ',') }
            return [string]$Value
        }

        function Get-TestDocExampleParse {
            # Parses one documented command line: command name, parameters, value types.
            [CmdletBinding()]
            param([Parameter(Mandatory)][object]$Example)

            $problems = New-Object System.Collections.Generic.List[string]
            $where = ('{0}:{1}' -f $Example.File, $Example.Line)
            $result = [pscustomobject][ordered]@{
                Example    = $Example
                Command    = ''
                Args       = @()
                HasExecute = $false
                ScalarOnly = $true
                Problems   = @()
            }

            # Placeholders such as <serial from erase-readiness.md> are fine: they are masked to a
            # quoted constant so the line still parses, and never run.
            $masked = [regex]::Replace([string]$Example.Text, '<[^<>]*>', "'PLACEHOLDER'")
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($masked, [ref]$tokens, [ref]$parseErrors)
            foreach ($parseError in @($parseErrors)) {
                $problems.Add(('{0} does not parse: {1}' -f $where, $parseError.Message))
            }

            $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and ($node.Extent.Text -match 'vacate\.ps1') }, $true))
            if ($calls.Count -eq 0) {
                $problems.Add(('{0} names vacate.ps1 but is not a command' -f $where))
                $result.Problems = $problems.ToArray()
                return $result
            }

            $elements = @($calls[0].CommandElements)
            $start = -1
            for ($index = 0; $index -lt $elements.Count; $index++) {
                $elementText = ([string]$elements[$index].Extent.Text).Trim([char[]]@("'", '"'))
                if ($elementText -match 'vacate\.ps1$') { $start = $index; break }
            }

            $rest = @()
            if ($start -lt 0) {
                $problems.Add(('{0} does not call vacate.ps1 as a script' -f $where))
            }
            elseif ($start + 1 -lt $elements.Count) {
                $rest = @($elements[($start + 1)..($elements.Count - 1)])
            }
            if ($rest.Count -eq 0) {
                if ($start -ge 0) { $problems.Add(('{0} calls vacate.ps1 with no command' -f $where)) }
                $result.Problems = $problems.ToArray()
                return $result
            }

            $argList = New-Object System.Collections.Generic.List[string]
            $index = 0
            if ($rest[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $result.Command = [string]$rest[0].Value
                $argList.Add($result.Command)
                if (-not ($script:docCommandNames -contains $result.Command)) {
                    $problems.Add(('{0} calls ''{1}'', which is not a vacate command ({2})' -f $where, $result.Command, ($script:docCommandNames -join ', ')))
                }
                $index = 1
            }
            else {
                $problems.Add(('{0} does not name a vacate command' -f $where))
            }

            $subCommand = ''
            while ($index -lt $rest.Count) {
                $element = $rest[$index]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $parameterName = [string]$element.ParameterName
                    if ($parameterName -ieq 'Execute') { $result.HasExecute = $true }
                    $argList.Add('-' + $parameterName)
                    $parameter = Get-TestScriptParameter -Name $parameterName
                    if ($null -eq $parameter) {
                        $problems.Add(('{0} passes -{1}, which vacate.ps1 does not have' -f $where, $parameterName))
                        $index++
                        continue
                    }
                    if ($parameter.ParameterType -eq [System.Management.Automation.SwitchParameter]) {
                        if ($null -ne $element.Argument) {
                            $problems.Add(('{0} gives -{1} a value, but it is a switch' -f $where, $parameterName))
                        }
                        $index++
                        continue
                    }
                    $valueElement = $null
                    if ($null -ne $element.Argument) {
                        $valueElement = $element.Argument
                        $index++
                    }
                    elseif ($index + 1 -lt $rest.Count) {
                        $valueElement = $rest[$index + 1]
                        $index += 2
                    }
                    else {
                        $problems.Add(('{0} passes -{1} without a value' -f $where, $parameterName))
                        $index++
                        continue
                    }

                    $value = $null
                    try { $value = $valueElement.SafeGetValue() } catch { $value = $null }
                    $type = $parameter.ParameterType
                    if ($type -eq [int[]]) {
                        $numbers = @($value)
                        if ($null -eq $value) { $numbers = @() }
                        foreach ($number in $numbers) {
                            if (($number -isnot [int]) -and ($number -isnot [long])) {
                                $problems.Add(('{0} passes ''{1}'' to -{2}, which needs whole numbers (int[])' -f $where, $valueElement.Extent.Text, $parameterName))
                            }
                        }
                    }
                    elseif ($type -eq [int]) {
                        if (($null -ne $value) -and ($value -isnot [int]) -and ($value -isnot [long])) {
                            $problems.Add(('{0} passes ''{1}'' to -{2}, which needs a whole number (int)' -f $where, $valueElement.Extent.Text, $parameterName))
                        }
                    }
                    elseif ($type -eq [string]) {
                        if ($value -is [array]) {
                            $problems.Add(('{0} passes a list to -{1}, which takes one value' -f $where, $parameterName))
                        }
                    }
                    foreach ($attribute in @($parameter.Attributes)) {
                        if (($attribute -is [System.Management.Automation.ValidateSetAttribute]) -and ($value -is [string])) {
                            if (-not (@($attribute.ValidValues) -contains $value)) {
                                $problems.Add(('{0} passes ''{1}'' to -{2}, which accepts {3}' -f $where, $value, $parameterName, (@($attribute.ValidValues) -join ', ')))
                            }
                        }
                        if (($attribute -is [System.Management.Automation.ValidateRangeAttribute]) -and (($value -is [int]) -or ($value -is [long]))) {
                            if (($value -lt $attribute.MinRange) -or ($value -gt $attribute.MaxRange)) {
                                $problems.Add(('{0} passes {1} to -{2}, which accepts {3}..{4}' -f $where, $value, $parameterName, $attribute.MinRange, $attribute.MaxRange))
                            }
                        }
                    }
                    if ($value -is [array]) { $result.ScalarOnly = $false }
                    $argList.Add((ConvertTo-TestDocArgText -Value $value -Element $valueElement))
                    continue
                }

                $positional = $null
                try { $positional = $element.SafeGetValue() } catch { $positional = $null }
                if ($positional -is [array]) { $result.ScalarOnly = $false }
                if (($result.Command -ceq 'rules') -and ($subCommand -eq '')) {
                    $subCommand = [string]$positional
                    if (@('list', 'show', 'validate') -notcontains $subCommand) {
                        $problems.Add(('{0} runs ''rules {1}'', but rules has only list, show and validate' -f $where, $subCommand))
                    }
                }
                $argList.Add((ConvertTo-TestDocArgText -Value $positional -Element $element))
                $index++
            }

            $result.Args = $argList.ToArray()
            $result.Problems = $problems.ToArray()
            return $result
        }

        function Test-TestDocExampleSafe {
            # Last line of defence before a child process starts.
            [CmdletBinding()]
            param([Parameter(Mandatory)][object]$Parsed)

            if ($Parsed.HasExecute) { throw ('refusing to run ' + $Parsed.Example.File + ':' + $Parsed.Example.Line + ': the example names -Execute') }
            if (-not $script:readonlyDocCommand.Contains($Parsed.Command)) { throw ('refusing to run doc command ' + $Parsed.Command + ': not on the read-only list') }
            if (-not $Parsed.ScalarOnly) { throw ('refusing to run ' + $Parsed.Command + ': an argument is not a single value') }
            foreach ($argument in @($Parsed.Args)) {
                if ($argument -match '^-(Execute|Confirm|DiskSerial|RecordTo|WalletsBackedUp)$') {
                    throw ('refusing to run ' + $Parsed.Command + ': ' + $argument + ' acts on the machine')
                }
            }
        }

        function Invoke-TestDocRun {
            # Runs one documented example as a child process, from the sandbox folder. The same
            # argument list is run once and reused, so four "scan" examples cost one scan.
            [CmdletBinding()]
            param([Parameter(Mandatory)][object]$Parsed)

            Test-TestDocExampleSafe -Parsed $Parsed
            $key = ($Parsed.Args -join ' ').ToLowerInvariant()
            if ($script:runCache.ContainsKey($key)) { return $script:runCache[$key] }
            $text = @()
            $code = -1
            Push-Location -LiteralPath $script:sandbox
            try {
                $text = @(& $script:exe -NoProfile -ExecutionPolicy Bypass -File $script:sandboxCli @($Parsed.Args) 2>&1)
                $code = $LASTEXITCODE
            }
            finally {
                Pop-Location
            }
            $result = [pscustomobject][ordered]@{
                Code = [int]$code
                Text = (@($text) -join "`n")
                Args = $Parsed.Args
            }
            $script:runCache[$key] = $result
            return $result
        }

        function Get-TestDocRunDir {
            # The run folder the example worked on: printed by scan, or named by -Run.
            [CmdletBinding()]
            param([Parameter(Mandatory)][object]$Parsed, [Parameter(Mandatory)][object]$Result)

            if ($Parsed.Command -ceq 'scan') {
                $match = [regex]::Match([string]$Result.Text, 'Report:\s*(.+?report\.html)')
                if (-not $match.Success) { return $null }
                return ([IO.Path]::GetDirectoryName($match.Groups[1].Value.Trim()))
            }
            $run = $null
            for ($index = 0; $index -lt $Parsed.Args.Count; $index++) {
                if (($Parsed.Args[$index] -ieq '-Run') -and ($index + 1 -lt $Parsed.Args.Count)) { $run = $Parsed.Args[$index + 1] }
            }
            if ([string]::IsNullOrEmpty($run)) { return $null }
            if ([IO.Path]::IsPathRooted($run)) { return $run }
            return [IO.Path]::GetFullPath((Join-Path $script:sandbox $run))
        }

        function Get-TestDocPromisedFile {
            # Files the docs say each command writes (README "Output files" and the guide).
            [CmdletBinding()]
            [OutputType([string[]])]
            param([Parameter(Mandatory)][string]$Command)

            $byCommand = @{
                'scan'      = @('report.html', 'report.json', 'summary.md', 'checklist.md', 'scan.log')
                'report'    = @('report.html', 'summary.md', 'checklist.md')
                'checklist' = @('checklist.md')
                'plan'      = @('plan.json', 'plan.md', 'plan.html')
                'clean'     = @('clean-preview.md')
                'erase'     = @('erase-readiness.md')
                'undo'      = @('undo-preview.md')
            }
            if ($byCommand.ContainsKey($Command)) { return $byCommand[$Command] }
            return @()
        }

        $script:runCache = @{}
        $script:scriptParameters = (Get-Command -Name $script:sandboxCli -ErrorAction Stop).Parameters
        $script:docCommandNames = Get-TestVacateCommandName -Path $script:sandboxCli
        $script:readonlyDocCommand = @('version', 'help', 'scan', 'rules', 'report', 'checklist', 'plan', 'clean', 'undo', 'erase')

        # One plain scan also feeds the plan/clean/erase examples: they name this run folder.
        $script:docRunName = '20261120-101500'
        $script:docRun = Join-Path $script:sandbox ('runs/' + $script:docRunName)
        $scanExample = @($script:docExamples | Where-Object { ($_.Command -ceq 'scan') -and ($_.Text -notmatch '-Redact') -and $_.CanRun })
        if ($scanExample.Count -eq 0) { throw 'no plain scan example in the docs to build the run folder from' }
        $scanParsed = Get-TestDocExampleParse -Example $scanExample[0]
        Test-TestDocExampleSafe -Parsed $scanParsed
        $script:scanResult = Invoke-TestDocRun -Parsed $scanParsed
        if ($script:scanResult.Code -ne 0) { throw ('the plain scan example failed: ' + $script:scanResult.Text) }
        $scanRunDir = Get-TestDocRunDir -Parsed $scanParsed -Result $script:scanResult
        if ([string]::IsNullOrEmpty($scanRunDir) -or -not [IO.Directory]::Exists($scanRunDir)) { throw ('the plain scan example wrote no run folder: ' + $script:scanResult.Text) }
        [void][IO.Directory]::CreateDirectory($script:docRun)
        foreach ($file in @(Get-ChildItem -LiteralPath $scanRunDir -File)) {
            [IO.File]::Copy($file.FullName, (Join-Path $script:docRun $file.Name))
        }
        $planExample = @($script:docExamples | Where-Object { ($_.Command -ceq 'plan') -and $_.CanRun })
        if ($planExample.Count -gt 0) {
            $script:planResult = Invoke-TestDocRun -Parsed (Get-TestDocExampleParse -Example $planExample[0])
            if ($script:planResult.Code -ne 0) { throw ('the plan example failed: ' + $script:planResult.Text) }
        }
    }

    Context 'what the docs contain' {
        It 'finds command examples in README.md and docs/GUIDE.md' {
            $script:docExamples.Count | Should -BeGreaterThan 10
            @($script:docExamples | Where-Object { $_.File -ceq 'README.md' }).Count | Should -BeGreaterThan 0
            @($script:docExamples | Where-Object { $_.File -ceq 'docs/GUIDE.md' }).Count | Should -BeGreaterThan 0
        }

        It 'knows the vacate commands from vacate.ps1 itself' {
            foreach ($name in @('version', 'scan', 'rules', 'report', 'checklist', 'plan', 'clean', 'undo', 'erase', 'help')) {
                $script:docCommandNames -contains $name | Should -BeTrue -Because ('vacate.ps1 must still have the ' + $name + ' command')
            }
        }

        It 'reads the parameter list of vacate.ps1' {
            @($script:scriptParameters.Keys) -contains 'Run' | Should -BeTrue
            @($script:scriptParameters.Keys) -contains 'Steps' | Should -BeTrue
            $script:scriptParameters['Steps'].ParameterType | Should -Be ([int[]])
        }

        It 'states the readiness check counts the code really has' {
            # README sells `erase -Run <dir>` with these two numbers; they drifted once already.
            $source = [IO.File]::ReadAllText((Join-Path $script:repo 'src/Vacate/Private/EraseReadiness.ps1'))
            $checks = ([regex]::Matches($source, 'New-VacateEraseCheck -Id')).Count
            $blocking = ([regex]::Matches($source, "-Severity 'block'")).Count
            $readme = [IO.File]::ReadAllText((Join-Path $script:repo 'README.md'))
            $claim = [regex]::Match($readme, 'all (\d+) readiness checks \((\d+) can block')
            $claim.Success | Should -BeTrue -Because 'README describes the erase readiness report'
            [int]$claim.Groups[1].Value | Should -Be $checks -Because 'README says how many checks the erase readiness report lists'
            [int]$claim.Groups[2].Value | Should -Be $blocking -Because 'README says how many of them can block an erase'
        }
    }

    Context 'parsing every documented command line' {
        It 'parses <File> line <Line>' -ForEach $script:docExamples {
            $parsed = Get-TestDocExampleParse -Example $_
            @($parsed.Problems) | Should -BeNullOrEmpty -Because (@($parsed.Problems) -join '; ')
            $parsed.Command | Should -Be $_.Command
        }
    }

    Context 'running the read-only examples' {
        It 'runs <File> line <Line>' -ForEach $script:docRunExamples {
            $parsed = Get-TestDocExampleParse -Example $_
            @($parsed.Problems) | Should -BeNullOrEmpty -Because (@($parsed.Problems) -join '; ')
            $parsed.HasExecute | Should -BeFalse -Because 'a documented -Execute line is parsed, never run'
            $result = Invoke-TestDocRun -Parsed $parsed
            $result.Code | Should -Be 0 -Because (('vacate.ps1 ' + ($parsed.Args -join ' ') + ' must work as documented. Output: ' + $result.Text))
            $runDir = Get-TestDocRunDir -Parsed $parsed -Result $result
            foreach ($name in @(Get-TestDocPromisedFile -Command $parsed.Command)) {
                [IO.File]::Exists((Join-Path $runDir $name)) | Should -BeTrue -Because (($parsed.Command + ' must write ' + $name + ' into the run folder'))
            }
        }

        It 'never runs a documented line that names -Execute' {
            foreach ($example in @($script:docExamples | Where-Object { $_.Text -match '-Execute' })) {
                $example.CanRun | Should -BeFalse -Because ('the docs still document a machine-changing command in ' + $example.File + ':' + $example.Line)
                $parsed = Get-TestDocExampleParse -Example $example
                $parsed.HasExecute | Should -BeTrue
                { Test-TestDocExampleSafe -Parsed $parsed } | Should -Throw
            }
        }

        It 'keeps every run folder inside the test sandbox' {
            $resolvedSandbox = [IO.Path]::GetFullPath($script:sandbox)
            $resolvedRun = [IO.Path]::GetFullPath($script:docRun)
            $resolvedRun.StartsWith($resolvedSandbox, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            [IO.Directory]::Exists($script:docRun) | Should -BeTrue
            [IO.File]::Exists((Join-Path $script:docRun 'plan.json')) | Should -BeTrue -Because 'the plan example runs before clean and erase need it'
        }
    }
}
