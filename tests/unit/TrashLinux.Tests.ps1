# TrashLinux.Tests.ps1 - tests for the freedesktop.org Trash mover.
# Every file-system test works in a unique folder under [IO.Path]::GetTempPath().
# The real ~/.local/share/Trash is never touched. ASCII only.

$script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$script:onLinux = $false
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $topLinux = Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue
    if ($topLinux -eq $true) { $script:onLinux = $true }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    $script:onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    $linux = Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue
    if ($linux -eq $true) { $script:onLinux = $true }

    function Get-TestTrashSandbox {
        # A fresh temporary folder. Tests create source items and a Trash inside it.
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('vacate-trash-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($sandbox)
        return $sandbox
    }

    function Clear-TestSandbox {
        param([string]$Path)
        if ([string]::IsNullOrEmpty($Path)) { return }
        if (-not [IO.Directory]::Exists($Path)) { return }
        try {
            [IO.Directory]::Delete($Path, $true)
        }
        catch {
            Write-Verbose ('test cleanup failed: ' + $_.Exception.Message)
        }
    }

    function Invoke-TestTrashMove {
        param([string]$Path, [string]$TrashRoot)
        return (InModuleScope Vacate -Parameters @{ P = $Path; R = $TrashRoot } {
                param($P, $R)
                Move-VacateItemToTrashLinux -Path $P -TrashRoot $R
            })
    }

    function Invoke-TestTrashRestore {
        param([string]$TrashLocation, [string]$OriginalPath, [string]$TrashRoot)
        return (InModuleScope Vacate -Parameters @{ L = $TrashLocation; O = $OriginalPath; R = $TrashRoot } {
                param($L, $O, $R)
                Restore-VacateItemFromTrashLinux -TrashLocation $L -OriginalPath $O -TrashRoot $R
            })
    }

    function Get-TestTrashInfo {
        param([string]$Path)
        return (InModuleScope Vacate -Parameters @{ P = $Path } {
                param($P)
                Get-VacateTrashInfo -Path $P
            })
    }

    function Get-TestTrashEncode {
        param([string]$Path)
        return (InModuleScope Vacate -Parameters @{ P = $Path } {
                param($P)
                ConvertTo-VacateTrashInfoPath -Path $P
            })
    }
}

Describe 'trash path encoding' {
    It 'encodes spaces, percent signs and reserved characters' {
        $encoded = InModuleScope Vacate { ConvertTo-VacateTrashInfoPath -Path '/home/u/My File 100%.txt' }
        $encoded | Should -Be '/home/u/My%20File%20100%25.txt'
    }

    It 'encodes non-ASCII text as UTF-8 bytes' {
        $path = '/home/u/caf' + [char]0x00E9 + '.txt'
        $encoded = Get-TestTrashEncode -Path $path
        $encoded | Should -Be '/home/u/caf%C3%A9.txt'
    }

    It 'keeps unreserved characters and the separator readable' {
        $encoded = InModuleScope Vacate { ConvertTo-VacateTrashInfoPath -Path '/a/b_c-d.e~f' }
        $encoded | Should -Be '/a/b_c-d.e~f'
    }

    It 'round-trips through the decoder' {
        $path = '/home/u/a b%c' + [char]0x00E9 + '/x.txt'
        $decoded = InModuleScope Vacate -Parameters @{ P = $path } {
            param($P)
            $encoded = ConvertTo-VacateTrashInfoPath -Path $P
            return (ConvertFrom-VacateTrashInfoPath -Value $encoded)
        }
        $decoded | Should -Be $path
    }

    It 'encodes a newline and a carriage return so no second line can be injected' {
        $path = '/home/u/a' + [char]10 + 'Path=/etc/passwd' + [char]13 + 'b'
        $encoded = InModuleScope Vacate -Parameters @{ P = $path } { param($P) ConvertTo-VacateTrashInfoPath -Path $P }
        $encoded | Should -Be '/home/u/a%0APath%3D/etc/passwd%0Db'
        $text = InModuleScope Vacate -Parameters @{ P = $path } {
            param($P)
            ConvertTo-VacateTrashInfoText -Path $P -Now ([datetime]'2026-11-23T14:05:09')
        }
        $lines = $text.Split([char]10)
        $lines.Count | Should -Be 4
        $lines[3] | Should -Be ''
        @($lines | Where-Object { $_ -like 'Path=*' }).Count | Should -Be 1
        $text.IndexOf([char]13) | Should -Be -1
    }

    It 'encodes every reserved and control byte' {
        $encoded = InModuleScope Vacate { ConvertTo-VacateTrashInfoPath -Path ('/x' + [char]9 + '#?&=+;[]') }
        $encoded | Should -Be '/x%09%23%3F%26%3D%2B%3B%5B%5D'
    }

    It 'does not decode plus as a space' {
        $decoded = InModuleScope Vacate { ConvertFrom-VacateTrashInfoPath -Value '/home/u/a+b' }
        $decoded | Should -Be '/home/u/a+b'
    }

    It 'keeps a malformed percent sequence literal' {
        $decoded = InModuleScope Vacate { ConvertFrom-VacateTrashInfoPath -Value '/home/u/a%zz%2' }
        $decoded | Should -Be '/home/u/a%zz%2'
    }

    It 'decodes literal non-ASCII text kept unencoded in the file' {
        $path = '/home/u/caf' + [char]0x00E9 + '.txt'
        $decoded = InModuleScope Vacate -Parameters @{ P = $path } {
            param($P)
            ConvertFrom-VacateTrashInfoPath -Value $P
        }
        $decoded | Should -Be $path
    }

    It 'round-trips a character outside the basic plane' {
        $path = '/home/u/' + [char]::ConvertFromUtf32(0x1F600) + '.txt'
        $decoded = InModuleScope Vacate -Parameters @{ P = $path } {
            param($P)
            $encoded = ConvertTo-VacateTrashInfoPath -Path $P
            return (ConvertFrom-VacateTrashInfoPath -Value $encoded)
        }
        $decoded | Should -Be $path
    }
}

