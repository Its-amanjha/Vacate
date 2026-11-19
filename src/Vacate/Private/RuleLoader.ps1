# RuleLoader.ps1 - loads and validates rule JSON files.
# PowerShell 5.1 compatible. ASCII only. Validation is hand-written so it runs on 5.1
# (no Test-Json there, see DECISIONS D4); schemas/rule.schema.json mirrors these checks.

$script:VacateRuleKeys = @(
    'id', 'platforms', 'category', 'title', 'whyItMatters', 'sensitivity', 'locator',
    'measure', 'maxEntries', 'requiresElevation', 'verifiedOn', 'verified', 'source', 'notes'
)

$script:VacateLocatorKeys = @{
    'path'              = @{ Required = @('kind', 'root', 'path', 'match'); Optional = @('recurse', 'include', 'excludeHome') }
    'registry'          = @{ Required = @('kind', 'hive', 'key'); Optional = @('view') }
    'wmi'               = @{ Required = @('kind', 'namespace', 'className', 'properties'); Optional = @() }
    'installed-program' = @{ Required = @('kind', 'scope'); Optional = @() }
    'system-query'      = @{ Required = @('kind', 'name'); Optional = @() }
}

$script:VacateMeasuresByKind = @{
    'path'              = @('exists', 'sizeBytes', 'lastWriteTime', 'itemCount')
    'registry'          = @('exists', 'valueCount', 'subkeyCount')
    'wmi'               = @('exists', 'properties')
    'installed-program' = @('exists', 'itemCount', 'properties')
    'system-query'      = @('exists', 'properties')
}

function Get-VacateRuleField {
    # Strict-mode-safe property read. Returns @{ Present; Value }.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object -or -not ($Object -is [pscustomobject])) { return @{ Present = $false; Value = $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return @{ Present = $false; Value = $null } }
    return @{ Present = $true; Value = $p.Value }
}

function Test-VacateIsInteger {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value)
    return ($Value -is [int] -or $Value -is [long])
}

function Test-VacateIsStringArray {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or -not ($Value -is [array])) { return $false }
    foreach ($v in $Value) { if (-not ($v -is [string])) { return $false } }
    return $true
}

