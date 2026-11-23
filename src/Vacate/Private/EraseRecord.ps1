# EraseRecord.ps1 - Phase 4: erase record (certificate) model and canonical serialization.
# PowerShell 5.1 compatible. ASCII only. Set-StrictMode -Version Latest.
#
# Before initiating an erase, vacate writes an erase record (erase-record.json and
# erase-record.md) documenting machine identity, disk serial, encryption status,
# method, readiness checks, and a canonical SHA-256 fingerprint (DECISIONS D56).
# The record is explicitly unsigned; digital signing is Phase 5 (DECISIONS D56).
# Erase uses the operating system's built-in reset/erase tools (DECISIONS D54, D55).
# All erase record functions are pure in-memory functions (DECISIONS D57).

Set-StrictMode -Version Latest

$script:VacateEraseRecordSchemaVersion = '1.0'
$script:VacateEraseRecordKind = 'vacate-erase-record'
$script:VacateEraseStandard = 'NIST SP 800-88 Rev. 2 cryptographic erase via the operating system (not independently verified)'
$script:VacateEraseMethods = @(
    'windows-reset-this-pc',
    'macos-erase-all-content-and-settings',
    'linux-luks-key-erase'
)

function ConvertTo-VacateEscapedJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`b" { [void]$sb.Append('\b') }
            "`f" { [void]$sb.Append('\f') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                $code = [int]$ch
                if ($code -lt 32) {
                    [void]$sb.AppendFormat('\u{0:x4}', $code)
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-VacateCanonicalJson {
    # Deterministic JSON with 2-space indentation and LF line endings across PowerShell 5.1 and 7.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$InputObject,
        [int]$IndentLevel = 0
    )

    if ($null -eq $InputObject) {
        return 'null'
    }
    if ($InputObject -is [bool]) {
        if ($InputObject) { return 'true' } else { return 'false' }
    }
    if ($InputObject -is [byte] -or $InputObject -is [int16] -or $InputObject -is [int32] -or $InputObject -is [int64] -or
        $InputObject -is [sbyte] -or $InputObject -is [uint16] -or $InputObject -is [uint32] -or $InputObject -is [uint64]) {
        return $InputObject.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($InputObject -is [double] -or $InputObject -is [float] -or $InputObject -is [decimal]) {
        return $InputObject.ToString('G', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($InputObject -is [string]) {
        return (ConvertTo-VacateEscapedJsonString -Text ([string]$InputObject))
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $keys = @($InputObject.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $indent = ('  ' * $IndentLevel)
        $childIndent = ('  ' * ($IndentLevel + 1))
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($k in $keys) {
            $valJson = ConvertTo-VacateCanonicalJson -InputObject $InputObject[$k] -IndentLevel ($IndentLevel + 1)
            $keyJson = ConvertTo-VacateEscapedJsonString -Text ([string]$k)
            $items.Add($childIndent + $keyJson + ': ' + $valJson)
        }
        return '{' + "`n" + ($items -join (',' + "`n")) + "`n" + $indent + '}'
    }
    if ($InputObject -is [array] -or $InputObject -is [System.Collections.IList]) {
        if ($InputObject.Count -eq 0) { return '[]' }
        $indent = ('  ' * $IndentLevel)
        $childIndent = ('  ' * ($IndentLevel + 1))
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($elem in $InputObject) {
            $elemJson = ConvertTo-VacateCanonicalJson -InputObject $elem -IndentLevel ($IndentLevel + 1)
            $items.Add($childIndent + $elemJson)
        }
        return '[' + "`n" + ($items -join (',' + "`n")) + "`n" + $indent + ']'
    }

    # Otherwise treat as object (pscustomobject, etc.)
    $props = @($InputObject.PSObject.Properties)
    if ($props.Count -eq 0) { return '{}' }
    $indent = ('  ' * $IndentLevel)
    $childIndent = ('  ' * ($IndentLevel + 1))
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($p in $props) {
        $valJson = ConvertTo-VacateCanonicalJson -InputObject $p.Value -IndentLevel ($IndentLevel + 1)
        $keyJson = ConvertTo-VacateEscapedJsonString -Text ([string]$p.Name)
        $items.Add($childIndent + $keyJson + ': ' + $valJson)
    }
    return '{' + "`n" + ($items -join (',' + "`n")) + "`n" + $indent + '}'
}

function Get-VacateSha256Hex {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Get-VacateEraseRecordCanonicalBody {
    # Extracts and normalizes the canonical body (all 16 fields except sha256) in fixed order.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Record)

    $toolName = 'vacate'
    $toolVersion = $script:VacateToolVersion
    if ($null -ne $Record.tool) {
        if ($null -ne $Record.tool.name) { $toolName = [string]$Record.tool.name }
        if ($null -ne $Record.tool.version) { $toolVersion = [string]$Record.tool.version }
    }

    $osName = ''
    $osVersion = ''
    if ($null -ne $Record.os) {
        if ($null -ne $Record.os.name) { $osName = [string]$Record.os.name }
        if ($null -ne $Record.os.version) { $osVersion = [string]$Record.os.version }
    }

    $diskModel = $null
    $diskSerial = $null
    $diskSizeBytes = $null
    $diskBusType = $null
    if ($null -ne $Record.disk) {
        if ($null -ne $Record.disk.model) { $diskModel = [string]$Record.disk.model }
        if ($null -ne $Record.disk.serial) { $diskSerial = [string]$Record.disk.serial }
        if ($null -ne $Record.disk.sizeBytes) { $diskSizeBytes = [long]$Record.disk.sizeBytes }
        if ($null -ne $Record.disk.busType) { $diskBusType = [string]$Record.disk.busType }
    }

    $encKind = 'unknown'
    $encProtectionOn = $null
    if ($null -ne $Record.encryption) {
        if ($null -ne $Record.encryption.kind) { $encKind = [string]$Record.encryption.kind }
        if ($null -ne $Record.encryption.protectionOn) { $encProtectionOn = [bool]$Record.encryption.protectionOn }
    }

    $checks = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Record.readiness) {
        foreach ($c in @($Record.readiness)) {
            if ($null -eq $c) { continue }
            $checks.Add([pscustomobject][ordered]@{
                id       = [string]$c.id
                ok       = [bool]$c.ok
                severity = [string]$c.severity
                message  = [string]$c.message
            })
        }
    }

    $sourceFinishedAt = $null
    $sourceTraces = 0
    if ($null -ne $Record.sourceRun) {
        if ($null -ne $Record.sourceRun.finishedAt) { $sourceFinishedAt = [string]$Record.sourceRun.finishedAt }
        if ($null -ne $Record.sourceRun.traces) { $sourceTraces = [int]$Record.sourceRun.traces }
    }

    $notes = @()
    if ($null -ne $Record.notes) {
        $notes = @($Record.notes | ForEach-Object { [string]$_ })
    }

    return [pscustomobject][ordered]@{
        schemaVersion = [string]$Record.schemaVersion
        kind          = [string]$Record.kind
        signed        = [bool]$Record.signed
        tool          = [pscustomobject][ordered]@{
            name    = $toolName
            version = $toolVersion
        }
        createdAt     = [string]$Record.createdAt
        machine       = [string]$Record.machine
        operator      = [string]$Record.operator
        platform      = [string]$Record.platform
        os            = [pscustomobject][ordered]@{
            name    = $osName
            version = $osVersion
        }
        disk          = [pscustomobject][ordered]@{
            model     = $diskModel
            serial    = $diskSerial
            sizeBytes = $diskSizeBytes
            busType   = $diskBusType
        }
        encryption    = [pscustomobject][ordered]@{
            kind         = $encKind
            protectionOn = $encProtectionOn
        }
        method        = [string]$Record.method
        standard      = [string]$Record.standard
        readiness     = $checks.ToArray()
        sourceRun     = [pscustomobject][ordered]@{
            finishedAt = $sourceFinishedAt
            traces     = $sourceTraces
        }
        notes         = $notes
    }
}

function New-VacateEraseRecord {
    <#
    .SYNOPSIS
        Creates a new erase record object before initiating an OS erase (DECISIONS D56).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][object]$SystemDisk,
        [Parameter(Mandatory)][object]$Readiness,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][string]$Operator,
        [Parameter(Mandatory)][datetime]$Now,
        [string[]]$Notes = @()
    )

    if ([string]::IsNullOrWhiteSpace($Machine)) { throw 'erase record: machine name is required.' }
    if ([string]::IsNullOrWhiteSpace($Operator)) { throw 'erase record: operator name is required.' }
    if ($script:VacateEraseMethods -notcontains $Method) {
        throw "erase record: invalid erase method '$Method'."
    }

    $platform = [string]$SystemDisk.platform
    if ([string]::IsNullOrEmpty($platform) -and $null -ne $Report.scan) {
        $platform = [string]$Report.scan.platform
    }

    $osName = ''
    $osVersion = ''
    if ($null -ne $Report.scan -and $null -ne $Report.scan.host) {
        $osName = [string]$Report.scan.host.os
        $osVersion = [string]$Report.scan.host.version
    }

    $cleanChecks = New-Object System.Collections.Generic.List[object]
    $checksSource = @()
    if ($null -ne $Readiness.checks) {
        $checksSource = @($Readiness.checks)
    }
    elseif ($Readiness -is [array] -or $Readiness -is [System.Collections.IList]) {
        $checksSource = @($Readiness)
    }
    foreach ($c in $checksSource) {
        if ($null -eq $c) { continue }
        [void]$cleanChecks.Add([pscustomobject][ordered]@{
            id       = [string]$c.id
            ok       = [bool]$c.ok
            severity = [string]$c.severity
            message  = [string]$c.message
        })
    }

    $sourceFinishedAt = $null
    if ($null -ne $Report.scan -and $null -ne $Report.scan.finishedAt) {
        $sourceFinishedAt = [string]$Report.scan.finishedAt
    }
    $traceCount = 0
    if ($null -ne $Report.traces) {
        $traceCount = @($Report.traces).Count
    }
    elseif ($null -ne $Report.sourceRun -and $null -ne $Report.sourceRun.traces) {
        $traceCount = [int]$Report.sourceRun.traces
    }

    $notesList = @()
    if ($null -ne $Notes -and $Notes.Count -gt 0) {
        $notesList = @($Notes | ForEach-Object { [string]$_ })
    }
    else {
        $notesList = @(
            'This record was generated prior to initiating the operating system erase procedure.',
            'This record is unsigned and does not constitute an independent third-party verification.',
            'Cryptographic erase relies on destruction of the volume encryption key by the operating system reset mechanism.'
        )
    }

    $raw = [pscustomobject][ordered]@{
        schemaVersion = $script:VacateEraseRecordSchemaVersion
        kind          = $script:VacateEraseRecordKind
        signed        = $false
        tool          = [pscustomobject][ordered]@{
            name    = $script:VacateToolName
            version = $script:VacateToolVersion
        }
        createdAt     = (ConvertTo-VacateIsoTime $Now)
        machine       = [string]$Machine
        operator      = [string]$Operator
        platform      = $platform
        os            = [pscustomobject][ordered]@{
            name    = $osName
            version = $osVersion
        }
        disk          = [pscustomobject][ordered]@{
            model     = if ($null -ne $SystemDisk.model) { [string]$SystemDisk.model } else { $null }
            serial    = if ($null -ne $SystemDisk.serial) { [string]$SystemDisk.serial } else { $null }
            sizeBytes = if ($null -ne $SystemDisk.sizeBytes) { [long]$SystemDisk.sizeBytes } else { $null }
            busType   = if ($null -ne $SystemDisk.busType) { [string]$SystemDisk.busType } else { $null }
        }
        encryption    = [pscustomobject][ordered]@{
            kind         = if ($null -ne $SystemDisk.encryption -and $null -ne $SystemDisk.encryption.kind) { [string]$SystemDisk.encryption.kind } else { 'unknown' }
            protectionOn = if ($null -ne $SystemDisk.encryption -and $null -ne $SystemDisk.encryption.protectionOn) { [bool]$SystemDisk.encryption.protectionOn } else { $null }
        }
        method        = $Method
        standard      = $script:VacateEraseStandard
        readiness     = $cleanChecks.ToArray()
        sourceRun     = [pscustomobject][ordered]@{
            finishedAt = $sourceFinishedAt
            traces     = $traceCount
        }
        notes         = $notesList
    }

    $canonicalBody = Get-VacateEraseRecordCanonicalBody -Record $raw
    $canonicalJson = ConvertTo-VacateCanonicalJson -InputObject $canonicalBody
    $sha256 = Get-VacateSha256Hex -Text $canonicalJson

    return [pscustomobject][ordered]@{
        schemaVersion = $canonicalBody.schemaVersion
        kind          = $canonicalBody.kind
        signed        = $canonicalBody.signed
        tool          = $canonicalBody.tool
        createdAt     = $canonicalBody.createdAt
        machine       = $canonicalBody.machine
        operator      = $canonicalBody.operator
        platform      = $canonicalBody.platform
        os            = $canonicalBody.os
        disk          = $canonicalBody.disk
        encryption    = $canonicalBody.encryption
        method        = $canonicalBody.method
        standard      = $canonicalBody.standard
        readiness     = $canonicalBody.readiness
        sourceRun     = $canonicalBody.sourceRun
        notes         = $canonicalBody.notes
        sha256        = $sha256
    }
}

function ConvertTo-VacateEraseRecordJson {
    <#
    .SYNOPSIS
        Converts an erase record object to canonical JSON (DECISIONS D56).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Record)

    $canonicalBody = Get-VacateEraseRecordCanonicalBody -Record $Record
    $sha = $null
    if ($null -ne $Record.sha256 -and -not [string]::IsNullOrWhiteSpace([string]$Record.sha256)) {
        $sha = [string]$Record.sha256
    }
    else {
        $bodyJson = ConvertTo-VacateCanonicalJson -InputObject $canonicalBody
        $sha = Get-VacateSha256Hex -Text $bodyJson
    }

    $full = [pscustomobject][ordered]@{
        schemaVersion = $canonicalBody.schemaVersion
        kind          = $canonicalBody.kind
        signed        = $canonicalBody.signed
        tool          = $canonicalBody.tool
        createdAt     = $canonicalBody.createdAt
        machine       = $canonicalBody.machine
        operator      = $canonicalBody.operator
        platform      = $canonicalBody.platform
        os            = $canonicalBody.os
        disk          = $canonicalBody.disk
        encryption    = $canonicalBody.encryption
        method        = $canonicalBody.method
        standard      = $canonicalBody.standard
        readiness     = $canonicalBody.readiness
        sourceRun     = $canonicalBody.sourceRun
        notes         = $canonicalBody.notes
        sha256        = $sha
    }
    return (ConvertTo-VacateCanonicalJson -InputObject $full)
}

