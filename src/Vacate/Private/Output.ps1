# Output.ps1 - the ONLY place vacate writes to disk. Owner: Claude.
# PowerShell 5.1 compatible. ASCII only.
# Every write must land inside the run base folder (runs/). The run base is excluded from every
# scan (DECISIONS D28), so the tool never reports or touches its own output.

function New-VacateRunFolder {
    # Creates runs/<yyyyMMdd-HHmmss>[-n] under -BaseDir and returns its full path.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][datetime]$Now
    )
    $stamp = $Now.ToUniversalTime().ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $candidate = [IO.Path]::Combine($BaseDir, $stamp)
    $n = 1
    while ([IO.Directory]::Exists($candidate)) { $n++; $candidate = [IO.Path]::Combine($BaseDir, $stamp + '-' + $n) }
    if ($PSCmdlet.ShouldProcess($candidate, 'Create run folder')) {
        [void][IO.Directory]::CreateDirectory($candidate)
    }
    return [IO.Path]::GetFullPath($candidate)
}

function Write-VacateTextFile {
    # UTF-8 without BOM. Refuses any path outside -BaseDir (after full-path resolution) and any
    # path whose parent folder is a link.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $base = [IO.Path]::GetFullPath($BaseDir).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($Path)
    $cmp = [StringComparison]::Ordinal
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { $cmp = [StringComparison]::OrdinalIgnoreCase }
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, $cmp)) {
        throw "output: refusing to write outside the run folder: $full"
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    $probe = $parent
    while ($probe.Length -gt $base.Length) {
        $di = New-Object IO.DirectoryInfo $probe
        if ($di.Exists -and (Test-VacateReparse -Attributes $di.Attributes)) { throw "output: refusing to write through a link: $probe" }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
    if ($PSCmdlet.ShouldProcess($full, 'Write file')) {
        [IO.File]::WriteAllText($full, $Text, (New-Object Text.UTF8Encoding $false))
    }
}

function ConvertTo-VacateReportJson {
    # Stable, readable JSON. Property order comes from the [ordered]/pscustomobject construction.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Report)
    return (($Report | ConvertTo-Json -Depth 20) -replace "`r`n", "`n")
}