Describe 'trash information format' {
    It 'writes the header, encoded path and local date' {
        $text = InModuleScope Vacate {
            ConvertTo-VacateTrashInfoText -Path '/home/u/a b.txt' -Now ([datetime]'2026-11-23T14:05:09')
        }
        $lines = [regex]::Split($text, '\r\n|\n|\r')
        $lines[0] | Should -Be '[Trash Info]'
        $lines[1] | Should -Be 'Path=/home/u/a%20b.txt'
        $lines[2] | Should -Be 'DeletionDate=2026-11-23T14:05:09'
    }

    It 'writes no time zone suffix' {
        $text = InModuleScope Vacate {
            ConvertTo-VacateTrashInfoText -Path '/a' -Now ([datetime]'2026-11-23T14:05:09')
        }
        $text | Should -Not -Match 'DeletionDate=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[Z+-]'
    }
}

Describe 'Get-VacateTrashInfo' {
    BeforeEach {
        $script:sandbox = Get-TestTrashSandbox
        $script:infoPath = Join-Path $script:sandbox 'item.trashinfo'
    }

    AfterEach {
        Clear-TestSandbox -Path $script:sandbox
    }

    It 'reads the first Path and DeletionDate and ignores other lines' {
        [IO.File]::WriteAllText($script:infoPath, "[Trash Info]`nPath=/one`nPath=/two`nDeletionDate=2026-01-02T03:04:05`nX-Other=1`n")
        $info = Get-TestTrashInfo -Path $script:infoPath
        $info.path | Should -Be '/one'
        $info.deletionDate | Should -Be '2026-01-02T03:04:05'
    }

    It 'decodes the Path value' {
        [IO.File]::WriteAllText($script:infoPath, "[Trash Info]`nPath=%2Fhome%2Fu%2Fa%20b.txt`nDeletionDate=2026-01-02T03:04:05`n")
        $info = Get-TestTrashInfo -Path $script:infoPath
        $info.path | Should -Be '/home/u/a b.txt'
    }

    It 'rejects a missing header' {
        [IO.File]::WriteAllText($script:infoPath, "[Nope]`nPath=/a`n")
        { Get-TestTrashInfo -Path $script:infoPath } | Should -Throw -ExpectedMessage '*does not start with*'
    }

    It 'rejects a missing Path' {
        [IO.File]::WriteAllText($script:infoPath, "[Trash Info]`nDeletionDate=2026-01-02T03:04:05`n")
        { Get-TestTrashInfo -Path $script:infoPath } | Should -Throw -ExpectedMessage '*has no Path*'
    }

    It 'rejects a missing file' {
        { Get-TestTrashInfo -Path (Join-Path $script:sandbox 'none.trashinfo') } | Should -Throw -ExpectedMessage '*is missing*'
    }

    It 'rejects a symlinked information file' -Skip:(-not $script:onLinux) {
        [IO.File]::WriteAllText($script:infoPath, "[Trash Info]`nPath=/a`nDeletionDate=2026-01-02T03:04:05`n")
        $link = Join-Path $script:sandbox 'link.trashinfo'
        [void][IO.File]::CreateSymbolicLink($link, $script:infoPath)
        { Get-TestTrashInfo -Path $link } | Should -Throw -ExpectedMessage '*is a link*'
    }
}

