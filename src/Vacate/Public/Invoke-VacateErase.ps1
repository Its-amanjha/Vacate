# Invoke-VacateErase.ps1 - public: Phase 4 erase via the operating system (DECISIONS D54-D57).
# PowerShell 5.1 compatible. ASCII only.
# A readiness report by default. Starting the erase needs every blocking readiness check to pass,
# -Execute, -Confirm <MACHINENAME>, -DiskSerial <system disk serial>, -RecordTo on another volume
# and the typed YES (asked by vacate.ps1). The erase record is written BEFORE the OS tool starts,
# to the run folder and to -RecordTo, because nothing on the disk survives the erase (D56).

function Test-VacateOtherVolume {
    # True when Path is on a different volume than the system disk.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Platform, [string]$SystemVolume)
    $full = [IO.Path]::GetFullPath($Path)
    if ($Platform -ceq 'windows') {
        # The identified system volume of the disk being erased; the Windows folder's drive otherwise.
        $sys = $SystemVolume
        if ([string]::IsNullOrEmpty($sys)) { $sys = [IO.Path]::GetPathRoot([Environment]::SystemDirectory) }
        return -not [string]::Equals([IO.Path]::GetPathRoot($full).TrimEnd('\'), $sys.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    }
    # POSIX: the longest mount point that contains the path must not be '/'.
    $best = '/'
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        $root = [string]$d.RootDirectory.FullName
        if ($root -eq '/' -or $root -eq '') { continue }
        $prefix = $root.TrimEnd('/') + '/'
        if (($full + '/').StartsWith($prefix, [StringComparison]::Ordinal) -and $root.Length -gt $best.Length) { $best = $root }
    }
    $sysRoot = '/'
    if (-not [string]::IsNullOrEmpty($SystemVolume)) { $sysRoot = $SystemVolume }
    return ($best.TrimEnd('/') -ne $sysRoot.TrimEnd('/'))
}

function ConvertTo-VacateReadinessMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Readiness, [Parameter(Mandatory)][object]$SystemDisk)
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    [void]$sb.Append('# Erase readiness' + $nl + $nl)
    $state = 'NOT READY - fix the blocking items below first.'
    if ($Readiness.ready) { $state = 'Ready. Read the warnings, then follow docs/GUIDE.md to start the erase.' }
    foreach ($l in (Format-VacateWrappedText -Text $state)) { [void]$sb.Append($l + $nl) }
    [void]$sb.Append($nl)
    $enc = $SystemDisk.encryption
    foreach ($l in (Format-VacateWrappedText -Text ('System disk: {0}, serial {1}, encryption {2} (protection on: {3}).' -f $SystemDisk.model, $SystemDisk.serial, $enc.kind, $enc.protectionOn))) { [void]$sb.Append($l + $nl) }
    [void]$sb.Append($nl + '| Check | Result | Note |' + $nl + '|---|---|---|' + $nl)
    foreach ($c in @($Readiness.checks)) {
        $res = 'ok'
        if (-not $c.ok) { if ($c.severity -ceq 'block') { $res = 'BLOCKS' } else { $res = 'warning' } }
        [void]$sb.Append(('| {0} | {1} | {2} |' -f $c.id, $res, ([string]$c.message).Replace('|', '/')) + $nl)
    }
    [void]$sb.Append($nl)
    foreach ($l in (Format-VacateWrappedText -Text 'vacate never erases on its own: it starts the operating system''s own erase after every check passes, and writes an erase record first. Only for a device you own or are authorised to hand over.')) { [void]$sb.Append($l + $nl) }
    return $sb.ToString()
}

