# WriteSpy.ps1 - test helpers for verifying read-only invariants.
# PowerShell 5.1 compatible. ASCII only.

function Get-VacateTreeSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $results = New-Object 'System.Collections.Generic.List[pscustomobject]'
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject[]]$results.ToArray()
    }

    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($Path)

    while ($queue.Count -gt 0) {
        $curr = $queue.Dequeue()
        $dirInfo = New-Object System.IO.DirectoryInfo $curr
        $items = $null
        try {
            $items = $dirInfo.GetFileSystemInfos()
        }
        catch {
            continue
        }

        foreach ($item in $items) {
            $attr = [int64]$item.Attributes
            $isDir = (($attr -band [System.IO.FileAttributes]::Directory) -ne 0)
            $isReparse = (($attr -band 0x400) -ne 0)

            $len = [int64]0
            if (-not $isDir) {
                try {
                    $len = [int64]((New-Object System.IO.FileInfo $item.FullName).Length)
                }
                catch {
                    $len = [int64]0
                }
            }

            $results.Add([pscustomobject][ordered]@{
                Path             = [string]$item.FullName
                Length           = $len
                LastWriteTimeUtc = [datetime]$item.LastWriteTimeUtc
                Attributes       = $attr
            })

            if ($isDir -and -not $isReparse) {
                $queue.Enqueue($item.FullName)
            }
        }
    }

    if ($results.Count -gt 1) {
        $results.Sort([System.Comparison[pscustomobject]]{
            param($a, $b)
            [System.StringComparer]::Ordinal.Compare($a.Path, $b.Path)
        })
    }

    return [pscustomobject[]]$results.ToArray()
}

function Compare-VacateTreeSnapshot {
    [CmdletBinding()]
    [OutputType([string[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Ignore', Justification = 'Used in testIgnored scriptblock.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Before,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$After,
        [string[]]$Ignore = @()
    )

    $testIgnored = {
        param([string]$targetPath)
        if ($null -eq $Ignore -or $Ignore.Length -eq 0) { return $false }
        foreach ($ign in $Ignore) {
            if ([string]::IsNullOrEmpty($ign)) { continue }
            $trimmed = $ign.TrimEnd([char[]]@([char]'/', [char]'\'))
            if ($targetPath -eq $trimmed) { return $true }
            if ($targetPath.StartsWith($trimmed + '\', [System.StringComparison]::Ordinal)) { return $true }
            if ($targetPath.StartsWith($trimmed + '/', [System.StringComparison]::Ordinal)) { return $true }
        }
        return $false
    }

    $beforeMap = @{}
    if ($null -ne $Before) {
        foreach ($b in $Before) {
            $beforeMap[$b.Path] = $b
        }
    }

    $afterMap = @{}
    if ($null -ne $After) {
        foreach ($a in $After) {
            $afterMap[$a.Path] = $a
        }
    }

    $diffSet = New-Object 'System.Collections.Generic.HashSet[string]'([System.StringComparer]::Ordinal)

    foreach ($path in $afterMap.Keys) {
        if (& $testIgnored $path) { continue }
        if (-not $beforeMap.ContainsKey($path)) {
            [void]$diffSet.Add($path)
        }
        else {
            $b = $beforeMap[$path]
            $a = $afterMap[$path]
            if ($b.Length -ne $a.Length -or $b.LastWriteTimeUtc -ne $a.LastWriteTimeUtc -or $b.Attributes -ne $a.Attributes) {
                [void]$diffSet.Add($path)
            }
        }
    }

    foreach ($path in $beforeMap.Keys) {
        if (& $testIgnored $path) { continue }
        if (-not $afterMap.ContainsKey($path)) {
            [void]$diffSet.Add($path)
        }
    }

    $diffList = New-Object 'System.Collections.Generic.List[string]'($diffSet)
    if ($diffList.Count -gt 1) {
        $diffList.Sort([System.StringComparer]::Ordinal)
    }

    return [string[]]$diffList.ToArray()
}

function New-VacateSpyFileSystemProvider {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Inner', Justification = 'Captured in ScriptMethod closures.')]
    param(
        [Parameter(Mandatory)][object]$Inner
    )

    $calls = New-Object 'System.Collections.Generic.List[pscustomobject]'

    $spy = New-Object -TypeName pscustomobject
    $spy | Add-Member -MemberType NoteProperty -Name 'Calls' -Value $calls

    $getItemMethod = {
        param([string]$Path)
        $this.Calls.Add([pscustomobject][ordered]@{
            Method = 'GetItem'
            Path   = $Path
        })
        return $Inner.GetItem($Path)
    }.GetNewClosure()

    $getChildrenMethod = {
        param([string]$Path)
        $this.Calls.Add([pscustomobject][ordered]@{
            Method = 'GetChildren'
            Path   = $Path
        })
        return $Inner.GetChildren($Path)
    }.GetNewClosure()

    $failWriteMethod = {
        throw 'spy: write attempted'
    }

    $spy | Add-Member -MemberType ScriptMethod -Name 'GetItem' -Value $getItemMethod
    $spy | Add-Member -MemberType ScriptMethod -Name 'GetChildren' -Value $getChildrenMethod
    $spy | Add-Member -MemberType ScriptMethod -Name 'Delete' -Value $failWriteMethod
    $spy | Add-Member -MemberType ScriptMethod -Name 'Move' -Value $failWriteMethod
    $spy | Add-Member -MemberType ScriptMethod -Name 'Write' -Value $failWriteMethod
    $spy | Add-Member -MemberType ScriptMethod -Name 'Create' -Value $failWriteMethod

    return $spy
}
