# Undo.ps1 - Phase 3: the undo log that records every move to the Recycle Bin or Trash.
# PowerShell 5.1 compatible. ASCII only.
# Pure functions, no I/O: the caller writes the JSON through Output.ps1 after every move and
# reads it back for `vacate undo`. (DECISIONS D50, D53)
# Add-VacateUndoEntry and Set-VacateUndoRestored never change the log they are given; they return
# a new log, so the caller writes `$log = Add-VacateUndoEntry -Log $log ...`.
# Entry indexes start at 1 and follow the order of the moves.

$script:VacateUndoSchemaVersion = '1.0'
$script:VacateUndoTimeFormat = 'yyyy-MM-ddTHH:mm:ssZ'
$script:VacateUndoTopFields = @('schemaVersion', 'tool', 'platform', 'machine', 'run', 'createdAt', 'entries')
$script:VacateUndoToolFields = @('name', 'version')
$script:VacateUndoEntryFields = @('index', 'step', 'ruleId', 'originalPath', 'trashLocation', 'isDirectory', 'sizeBytes', 'movedAt', 'restoredAt')

function ConvertTo-VacateUndoTime {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Now)
    return $Now.ToUniversalTime().ToString($script:VacateUndoTimeFormat, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-VacateUndoTime {
    # Parses a log time string; throws when it is not exactly yyyy-MM-ddTHH:mm:ssZ.
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][AllowNull()][object]$Value, [Parameter(Mandatory)][string]$Field)
    if ($Value -isnot [string]) { throw "undo log: $Field must be a time string." }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Value, $script:VacateUndoTimeFormat, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)
    if (-not $ok) { throw "undo log: $Field '$Value' is not a UTC time like 2026-01-31T12:00:00Z." }
    return $parsed
}

function Test-VacateUndoInteger {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or
        $Value -is [uint16] -or $Value -is [uint32])
}

function Get-VacateUndoField {
    # Returns a required property value; throws when it is missing. Unknown properties are refused
    # so the log matches schemas/undo.schema.json (additionalProperties false).
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$Fields,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where
    )
    if ($null -eq $Object -or $Object -is [string] -or $Object -is [array] -or $Object -is [ValueType]) {
        throw "undo log: $Where must be an object."
    }
    $props = @($Object.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
    foreach ($p in $props) {
        if ($Fields -notcontains $p.Name) { throw "undo log: $Where has an unknown field '$($p.Name)'." }
    }
    $match = @($props | Where-Object { $_.Name -ceq $Name })
    if ($match.Count -eq 0) { throw "undo log: $Where is missing the field '$Name'." }
    return , $match[0].Value
}

function Test-VacateUndoText {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][object]$Value)
    return ($Value -is [string] -and $Value.Length -gt 0)
}

