<#
.SYNOPSIS
    Smoke-tests a built release ZIP the way a downloader uses it (P5, D61).
.DESCRIPTION
    Unzips the release, checks the MANIFEST and SHA256SUMS, and then runs the extracted copy -
    not the repository - with the current engine as a child process: version, rules validate,
    a short redacted scan and a plan for that run. On Windows it also checks the two launcher
    cases a person hits first: vacate.cmd works, and an unknown command exits 2.

    This is NOT part of the normal suite. The Describe is tagged Release and
    tests/Run-Tests.ps1 excludes that tag. Run it through tests/release/Invoke-ReleaseSmoke.ps1
    with a ZIP path (or VACATE_RELEASE_ZIP); without one, pwsh 7 builds a ZIP into $TestDrive.
.EXAMPLE
    # One ZIP, tested on Windows PowerShell 5.1, pwsh 7 and WSL (same bytes):
    pwsh -NoProfile -File tools/Build-Release.ps1 -Version 0.1.0 -AllowDirty
    $env:VACATE_RELEASE_ZIP = (Resolve-Path dist/vacate-0.1.0.zip).Path
    powershell -NoProfile -File tests/release/Invoke-ReleaseSmoke.ps1
    pwsh -NoProfile -File tests/release/Invoke-ReleaseSmoke.ps1
    wsl -d Ubuntu-24.04 -- env VACATE_RELEASE_ZIP=/mnt/f/vacate/dist/vacate-0.1.0.zip /snap/bin/pwsh -NoProfile -File /mnt/f/vacate/tests/release/Invoke-ReleaseSmoke.ps1
#>
[CmdletBinding()]
param(
    # Path to a built vacate-<version>.zip. Defaults to $env:VACATE_RELEASE_ZIP.
    [string]$ZipPath = $env:VACATE_RELEASE_ZIP
)

BeforeDiscovery {
    $script:onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $script:zipGiven = $ZipPath
    # Without a ZIP the test builds one, which needs git and the builder's own requirement (pwsh 7).
    $script:canBuild = $PSVersionTable.PSEdition -eq 'Core' -and [bool](Get-Command git -ErrorAction SilentlyContinue)
    $script:runnable = [bool]$script:zipGiven -or $script:canBuild
}

