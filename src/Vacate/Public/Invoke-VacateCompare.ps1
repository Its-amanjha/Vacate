# Invoke-VacateCompare.ps1 - public: compares two scans (DECISIONS D60).
# PowerShell 5.1 compatible. ASCII only.
# Read-only: never modifies any system state or scans; only writes compare.md and compare.json
# into the newer run folder.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VacateRuleExecStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][hashtable]$Rules,
        [Parameter(Mandatory)][hashtable]$Skips,
        [Parameter(Mandatory)][hashtable]$Errors
    )
    if ($Skips.ContainsKey($RuleId)) {
        return [pscustomobject]@{ Ran = $false; State = 'skipped'; Detail = [string]$Skips[$RuleId] }
    }
    if ($Errors.ContainsKey($RuleId)) {
        return [pscustomobject]@{ Ran = $false; State = 'failed'; Detail = [string]$Errors[$RuleId] }
    }
    if ($Rules.ContainsKey($RuleId)) {
        return [pscustomobject]@{ Ran = $true; State = 'ran'; Detail = '' }
    }
    return [pscustomobject]@{ Ran = $false; State = 'not-in-catalog'; Detail = '' }
}

function Get-VacateComparisonData {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$NewerReport,
        [Parameter(Mandatory)][object]$OlderReport,
        [Parameter(Mandatory)][string]$NewerRunPath,
        [Parameter(Mandatory)][string]$OlderRunPath,
        [Parameter(Mandatory)][datetime]$Now
    )
    $olderRules = @{}
    foreach ($r in @($OlderReport.catalog.rules)) { $olderRules[[string]$r.id] = $r }
    $newerRules = @{}
    foreach ($r in @($NewerReport.catalog.rules)) { $newerRules[[string]$r.id] = $r }

    $olderSkips = @{}
    foreach ($s in @($OlderReport.skipped)) { $olderSkips[[string]$s.ruleId] = [string]$s.reason }
    $newerSkips = @{}
    foreach ($s in @($NewerReport.skipped)) { $newerSkips[[string]$s.ruleId] = [string]$s.reason }

    $olderErrors = @{}
    foreach ($e in @($OlderReport.errors)) { $olderErrors[[string]$e.ruleId] = [string]$e.message }
    $newerErrors = @{}
    foreach ($e in @($NewerReport.errors)) { $newerErrors[[string]$e.ruleId] = [string]$e.message }

    $allRuleIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in $olderRules.Keys) { [void]$allRuleIds.Add($k) }
    foreach ($k in $newerRules.Keys) { [void]$allRuleIds.Add($k) }

    $notComparable = New-Object System.Collections.Generic.List[object]
    $notComparableSet = New-Object System.Collections.Generic.HashSet[string]

    foreach ($rid in $allRuleIds) {
        $stOld = Get-VacateRuleExecStatus -RuleId $rid -Rules $olderRules -Skips $olderSkips -Errors $olderErrors
        $stNew = Get-VacateRuleExecStatus -RuleId $rid -Rules $newerRules -Skips $newerSkips -Errors $newerErrors

        $rObj = if ($newerRules.ContainsKey($rid)) { $newerRules[$rid] } else { $olderRules[$rid] }
        $category = if ($null -ne $rObj -and $null -ne $rObj.category) { [string]$rObj.category } else { 'unknown' }
        $title = if ($null -ne $rObj -and $null -ne $rObj.title) { [string]$rObj.title } else { $rid }

        $isNotComparable = $false
        $reason = ''
        if ($stOld.Ran -and -not $stNew.Ran) {
            $isNotComparable = $true
            if ($stNew.State -ceq 'skipped') {
                $reason = ('Rule ran in older scan, but was skipped in newer scan ({0}).' -f $stNew.Detail)
            }
            elseif ($stNew.State -ceq 'failed') {
                $reason = ('Rule ran in older scan, but failed in newer scan: {0}' -f $stNew.Detail)
            }
            else {
                $reason = 'Rule ran in older scan, but was not in newer catalog.'
            }
        }
        elseif (-not $stOld.Ran -and $stNew.Ran) {
            $isNotComparable = $true
            if ($stOld.State -ceq 'skipped') {
                $reason = ('Rule was skipped in older scan ({0}), but ran in newer scan.' -f $stOld.Detail)
            }
            elseif ($stOld.State -ceq 'failed') {
                $reason = ('Rule failed in older scan ({0}), but ran in newer scan.' -f $stOld.Detail)
            }
            else {
                $reason = 'Rule was not in older catalog, but ran in newer scan.'
            }
        }

        if ($isNotComparable) {
            [void]$notComparableSet.Add($rid)
            $oldStatusText = $stOld.State; if ($stOld.Detail) { $oldStatusText += (' (' + $stOld.Detail + ')') }
            $newStatusText = $stNew.State; if ($stNew.Detail) { $newStatusText += (' (' + $stNew.Detail + ')') }
            $notComparable.Add([pscustomobject][ordered]@{
                ruleId      = $rid
                category    = $category
                title       = $title
                olderStatus = $oldStatusText
                newerStatus = $newStatusText
                reason      = $reason
            })
        }
    }

    $platform = [string]$NewerReport.scan.platform
    $comparer = if ($platform -eq 'linux') { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }

    $olderTraceMap = New-Object 'System.Collections.Generic.Dictionary[string, object]' $comparer
    foreach ($t in @($OlderReport.traces)) {
        $rid = [string]$t.ruleId
        if ($notComparableSet.Contains($rid)) { continue }
        $key = [string]$t.ruleId + '|' + [string]$t.locator.kind + '|' + [string]$t.locator.resolved
        $olderTraceMap[$key] = $t
    }

    $newerTraceMap = New-Object 'System.Collections.Generic.Dictionary[string, object]' $comparer
    foreach ($t in @($NewerReport.traces)) {
        $rid = [string]$t.ruleId
        if ($notComparableSet.Contains($rid)) { continue }
        $key = [string]$t.ruleId + '|' + [string]$t.locator.kind + '|' + [string]$t.locator.resolved
        $newerTraceMap[$key] = $t
    }

    $gone = New-Object System.Collections.Generic.List[object]
    $stillThere = New-Object System.Collections.Generic.List[object]
    $newTraces = New-Object System.Collections.Generic.List[object]

    foreach ($key in $olderTraceMap.Keys) {
        $ot = $olderTraceMap[$key]
        if ($newerTraceMap.ContainsKey($key)) {
            $nt = $newerTraceMap[$key]
            $delta = $null
            if ($null -ne $ot.sizeBytes -and $null -ne $nt.sizeBytes) {
                $delta = [long]$nt.sizeBytes - [long]$ot.sizeBytes
            }
            $stillThere.Add([pscustomobject][ordered]@{
                ruleId             = [string]$ot.ruleId
                category           = [string]$ot.category
                title              = [string]$ot.title
                locator            = [pscustomobject][ordered]@{
                    kind     = [string]$ot.locator.kind
                    resolved = [string]$ot.locator.resolved
                }
                olderSizeBytes     = if ($null -ne $ot.sizeBytes) { [long]$ot.sizeBytes } else { $null }
                newerSizeBytes     = if ($null -ne $nt.sizeBytes) { [long]$nt.sizeBytes } else { $null }
                sizeDeltaBytes     = $delta
                olderLastWriteTime = if ($null -ne $ot.lastWriteTime) { [string]$ot.lastWriteTime } else { $null }
                newerLastWriteTime = if ($null -ne $nt.lastWriteTime) { [string]$nt.lastWriteTime } else { $null }
            })
        }
        else {
            $gone.Add([pscustomobject][ordered]@{
                ruleId        = [string]$ot.ruleId
                category      = [string]$ot.category
                title         = [string]$ot.title
                locator       = [pscustomobject][ordered]@{
                    kind     = [string]$ot.locator.kind
                    resolved = [string]$ot.locator.resolved
                }
                sizeBytes     = if ($null -ne $ot.sizeBytes) { [long]$ot.sizeBytes } else { $null }
                lastWriteTime = if ($null -ne $ot.lastWriteTime) { [string]$ot.lastWriteTime } else { $null }
            })
        }
    }

    foreach ($key in $newerTraceMap.Keys) {
        if (-not $olderTraceMap.ContainsKey($key)) {
            $nt = $newerTraceMap[$key]
            $newTraces.Add([pscustomobject][ordered]@{
                ruleId        = [string]$nt.ruleId
                category      = [string]$nt.category
                title         = [string]$nt.title
                locator       = [pscustomobject][ordered]@{
                    kind     = [string]$nt.locator.kind
                    resolved = [string]$nt.locator.resolved
                }
                sizeBytes     = if ($null -ne $nt.sizeBytes) { [long]$nt.sizeBytes } else { $null }
                lastWriteTime = if ($null -ne $nt.lastWriteTime) { [string]$nt.lastWriteTime } else { $null }
            })
        }
    }

    $summary = [pscustomobject][ordered]@{
        gone          = $gone.Count
        stillThere    = $stillThere.Count
        new           = $newTraces.Count
        notComparable = $notComparable.Count
    }

    $newerHost = ''
    if ($null -ne $NewerReport.scan.PSObject.Properties['host'] -and $null -ne $NewerReport.scan.host -and $null -ne $NewerReport.scan.host.PSObject.Properties['name']) {
        $newerHost = [string]$NewerReport.scan.host.name
    }

    $newerTraceCount = if ($null -ne $NewerReport.traces) { $NewerReport.traces.Count } else { 0 }
    $olderTraceCount = if ($null -ne $OlderReport.traces) { $OlderReport.traces.Count } else { 0 }

    return [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        tool          = [pscustomobject][ordered]@{
            name    = $script:VacateToolName
            version = $script:VacateToolVersion
        }
        comparedAt    = (ConvertTo-VacateIsoTime $Now)
        platform      = $platform
        machine       = $newerHost
        redacted      = [bool]$NewerReport.scan.redacted
        newerRun      = [pscustomobject][ordered]@{
            path       = $NewerRunPath
            finishedAt = [string]$NewerReport.scan.finishedAt
            traces     = $newerTraceCount
        }
        olderRun      = [pscustomobject][ordered]@{
            path       = $OlderRunPath
            finishedAt = [string]$OlderReport.scan.finishedAt
            traces     = $olderTraceCount
        }
        summary       = $summary
        gone          = $gone.ToArray()
        stillThere    = $stillThere.ToArray()
        new           = $newTraces.ToArray()
        notComparable = $notComparable.ToArray()
    }
}