function Invoke-VacateErase {
    <#
    .SYNOPSIS
        Erase readiness report, or (with every gate) starts the operating system's erase.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Run,
        [switch]$Execute,
        [Alias('Confirm')][string]$ConfirmMachine,
        [string]$DiskSerial,
        [string]$RecordTo,
        [switch]$WalletsBackedUp,
        # The console answer the CLI collected; must be exactly YES for -Execute.
        [string]$TypedConfirmation,
        # Tests only (D57): fake disk, stubbed launcher, fixed elevation, no typed YES.
        [object]$SystemDisk,
        [scriptblock]$Launcher,
        [object]$Elevated,
        [object]$Virtualized,
        [switch]$SkipTypedConfirm,
        [datetime]$Now = [datetime]::UtcNow
    )
    $runDir = [IO.Path]::GetFullPath($Run)
    $base = [IO.Path]::GetDirectoryName($runDir)
    $report = Read-VacateRunFile -RunDir $runDir -Name 'report.json'
    $plan = Read-VacateRunFile -RunDir $runDir -Name 'plan.json' -Optional
    $platform = Get-VacatePlatform
    $machine = [Environment]::MachineName
    $isElevated = $false
    if ($null -ne $Elevated) { $isElevated = [bool]$Elevated } else { $isElevated = Test-VacateElevated -Platform $platform }

    $disk = $SystemDisk
    if ($null -eq $disk) {
        $cim = $null
        if ($platform -ceq 'windows') { $cim = New-VacateCimRunner }
        $sq = $ExecutionContext.SessionState.Module.NewBoundScriptBlock({ param([string]$QueryName) Invoke-VacateSystemQuery -Name $QueryName -Platform (Get-VacatePlatform) })
        $disk = Get-VacateSystemDisk -Platform $platform -CimRunner $cim -SystemQuery $sq
    }
    $virt = $Virtualized
    if ($null -eq $PSBoundParameters['Virtualized']) {
        $cimV = $null
        if ($platform -ceq 'windows') { $cimV = New-VacateCimRunner }
        $virt = (Get-VacateVirtualization -Platform $platform -CimRunner $cimV -SystemDisk $disk).virtualized
    }
    $readiness = Get-VacateEraseReadiness -Report $report -Plan $plan -SystemDisk $disk -Elevated $isElevated -Platform $platform -Machine $machine -Now $Now -WalletsBackedUp $WalletsBackedUp.IsPresent -Virtualized $virt
    Write-VacateTextFile -BaseDir $base -Path ([IO.Path]::Combine($runDir, 'erase-readiness.md')) -Text (ConvertTo-VacateReadinessMarkdown -Readiness $readiness -SystemDisk $disk)

    $result = [pscustomobject][ordered]@{ mode = 'dry-run'; ready = [bool]$readiness.ready; checks = @($readiness.checks); recordFiles = @(); launch = $null }
    if (-not $Execute) { return $result }
    $result.mode = 'execute'

    # Gates (D55). Each refusal happens before anything is written outside the run folder.
    if (-not $readiness.ready) {
        $failed = @($readiness.checks | Where-Object { -not $_.ok -and $_.severity -ceq 'block' } | ForEach-Object { $_.id })
        throw ('Not ready to erase. Blocking checks: {0}. See erase-readiness.md.' -f ($failed -join ', '))
    }
    if ([string]::IsNullOrEmpty($ConfirmMachine) -or -not [string]::Equals($ConfirmMachine.Trim(), $machine, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("-Execute needs -Confirm with this machine's name ({0}). Nothing was erased." -f $machine)
    }
    $serial = [string]$disk.serial
    if ([string]::IsNullOrEmpty($DiskSerial) -or [string]::IsNullOrEmpty($serial) -or -not [string]::Equals($DiskSerial.Trim(), $serial.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
        throw ('-DiskSerial does not match the system disk serial ({0}). Nothing was erased.' -f $serial.Trim())
    }
    if ([string]::IsNullOrEmpty($RecordTo) -or -not [IO.Directory]::Exists($RecordTo)) {
        throw '-RecordTo must be an existing folder on a USB drive or other disk, to keep the erase record. Nothing was erased.'
    }
    $sysVol = $null
    if ($null -ne $disk.PSObject.Properties['osVolume']) { $sysVol = [string]$disk.osVolume }
    if (-not (Test-VacateOtherVolume -Path $RecordTo -Platform $platform -SystemVolume $sysVol)) {
        throw '-RecordTo is on the disk being erased; the record would be erased too. Use a USB drive. Nothing was erased.'
    }
    if (-not $SkipTypedConfirm -and $TypedConfirmation -cne 'YES') {
        throw 'The final confirmation was not YES. Nothing was erased.'
    }

    # Record first (D56), in both places, and prove both copies are valid before starting.
    $method = $script:VacateEraseMethodByPlatform[$platform]
    $record = New-VacateEraseRecord -Report $report -SystemDisk $disk -Readiness $readiness -Method $method -Machine $machine -Operator ([Environment]::UserName) -Now $Now
    $json = ConvertTo-VacateEraseRecordJson -Record $record
    $md = ConvertTo-VacateEraseRecordMarkdown -Record $record
    $stamp = $Now.ToUniversalTime().ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $recordDir = [IO.Path]::GetFullPath($RecordTo)
    $files = @(
        @{ Base = $base; Path = [IO.Path]::Combine($runDir, 'erase-record.json'); Text = $json },
        @{ Base = $base; Path = [IO.Path]::Combine($runDir, 'erase-record.md'); Text = $md },
        @{ Base = $recordDir; Path = [IO.Path]::Combine($recordDir, "vacate-erase-record-$stamp.json"); Text = $json },
        @{ Base = $recordDir; Path = [IO.Path]::Combine($recordDir, "vacate-erase-record-$stamp.md"); Text = $md }
    )
    foreach ($f in $files) { Write-VacateTextFile -BaseDir $f.Base -Path $f.Path -Text $f.Text }
    foreach ($f in $files | Where-Object { $_.Path.EndsWith('.json') }) {
        $check = Test-VacateEraseRecord -Json ([IO.File]::ReadAllText($f.Path))
        if (-not $check.valid) { throw ('The erase record at {0} did not verify ({1}). Nothing was erased.' -f $f.Path, (@($check.problems) -join '; ')) }
    }
    $result.recordFiles = @($files | ForEach-Object { $_.Path })
    $result.launch = Start-VacateOsErase -Platform $platform -SystemDisk $disk -Launcher $Launcher
    return $result
}
