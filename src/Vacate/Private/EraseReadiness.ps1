# EraseReadiness.ps1 - Phase 4: the checks before an erase may be started.
# PowerShell 5.1 compatible. ASCII only. Set-StrictMode -Version Latest (from the module loader).
#
# Pure function (DECISIONS D55): no file system, no CIM, no registry, no clock reads. Its inputs
# are a report, a plan, the system disk description, the session state and -Now; its output is an
# ordered list of checks. It decides nothing destructive and starts nothing (D54, D57).

function Get-VacateEraseReadinessProperty {
    # Strict-mode-safe property read for report, plan and disk objects. Returns @{ Present; Value }.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $InputObject) { return @{ Present = $false; Value = $null } }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return @{ Present = $false; Value = $null } }
        return @{ Present = $true; Value = $InputObject[$Name] }
    }
    if (-not ($InputObject -is [pscustomobject])) { return @{ Present = $false; Value = $null } }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return @{ Present = $false; Value = $null } }
    return @{ Present = $true; Value = $property.Value }
}

function ConvertTo-VacateEraseUtc {
    # A datetime read as UTC whatever kind the caller passed: an unspecified time is taken as UTC
    # so the result does not depend on the test machine's time zone.
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][datetime]$Value)

    if ($Value.Kind -eq [System.DateTimeKind]::Local) { return $Value.ToUniversalTime() }
    return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
}

function New-VacateEraseCheck {
    # One readiness check: id, ok, severity (block|warn), message (field order from the contract).
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][ValidateSet('block', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Message
    )

    return [pscustomobject][ordered]@{
        id       = $Id
        ok       = $Ok
        severity = $Severity
        message  = $Message
    }
}

