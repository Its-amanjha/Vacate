# PlanRenderer.ps1 - turns a plan object into Markdown and HTML.
# PowerShell 5.1 compatible. ASCII only.
# Same rules as the report: every value is HTML-encoded, no script, no external resources,
# Markdown lines no wider than 100 characters.

function Get-VacatePlanStepHeading {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Step)
    return ('{0}. {1} ({2})' -f $Step.step, $Step.title, $Step.sensitivity)
}

function Get-VacatePlanLocationText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Location)
    $extra = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Location.sizeBytes) { $extra.Add((Format-VacateByteSize $Location.sizeBytes)) }
    if ($null -ne $Location.itemCount) { $extra.Add(([string]$Location.itemCount + ' items')) }
    $text = [string]$Location.resolved
    if ($extra.Count -gt 0) { $text = $text + ' (' + ($extra.ToArray() -join ', ') + ')' }
    return $text
}

function Format-VacatePlanLocationLine {
    # A location is one unbreakable token: "- " plus the path, hard-split at 100 columns with a
    # 4-space continuation, so the bullet never sits alone on a line.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Text, [int]$Width = 100)
    $lines = New-Object System.Collections.Generic.List[string]
    $prefix = '  - '
    $rest = $Text
    while ($rest.Length -gt 0) {
        $room = $Width - $prefix.Length
        if ($rest.Length -le $room) { $lines.Add($prefix + $rest); break }
        $lines.Add($prefix + $rest.Substring(0, $room))
        $rest = $rest.Substring($room)
        $prefix = '    '
    }
    return $lines.ToArray()
}

function ConvertTo-VacatePlanMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Plan)
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    $add = { param([string]$Text, [string]$Indent = '') foreach ($l in (Format-VacateWrappedText -Text $Text -Indent $Indent)) { [void]$sb.Append($l + $nl) } }

    [void]$sb.Append('# Cleanup plan' + $nl + $nl)
    & $add ('Made by vacate {0} from the {1} scan of {2}. This is a dry run: vacate has not changed anything. You do every step yourself, in order.' -f $Plan.tool.version, $Plan.report.platform, $Plan.report.finishedAt)
    [void]$sb.Append($nl)
    $s = $Plan.summary
    & $add ('{0} steps cover all {1} traces from the report. {2} have guidance, {3} have none yet. {4} would also go away with a full reset.' -f $s.steps, $s.traces, $s.withGuidance, ($s.noGuidance + $s.ruleMissing), $s.resetCovers)
    [void]$sb.Append($nl)

    [void]$sb.Append('## Before you start' + $nl + $nl)
    foreach ($n in @($Plan.beforeYouStart.notes)) { & $add ('- ' + $n) '' }
    if (@($Plan.beforeYouStart.closeApps).Count -gt 0) {
        & $add ('- Close these apps first: ' + (@($Plan.beforeYouStart.closeApps) -join ', ') + '.')
    }
    [void]$sb.Append($nl)

    $lastStage = $null
    foreach ($st in @($Plan.steps)) {
        if ($st.stage -cne $lastStage) {
            $title = @($Plan.summary.byStage | Where-Object { $_.stage -ceq $st.stage })[0].title
            [void]$sb.Append('## ' + $title + $nl + $nl)
            $lastStage = $st.stage
        }
        [void]$sb.Append('### ' + (Get-VacatePlanStepHeading -Step $st) + $nl + $nl)
        if ($null -ne $st.exportFirst) { & $add ('Save first: ' + $st.exportFirst); [void]$sb.Append($nl) }
        if ($null -ne $st.signOut) { & $add ('Sign out: ' + $st.signOut); [void]$sb.Append($nl) }
        $i = 0
        foreach ($line in @($st.instructions)) { $i++; & $add ('{0}. {1}' -f $i, $line) }
        if ($i -gt 0) { [void]$sb.Append($nl) }
        if ($null -ne $st.reason) { & $add $st.reason; [void]$sb.Append($nl) }
        if ($null -ne $st.risk) { & $add ('Risk: ' + $st.risk) }
        if ($st.resetCovers -eq $true) { & $add 'A full reset also removes this.' }
        & $add ('Found at (' + $st.ruleId + '):')
        foreach ($loc in @($st.locations)) { foreach ($l in (Format-VacatePlanLocationLine -Text (Get-VacatePlanLocationText -Location $loc))) { [void]$sb.Append($l + $nl) } }
        if ($null -ne $st.source) { & $add ('Source: ' + $st.source) }
        [void]$sb.Append($nl)
    }

    $r = $Plan.fullReset
    [void]$sb.Append('## Last: ' + $r.title + $nl + $nl)
    & $add $r.when
    [void]$sb.Append($nl)
    $i = 0
    foreach ($line in @($r.steps)) { $i++; & $add ('{0}. {1}' -f $i, $line) }
    [void]$sb.Append($nl)
    & $add ('Source: ' + $r.source)
    [void]$sb.Append($nl + '## Limits' + $nl + $nl)
    foreach ($l in @($Plan.limitations)) { & $add ('- ' + $l) }
    [void]$sb.Append($nl)
    & $add 'For a device you own or are authorised to hand over. Not for destroying evidence or defeating a legal hold.'
    return $sb.ToString()
}

