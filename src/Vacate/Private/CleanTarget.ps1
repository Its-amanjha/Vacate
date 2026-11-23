# CleanTarget.ps1 - the last check before a file or folder is sent to the Recycle Bin or Trash.
# PowerShell 5.1 compatible. ASCII only.
# Re-checks a target at execute time and never trusts the report (D50). Read-only: the only disk
# calls are [IO.File]::GetAttributes, which reads metadata and does not follow a link or junction
# (it reports the link itself). No Resolve-Path / Test-Path / Get-Item, which can follow links.
# [IO.Path]::GetFullPath is pure string work here: it only runs on paths already known absolute.

function Get-VacateCleanTargetPlatform {
    # The comparison rules of the machine we run on (same values as the platform profiles):
    # case-insensitive on Windows and macOS, ordinal on Linux.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = Get-VacatePlatform
    $sep = [char]'/'
    $cmp = [StringComparison]::Ordinal
    if ($name -eq 'windows') { $sep = [char]'\'; $cmp = [StringComparison]::OrdinalIgnoreCase }
    elseif ($name -eq 'macos') { $cmp = [StringComparison]::OrdinalIgnoreCase }
    return [pscustomobject]@{ Name = $name; Separator = $sep; Comparison = $cmp; CaseSensitive = ($name -eq 'linux') }
}

function Split-VacateCleanTargetPath {
    # Parses an absolute path into a prefix ('C:' or '') and its raw segments ('.' and '..' kept,
    # empty segments from repeated separators dropped). Returns @{ Ok; Reason; Prefix; Segments }.
    # Pure string work, no disk access.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][object]$Platform
    )
    $fail = { param($why) @{ Ok = $false; Reason = $why; Prefix = ''; Segments = @() } }
    if ($Path.Trim() -eq '') { return (& $fail 'path is empty') }
    if ($Path -match '[\x00-\x1F]') { return (& $fail 'path contains a control character') }
    if ([string]$Platform.Separator -eq '\') {
        $p = $Path.Replace('/', '\')
        if ($p.StartsWith('\\')) { return (& $fail 'UNC and device paths (\\server, \\?\) are not accepted') }
        if ($p -notmatch '^[A-Za-z]:\\') { return (& $fail 'not an absolute path with a drive letter (C:\...)') }
        $prefix = $p.Substring(0, 2).ToUpperInvariant()
        $segs = @($p.Substring(3).Split([char]'\') | Where-Object { $_ -ne '' })
        foreach ($s in $segs) {
            if ($s -match '[<>"|?*]') { return (& $fail "segment '$s' contains a character Windows does not allow in a name") }
            if ($s -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') { return (& $fail "segment '$s' is a reserved device name") }
        }
        return @{ Ok = $true; Reason = ''; Prefix = $prefix; Segments = $segs }
    }
    if (-not $Path.StartsWith('/')) { return (& $fail 'not an absolute path (must start with /)') }
    $segs = @($Path.Split([char]'/') | Where-Object { $_ -ne '' })
    return @{ Ok = $true; Reason = ''; Prefix = ''; Segments = $segs }
}

function Join-VacateCleanTargetPath {
    # Builds a path from a prefix and segments ('C:' + a,b -> C:\a\b ; '' + a,b -> /a/b).
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Prefix, [AllowEmptyCollection()][string[]]$Segments, [object]$Platform)
    $sep = [string]$Platform.Separator
    return $Prefix + $sep + (@($Segments) -join $sep)
}

function Get-VacateCleanTargetCanonicalProblem {
    # Returns why an absolute path is not in canonical form, or '' when it is. A canonical path
    # names exactly one item and the OS cannot rewrite it on the way to the disk: no '.' or '..'
    # segment; on Windows no trailing dot or space (silently stripped), no ':' after the drive
    # (alternate data stream) and no '~<digit>' 8.3 short-name segment (an alias of another name);
    # and [IO.Path]::GetFullPath returns the same text (ignoring case on Windows and a trailing
    # separator), which also rules out '/' on Windows and repeated separators.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Segments,
        [Parameter(Mandatory)][object]$Platform
    )
    $onWindows = ([string]$Platform.Separator -eq '\')
    foreach ($s in @($Segments)) {
        if ($s -eq '.' -or $s -eq '..') { return "segment '$s' is not allowed; give the resolved path" }
        if ($onWindows) {
            if ($s.EndsWith('.') -or $s.EndsWith(' ')) { return "segment '$s' ends with a dot or space; Windows would silently strip it" }
            if ($s.IndexOf(':') -ge 0) { return "segment '$s' contains ':' (alternate data stream)" }
            if ($s -match '~\d') { return "segment '$s' looks like an 8.3 short name" }
        }
    }
    try { $full = [IO.Path]::GetFullPath($Path) }
    catch {
        $ex = $_.Exception
        while ($ex -is [Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
        return "GetFullPath refused the path ($($ex.GetType().Name))"
    }
    $sep = [char]$Platform.Separator
    $a = $Path
    $b = $full
    if ($a.Length -gt 1 -and $a.EndsWith([string]$sep)) { $a = $a.TrimEnd($sep) }
    if ($b.Length -gt 1 -and $b.EndsWith([string]$sep)) { $b = $b.TrimEnd($sep) }
    $cmp = [StringComparison]::Ordinal
    if ($onWindows) { $cmp = [StringComparison]::OrdinalIgnoreCase }
    if (-not $a.Equals($b, $cmp)) { return "the full path would be '$full', not the path as given" }
    return ''
}

function Get-VacateCleanTargetAttribute {
    # Metadata of the item itself (a link is reported as a link, never followed).
    # Returns @{ Exists; Attributes; Error }.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $a = [int64][IO.File]::GetAttributes($Path)
        return @{ Exists = $true; Attributes = $a; Error = '' }
    }
    catch {
        $ex = $_.Exception
        while ($ex -is [Management.Automation.MethodInvocationException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
        if ($ex -is [IO.FileNotFoundException] -or $ex -is [IO.DirectoryNotFoundException]) {
            return @{ Exists = $false; Attributes = [int64]0; Error = '' }
        }
        return @{ Exists = $false; Attributes = [int64]0; Error = $ex.GetType().Name }
    }
}

function ConvertTo-VacateCleanTargetRoot {
    # An allowed root in comparable form, or $null when it cannot be one: it must be absolute,
    # below a drive or / (a bare C:\ or / is never a user root). '.' and '..' are collapsed and the
    # result goes through GetFullPath, so the root and the target are compared in the same form.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Root, [Parameter(Mandatory)][object]$Platform)
    if ([string]::IsNullOrEmpty($Root)) { return $null }
    $rp = Split-VacateCleanTargetPath -Path $Root -Platform $Platform
    if (-not $rp.Ok) { return $null }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($s in $rp.Segments) {
        if ($s -eq '.') { continue }
        if ($s -eq '..') { if ($out.Count -gt 0) { $out.RemoveAt($out.Count - 1) }; continue }
        $out.Add($s)
    }
    if ($out.Count -eq 0) { return $null }
    $joined = Join-VacateCleanTargetPath -Prefix $rp.Prefix -Segments $out.ToArray() -Platform $Platform
    try { $full = [IO.Path]::GetFullPath($joined) } catch { return $null }
    $sep = [char]$Platform.Separator
    if ($full.Length -gt 1 -and $full.EndsWith([string]$sep)) { $full = $full.TrimEnd($sep) }
    if (-not $full.Equals($joined, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $joined
}

function Test-VacateCleanTarget {
    # Execute-time check of one target (D50). The target must be an existing file or folder, given
    # as a canonical absolute path, that sits strictly below one of AllowedRoots, with no link,
    # junction or other reparse point from that root down to and including the target, and must
    # not be a redacted (hashed) path. Returns { ok; code; reason; fullPath; isDirectory }.
    # Checks run in a fixed order and the first failure wins: not-absolute, not-canonical,
    # redacted-path, outside-roots, is-root, then on disk missing / reparse-in-chain /
    # reparse-target.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$AllowedRoots
    )
    $platform = Get-VacateCleanTargetPlatform
    $cmp = [StringComparison]$platform.Comparison
    $fullPath = [string]$Path
    $result = {
        param($code, $why, $isDir)
        [pscustomobject]@{ ok = ($code -ceq 'ok'); code = $code; reason = $why; fullPath = $fullPath; isDirectory = [bool]$isDir }
    }

    # 1. Syntax: an absolute, plain path for this platform.
    $parsed = Split-VacateCleanTargetPath -Path ([string]$Path) -Platform $platform
    if (-not $parsed.Ok) { return (& $result 'not-absolute' $parsed.Reason $false) }

    # 2. Canonical: the text names exactly the item that will be moved, with nothing to resolve.
    $problem = Get-VacateCleanTargetCanonicalProblem -Path ([string]$Path) -Segments $parsed.Segments -Platform $platform
    if ($problem -ne '') { return (& $result 'not-canonical' $problem $false) }
    $fullPath = Join-VacateCleanTargetPath -Prefix $parsed.Prefix -Segments $parsed.Segments -Platform $platform

    # 3. Redacted report paths are hashes (h-<10 hex>), never real names.
    foreach ($s in $parsed.Segments) {
        if ($s -match '^h-[0-9a-f]{10}$') { return (& $result 'redacted-path' "segment '$s' is a redaction hash, not a real name" $false) }
    }

    # 4. Roots in the same canonical form; unusable entries are ignored.
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($AllowedRoots)) {
        $c = ConvertTo-VacateCleanTargetRoot -Root $r -Platform $platform
        if ($null -ne $c) { $roots.Add($c) }
    }

    # 5. Strictly below a root, on a separator boundary (C:\Users\bob2 is not below C:\Users\bob).
    #    Equal to any root is refused even if it also lies below another root.
    foreach ($r in $roots) {
        if ($fullPath.Equals($r, $cmp)) { return (& $result 'is-root' "the path is the allowed root '$r' itself" $false) }
    }
    $root = $null
    foreach ($r in $roots) {
        if (Test-VacatePathUnderRoot -Path $fullPath -Root $r -Platform $platform) {
            # The shortest containing root checks the most components for links.
            if ($null -eq $root -or $r.Length -lt $root.Length) { $root = $r }
        }
    }
    if ($null -eq $root) { return (& $result 'outside-roots' 'the path is not below any allowed root' $false) }

    # 6. On disk, from the root down to the target. Metadata only; links are never followed.
    $chain = New-Object System.Collections.Generic.List[string]
    $chain.Add($root)
    $current = $root
    foreach ($s in @(Get-VacateRelativeSegment -Path $fullPath -Root $root -Platform $platform)) {
        $current = Join-VacatePath -Parent $current -Child $s -Platform $platform
        $chain.Add($current)
    }
    $isDir = $false
    for ($i = 0; $i -lt $chain.Count; $i++) {
        $c = $chain[$i]
        $last = ($i -eq $chain.Count - 1)
        $m = Get-VacateCleanTargetAttribute -Path $c
        if ($m.Error -ne '') { return (& $result 'missing' "cannot read metadata of '$c' ($($m.Error))" $false) }
        if (-not $m.Exists) { return (& $result 'missing' "'$c' does not exist" $false) }
        if (Test-VacateReparse -Attributes $m.Attributes) {
            if ($last) { return (& $result 'reparse-target' 'the target is a link, junction or other reparse point' $false) }
            return (& $result 'reparse-in-chain' "'$c' is a link, junction or other reparse point" $false)
        }
        $isDir = (($m.Attributes -band 0x10) -ne 0)
        if (-not $last -and -not $isDir) { return (& $result 'missing' "'$c' is not a folder" $false) }
    }

    return (& $result 'ok' '' $isDir)
}
