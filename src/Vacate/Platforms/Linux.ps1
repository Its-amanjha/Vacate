# Linux.ps1 - Linux platform profile.
# PowerShell 5.1 compatible. ASCII only. Reads no environment, touches no filesystem.

function Get-VacateLinuxProfile {
    # Roots follow the SPEC "Platform roots" table. XDG_* follows the XDG Base Directory
    # spec: an env value is used only when it is absolute, otherwise the HOME default.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)

    $separator = [char]'/'

    $homeRaw = Get-VacateEnvironmentValue -Environment $Environment -Name 'HOME'
    if ($null -eq $homeRaw) { throw 'platform: HOME not available' }
    $homePath = ConvertTo-VacateRootPath -Path $homeRaw -Separator $separator

    $roots = [ordered]@{}
    $roots['HOME'] = $homePath
    $roots['USERS'] = '/home'
    $roots['APPLICATIONS'] = '/usr/share/applications'
    $roots['SYSTEM'] = '/'

    $xdg = @(
        @('XDG_CONFIG', 'XDG_CONFIG_HOME', '.config'),
        @('XDG_DATA', 'XDG_DATA_HOME', '.local/share'),
        @('XDG_STATE', 'XDG_STATE_HOME', '.local/state')
    )
    foreach ($pair in $xdg) {
        $raw = Get-VacateEnvironmentValue -Environment $Environment -Name $pair[1]
        if ($null -ne $raw -and (Test-VacateUnixAbsolutePath -Path $raw)) {
            $roots[$pair[0]] = ConvertTo-VacateRootPath -Path $raw -Separator $separator
        }
        else {
            $roots[$pair[0]] = Join-VacateRootPath -Base $homePath -Child $pair[2] -Separator $separator
        }
    }

    $roots['ETC'] = '/etc'
    $roots['VAR'] = '/var'

    $usersRoot = $roots['USERS']
    $userName = Get-VacateEnvironmentUserName -Environment $Environment -Name @('USER', 'LOGNAME')

    return [pscustomobject][ordered]@{
        Name          = 'linux'
        CaseSensitive = $true
        Comparison    = [StringComparison]::Ordinal
        Separator     = $separator
        Roots         = $roots
        HomePath      = $homePath
        UsersRoot     = $usersRoot
        UserName      = $userName
    }
}