function ConvertTo-VacateUndoEntry {
    # Validates one entry and rebuilds it with the fixed property order.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()][object]$Entry, [Parameter(Mandatory)][int]$Position)
    $where = "entry $Position"
    $f = $script:VacateUndoEntryFields
    $index = Get-VacateUndoField -Object $Entry -Fields $f -Name 'index' -Where $where
    $step = Get-VacateUndoField -Object $Entry -Fields $f -Name 'step' -Where $where
    $ruleId = Get-VacateUndoField -Object $Entry -Fields $f -Name 'ruleId' -Where $where
    $original = Get-VacateUndoField -Object $Entry -Fields $f -Name 'originalPath' -Where $where
    $trash = Get-VacateUndoField -Object $Entry -Fields $f -Name 'trashLocation' -Where $where
    $isDir = Get-VacateUndoField -Object $Entry -Fields $f -Name 'isDirectory' -Where $where
    $size = Get-VacateUndoField -Object $Entry -Fields $f -Name 'sizeBytes' -Where $where
    $movedAt = Get-VacateUndoField -Object $Entry -Fields $f -Name 'movedAt' -Where $where
    $restoredAt = Get-VacateUndoField -Object $Entry -Fields $f -Name 'restoredAt' -Where $where

    if (-not (Test-VacateUndoInteger $index)) { throw "undo log: $where index must be an integer." }
    if ([long]$index -ne $Position) { throw "undo log: $where has index $index; indexes must run 1, 2, 3 in order." }
    if (-not (Test-VacateUndoInteger $step) -or [long]$step -lt 1) { throw "undo log: $where step must be an integer of 1 or more." }
    if (-not (Test-VacateUndoText $ruleId)) { throw "undo log: $where ruleId must be a non-empty string." }
    if (-not (Test-VacateUndoText $original)) { throw "undo log: $where originalPath must be a non-empty string." }
    if ($null -ne $trash -and -not (Test-VacateUndoText $trash)) { throw "undo log: $where trashLocation must be a non-empty string or null." }
    if ($isDir -isnot [bool]) { throw "undo log: $where isDirectory must be true or false." }
    if ($null -ne $size -and (-not (Test-VacateUndoInteger $size) -or [long]$size -lt 0)) {
        throw "undo log: $where sizeBytes must be a non-negative integer or null."
    }
    $movedTime = ConvertFrom-VacateUndoTime -Value $movedAt -Field "$where movedAt"
    if ($null -ne $restoredAt) {
        $restoredTime = ConvertFrom-VacateUndoTime -Value $restoredAt -Field "$where restoredAt"
        if ($restoredTime -lt $movedTime) { throw "undo log: $where restoredAt $restoredAt is earlier than movedAt $movedAt." }
    }

    $sizeOut = $null
    if ($null -ne $size) { $sizeOut = [long]$size }
    return [pscustomobject][ordered]@{
        index         = [int]$index
        step          = [int]$step
        ruleId        = [string]$ruleId
        originalPath  = [string]$original
        trashLocation = $trash
        isDirectory   = [bool]$isDir
        sizeBytes     = $sizeOut
        movedAt       = [string]$movedAt
        restoredAt    = $restoredAt
    }
}

function ConvertTo-VacateUndoLogObject {
    # Validates a whole log and rebuilds it with the fixed property order. Throws on a bad log.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()][object]$Log)
    $f = $script:VacateUndoTopFields
    $schemaVersion = Get-VacateUndoField -Object $Log -Fields $f -Name 'schemaVersion' -Where 'the log'
    $tool = Get-VacateUndoField -Object $Log -Fields $f -Name 'tool' -Where 'the log'
    $platform = Get-VacateUndoField -Object $Log -Fields $f -Name 'platform' -Where 'the log'
    $machine = Get-VacateUndoField -Object $Log -Fields $f -Name 'machine' -Where 'the log'
    $run = Get-VacateUndoField -Object $Log -Fields $f -Name 'run' -Where 'the log'
    $createdAt = Get-VacateUndoField -Object $Log -Fields $f -Name 'createdAt' -Where 'the log'
    $entries = Get-VacateUndoField -Object $Log -Fields $f -Name 'entries' -Where 'the log'

    if ($schemaVersion -isnot [string] -or $schemaVersion -cne $script:VacateUndoSchemaVersion) {
        throw "undo log: schemaVersion '$schemaVersion' is not supported (expected '$($script:VacateUndoSchemaVersion)')."
    }
    $toolName = Get-VacateUndoField -Object $tool -Fields $script:VacateUndoToolFields -Name 'name' -Where 'tool'
    $toolVersion = Get-VacateUndoField -Object $tool -Fields $script:VacateUndoToolFields -Name 'version' -Where 'tool'
    if ($toolName -isnot [string] -or $toolName -cne $script:VacateToolName) { throw "undo log: tool.name must be '$($script:VacateToolName)'." }
    if ($toolVersion -isnot [string] -or $toolVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'undo log: tool.version must look like 1.2.3.' }
    if ($platform -isnot [string] -or $script:VacatePlatforms -cnotcontains $platform) { throw "undo log: platform '$platform' is not one of $($script:VacatePlatforms -join ', ')." }
    if (-not (Test-VacateUndoText $machine)) { throw 'undo log: machine must be a non-empty string.' }
    if (-not (Test-VacateUndoText $run) -or $run -match '[\\/]') { throw 'undo log: run must be a run folder name, not a path.' }
    $null = ConvertFrom-VacateUndoTime -Value $createdAt -Field 'createdAt'
    if ($null -eq $entries -or $entries -isnot [array]) { throw 'undo log: entries must be a list.' }

    $built = New-Object System.Collections.Generic.List[object]
    $pos = 0
    foreach ($e in $entries) {
        $pos++
        $built.Add((ConvertTo-VacateUndoEntry -Entry $e -Position $pos))
    }
    return [pscustomobject][ordered]@{
        schemaVersion = $script:VacateUndoSchemaVersion
        tool          = [pscustomobject][ordered]@{ name = [string]$toolName; version = [string]$toolVersion }
        platform      = [string]$platform
        machine       = [string]$machine
        run           = [string]$run
        createdAt     = [string]$createdAt
        entries       = [object[]]$built.ToArray()
    }
}

