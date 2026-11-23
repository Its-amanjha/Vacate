# Tests for Test-VacateCleanTarget (D50): the last check before a move to the Recycle Bin/Trash.
# Real temp folders only, under [IO.Path]::GetTempPath(). Junctions on Windows, symlinks elsewhere.

# -Skip is evaluated at discovery time, so the runtime platform is computed here.
$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$script:onLinux = ((Get-Variable IsLinux -ValueOnly -ErrorAction SilentlyContinue) -eq $true)

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $script:sep = [string][IO.Path]::DirectorySeparatorChar

    function Invoke-CleanTarget {
        param([AllowNull()][AllowEmptyString()][string]$Path, [AllowNull()][AllowEmptyCollection()][string[]]$Roots)
        InModuleScope Vacate -Parameters @{ P = $Path; R = $Roots } {
            param($P, $R)
            Test-VacateCleanTarget -Path $P -AllowedRoots $R
        }
    }

    function J {
        # Joins segments with the platform separator, no disk access.
        param([Parameter(ValueFromRemainingArguments)][string[]]$Parts)
        return ($Parts -join $script:sep)
    }

    function Add-TestLink {
        # Junction on Windows (no privilege needed), symlink elsewhere. Records it for cleanup.
        param([string]$Link, [string]$Target)
        if ($script:onWindows) { New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $Link -Target $Target | Out-Null }
        $script:links.Add($Link)
    }

    # Tree:
    #   <tree>/bob                 allowed root (HOME-like)
    #   <tree>/bob/AppData/Local   allowed root (nested)
    #   <tree>/bob/AppData/Local/App/cache.db, App/Cache/x.bin
    #   <tree>/bob/notes.txt
    #   <tree>/bob2/secret.txt     sibling whose name starts with the root name
    #   <tree>/outside/secret/s.txt
    #   <tree>/linkroot/real       target of a link used as an allowed root
    $script:tree = Join-Path ([IO.Path]::GetTempPath()) ('vacate-clean-' + [guid]::NewGuid().ToString('N'))
    foreach ($d in @('bob/AppData/Local/App/Cache', 'bob/Docs/sub', 'bob2', 'outside/secret', 'linkroot/real/inner')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:tree $d))
    }
    foreach ($f in @('bob/AppData/Local/App/cache.db', 'bob/AppData/Local/App/Cache/x.bin', 'bob/notes.txt', 'bob2/secret.txt', 'outside/secret/s.txt', 'linkroot/real/inner/f.txt')) {
        [IO.File]::WriteAllText((Join-Path $script:tree $f), 'x')
    }
    $script:bob = J $script:tree 'bob'
    $script:local = J $script:bob 'AppData' 'Local'
    $script:roots = @($script:bob, $script:local)
    $script:links = New-Object System.Collections.Generic.List[string]
}

AfterAll {
    # Links first (never recurse through one), then the tree.
    foreach ($l in $script:links) {
        try { [IO.Directory]::Delete($l) }
        catch {
            try { [IO.File]::Delete($l) } catch { Write-Warning "could not remove test link $l" }
        }
    }
    if ($script:tree -and [IO.Directory]::Exists($script:tree)) { [IO.Directory]::Delete($script:tree, $true) }
}

Describe 'Test-VacateCleanTarget result shape' {
    It 'returns the contract fields in order' {
        $r = Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots $roots
        @($r.PSObject.Properties.Name) | Should -Be @('ok', 'code', 'reason', 'fullPath', 'isDirectory')
        $r.ok | Should -BeOfType [bool]
        $r.isDirectory | Should -BeOfType [bool]
        $r.code | Should -BeOfType [string]
    }
}

Describe 'Test-VacateCleanTarget accepts real targets' {
    It 'ok for a file below a root' {
        $p = J $bob 'notes.txt'
        $r = Invoke-CleanTarget -Path $p -Roots $roots
        $r.ok | Should -BeTrue
        $r.code | Should -Be 'ok'
        $r.reason | Should -Be ''
        $r.fullPath | Should -Be $p
        $r.isDirectory | Should -BeFalse
    }
    It 'ok for a folder below a nested root' {
        $p = J $local 'App' 'Cache'
        $r = Invoke-CleanTarget -Path $p -Roots $roots
        $r.code | Should -Be 'ok'
        $r.isDirectory | Should -BeTrue
        $r.fullPath | Should -Be $p
    }
    It 'ok with a single root and a trailing separator on the root' {
        $r = Invoke-CleanTarget -Path (J $local 'App' 'cache.db') -Roots @($local + $sep)
        $r.code | Should -Be 'ok'
    }
    It 'accepts a trailing separator on the target and drops it from fullPath' {
        $r = Invoke-CleanTarget -Path ((J $bob 'Docs' 'sub') + $sep) -Roots $roots
        $r.code | Should -Be 'ok'
        $r.fullPath | Should -Be (J $bob 'Docs' 'sub')
        $r.isDirectory | Should -BeTrue
    }
    It 'canonicalises a root given with . or ..' {
        $r = Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots @((J $bob 'Docs' '..'), (J $bob '.'))
        $r.code | Should -Be 'ok'
    }
    It 'ignores null and empty root entries next to a valid root' {
        $r = Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots @($null, '', $bob)
        $r.code | Should -Be 'ok'
    }
}