function Get-VacateEraseReadiness {
    <#
    .SYNOPSIS
        Returns { ready; checks } for one run, in the order the contract fixes (D55).
    .DESCRIPTION
        Checks, in this order: an elevated session, the same platform as the report, the same
        machine name, an unredacted report, a complete scan, a scan finished less than 24 hours
        ago, a plan, a named system disk, an encrypted system disk, that encryption protection is
        on, backed-up wallets, cloud-sync traces (warn), account sign-out (warn) and mains power
        (warn). 'ready' means no check of severity 'block' failed; warns never block.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Report,
        [AllowNull()][object]$Plan,
        [Parameter(Mandatory)][AllowNull()][object]$SystemDisk,
        [Parameter(Mandatory)][bool]$Elevated,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Platform,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Machine,
        [Parameter(Mandatory)][datetime]$Now,
        [bool]$WalletsBackedUp = $false,
        # $true inside a VM, WSL or container; $false on bare metal; $null when it could not be told.
        [AllowNull()][object]$Virtualized = $null
    )

    $checks = New-Object System.Collections.Generic.List[object]

    # 1. Elevated session: staging an OS erase needs administrator/root rights (D55).
    [void]$checks.Add((New-VacateEraseCheck -Id 'elevated' -Ok $Elevated -Severity 'block' -Message $(if ($Elevated) {
                    'This session is elevated.'
                }
                else {
                    'vacate needs an administrator (root) session to start the erase. Close this window and open one with elevation.'
                })))

    # Everything below reads the report, so read it once, defensively (a hand-edited or older
    # report.json must never throw out of this function).
    $scan = (Get-VacateEraseReadinessProperty -InputObject $Report -Name 'scan').Value
    $hostInfo = (Get-VacateEraseReadinessProperty -InputObject $scan -Name 'host').Value

    $reportPlatform = [string](Get-VacateEraseReadinessProperty -InputObject $scan -Name 'platform').Value
    $reportMachine = [string](Get-VacateEraseReadinessProperty -InputObject $hostInfo -Name 'name').Value

    # 2. Same platform as the report: an erase method belongs to one OS (D54).
    $samePlatform = ($reportPlatform.Length -gt 0 -and $null -ne $Platform -and $reportPlatform.Trim() -ieq $Platform.Trim())
    [void]$checks.Add((New-VacateEraseCheck -Id 'same-platform' -Ok $samePlatform -Severity 'block' -Message $(if ($samePlatform) {
                    "The report and this session are both on '$Platform'."
                }
                else {
                    $shown = $reportPlatform.Trim()
                    if ($shown.Length -eq 0) { $shown = '(none)' }
                    "The report was made on '$shown', not on this platform. Scan again on the machine you want to erase."
                })))

    # 3. Same machine: the report must be about this machine, compared case-insensitively (D55).
    $sameMachine = ($reportMachine.Trim().Length -gt 0 -and $null -ne $Machine -and $reportMachine.Trim() -ieq $Machine.Trim())
    [void]$checks.Add((New-VacateEraseCheck -Id 'same-machine' -Ok $sameMachine -Severity 'block' -Message $(if ($sameMachine) {
                    "The report is for this machine ('$($Machine.Trim())')."
                }
                else {
                    $shown = $reportMachine.Trim()
                    if ($shown.Length -eq 0) { $shown = '(unknown)' }
                    "The report was made on machine '$shown', not on this one. Scan again on the machine you want to erase."
                })))

    # 4. Unredacted report: hashed paths cannot be checked against this disk (D25, D55).
    $redacted = ((Get-VacateEraseReadinessProperty -InputObject $scan -Name 'redacted').Value -eq $true)
    [void]$checks.Add((New-VacateEraseCheck -Id 'not-redacted' -Ok (-not $redacted) -Severity 'block' -Message $(if ($redacted) {
                    'This report is redacted, so its locations are hashes. Scan again without -Redact.'
                }
                else {
                    'The report is not redacted.'
                })))

    # 5. Complete scan: a budget-stopped scan does not describe the whole machine (D55).
    $complete = ((Get-VacateEraseReadinessProperty -InputObject $scan -Name 'complete').Value -eq $true)
    [void]$checks.Add((New-VacateEraseCheck -Id 'scan-complete' -Ok $complete -Severity 'block' -Message $(if ($complete) {
                    'The scan finished.'
                }
                else {
                    'The scan did not finish, so the report is incomplete. Scan again with a larger -BudgetSeconds.'
                })))

    # 6. Recent scan: anything older than 24 hours is not evidence about the machine as it is now.
    $finishedText = [string](Get-VacateEraseReadinessProperty -InputObject $scan -Name 'finishedAt').Value
    $finishedAt = [datetime]::MinValue
    $finishedParsed = $false
    if ($finishedText.Trim().Length -gt 0) {
        # RoundtripKind alone: the report writes an ISO 8601 time with a Z suffix.
        $finishedParsed = [datetime]::TryParse(
            $finishedText.Trim(),
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$finishedAt)
    }
    $scanRecent = $false
    $scanRecentMessage = 'The scan time could not be read. Scan again.'
    if ($finishedParsed) {
        $nowUtc = ConvertTo-VacateEraseUtc -Value $Now
        $finishedUtc = ConvertTo-VacateEraseUtc -Value $finishedAt
        $age = $nowUtc - $finishedUtc
        # Exactly 24 hours still counts as recent; a second more does not.
        $scanRecent = ($age.TotalHours -le 24)
        if ($scanRecent) {
            $scanRecentMessage = "The scan finished at $($finishedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)), on the right side of the 24 hour limit."
        }
        else {
            $scanRecentMessage = "The scan finished at $($finishedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)), more than 24 hours ago. Scan again."
        }
    }
    [void]$checks.Add((New-VacateEraseCheck -Id 'scan-recent' -Ok $scanRecent -Severity 'block' -Message $scanRecentMessage))

    # 7. A plan: it is what the erase record points at and what the person has read (D56).
    $planPresent = ($null -ne $Plan)
    [void]$checks.Add((New-VacateEraseCheck -Id 'plan-present' -Ok $planPresent -Severity 'block' -Message $(if ($planPresent) {
                    'The plan for this run is here.'
                }
                else {
                    'This run has no plan. Make one with "vacate plan -Run <dir>" and read it first.'
                })))

    # 8. A disk vacate can name: never guess a serial (D56).
    $serial = ''
    $model = ''
    $encryption = $null
    if ($null -ne $SystemDisk) {
        $serial = [string](Get-VacateEraseReadinessProperty -InputObject $SystemDisk -Name 'serial').Value
        $model = [string](Get-VacateEraseReadinessProperty -InputObject $SystemDisk -Name 'model').Value
        $encryption = (Get-VacateEraseReadinessProperty -InputObject $SystemDisk -Name 'encryption').Value
    }
    $serial = $serial.Trim()
    $model = $model.Trim()
    $diskIdentified = ($serial.Length -gt 0 -and $model.Length -gt 0)
    [void]$checks.Add((New-VacateEraseCheck -Id 'disk-identified' -Ok $diskIdentified -Severity 'block' -Message $(if ($diskIdentified) {
                    "The system disk is '$model', serial '$serial'."
                }
                else {
                    $missing = New-Object System.Collections.Generic.List[string]
                    if ($model.Length -eq 0) { $missing.Add('model') }
                    if ($serial.Length -eq 0) { $missing.Add('serial') }
                    "vacate could not read the system disk $($missing -join ' or '). It will not erase a disk it cannot name."
                })))
    # Any uncertainty about the disk blocks (Phase 4 threat model): vacate erases only what it fully identified.
    $problems = @()
    if ($null -ne $SystemDisk) { $problems = @((Get-VacateEraseReadinessProperty -InputObject $SystemDisk -Name 'problems').Value | Where-Object { $null -ne $_ -and [string]$_ -ne '' }) }
    $diskComplete = ($problems.Count -eq 0)
    $completeMsg = 'Every detail of the system disk and its encryption was read.'
    if (-not $diskComplete) { $completeMsg = 'vacate could not fully read the system disk: ' + ($problems -join '; ') + '. It will not erase on partial information.' }
    [void]$checks.Add((New-VacateEraseCheck -Id 'disk-complete' -Ok $diskComplete -Severity 'block' -Message $completeMsg))

    # A VM, WSL or container would erase a virtual disk while the real machine stays untouched.
    $virtOk = ($null -ne $Virtualized -and -not [bool]$Virtualized)
    $virtMsg = 'This is not a virtual machine, WSL or container.'
    if ($null -eq $Virtualized) { $virtMsg = 'vacate could not tell whether this is a virtual machine or WSL. It erases only on real hardware it can confirm.' }
    elseif ([bool]$Virtualized) { $virtMsg = 'This is a virtual machine, WSL or container. Erasing here would not erase the real computer, so vacate refuses.' }
    [void]$checks.Add((New-VacateEraseCheck -Id 'not-virtualized' -Ok $virtOk -Severity 'block' -Message $virtMsg))

    # 9. Encrypted system disk: only a cryptographic erase is in scope (D54).
    $kind = [string](Get-VacateEraseReadinessProperty -InputObject $encryption -Name 'kind').Value
    $kind = $kind.Trim()
    $diskEncrypted = ($kind -ieq 'bitlocker' -or $kind -ieq 'filevault' -or $kind -ieq 'luks')
    # Apple silicon and T2 Macs encrypt the internal SSD in hardware even with FileVault off, and
    # Erase All Content and Settings destroys that key (Phase 4 research), so their internal Apple SSD
    # counts as encrypted with protection on.
    $appleHardware = ($Platform -ceq 'macos' -and $model -match '^(?i)APPLE SSD')
    if ($appleHardware) { $diskEncrypted = $true; if ($kind.Length -eq 0 -or $kind -ieq 'none' -or $kind -ieq 'unknown') { $kind = 'apple-hardware' } }
    [void]$checks.Add((New-VacateEraseCheck -Id 'disk-encrypted' -Ok $diskEncrypted -Severity 'block' -Message $(if ($diskEncrypted) {
                    "The system disk is encrypted ($kind)."
                }
                else {
                    $shown = $kind
                    if ($shown.Length -eq 0) { $shown = 'unknown' }
                    "System disk encryption is '$shown'. vacate only starts a cryptographic erase, so turn on BitLocker, FileVault or LUKS first."
                })))

    # 10. Protection on: encryption that is set up but not protecting does not erase anything (D54).
    $protectionOn = ((Get-VacateEraseReadinessProperty -InputObject $encryption -Name 'protectionOn').Value -eq $true) -or $appleHardware
    [void]$checks.Add((New-VacateEraseCheck -Id 'protection-on' -Ok $protectionOn -Severity 'block' -Message $(if ($protectionOn) {
                    'Encryption protection is on.'
                }
                else {
                    'Encryption protection is not on, so the keys may not be the only copy of the data. Turn protection on and let it finish before erasing.'
                })))

    # 11. Wallets: wallet files are the one thing an erase destroys beyond recovery (D51, D55).
    $walletCount = 0
    $cloudSyncCount = 0
    $traces = @()
    $tracesValue = (Get-VacateEraseReadinessProperty -InputObject $Report -Name 'traces').Value
    if ($null -ne $tracesValue -and -not ($tracesValue -is [string]) -and ($tracesValue -is [System.Collections.IEnumerable])) {
        $traces = @($tracesValue)
    }
    elseif ($null -ne $tracesValue) {
        $traces = @(, $tracesValue)
    }
    foreach ($trace in $traces) {
        if ($null -eq $trace) { continue }
        $category = [string](Get-VacateEraseReadinessProperty -InputObject $trace -Name 'category').Value
        if ($category -ieq 'wallets') { $walletCount++ }
        elseif ($category -ieq 'cloud-sync') { $cloudSyncCount++ }
    }
    if ($walletCount -eq 0) {
        $walletOk = $true
        $walletMessage = 'The scan found no wallet data.'
    }
    elseif ($WalletsBackedUp) {
        $walletOk = $true
        $walletMessage = "The scan found $walletCount wallet location(s) and you confirmed every recovery phrase or backup is safe off this machine."
    }
    else {
        $walletOk = $false
        $walletMessage = "The scan found $walletCount wallet location(s). Confirm you have every recovery phrase or backup off this machine, then repeat with -WalletsBackedUp."
    }
    [void]$checks.Add((New-VacateEraseCheck -Id 'wallets' -Ok $walletOk -Severity 'block' -Message $walletMessage))

    # 12. Cloud-sync (warn): placeholders for online-only files vanish with the disk (D55).
    $cloudOk = ($cloudSyncCount -eq 0)
    $cloudMessage = $(if ($cloudOk) {
            'The scan found no cloud-sync folders.'
        }
        else {
            "The scan found $cloudSyncCount cloud-sync location(s). Files that exist only in the cloud will not come back, so check them before erasing."
        })
    [void]$checks.Add((New-VacateEraseCheck -Id 'cloud-sync' -Ok $cloudOk -Severity 'warn' -Message $cloudMessage))

    # 13. Account sign-out (warn): no script can sign a person out of an account or Find My (D55).
    [void]$checks.Add((New-VacateEraseCheck -Id 'account-sign-out' -Ok $false -Severity 'warn' -Message 'Sign out by hand first: the Microsoft account or Apple Account, Find My, and browser sync. An erase does not do these for you.'))

    # 14. Mains power (warn): a battery that runs out mid-erase leaves a disk nobody can start (D55).
    [void]$checks.Add((New-VacateEraseCheck -Id 'power' -Ok $false -Severity 'warn' -Message 'Keep this machine on mains power for the whole erase. Losing power part way through leaves the disk unusable.'))

    # ready ignores warns: only a failing block check stops an erase (D55).
    $ready = $true
    foreach ($check in $checks) {
        if (-not $check.ok -and $check.severity -ceq 'block') { $ready = $false; break }
    }

    return [pscustomobject][ordered]@{
        ready  = $ready
        checks = $checks.ToArray()
    }
}
