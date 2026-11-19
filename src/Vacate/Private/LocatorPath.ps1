# LocatorPath.ps1 - executor for 'path' rules.
# PowerShell 5.1 compatible. ASCII only.
# Resolves targets through the path jail, then measures each one with the read-only walker.
# Metadata only: never opens a file.

function Invoke-VacatePathLocator {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][datetime]$Deadline
    )
    $traces = New-Object System.Collections.Generic.List[object]
    $skips = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $out = { [pscustomobject][ordered]@{ Traces = $traces.ToArray(); Skips = $skips.ToArray(); Errors = $errors.ToArray(); Programs = @() } }
    $id = [string]$Rule.id
    if ([datetime]::UtcNow -ge $Deadline) {
        $skips.Add((New-VacateSkip -RuleId $id -Reason 'timeout' -Detail 'Rule deadline passed before it started.'))
        return (& $out)
    }

    $loc = $Rule.locator
    $platform = $Context.Platform
    $token = [string]$loc.root
    if (-not $platform.Roots.Contains($token)) {
        $skips.Add((New-VacateSkip -RuleId $id -Reason 'unavailable' -Detail "Root '$token' is not available on this machine."))
        return (& $out)
    }
    $root = [string]$platform.Roots[$token]
    $recurse = $false
    if ($loc.PSObject.Properties['recurse'] -and $loc.recurse -eq $true) { $recurse = $true }
    $include = $null
    if ($loc.PSObject.Properties['include'] -and $loc.include) { $include = [string]$loc.include }
    $excludeHome = $false
    if ($loc.PSObject.Properties['excludeHome'] -and $loc.excludeHome -eq $true) { $excludeHome = $true }
    $maxEntries = [int]$Rule.maxEntries

    $resolved = Resolve-VacateRuleTargets -FileSystem $Context.FileSystem -Root $root -RulePath ([string]$loc.path) -Match ([string]$loc.match) -Platform $platform -MountPoints @($Context.MountPoints) -Exclude @($Context.Exclude) -ExcludeHome:$excludeHome
    $denied = New-Object System.Collections.Generic.List[string]
    foreach ($d in @($resolved.Denied)) { $denied.Add([string]$d) }

    $targets = @($resolved.Targets)
    if ($excludeHome) {
        # Other-profile rules: drop built-in profiles (Public, Default, Shared...) - D31.
        $builtIn = @($script:VacateSystemProfileNames[[string]$platform.Name])
        $cmp = [StringComparer]::Ordinal
        if (-not $platform.CaseSensitive) { $cmp = [StringComparer]::OrdinalIgnoreCase }
        $targets = @($targets | Where-Object { $n = $_.Name; -not @($builtIn | Where-Object { $cmp.Equals($_, $n) }).Count })
    }
    $remaining = $maxEntries
    $truncatedTargets = $false
    if ($targets.Count -gt $maxEntries) { $targets = @($targets[0..($maxEntries - 1)]); $truncatedTargets = $true }
    $timedOut = $false

    foreach ($t in $targets) {
        if ([datetime]::UtcNow -ge $Deadline) { $timedOut = $true; break }
        $full = ConvertTo-VacateNormalizedPath -Path $t.FullName -Platform $platform
        $isDir = ($t -is [IO.DirectoryInfo])
        if ($isDir -and $recurse) {
            if ($remaining -le 0) { $truncatedTargets = $true; break }
            $w = Invoke-VacateWalk -FileSystem $Context.FileSystem -Path $full -Recurse $true -Include $include -MaxEntries $remaining -Deadline $Deadline -Platform $platform
            $remaining = $remaining - ([int]$w.Files + [int]$w.Directories)
            foreach ($d in @($w.DeniedPaths)) { $denied.Add([string]$d) }
            if ($w.TimedOut) { $timedOut = $true }
            if ($null -ne $include -and [int]$w.Files -eq 0) { continue }
            $lwt = $w.LastWriteTimeUtc
            if ($null -eq $lwt) { $lwt = $t.LastWriteTimeUtc }
            $traces.Add((New-VacateTrace -Rule $Rule -Platform $platform.Name -Resolved $full -SizeBytes ([long]$w.SizeBytes) -ItemCount ([long]$w.Files) -LastWriteTime $lwt -Samples @($w.Samples) -Truncated ([bool]($w.Truncated -or $w.TimedOut))))
            if ($w.TimedOut) { break }
        }
        elseif ($isDir) {
            $traces.Add((New-VacateTrace -Rule $Rule -Platform $platform.Name -Resolved $full -LastWriteTime $t.LastWriteTimeUtc -Samples @($t.Name)))
        }
        else {
            $traces.Add((New-VacateTrace -Rule $Rule -Platform $platform.Name -Resolved $full -SizeBytes ([long]$t.Length) -ItemCount 1 -LastWriteTime $t.LastWriteTimeUtc -Samples @($t.Name)))
        }
    }

    if ($truncatedTargets -and $traces.Count -gt 0) { $traces[$traces.Count - 1].truncated = $true }
    if ($timedOut) {
        $skips.Add((New-VacateSkip -RuleId $id -Reason 'timeout' -Detail 'Rule stopped at its time limit; results are partial.'))
    }
    if ($denied.Count -gt 0) {
        $first = $denied[0]
        $detail = ('{0} folder(s) could not be read without more rights, e.g. {1}' -f $denied.Count, $first)
        $skips.Add((New-VacateSkip -RuleId $id -Reason 'permission' -Detail $detail))
    }
    return (& $out)
}
