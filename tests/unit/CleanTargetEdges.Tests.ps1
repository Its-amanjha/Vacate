# Edge-case tests for Test-VacateCleanTarget (D50): spellings that name something other than
# the item on disk. Complements CleanTarget.Tests.ps1 (no repeated cases here): 8.3 short names,
# trailing dots and spaces, device and UNC prefixes, mixed and doubled separators, roots with
# separators, Unicode normalisation, paths longer than 260 characters, link chains, and a target
# that is swapped or removed between the plan and the execute-time re-check.
# Fixtures live under $TestDrive only; links are junctions on Windows (no privilege needed) and
# symlinks elsewhere.

# -Skip is evaluated at discovery time, so the runtime platform is computed here (D24).
$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$script:onLinux = ((Get-Variable IsLinux -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$script:onMacOS = ((Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    # Pester 5 does not re-run the file's top-level code for the run phase, so the flags used
    # by the helpers are set again here (D24).
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $script:onLinux = ((Get-Variable IsLinux -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $script:onMacOS = ((Get-Variable IsMacOS -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $script:sep = [string][IO.Path]::DirectorySeparatorChar

    function Invoke-EdgeCheck {
        # One execute-time check, called inside the module so the private function is visible.
        param([AllowNull()][AllowEmptyString()][string]$Path, [AllowNull()][AllowEmptyCollection()][string[]]$Roots)
        InModuleScope Vacate -Parameters @{ P = $Path; R = $Roots } {
            param($P, $R)
            Test-VacateCleanTarget -Path $P -AllowedRoots $R
        }
    }

    function Get-TestJoinedPath {
        # Joins segments with the platform separator, no disk access.
        param([Parameter(ValueFromRemainingArguments)][string[]]$Parts)
        return ($Parts -join $script:sep)
    }

    function Add-TestLink {
        # Junction on Windows, symlink elsewhere. Records it so cleanup deletes the link itself.
        param([string]$Link, [string]$Target)
        if ($script:onWindows) { New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $Link -Target $Target | Out-Null }
        $script:links.Add($Link)
    }

    $script:links = New-Object System.Collections.Generic.List[string]

    # Tree under $TestDrive:
    #   bob                          allowed root (HOME-like)
    #   bob/AppData/Local            allowed root (nested)
    #   bob/notes.txt, bob/Docs/sub
    #   bob2/secret.txt              sibling whose name starts with the root name
    #   outside/secret/s.txt         target of every link below
    $script:tree = Join-Path $TestDrive ('edges-' + [guid]::NewGuid().ToString('N'))
    foreach ($d in @('bob/AppData/Local', 'bob/Docs/sub', 'bob2', 'outside/secret')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:tree $d))
    }
    foreach ($f in @('bob/notes.txt', 'bob2/secret.txt', 'outside/secret/s.txt')) {
        [IO.File]::WriteAllText((Join-Path $script:tree $f), 'x')
    }
    $script:bob = Get-TestJoinedPath $script:tree 'bob'
    $script:local = Get-TestJoinedPath $script:bob 'AppData' 'Local'
    $script:roots = @($script:bob, $script:local)
}

AfterAll {
    # Links first (never recurse through one), then the tree.
    if ($null -ne $script:links) {
        foreach ($l in $script:links) {
            try { [IO.Directory]::Delete($l) }
            catch {
                try { [IO.File]::Delete($l) } catch { Write-Warning "could not remove test link $l" }
            }
        }
    }
    if ($script:tree -and [IO.Directory]::Exists($script:tree)) {
        try { [IO.Directory]::Delete($script:tree, $true) }
        catch { Write-Warning "could not remove test tree $($script:tree)" }
    }
}

Describe 'Windows spellings that resolve to another item (D50)' -Skip:(-not $script:onWindows) {
    It 'refuses a real 8.3 short name of a folder, below it, and as the allowed root' {
        # A long name makes NTFS write a short alias next to it; if the volume has 8.3 off,
        # no alias exists and the case cannot be exercised here.
        $longDir = Get-TestJoinedPath $script:bob 'p4c8dot3longname'
        [void][IO.Directory]::CreateDirectory($longDir)
        $alias = Get-TestJoinedPath $script:bob 'P4C8DO~1'
        if (-not (Test-Path -LiteralPath $alias)) {
            Set-ItResult -Skipped -Because 'this volume does not create 8.3 short names'
            return
        }

        $r = Invoke-EdgeCheck -Path $alias -Roots $script:roots
        $r.code | Should -Be 'not-canonical'
        $r.ok | Should -BeFalse

        (Invoke-EdgeCheck -Path (Get-TestJoinedPath $alias 'x.txt') -Roots $script:roots).code | Should -Be 'not-canonical'
        (Invoke-EdgeCheck -Path (Get-TestJoinedPath $alias 'x.txt') -Roots @($alias)).code | Should -Be 'not-canonical'
    }

    It 'refuses a middle segment ending in a dot or a space' -ForEach @(
        @{ Name = 'dot'; Segment = 'Docs.' },
        @{ Name = 'space'; Segment = 'Docs ' }
    ) {
        $r = Invoke-EdgeCheck -Path (Get-TestJoinedPath $script:bob $Segment 'sub') -Roots $script:roots
        $r.code | Should -Be 'not-canonical'
        $r.ok | Should -BeFalse
    }

    It 'refuses a device or UNC prefix: <Name>' -ForEach @(
        @{ Name = 'UNC device form'; P = '\\?\UNC\server\share\x' },
        @{ Name = 'volume device form'; P = '\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}\x' },
        @{ Name = 'dot device form'; P = '\\.\PhysicalDrive0' },
        @{ Name = 'NT namespace form'; P = '\??\C:\Temp\x' },
        @{ Name = 'UNC with forward slashes'; P = '//server/share/x' }
    ) {
        (Invoke-EdgeCheck -Path $P -Roots @('C:\Temp')).code | Should -Be 'not-absolute'
    }

    It 'refuses a drive-relative path that names a real folder: <P>' -ForEach @(
        @{ P = 'C:bob\notes.txt' },
        @{ P = 'C:..\bob\notes.txt' },
        @{ P = 'c:notes.txt' }
    ) {
        (Invoke-EdgeCheck -Path $P -Roots $script:roots).code | Should -Be 'not-absolute'
    }

    It 'refuses a path that mixes / and \ inside one spelling' {
        $mixed = (Get-TestJoinedPath $script:bob 'Docs' 'sub').Replace('\Docs\', '/Docs/')
        $mixed | Should -Not -Be (Get-TestJoinedPath $script:bob 'Docs' 'sub')
        $r = Invoke-EdgeCheck -Path $mixed -Roots $script:roots
        $r.code | Should -Be 'not-canonical'
        $r.ok | Should -BeFalse
    }

    It 'refuses doubled separators right after the drive' {
        $drive = $script:bob.Substring(0, 2)
        $doubled = $drive + $script:sep + $script:sep + $script:bob.Substring(3) + $script:sep + 'notes.txt'
        (Invoke-EdgeCheck -Path $doubled -Roots $script:roots).code | Should -Be 'not-canonical'
    }

    It 'accepts redundant trailing separators on a folder but reports the path without them' {
        # Trailing separators cannot name a different item, so they are trimmed rather than
        # refused; fullPath is the canonical spelling that will be moved.
        $folder = Get-TestJoinedPath $script:bob 'Docs' 'sub'
        $r = Invoke-EdgeCheck -Path ($folder + $script:sep + $script:sep) -Roots $script:roots
        $r.code | Should -Be 'ok'
        $r.fullPath | Should -Be $folder
        $r.isDirectory | Should -BeTrue
    }

    It 'refuses a root spelled in another case with a trailing separator when the path is that root' {
        $r = Invoke-EdgeCheck -Path $script:bob.ToUpperInvariant() -Roots @($script:bob + $script:sep)
        $r.code | Should -Be 'is-root'
    }

    It 'accepts a root given with two trailing separators' {
        $r = Invoke-EdgeCheck -Path (Get-TestJoinedPath $script:bob 'notes.txt') -Roots @($script:bob + $script:sep + $script:sep)
        $r.code | Should -Be 'ok'
        (Invoke-EdgeCheck -Path (Get-TestJoinedPath $script:tree 'bob2' 'secret.txt') -Roots @($script:bob + $script:sep + $script:sep)).code | Should -Be 'outside-roots'
    }
}

Describe 'Unicode names (D50)' {
    It 'accepts the name as stored and refuses the other normalisation form' {
        # 'cafe' + combining acute (NFD) vs 'caf' + e-acute (NFC). util.Linux and NTFS compare
        # bytes; APFS compares normalisation-insensitively, so the negative does not hold there.
        if ($script:onMacOS) {
            Set-ItResult -Skipped -Because 'APFS compares names normalisation-insensitively'
            return
        }
        $nfc = 'caf' + [char]0x00E9
        $nfd = 'cafe' + [char]0x0301
        [void][IO.Directory]::CreateDirectory((Join-Path $script:bob $nfc))

        (Invoke-EdgeCheck -Path (Join-Path $script:bob $nfc) -Roots $script:roots).code | Should -Be 'ok'
        (Invoke-EdgeCheck -Path (Join-Path $script:bob $nfd) -Roots $script:roots).code | Should -Be 'missing'
    }

    It 'refuses a file name that only differs by its normalisation form' {
        # The bytes on disk decide: a decomposed spelling of a real file is missing, not a
        # second live target.
        if ($script:onMacOS) {
            Set-ItResult -Skipped -Because 'APFS compares names normalisation-insensitively'
            return
        }
        $nfcFile = 'se' + [char]0x00F1 + 'al.txt'
        [IO.File]::WriteAllText((Join-Path $script:bob $nfcFile), 'x')
        (Invoke-EdgeCheck -Path (Join-Path $script:bob $nfcFile) -Roots $script:roots).code | Should -Be 'ok'
        $nfdFile = 'sen' + [char]0x0303 + 'al.txt'
        (Invoke-EdgeCheck -Path (Join-Path $script:bob $nfdFile) -Roots $script:roots).code | Should -Be 'missing'
    }
}

Describe 'Long paths (D50)' {
    It 'accepts an existing target deeper than 260 characters' {
        # Seven long segments under the temp root push the absolute path past 260 characters.
        # Creation can fail when long paths are disabled for the host; then this case cannot be
        # exercised and says so instead of passing on a short path.
        $segment = 'vacate-long-path-segment-abcdefghijkl'
        $deep = $script:tree
        try {
            for ($i = 0; $i -lt 7; $i++) {
                $deep = Join-Path $deep $segment
                [void][IO.Directory]::CreateDirectory($deep)
            }
        }
        catch {
            Set-ItResult -Skipped -Because ('this host cannot create paths longer than 260 characters ({0})' -f $_.Exception.GetType().Name)
            return
        }
        $deep.Length | Should -BeGreaterThan 260

        $r = Invoke-EdgeCheck -Path $deep -Roots @($script:tree)
        $r.code | Should -Be 'ok'
        $r.isDirectory | Should -BeTrue
    }
}

Describe 'Targets that change or vanish between the plan and the execute check (D50)' {
    It 'refuses a target that was valid and has since been removed' {
        $victim = Get-TestJoinedPath $script:bob 'doomed.txt'
        [IO.File]::WriteAllText($victim, 'x')
        (Invoke-EdgeCheck -Path $victim -Roots $script:roots).code | Should -Be 'ok'

        # The move happens after the plan: whatever disappears in between must be reported.
        [IO.File]::Delete($victim)
        $r = Invoke-EdgeCheck -Path $victim -Roots $script:roots
        $r.code | Should -Be 'missing'
        $r.ok | Should -BeFalse
    }

    It 'refuses a target whose parent folder was removed after the first check' {
        $folder = Get-TestJoinedPath $script:bob 'doomed-dir'
        [void][IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllText((Join-Path $folder 'inner.txt'), 'x')
        (Invoke-EdgeCheck -Path (Join-Path $folder 'inner.txt') -Roots $script:roots).code | Should -Be 'ok'

        [IO.Directory]::Delete($folder, $true)
        (Invoke-EdgeCheck -Path (Join-Path $folder 'inner.txt') -Roots $script:roots).code | Should -Be 'missing'
        (Invoke-EdgeCheck -Path $folder -Roots $script:roots).code | Should -Be 'missing'
    }

    It 'refuses a real folder that was swapped for a link between the two checks' {
        $swapped = Get-TestJoinedPath $script:bob 'swapped'
        [void][IO.Directory]::CreateDirectory($swapped)
        [IO.File]::WriteAllText((Join-Path $swapped 'inner.txt'), 'x')
        (Invoke-EdgeCheck -Path (Join-Path $swapped 'inner.txt') -Roots $script:roots).code | Should -Be 'ok'

        [IO.Directory]::Delete($swapped, $true)
        Add-TestLink -Link $swapped -Target (Get-TestJoinedPath $script:tree 'outside')

        $r = Invoke-EdgeCheck -Path (Join-Path $swapped 'inner.txt') -Roots $script:roots
        $r.code | Should -Be 'reparse-in-chain'
        $r.ok | Should -BeFalse
        (Invoke-EdgeCheck -Path $swapped -Roots $script:roots).code | Should -Be 'reparse-target'
    }

    It 'refuses a file that was swapped for a link between the two checks' {
        $swapped = Get-TestJoinedPath $script:bob 'swapped-file.txt'
        [IO.File]::WriteAllText($swapped, 'x')
        (Invoke-EdgeCheck -Path $swapped -Roots $script:roots).code | Should -Be 'ok'

        [IO.File]::Delete($swapped)
        try {
            Add-TestLink -Link $swapped -Target (Get-TestJoinedPath $script:tree 'outside' 'secret' 's.txt')
        }
        catch {
            Set-ItResult -Skipped -Because ('this user cannot create a symbolic link ({0})' -f $_.Exception.GetType().Name)
            return
        }

        (Invoke-EdgeCheck -Path $swapped -Roots $script:roots).code | Should -Be 'reparse-target'
    }

    It 'refuses a two-hop link chain at its first hop' {
        $first = Get-TestJoinedPath $script:bob 'hop-one'
        $second = Get-TestJoinedPath $script:tree 'hop-two'
        Add-TestLink -Link $second -Target (Get-TestJoinedPath $script:tree 'outside')
        Add-TestLink -Link $first -Target $second

        (Invoke-EdgeCheck -Path (Get-TestJoinedPath $first 'secret' 's.txt') -Roots $script:roots).code | Should -Be 'reparse-in-chain'
        (Invoke-EdgeCheck -Path $first -Roots $script:roots).code | Should -Be 'reparse-target'
    }

    It 'refuses a target below an allowed root that is a file' {
        $fileRoot = Get-TestJoinedPath $script:bob 'notes.txt'
        $r = Invoke-EdgeCheck -Path (Get-TestJoinedPath $fileRoot 'x.txt') -Roots @($fileRoot)
        $r.code | Should -Be 'missing'
        $r.ok | Should -BeFalse
    }
}