function Test-VacateRulePathSyntax {
    # Data-level check of locator.path. The runtime path jail (PathJail.ps1) checks again
    # before touching disk; this is defence in depth at load time (DECISIONS D14).
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Path -eq '') { return $problems.ToArray() }
    if ($Path.Length -gt 260) { $problems.Add('path longer than 260 characters') }
    if ($Path.IndexOf('\') -ge 0) { $problems.Add('path must use / not \') }
    if ($Path.StartsWith('/')) { $problems.Add('absolute path not allowed') }
    if ($Path -match '^[A-Za-z]:') { $problems.Add('drive letter not allowed') }
    if ($Path -match '[<>|"]') { $problems.Add('path contains < > | or "') }
    if ($Path -match '[\x00-\x1F]') { $problems.Add('path contains control characters') }
    foreach ($seg in $Path.Split('/')) {
        if ($seg -eq '') { $problems.Add('empty path segment (leading, trailing or double /)'); break }
        if ($seg -eq '..') { $problems.Add("'..' segment not allowed") }
        elseif ($seg -eq '.') { $problems.Add("'.' segment not allowed") }
        elseif ($seg.IndexOf('**') -ge 0) { $problems.Add("'**' not allowed; '*' matches one segment") }
        elseif ($seg.IndexOf(':') -ge 0) { $problems.Add("':' not allowed in a segment") }
    }
    return $problems.ToArray()
}

function Test-VacateRule {
    # Returns problems as string[]; empty means valid.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object]$Rule)

    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Rule -or -not ($Rule -is [pscustomobject])) {
        $p.Add('rule must be a JSON object')
        return $p.ToArray()
    }

    $names = @($Rule.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($k in $script:VacateRuleKeys) { if ($names -cnotcontains $k) { $p.Add("missing field '$k'") } }
    foreach ($n in $names) { if ($script:VacateRuleKeys -cnotcontains $n) { $p.Add("unknown field '$n'") } }

    # id
    $f = Get-VacateRuleField $Rule 'id'
    if ($f.Present) {
        if (-not ($f.Value -is [string]) -or $f.Value -cnotmatch '^[a-z0-9]+(\.[a-z0-9-]+)+$' -or $f.Value.Length -gt 100) {
            $p.Add("id must be lowercase dot-separated (e.g. browser.chrome.history)")
        }
    }

    # platforms
    $platforms = @()
    $f = Get-VacateRuleField $Rule 'platforms'
    if ($f.Present) {
        if (-not (Test-VacateIsStringArray $f.Value) -or @($f.Value).Count -eq 0) { $p.Add('platforms must be a non-empty array of strings') }
        else {
            $platforms = @($f.Value)
            foreach ($pl in $platforms) { if ($script:VacatePlatforms -cnotcontains $pl) { $p.Add("unknown platform '$pl'") } }
            if (@($platforms | Select-Object -Unique).Count -ne $platforms.Count) { $p.Add('platforms has duplicates') }
        }
    }
    $knownPlatforms = @($platforms | Where-Object { $script:VacatePlatforms -ccontains $_ })

    # simple enums and strings
    $f = Get-VacateRuleField $Rule 'category'
    if ($f.Present -and ($script:VacateCategories -cnotcontains [string]$f.Value -or -not ($f.Value -is [string]))) { $p.Add("unknown category '$($f.Value)'") }
    $f = Get-VacateRuleField $Rule 'sensitivity'
    if ($f.Present -and ($script:VacateSensitivities -cnotcontains [string]$f.Value -or -not ($f.Value -is [string]))) { $p.Add("unknown sensitivity '$($f.Value)'") }
    foreach ($spec in @(@('title', 3, 120), @('whyItMatters', 10, 400), @('source', 10, 400))) {
        $f = Get-VacateRuleField $Rule $spec[0]
        if ($f.Present) {
            if (-not ($f.Value -is [string]) -or $f.Value.Trim().Length -lt $spec[1] -or $f.Value.Length -gt $spec[2]) {
                $p.Add(("{0} must be text of {1}-{2} characters" -f $spec[0], $spec[1], $spec[2]))
            }
        }
    }
    $f = Get-VacateRuleField $Rule 'notes'
    if ($f.Present -and $null -ne $f.Value -and (-not ($f.Value -is [string]) -or $f.Value.Length -gt 600)) { $p.Add('notes must be null or text up to 600 characters') }

    # numbers and booleans
    $f = Get-VacateRuleField $Rule 'maxEntries'
    if ($f.Present) {
        if (-not (Test-VacateIsInteger $f.Value)) { $p.Add('maxEntries must be an integer') }
        elseif ($f.Value -lt 1 -or $f.Value -gt $script:VacateMaxMaxEntries) { $p.Add("maxEntries must be 1-$($script:VacateMaxMaxEntries)") }
    }
    foreach ($b in @('requiresElevation', 'verified')) {
        $f = Get-VacateRuleField $Rule $b
        if ($f.Present -and -not ($f.Value -is [bool])) { $p.Add("$b must be true or false") }
    }
    $f = Get-VacateRuleField $Rule 'verifiedOn'
    $verifiedOnCount = 0
    if ($f.Present) {
        $vo = $f.Value
        if ($null -ne $vo -and -not ($vo -is [array])) { $vo = @($vo) }
        if ($null -eq $vo) { $vo = @() }
        if (@($vo).Count -gt 0 -and -not (Test-VacateIsStringArray $vo)) { $p.Add('verifiedOn must be an array of strings') }
        $verifiedOnCount = @($vo).Count
    }
    $f = Get-VacateRuleField $Rule 'verified'
    if ($f.Present -and $f.Value -eq $true -and $verifiedOnCount -eq 0) { $p.Add('verified=true requires verifiedOn') }

    # locator
    $kind = $null
    $f = Get-VacateRuleField $Rule 'locator'
    if ($f.Present) {
        $loc = $f.Value
        if (-not ($loc -is [pscustomobject])) { $p.Add('locator must be an object') }
        else {
            $k = Get-VacateRuleField $loc 'kind'
            if (-not $k.Present -or -not ($k.Value -is [string]) -or $script:VacateLocatorKinds -cnotcontains $k.Value) {
                $p.Add("unknown locator kind '$($k.Value)'")
            }
            else {
                $kind = $k.Value
                foreach ($problem in (Test-VacateLocator -Locator $loc -Kind $kind -Platforms $knownPlatforms)) { $p.Add($problem) }
            }
        }
    }

    # measure
    $f = Get-VacateRuleField $Rule 'measure'
    if ($f.Present) {
        if (-not (Test-VacateIsStringArray $f.Value) -or @($f.Value).Count -eq 0) { $p.Add('measure must be a non-empty array of strings') }
        else {
            foreach ($m in $f.Value) {
                if ($script:VacateMeasures -cnotcontains $m) { $p.Add("unknown measure '$m'") }
                elseif ($null -ne $kind -and $script:VacateMeasuresByKind[$kind] -cnotcontains $m) { $p.Add("measure '$m' not valid for locator kind '$kind'") }
            }
        }
    }

    return $p.ToArray()
}

function Test-VacateLocator {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Locator,
        [Parameter(Mandatory)][string]$Kind,
        [AllowEmptyCollection()][string[]]$Platforms = @()
    )
    $p = New-Object System.Collections.Generic.List[string]
    $spec = $script:VacateLocatorKeys[$Kind]
    $names = @($Locator.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($r in $spec.Required) { if ($names -cnotcontains $r) { $p.Add("locator.$r is required for kind '$Kind'") } }
    foreach ($n in $names) {
        if ($spec.Required -cnotcontains $n -and $spec.Optional -cnotcontains $n) { $p.Add("locator.$n is not allowed for kind '$Kind'") }
    }

    if ($script:VacateWindowsOnlyKinds -ccontains $Kind) {
        foreach ($pl in $Platforms) { if ($pl -cne 'windows') { $p.Add("locator kind '$Kind' is Windows-only but rule lists '$pl'") } }
    }

    switch ($Kind) {
        'path' {
            $root = Get-VacateRuleField $Locator 'root'
            if ($root.Present) {
                if (-not ($root.Value -is [string])) { $p.Add('locator.root must be a token name') }
                else {
                    $any = $false
                    foreach ($pl in $script:VacatePlatforms) { if ($script:VacateRootTokens[$pl] -ccontains $root.Value) { $any = $true } }
                    if (-not $any) { $p.Add("unknown root token '$($root.Value)'") }
                    else {
                        foreach ($pl in $Platforms) {
                            if ($script:VacateRootTokens[$pl] -cnotcontains $root.Value) { $p.Add("root token '$($root.Value)' is not defined for platform '$pl'") }
                        }
                    }
                }
            }
            $path = Get-VacateRuleField $Locator 'path'
            if ($path.Present) {
                if (-not ($path.Value -is [string])) { $p.Add('locator.path must be text') }
                else { foreach ($x in (Test-VacateRulePathSyntax -Path $path.Value)) { $p.Add("locator.path: $x") } }
            }
            $match = Get-VacateRuleField $Locator 'match'
            if ($match.Present -and @('files', 'directories', 'any') -cnotcontains [string]$match.Value) { $p.Add("locator.match must be files, directories or any") }
            foreach ($b in @('recurse', 'excludeHome')) {
                $v = Get-VacateRuleField $Locator $b
                if ($v.Present -and -not ($v.Value -is [bool])) { $p.Add("locator.$b must be true or false") }
            }
            $inc = Get-VacateRuleField $Locator 'include'
            if ($inc.Present) {
                if (-not ($inc.Value -is [string]) -or $inc.Value.Length -lt 1 -or $inc.Value.Length -gt 100 -or $inc.Value -match '[/\\]') {
                    $p.Add('locator.include must be a single file-name glob')
                }
                $rec = Get-VacateRuleField $Locator 'recurse'
                if (-not ($rec.Present -and $rec.Value -eq $true)) { $p.Add('locator.include requires recurse=true') }
            }
            $ex = Get-VacateRuleField $Locator 'excludeHome'
            if ($ex.Present -and $ex.Value -eq $true -and $root.Present -and $root.Value -cne 'USERS') { $p.Add('locator.excludeHome is only valid with root USERS') }
        }
        'registry' {
            $hive = Get-VacateRuleField $Locator 'hive'
            if ($hive.Present -and @('HKCU', 'HKLM') -cnotcontains [string]$hive.Value) { $p.Add('locator.hive must be HKCU or HKLM') }
            $key = Get-VacateRuleField $Locator 'key'
            if ($key.Present) {
                $kv = [string]$key.Value
                if (-not ($key.Value -is [string]) -or $kv.Length -lt 2 -or $kv.Length -gt 255) { $p.Add('locator.key must be 2-255 characters') }
                elseif ($kv.StartsWith('\') -or $kv.EndsWith('\') -or $kv.IndexOf('/') -ge 0) { $p.Add('locator.key must not start/end with \ or contain /') }
                elseif ($kv -match '^(HKEY_|HK(CU|LM|CR|U)[:\\])') { $p.Add('locator.key must not include the hive') }
                elseif ($kv.IndexOf('\\') -ge 0 -or $kv.IndexOf('..') -ge 0) { $p.Add('locator.key has an empty segment or ..') }
            }
            $view = Get-VacateRuleField $Locator 'view'
            if ($view.Present -and @('Default', 'Registry32', 'Registry64') -cnotcontains [string]$view.Value) { $p.Add('locator.view must be Default, Registry32 or Registry64') }
        }
        'wmi' {
            $ns = Get-VacateRuleField $Locator 'namespace'
            if ($ns.Present -and ([string]$ns.Value) -cnotmatch '^root(/[A-Za-z0-9_]+)*$') { $p.Add('locator.namespace must look like root/CIMV2') }
            $cls = Get-VacateRuleField $Locator 'className'
            if ($cls.Present -and ([string]$cls.Value) -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$') { $p.Add('locator.className must be a plain class name') }
            $props = Get-VacateRuleField $Locator 'properties'
            if ($props.Present) {
                if (-not (Test-VacateIsStringArray $props.Value) -or @($props.Value).Count -eq 0) { $p.Add('locator.properties must be a non-empty array') }
                else { foreach ($x in $props.Value) { if ($x -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$') { $p.Add("locator.properties: bad name '$x'") } } }
            }
        }
        'installed-program' {
            $scope = Get-VacateRuleField $Locator 'scope'
            if ($scope.Present -and @('user', 'machine', 'all') -cnotcontains [string]$scope.Value) { $p.Add('locator.scope must be user, machine or all') }
        }
        'system-query' {
            $name = Get-VacateRuleField $Locator 'name'
            if ($name.Present) {
                if ($script:VacateSystemQueryNames -cnotcontains [string]$name.Value) { $p.Add("unknown system query '$($name.Value)'") }
                else {
                    $qp = $script:VacateSystemQueryPlatforms[[string]$name.Value]
                    foreach ($pl in $Platforms) { if ($pl -cne $qp) { $p.Add("system query '$($name.Value)' only exists on $qp") } }
                }
            }
        }
    }
    return $p.ToArray()
}

function Import-VacateRuleSet {
    # Loads every rules/<platform>/*.json. Returns:
    #   Rules         - valid rules for -Platform (or all platforms when omitted), sorted ordinal by id
    #   NotApplicable - valid rules whose platforms exclude -Platform, sorted by id
    #   Errors        - @{ File; Problems } for every invalid file, sorted by file
    #   FileCount     - number of JSON files seen
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Platform
    )
    if ($Platform -and $script:VacatePlatforms -cnotcontains $Platform) { throw "rules: unknown platform '$Platform'." }
    if (-not [IO.Directory]::Exists($Path)) { throw "rules: folder not found: $Path" }

    $valid = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $fileCount = 0

    $dirs = @([IO.Directory]::GetDirectories($Path))
    [Array]::Sort($dirs, [StringComparer]::Ordinal)
    foreach ($dir in $dirs) {
        $folderPlatform = [IO.Path]::GetFileName($dir)
        $files = @([IO.Directory]::GetFiles($dir, '*.json'))
        [Array]::Sort($files, [StringComparer]::Ordinal)
        if ($script:VacatePlatforms -cnotcontains $folderPlatform) {
            foreach ($file in $files) { $fileCount++; $errors.Add(@{ File = $file; Problems = @("rules folder '$folderPlatform' is not a platform") }) }
            continue
        }
        foreach ($file in $files) {
            $fileCount++
            $problems = New-Object System.Collections.Generic.List[string]
            $rule = $null
            try {
                $bytes = [IO.File]::ReadAllBytes($file)
                if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $problems.Add('file has a UTF-8 BOM') }
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                if ($text -match '[^\x00-\x7F]') { $problems.Add('file contains non-ASCII characters') }
                $rule = $text.TrimStart([char]0xFEFF) | ConvertFrom-Json
            }
            catch { $problems.Add('invalid JSON: ' + $_.Exception.Message) }

            if ($null -ne $rule) {
                foreach ($x in (Test-VacateRule -Rule $rule)) { $problems.Add($x) }
                $id = Get-VacateRuleField $rule 'id'
                $pl = Get-VacateRuleField $rule 'platforms'
                if ($id.Present -and $id.Value -is [string]) {
                    $base = [IO.Path]::GetFileNameWithoutExtension($file)
                    if ($base -cne $id.Value) { $problems.Add("file name must equal id '$($id.Value)'") }
                    # An id must be unique per platform (DECISIONS D21): the same id may exist once
                    # in windows/ and once in linux/, but never twice for the same platform.
                    $declared = @($folderPlatform)
                    if ($pl.Present -and (Test-VacateIsStringArray $pl.Value)) { $declared = @($pl.Value) }
                    foreach ($dp in $declared) {
                        $key = [string]$dp + '|' + $id.Value
                        if ($seen.ContainsKey($key)) { $problems.Add("duplicate id '$($id.Value)' for platform '$dp' (also in $($seen[$key]))") }
                        else { $seen[$key] = $file }
                    }
                }
                if ($pl.Present -and (Test-VacateIsStringArray $pl.Value) -and @($pl.Value) -cnotcontains $folderPlatform) {
                    $problems.Add("platforms must include '$folderPlatform' (the folder it lives in)")
                }
            }

            if ($problems.Count -gt 0) { $errors.Add(@{ File = $file; Problems = $problems.ToArray() }) }
            else { $valid.Add($rule) }
        }
    }

    # Ordinal sort by id (Sort-Object is culture-aware, which is not deterministic across machines).
    $arr = [object[]]$valid.ToArray()
    $keys = [string[]]@($arr | ForEach-Object { [string]$_.id })
    [Array]::Sort([Array]$keys, [Array]$arr, [Collections.IComparer][StringComparer]::Ordinal)

    $rules = New-Object System.Collections.Generic.List[object]
    $na = New-Object System.Collections.Generic.List[object]
    foreach ($r in $arr) {
        if (-not $Platform -or @($r.platforms) -ccontains $Platform) { $rules.Add($r) } else { $na.Add($r) }
    }

    return @{
        Rules         = $rules.ToArray()
        NotApplicable = $na.ToArray()
        Errors        = $errors.ToArray()
        FileCount     = $fileCount
    }
}
