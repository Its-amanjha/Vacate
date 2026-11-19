# Perf.Tests.ps1 - opt-in performance budget tests.
# PowerShell 5.1 compatible. ASCII only.
#
# Builds a synthetic 50,000-file home under the OS temp folder, points a fake platform
# profile at it and runs the real rule catalog through the engine. These tests are not
# part of the default Run-Tests.ps1 set because building the tree is slow:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/Run-Tests.ps1 -Path tests/perf
#   pwsh -NoProfile -File tests/Run-Tests.ps1 -Path tests/perf

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    $script:platformName = InModuleScope Vacate { Get-VacatePlatform }
    $script:rulesPath = (Resolve-Path (Join-Path $PSScriptRoot '../../src/Vacate/rules')).Path

    # One tree per run, under the platform temp folder (on WSL that is Linux /tmp, not /mnt).
    $script:treeRoot = Join-Path ([IO.Path]::GetTempPath()) ('vacate-perf-' + [guid]::NewGuid().ToString('N'))
    $script:usersRoot = [IO.Path]::Combine($script:treeRoot, 'Users')
    $script:homeDir = [IO.Path]::Combine($script:usersRoot, 'me')
    $script:fileCount = 0

    # Content is irrelevant to a metadata scan; empty files keep the fixture fast while still
    # giving the walker 50,000 real directory entries.
    $script:payload = New-Object 'byte[]' 0

    # Writes Count marker files into Dir and counts them.
    $script:addFiles = {
        param([string]$Dir, [int]$Count, [string]$Prefix)
        [void][IO.Directory]::CreateDirectory($Dir)
        for ($i = 0; $i -lt $Count; $i++) {
            $path = [IO.Path]::Combine($Dir, ($Prefix + $i.ToString('D5') + '.txt'))
            [IO.File]::WriteAllBytes($path, $script:payload)
        }
        $script:fileCount = $script:fileCount + $Count
    }

    # Writes one small marker file and counts it.
    $script:addMarker = {
        param([string]$Path, [string]$Text)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
        [IO.File]::WriteAllText($Path, $Text)
        $script:fileCount = $script:fileCount + 1
    }

    $addFiles = $script:addFiles
    $addMarker = $script:addMarker

    # Time the fixture build separately so the reported scan time stays honest.
    $buildTimer = [Diagnostics.Stopwatch]::StartNew()

    # Desktop: 5,000 files in 10 folders.
    for ($d = 0; $d -lt 10; $d++) {
        & $addFiles ([IO.Path]::Combine($script:homeDir, 'Desktop', ('folder-' + $d.ToString('D2')))) 500 'desk'
    }

    # Documents: 25,000 files in a deep tree (Documents/Projects/2026/project-N/src/module-M).
    for ($p = 0; $p -lt 10; $p++) {
        for ($m = 0; $m -lt 5; $m++) {
            $dir = [IO.Path]::Combine($script:homeDir, 'Documents', 'Projects', '2026', ('project-' + $p.ToString('D2')), 'src', ('module-' + $m.ToString('D2')))
            & $addFiles $dir 500 'doc'
        }
    }

    # Downloads: 10,000 files in 20 folders.
    for ($d = 0; $d -lt 20; $d++) {
        & $addFiles ([IO.Path]::Combine($script:homeDir, 'Downloads', ('download-' + $d.ToString('D2')))) 500 'dl'
    }

    # Fake browser profile: 5,000 Chrome files in the layout the real rules look for.
    if ($script:platformName -eq 'windows') {
        $chromeDefault = [IO.Path]::Combine($script:homeDir, 'AppData', 'Local', 'Google', 'Chrome', 'User Data', 'Default')
    }
    elseif ($script:platformName -eq 'macos') {
        $chromeDefault = [IO.Path]::Combine($script:homeDir, 'Library', 'Application Support', 'Google', 'Chrome', 'Default')
    }
    else {
        $chromeDefault = [IO.Path]::Combine($script:homeDir, '.config', 'google-chrome', 'Default')
    }
    for ($c = 0; $c -lt 10; $c++) {
        $count = 500
        if ($c -eq 9) { $count = 495 }
        & $addFiles ([IO.Path]::Combine($chromeDefault, 'Cache', ('cache-' + $c.ToString('D2')))) $count 'cache'
    }
    foreach ($marker in @('Preferences', 'History', 'Login Data', 'Web Data')) {
        & $addMarker ([IO.Path]::Combine($chromeDefault, $marker)) '{}'
    }
    & $addMarker ([IO.Path]::Combine($chromeDefault, 'Network', 'Cookies')) '{}'

    # Developer folders: 100 .ssh files, 400 each in .aws and .kube, 400 in .config.
    & $addFiles ([IO.Path]::Combine($script:homeDir, '.ssh')) 100 'key'
    for ($d = 0; $d -lt 2; $d++) {
        & $addFiles ([IO.Path]::Combine($script:homeDir, '.aws', ('profile-' + $d.ToString('D2')))) 200 'aws'
        & $addFiles ([IO.Path]::Combine($script:homeDir, '.kube', ('cluster-' + $d.ToString('D2')))) 200 'kube'
        & $addFiles ([IO.Path]::Combine($script:homeDir, '.config', ('app-' + $d.ToString('D2')))) 200 'cfg'
    }

    # Application data: 2,000 files where the platform keeps per-user app state.
    if ($script:platformName -eq 'windows') {
        $appData = [IO.Path]::Combine($script:homeDir, 'AppData', 'Roaming')
    }
    elseif ($script:platformName -eq 'macos') {
        $appData = [IO.Path]::Combine($script:homeDir, 'Library', 'Application Support')
    }
    else {
        $appData = [IO.Path]::Combine($script:homeDir, '.local', 'share')
    }
    for ($d = 0; $d -lt 4; $d++) {
        & $addFiles ([IO.Path]::Combine($appData, ('app-' + $d.ToString('D2')))) 500 'app'
    }

    # Pictures 1,000 and Videos 700 (media folders the real rules recurse into).
    for ($d = 0; $d -lt 2; $d++) {
        & $addFiles ([IO.Path]::Combine($script:homeDir, 'Pictures', ('album-' + $d.ToString('D2')))) 500 'pic'
    }
    & $addFiles ([IO.Path]::Combine($script:homeDir, 'Videos')) 700 'vid'
    $buildTimer.Stop()
    $script:buildSeconds = $buildTimer.Elapsed.TotalSeconds

    # Every platform root points inside the test tree, so the scan never leaves it.
    $script:roots = [ordered]@{}
    $script:roots['HOME'] = $script:homeDir
    $script:roots['USERS'] = $script:usersRoot
    if ($script:platformName -eq 'windows') {
        $script:roots['APPDATA'] = [IO.Path]::Combine($script:homeDir, 'AppData', 'Roaming')
        $script:roots['LOCALAPPDATA'] = [IO.Path]::Combine($script:homeDir, 'AppData', 'Local')
        $script:roots['PROGRAMDATA'] = [IO.Path]::Combine($script:treeRoot, 'ProgramData')
        $script:roots['SYSTEMDRIVE'] = [IO.Path]::Combine($script:treeRoot, 'SystemDrive')
    }
    elseif ($script:platformName -eq 'macos') {
        $script:roots['LIBRARY'] = [IO.Path]::Combine($script:homeDir, 'Library')
        $script:roots['APPLICATIONS'] = [IO.Path]::Combine($script:treeRoot, 'Applications')
        $script:roots['SYSTEM'] = [IO.Path]::Combine($script:treeRoot, 'System')
    }
    else {
        $script:roots['APPLICATIONS'] = [IO.Path]::Combine($script:treeRoot, 'Applications')
        $script:roots['SYSTEM'] = [IO.Path]::Combine($script:treeRoot, 'System')
        $script:roots['XDG_CONFIG'] = [IO.Path]::Combine($script:homeDir, '.config')
        $script:roots['XDG_DATA'] = [IO.Path]::Combine($script:homeDir, '.local', 'share')
        $script:roots['XDG_STATE'] = [IO.Path]::Combine($script:homeDir, '.local', 'state')
        $script:roots['ETC'] = [IO.Path]::Combine($script:treeRoot, 'etc')
        $script:roots['VAR'] = [IO.Path]::Combine($script:treeRoot, 'var')
    }
    foreach ($rootPath in @($script:roots.Values)) { [void][IO.Directory]::CreateDirectory([string]$rootPath) }

    $script:caseSensitive = ($script:platformName -eq 'linux')
    $script:comparison = [StringComparison]::Ordinal
    $script:separator = [char]'/'
    if ($script:platformName -eq 'windows') {
        $script:comparison = [StringComparison]::OrdinalIgnoreCase
        $script:separator = [char]'\'
    }
    elseif ($script:platformName -eq 'macos') {
        $script:comparison = [StringComparison]::OrdinalIgnoreCase
    }

    $script:profile = [pscustomobject][ordered]@{
        Name          = $script:platformName
        CaseSensitive = $script:caseSensitive
        Comparison    = $script:comparison
        Separator     = $script:separator
        Roots         = $script:roots
        HomePath      = $script:homeDir
        UsersRoot     = $script:usersRoot
        UserName      = 'me'
    }

    $script:fileSystem = InModuleScope Vacate { New-VacateFileSystemProvider }
    $script:context = [pscustomobject][ordered]@{
        Platform    = $script:profile
        FileSystem  = $script:fileSystem
        Registry    = $null
        Cim         = $null
        SystemQuery = $null
        Elevated    = $false
        MountPoints = @()
        Exclude     = @()
    }

    $script:ruleSet = InModuleScope Vacate -Parameters @{ P = $script:rulesPath; Pl = $script:platformName } {
        param($P, $Pl)
        Import-VacateRuleSet -Path $P -Platform $Pl
    }

    function Get-TestWalkRule {
        # One recurse rule covering the whole synthetic home. maxEntries equals the model
        # maximum and the tree has more entries than that (files plus directories), so the
        # walk is guaranteed to stop with a truncated trace or a timeout skip.
        param([int]$MaxEntries = 50000)
        $locator = [pscustomobject][ordered]@{
            kind    = 'path'
            root    = 'HOME'
            path    = ''
            match   = 'directories'
            recurse = $true
        }
        return [pscustomobject][ordered]@{
            id               = 'perf.walk-home'
            platforms        = @($script:platformName)
            category         = 'personal-files'
            title            = 'Synthetic home walk'
            whyItMatters     = 'Performance test only; this rule is never shipped.'
            sensitivity      = 'low'
            locator          = $locator
            measure          = @('exists', 'sizeBytes', 'itemCount')
            maxEntries       = $MaxEntries
            requiresElevation = $false
            verifiedOn       = @()
            verified         = $false
            source           = 'tests/perf/Perf.Tests.ps1 performance fixture'
            notes            = $null
        }
    }
}

