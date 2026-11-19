# Primitives.ps1 - tiny pure helpers shared by PathJail and Providers.
# Owner: Claude. PowerShell 5.1 compatible. ASCII only.

function Test-VacateGlobMatch {
    # One path segment. '*' = zero or more chars, '?' = exactly one char. Everything else literal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Pattern,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][bool]$CaseSensitive
    )
    if ($Pattern.IndexOf('/') -ge 0 -or $Pattern.IndexOf('\') -ge 0) {
        throw "glob: pattern '$Pattern' spans more than one segment."
    }
    if ($Name.IndexOf('/') -ge 0 -or $Name.IndexOf('\') -ge 0) { return $false }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('\A')
    foreach ($ch in $Pattern.ToCharArray()) {
        if ($ch -eq '*') { [void]$sb.Append('.*') }
        elseif ($ch -eq '?') { [void]$sb.Append('.') }
        else { [void]$sb.Append([regex]::Escape([string]$ch)) }
    }
    [void]$sb.Append('\z')

    $options = [Text.RegularExpressions.RegexOptions]::Singleline -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
    if (-not $CaseSensitive) { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
    return [regex]::IsMatch($Name, $sb.ToString(), $options)
}

function Test-VacateReparse {
    # True for junctions, symlinks and any other reparse point. .NET reports Unix symlinks as ReparsePoint.
    [CmdletBinding()]
    [OutputType([bool])]
    # Typed [int64], not [IO.FileAttributes]: real files carry bits the enum does not name
    # (e.g. 0x400000) and PowerShell refuses to cast those to the enum.
    param([Parameter(Mandatory)][int64]$Attributes)
    return (($Attributes -band 0x400) -ne 0)
}

function Test-VacateCloudPlaceholder {
    # Offline (0x1000), RecallOnOpen (0x40000), RecallOnDataAccess (0x400000).
    # Placeholders are counted by metadata only; their contents are never opened (opening could hydrate).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int64]$Attributes)
    $mask = 0x1000 -bor 0x40000 -bor 0x400000
    return (($Attributes -band $mask) -ne 0)
}