Describe 'trash mount points' {
    BeforeAll {
        $script:mountSandbox = Get-TestTrashSandbox
    }

    AfterAll {
        Clear-TestSandbox -Path $script:mountSandbox
    }

    It 'picks the longest mount point' {
        $expected = [IO.Path]::GetFullPath('/home/u')
        $mount = InModuleScope Vacate {
            Select-VacateTrashMountPoint -Path '/home/u/x' -MountPoint @('/', '/home', '/home/u')
        }
        $mount | Should -Be $expected
    }

    It 'respects a path-segment boundary' {
        $expected = [IO.Path]::GetFullPath('/home')
        $mount = InModuleScope Vacate {
            Select-VacateTrashMountPoint -Path '/home/username/x' -MountPoint @('/home/user', '/home')
        }
        $mount | Should -Be $expected
    }

    It 'rejects a path with no matching mount point' {
        {
            InModuleScope Vacate {
                Select-VacateTrashMountPoint -Path '/home/u/x' -MountPoint @('/mnt/usb')
            }
        } | Should -Throw -ExpectedMessage '*no mount point*'
    }

    It 'accepts two paths on the same mount' {
        $same = InModuleScope Vacate {
            Test-VacateTrashSameDevice -PathA '/home/u/a' -PathB '/home/u/b' -MountPoint @('/', '/home/u')
        }
        $same | Should -BeTrue
    }

    It 'rejects two paths on different mounts' {
        $same = InModuleScope Vacate {
            Test-VacateTrashSameDevice -PathA '/home/u/a' -PathB '/mnt/usb/b' -MountPoint @('/', '/home/u', '/mnt/usb')
        }
        $same | Should -BeFalse
    }

    It 'sees the real environment as one device for a temp folder' -Skip:(-not $script:onLinux) {
        $same = InModuleScope Vacate -Parameters @{ A = $script:mountSandbox } {
            param($A)
            Test-VacateTrashSameDevice -PathA $A -PathB $A
        }
        $same | Should -BeTrue
    }

    It 'decodes findmnt hex escapes in a mount point' {
        $decoded = InModuleScope Vacate { ConvertFrom-VacateTrashMountEscape -Value '/media/u/my\x20disk' }
        $decoded | Should -Be '/media/u/my disk'
    }

    It 'returns nothing for a mount point without escapes' {
        $decoded = InModuleScope Vacate { ConvertFrom-VacateTrashMountEscape -Value '/media/u/disk' }
        $decoded | Should -BeNullOrEmpty
    }

    It 'lists both spellings of an escaped mount point from the system query' {
        $list = InModuleScope Vacate {
            Mock Invoke-VacateSystemQuery {
                return [pscustomobject]@{ Name = 'mounts'; Status = 'ok'; Value = @(
                        [pscustomobject]@{ target = '/'; source = '/dev/sda1'; fstype = 'ext4' },
                        [pscustomobject]@{ target = '/media/u/my\x20disk'; source = '/dev/sdb1'; fstype = 'vfat' }
                    ); Message = $null }
            }
            Get-VacateTrashMountList
        }
        @($list) | Should -Contain '/'
        @($list) | Should -Contain '/media/u/my disk'
        @($list) | Should -Contain '/media/u/my\x20disk'
    }

    It 'throws when the mount list is unavailable' {
        {
            InModuleScope Vacate {
                Mock Invoke-VacateSystemQuery {
                    return [pscustomobject]@{ Name = 'mounts'; Status = 'unavailable'; Value = $null; Message = 'x' }
                }
                Get-VacateTrashMountList
            }
        } | Should -Throw -ExpectedMessage '*cannot determine the file system*'
    }

    It 'treats a path below an escaped mount as a different device' {
        $same = InModuleScope Vacate {
            Mock Invoke-VacateSystemQuery {
                return [pscustomobject]@{ Name = 'mounts'; Status = 'ok'; Value = @(
                        [pscustomobject]@{ target = '/'; source = '/dev/sda1'; fstype = 'ext4' },
                        [pscustomobject]@{ target = '/home/u/my\x20disk'; source = '/dev/sdb1'; fstype = 'vfat' }
                    ); Message = $null }
            }
            Test-VacateTrashSameDevice -PathA '/home/u/my disk/a.txt' -PathB '/home/u/.local/share/Trash'
        }
        $same | Should -BeFalse
    }
}