AfterAll {
    # Clean up even when a test failed.
    if ($null -ne $script:treeRoot -and [IO.Directory]::Exists($script:treeRoot)) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            [IO.Directory]::Delete($script:treeRoot, $true)
        }
        catch {
            Write-Warning ('perf: could not remove the test tree: ' + $_.Exception.Message)
        }
        $timer.Stop()
        Write-Information -MessageData ('PERF cleanup removed the 50k tree in {0:N1} s' -f $timer.Elapsed.TotalSeconds) -InformationAction Continue
    }
}

Describe 'performance: synthetic 50k-file profile' -Tag 'Perf' {
    It 'runs the real catalog within the 120 s budget' {
        @($script:ruleSet.Errors).Count | Should -Be 0 -Because 'the shipped catalog must load before any timing means anything'
        @($script:ruleSet.Rules).Count | Should -BeGreaterThan 0

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $run = InModuleScope Vacate -Parameters @{ R = @($script:ruleSet.Rules); C = $script:context } {
            param($R, $C)
            $inner = [Diagnostics.Stopwatch]::StartNew()
            $engineResult = Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 120
            $inner.Stop()
            return [pscustomobject][ordered]@{ Result = $engineResult; Seconds = $inner.Elapsed.TotalSeconds }
        }
        $stopwatch.Stop()

        $elapsed = [double]$run.Seconds
        $outerElapsed = $stopwatch.Elapsed.TotalSeconds
        $filesPerSecond = [math]::Round($script:fileCount / [math]::Max($elapsed, 0.001), 1)
        $because = ('50k scan: {0:N2} s for {1} files ({2:N1} files/s), budget 120 s; build {3:N1} s; harness {4:N2} s' -f $elapsed, $script:fileCount, $filesPerSecond, $script:buildSeconds, $outerElapsed)
        Write-Information -MessageData ('PERF full-catalog ' + $because) -InformationAction Continue

        @($run.Result.Skips | Where-Object { $_.reason -ceq 'budget' }).Count | Should -Be 0 -Because $because
        @($run.Result.Traces).Count | Should -BeGreaterThan 0 -Because ('the fake profile has data the catalog should find; ' + $because)
        $elapsed | Should -BeLessThan 120 -Because $because
    }
}

