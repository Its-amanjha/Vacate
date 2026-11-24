# BuildRelease.Tests.ps1 - the release ZIP is reproducible and holds only product files (D61).

BeforeDiscovery {
    $script:canBuild = $PSVersionTable.PSEdition -eq 'Core' -and [bool](Get-Command git -ErrorAction SilentlyContinue)
}

Describe 'tools/Build-Release.ps1' -Skip:(-not $script:canBuild) {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $script:builder = Join-Path $root 'tools/Build-Release.ps1'
        $models = Get-Content -LiteralPath (Join-Path $root 'src/Vacate/Models.ps1') -Raw
        $null = $models -match "VacateToolVersion\s*=\s*'([^']+)'"
        $script:version = $Matches[1]
        $script:root = $root
        function Invoke-Build([string]$Out, [string]$Ver = $script:version) {
            & $script:builder -Version $Ver -OutDir $Out -SourceRoot $script:root -AllowDirty
        }
        Invoke-Build (Join-Path $TestDrive 'a') | Out-Null
        Invoke-Build (Join-Path $TestDrive 'b') | Out-Null
        $script:zipA = Join-Path $TestDrive "a/vacate-$($script:version).zip"
        $script:zipB = Join-Path $TestDrive "b/vacate-$($script:version).zip"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($script:zipA)
        try { $script:entries = @($z.Entries | ForEach-Object FullName) } finally { $z.Dispose() }
    }

    It 'gives the same bytes for the same commit' {
        (Get-FileHash $script:zipA).Hash | Should -Be (Get-FileHash $script:zipB).Hash
    }

    It 'writes SHA256SUMS matching the ZIP' {
        $line = Get-Content -LiteralPath (Join-Path $TestDrive 'a/SHA256SUMS')
        $line | Should -Be ('{0}  vacate-{1}.zip' -f (Get-FileHash $script:zipA).Hash.ToLowerInvariant(), $script:version)
    }

    It 'puts everything under one top folder and includes the launchers, module and manifest' {
        $top = "vacate-$($script:version)/"
        @($script:entries | Where-Object { -not $_.StartsWith($top) }).Count | Should -Be 0
        foreach ($f in 'vacate.ps1', 'vacate.cmd', 'src/Vacate/Vacate.psm1', 'MANIFEST.sha256', 'README.md', 'docs/GUIDE.md') {
            $script:entries | Should -Contain ($top + $f)
        }
    }

    It 'leaves out tests, tools and internal notes' {
        $bad = @($script:entries | Where-Object { $_ -match '/(tests|tools|docs/prompts|docs/research|\.github)/|PROGRESS\.md|CONTRACTS-|HANDOFF' })
        $bad | Should -BeNullOrEmpty
    }

    It 'refuses a version that does not match the tool version' {
        { Invoke-Build (Join-Path $TestDrive 'c') '99.0.0' } | Should -Throw '*does not match*'
    }
}