Describe 'Move-VacateItemToTrashLinux' {
    BeforeAll {
        # Windows has no findmnt: give the logic tests one mount, the temp drive root.
        # On Linux the real mount list from the system query is used.
        if (-not $script:onLinux) {
            Mock -ModuleName Vacate Get-VacateTrashMountList { return @([IO.Path]::GetPathRoot([IO.Path]::GetTempPath())) }
        }
    }

    BeforeEach {
        $script:sandbox = Get-TestTrashSandbox
        $script:trashRoot = Join-Path $script:sandbox 'Trash'
        $script:sourceDir = Join-Path $script:sandbox 'source'
        [void][IO.Directory]::CreateDirectory($script:sourceDir)
    }

    AfterEach {
        Clear-TestSandbox -Path $script:sandbox
    }

    It 'moves a file and writes the information file' {
        $source = Join-Path $script:sourceDir 'report.txt'
        [IO.File]::WriteAllText($source, 'payload')

        $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        $result.error | Should -BeNullOrEmpty
        ($result.PSObject.Properties.Name -join ',') | Should -Be 'ok,trashLocation,error'
        [IO.File]::Exists($source) | Should -BeFalse
        [IO.File]::Exists($result.trashLocation) | Should -BeTrue
        [IO.File]::ReadAllText($result.trashLocation) | Should -Be 'payload'

        $infoPath = Join-Path (Join-Path $script:trashRoot 'info') 'report.txt.trashinfo'
        [IO.File]::Exists($infoPath) | Should -BeTrue
        $info = Get-TestTrashInfo -Path $infoPath
        $info.path | Should -Be $source
        $info.deletionDate | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
        $stamp = [datetime]::ParseExact($info.deletionDate, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        [math]::Abs(($stamp - [datetime]::Now).TotalMinutes) | Should -BeLessThan 10
    }

    It 'creates Trash, files and info when the root does not exist' {
        $source = Join-Path $script:sourceDir 'new.txt'
        [IO.File]::WriteAllText($source, 'x')

        $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.Directory]::Exists($script:trashRoot) | Should -BeTrue
        [IO.Directory]::Exists((Join-Path $script:trashRoot 'files')) | Should -BeTrue
        [IO.Directory]::Exists((Join-Path $script:trashRoot 'info')) | Should -BeTrue
    }

    It 'moves a folder with its contents' {
        $source = Join-Path $script:sourceDir 'My Folder'
        [void][IO.Directory]::CreateDirectory($source)
        [IO.File]::WriteAllText((Join-Path $source 'child.txt'), 'inside')

        $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.Path]::GetFileName($result.trashLocation) | Should -Be 'My Folder'
        [IO.Directory]::Exists($source) | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $result.trashLocation 'child.txt')) | Should -Be 'inside'
        $infoPath = Join-Path (Join-Path $script:trashRoot 'info') 'My Folder.trashinfo'
        (Get-TestTrashInfo -Path $infoPath).path | Should -Be $source
    }

    It 'gives a second item with the same name a new name' {
        $one = Join-Path $script:sourceDir 'one'
        $two = Join-Path $script:sourceDir 'two'
        [void][IO.Directory]::CreateDirectory($one)
        [void][IO.Directory]::CreateDirectory($two)
        $first = Join-Path $one 'report.txt'
        $second = Join-Path $two 'report.txt'
        [IO.File]::WriteAllText($first, 'first')
        [IO.File]::WriteAllText($second, 'second')

        $resultOne = Invoke-TestTrashMove -Path $first -TrashRoot $script:trashRoot
        $resultTwo = Invoke-TestTrashMove -Path $second -TrashRoot $script:trashRoot

        $resultOne.ok | Should -BeTrue
        $resultTwo.ok | Should -BeTrue
        [IO.Path]::GetFileName($resultOne.trashLocation) | Should -Be 'report.txt'
        [IO.Path]::GetFileName($resultTwo.trashLocation) | Should -Be 'report.2.txt'
        [IO.File]::ReadAllText($resultOne.trashLocation) | Should -Be 'first'
        [IO.File]::ReadAllText($resultTwo.trashLocation) | Should -Be 'second'

        $infoTwo = Join-Path (Join-Path $script:trashRoot 'info') 'report.2.txt.trashinfo'
        (Get-TestTrashInfo -Path $infoTwo).path | Should -Be $second
        [IO.File]::Exists((Join-Path (Join-Path $script:trashRoot 'info') 'report.txt.trashinfo')) | Should -BeTrue
    }

    It 'gives a second folder with the same name a new name' {
        $one = Join-Path $script:sourceDir 'one'
        $two = Join-Path $script:sourceDir 'two'
        foreach ($parent in @($one, $two)) {
            [void][IO.Directory]::CreateDirectory((Join-Path $parent 'archive'))
            [IO.File]::WriteAllText((Join-Path (Join-Path $parent 'archive') 'child.txt'), $parent)
        }

        $first = Invoke-TestTrashMove -Path (Join-Path $one 'archive') -TrashRoot $script:trashRoot
        $second = Invoke-TestTrashMove -Path (Join-Path $two 'archive') -TrashRoot $script:trashRoot

        $first.ok | Should -BeTrue
        $second.ok | Should -BeTrue
        [IO.Path]::GetFileName($first.trashLocation) | Should -Be 'archive'
        [IO.Path]::GetFileName($second.trashLocation) | Should -Be 'archive.2'
        [IO.File]::ReadAllText((Join-Path $first.trashLocation 'child.txt')) | Should -Be $one
        [IO.File]::ReadAllText((Join-Path $second.trashLocation 'child.txt')) | Should -Be $two
    }

    It 'does not reuse a stale information file' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'files'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'info'))
        $stale = Join-Path (Join-Path $script:trashRoot 'info') 'notes.txt.trashinfo'
        [IO.File]::WriteAllText($stale, 'keep me')
        $source = Join-Path $script:sourceDir 'notes.txt'
        [IO.File]::WriteAllText($source, 'new')

        $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.Path]::GetFileName($result.trashLocation) | Should -Be 'notes.2.txt'
        [IO.File]::ReadAllText($stale) | Should -Be 'keep me'
    }

    It 'reports a missing item and leaves no information file' {
        $missing = Join-Path $script:sourceDir 'nope.txt'

        $result = Invoke-TestTrashMove -Path $missing -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.trashLocation | Should -BeNullOrEmpty
        $result.error | Should -Match '^trash: item not found'
        [IO.Directory]::Exists($script:trashRoot) | Should -BeFalse
    }

    It 'refuses a relative path' {
        $result = Invoke-TestTrashMove -Path 'relative.txt' -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'not absolute'
    }

    It 'refuses to trash the Trash folder itself' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'files'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'info'))

        $result = Invoke-TestTrashMove -Path $script:trashRoot -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'the Trash folder'
    }

    It 'refuses to trash an item inside the Trash folder' {
        $inside = Join-Path (Join-Path $script:trashRoot 'files') 'old.txt'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'files'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'info'))
        [IO.File]::WriteAllText($inside, 'x')

        $result = Invoke-TestTrashMove -Path $inside -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'inside the Trash folder'
        [IO.File]::Exists($inside) | Should -BeTrue
    }

    It 'refuses to trash a folder that contains the Trash' {
        $outer = Join-Path $script:sandbox 'outer'
        $innerTrash = Join-Path $outer 'Trash'
        [void][IO.Directory]::CreateDirectory((Join-Path $innerTrash 'files'))
        [void][IO.Directory]::CreateDirectory((Join-Path $innerTrash 'info'))

        $result = Invoke-TestTrashMove -Path $outer -TrashRoot $innerTrash

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'contains the Trash'
        [IO.Directory]::Exists($outer) | Should -BeTrue
    }

    It 'refuses a different file system' {
        $source = Join-Path $script:sourceDir 'keep.txt'
        [IO.File]::WriteAllText($source, 'x')

        $result = InModuleScope Vacate -Parameters @{ P = $source; R = $script:trashRoot } {
            param($P, $R)
            Mock Test-VacateTrashSameDevice { return $false }
            Move-VacateItemToTrashLinux -Path $P -TrashRoot $R
        }

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'different file systems'
        [IO.File]::Exists($source) | Should -BeTrue
        [IO.Directory]::Exists($script:trashRoot) | Should -BeFalse
    }

    It 'refuses a different file system from injected mount data' {
        $source = Join-Path $script:sourceDir 'keep.txt'
        [IO.File]::WriteAllText($source, 'x')

        $result = InModuleScope Vacate -Parameters @{ P = $source; R = $script:trashRoot; S = $script:sourceDir } {
            param($P, $R, $S)
            $script:testMounts = @([IO.Path]::GetPathRoot($S), $S)
            Mock Get-VacateTrashMountList { return $script:testMounts }
            Move-VacateItemToTrashLinux -Path $P -TrashRoot $R
        }

        $result.ok | Should -BeFalse
        $result.trashLocation | Should -BeNullOrEmpty
        $result.error | Should -Match 'different file systems'
        [IO.File]::Exists($source) | Should -BeTrue
        [IO.Directory]::Exists($script:trashRoot) | Should -BeFalse
    }

    It 'refuses when the mount list cannot be read' {
        $source = Join-Path $script:sourceDir 'keep.txt'
        [IO.File]::WriteAllText($source, 'x')

        $result = InModuleScope Vacate -Parameters @{ P = $source; R = $script:trashRoot } {
            param($P, $R)
            Mock Get-VacateTrashMountList { throw 'trash: cannot determine the file system of the item (mount list timeout); refusing to move' }
            Move-VacateItemToTrashLinux -Path $P -TrashRoot $R
        }

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'cannot determine the file system'
        [IO.File]::Exists($source) | Should -BeTrue
        [IO.Directory]::Exists($script:trashRoot) | Should -BeFalse
    }

    It 'never overwrites an information file that appears before writing' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'files'))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:trashRoot 'info'))
        $existing = Join-Path (Join-Path $script:trashRoot 'info') 'raced.txt.trashinfo'
        [IO.File]::WriteAllText($existing, 'keep me')
        $source = Join-Path $script:sourceDir 'raced.txt'
        [IO.File]::WriteAllText($source, 'x')

        $result = InModuleScope Vacate -Parameters @{ P = $source; R = $script:trashRoot } {
            param($P, $R)
            # Simulates another process taking the name after the free-name search.
            Mock Find-VacateTrashFreeName { return 'raced.txt' }
            Move-VacateItemToTrashLinux -Path $P -TrashRoot $R
        }

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'taken while preparing'
        [IO.File]::ReadAllText($existing) | Should -Be 'keep me'
        [IO.File]::Exists($source) | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $script:trashRoot 'files') -Force).Count | Should -Be 0
    }

    It 'removes the information file when the move fails (file in use)' -Skip:(-not $script:onWindows) {
        $source = Join-Path $script:sourceDir 'busy.txt'
        [IO.File]::WriteAllText($source, 'x')
        $handle = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot
        }
        finally {
            $handle.Dispose()
        }

        $result.ok | Should -BeFalse
        $result.trashLocation | Should -BeNullOrEmpty
        [IO.File]::Exists($source) | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $script:trashRoot 'info') -Force).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $script:trashRoot 'files') -Force).Count | Should -Be 0
    }

    It 'refuses an item below a symbolic link' -Skip:(-not $script:onLinux) {
        $real = Join-Path $script:sandbox 'real'
        [void][IO.Directory]::CreateDirectory($real)
        [IO.File]::WriteAllText((Join-Path $real 'keep.txt'), 'x')
        $linked = Join-Path $script:sandbox 'linked'
        [void][IO.Directory]::CreateSymbolicLink($linked, $real)

        $result = Invoke-TestTrashMove -Path (Join-Path $linked 'keep.txt') -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'below a link'
        [IO.File]::Exists((Join-Path $real 'keep.txt')) | Should -BeTrue
    }

    It 'moves and restores names with a space, a percent sign and a newline' -Skip:(-not $script:onLinux) {
        foreach ($name in @('a b.txt', '100%.txt', ('line' + [char]10 + 'Path=x'))) {
            $source = Join-Path $script:sourceDir $name
            [IO.File]::WriteAllText($source, $name)

            $moved = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot
            $moved.ok | Should -BeTrue
            $infoPath = Join-Path (Join-Path $script:trashRoot 'info') ([IO.Path]::GetFileName($moved.trashLocation) + '.trashinfo')
            $raw = [IO.File]::ReadAllText($infoPath)
            $lines = $raw.Split([char]10)
            $lines.Count | Should -Be 4
            $lines[1] | Should -Match '^Path=[A-Za-z0-9%/._~-]+$'
            (Get-TestTrashInfo -Path $infoPath).path | Should -Be $source

            $restored = Invoke-TestTrashRestore -TrashLocation $moved.trashLocation -OriginalPath $source -TrashRoot $script:trashRoot
            $restored.ok | Should -BeTrue
            [IO.File]::ReadAllText($source) | Should -Be $name
            [IO.File]::Exists($infoPath) | Should -BeFalse
        }
    }

    It 'removes the information file when the move fails' -Skip:(-not $script:onLinux -or [Environment]::UserName -eq 'root') {
        $locked = Join-Path $script:sourceDir 'locked'
        [void][IO.Directory]::CreateDirectory($locked)
        $source = Join-Path $locked 'stuck.txt'
        [IO.File]::WriteAllText($source, 'x')
        $lockedMode = [enum]::Parse([type]'System.IO.UnixFileMode', 'UserRead, UserExecute')
        $openMode = [enum]::Parse([type]'System.IO.UnixFileMode', 'UserRead, UserWrite, UserExecute')
        [IO.File]::SetUnixFileMode($locked, $lockedMode)
        try {
            $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot
        }
        finally {
            [IO.File]::SetUnixFileMode($locked, $openMode)
        }

        $result.ok | Should -BeFalse
        [IO.File]::Exists($source) | Should -BeTrue
        $infoFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:trashRoot 'info') -File -Force)
        $infoFiles.Count | Should -Be 0
    }

    It 'refuses a symlinked trash root' -Skip:(-not $script:onLinux) {
        $target = Join-Path $script:sandbox 'elsewhere'
        [void][IO.Directory]::CreateDirectory($target)
        [void][IO.Directory]::CreateSymbolicLink($script:trashRoot, $target)
        $source = Join-Path $script:sourceDir 'keep.txt'
        [IO.File]::WriteAllText($source, 'x')

        $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'refusing a link'
        [IO.File]::Exists($source) | Should -BeTrue
    }

    It 'moves a dangling symlink without following it' -Skip:(-not $script:onLinux) {
        $source = Join-Path $script:sourceDir 'dangling'
        [void][IO.File]::CreateSymbolicLink($source, (Join-Path $script:sourceDir 'missing-target'))

        $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.File]::Exists($result.trashLocation) | Should -BeTrue
        $infoPath = Join-Path (Join-Path $script:trashRoot 'info') 'dangling.trashinfo'
        (Get-TestTrashInfo -Path $infoPath).path | Should -Be $source
    }

    It 'moves a symbolic link to a folder without moving the target' -Skip:(-not $script:onLinux) {
        $target = Join-Path $script:sourceDir 'target'
        [void][IO.Directory]::CreateDirectory($target)
        [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'keep')
        $source = Join-Path $script:sourceDir 'link'
        [void][IO.Directory]::CreateSymbolicLink($source, $target)

        $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.File]::Exists((Join-Path $target 'keep.txt')) | Should -BeTrue
        [IO.Directory]::Exists($source) | Should -BeFalse
        [IO.Directory]::Exists($result.trashLocation) | Should -BeTrue
        $movedAttributes = [IO.File]::GetAttributes($result.trashLocation)
        ($movedAttributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        [IO.Directory]::Exists((Join-Path (Join-Path $script:trashRoot 'files') 'target')) | Should -BeFalse

        $restored = Invoke-TestTrashRestore -TrashLocation $result.trashLocation -OriginalPath $source -TrashRoot $script:trashRoot
        $restored.ok | Should -BeTrue
        ([IO.File]::GetAttributes($source) -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        [IO.File]::ReadAllText((Join-Path $target 'keep.txt')) | Should -Be 'keep'
    }
}

