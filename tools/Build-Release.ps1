<#
.SYNOPSIS
    Builds the release ZIP and its SHA256SUMS file (D61). Development helper; not part of vacate.
.DESCRIPTION
    Packs the tracked product files of the current commit into dist/vacate-<version>.zip with a
    top folder vacate-<version>/. The archive is reproducible: entries are sorted, every entry
    carries the commit time, and file bytes come from git (eol=lf), so the same commit gives the
    same ZIP. A MANIFEST.sha256 inside the ZIP lists every file's hash. Needs PowerShell 7 and git.
.EXAMPLE
    pwsh -NoProfile -File tools/Build-Release.ps1 -Version 0.5.0
#>
[CmdletBinding()]
param(
    # Release version without the leading v; must equal the version in src/Vacate/Models.ps1.
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')][string]$Version,
    [string]$OutDir,
    # Repository root to build from (tests use a temp clone).
    [string]$SourceRoot,
    # Build even when product files have uncommitted changes (tests only).
    [switch]$AllowDirty
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Core') { throw 'Build-Release needs PowerShell 7 (pwsh).' }

if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
if (-not $OutDir) { $OutDir = Join-Path $SourceRoot 'dist' }

# What a user needs to run vacate. Tests, tools and internal notes stay out.
$include = @(
    'vacate.ps1', 'vacate.cmd', 'src/', 'schemas/',
    'README.md', 'CHANGELOG.md', 'LIMITS.md', 'THREAT-MODEL.md', 'RULES.md', 'DECISIONS.md', 'LICENSE',
    'docs/GUIDE.md', 'docs/FAQ.md', 'docs/TROUBLESHOOTING.md', 'docs/VERIFY.md'
)

function Invoke-Git {
    param([string[]]$GitArgs)
    $out = & git -C $SourceRoot @GitArgs
    if ($LASTEXITCODE -ne 0) { throw ('git {0} failed' -f ($GitArgs -join ' ')) }
    return $out
}

$models = Get-Content -LiteralPath (Join-Path $SourceRoot 'src/Vacate/Models.ps1') -Raw
if ($models -notmatch "VacateToolVersion\s*=\s*'([^']+)'") { throw 'Tool version not found in src/Vacate/Models.ps1.' }
if ($Matches[1] -ne $Version) { throw ("Version {0} does not match the tool version {1} in src/Vacate/Models.ps1." -f $Version, $Matches[1]) }

$files = @(Invoke-Git @('ls-files', '-z') | ForEach-Object { $_ -split "`0" } | Where-Object { $_ } | Where-Object {
        $f = $_
        @($include | Where-Object { if ($_.EndsWith('/')) { $f.StartsWith($_) } else { $f -eq $_ } }).Count -gt 0
    } | Sort-Object -Culture ([Globalization.CultureInfo]::InvariantCulture) -CaseSensitive)
if ($files.Count -eq 0) { throw 'No product files found.' }
foreach ($required in 'vacate.ps1', 'src/Vacate/Vacate.psm1') {
    if ($files -notcontains $required) { throw "Required file missing from the release: $required" }
}

if (-not $AllowDirty) {
    $dirty = @(Invoke-Git (@('status', '--porcelain', '--') + $files))
    if ($dirty.Count -gt 0) { throw ("Product files have uncommitted changes:`n" + ($dirty -join "`n")) }
}

$commitTime = [DateTimeOffset]::FromUnixTimeSeconds([long](Invoke-Git @('log', '-1', '--format=%ct'))).UtcDateTime
# ZIP stores local time without a zone; a fixed UTC value keeps builds identical everywhere.
$stamp = [DateTimeOffset]::new($commitTime.Year, $commitTime.Month, $commitTime.Day, $commitTime.Hour, $commitTime.Minute, [Math]::Floor($commitTime.Second / 2) * 2, [TimeSpan]::Zero)

$null = New-Item -ItemType Directory -Force -Path $OutDir
$name = "vacate-$Version"
$zipPath = Join-Path $OutDir "$name.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression
$sha = [Security.Cryptography.SHA256]::Create()
$manifest = New-Object System.Text.StringBuilder
$stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
try {
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            # .gitattributes forces eol=lf, so a clean checkout holds the committed bytes on every OS.
            $bytes = [IO.File]::ReadAllBytes((Join-Path $SourceRoot $f))
            $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
            $null = $manifest.Append("$hash  $f`n")
            $entry = $zip.CreateEntry("$name/$f", [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $stamp
            $entry.ExternalAttributes = 0x81A40000  # regular file, 0644
            $es = $entry.Open(); try { $es.Write($bytes, 0, $bytes.Length) } finally { $es.Dispose() }
        }
        $mBytes = [Text.Encoding]::ASCII.GetBytes($manifest.ToString())
        $entry = $zip.CreateEntry("$name/MANIFEST.sha256", [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $stamp
        $entry.ExternalAttributes = 0x81A40000
        $es = $entry.Open(); try { $es.Write($mBytes, 0, $mBytes.Length) } finally { $es.Dispose() }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sums = Join-Path $OutDir 'SHA256SUMS'
[IO.File]::WriteAllText($sums, "$zipHash  $name.zip`n", (New-Object Text.UTF8Encoding $false))
Write-Output ("Built {0} ({1} files) sha256 {2}" -f $zipPath, $files.Count, $zipHash)