function ConvertTo-VacatePlanHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Plan)
    $h = { param($v) ConvertTo-VacateHtmlText $v }
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    [void]$sb.Append('<!DOCTYPE html>' + $nl + '<html lang="en"><head><meta charset="utf-8">' + $nl)
    [void]$sb.Append('<meta name="viewport" content="width=device-width, initial-scale=1">' + $nl)
    [void]$sb.Append('<meta name="robots" content="noindex">' + $nl)
    [void]$sb.Append('<title>vacate cleanup plan</title>' + $nl)
    [void]$sb.Append('<style>' + $script:VacateReportCss + ' .step ol { margin: 6px 0; padding-left: 22px; } .step p { margin: 6px 0; } .label { font-weight: 600; }</style></head><body><main>' + $nl)

    $red = ''
    if ($Plan.report.redacted) { $red = ' &middot; <strong>redacted</strong>' }
    [void]$sb.Append('<header><h1>Cleanup plan</h1>' + $nl)
    [void]$sb.Append(('<p class="muted">{0} &middot; scan finished {1} &middot; vacate {2}{3}</p>' -f (& $h $Plan.report.platform), (& $h $Plan.report.finishedAt), (& $h $Plan.tool.version), $red) + $nl)
    [void]$sb.Append('<p class="warn"><strong>Dry run.</strong> vacate has not changed anything. You do every step yourself, top to bottom.</p></header>' + $nl)

    $s = $Plan.summary
    [void]$sb.Append('<section><h2>Summary</h2><p>' + (& $h ('{0} steps cover all {1} traces from the report. {2} have guidance, {3} have none yet. {4} would also go away with a full reset.' -f $s.steps, $s.traces, $s.withGuidance, ($s.noGuidance + $s.ruleMissing), $s.resetCovers)) + '</p>' + $nl)
    [void]$sb.Append('<table><thead><tr><th>Stage</th><th class="num">Steps</th></tr></thead><tbody>')
    foreach ($b in @($s.byStage)) { [void]$sb.Append('<tr><td>' + (& $h $b.title) + '</td><td class="num">' + (& $h $b.steps) + '</td></tr>') }
    [void]$sb.Append('</tbody></table></section>' + $nl)

    [void]$sb.Append('<section><h2>Before you start</h2><ul>')
    foreach ($n in @($Plan.beforeYouStart.notes)) { [void]$sb.Append('<li>' + (& $h $n) + '</li>') }
    if (@($Plan.beforeYouStart.closeApps).Count -gt 0) { [void]$sb.Append('<li>Close these apps first: ' + (& $h (@($Plan.beforeYouStart.closeApps) -join ', ')) + '.</li>') }
    [void]$sb.Append('</ul></section>' + $nl)

    $lastStage = $null
    foreach ($st in @($Plan.steps)) {
        if ($st.stage -cne $lastStage) {
            if ($null -ne $lastStage) { [void]$sb.Append('</section>' + $nl) }
            $title = @($Plan.summary.byStage | Where-Object { $_.stage -ceq $st.stage })[0].title
            [void]$sb.Append('<section><h2>' + (& $h $title) + '</h2>' + $nl)
            $lastStage = $st.stage
        }
        [void]$sb.Append('<div class="trace step"><strong>' + (& $h $st.step) + '. ' + (& $h $st.title) + '</strong> <span class="sev-' + (& $h $st.sensitivity) + '">' + (& $h $st.sensitivity) + '</span>')
        if ($null -ne $st.exportFirst) { [void]$sb.Append('<p><span class="label">Save first:</span> ' + (& $h $st.exportFirst) + '</p>') }
        if ($null -ne $st.signOut) { [void]$sb.Append('<p><span class="label">Sign out:</span> ' + (& $h $st.signOut) + '</p>') }
        if (@($st.instructions).Count -gt 0) {
            [void]$sb.Append('<ol>')
            foreach ($line in @($st.instructions)) { [void]$sb.Append('<li>' + (& $h $line) + '</li>') }
            [void]$sb.Append('</ol>')
        }
        if ($null -ne $st.reason) { [void]$sb.Append('<p>' + (& $h $st.reason) + '</p>') }
        [void]$sb.Append('<dl>')
        if ($null -ne $st.risk) { [void]$sb.Append('<dt>Risk</dt><dd>' + (& $h $st.risk) + '</dd>') }
        if ($st.resetCovers -eq $true) { [void]$sb.Append('<dt>Full reset</dt><dd>also removes this</dd>') }
        [void]$sb.Append('<dt>Found at</dt><dd>')
        foreach ($loc in @($st.locations)) { [void]$sb.Append('<code>' + (& $h (Get-VacatePlanLocationText -Location $loc)) + '</code><br>') }
        [void]$sb.Append('</dd><dt>Rule</dt><dd><code>' + (& $h $st.ruleId) + '</code></dd>')
        if ($null -ne $st.source) { [void]$sb.Append('<dt>Source</dt><dd>' + (& $h $st.source) + '</dd>') }
        [void]$sb.Append('</dl></div>' + $nl)
    }
    if ($null -ne $lastStage) { [void]$sb.Append('</section>' + $nl) }

    $r = $Plan.fullReset
    [void]$sb.Append('<section><h2>Last: ' + (& $h $r.title) + '</h2><p class="warn">' + (& $h $r.when) + '</p><ol>')
    foreach ($line in @($r.steps)) { [void]$sb.Append('<li>' + (& $h $line) + '</li>') }
    [void]$sb.Append('</ol><p class="muted">Source: ' + (& $h $r.source) + '</p></section>' + $nl)

    [void]$sb.Append('<section><h2>Limits</h2><ul>')
    foreach ($l in @($Plan.limitations)) { [void]$sb.Append('<li>' + (& $h $l) + '</li>') }
    [void]$sb.Append('</ul></section>' + $nl)
    [void]$sb.Append('<footer>For a device you own or are authorised to hand over. Not for destroying evidence or defeating a legal hold.</footer>' + $nl)
    [void]$sb.Append('</main></body></html>' + $nl)
    return $sb.ToString()
}
