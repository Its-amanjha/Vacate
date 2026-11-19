# Providers.ps1 - read-only filesystem and registry providers, directory walker.
# Owner: Gemini. PowerShell 5.1 compatible. ASCII only.

function New-VacateFileSystemProvider {
    # Returns a read-only filesystem provider object with GetItem and GetChildren.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    param()

    $provider = New-Object -TypeName pscustomobject

    $getItemMethod = {
        param([string]$Path)

        if ([string]::IsNullOrEmpty($Path)) {
            return $null
        }

        try {
            if ([System.IO.File]::Exists($Path)) {
                return (New-Object System.IO.FileInfo $Path)
            }
            if ([System.IO.Directory]::Exists($Path)) {
                return (New-Object System.IO.DirectoryInfo $Path)
            }

            $fi = New-Object System.IO.FileInfo $Path
            if ($fi.Exists) {
                return $fi
            }

            $di = New-Object System.IO.DirectoryInfo $Path
            if ($di.Exists) {
                return $di
            }

            $attr = [System.IO.File]::GetAttributes($Path)
            if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) {
                return (New-Object System.IO.DirectoryInfo $Path)
            }
            return (New-Object System.IO.FileInfo $Path)
        }
        catch [System.IO.FileNotFoundException] {
            return $null
        }
        catch [System.IO.DirectoryNotFoundException] {
            return $null
        }
        catch [System.UnauthorizedAccessException] {
            return $null
        }
        catch [System.IO.IOException] {
            return $null
        }
        catch [System.Security.SecurityException] {
            return $null
        }
        catch [System.ArgumentException] {
            return $null
        }
        catch [System.NotSupportedException] {
            return $null
        }
    }

    $getChildrenMethod = {
        param([string]$Path)

        if ([string]::IsNullOrEmpty($Path)) {
            return [ordered]@{
                Items  = @()
                Denied = $true
            }
        }

        $items = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
        $denied = $false

        try {
            $dirInfo = New-Object System.IO.DirectoryInfo $Path
            $enumerator = $dirInfo.EnumerateFileSystemInfos().GetEnumerator()
            try {
                while ($enumerator.MoveNext()) {
                    $items.Add($enumerator.Current)
                }
            }
            finally {
                if ($enumerator -is [System.IDisposable]) {
                    $enumerator.Dispose()
                }
            }
        }
        catch [System.UnauthorizedAccessException] {
            $denied = $true
        }
        catch [System.IO.DirectoryNotFoundException] {
            $denied = $true
        }
        catch [System.IO.IOException] {
            $denied = $true
        }
        catch [System.Security.SecurityException] {
            $denied = $true
        }

        if ($denied) {
            return [ordered]@{
                Items  = @()
                Denied = $true
            }
        }

        if ($items.Count -gt 1) {
            $items.Sort([System.Comparison[System.IO.FileSystemInfo]]{
                param($a, $b)
                [System.StringComparer]::Ordinal.Compare($a.Name, $b.Name)
            })
        }

        return [ordered]@{
            Items  = $items.ToArray()
            Denied = $false
        }
    }

    $provider | Add-Member -MemberType ScriptMethod -Name 'GetItem' -Value $getItemMethod
    $provider | Add-Member -MemberType ScriptMethod -Name 'GetChildren' -Value $getChildrenMethod

    return $provider
}

