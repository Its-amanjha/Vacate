# Tests for the Homebrew formula and its README (D61, D62).
# Text checks only: the formula is exercised for real with Linuxbrew in WSL, which cannot run in
# the Pester suite. These tests keep the pieces that matter for an installed release: the release
# ZIP of the pinned version, a pinned checksum, the whole tree in libexec, and a wrapper that
# cannot start without pwsh (formulae cannot depend on casks, Homebrew/brew#17326).

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:formulaPath = Join-Path $script:repoRoot 'packaging/homebrew/vacate.rb'
    $script:readmePath = Join-Path $script:repoRoot 'packaging/homebrew/README.md'

    function Get-HomebrewLine {
        # The formula line that starts with the given text, or $null.
        param([string]$Text, [string]$Prefix)
        foreach ($line in ($Text -split "\r?\n")) {
            if ($line.TrimStart().StartsWith($Prefix, [StringComparison]::Ordinal)) { return $line }
        }
        return $null
    }
}

Describe 'Homebrew formula files (D62)' {
    It 'ships a formula and a README, both ASCII only' {
        Test-Path -LiteralPath $script:formulaPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:readmePath -PathType Leaf | Should -BeTrue
        $formula = [IO.File]::ReadAllText($script:formulaPath)
        $readme = [IO.File]::ReadAllText($script:readmePath)
        $formula | Should -Not -Match '[^\x00-\x7F]'
        $readme | Should -Not -Match '[^\x00-\x7F]'
    }
}

Describe 'Homebrew formula content (D61, D62)' {
    BeforeAll {
        $script:formula = [IO.File]::ReadAllText($script:formulaPath)
        $script:readme = [IO.File]::ReadAllText($script:readmePath)
    }

    It 'defines the vacate formula with the fields brew audit requires' {
        $script:formula | Should -Match '(?m)^class Vacate < Formula$'
        $script:formula | Should -Match '(?m)^  desc "[^"\r\n]+"$'
        $script:formula | Should -Match '(?m)^  homepage "https://github\.com/Its-amanjha/Vacate"$'
        $script:formula | Should -Match '(?m)^  license "[^"\r\n]+"$'
    }

    It 'downloads the release ZIP, with the version in the URL rather than in a stanza' {
        $url = Get-HomebrewLine -Text $script:formula -Prefix 'url '
        $url | Should -Not -BeNullOrEmpty
        $match = [regex]::Match($url.Trim(),
            '^url "https://github\.com/Its-amanjha/Vacate/releases/download/v(?<v>[^/"]+)/vacate-(?<w>[^/"]+)\.zip"$')
        $match.Success | Should -BeTrue
        # The tag and the file name must carry the same version.
        $match.Groups['v'].Value | Should -Be $match.Groups['w'].Value
        $match.Groups['v'].Value | Should -Match '^(VERSION|\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?)$'
    }

    It 'has no separate version stanza, which Homebrew would read from the URL' {
        Get-HomebrewLine -Text $script:formula -Prefix 'version ' | Should -BeNullOrEmpty
    }

    It 'pins a checksum that is the documented placeholder or a real 64-hex hash' {
        $sha = Get-HomebrewLine -Text $script:formula -Prefix 'sha256 '
        $sha | Should -Not -BeNullOrEmpty
        $sha.Trim() | Should -Match '^sha256 "(SHA256|[0-9a-f]{64})"$'
    }

    It 'puts url before sha256, the order brew style requires' {
        $lines = $script:formula -split "\r?\n"
        $urlIndex = [Array]::IndexOf($lines, (Get-HomebrewLine -Text $script:formula -Prefix 'url '))
        $shaIndex = [Array]::IndexOf($lines, (Get-HomebrewLine -Text $script:formula -Prefix 'sha256 '))
        ($urlIndex -ge 0) | Should -BeTrue
        ($urlIndex -lt $shaIndex) | Should -BeTrue
    }

    It 'installs the whole release tree into libexec' {
        # Homebrew strips the archive's single top folder, hence the fallback to '*'
        $script:formula | Should -Match 'File\.directory\?\("vacate-#\{version\}"\)'
        $script:formula | Should -Match 'libexec\.install Dir\["#\{root\}/\*"\]'
    }

    It 'writes a bin wrapper that runs vacate.ps1 through pwsh with -NoProfile and forwards arguments' {
        $script:formula | Should -Match '\(bin/"vacate"\)\.write'
        $script:formula | Should -Match 'pwsh -NoProfile -File "#\{libexec\}/vacate\.ps1" "\$@"'
        $script:formula | Should -Match '(?m)^      #!/bin/sh$'
    }

    It 'refuses to run without pwsh and names the cask to install' {
        $script:formula | Should -Match 'command -v pwsh >/dev/null 2>&1'
        $script:formula | Should -Match 'brew install --cask powershell'
        $script:formula | Should -Match '(?m)^        exit 1$'
    }

    It 'declares no formula or cask dependency for PowerShell' {
        # Formulae cannot depend on casks (Homebrew/brew#17326); the caveats block and the
        # wrapper check are the documented alternative.
        $script:formula | Should -Not -Match '(?m)^\s*depends_on\b'
        $script:formula | Should -Match '(?m)^  def caveats$'
        $script:formula | Should -Match 'brew install --cask powershell'
    }

    It 'tests the installed command: version and rules validate' {
        $script:formula | Should -Match '(?m)^  test do$'
        $script:formula | Should -Match 'assert_match version\.to_s, shell_output\("#\{bin\}/vacate version"\)'
        $script:formula | Should -Match 'system bin/"vacate", "rules", "validate"'
    }

    It 'has no post-install step, no brew call and no network access of its own' {
        $script:formula | Should -Not -Match 'post_install'
        $script:formula | Should -Not -Match 'system\s+"brew'
        $script:formula | Should -Not -Match '\b(curl|wget|Invoke-WebRequest)\b'
    }

    It 'documents the release step that fills in VERSION and SHA256' {
        $script:readme | Should -Match 'SHA256SUMS'
        $script:readme | Should -Match 's/VERSION/\$VERSION/g'
        $script:readme | Should -Match 's/SHA256/\$SHA256/'
        $script:readme | Should -Match 'Its-amanjha/homebrew-vacate'
        $script:readme | Should -Match 'brew audit --strict'
        $script:readme | Should -Match 'brew test vacate'
    }

    It 'documents the cask limitation and the tap trust step' {
        $script:readme | Should -Match 'formulae cannot depend on casks'
        $script:readme | Should -Match 'brew install --cask powershell'
        $script:readme | Should -Match 'brew trust Its-amanjha/vacate'
    }
}
