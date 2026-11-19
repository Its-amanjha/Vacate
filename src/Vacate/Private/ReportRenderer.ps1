# ReportRenderer.ps1 - turns a report object into HTML and Markdown.
# PowerShell 5.1 compatible. ASCII only.
# Every value from the report goes through ConvertTo-VacateHtmlText (WebUtility.HtmlEncode).
# No script, no external fonts, no CDN: the page must read with JavaScript off and print cleanly.

function ConvertTo-VacateHtmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-VacateRuleInfoMap {
    # id -> catalog rule entry (from report.catalog.rules).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object]$Report)
    $map = @{}
    foreach ($r in @($Report.catalog.rules)) { if ($null -ne $r) { $map[[string]$r.id] = $r } }
    return $map
}

function Get-VacateSummarySentence {
    # One plain-language paragraph shared by HTML and Markdown.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Report)
    $s = $Report.summary
    $cats = @($s.byCategory | Where-Object { $_.traces -gt 0 }).Count
    $complete = 'The scan finished completely.'
    if (-not $Report.scan.complete) { $complete = 'The scan did NOT finish (time budget or errors), so this list is incomplete.' }
    if ([int]$s.tracesFound -eq 0) {
        $found = 'vacate found no traces in the locations it knows about.'
    }
    else {
        $found = ('vacate found {0} traces in {1} categories, taking {2} in total.' -f $s.tracesFound, $cats, (Format-VacateByteSize $s.totalBytes))
    }
    $rules = (' {0} rules ran, {1} were skipped and {2} failed.' -f $s.rulesRun, $s.rulesSkipped, $s.rulesFailed)
    $limit = ' A short list does not mean the machine is clean; read "What this does not see".'
    return ($found + ' ' + $complete + $rules + $limit)
}