Describe 'Restore-VacateItemFromTrashLinux' {
    BeforeEach {
        $script:sandbox = Get-TestTrashSandbox
        $script:trashRoot = Join-Path $script:sandbox 'Trash'
        $script:sourceDir = Join-Path $script:sandbox 'source'
        [void][IO.Directory]::CreateDirectory($script:sourceDir)
    }

    AfterEach {
        Clear-TestSandbox -Path $script:sandbox
    }

    BeforeAll {
        if (-not $script:onLinux) {
            Mock -ModuleName Vacate Get-VacateTrashMountList { return @([IO.Path]::GetPathRoot([IO.Path]::GetTempPath())) }
        }

        function Get-TestMovedItem {
            param([string]$Name = 'report.txt', [string]$Content = 'payload')
            $source = Join-Path $script:sourceDir $Name
            [IO.File]::WriteAllText($source, $Content)
            $result = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot
            if (-not $result.ok) { throw ('test setup move failed: ' + $result.error) }
            return [pscustomobject]@{ source = $source; moved = $result }
        }

        function Get-TestInfoPathFor {
            param([string]$TrashLocation)
            $name = [IO.Path]::GetFileName($TrashLocation)
            return (Join-Path (Join-Path $script:trashRoot 'info') ($name + '.trashinfo'))
        }
    }

    It 'restores a file and removes its information file' {
        $setup = Get-TestMovedItem
        $infoPath = Get-TestInfoPathFor -TrashLocation $setup.moved.trashLocation

        $result = Invoke-TestTrashRestore -TrashLocation $setup.moved.trashLocation -OriginalPath $setup.source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        $result.error | Should -BeNullOrEmpty
        ($result.PSObject.Properties.Name -join ',') | Should -Be 'ok,error'
        [IO.File]::Exists($setup.source) | Should -BeTrue
        [IO.File]::ReadAllText($setup.source) | Should -Be 'payload'
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeFalse
        [IO.File]::Exists($infoPath) | Should -BeFalse
    }

    It 'restores a folder with its contents' {
        $source = Join-Path $script:sourceDir 'folder'
        [void][IO.Directory]::CreateDirectory($source)
        [IO.File]::WriteAllText((Join-Path $source 'child.txt'), 'inside')
        $moved = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result = Invoke-TestTrashRestore -TrashLocation $moved.trashLocation -OriginalPath $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.Directory]::Exists($source) | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $source 'child.txt')) | Should -Be 'inside'
    }

    It 'recreates a missing parent folder' {
        $deep = Join-Path $script:sourceDir 'deep'
        [void][IO.Directory]::CreateDirectory($deep)
        $source = Join-Path $deep 'item.txt'
        [IO.File]::WriteAllText($source, 'x')
        $moved = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot
        [IO.Directory]::Delete($deep)

        $result = Invoke-TestTrashRestore -TrashLocation $moved.trashLocation -OriginalPath $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.Directory]::Exists($deep) | Should -BeTrue
        [IO.File]::Exists($source) | Should -BeTrue
    }

    It 'refuses when the original path exists' {
        $setup = Get-TestMovedItem
        [IO.File]::WriteAllText($setup.source, 'newer')
        $infoPath = Get-TestInfoPathFor -TrashLocation $setup.moved.trashLocation

        $result = Invoke-TestTrashRestore -TrashLocation $setup.moved.trashLocation -OriginalPath $setup.source -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'already exists'
        [IO.File]::ReadAllText($setup.source) | Should -Be 'newer'
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeTrue
        [IO.File]::Exists($infoPath) | Should -BeTrue
    }

    It 'refuses when the information file is missing' {
        $setup = Get-TestMovedItem
        $infoPath = Get-TestInfoPathFor -TrashLocation $setup.moved.trashLocation
        [IO.File]::Delete($infoPath)

        $result = Invoke-TestTrashRestore -TrashLocation $setup.moved.trashLocation -OriginalPath $setup.source -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'is missing'
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeTrue
        [IO.File]::Exists($setup.source) | Should -BeFalse
    }

    It 'refuses when the information file names a different path' {
        $setup = Get-TestMovedItem
        $infoPath = Get-TestInfoPathFor -TrashLocation $setup.moved.trashLocation
        $other = Join-Path $script:sandbox 'other.txt'
        $encoded = Get-TestTrashEncode -Path $other
        [IO.File]::WriteAllText($infoPath, "[Trash Info]`nPath=$encoded`nDeletionDate=2026-01-02T03:04:05`n")

        $result = Invoke-TestTrashRestore -TrashLocation $setup.moved.trashLocation -OriginalPath $setup.source -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'different original path'
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeTrue
        [IO.File]::Exists($setup.source) | Should -BeFalse
    }

    It 'refuses a malformed information file' {
        $setup = Get-TestMovedItem
        $infoPath = Get-TestInfoPathFor -TrashLocation $setup.moved.trashLocation
        [IO.File]::WriteAllText($infoPath, "[Nope]`nPath=/x`n")

        $result = Invoke-TestTrashRestore -TrashLocation $setup.moved.trashLocation -OriginalPath $setup.source -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'does not start with'
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeTrue
    }

    It 'refuses a trash location outside the expected root' {
        $setup = Get-TestMovedItem
        $otherRoot = Join-Path $script:sandbox 'Other'

        $result = Invoke-TestTrashRestore -TrashLocation $setup.moved.trashLocation -OriginalPath $setup.source -TrashRoot $otherRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'outside the expected trash root'
    }

    It 'refuses to restore into the Trash folder' {
        $setup = Get-TestMovedItem
        $target = Join-Path (Join-Path $script:trashRoot 'files') 'back.txt'

        $result = Invoke-TestTrashRestore -TrashLocation $setup.moved.trashLocation -OriginalPath $target -TrashRoot $script:trashRoot

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'into the Trash folder'
    }

    It 'refuses a different file system' {
        $setup = Get-TestMovedItem

        $result = InModuleScope Vacate -Parameters @{ L = $setup.moved.trashLocation; O = $setup.source; R = $script:trashRoot } {
            param($L, $O, $R)
            Mock Test-VacateTrashSameDevice { return $false }
            Restore-VacateItemFromTrashLinux -TrashLocation $L -OriginalPath $O -TrashRoot $R
        }

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'different file systems'
        [IO.File]::Exists($setup.source) | Should -BeFalse
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeTrue
    }

    It 'refuses a different file system from injected mount data' {
        $setup = Get-TestMovedItem

        $result = InModuleScope Vacate -Parameters @{ L = $setup.moved.trashLocation; O = $setup.source; R = $script:trashRoot; S = $script:sourceDir } {
            param($L, $O, $R, $S)
            $script:testMounts = @([IO.Path]::GetPathRoot($S), $S)
            Mock Get-VacateTrashMountList { return $script:testMounts }
            Restore-VacateItemFromTrashLinux -TrashLocation $L -OriginalPath $O -TrashRoot $R
        }

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'different file systems'
        [IO.File]::Exists($setup.source) | Should -BeFalse
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeTrue
    }

    It 'refuses a location outside the home trash when no root is injected' {
        $setup = Get-TestMovedItem

        $result = InModuleScope Vacate -Parameters @{ L = $setup.moved.trashLocation; O = $setup.source } {
            param($L, $O)
            Mock Get-VacateEnvironmentSnapshot { return @{ HOME = '/home/vacate-test-user'; XDG_DATA_HOME = '' } }
            Restore-VacateItemFromTrashLinux -TrashLocation $L -OriginalPath $O
        }

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'outside the expected trash root'
        [IO.File]::Exists($setup.moved.trashLocation) | Should -BeTrue
    }

    It 'restores a dangling symlink as a link' -Skip:(-not $script:onLinux) {
        $source = Join-Path $script:sourceDir 'dangling'
        [void][IO.File]::CreateSymbolicLink($source, (Join-Path $script:sourceDir 'missing-target'))
        $moved = Invoke-TestTrashMove -Path $source -TrashRoot $script:trashRoot

        $result = Invoke-TestTrashRestore -TrashLocation $moved.trashLocation -OriginalPath $source -TrashRoot $script:trashRoot

        $result.ok | Should -BeTrue
        [IO.File]::Exists($source) | Should -BeTrue
    }
}