Describe 'Test-VacateCleanTarget not-absolute' {
    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an empty path'; P = '' },
        @{ Name = 'a null path'; P = $null },
        @{ Name = 'whitespace'; P = '   ' },
        @{ Name = 'a relative path'; P = 'bob/notes.txt' },
        @{ Name = 'a dot-relative path'; P = './notes.txt' },
        @{ Name = 'a parent-relative path'; P = '../notes.txt' },
        @{ Name = 'a tilde path'; P = '~/notes.txt' }
    ) {
        $r = Invoke-CleanTarget -Path $P -Roots $roots
        $r.ok | Should -BeFalse
        $r.code | Should -Be 'not-absolute'
        $r.isDirectory | Should -BeFalse
    }
    It 'refuses a path with a control character' {
        $r = Invoke-CleanTarget -Path ((J $bob 'notes.txt') + [char]0) -Roots $roots
        $r.code | Should -Be 'not-absolute'
    }
    It 'refuses Windows-only bad forms: <Name>' -Skip:(-not $script:onWindows) -ForEach @(
        @{ Name = 'drive-relative C:x'; P = 'C:notes.txt' },
        @{ Name = 'rooted without drive'; P = '\Users\bob\notes.txt' },
        @{ Name = 'forward-slash rooted without drive'; P = '/Users/bob/notes.txt' },
        @{ Name = 'UNC'; P = '\\server\share\x' },
        @{ Name = 'device path'; P = '\\?\C:\Users\bob\x' },
        @{ Name = 'dot device path'; P = '\\.\C:\Users\bob\x' },
        @{ Name = 'bare drive'; P = 'C:' }
    ) {
        $r = Invoke-CleanTarget -Path $P -Roots @('C:\Users\bob')
        $r.code | Should -Be 'not-absolute'
    }
    It 'refuses names Windows does not allow: <Name>' -Skip:(-not $script:onWindows) -ForEach @(
        @{ Name = 'wildcard'; Leaf = 'note*.txt' },
        @{ Name = 'question mark'; Leaf = 'note?.txt' },
        @{ Name = 'reserved device name'; Leaf = 'NUL' },
        @{ Name = 'reserved device name with extension'; Leaf = 'com1.txt' }
    ) {
        $r = Invoke-CleanTarget -Path (J $bob $Leaf) -Roots $roots
        $r.code | Should -Be 'not-absolute'
    }
    It 'refuses a Windows-style path on Linux and macOS' -Skip:($script:onWindows) {
        $r = Invoke-CleanTarget -Path 'C:\Users\bob\x' -Roots $roots
        $r.code | Should -Be 'not-absolute'
    }
}

