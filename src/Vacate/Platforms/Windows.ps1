# Windows.ps1 - Windows platform profile.
# Owner: Pi. PowerShell 5.1 compatible. ASCII only. Reads no environment, touches no filesystem.

function Get-VacateWindowsProfile {
    # Roots follow the SPEC "Platform roots" table. A root whose variable is missing is
    # left out; the engine then marks rules using that token unavailable.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment)

    $separator = [char]'\'

    $userProfile = Get-VacateEnvironmentValue -Environment $Environment -Name 'USERPROFILE'
    if ($null -eq $userProfile) { throw 'platform: HOME not available' }
    $homePath = ConvertTo-VacateRootPath -Path $userProfile -Separator $separator

    $roots = [ordered]@{}
    $roots['HOME'] = $homePath

    # USERS is the parent folder of the profile, never a hard-coded C:\Users.
    $usersRoot = $null
    $lastSeparator = $homePath.LastIndexOf($separator)
    if ($lastSeparator -gt 0 -and $lastSeparator -lt ($homePath.Length - 1)) {
        $usersRoot = $homePath.Substring(0, $lastSeparator)
    }
    if ($null -ne $usersRoot) { $roots['USERS'] = $usersRoot }

    foreach ($pair in @(
            @('APPDATA', 'APPDATA'),
            @('LOCALAPPDATA', 'LOCALAPPDATA'),
            @('PROGRAMDATA', 'PROGRAMDATA')
        )) {
        $value = Get-VacateEnvironmentValue -Environment $Environment -Name $pair[0]
        if ($null -eq $value) { continue }
        $roots[$pair[1]] = ConvertTo-VacateRootPath -Path $value -Separator $separator
    }

    $systemDrive = Get-VacateEnvironmentValue -Environment $Environment -Name 'SystemDrive'
    if ($null -ne $systemDrive) {
        $roots['SYSTEMDRIVE'] = ConvertTo-VacateRootPath -Path ($systemDrive + [string]$separator) -Separator $separator
    }

    $userName = Get-VacateEnvironmentUserName -Environment $Environment -Name @('USERNAME')

    return [pscustomobject][ordered]@{
        Name          = 'windows'
        CaseSensitive = $false
        Comparison    = [StringComparison]::OrdinalIgnoreCase
        Separator     = $separator
        Roots         = $roots
        HomePath      = $homePath
        UsersRoot     = $usersRoot
        UserName      = $userName
    }
}
