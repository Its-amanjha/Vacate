# Redaction.ps1 - makes a shareable copy of a report. Owner: Claude.
# PowerShell 5.1 compatible. ASCII only.
# Names and path segments become stable hashes (same input -> same hash within one report);
# counts, sizes, times, rule ids and catalog text are kept. The HMAC key is random per call and
# never stored, so hashes cannot be reversed or matched against another report (DECISIONS D25).

function New-VacateRedactor {
    # Returns an object with ScriptMethod Hash(string) -> 'h-' + 10 hex chars.
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    param([byte[]]$Key)
    if (-not $Key) {
        $Key = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($Key) } finally { $rng.Dispose() }
    }
    $hmac = New-Object Security.Cryptography.HMACSHA256 (, $Key)
    $obj = [pscustomobject]@{ Hmac = $hmac; Cache = @{} }
    $obj | Add-Member -MemberType ScriptMethod -Name Hash -Value {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        if ($this.Cache.ContainsKey($Text)) { return $this.Cache[$Text] }
        $bytes = $this.Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        $hex = -join ($bytes[0..4] | ForEach-Object { $_.ToString('x2') })
        $h = 'h-' + $hex
        $this.Cache[$Text] = $h
        return $h
    }
    return $obj
}

function ConvertTo-VacateRedactedPath {
    # Hashes every segment except structural ones: a drive (C:), a registry hive (HKCU/HKLM),
    # a WMI namespace prefix, the ' (32-bit)' marker, and an empty leading segment (Unix root).
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Path, [Parameter(Mandatory)][object]$Redactor)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $suffix = ''
    if ($Path.EndsWith(' (32-bit)')) { $suffix = ' (32-bit)'; $Path = $Path.Substring(0, $Path.Length - 9) }
    if ($Path -match '^(root(/[A-Za-z0-9_]+)*):([A-Za-z0-9_]+)(\[\d+\])$') {
        # WMI locator: namespace and class come from the rule, not the user; keep them.
        return $Path + $suffix
    }
    $sep = '/'
    if ($Path.IndexOf('\') -ge 0) { $sep = '\' }
    $parts = $Path.Split($sep)
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $parts.Length; $i++) {
        $p = $parts[$i]
        if ($p -eq '') { $out.Add($p); continue }
        if ($i -eq 0 -and ($p -match '^[A-Za-z]:$' -or $p -ceq 'HKCU' -or $p -ceq 'HKLM')) { $out.Add($p); continue }
        $out.Add($Redactor.Hash($p))
    }
    return (($out.ToArray()) -join $sep) + $suffix
}

function Protect-VacateReport {
    # Returns a redacted deep copy; the input is not modified.
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][object]$Report, [byte[]]$Key)

    $r = ConvertFrom-VacateJson -Json ($Report | ConvertTo-Json -Depth 20)
    $red = New-VacateRedactor -Key $Key
    $known = New-Object System.Collections.Generic.List[string]

    $hostInfo = $r.scan.host
    foreach ($field in @('name', 'user')) {
        $v = [string]$hostInfo.$field
        if ($v) { $known.Add($v); $hostInfo.$field = $red.Hash($v) }
    }
    foreach ($vol in @($hostInfo.volumes)) {
        if ($null -eq $vol) { continue }
        $v = [string]$vol.name
        if ($v) { $known.Add($v); $vol.name = $red.Hash($v) }
    }

    foreach ($t in @($r.traces)) {
        if ($null -eq $t) { continue }
        $orig = [string]$t.locator.resolved
        foreach ($seg in ($orig -split '[\\/]')) { if ($seg.Length -gt 2) { $known.Add($seg) } }
        $t.locator.resolved = ConvertTo-VacateRedactedPath -Path $orig -Redactor $red
        $samples = @()
        foreach ($s in @($t.samples)) { if ($null -ne $s) { $known.Add([string]$s); $samples += $red.Hash([string]$s) } }
        $t.samples = $samples
        if ($t.PSObject.Properties['properties'] -and $null -ne $t.properties) {
            foreach ($p in @($t.properties.PSObject.Properties)) {
                if ($p.Value -is [string] -and $p.Value.Length -gt 0) { $p.Value = $red.Hash([string]$p.Value) }
            }
        }
    }

    # Free text (skip details, error messages, trace errors) may echo a path or name: hash anything
    # that looks like a path FIRST (replacing a volume name like 'C:' first would hide the path from
    # the detector), then replace every remaining known raw string longer than 2 chars, longest first.
    $needles = @($known.ToArray() | Where-Object { $_ -and $_.Length -gt 2 } | Select-Object -Unique | Sort-Object -Property Length -Descending)
    $scrub = {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        # A path runs to the end of the clause, spaces included ("Private Thing"). Over-hashing a
        # trailing word is acceptable; leaking half a folder name is not. Plain loop, not a
        # MatchEvaluator scriptblock: those lose module scope on PowerShell 7.
        $ms = [regex]::Matches($Text, '(?:[A-Za-z]:\\|(?<![A-Za-z0-9])/)[^:;,''"\r\n]+')
        for ($i = $ms.Count - 1; $i -ge 0; $i--) {
            $m = $ms[$i]
            $rep = ConvertTo-VacateRedactedPath -Path $m.Value.TrimEnd() -Redactor $red
            $Text = $Text.Substring(0, $m.Index) + $rep + $Text.Substring($m.Index + $m.Length)
        }
        foreach ($n in $needles) { $Text = $Text.Replace($n, $red.Hash($n)) }
        return $Text
    }
    foreach ($t in @($r.traces)) { if ($null -ne $t -and $t.error) { $t.error = & $scrub ([string]$t.error) } }
    foreach ($s in @($r.skipped)) { if ($null -ne $s -and $s.detail) { $s.detail = & $scrub ([string]$s.detail) } }
    foreach ($e in @($r.errors)) { if ($null -ne $e -and $e.message) { $e.message = & $scrub ([string]$e.message) } }

    $r.scan.redacted = $true
    return $r
}