function New-VacateRegistryProvider {
    # Returns a read-only registry provider object for Windows.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RegistryBase', Justification = 'Captured by ScriptMethod closure.')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$RegistryBase
    )

    $isWin = ($PSVersionTable.PSEdition -eq 'Desktop')
    if (-not $isWin) {
        $detectedWin = Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue
        if ($detectedWin -eq $true) {
            $isWin = $true
        }
    }
    if (-not $isWin) {
        throw 'provider: registry is Windows-only'
    }

    $provider = New-Object -TypeName pscustomobject

    $getKeyMethod = {
        param(
            [string]$Hive,
            [string]$Path,
            [string]$View
        )

        if ([string]::IsNullOrEmpty($Hive)) {
            return $null
        }

        $baseEntry = $null
        if ($null -ne $RegistryBase) {
            if ($RegistryBase.Contains($Hive)) {
                $baseEntry = $RegistryBase[$Hive]
            }
            elseif ($RegistryBase.Contains($Hive.ToUpperInvariant())) {
                $baseEntry = $RegistryBase[$Hive.ToUpperInvariant()]
            }
        }

        $targetHiveName = $Hive
        $prefix = ''
        if ($null -ne $baseEntry) {
            if ($baseEntry -is [System.Collections.IDictionary] -or $baseEntry -is [pscustomobject]) {
                if ($null -ne $baseEntry.Hive -and [string]$baseEntry.Hive -ne '') {
                    $targetHiveName = [string]$baseEntry.Hive
                }
                if ($null -ne $baseEntry.Prefix) {
                    $prefix = [string]$baseEntry.Prefix
                }
            }
        }

        $regHive = $null
        switch ($targetHiveName.ToUpperInvariant()) {
            'HKCU' { $regHive = [Microsoft.Win32.RegistryHive]::CurrentUser }
            'HKEY_CURRENT_USER' { $regHive = [Microsoft.Win32.RegistryHive]::CurrentUser }
            'CURRENTUSER' { $regHive = [Microsoft.Win32.RegistryHive]::CurrentUser }
            'HKLM' { $regHive = [Microsoft.Win32.RegistryHive]::LocalMachine }
            'HKEY_LOCAL_MACHINE' { $regHive = [Microsoft.Win32.RegistryHive]::LocalMachine }
            'LOCALMACHINE' { $regHive = [Microsoft.Win32.RegistryHive]::LocalMachine }
            default { throw "registry: unsupported hive '$Hive'" }
        }

        $regView = [Microsoft.Win32.RegistryView]::Default
        if (-not [string]::IsNullOrEmpty($View)) {
            switch ($View.ToUpperInvariant()) {
                'DEFAULT' { $regView = [Microsoft.Win32.RegistryView]::Default }
                'REGISTRY32' { $regView = [Microsoft.Win32.RegistryView]::Registry32 }
                'REGISTRY64' { $regView = [Microsoft.Win32.RegistryView]::Registry64 }
                default { throw "registry: unsupported view '$View'" }
            }
        }

        $cleanPrefix = ''
        if ($prefix.Length -gt 0) {
            $cleanPrefix = $prefix.Trim([char[]]@([char]'/', [char]'\'))
        }
        $cleanPath = ''
        if (-not [string]::IsNullOrEmpty($Path)) {
            $cleanPath = $Path.Trim([char[]]@([char]'/', [char]'\'))
        }

        $effectivePath = ''
        if ($cleanPrefix.Length -gt 0 -and $cleanPath.Length -gt 0) {
            $effectivePath = $cleanPrefix + '\' + $cleanPath
        }
        elseif ($cleanPrefix.Length -gt 0) {
            $effectivePath = $cleanPrefix
        }
        elseif ($cleanPath.Length -gt 0) {
            $effectivePath = $cleanPath
        }

        $effectivePath = $effectivePath.Replace('/', '\')

        $baseKey = $null
        $subKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($regHive, $regView)
            try {
                $subKey = $baseKey.OpenSubKey($effectivePath, $false)
            }
            catch [System.Security.SecurityException] {
                return $null
            }
            catch [System.UnauthorizedAccessException] {
                return $null
            }

            if ($null -eq $subKey) {
                return $null
            }

            $valCount = $subKey.ValueCount
            $subCount = $subKey.SubKeyCount
            $subNames = @($subKey.GetSubKeyNames())

            if ($subNames.Length -gt 1) {
                [System.Array]::Sort($subNames, [System.StringComparer]::Ordinal)
            }

            if ($subNames.Length -gt 50) {
                $truncatedNames = New-Object string[] 50
                [System.Array]::Copy($subNames, $truncatedNames, 50)
                $subNames = $truncatedNames
            }

            return [ordered]@{
                ValueCount  = $valCount
                SubKeyCount = $subCount
                SubKeyNames = [string[]]$subNames
            }
        }
        finally {
            if ($null -ne $subKey) {
                $subKey.Dispose()
            }
            if ($null -ne $baseKey) {
                $baseKey.Dispose()
            }
        }
    }.GetNewClosure()

    $provider | Add-Member -MemberType ScriptMethod -Name 'GetKey' -Value $getKeyMethod
    return $provider
}

function Invoke-VacateWalk {
    # Recursive depth-first tree walk adhering to CONTRACTS section 4.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Used in nested scriptblock walkStep.')]
    param(
        [Parameter(Mandatory)][object]$FileSystem,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Recurse,
        [AllowNull()][string]$Include,
        [Parameter(Mandatory)][int]$MaxEntries,
        [Parameter(Mandatory)][datetime]$Deadline,
        [Parameter(Mandatory)][object]$Platform
    )

    $deadlineUtc = $Deadline
    if ($deadlineUtc.Kind -eq [System.DateTimeKind]::Local) {
        $deadlineUtc = $deadlineUtc.ToUniversalTime()
    }
    elseif ($deadlineUtc.Kind -eq [System.DateTimeKind]::Unspecified) {
        $deadlineUtc = [System.DateTime]::SpecifyKind($deadlineUtc, [System.DateTimeKind]::Utc)
    }

    if ([datetime]::UtcNow -ge $deadlineUtc) {
        return [pscustomobject][ordered]@{
            Files            = 0
            Directories      = 0
            SizeBytes        = [int64]0
            LastWriteTimeUtc = $null
            Samples          = [string[]]@()
            Truncated        = $false
            TimedOut         = $true
            DeniedPaths      = [string[]]@()
            SkippedLinks     = 0
            Placeholders     = 0
        }
    }

    $rootItem = $FileSystem.GetItem($Path)
    if ($null -eq $rootItem) {
        return [pscustomobject][ordered]@{
            Files            = 0
            Directories      = 0
            SizeBytes        = [int64]0
            LastWriteTimeUtc = $null
            Samples          = [string[]]@()
            Truncated        = $false
            TimedOut         = $false
            DeniedPaths      = [string[]]@()
            SkippedLinks     = 0
            Placeholders     = 0
        }
    }

    if (Test-VacateReparse -Attributes $rootItem.Attributes) {
        return [pscustomobject][ordered]@{
            Files            = 0
            Directories      = 0
            SizeBytes        = [int64]0
            LastWriteTimeUtc = $null
            Samples          = [string[]]@()
            Truncated        = $false
            TimedOut         = $false
            DeniedPaths      = [string[]]@()
            SkippedLinks     = 1
            Placeholders     = 0
        }
    }

    $isDir = (($rootItem.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
    if (-not $isDir) {
        $phCount = 0
        if (Test-VacateCloudPlaceholder -Attributes $rootItem.Attributes) {
            $phCount = 1
        }

        return [pscustomobject][ordered]@{
            Files            = 1
            Directories      = 0
            SizeBytes        = [int64]$rootItem.Length
            LastWriteTimeUtc = $rootItem.LastWriteTimeUtc
            Samples          = [string[]]@($rootItem.Name)
            Truncated        = $false
            TimedOut         = $false
            DeniedPaths      = [string[]]@()
            SkippedLinks     = 0
            Placeholders     = $phCount
        }
    }

    $state = [ordered]@{
        Files            = 0
        Directories      = 0
        SizeBytes        = [int64]0
        LastWriteTimeUtc = $null
        Samples          = New-Object 'System.Collections.Generic.List[string]'
        Truncated        = $false
        TimedOut         = $false
        DeniedPaths      = New-Object 'System.Collections.Generic.List[string]'
        SkippedLinks     = 0
        Placeholders     = 0
        VisitedEntries   = 0
    }

    $walkStep = {
        param([string]$currentDirPath)

        $childrenResult = $FileSystem.GetChildren($currentDirPath)
        if ($childrenResult.Denied -eq $true) {
            $state.DeniedPaths.Add($currentDirPath)
            return
        }

        $items = $childrenResult.Items
        if ($null -eq $items) { return }

        foreach ($entry in $items) {
            if ([datetime]::UtcNow -ge $deadlineUtc) {
                $state.TimedOut = $true
                return
            }

            if ($state.VisitedEntries -ge $MaxEntries) {
                $state.Truncated = $true
                return
            }
            $state.VisitedEntries++

            if (Test-VacateReparse -Attributes $entry.Attributes) {
                $state.SkippedLinks++
                continue
            }

            $entryIsDir = (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            if ($entryIsDir) {
                $state.Directories++
                if ($Recurse) {
                    & $walkStep $entry.FullName
                    if ($state.TimedOut -or $state.Truncated) {
                        return
                    }
                }
            }
            else {
                if (Test-VacateCloudPlaceholder -Attributes $entry.Attributes) {
                    $state.Placeholders++
                }

                $match = $true
                if (-not [string]::IsNullOrEmpty($Include)) {
                    $match = Test-VacateGlobMatch -Pattern $Include -Name $entry.Name -CaseSensitive $Platform.CaseSensitive
                }

                if ($match) {
                    $state.Files++
                    $state.SizeBytes += [int64]$entry.Length
                    if ($null -eq $state.LastWriteTimeUtc -or $entry.LastWriteTimeUtc -gt $state.LastWriteTimeUtc) {
                        $state.LastWriteTimeUtc = $entry.LastWriteTimeUtc
                    }
                    if ($state.Samples.Count -lt 3) {
                        $state.Samples.Add($entry.Name)
                    }
                }
            }
        }
    }

    & $walkStep $Path

    return [pscustomobject][ordered]@{
        Files            = $state.Files
        Directories      = $state.Directories
        SizeBytes        = [int64]$state.SizeBytes
        LastWriteTimeUtc = $state.LastWriteTimeUtc
        Samples          = [string[]]$state.Samples.ToArray()
        Truncated        = [bool]$state.Truncated
        TimedOut         = [bool]$state.TimedOut
        DeniedPaths      = [string[]]$state.DeniedPaths.ToArray()
        SkippedLinks     = $state.SkippedLinks
        Placeholders     = $state.Placeholders
    }
}