Describe 'Test-VacateCleanTarget outside-roots and is-root' {
    It 'refuses a sibling folder whose name starts with the root name' {
        $r = Invoke-CleanTarget -Path (J $tree 'bob2' 'secret.txt') -Roots $roots
        $r.code | Should -Be 'outside-roots'
        $r.ok | Should -BeFalse
        $r2 = Invoke-CleanTarget -Path (J $tree 'bob2') -Roots $roots
        $r2.code | Should -Be 'outside-roots'
    }
    It 'refuses a path above the root' {
        (Invoke-CleanTarget -Path $tree -Roots $roots).code | Should -Be 'outside-roots'
    }
    It 'refuses an unrelated existing path' {
        (Invoke-CleanTarget -Path (J $tree 'outside' 'secret' 's.txt') -Roots $roots).code | Should -Be 'outside-roots'
    }
    It 'keeps the separator boundary when the root has a trailing separator' {
        (Invoke-CleanTarget -Path (J $tree 'bob2' 'secret.txt') -Roots @($bob + $sep)).code | Should -Be 'outside-roots'
    }
    It 'refuses when no roots are given' {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots @()).code | Should -Be 'outside-roots'
        (Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots $null).code | Should -Be 'outside-roots'
    }
    It 'ignores a relative root' {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots @('bob', '.')).code | Should -Be 'outside-roots'
    }
    It 'ignores a bare drive or filesystem root as an allowed root' {
        $top = [IO.Path]::GetPathRoot($bob)
        (Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots @($top)).code | Should -Be 'outside-roots'
        if ($script:onWindows) { (Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots @('C:', 'C:/', 'C:\..')).code | Should -Be 'outside-roots' }
        else { (Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots @('/', '//', '/..')).code | Should -Be 'outside-roots' }
    }
    It 'refuses a path equal to a root' {
        $r = Invoke-CleanTarget -Path $bob -Roots $roots
        $r.code | Should -Be 'is-root'
        $r.ok | Should -BeFalse
        (Invoke-CleanTarget -Path ($bob + $sep) -Roots $roots).code | Should -Be 'is-root'
    }
    It 'refuses a nested root even though it lies below another root' {
        (Invoke-CleanTarget -Path $local -Roots $roots).code | Should -Be 'is-root'
    }
    It 'matches case-insensitively on Windows' -Skip:(-not $script:onWindows) {
        (Invoke-CleanTarget -Path $bob.ToUpperInvariant() -Roots $roots).code | Should -Be 'is-root'
        $r = Invoke-CleanTarget -Path (J $bob.ToUpperInvariant() 'NOTES.TXT') -Roots $roots
        $r.code | Should -Be 'ok'
        (Invoke-CleanTarget -Path (J ($tree.ToUpperInvariant()) 'BOB2' 'secret.txt') -Roots $roots).code | Should -Be 'outside-roots'
        (Invoke-CleanTarget -Path ($bob.Substring(0, 1).ToLowerInvariant() + (J $bob 'notes.txt').Substring(1)) -Roots $roots).code | Should -Be 'ok'
    }
    It 'matches case-sensitively (ordinal) on Linux' -Skip:(-not $script:onLinux) {
        $r = Invoke-CleanTarget -Path (J $tree 'BOB' 'notes.txt') -Roots $roots
        $r.code | Should -Be 'outside-roots'
    }
}

Describe 'Test-VacateCleanTarget missing' {
    It 'refuses a target that does not exist' {
        $r = Invoke-CleanTarget -Path (J $bob 'nope.txt') -Roots $roots
        $r.code | Should -Be 'missing'
        $r.ok | Should -BeFalse
        $r.fullPath | Should -Be (J $bob 'nope.txt')
    }
    It 'refuses when a parent folder does not exist' {
        (Invoke-CleanTarget -Path (J $bob 'gone' 'x.txt') -Roots $roots).code | Should -Be 'missing'
    }
    It 'refuses when a parent component is a file' {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt' 'x') -Roots $roots).code | Should -Be 'missing'
    }
    It 'refuses when the root itself does not exist' {
        $ghost = J $tree 'ghost'
        (Invoke-CleanTarget -Path (J $ghost 'x') -Roots @($ghost)).code | Should -Be 'missing'
    }
}

