# Static safety tests: scan the module source as text for the calls the SPEC forbids
# (network, dynamic code, process launches, unlisted binaries, writes, $env:, non-ASCII).
# Comments are stripped before matching so documentation may name a forbidden call, but
# string literals are kept because a URL or a binary path in a string is still a real use.
# The self-tests at the bottom prove the scanner detects what it claims to detect.

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

    # file:pattern pairs that are allowed. Keep this list short and explain every entry.
    $script:allowedFilePatterns = @(
        # The only code allowed to start a process: three fixed binaries, no shell.
        'src/Vacate/Private/SystemQueries.ps1:System.Diagnostics.Process',
        'src/Vacate/Private/SystemQueries.ps1:ProcessStartInfo',
        # The one future output writer. Nothing else may write outside runs/<timestamp>/.
        'src/Vacate/Private/Output.ps1:WriteAllText',
        'src/Vacate/Private/Output.ps1:CreateDirectory',
        # Phase 3 (D50): the three Trash movers are the only code allowed to move user files,
        # and only into the Recycle Bin or Trash. A mover never deletes permanently.
        'src/Vacate/Private/TrashWindows.ps1:File/Directory mutation',
        # Loads the framework's Microsoft.VisualBasic assembly by name for its Recycle Bin call;
        # -TypeDefinition (compiling code) stays forbidden and is checked by review.
        'src/Vacate/Private/TrashWindows.ps1:Add-Type',
        # Microsoft.VisualBasic FileSystem.DeleteFile/DeleteDirectory, ONLY with
        # RecycleOption.SendToRecycleBin (review checks this; DeletePermanently stays forbidden).
        'src/Vacate/Private/TrashWindows.ps1:DeleteFile',
        'src/Vacate/Private/TrashWindows.ps1:DeleteDirectory',
        'src/Vacate/Private/TrashWindows.ps1:.MoveTo(',
        'src/Vacate/Private/TrashLinux.ps1:.MoveTo(',
        'src/Vacate/Private/TrashMacOS.ps1:.MoveTo(',
        'src/Vacate/Private/TrashLinux.ps1:File/Directory mutation',
        # The freedesktop Trash spec needs files/ and info/ folders and a .trashinfo file per item;
        # .Delete( only removes vacate's own .trashinfo when a move fails or after a restore.
        'src/Vacate/Private/TrashLinux.ps1:CreateDirectory',
        'src/Vacate/Private/TrashLinux.ps1:WriteAllText',
        'src/Vacate/Private/TrashLinux.ps1:.Delete(',
        'src/Vacate/Private/TrashMacOS.ps1:File/Directory mutation',
        'src/Vacate/Private/TrashMacOS.ps1:CreateDirectory'
    )

    # The only absolute binaries the tool may read. Paths are compared case-sensitively.
    $script:allowedBinaryPaths = @('/usr/bin/fdesetup', '/usr/bin/lsblk', '/usr/bin/findmnt')

    # Not binaries: the Linux APPLICATIONS root token is a directory of .desktop files.
    $script:allowedNonBinaryPaths = @('/usr/share/applications')

    # The only file allowed to read the process environment.
    $script:envAllowedFile = 'src/Vacate/Private/Platform.ps1'

    $script:staticSafetyRules = @(
        [pscustomobject]@{ Kind = 'network'; Name = 'Invoke-WebRequest'; Regex = 'Invoke-WebRequest' },
        [pscustomobject]@{ Kind = 'network'; Name = 'Invoke-RestMethod'; Regex = 'Invoke-RestMethod' },
        [pscustomobject]@{ Kind = 'network'; Name = 'iwr'; Regex = '(?<![\w$])iwr\s' },
        [pscustomobject]@{ Kind = 'network'; Name = 'irm'; Regex = '(?<![\w$])irm\s' },
        [pscustomobject]@{ Kind = 'network'; Name = 'curl'; Regex = '(?<![\w$])curl\s' },
        [pscustomobject]@{ Kind = 'network'; Name = 'wget'; Regex = '(?<![\w$])wget\s' },
        [pscustomobject]@{ Kind = 'network'; Name = 'Net.WebClient'; Regex = 'Net\.WebClient' },
        [pscustomobject]@{ Kind = 'network'; Name = 'Net.Http'; Regex = 'Net\.Http' },
        [pscustomobject]@{ Kind = 'network'; Name = 'HttpClient'; Regex = 'HttpClient' },
        [pscustomobject]@{ Kind = 'network'; Name = 'Net.Sockets'; Regex = 'Net\.Sockets' },
        [pscustomobject]@{ Kind = 'network'; Name = 'TcpClient'; Regex = 'TcpClient' },
        [pscustomobject]@{ Kind = 'network'; Name = 'Net.Dns'; Regex = 'Net\.Dns' },
        [pscustomobject]@{ Kind = 'network'; Name = 'Start-BitsTransfer'; Regex = 'Start-BitsTransfer' },
        [pscustomobject]@{ Kind = 'dynamic'; Name = 'Invoke-Expression'; Regex = 'Invoke-Expression' },
        [pscustomobject]@{ Kind = 'dynamic'; Name = 'iex'; Regex = '(?<![\w$])iex\s' },
        [pscustomobject]@{ Kind = 'dynamic'; Name = 'Add-Type'; Regex = 'Add-Type' },
        [pscustomobject]@{ Kind = 'dynamic'; Name = '[scriptblock]::Create'; Regex = '\[scriptblock\]::Create' },
        [pscustomobject]@{ Kind = 'dynamic'; Name = 'NewScriptBlock'; Regex = 'NewScriptBlock' },
        [pscustomobject]@{ Kind = 'process'; Name = 'Start-Process'; Regex = 'Start-Process' },
        [pscustomobject]@{ Kind = 'process'; Name = 'cmd /c'; Regex = '\bcmd\s+/c' },
        [pscustomobject]@{ Kind = 'process'; Name = 'cmd.exe'; Regex = '\bcmd\.exe' },
        [pscustomobject]@{ Kind = 'process'; Name = 'bash -c'; Regex = '\bbash\s+-c' },
        [pscustomobject]@{ Kind = 'process'; Name = 'sh -c'; Regex = '\bsh\s+-c' },
        [pscustomobject]@{ Kind = 'process'; Name = 'sudo'; Regex = '\bsudo\b' },
        [pscustomobject]@{ Kind = 'process'; Name = 'runas'; Regex = '\brunas\b' },
        [pscustomobject]@{ Kind = 'process'; Name = 'UseShellExecute = $true'; Regex = 'UseShellExecute\s*=\s*\$true' },
        [pscustomobject]@{ Kind = 'process'; Name = 'System.Diagnostics.Process'; Regex = 'System\.Diagnostics\.Process' },
        [pscustomobject]@{ Kind = 'process'; Name = 'ProcessStartInfo'; Regex = '\bProcessStartInfo\b' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Remove-Item'; Regex = 'Remove-Item' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Set-Content'; Regex = 'Set-Content' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Add-Content'; Regex = 'Add-Content' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Out-File'; Regex = 'Out-File' },
        [pscustomobject]@{ Kind = 'write'; Name = 'New-Item'; Regex = 'New-Item' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Move-Item'; Regex = 'Move-Item' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Copy-Item'; Regex = 'Copy-Item' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Rename-Item'; Regex = 'Rename-Item' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Clear-Content'; Regex = 'Clear-Content' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Set-ItemProperty'; Regex = 'Set-ItemProperty' },
        [pscustomobject]@{ Kind = 'write'; Name = 'New-ItemProperty'; Regex = 'New-ItemProperty' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Remove-ItemProperty'; Regex = 'Remove-ItemProperty' },
        [pscustomobject]@{ Kind = 'write'; Name = '.Delete('; Regex = '\.Delete\s*\(' },
        [pscustomobject]@{ Kind = 'write'; Name = 'WriteAllText'; Regex = 'WriteAllText' },
        [pscustomobject]@{ Kind = 'write'; Name = 'WriteAllBytes'; Regex = 'WriteAllBytes' },
        [pscustomobject]@{ Kind = 'write'; Name = 'CreateSubKey'; Regex = 'CreateSubKey' },
        [pscustomobject]@{ Kind = 'write'; Name = 'SetValue('; Regex = 'SetValue\s*\(' },
        [pscustomobject]@{ Kind = 'write'; Name = 'DeleteSubKey'; Regex = 'DeleteSubKey' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Set-CimInstance'; Regex = 'Set-CimInstance' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Invoke-CimMethod'; Regex = 'Invoke-CimMethod' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Remove-CimInstance'; Regex = 'Remove-CimInstance' },
        [pscustomobject]@{ Kind = 'write'; Name = 'New-CimInstance'; Regex = 'New-CimInstance' },
        # Added by Claude on review: other .NET ways to create, change or remove files.
        [pscustomobject]@{ Kind = 'write'; Name = 'CreateDirectory'; Regex = 'CreateDirectory' },
        [pscustomobject]@{ Kind = 'write'; Name = 'AppendAll'; Regex = 'AppendAll(Text|Lines)' },
        [pscustomobject]@{ Kind = 'write'; Name = 'WriteAllLines'; Regex = 'WriteAllLines' },
        [pscustomobject]@{ Kind = 'write'; Name = 'File/Directory mutation'; Regex = '\[(System\.)?IO\.(File|Directory)\]::(Create|Move|Copy|Replace|Delete|SetAttributes|SetLastWriteTime\w*|SetCreationTime\w*|SetAccessControl)\b' },
        [pscustomobject]@{ Kind = 'write'; Name = 'StreamWriter'; Regex = 'StreamWriter' },
        [pscustomobject]@{ Kind = 'write'; Name = 'FileStream'; Regex = 'FileStream' },
        [pscustomobject]@{ Kind = 'write'; Name = 'OpenWrite'; Regex = 'OpenWrite' },
        [pscustomobject]@{ Kind = 'write'; Name = 'Set-Acl'; Regex = 'Set-Acl' },
        # Added for Phase 3 (threat model): other ways to move or delete files, and COM objects.
        [pscustomobject]@{ Kind = 'write'; Name = '.MoveTo('; Regex = '\.MoveTo\s*\(' },
        [pscustomobject]@{ Kind = 'write'; Name = 'DeleteFile'; Regex = '\bDeleteFile\b' },
        [pscustomobject]@{ Kind = 'write'; Name = 'DeleteDirectory'; Regex = '\bDeleteDirectory\b' },
        [pscustomobject]@{ Kind = 'write'; Name = 'DeletePermanently'; Regex = 'DeletePermanently' },
        [pscustomobject]@{ Kind = 'dynamic'; Name = '-ComObject'; Regex = '-ComObject' }
    )

    function ConvertTo-StaticSafetyCode {
        # Returns the text with comments replaced by spaces and newlines kept, so line
        # numbers still match the file. Strings and here-strings are copied verbatim.
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

        $chars = $Text.ToCharArray()
        $result = [char[]]::new($chars.Length)
        $state = 'code'
        $i = 0
        while ($i -lt $chars.Length) {
            $c = $chars[$i]
            $next = [char]0
            if (($i + 1) -lt $chars.Length) { $next = $chars[$i + 1] }

            if ($state -eq 'code') {
                if ($c -eq [char]'<' -and $next -eq [char]'#') {
                    $result[$i] = [char]' '
                    $result[$i + 1] = [char]' '
                    $i += 2
                    $state = 'block'
                    continue
                }
                if ($c -eq [char]'#') {
                    $result[$i] = [char]' '
                    $i++
                    $state = 'line'
                    continue
                }
                if ($c -eq [char]'@' -and ($next -eq [char]"'" -or $next -eq [char]'"')) {
                    $result[$i] = $c
                    $result[$i + 1] = $next
                    $i += 2
                    if ($next -eq [char]"'") { $state = 'here-single' }
                    else { $state = 'here-double' }
                    continue
                }
                if ($c -eq [char]"'") {
                    $state = 'single'
                    $result[$i] = $c
                    $i++
                    continue
                }
                if ($c -eq [char]'"') {
                    $state = 'double'
                    $result[$i] = $c
                    $i++
                    continue
                }
                $result[$i] = $c
                $i++
                continue
            }

            if ($state -eq 'line') {
                if ($c -eq [char]10 -or $c -eq [char]13) {
                    $result[$i] = $c
                    $state = 'code'
                }
                else {
                    $result[$i] = [char]' '
                }
                $i++
                continue
            }

            if ($state -eq 'block') {
                if ($c -eq [char]'#' -and $next -eq [char]'>') {
                    $result[$i] = [char]' '
                    $result[$i + 1] = [char]' '
                    $i += 2
                    $state = 'code'
                    continue
                }
                if ($c -eq [char]10 -or $c -eq [char]13) { $result[$i] = $c }
                else { $result[$i] = [char]' ' }
                $i++
                continue
            }

            # String states: copy every character as written.
            $result[$i] = $c
            if ($state -eq 'single') {
                if ($c -eq [char]"'" -and $next -eq [char]"'") {
                    $result[$i + 1] = $next
                    $i += 2
                    continue
                }
                if ($c -eq [char]"'") { $state = 'code' }
                $i++
                continue
            }
            if ($state -eq 'double') {
                if ($c -eq [char]0x60 -and (($i + 1) -lt $chars.Length)) {
                    $result[$i + 1] = $next
                    $i += 2
                    continue
                }
                if ($c -eq [char]'"' -and $next -eq [char]'"') {
                    $result[$i + 1] = $next
                    $i += 2
                    continue
                }
                if ($c -eq [char]'"') { $state = 'code' }
                $i++
                continue
            }
            if ($state -eq 'here-single' -or $state -eq 'here-double') {
                $atLineStart = ($i -eq 0 -or $chars[$i - 1] -eq [char]10 -or $chars[$i - 1] -eq [char]13)
                if ($atLineStart -and $next -eq [char]'@') {
                    if ($state -eq 'here-single' -and $c -eq [char]"'") {
                        $result[$i + 1] = $next
                        $i += 2
                        $state = 'code'
                        continue
                    }
                    if ($state -eq 'here-double' -and $c -eq [char]'"') {
                        $result[$i + 1] = $next
                        $i += 2
                        $state = 'code'
                        continue
                    }
                }
                $i++
                continue
            }
        }
        return (-join $result)
    }

    function Test-StaticSafetyAllowed {
        # True when this exact file:pattern pair is on the allow-list.
        param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Pattern)

        foreach ($entry in $script:allowedFilePatterns) {
            $separator = $entry.IndexOf(':')
            if ($separator -lt 1) { continue }
            $allowedFile = $entry.Substring(0, $separator)
            $allowedPattern = $entry.Substring($separator + 1)
            if ($File -eq $allowedFile -and $Pattern -eq $allowedPattern) { return $true }
        }
        return $false
    }

    function Get-StaticSafetyNonAsciiHit {
        # One hit per line that contains a character outside ASCII.
        param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)

        $hits = New-Object System.Collections.ArrayList
        $lines = [regex]::Split($Text, '\r\n|\n|\r')
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $match = [regex]::Match($lines[$index], '[^\x00-\x7F]')
            if (-not $match.Success) { continue }
            $codePoint = [int]$match.Value[0]
            [void]$hits.Add([pscustomobject][ordered]@{
                    File    = $File
                    Line    = $index + 1
                    Kind    = 'non-ascii'
                    Pattern = ('non-ASCII U+{0:X4}' -f $codePoint)
                })
        }
        return $hits.ToArray()
    }

    function Get-StaticSafetyHit {
        # Runs every rule over the text and returns file:line pattern hits.
        param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)

        $hits = New-Object System.Collections.ArrayList
        $code = ConvertTo-StaticSafetyCode -Text $Text
        $lines = [regex]::Split($code, '\r\n|\n|\r')
        $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

        for ($index = 0; $index -lt $lines.Length; $index++) {
            $lineNumber = $index + 1
            $line = $lines[$index]
            # WebUtility only encodes HTML; it is not a network client.
            $networkLine = [regex]::Replace($line, 'System\.Net\.WebUtility', '', $ignoreCase)

            foreach ($rule in $script:staticSafetyRules) {
                $subject = $line
                if ($rule.Kind -eq 'network') { $subject = $networkLine }
                if (-not [regex]::IsMatch($subject, $rule.Regex, $ignoreCase)) { continue }
                if (Test-StaticSafetyAllowed -File $File -Pattern $rule.Name) { continue }
                [void]$hits.Add([pscustomobject][ordered]@{
                        File    = $File
                        Line    = $lineNumber
                        Kind    = $rule.Kind
                        Pattern = $rule.Name
                    })
            }

            if ($File -ne $script:envAllowedFile -and [regex]::IsMatch($line, '\$env:', $ignoreCase)) {
                [void]$hits.Add([pscustomobject][ordered]@{
                        File    = $File
                        Line    = $lineNumber
                        Kind    = 'env'
                        Pattern = '$env:'
                    })
            }

            $binaryPattern = '/(?:usr|bin|sbin)/[A-Za-z0-9._+/-]+|[^\s''"]+\.exe\b'
            foreach ($match in [regex]::Matches($line, $binaryPattern, $ignoreCase)) {
                $candidate = $match.Value.TrimEnd([char[]]@('.', ',', ')', ']', '}', ';'))
                if ($candidate.Length -eq 0) { continue }
                if ($script:allowedBinaryPaths -ccontains $candidate) { continue }
                if ($script:allowedNonBinaryPaths -ccontains $candidate) { continue }
                [void]$hits.Add([pscustomobject][ordered]@{
                        File    = $File
                        Line    = $lineNumber
                        Kind    = 'binary'
                        Pattern = $candidate
                    })
            }
        }

        foreach ($hit in (Get-StaticSafetyNonAsciiHit -File $File -Text $Text)) { [void]$hits.Add($hit) }
        return $hits.ToArray()
    }

    function Get-StaticSafetySourceFile {
        # Every .ps1/.psm1 under src plus the CLI entry point. Tests are not scanned.
        $files = New-Object System.Collections.ArrayList
        $sourceRoot = Join-Path $script:repoRoot 'src'
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })) {
            [void]$files.Add($file.FullName)
        }
        $cli = Join-Path $script:repoRoot 'vacate.ps1'
        if (Test-Path -LiteralPath $cli -PathType Leaf) { [void]$files.Add($cli) }
        $result = $files.ToArray()
        [Array]::Sort($result, [StringComparer]::Ordinal)
        return $result
    }

    function Get-StaticSafetyRuleFile {
        # Every rule JSON. Non-ASCII is the only text rule that applies to data files.
        $ruleRoot = Join-Path $script:repoRoot 'src/Vacate/rules'
        $files = @(Get-ChildItem -LiteralPath $ruleRoot -Recurse -File -Filter '*.json' | ForEach-Object { $_.FullName })
        [Array]::Sort($files, [StringComparer]::Ordinal)
        return $files
    }

    function Get-StaticSafetyRelativePath {
        param([Parameter(Mandatory)][string]$FullName)
        $prefix = $script:repoRoot.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
        if ($FullName.StartsWith($prefix, [StringComparison]::Ordinal)) {
            return $FullName.Substring($prefix.Length).Replace('\', '/')
        }
        return $FullName.Replace('\', '/')
    }

    function Get-StaticSafetyReport {
        # A multi-line report for one category. Empty string means no hits.
        param([Parameter(Mandatory)][string]$Kind)
        $found = @($script:sourceHits | Where-Object { $_.Kind -eq $Kind })
        if ($found.Count -eq 0) { return '' }
        return (($found | ForEach-Object { '{0}:{1} {2}' -f $_.File, $_.Line, $_.Pattern }) -join "`n")
    }

    $script:sourceHits = New-Object System.Collections.ArrayList
    foreach ($fullName in (Get-StaticSafetySourceFile)) {
        $relative = Get-StaticSafetyRelativePath -FullName $fullName
        $text = [IO.File]::ReadAllText($fullName)
        foreach ($hit in (Get-StaticSafetyHit -File $relative -Text $text)) { [void]$script:sourceHits.Add($hit) }
    }
    foreach ($fullName in (Get-StaticSafetyRuleFile)) {
        $relative = Get-StaticSafetyRelativePath -FullName $fullName
        $text = [IO.File]::ReadAllText($fullName)
        foreach ($hit in (Get-StaticSafetyNonAsciiHit -File $relative -Text $text)) { [void]$script:sourceHits.Add($hit) }
    }
    $script:sourceHits = $script:sourceHits.ToArray()
}

Describe 'static safety scanner self-test' {
    It 'detects Invoke-WebRequest and ignores the same word in a comment' {
        $sample = @'
function Invoke-TestSample {
    # Documentation may mention Invoke-WebRequest.
    Invoke-WebRequest -Uri 'https://example.invalid'
}
'@
        $hits = @(Get-StaticSafetyHit -File 'sample.ps1' -Text $sample)
        $network = @($hits | Where-Object { $_.Kind -eq 'network' })
        $network.Count | Should -Be 1
        $network[0].Pattern | Should -Be 'Invoke-WebRequest'
        $network[0].Line | Should -Be 3
    }

    It 'detects a write, an environment read and a non-ASCII character' {
        $text = "Set-Content -Path 'x'`n" + '$env:SECRET' + "`n" + 'dash ' + [char]0x2014
        $hits = @(Get-StaticSafetyHit -File 'sample.ps1' -Text $text)
        @($hits | Where-Object { $_.Kind -eq 'write' }).Count | Should -Be 1
        @($hits | Where-Object { $_.Kind -eq 'env' }).Count | Should -Be 1
        @($hits | Where-Object { $_.Kind -eq 'non-ascii' }).Count | Should -Be 1
    }

    It 'allows the three named binaries and flags any other absolute path' {
        $text = "'/usr/bin/lsblk'`n'/usr/bin/fdesetup'`n'/usr/bin/findmnt'`n'/usr/bin/whoami'"
        $hits = @(Get-StaticSafetyHit -File 'sample.ps1' -Text $text)
        $binary = @($hits | Where-Object { $_.Kind -eq 'binary' })
        $binary.Count | Should -Be 1
        $binary[0].Pattern | Should -Be '/usr/bin/whoami'
    }

    It 'allows process types only in SystemQueries.ps1' {
        $text = '$startInfo = New-Object -TypeName ''System.Diagnostics.ProcessStartInfo'''
        $allowed = @(Get-StaticSafetyHit -File 'src/Vacate/Private/SystemQueries.ps1' -Text $text)
        $denied = @(Get-StaticSafetyHit -File 'src/Vacate/Private/Other.ps1' -Text $text)
        @($allowed | Where-Object { $_.Kind -eq 'process' }).Count | Should -Be 0
        @($denied | Where-Object { $_.Kind -eq 'process' }).Count | Should -Be 2
    }
}

Describe 'module source' {
    It 'contains no network calls' {
        (Get-StaticSafetyReport -Kind 'network') | Should -Be ''
    }

    It 'contains no dynamic code execution' {
        (Get-StaticSafetyReport -Kind 'dynamic') | Should -Be ''
    }

    It 'contains no process launches outside SystemQueries.ps1' {
        (Get-StaticSafetyReport -Kind 'process') | Should -Be ''
    }

    It 'contains no external binaries outside the allow-list' {
        (Get-StaticSafetyReport -Kind 'binary') | Should -Be ''
    }

    It 'contains no writes outside the allowed output writer' {
        (Get-StaticSafetyReport -Kind 'write') | Should -Be ''
    }

    It 'reads the environment only in Platform.ps1' {
        (Get-StaticSafetyReport -Kind 'env') | Should -Be ''
    }

    It 'contains only ASCII characters in source and rule files' {
        (Get-StaticSafetyReport -Kind 'non-ascii') | Should -Be ''
    }
}