Describe 'Get-VacateTrashRootPath' {
    It 'uses an absolute XDG_DATA_HOME' {
        $root = InModuleScope Vacate -Parameters @{ E = @{ XDG_DATA_HOME = '/xdg/data'; HOME = '/home/u' } } {
            param($E)
            Get-VacateTrashRootPath -TrashRoot '' -Environment $E
        }
        $root | Should -Be '/xdg/data/Trash'
    }

    It 'ignores a relative XDG_DATA_HOME' {
        $root = InModuleScope Vacate -Parameters @{ E = @{ XDG_DATA_HOME = 'relative/data'; HOME = '/home/u' } } {
            param($E)
            Get-VacateTrashRootPath -TrashRoot '' -Environment $E
        }
        $root | Should -Be '/home/u/.local/share/Trash'
    }

    It 'falls back to HOME/.local/share when XDG_DATA_HOME is empty' {
        $root = InModuleScope Vacate -Parameters @{ E = @{ XDG_DATA_HOME = ''; HOME = '/home/u' } } {
            param($E)
            Get-VacateTrashRootPath -TrashRoot '' -Environment $E
        }
        $root | Should -Be '/home/u/.local/share/Trash'
    }

    It 'normalizes a trailing separator' {
        $root = InModuleScope Vacate -Parameters @{ E = @{ XDG_DATA_HOME = '/xdg/data/'; HOME = '/home/u' } } {
            param($E)
            Get-VacateTrashRootPath -TrashRoot '' -Environment $E
        }
        $root | Should -Be '/xdg/data/Trash'
    }

    It 'rejects an environment with no usable home' {
        {
            InModuleScope Vacate -Parameters @{ E = @{ XDG_DATA_HOME = 'relative'; HOME = 'relative/home' } } {
                param($E)
                Get-VacateTrashRootPath -TrashRoot '' -Environment $E
            }
        } | Should -Throw -ExpectedMessage '*cannot resolve the home trash*'
    }

    It 'returns an injected root unchanged after normalization' {
        $explicit = Join-Path ([IO.Path]::GetTempPath()) ('vacate-trash-root-' + [guid]::NewGuid().ToString('N'))
        $root = InModuleScope Vacate -Parameters @{ T = $explicit } {
            param($T)
            Get-VacateTrashRootPath -TrashRoot $T
        }
        $root | Should -Be ([IO.Path]::GetFullPath($explicit))
    }

    It 'rejects a relative injected root' {
        {
            InModuleScope Vacate {
                Get-VacateTrashRootPath -TrashRoot 'relative'
            }
        } | Should -Throw -ExpectedMessage '*not absolute*'
    }
}