function Invoke-VacateCompare {
    <#
    .SYNOPSIS
        Compares two scans and writes compare.md and compare.json into the newer run folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Run,
        [Parameter(Mandatory)][string]$Against,
        [datetime]$Now = [datetime]::UtcNow
    )

    $runDir = [IO.Path]::GetFullPath($Run)
    $againstDir = [IO.Path]::GetFullPath($Against)
    $base = [IO.Path]::GetDirectoryName($runDir)

    $runReportPath = [IO.Path]::Combine($runDir, 'report.json')
    if (-not [IO.File]::Exists($runReportPath)) {
        throw "No report.json in $runDir. Run scan first."
    }
    $againstReportPath = [IO.Path]::Combine($againstDir, 'report.json')
    if (-not [IO.File]::Exists($againstReportPath)) {
        throw "No report.json in $againstDir. Run scan first."
    }

    $newerReport = ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText($runReportPath))
    $olderReport = ConvertFrom-VacateJson -Json ([IO.File]::ReadAllText($againstReportPath))

    $newerPlat = [string]$newerReport.scan.platform
    $olderPlat = [string]$olderReport.scan.platform
    if ($newerPlat -cne $olderPlat) {
        throw ("Scans are from different platforms ('{0}' vs '{1}'). Compare only runs on scans from the same platform." -f $newerPlat, $olderPlat)
    }

    $newerHost = ''
    if ($null -ne $newerReport.scan.PSObject.Properties['host'] -and $null -ne $newerReport.scan.host -and $null -ne $newerReport.scan.host.PSObject.Properties['name']) {
        $newerHost = [string]$newerReport.scan.host.name
    }
    $olderHost = ''
    if ($null -ne $olderReport.scan.PSObject.Properties['host'] -and $null -ne $olderReport.scan.host -and $null -ne $olderReport.scan.host.PSObject.Properties['name']) {
        $olderHost = [string]$olderReport.scan.host.name
    }
    if ([string]::IsNullOrEmpty($newerHost) -or [string]::IsNullOrEmpty($olderHost) -or -not [string]::Equals($newerHost, $olderHost, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Scans are from different machines ('{0}' vs '{1}'). Compare only runs on scans from the same machine." -f $newerHost, $olderHost)
    }

    $newerFinished = [datetime]::Parse([string]$newerReport.scan.finishedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    $olderFinished = [datetime]::Parse([string]$olderReport.scan.finishedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    if ($olderFinished -gt $newerFinished) {
        throw ("-Against scan ({0}) is newer than -Run scan ({1}). Pass the newer run as -Run and the older run as -Against." -f $olderReport.scan.finishedAt, $newerReport.scan.finishedAt)
    }

    if ([bool]$newerReport.scan.redacted -ne [bool]$olderReport.scan.redacted) {
        throw 'Cannot compare a redacted scan with an unredacted scan (paths would not match).'
    }

    $compareData = Get-VacateComparisonData -NewerReport $newerReport -OlderReport $olderReport -NewerRunPath $Run -OlderRunPath $Against -Now $Now

    $mdText = ConvertTo-VacateCompareMarkdown -Compare $compareData
    $jsonText = ConvertTo-VacateCompareJson -Compare $compareData

    $mdPath = [IO.Path]::Combine($runDir, 'compare.md')
    $jsonPath = [IO.Path]::Combine($runDir, 'compare.json')

    $written = New-Object System.Collections.Generic.List[string]
    if ($PSCmdlet.ShouldProcess($mdPath, 'Write comparison markdown')) {
        Write-VacateTextFile -BaseDir $base -Path $mdPath -Text $mdText
        $written.Add($mdPath)
    }
    if ($PSCmdlet.ShouldProcess($jsonPath, 'Write comparison json')) {
        Write-VacateTextFile -BaseDir $base -Path $jsonPath -Text $jsonText
        $written.Add($jsonPath)
    }

    return [pscustomobject]@{
        summary = $compareData.summary
        written = $written.ToArray()
        data    = $compareData
    }
}