$script:VacateReportCss = @'
:root { --fg:#1b1b1f; --muted:#5b5b66; --bg:#ffffff; --card:#f6f6f8; --line:#d9d9e0; --warn-bg:#fff4e5; --warn-fg:#7a3d00; --crit:#a10f2b; --high:#b34700; --med:#6b5a00; --low:#3d5a3d; }
@media (prefers-color-scheme: dark) { :root { --fg:#ececf1; --muted:#a8a8b3; --bg:#141418; --card:#1f1f25; --line:#34343d; --warn-bg:#3a2a12; --warn-fg:#ffd9a8; --crit:#ff7a90; --high:#ffad66; --med:#e6d36b; --low:#9ccc9c; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, Ubuntu, sans-serif; }
main { max-width: 980px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 26px; margin: 0 0 4px; } h2 { font-size: 20px; margin: 36px 0 10px; border-bottom: 1px solid var(--line); padding-bottom: 4px; }
h3 { font-size: 16px; margin: 20px 0 8px; }
.muted { color: var(--muted); }
.warn { background: var(--warn-bg); color: var(--warn-fg); border-radius: 6px; padding: 10px 14px; margin: 14px 0; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 14px; }
th, td { text-align: left; vertical-align: top; padding: 6px 8px; border-bottom: 1px solid var(--line); }
th { font-weight: 600; }
td.num, th.num { text-align: right; white-space: nowrap; }
.trace { background: var(--card); border-radius: 6px; padding: 10px 14px; margin: 8px 0; break-inside: avoid; }
.trace dl { display: grid; grid-template-columns: 9em 1fr; gap: 2px 12px; margin: 6px 0 0; font-size: 14px; }
.trace dt { color: var(--muted); } .trace dd { margin: 0; overflow-wrap: anywhere; }
code { font-family: ui-monospace, Consolas, "DejaVu Sans Mono", monospace; font-size: 13px; overflow-wrap: anywhere; }
.sev-critical { color: var(--crit); font-weight: 600; } .sev-high { color: var(--high); font-weight: 600; }
.sev-medium { color: var(--med); } .sev-low { color: var(--low); }
ol.checklist li { margin: 0 0 10px; } ol.checklist ul { margin: 4px 0 0; font-size: 14px; }
footer { margin-top: 40px; font-size: 13px; color: var(--muted); }
@media print { body { background:#fff; color:#000; font-size: 11pt; } main { max-width: none; padding: 0; } .trace { border: 1px solid #ccc; background: #fff; } h2 { break-after: avoid; } }
'@

function ConvertTo-VacateReportHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Checklist
    )
    $h = { param($v) ConvertTo-VacateHtmlText $v }
    $info = Get-VacateRuleInfoMap -Report $Report
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    $scan = $Report.scan
    $hostInfo = $scan.host

    [void]$sb.Append('<!DOCTYPE html>' + $nl + '<html lang="en"><head><meta charset="utf-8">' + $nl)
    [void]$sb.Append('<meta name="viewport" content="width=device-width, initial-scale=1">' + $nl)
    [void]$sb.Append('<meta name="robots" content="noindex">' + $nl)
    [void]$sb.Append('<title>vacate report - ' + (& $h $hostInfo.name) + '</title>' + $nl)
    [void]$sb.Append('<style>' + $script:VacateReportCss + '</style></head><body><main>' + $nl)

    # 1. Header
    [void]$sb.Append('<header><h1>Handover report</h1>' + $nl)
    $elev = 'no'
    if ($scan.elevated) { $elev = 'yes' }
    $redacted = ''
    if ($scan.redacted) { $redacted = ' &middot; <strong>redacted</strong>' }
    [void]$sb.Append(('<p class="muted">{0} &middot; machine <strong>{1}</strong> &middot; user <strong>{2}</strong> &middot; {3} &middot; elevated: {4} &middot; vacate {5}{6}</p>' -f (& $h $scan.platform), (& $h $hostInfo.name), (& $h $hostInfo.user), (& $h $scan.finishedAt), $elev, (& $h $Report.tool.version), $redacted) + $nl)
    if (-not $scan.redacted) {
        [void]$sb.Append('<p class="warn"><strong>Sensitive:</strong> this report lists where your private data lives on this machine. Treat it like a password: do not share it. Use <code>-Redact</code> for a shareable version.</p>' + $nl)
    }
    [void]$sb.Append('</header>' + $nl)

    # 2. Summary
    [void]$sb.Append('<section><h2>Summary</h2><p>' + (& $h (Get-VacateSummarySentence -Report $Report)) + '</p></section>' + $nl)

    # 3. By category
    [void]$sb.Append('<section><h2>By category</h2><table><thead><tr><th>Category</th><th class="num">Traces</th><th class="num">Size</th><th>Highest sensitivity</th><th>What it means</th></tr></thead><tbody>' + $nl)
    foreach ($c in @($Report.summary.byCategory)) {
        [void]$sb.Append(('<tr><td>{0}</td><td class="num">{1}</td><td class="num">{2}</td><td class="sev-{3}">{3}</td><td>{4}</td></tr>' -f (& $h $c.category), (& $h $c.traces), (& $h (Format-VacateByteSize $c.sizeBytes)), (& $h $c.highestSensitivity), (& $h (Get-VacateCategoryMeaning $c.category))) + $nl)
    }
    if (@($Report.summary.byCategory).Count -eq 0) { [void]$sb.Append('<tr><td colspan="5">No traces found.</td></tr>' + $nl) }
    [void]$sb.Append('</tbody></table></section>' + $nl)

    # 4. Details
    [void]$sb.Append('<section><h2>Details</h2>' + $nl)
    $lastCat = $null
    foreach ($t in @($Report.traces)) {
        if ($t.category -cne $lastCat) { [void]$sb.Append('<h3>' + (& $h $t.category) + '</h3>' + $nl); $lastCat = $t.category }
        $r = $null
        if ($info.ContainsKey([string]$t.ruleId)) { $r = $info[[string]$t.ruleId] }
        $why = ''; $src = ''
        if ($null -ne $r) { $why = $r.whyItMatters; $src = $r.source }
        $size = Format-VacateByteSize $t.sizeBytes
        $count = '-'
        if ($null -ne $t.itemCount) { $count = [string]$t.itemCount }
        if ($t.truncated) { $count = $count + ' (stopped at the limit; real count is higher)' }
        $verified = 'not yet verified on a real machine'
        if ($t.confidence -ceq 'verified') { $verified = 'verified' }
        [void]$sb.Append('<div class="trace"><strong>' + (& $h $t.title) + '</strong> <span class="sev-' + (& $h $t.sensitivity) + '">' + (& $h $t.sensitivity) + '</span>')
        if ($why) { [void]$sb.Append('<div>' + (& $h $why) + '</div>') }
        [void]$sb.Append('<dl>')
        [void]$sb.Append('<dt>Location</dt><dd><code>' + (& $h $t.locator.resolved) + '</code></dd>')
        [void]$sb.Append('<dt>Size / items</dt><dd>' + (& $h $size) + ' / ' + (& $h $count) + '</dd>')
        $lw = '-'
        if ($t.lastWriteTime) { $lw = $t.lastWriteTime }
        [void]$sb.Append('<dt>Last modified</dt><dd>' + (& $h $lw) + '</dd>')
        if (@($t.samples).Count -gt 0) { [void]$sb.Append('<dt>Examples</dt><dd><code>' + (& $h ((@($t.samples)) -join ', ')) + '</code></dd>') }
        [void]$sb.Append('<dt>Rule</dt><dd><code>' + (& $h $t.ruleId) + '</code> &middot; ' + (& $h $verified) + '</dd>')
        if ($src) { [void]$sb.Append('<dt>Source</dt><dd>' + (& $h $src) + '</dd>') }
        if ($t.error) { [void]$sb.Append('<dt>Note</dt><dd>' + (& $h $t.error) + '</dd>') }
        [void]$sb.Append('</dl></div>' + $nl)
    }
    if (@($Report.traces).Count -eq 0) { [void]$sb.Append('<p>No traces found.</p>' + $nl) }
    [void]$sb.Append('</section>' + $nl)

    # 5. Checklist
    [void]$sb.Append('<section><h2>De-link checklist</h2><p class="muted">Do these in order. Sign out and export before you uninstall anything.</p><ol class="checklist">' + $nl)
    foreach ($s in $Checklist) {
        [void]$sb.Append('<li><strong>' + (& $h $s.title) + '</strong><br>' + (& $h $s.detail))
        if (@($s.traces).Count -gt 0) {
            [void]$sb.Append('<ul>')
            foreach ($tr in $s.traces) { [void]$sb.Append('<li>' + (& $h $tr.title) + ' <code>' + (& $h $tr.ruleId) + '</code> (' + (& $h $tr.count) + ')</li>') }
            [void]$sb.Append('</ul>')
        }
        [void]$sb.Append('</li>' + $nl)
    }
    [void]$sb.Append('</ol></section>' + $nl)

    # 6. Installed programs
    [void]$sb.Append('<section><h2>Installed programs</h2>' + $nl)
    $progs = @($Report.installedPrograms)
    if ($progs.Count -eq 0) { [void]$sb.Append('<p class="muted">No installed-program list for this platform or scan.</p>' + $nl) }
    else {
        [void]$sb.Append('<table><thead><tr><th>Name</th><th>Publisher</th><th>Version</th><th>Installed</th><th>Scope</th></tr></thead><tbody>' + $nl)
        foreach ($p in $progs) {
            [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f (& $h $p.name), (& $h $p.publisher), (& $h $p.version), (& $h $p.installDate), (& $h $p.scope)) + $nl)
        }
        [void]$sb.Append('</tbody></table>' + $nl)
    }
    [void]$sb.Append('</section>' + $nl)

    # 7. Skipped and failed
    [void]$sb.Append('<section><h2>Skipped and failed</h2>' + $nl)
    $sk = @($Report.skipped); $er = @($Report.errors)
    if ($sk.Count + $er.Count -eq 0) { [void]$sb.Append('<p>Every applicable rule ran.</p>' + $nl) }
    else {
        [void]$sb.Append('<table><thead><tr><th>Rule</th><th>Reason</th><th>Detail</th></tr></thead><tbody>' + $nl)
        foreach ($x in $sk) { [void]$sb.Append(('<tr><td><code>{0}</code></td><td>{1}</td><td>{2}</td></tr>' -f (& $h $x.ruleId), (& $h $x.reason), (& $h $x.detail)) + $nl) }
        foreach ($x in $er) { [void]$sb.Append(('<tr><td><code>{0}</code></td><td>error</td><td>{1}: {2}</td></tr>' -f (& $h $x.ruleId), (& $h $x.type), (& $h $x.message)) + $nl) }
        [void]$sb.Append('</tbody></table>' + $nl)
    }
    [void]$sb.Append('</section>' + $nl)

    # 8. Limitations
    [void]$sb.Append('<section><h2>What this does not see</h2><ul>' + $nl)
    foreach ($l in @($Report.limitations)) { [void]$sb.Append('<li>' + (& $h $l.text) + '</li>' + $nl) }
    [void]$sb.Append('</ul></section>' + $nl)

    # 9. Methodology
    $unv = @($Report.catalog.unverified)
    [void]$sb.Append('<section><h2>Methodology</h2><ul>' + $nl)
    [void]$sb.Append('<li>Read-only: vacate never deletes, moves or changes anything, never opens file contents, and makes no network connections. It records names, sizes, counts and timestamps only.</li>' + $nl)
    [void]$sb.Append(('<li>Rule catalog {0}: {1} rules loaded, {2} not applicable to this platform, {3} invalid files ignored.</li>' -f (& $h $Report.catalog.version), (& $h $Report.catalog.rulesLoaded), (& $h $Report.summary.rulesNotApplicable), (& $h $Report.catalog.invalidFiles)) + $nl)
    [void]$sb.Append(('<li>Time budget {0} s for the whole scan, {1} s per rule. Started {2}, finished {3} ({4} ms).</li>' -f (& $h $scan.budgetSeconds), (& $h $scan.ruleTimeoutSeconds), (& $h $scan.startedAt), (& $h $scan.finishedAt), (& $h $scan.durationMs)) + $nl)
    if ($unv.Count -gt 0) {
        [void]$sb.Append(('<li>{0} rules are not yet verified on a real machine: <code>{1}</code></li>' -f $unv.Count, (& $h ($unv -join ', '))) + $nl)
    }
    else { [void]$sb.Append('<li>All rules that ran are verified on a real machine.</li>' + $nl) }
    [void]$sb.Append('</ul></section>' + $nl)

    [void]$sb.Append('<footer>For devices you own or are authorised to hand over. Not for destroying evidence, defeating a legal hold, or falsifying records.</footer>' + $nl)
    [void]$sb.Append('</main></body></html>' + $nl)
    return $sb.ToString()
}

function ConvertTo-VacateSummaryMarkdown {
    # Same facts as the HTML, no line wider than 100 characters, no file paths.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Report)
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    $add = { param($text, $indent) foreach ($l in (Format-VacateWrappedText -Text $text -Indent $indent)) { [void]$sb.Append($l + $nl) } }
    $scan = $Report.scan
    $s = $Report.summary

    [void]$sb.Append('# vacate summary' + $nl + $nl)
    & $add ('Machine: {0}. User: {1}. Platform: {2}. Scanned: {3}. Elevated: {4}. vacate {5}.' -f $scan.host.name, $scan.host.user, $scan.platform, $scan.finishedAt, $scan.elevated, $Report.tool.version) ''
    [void]$sb.Append($nl)
    & $add (Get-VacateSummarySentence -Report $Report) ''
    [void]$sb.Append($nl + '## Counts' + $nl + $nl)
    & $add ('- Traces found: {0}' -f $s.tracesFound) ''
    & $add ('- Total size: {0} ({1} bytes)' -f (Format-VacateByteSize $s.totalBytes), $s.totalBytes) ''
    & $add ('- Rules: {0} total, {1} ran, {2} skipped, {3} failed, {4} not applicable' -f $s.totalRules, $s.rulesRun, $s.rulesSkipped, $s.rulesFailed, $s.rulesNotApplicable) ''
    & $add ('- Scan complete: {0}' -f $scan.complete) ''
    [void]$sb.Append($nl + '## By category' + $nl + $nl)
    if (@($s.byCategory).Count -eq 0) { [void]$sb.Append('- none' + $nl) }
    foreach ($c in @($s.byCategory)) {
        & $add ('- {0}: {1} traces, {2}, highest sensitivity {3}' -f $c.category, $c.traces, (Format-VacateByteSize $c.sizeBytes), $c.highestSensitivity) ''
    }
    $sk = @($Report.skipped)
    if ($sk.Count -gt 0) {
        [void]$sb.Append($nl + '## Skipped' + $nl + $nl)
        $byReason = @{}
        foreach ($x in $sk) { $k = [string]$x.reason; if (-not $byReason.ContainsKey($k)) { $byReason[$k] = 0 }; $byReason[$k]++ }
        $keys = [string[]]@($byReason.Keys); [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($k in $keys) { & $add ('- {0}: {1}' -f $k, $byReason[$k]) '' }
    }
    $unv = @($Report.catalog.unverified)
    if ($unv.Count -gt 0) {
        [void]$sb.Append($nl)
        & $add ('{0} rules are not yet verified on a real machine.' -f $unv.Count) ''
    }
    [void]$sb.Append($nl + '## What this does not see' + $nl + $nl)
    foreach ($l in @($Report.limitations)) { & $add ('- ' + $l.text) '' }
    [void]$sb.Append($nl)
    & $add 'For devices you own or are authorised to hand over. Not for destroying evidence or defeating a legal hold.' ''
    return $sb.ToString()
}
