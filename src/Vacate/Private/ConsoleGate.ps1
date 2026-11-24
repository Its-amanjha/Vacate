# ConsoleGate.ps1 - Phase 4/5: the last human checks before an erase (D55).
# PowerShell 5.1 compatible. ASCII only. Set-StrictMode -Version Latest (from the module loader).
#
# Two decisions live here so they can be tested without a real console: whether a person is at
# an interactive console, and whether the answer they typed is the final YES. Both are pure
# (they read no files, start nothing and write nothing); vacate.ps1 calls them and keeps the
# messages, the exit codes and the order (readiness -> console -> typed YES -> erase).

function Test-VacateInteractiveConsole {
    <#
    .SYNOPSIS
        Decides whether a person is at a real console. Returns ok and a reason.
    .DESCRIPTION
        A piped or scripted YES must never reach the erase gate (Phase 4 threat model). The three
        facts are parameters that default to the real console, so tests can drive every
        combination; nothing else in the module reads them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # [Console]::IsInputRedirected
        [AllowNull()][Nullable[bool]]$InputRedirected,
        # [Console]::IsOutputRedirected
        [AllowNull()][Nullable[bool]]$OutputRedirected,
        # [Environment]::UserInteractive
        [AllowNull()][Nullable[bool]]$UserInteractive
    )

    if ($null -eq $InputRedirected) { $InputRedirected = [Console]::IsInputRedirected }
    if ($null -eq $OutputRedirected) { $OutputRedirected = [Console]::IsOutputRedirected }
    if ($null -eq $UserInteractive) { $UserInteractive = [Environment]::UserInteractive }

    $ok = ((-not [bool]$InputRedirected) -and (-not [bool]$OutputRedirected) -and [bool]$UserInteractive)
    $reason = 'interactive console'
    if (-not $ok) {
        if ([bool]$InputRedirected) { $reason = 'input is redirected' }
        elseif ([bool]$OutputRedirected) { $reason = 'output is redirected' }
        else { $reason = 'the session is not interactive' }
    }

    return [pscustomobject][ordered]@{
        ok     = [bool]$ok
        reason = $reason
    }
}

function Read-VacateTypedConfirm {
    <#
    .SYNOPSIS
        Asks for the final confirmation and returns $true only for exactly YES.
    .DESCRIPTION
        The answer must be exactly YES, the same test Invoke-VacateErase applies to
        -TypedConfirmation (-cne 'YES'): no trimming and no case folding, so 'yes', ' YES', 'Y'
        and an empty or missing answer all mean no. -Reader replaces Read-Host in tests.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Prompt = 'Type YES to continue',
        # Tests only: a scriptblock that receives the prompt and returns the typed answer.
        [AllowNull()][scriptblock]$Reader
    )

    $answer = $null
    if ($null -ne $Reader) { $answer = & $Reader $Prompt }
    else { $answer = Read-Host $Prompt }

    return ([string]$answer -ceq 'YES')
}
