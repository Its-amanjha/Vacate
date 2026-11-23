# Unit tests for the macOS Trash mover.
# Every move uses a temporary injected Trash root, so no real Trash is ever touched.
# The logic is plain .NET, so these tests run on Windows, Linux and macOS.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force
    # Also load the mover into this test scope: it is self-contained, and calling it directly
    # avoids the large InModuleScope overhead on Windows PowerShell 5.1.
    . (Join-Path $PSScriptRoot '../../src/Vacate/Private/TrashMacOS.ps1')
    $script:testBase = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'vacate-trash-macos-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:testBase)

    function Get-TestLayout {
        param([string]$Name)
        $caseDir = [IO.Path]::Combine($script:testBase, $Name)
        $sourceDir = [IO.Path]::Combine($caseDir, 'from')
        $trashDir = [IO.Path]::Combine($caseDir, 'trash')
        [void][IO.Directory]::CreateDirectory($sourceDir)
        [void][IO.Directory]::CreateDirectory($trashDir)
        return [pscustomobject]@{ CaseDir = $caseDir; SourceDir = $sourceDir; TrashDir = $trashDir }
    }

    function Get-TestFile {
        param([string]$Directory, [string]$Name, [string]$Text = 'vacate fixture')
        $path = [IO.Path]::Combine($Directory, $Name)
        [IO.File]::WriteAllText($path, $Text)
        return $path
    }

    function Get-OtherVolumeTrashRoot {
        # A path that is guaranteed to be on a different volume key than a temp folder.
        if ([IO.Path]::DirectorySeparatorChar -eq '\') { return 'D:\vacate-cross-volume-trash' }
        return '/Volumes/OtherVolume/.Trash'
    }
}

AfterAll {
    if ([IO.Directory]::Exists($script:testBase)) {
        [IO.Directory]::Delete($script:testBase, $true)
    }
}

Describe 'Move-VacateItemToTrashMacOS' {
    It 'moves a file into the injected Trash and reports the new location' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $file = Get-TestFile -Directory $layout.SourceDir -Name 'notes.txt'
        $result = Move-VacateItemToTrashMacOS -Path $file -TrashRoot $layout.TrashDir
        $result.ok | Should -BeTrue
        $result.error | Should -Be ''
        $result.trashLocation | Should -Be ([IO.Path]::Combine($layout.TrashDir, 'notes.txt'))
        [IO.File]::Exists($file) | Should -BeFalse
        [IO.File]::Exists($result.trashLocation) | Should -BeTrue
    }

    It 'moves a folder with its contents into the injected Trash' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $folder = [IO.Path]::Combine($layout.SourceDir, 'Album')
        [void][IO.Directory]::CreateDirectory($folder)
        [void](Get-TestFile -Directory $folder -Name 'photo.jpg')
        $result = Move-VacateItemToTrashMacOS -Path $folder -TrashRoot $layout.TrashDir
        $result.ok | Should -BeTrue
        $result.trashLocation | Should -Be ([IO.Path]::Combine($layout.TrashDir, 'Album'))
        [IO.Directory]::Exists($folder) | Should -BeFalse
        [IO.Directory]::Exists($result.trashLocation) | Should -BeTrue
        [IO.File]::Exists([IO.Path]::Combine($result.trashLocation, 'photo.jpg')) | Should -BeTrue
    }

    It 'never overwrites: a collision gets a number before the extension' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $file = Get-TestFile -Directory $layout.SourceDir -Name 'notes.txt' -Text 'incoming'
        $existing = Get-TestFile -Directory $layout.TrashDir -Name 'notes.txt' -Text 'kept'
        $result = Move-VacateItemToTrashMacOS -Path $file -TrashRoot $layout.TrashDir
        $result.ok | Should -BeTrue
        $result.trashLocation | Should -Be ([IO.Path]::Combine($layout.TrashDir, 'notes 2.txt'))
        [IO.File]::ReadAllText($existing) | Should -Be 'kept'
        [IO.File]::ReadAllText($result.trashLocation) | Should -Be 'incoming'
    }

    It 'uses the next free number on repeated collisions' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $file = Get-TestFile -Directory $layout.SourceDir -Name 'notes.txt'
        [void](Get-TestFile -Directory $layout.TrashDir -Name 'notes.txt')
        [void](Get-TestFile -Directory $layout.TrashDir -Name 'notes 2.txt')
        $result = Move-VacateItemToTrashMacOS -Path $file -TrashRoot $layout.TrashDir
        $result.ok | Should -BeTrue
        $result.trashLocation | Should -Be ([IO.Path]::Combine($layout.TrashDir, 'notes 3.txt'))
    }

    It 'suffixes an extension-less name and a hidden file without inventing an extension' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        [void](Get-TestFile -Directory $layout.TrashDir -Name 'README')
        [void](Get-TestFile -Directory $layout.TrashDir -Name '.npmrc')
        $readme = Get-TestFile -Directory $layout.SourceDir -Name 'README'
        $npmrc = Get-TestFile -Directory $layout.SourceDir -Name '.npmrc'
        $r1 = Move-VacateItemToTrashMacOS -Path $readme -TrashRoot $layout.TrashDir
        $r2 = Move-VacateItemToTrashMacOS -Path $npmrc -TrashRoot $layout.TrashDir
        $r1.ok | Should -BeTrue
        $r1.trashLocation | Should -Be ([IO.Path]::Combine($layout.TrashDir, 'README 2'))
        $r2.ok | Should -BeTrue
        $r2.trashLocation | Should -Be ([IO.Path]::Combine($layout.TrashDir, '.npmrc 2'))
    }

    It 'refuses a source that does not exist' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $missing = [IO.Path]::Combine($layout.SourceDir, 'gone.txt')
        $result = Move-VacateItemToTrashMacOS -Path $missing -TrashRoot $layout.TrashDir
        $result.ok | Should -BeFalse
        $result.trashLocation | Should -BeNullOrEmpty
        $result.error | Should -Be 'source-missing'
    }

    It 'refuses a cross-volume move before any rename happens' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $file = Get-TestFile -Directory $layout.SourceDir -Name 'other-volume.txt'
        $otherRoot = Get-OtherVolumeTrashRoot
        $result = Move-VacateItemToTrashMacOS -Path $file -TrashRoot $otherRoot
        $result.ok | Should -BeFalse
        $result.error | Should -Be 'cross-volume'
        [IO.File]::Exists($file) | Should -BeTrue
    }

    It 'returns ok=false when the Trash root cannot be created' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $file = Get-TestFile -Directory $layout.SourceDir -Name 'blocked.txt'
        $blockedRoot = Get-TestFile -Directory $layout.CaseDir -Name 'not-a-folder'
        $result = Move-VacateItemToTrashMacOS -Path $file -TrashRoot $blockedRoot
        $result.ok | Should -BeFalse
        $result.error | Should -Match '^trash-unavailable:'
        [IO.File]::Exists($file) | Should -BeTrue
    }
}

