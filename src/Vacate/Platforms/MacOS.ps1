# MacOS.ps1 - macOS platform profile.
# Owner: Pi. PowerShell 5.1 compatible. ASCII only. Reads no environment, touches no filesystem.

function Get-VacateMacOSProfile {
    # Roots follow the SPEC "Platform roots" table. macOS is case-insensitive but
    # case-preserving, so CaseSensitive stays $false.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)

    $separator = [char]'/'

    $homeRaw = Get-VacateEnvironmentValue -Environment $Environment -Name 'HOME'
    if ($null -eq $homeRaw) { throw 'platform: HOME not available' }
    $homePath = ConvertTo-VacateRootPath -Path $homeRaw -Separator $separator

    $roots = [ordered]@{}
    $roots['HOME'] = $homePath
    $roots['USERS'] = '/Users'
    $roots['LIBRARY'] = Join-VacateRootPath -Base $homePath -Child 'Library' -Separator $separator
    $roots['APPLICATIONS'] = '/Applications'
    $roots['SYSTEM'] = '/'

    $usersRoot = $roots['USERS']
    $userName = Get-VacateEnvironmentUserName -Environment $Environment -Name @('USER', 'LOGNAME')

    return [pscustomobject][ordered]@{
        Name          = 'macos'
        CaseSensitive = $false
        Comparison    = [StringComparison]::OrdinalIgnoreCase
        Separator     = $separator
        Roots         = $roots
        HomePath      = $homePath
        UsersRoot     = $usersRoot
        UserName      = $userName
    }
}