Describe 'release ZIP smoke test' -Tag Release -Skip:(-not $script:runnable) {
    BeforeAll {
        # Pester re-reads this file for the run, so resolve the ZIP again here rather than trusting
        # a $script: value set during discovery.
        $script:onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
        $script:zipGiven = if ($ZipPath) { $ZipPath } else { $env:VACATE_RELEASE_ZIP }
        $script:root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $script:engine = (Get-Process -Id $PID).Path
        $script:dest = Join-Path $TestDrive 'unzipped'

        if ($script:zipGiven) {
            if (-not (Test-Path -LiteralPath $script:zipGiven)) { throw "release ZIP not found: $($script:zipGiven)" }
            $script:zip = (Resolve-Path -LiteralPath $script:zipGiven).Path
        }
        else {
            $models = Get-Content -LiteralPath (Join-Path $script:root 'src/Vacate/Models.ps1') -Raw
            if ($models -notmatch "VacateToolVersion\s*=\s*'([^']+)'") { throw 'Tool version not found in src/Vacate/Models.ps1.' }
            $builtVersion = $Matches[1]
            $outDir = Join-Path $TestDrive 'dist'
            & $script:engine -NoProfile -File (Join-Path $script:root 'tools/Build-Release.ps1') -Version $builtVersion -OutDir $outDir -AllowDirty | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'tools/Build-Release.ps1 failed.' }
            $script:zip = Join-Path $outDir "vacate-$builtVersion.zip"
        }

        Expand-Archive -LiteralPath $script:zip -DestinationPath $script:dest -Force
        $script:tops = @(Get-ChildItem -LiteralPath $script:dest)
        $script:folders = @($script:tops | Where-Object { $_.PSIsContainer })
        $script:folder = $null
        $script:version = $null
        if ($script:folders.Count -eq 1 -and $script:folders[0].Name -match '^vacate-(.+)$') {
            $script:folder = $script:folders[0].FullName
            $script:version = $Matches[1]
        }

        # Runs the extracted copy, never the repository, with this engine as a child process.
        function Invoke-VacateCli {
            param([string[]]$CliArgs)
            $engineArgs = @('-NoProfile')
            if ($script:onWindows) { $engineArgs += @('-ExecutionPolicy', 'Bypass') }
            Push-Location -LiteralPath $script:folder
            try {
                $out = & $script:engine @engineArgs -File (Join-Path $script:folder 'vacate.ps1') @CliArgs 2>&1
                $code = $LASTEXITCODE
            }
            finally { Pop-Location }
            [pscustomobject]@{ Code = [int]$code; Text = (@($out) -join "`n") }
        }

        # Snapshot the fresh unzip before the tool writes anything: the manifest must describe
        # exactly these files, and nothing else.
        $script:listed = @()
        $script:mismatches = @()
        $script:onDisk = @()
        $script:runDir = $null
        $script:versionRun = $null
        $script:rulesRun = $null
        $script:scanRun = $null
        $script:planRun = $null
        if ($script:folder) {
            $manifest = Join-Path $script:folder 'MANIFEST.sha256'
            $listed = New-Object System.Collections.Generic.List[string]
            $mismatches = New-Object System.Collections.Generic.List[string]
            if (Test-Path -LiteralPath $manifest) {
                foreach ($line in (Get-Content -LiteralPath $manifest)) {
                    if (-not $line) { continue }
                    $hash, $file = $line -split '  ', 2
                    $listed.Add($file)
                    $full = Join-Path $script:folder $file
                    if (-not (Test-Path -LiteralPath $full)) { $mismatches.Add("MISSING: $file"); continue }
                    if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { $mismatches.Add("CHANGED: $file") }
                }
            }
            $script:listed = @($listed)
            $script:mismatches = @($mismatches)
            $script:onDisk = @(Get-ChildItem -LiteralPath $script:folder -Recurse -File | ForEach-Object {
                    $_.FullName.Substring($script:folder.Length + 1).Replace('\', '/')
                } | Where-Object { $_ -ne 'MANIFEST.sha256' })

            $script:versionRun = Invoke-VacateCli @('version')
            $script:rulesRun = Invoke-VacateCli @('rules', 'validate')
            $script:scanRun = Invoke-VacateCli @('scan', '-Redact', '-BudgetSeconds', '60')
            $runsDir = Join-Path $script:folder 'runs'
            if (Test-Path -LiteralPath $runsDir) {
                $runs = @(Get-ChildItem -LiteralPath $runsDir -Directory | Sort-Object -Property Name)
                if ($runs.Count -gt 0) { $script:runDir = $runs[-1].FullName }
            }
            if ($script:runDir) { $script:planRun = Invoke-VacateCli @('plan', '-Run', $script:runDir) }
        }
    }

    It 'unzips to exactly one top folder vacate-<version>/' {
        $script:folders.Count | Should -Be 1
        @($script:tops | Where-Object { -not $_.PSIsContainer }).Count | Should -Be 0
        $script:version | Should -Match '^\d+\.\d+\.\d+'
    }

    It 'matches MANIFEST.sha256 line for line, and lists every file' {
        Test-Path -LiteralPath (Join-Path $script:folder 'MANIFEST.sha256') | Should -BeTrue
        $script:mismatches.Count | Should -Be 0 -Because ($script:mismatches -join '; ')
        $script:onDisk.Count | Should -BeGreaterThan 0
        $unlisted = @($script:onDisk | Where-Object { $script:listed -notcontains $_ } | Sort-Object)
        $unlisted | Should -BeNullOrEmpty -Because ('not in MANIFEST: ' + ($unlisted -join ', '))
    }

    It 'has a SHA256SUMS next to the ZIP that matches its bytes' {
        $sums = Join-Path (Split-Path -Parent $script:zip) 'SHA256SUMS'
        Test-Path -LiteralPath $sums | Should -BeTrue
        $line = @(Get-Content -LiteralPath $sums)[0]
        $hash, $name = $line -split '  ', 2
        $name | Should -Be (Split-Path -Leaf $script:zip)
        (Get-FileHash -LiteralPath $script:zip -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $hash.ToLowerInvariant()
    }

    It 'prints the version from the extracted copy' {
        $script:versionRun.Code | Should -Be 0
        $script:versionRun.Text | Should -BeExactly ('vacate ' + $script:version)
    }

    It 'validates the rule catalog from the extracted copy' {
        $script:rulesRun.Code | Should -Be 0 -Because $script:rulesRun.Text
        $script:rulesRun.Text | Should -Match 'valid'
    }

    It 'scans from the extracted copy and writes report.html into its own runs folder' {
        $script:scanRun.Code | Should -Be 0 -Because $script:scanRun.Text
        $script:runDir | Should -Not -BeNullOrEmpty
        $script:runDir.StartsWith($script:folder, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:runDir 'report.html') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:runDir 'report.json') | Should -BeTrue
        # The extracted copy writes its run folders inside itself, and nowhere else.
        $stray = @(Get-ChildItem -LiteralPath $script:folder -Recurse -File | ForEach-Object {
                $_.FullName.Substring($script:folder.Length + 1).Replace('\', '/')
            } | Where-Object { $script:listed -notcontains $_ -and $_ -ne 'MANIFEST.sha256' -and -not $_.StartsWith('runs/') })
        $stray | Should -BeNullOrEmpty
    }

    It 'plans for that run from the extracted copy' {
        $script:planRun | Should -Not -BeNullOrEmpty
        $script:planRun.Code | Should -Be 0 -Because $script:planRun.Text
        Test-Path -LiteralPath (Join-Path $script:runDir 'plan.json') | Should -BeTrue
    }

    It 'starts through vacate.cmd and rejects an unknown command with exit 2' -Skip:(-not $script:onWindows) {
        Push-Location -LiteralPath $script:folder
        try {
            $versionOut = & cmd.exe /c 'vacate.cmd version' 2>&1
            $versionCode = $LASTEXITCODE
            $explodeOut = & cmd.exe /c 'vacate.cmd explode' 2>&1
            $explodeCode = $LASTEXITCODE
        }
        finally { Pop-Location }
        $versionCode | Should -Be 0 -Because (@($versionOut) -join "`n")
        (@($versionOut) -join "`n") | Should -Match ([regex]::Escape('vacate ' + $script:version))
        $explodeCode | Should -Be 2 -Because (@($explodeOut) -join "`n")
    }
}