Describe 'Restore-VacateItemFromTrashMacOS' {
    It 'restores a moved file to its original path' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $file = Get-TestFile -Directory $layout.SourceDir -Name 'notes.txt' -Text 'round trip'
        $moved = Move-VacateItemToTrashMacOS -Path $file -TrashRoot $layout.TrashDir
        $moved.ok | Should -BeTrue
        $restored = Restore-VacateItemFromTrashMacOS -TrashLocation $moved.trashLocation -OriginalPath $file
        $restored.ok | Should -BeTrue
        $restored.error | Should -Be ''
        [IO.File]::Exists($file) | Should -BeTrue
        [IO.File]::ReadAllText($file) | Should -Be 'round trip'
        [IO.File]::Exists($moved.trashLocation) | Should -BeFalse
    }

    It 'restores a folder to its original path' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $folder = [IO.Path]::Combine($layout.SourceDir, 'Album')
        [void][IO.Directory]::CreateDirectory($folder)
        [void](Get-TestFile -Directory $folder -Name 'photo.jpg')
        $moved = Move-VacateItemToTrashMacOS -Path $folder -TrashRoot $layout.TrashDir
        $moved.ok | Should -BeTrue
        $restored = Restore-VacateItemFromTrashMacOS -TrashLocation $moved.trashLocation -OriginalPath $folder
        $restored.ok | Should -BeTrue
        [IO.Directory]::Exists($folder) | Should -BeTrue
        [IO.File]::Exists([IO.Path]::Combine($folder, 'photo.jpg')) | Should -BeTrue
    }

    It 'refuses to overwrite an original path that already exists' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $original = Get-TestFile -Directory $layout.SourceDir -Name 'notes.txt' -Text 'new'
        $inTrash = Get-TestFile -Directory $layout.TrashDir -Name 'notes 2.txt' -Text 'old'
        $result = Restore-VacateItemFromTrashMacOS -TrashLocation $inTrash -OriginalPath $original
        $result.ok | Should -BeFalse
        $result.error | Should -Be 'destination-exists'
        [IO.File]::ReadAllText($original) | Should -Be 'new'
        [IO.File]::ReadAllText($inTrash) | Should -Be 'old'
    }

    It 'refuses when the Trash item is missing' {
        $layout = Get-TestLayout -Name ([guid]::NewGuid().ToString('N'))
        $missingInTrash = [IO.Path]::Combine($layout.TrashDir, 'not-there.txt')
        $original = [IO.Path]::Combine($layout.SourceDir, 'notes.txt')
        $result = Restore-VacateItemFromTrashMacOS -TrashLocation $missingInTrash -OriginalPath $original
        $result.ok | Should -BeFalse
        $result.error | Should -Be 'trash-item-missing'
    }
}

Describe 'macOS Trash helpers' {
    It 'gives every startup-volume path the same volume key' {
        Get-VacateMacOSVolumeKey -Path '/Users/alice/.Trash' | Should -Be '/'
        Get-VacateMacOSVolumeKey -Path '/private/tmp/vacate' | Should -Be '/'
    }

    It 'gives each /Volumes mount its own volume key' {
        Get-VacateMacOSVolumeKey -Path '/Volumes/Backup/notes.txt' | Should -Be '/Volumes/Backup'
        Get-VacateMacOSVolumeKey -Path '/Volumes/Other/.Trashes/501' | Should -Be '/Volumes/Other'
    }

    It 'gives each Windows drive and UNC share its own volume key' {
        Get-VacateMacOSVolumeKey -Path 'C:\Users\alice\.Trash' | Should -Be 'C:'
        Get-VacateMacOSVolumeKey -Path 'D:\notes.txt' | Should -Be 'D:'
        Get-VacateMacOSVolumeKey -Path '\\server\share\notes.txt' | Should -Be '//server/share'
    }

    It 'builds the default Trash root from the user profile and .Trash' {
        $root = Get-VacateMacOSTrashRootPath
        [IO.Path]::GetFileName($root) | Should -Be '.Trash'
        [IO.Path]::IsPathRooted($root) | Should -BeTrue
    }
}