function New-VacateUndoLog {
    # An empty undo log for one clean run (D53).
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][string]$Run,
        [Parameter(Mandatory)][datetime]$Now
    )
    $log = [pscustomobject][ordered]@{
        schemaVersion = $script:VacateUndoSchemaVersion
        tool          = [pscustomobject][ordered]@{ name = $script:VacateToolName; version = $script:VacateToolVersion }
        platform      = $Platform
        machine       = $Machine
        run           = $Run
        createdAt     = (ConvertTo-VacateUndoTime -Now $Now)
        entries       = [object[]]@()
    }
    return (ConvertTo-VacateUndoLogObject -Log $log)
}

function Add-VacateUndoEntry {
    # Returns a new log with one more entry for a move that just happened (D53).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Log,
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$OriginalPath,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TrashLocation,
        [Parameter(Mandatory)][bool]$IsDirectory,
        [Parameter(Mandatory)][AllowNull()][Nullable[long]]$SizeBytes,
        [Parameter(Mandatory)][datetime]$Now
    )
    $current = ConvertTo-VacateUndoLogObject -Log $Log
    # A [string] parameter turns $null into ''; the log stores null for "no Trash location".
    $trash = $null
    if (-not [string]::IsNullOrEmpty($TrashLocation)) { $trash = $TrashLocation }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($e in $current.entries) { $entries.Add($e) }
    $entries.Add([pscustomobject][ordered]@{
            index         = $entries.Count + 1
            step          = $Step
            ruleId        = $RuleId
            originalPath  = $OriginalPath
            trashLocation = $trash
            isDirectory   = $IsDirectory
            sizeBytes     = $SizeBytes
            movedAt       = (ConvertTo-VacateUndoTime -Now $Now)
            restoredAt    = $null
        })
    $current.entries = [object[]]$entries.ToArray()
    return (ConvertTo-VacateUndoLogObject -Log $current)
}

function Set-VacateUndoRestored {
    # Returns a new log in which entry -Index is marked as restored at -Now (D53).
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a new in-memory object; changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Log,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][datetime]$Now
    )
    $current = ConvertTo-VacateUndoLogObject -Log $Log
    $match = @($current.entries | Where-Object { $_.index -eq $Index })
    if ($match.Count -ne 1) { throw "undo log: there is no entry with index $Index." }
    $entry = $match[0]
    if ($null -ne $entry.restoredAt) { throw "undo log: entry $Index was already restored at $($entry.restoredAt)." }
    $entry.restoredAt = ConvertTo-VacateUndoTime -Now $Now
    # Re-validating catches a restore time earlier than the move time.
    return (ConvertTo-VacateUndoLogObject -Log $current)
}

function ConvertTo-VacateUndoJson {
    # Deterministic JSON: the log is validated and rebuilt in the fixed property order first.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Log)
    $clean = ConvertTo-VacateUndoLogObject -Log $Log
    return (($clean | ConvertTo-Json -Depth 10) -replace "`r`n", "`n")
}

function ConvertFrom-VacateUndoJson {
    # Parses and validates undo.json; throws on a log that is malformed or not version 1.0.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'undo log: the file is empty.' }
    try { $obj = ConvertFrom-VacateJson -Json $Json }
    catch { throw "undo log: not valid JSON ($($_.Exception.Message))." }
    return (ConvertTo-VacateUndoLogObject -Log $obj)
}