Describe 'performance: single rule timeout' -Tag 'Perf' {
    It 'stops one recurse rule inside its 1 s timeout plus slack' {
        $rule = Get-TestWalkRule

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $run = InModuleScope Vacate -Parameters @{ R = @($rule); C = $script:context } {
            param($R, $C)
            $inner = [Diagnostics.Stopwatch]::StartNew()
            $engineResult = Invoke-VacateEngine -Rules $R -Context $C -BudgetSeconds 120 -RuleTimeoutSeconds 1
            $inner.Stop()
            return [pscustomobject][ordered]@{ Result = $engineResult; Seconds = $inner.Elapsed.TotalSeconds }
        }
        $stopwatch.Stop()

        $elapsed = [double]$run.Seconds
        $outerElapsed = $stopwatch.Elapsed.TotalSeconds
        $result = $run.Result
        $timedOut = (@($result.Skips | Where-Object { $_.reason -ceq 'timeout' }).Count -gt 0)
        $truncated = (@($result.Traces | Where-Object { $_.truncated -eq $true }).Count -gt 0)
        $because = ('single rule: {0:N2} s, limit 1 s + 1.5 s slack; timeout skip={1}; truncated trace={2}; harness {3:N2} s' -f $elapsed, $timedOut, $truncated, $outerElapsed)
        Write-Information -MessageData ('PERF single-rule ' + $because) -InformationAction Continue

        @($result.Errors).Count | Should -Be 0 -Because $because
        $elapsed | Should -BeLessThan 2.5 -Because $because
        ($timedOut -or $truncated) | Should -BeTrue -Because $because
    }
}