Describe 'Test-VacateCleanTarget not-canonical' {
    It 'refuses a . segment' {
        $r = Invoke-CleanTarget -Path (J $bob '.' 'notes.txt') -Roots $roots
        $r.code | Should -Be 'not-canonical'
        $r.ok | Should -BeFalse
        $r.isDirectory | Should -BeFalse
    }
    It 'refuses a .. that would stay inside the root' {
        (Invoke-CleanTarget -Path (J $bob 'Docs' '..' 'notes.txt') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses a .. that would resolve outside the root' {
        (Invoke-CleanTarget -Path (J $bob 'Docs' '..' '..' 'outside' 'secret' 's.txt') -Roots $roots).code | Should -Be 'not-canonical'
        (Invoke-CleanTarget -Path (J $bob '..' 'bob2' 'secret.txt') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses a . or .. that would name the root itself' {
        (Invoke-CleanTarget -Path (J $bob '.') -Roots $roots).code | Should -Be 'not-canonical'
        (Invoke-CleanTarget -Path (J $bob 'Docs' '..') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses a .. after a missing folder or a file' {
        (Invoke-CleanTarget -Path (J $bob 'gone' '..' 'notes.txt') -Roots $roots).code | Should -Be 'not-canonical'
        (Invoke-CleanTarget -Path (J $bob 'notes.txt' '..' 'notes.txt') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses repeated separators (GetFullPath would rewrite them)' {
        (Invoke-CleanTarget -Path ($bob + $sep + $sep + 'notes.txt') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses forward slashes on Windows (GetFullPath would rewrite them)' -Skip:(-not $script:onWindows) {
        (Invoke-CleanTarget -Path ((J $bob 'notes.txt').Replace('\', '/')) -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses a segment ending in a dot on Windows' -Skip:(-not $script:onWindows) {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt.') -Roots $roots).code | Should -Be 'not-canonical'
        (Invoke-CleanTarget -Path (J $bob 'Docs.' 'sub') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses a segment ending in a space on Windows' -Skip:(-not $script:onWindows) {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt ') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses an alternate data stream on Windows' -Skip:(-not $script:onWindows) {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt:secret') -Roots $roots).code | Should -Be 'not-canonical'
        (Invoke-CleanTarget -Path (J $bob 'notes.txt::$DATA') -Roots $roots).code | Should -Be 'not-canonical'
        (Invoke-CleanTarget -Path (J $bob 'Docs:x' 'sub') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'refuses an 8.3 short-name segment on Windows' -Skip:(-not $script:onWindows) {
        (Invoke-CleanTarget -Path (J $bob 'APPDAT~1' 'Local') -Roots $roots).code | Should -Be 'not-canonical'
        (Invoke-CleanTarget -Path (J $bob 'notes~1.txt') -Roots $roots).code | Should -Be 'not-canonical'
    }
    It 'does not treat a plain tilde as a short name on Windows' -Skip:(-not $script:onWindows) {
        (Invoke-CleanTarget -Path (J $bob 'notes~x.txt') -Roots $roots).code | Should -Be 'missing'
    }
    It 'keeps trailing dots and colons as plain name characters on Linux and macOS' -Skip:($script:onWindows) {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt.') -Roots $roots).code | Should -Be 'missing'
        (Invoke-CleanTarget -Path (J $bob 'a:b') -Roots $roots).code | Should -Be 'missing'
    }
    It 'reports not-canonical before redacted-path' {
        (Invoke-CleanTarget -Path (J $bob 'h-0123456789' '..' 'notes.txt') -Roots $roots).code | Should -Be 'not-canonical'
    }
}

Describe 'Test-VacateCleanTarget redacted-path' {
    It 'refuses a path with an h-xxxxxxxxxx segment: <Name>' -ForEach @(
        @{ Name = 'leaf'; Segs = @('h-0a1b2c3d4e') },
        @{ Name = 'middle'; Segs = @('h-abcdef0123', 'x.txt') },
        @{ Name = 'uppercase hex'; Segs = @('H-ABCDEF0123') }
    ) {
        $p = $bob + $sep + ($Segs -join $sep)
        $r = Invoke-CleanTarget -Path $p -Roots $roots
        $r.code | Should -Be 'redacted-path'
        $r.ok | Should -BeFalse
    }
    It 'refuses a fully redacted path before any root check' {
        $p = $sep + 'h-0123456789' + $sep + 'h-9876543210'
        if ($script:onWindows) { $p = 'C:' + $p }
        (Invoke-CleanTarget -Path $p -Roots $roots).code | Should -Be 'redacted-path'
    }
    It 'refuses a redacted path even below a valid root before any disk check' {
        (Invoke-CleanTarget -Path (J $local 'h-0123456789' 'h-9876543210') -Roots $roots).code | Should -Be 'redacted-path'
    }
    It 'does not flag names that only look similar: <Leaf>' -ForEach @(
        @{ Leaf = 'h-0123456789a' }, @{ Leaf = 'h-012345678' }, @{ Leaf = 'h-012345678g' }, @{ Leaf = 'xh-0123456789' }, @{ Leaf = 'h_0123456789' }
    ) {
        (Invoke-CleanTarget -Path (J $bob $Leaf) -Roots $roots).code | Should -Be 'missing'
    }
}

Describe 'Test-VacateCleanTarget junctions and symlinks' {
    It 'refuses a link as the target (reparse-target)' {
        $link = J $bob 'link-out'
        Add-TestLink -Link $link -Target (J $tree 'outside')
        $r = Invoke-CleanTarget -Path $link -Roots $roots
        $r.code | Should -Be 'reparse-target'
        $r.ok | Should -BeFalse
        $r.isDirectory | Should -BeFalse
    }
    It 'refuses a link that points inside the root too' {
        $link = J $bob 'link-in'
        Add-TestLink -Link $link -Target (J $bob 'Docs')
        (Invoke-CleanTarget -Path $link -Roots $roots).code | Should -Be 'reparse-target'
    }
    It 'refuses a dangling link as the target' {
        $gone = J $tree 'soon-gone'
        [void][IO.Directory]::CreateDirectory($gone)
        $link = J $bob 'link-dangling'
        Add-TestLink -Link $link -Target $gone
        [IO.Directory]::Delete($gone)
        (Invoke-CleanTarget -Path $link -Roots $roots).code | Should -Be 'reparse-target'
    }
    It 'refuses a target below a link (reparse-in-chain)' {
        $link = J $bob 'link-chain'
        Add-TestLink -Link $link -Target (J $tree 'outside')
        $r = Invoke-CleanTarget -Path (J $link 'secret' 's.txt') -Roots $roots
        $r.code | Should -Be 'reparse-in-chain'
        $r.ok | Should -BeFalse
        (Invoke-CleanTarget -Path (J $link 'secret') -Roots $roots).code | Should -Be 'reparse-in-chain'
    }
    It 'refuses when the allowed root itself is a link' {
        $link = J $tree 'root-link'
        Add-TestLink -Link $link -Target (J $tree 'linkroot' 'real')
        $r = Invoke-CleanTarget -Path (J $link 'inner' 'f.txt') -Roots @($link)
        $r.code | Should -Be 'reparse-in-chain'
    }
    It 'checks from the outermost root, so a linked nested root is refused' {
        # <bob>/Linked is a link and also listed as a root; the walk from <bob> must still see it.
        $link = J $bob 'Linked'
        Add-TestLink -Link $link -Target (J $tree 'linkroot' 'real')
        $r = Invoke-CleanTarget -Path (J $link 'inner' 'f.txt') -Roots @($bob, $link)
        $r.code | Should -Be 'reparse-in-chain'
    }
    It 'refuses a .. that steps back out of a link' {
        # On Linux/macOS the kernel resolves link/.. physically (into the link target's parent),
        # so a '..' must never be collapsed lexically; it is refused outright.
        $link = J $bob 'link-dotdot'
        Add-TestLink -Link $link -Target (J $tree 'outside' 'secret')
        $r = Invoke-CleanTarget -Path (J $link '..' 'notes.txt') -Roots $roots
        $r.code | Should -Be 'not-canonical'
        $r.ok | Should -BeFalse
    }
    It 'reports missing before a link that lies further down' {
        $link = J $bob 'link-later'
        Add-TestLink -Link $link -Target (J $tree 'outside')
        (Invoke-CleanTarget -Path (J $bob 'gone' 'link-later') -Roots $roots).code | Should -Be 'missing'
    }
    It 'refuses a file symlink as the target' -Skip:($script:onWindows) {
        $link = J $bob 'file-link'
        Add-TestLink -Link $link -Target (J $tree 'outside' 'secret' 's.txt')
        (Invoke-CleanTarget -Path $link -Roots $roots).code | Should -Be 'reparse-target'
    }
    It 'still accepts real siblings of a link' {
        (Invoke-CleanTarget -Path (J $bob 'notes.txt') -Roots $roots).code | Should -Be 'ok'
    }
}

Describe 'Test-VacateCleanTarget is read-only' {
    It 'changes nothing on disk' {
        $snap = {
            # Manual walk that never enters a link; name and write time of every real item.
            $out = New-Object System.Collections.Generic.List[string]
            $stack = New-Object System.Collections.Generic.Stack[string]
            $stack.Push($tree)
            while ($stack.Count -gt 0) {
                $d = $stack.Pop()
                foreach ($e in [IO.Directory]::GetFileSystemEntries($d)) {
                    $a = [int64][IO.File]::GetAttributes($e)
                    if (($a -band 0x400) -ne 0) { $out.Add($e + '|link'); continue }
                    $out.Add($e + '|' + [IO.File]::GetLastWriteTimeUtc($e).Ticks)
                    if (($a -band 0x10) -ne 0) { $stack.Push($e) }
                }
            }
            return @($out.ToArray() | Sort-Object)
        }
        $before = & $snap
        foreach ($p in @((J $bob 'notes.txt'), (J $local 'App'), (J $bob 'nope'), (J $tree 'bob2'))) { [void](Invoke-CleanTarget -Path $p -Roots $roots) }
        $after = & $snap
        $after | Should -Be $before
        [IO.File]::Exists((J $bob 'notes.txt')) | Should -BeTrue
    }
}