function ConvertTo-VacateEraseRecordMarkdown {
    <#
    .SYNOPSIS
        Converts an erase record to reader-friendly Markdown (<= 100 columns) (DECISIONS D56).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Record)

    $machine = [string]$Record.machine
    $serial = if ($null -ne $Record.disk -and $null -ne $Record.disk.serial) { [string]$Record.disk.serial } else { '(unknown)' }
    $model = if ($null -ne $Record.disk -and $null -ne $Record.disk.model) { [string]$Record.disk.model } else { '(unknown)' }
    $method = [string]$Record.method
    $createdAt = [string]$Record.createdAt
    $operator = [string]$Record.operator
    $platform = [string]$Record.platform
    $sizeBytes = if ($null -ne $Record.disk -and $null -ne $Record.disk.sizeBytes) { [long]$Record.disk.sizeBytes } else { $null }
    $busType = if ($null -ne $Record.disk -and $null -ne $Record.disk.busType) { [string]$Record.disk.busType } else { '(unknown)' }
    $encKind = if ($null -ne $Record.encryption -and $null -ne $Record.encryption.kind) { [string]$Record.encryption.kind } else { 'unknown' }
    $protectionOn = if ($null -ne $Record.encryption) { $Record.encryption.protectionOn } else { $null }
    $osName = if ($null -ne $Record.os -and $null -ne $Record.os.name) { [string]$Record.os.name } else { '(unknown)' }
    $osVersion = if ($null -ne $Record.os -and $null -ne $Record.os.version) { [string]$Record.os.version } else { '(unknown)' }

    $lines = New-Object System.Collections.Generic.List[string]

    [void]$lines.Add('# Erase Record')
    [void]$lines.Add('')
    [void]$lines.Add('**Notice:** This record is not signed and is not an independent verification.')
    [void]$lines.Add('')
    [void]$lines.Add('## Summary')
    [void]$lines.Add('')
    [void]$lines.Add("- **Machine:** $machine")
    [void]$lines.Add("- **Disk Serial:** $serial")
    [void]$lines.Add("- **Erase Method:** $method")
    [void]$lines.Add("- **Date:** $createdAt")
    [void]$lines.Add("- **Operator:** $operator")
    [void]$lines.Add("- **Platform:** $platform")
    [void]$lines.Add('- **Status:** Unsigned (Phase 5 will add cryptographic signature)')
    [void]$lines.Add('')
    [void]$lines.Add('## Standard')
    [void]$lines.Add('')
    [void]$lines.Add('NIST SP 800-88 Rev. 2 cryptographic erase via the operating system')
    [void]$lines.Add('(not independently verified).')
    [void]$lines.Add('')
    [void]$lines.Add('## System Disk')
    [void]$lines.Add('')
    [void]$lines.Add("- **Model:** $model")
    [void]$lines.Add("- **Serial:** $serial")
    if ($null -ne $sizeBytes) {
        $sizeFormatted = $sizeBytes.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)
        $sizeHuman = Format-VacateByteSize -Bytes $sizeBytes
        [void]$lines.Add("- **Size:** $sizeFormatted bytes ($sizeHuman)")
    }
    else {
        [void]$lines.Add('- **Size:** (unknown)')
    }
    [void]$lines.Add("- **Bus Type:** $busType")
    $protStr = 'Unknown'
    if ($protectionOn -eq $true) { $protStr = 'On' }
    elseif ($protectionOn -eq $false) { $protStr = 'Off' }
    [void]$lines.Add("- **Encryption:** $encKind (Protection: $protStr)")
    [void]$lines.Add('')
    [void]$lines.Add('## Operating System')
    [void]$lines.Add('')
    [void]$lines.Add("- **OS:** $osName")
    [void]$lines.Add("- **Version:** $osVersion")
    [void]$lines.Add('')
    [void]$lines.Add('## Source Scan')
    [void]$lines.Add('')
    $finishedAt = if ($null -ne $Record.sourceRun -and $null -ne $Record.sourceRun.finishedAt) { [string]$Record.sourceRun.finishedAt } else { '(unknown)' }
    $traces = if ($null -ne $Record.sourceRun -and $null -ne $Record.sourceRun.traces) { [string]$Record.sourceRun.traces } else { '0' }
    [void]$lines.Add("- **Scan Finished:** $finishedAt")
    [void]$lines.Add("- **Traces Found:** $traces")
    [void]$lines.Add('')
    [void]$lines.Add('## Readiness Checks')
    [void]$lines.Add('')
    $checks = @()
    if ($null -ne $Record.readiness) { $checks = @($Record.readiness) }
    if ($checks.Count -eq 0) {
        [void]$lines.Add('No readiness checks recorded.')
    }
    else {
        foreach ($c in $checks) {
            $status = if ($c.ok) { 'PASS' } else { 'FAIL' }
            $sev = [string]$c.severity
            $msg = [string]$c.message
            $entryText = "- [$status] $($c.id) ($sev): $msg"
            foreach ($wrapped in (Format-VacateWrappedText -Text $entryText -Width 96 -Indent '')) {
                [void]$lines.Add($wrapped)
            }
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Notes')
    [void]$lines.Add('')
    $notes = @()
    if ($null -ne $Record.notes) { $notes = @($Record.notes) }
    if ($notes.Count -eq 0) {
        [void]$lines.Add('No additional notes.')
    }
    else {
        foreach ($n in $notes) {
            foreach ($wrapped in (Format-VacateWrappedText -Text ("- " + [string]$n) -Width 96 -Indent '')) {
                [void]$lines.Add($wrapped)
            }
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('## SHA-256 Fingerprint')
    [void]$lines.Add('')
    [void]$lines.Add('Canonical body SHA-256 (excludes the sha256 property itself):')
    [void]$lines.Add([string]$Record.sha256)
    [void]$lines.Add('')

    # Defensive final pass: wrap any line > 100 columns just in case.
    $finalLines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if ($l.Length -gt 100) {
            foreach ($w in (Format-VacateWrappedText -Text $l -Width 96 -Indent '')) {
                $finalLines.Add($w)
            }
        }
        else {
            $finalLines.Add($l)
        }
    }

    return ($finalLines -join "`n")
}

function Test-VacateEraseRecord {
    <#
    .SYNOPSIS
        Validates an erase record JSON string, checking required fields and recomputing SHA-256 (DECISIONS D56).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    $problems = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Json)) {
        $problems.Add('erase record JSON is empty or whitespace.')
        return [pscustomobject][ordered]@{ valid = $false; problems = $problems.ToArray() }
    }

    $obj = $null
    try {
        $obj = ConvertFrom-VacateJson -Json $Json
    }
    catch {
        $problems.Add("invalid JSON: $($_.Exception.Message)")
        return [pscustomobject][ordered]@{ valid = $false; problems = $problems.ToArray() }
    }

    $requiredFields = @(
        'schemaVersion', 'kind', 'signed', 'tool', 'createdAt',
        'machine', 'operator', 'platform', 'os', 'disk',
        'encryption', 'method', 'standard', 'readiness', 'sourceRun',
        'notes', 'sha256'
    )

    $actualProps = @{}
    if ($null -ne $obj.PSObject) {
        foreach ($p in $obj.PSObject.Properties) {
            $actualProps[$p.Name] = $true
        }
    }

    foreach ($f in $requiredFields) {
        if (-not $actualProps.ContainsKey($f)) {
            $problems.Add("missing required field '$f'.")
        }
    }

    # Verify unexpected fields
    foreach ($propName in $actualProps.Keys) {
        if ($requiredFields -notcontains $propName) {
            $problems.Add("unexpected field '$propName'.")
        }
    }

    # Validate top-level property semantics
    if ($actualProps.ContainsKey('schemaVersion') -and [string]$obj.schemaVersion -ne '1.0') {
        $problems.Add("schemaVersion must be '1.0', got '$($obj.schemaVersion)'.")
    }
    if ($actualProps.ContainsKey('kind') -and [string]$obj.kind -ne 'vacate-erase-record') {
        $problems.Add("kind must be 'vacate-erase-record', got '$($obj.kind)'.")
    }
    if ($actualProps.ContainsKey('signed') -and [bool]$obj.signed -ne $false) {
        $problems.Add('signed must be false for Phase 4 records.')
    }
    if ($actualProps.ContainsKey('method') -and ($script:VacateEraseMethods -notcontains [string]$obj.method)) {
        $problems.Add("invalid method '$($obj.method)'.")
    }
    if ($actualProps.ContainsKey('platform') -and ($script:VacatePlatforms -notcontains [string]$obj.platform)) {
        $problems.Add("invalid platform '$($obj.platform)'.")
    }
    if ($actualProps.ContainsKey('standard') -and [string]$obj.standard -ne $script:VacateEraseStandard) {
        $problems.Add("standard mismatch: expected '$script:VacateEraseStandard'.")
    }
    if ($actualProps.ContainsKey('sha256') -and (-not ([string]$obj.sha256 -match '^[0-9a-f]{64}$'))) {
        $problems.Add('sha256 must be a 64-character lowercase hexadecimal string.')
    }

    # Check nested structures if present
    if ($actualProps.ContainsKey('tool') -and ($null -eq $obj.tool -or [string]$obj.tool.name -ne 'vacate')) {
        $problems.Add("tool.name must be 'vacate'.")
    }
    if ($actualProps.ContainsKey('disk') -and $null -eq $obj.disk) {
        $problems.Add('disk object is required.')
    }
    if ($actualProps.ContainsKey('encryption') -and $null -eq $obj.encryption) {
        $problems.Add('encryption object is required.')
    }
    if ($actualProps.ContainsKey('readiness') -and $null -eq $obj.readiness) {
        $problems.Add('readiness checks array is required.')
    }

    # Recompute and compare SHA-256 fingerprint of canonical body
    if ($problems.Count -eq 0 -or ($actualProps.ContainsKey('sha256') -and $actualProps.ContainsKey('machine'))) {
        try {
            $canonicalBody = Get-VacateEraseRecordCanonicalBody -Record $obj
            $bodyJson = ConvertTo-VacateCanonicalJson -InputObject $canonicalBody
            $recomputedSha = Get-VacateSha256Hex -Text $bodyJson
            if ($actualProps.ContainsKey('sha256') -and [string]$obj.sha256 -ne $recomputedSha) {
                $problems.Add("sha256 mismatch: recorded '$($obj.sha256)', recomputed '$recomputedSha'.")
            }
        }
        catch {
            $problems.Add("error recomputing sha256: $($_.Exception.Message)")
        }
    }

    return [pscustomobject][ordered]@{
        valid    = ($problems.Count -eq 0)
        problems = $problems.ToArray()
    }
}
