# PathJail.ps1 - keeps every scan inside its allowed root. Owner: Claude (W1-A, taken over from Codex).
# PowerShell 5.1 compatible. ASCII only. See docs/CONTRACTS.md section 3.
# Only the injected $FileSystem provider touches disk; no Resolve-Path / Get-ChildItem / Test-Path
# here, because those can follow links or bypass the provider boundary.

function ConvertTo-VacateNormalizedPath {
    # Unify separators, collapse repeats, drop trailing separator (except a bare root), and on macOS
    # map /private/var|tmp|etc to /var|tmp|etc. On Unix a backslash is a legal file-name character,
    # so it is left alone there.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][object]$Platform
    )
    if ($Path -eq '') { return '' }
    $sep = [string]$Platform.Separator
    $p = $Path
    if ($sep -eq '\') {
        $p = $p.Replace('/', '\')
        $unc = $p.StartsWith('\\')
        while ($p.IndexOf('\\') -ge 0) { $p = $p.Replace('\\', '\') }
        if ($unc) { $p = '\' + $p }
        if ($p -match '^[A-Za-z]:$') { return $p + '\' }
        if ($p.Length -gt 3 -and $p.EndsWith('\')) { $p = $p.TrimEnd('\') }
        if ($p -match '^[A-Za-z]:$') { $p = $p + '\' }
        return $p
    }
    while ($p.IndexOf('//') -ge 0) { $p = $p.Replace('//', '/') }
    if ($p.Length -gt 1 -and $p.EndsWith('/')) { $p = $p.TrimEnd('/') }
    if ($p -eq '') { $p = '/' }
    if ([string]$Platform.Name -ceq 'macos') {
        foreach ($alias in @('var', 'tmp', 'etc')) {
            $long = '/private/' + $alias
            if ($p.Equals($long, [StringComparison]::OrdinalIgnoreCase)) { return '/' + $alias }
            if ($p.StartsWith($long + '/', [StringComparison]::OrdinalIgnoreCase)) { return '/' + $alias + $p.Substring($long.Length) }
        }
    }
    return $p
}

function Split-VacateRulePath {
    # Splits a rule's relative path into segments, refusing anything that could escape the root.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ($Path -eq '') { return @() }
    if ($Path.StartsWith('\\')) { throw "jail: UNC paths are not allowed: '$Path'" }
    if ($Path.StartsWith('/') -or $Path.StartsWith('\')) { throw "jail: absolute paths are not allowed: '$Path'" }
    if ($Path -match '^[A-Za-z]:') { throw "jail: drive letters are not allowed: '$Path'" }
    if ($Path.IndexOf('\') -ge 0) { throw "jail: use / in rule paths, not \: '$Path'" }
    if ($Path -match '[<>|"]') { throw "jail: illegal character in '$Path'" }
    if ($Path -match '[\x00-\x1F]') { throw 'jail: control character in rule path' }
    $segs = $Path.Split('/')
    foreach ($s in $segs) {
        if ($s -eq '') { throw "jail: empty segment in '$Path'" }
        if ($s -eq '.' -or $s -eq '..') { throw "jail: '$s' segment is not allowed in '$Path'" }
        if ($s.IndexOf('**') -ge 0) { throw "jail: '**' is not allowed in '$Path'" }
        if ($s.IndexOf(':') -ge 0) { throw "jail: ':' is not allowed in '$Path'" }
    }
    return $segs
}

function Test-VacatePathUnderRoot {
    # True when Path is Root or inside it, compared with the platform's case rules.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root,
        [Parameter(Mandatory)][object]$Platform
    )
    if ($Path -eq '' -or $Root -eq '') { return $false }
    $p = ConvertTo-VacateNormalizedPath -Path $Path -Platform $Platform
    $r = ConvertTo-VacateNormalizedPath -Path $Root -Platform $Platform
    $cmp = [StringComparison]$Platform.Comparison
    if ($p.Equals($r, $cmp)) { return $true }
    $sep = [string]$Platform.Separator
    $prefix = $r
    if (-not $prefix.EndsWith($sep)) { $prefix = $prefix + $sep }
    return $p.StartsWith($prefix, $cmp)
}

function Get-VacateRelativeSegment {
    # Segments of Path below Root (empty when equal). Caller must check Path is under Root.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Path, [string]$Root, [object]$Platform)
    $p = ConvertTo-VacateNormalizedPath -Path $Path -Platform $Platform
    $r = ConvertTo-VacateNormalizedPath -Path $Root -Platform $Platform
    if ($p.Length -le $r.Length) { return @() }
    $rest = $p.Substring($r.Length).TrimStart([char]$Platform.Separator)
    if ($rest -eq '') { return @() }
    return $rest.Split([char]$Platform.Separator)
}

function Test-VacateOtherUserPath {
    # True for anything inside another user's profile. The profile folder itself (a direct child
    # of UsersRoot) is allowed, because other profiles may be reported by name only.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Platform
    )
    $users = [string]$Platform.UsersRoot
    $homeDir = [string]$Platform.HomePath
    if ($users -eq '') { return $false }
    if (-not (Test-VacatePathUnderRoot -Path $Path -Root $users -Platform $Platform)) { return $false }
    if ($homeDir -ne '' -and (Test-VacatePathUnderRoot -Path $Path -Root $homeDir -Platform $Platform)) { return $false }
    $rel = @(Get-VacateRelativeSegment -Path $Path -Root $users -Platform $Platform)
    return ($rel.Count -gt 1)
}

function Test-VacateCrossesMount {
    # True when Path lives on a different mount than Root (longest matching mount point wins).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$MountPoints = @(),
        [Parameter(Mandatory)][object]$Platform
    )
    if (@($MountPoints).Count -eq 0) { return $false }
    $find = {
        param($x)
        $best = $null
        foreach ($m in $MountPoints) {
            if ([string]::IsNullOrEmpty($m)) { continue }
            if (Test-VacatePathUnderRoot -Path $x -Root $m -Platform $Platform) {
                $n = ConvertTo-VacateNormalizedPath -Path $m -Platform $Platform
                if ($null -eq $best -or $n.Length -gt $best.Length) { $best = $n }
            }
        }
        return $best
    }
    $a = & $find $Path
    $b = & $find $Root
    if ($null -eq $a -and $null -eq $b) { return $false }
    if ($null -eq $a -or $null -eq $b) { return $true }
    return (-not $a.Equals($b, [StringComparison]$Platform.Comparison))
}

function Join-VacatePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Parent, [string]$Child, [object]$Platform)
    $sep = [string]$Platform.Separator
    if ($Parent.EndsWith($sep)) { return $Parent + $Child }
    return $Parent + $sep + $Child
}

function Resolve-VacateRuleTargets {
    # Expands a rule path under Root one segment at a time through the provider and returns the
    # targets that pass every jail check. Never follows a reparse point.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by docs/CONTRACTS.md section 3.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MountPoints', Justification = 'Used inside the $check scriptblock.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Exclude', Justification = 'Used inside the $check scriptblock.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$FileSystem,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RulePath,
        [Parameter(Mandatory)][ValidateSet('files', 'directories', 'any')][string]$Match,
        [Parameter(Mandatory)][object]$Platform,
        [AllowEmptyCollection()][string[]]$MountPoints = @(),
        [AllowEmptyCollection()][string[]]$Exclude = @(),
        [switch]$ExcludeHome
    )
    $segments = @(Split-VacateRulePath -Path $RulePath)
    $rootNorm = ConvertTo-VacateNormalizedPath -Path $Root -Platform $Platform
    $rejected = New-Object System.Collections.Generic.List[object]
    $denied = New-Object System.Collections.Generic.List[string]
    $targets = New-Object System.Collections.Generic.List[object]
    $result = { @{ Targets = $targets.ToArray(); Rejected = $rejected.ToArray(); Denied = $denied.ToArray() } }

    $rootItem = $FileSystem.GetItem($rootNorm)
    if ($null -eq $rootItem) { return (& $result) }
    if (Test-VacateReparse -Attributes $rootItem.Attributes) {
        $rejected.Add(@{ Path = $rootNorm; Reason = 'link' })
        return (& $result)
    }

    # Returns a reason string when the candidate must be refused, else $null.
    $check = {
        param($item)
        $full = ConvertTo-VacateNormalizedPath -Path $item.FullName -Platform $Platform
        if (Test-VacateReparse -Attributes $item.Attributes) { return 'link' }
        if (-not (Test-VacatePathUnderRoot -Path $full -Root $rootNorm -Platform $Platform)) { return 'outside-root' }
        if (Test-VacateOtherUserPath -Path $full -Platform $Platform) { return 'other-user' }
        if (Test-VacateCrossesMount -Path $full -Root $rootNorm -MountPoints $MountPoints -Platform $Platform) { return 'other-volume' }
        foreach ($x in $Exclude) {
            if (-not [string]::IsNullOrEmpty($x) -and (Test-VacatePathUnderRoot -Path $full -Root $x -Platform $Platform)) { return 'excluded' }
        }
        return $null
    }

    $current = @($rootItem)
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg = $segments[$i]
        $last = ($i -eq $segments.Count - 1)
        $next = New-Object System.Collections.Generic.List[object]
        foreach ($dir in $current) {
            if (-not ($dir -is [IO.DirectoryInfo])) { continue }
            $candidates = @()
            if ($seg.IndexOf('*') -lt 0 -and $seg.IndexOf('?') -lt 0) {
                $item = $FileSystem.GetItem((Join-VacatePath -Parent $dir.FullName -Child $seg -Platform $Platform))
                if ($null -ne $item) { $candidates = @($item) }
            }
            else {
                $kids = $FileSystem.GetChildren($dir.FullName)
                if ($kids.Denied) { $denied.Add((ConvertTo-VacateNormalizedPath -Path $dir.FullName -Platform $Platform)); continue }
                foreach ($k in @($kids.Items)) {
                    if (Test-VacateGlobMatch -Pattern $seg -Name $k.Name -CaseSensitive ([bool]$Platform.CaseSensitive)) { $candidates += $k }
                }
            }
            foreach ($c in $candidates) {
                $why = & $check $c
                if ($null -ne $why) {
                    $rejected.Add(@{ Path = (ConvertTo-VacateNormalizedPath -Path $c.FullName -Platform $Platform); Reason = $why })
                    continue
                }
                if (-not $last -and -not ($c -is [IO.DirectoryInfo])) { continue }
                $next.Add($c)
            }
        }
        $current = $next.ToArray()
    }

    foreach ($t in $current) {
        $isDir = ($t -is [IO.DirectoryInfo])
        if ($Match -eq 'files' -and $isDir) { continue }
        if ($Match -eq 'directories' -and -not $isDir) { continue }
        $full = ConvertTo-VacateNormalizedPath -Path $t.FullName -Platform $Platform
        if ($segments.Count -gt 0) {
            $why = & $check $t
            if ($null -ne $why) { continue }
        }
        if ($ExcludeHome -and [string]$Platform.HomePath -ne '' -and $full.Equals((ConvertTo-VacateNormalizedPath -Path $Platform.HomePath -Platform $Platform), [StringComparison]$Platform.Comparison)) { continue }
        $targets.Add($t)
    }

    $arr = $targets.ToArray()
    if ($arr.Length -gt 1) {
        $keys = [string[]]@($arr | ForEach-Object { $_.FullName })
        [Array]::Sort($keys, $arr, [StringComparer]::Ordinal)
    }
    $targets.Clear()
    foreach ($a in $arr) { $targets.Add($a) }
    return (& $result)
}
