# EraseLauncher.ps1 - Phase 4: starts the operating system's own erase (DECISIONS D54-D57).
# PowerShell 5.1 compatible. ASCII only.
# The only code allowed to start these three fixed programs, with fixed arguments and no shell:
#   Windows  C:\Windows\System32\systemreset.exe -factoryreset   (opens Microsoft's Reset this PC;
#            the person still confirms every screen in Windows). Windows 11 24H2 and later ship no
#            systemreset.exe, so then C:\Windows\explorer.exe ms-settings:recovery opens Settings >
#            System > Recovery, where the person chooses Reset PC.
#   macOS    /usr/bin/open <Transfer or Reset settings URL>      (Apple allows no scripted erase;
#            the person clicks Erase All Content and Settings)
#   Linux    /usr/sbin/cryptsetup luksErase --batch-mode <LUKS device backing />
# Callers must have passed every readiness and confirmation check first (Invoke-VacateErase).

$script:VacateEraseMethodByPlatform = @{
    'windows' = 'windows-reset-this-pc'
    'macos'   = 'macos-erase-all-content-and-settings'
    'linux'   = 'linux-luks-key-erase'
}

function Get-VacateEraseCommand {
    # The exact program and arguments for a platform. Throws when the target is not acceptable.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Platform, [Parameter(Mandatory)][object]$SystemDisk)
    switch ($Platform) {
        'windows' {
            if ([IO.File]::Exists('C:\Windows\System32\systemreset.exe')) {
                return [pscustomobject]@{ Binary = 'C:\Windows\System32\systemreset.exe'; Arguments = [string[]]@('-factoryreset'); Wait = $false }
            }
            return [pscustomobject]@{ Binary = 'C:\Windows\explorer.exe'; Arguments = [string[]]@('ms-settings:recovery'); Wait = $false }
        }
        'macos' {
            return [pscustomobject]@{ Binary = '/usr/bin/open'; Arguments = [string[]]@('x-apple.systempreferences:com.apple.Transfer-Reset-Settings.extension'); Wait = $false }
        }
        'linux' {
            $container = $null
            if ($null -ne $SystemDisk.encryption) { $container = [string]$SystemDisk.encryption.container }
            if ([string]::IsNullOrEmpty($container) -or $container -cnotmatch '^/dev/[A-Za-z0-9][A-Za-z0-9/_.-]*$' -or $container.Contains('..')) {
                throw "erase: no valid LUKS device to erase ('$container')."
            }
            if ([string]$SystemDisk.encryption.kind -cne 'luks') { throw 'erase: the system disk is not LUKS-encrypted.' }
            return [pscustomobject]@{ Binary = '/usr/sbin/cryptsetup'; Arguments = [string[]]@('luksErase', '--batch-mode', $container); Wait = $true }
        }
        default { throw "erase: unknown platform '$Platform'." }
    }
}

function Invoke-VacateEraseProcess {
    # Default launcher: in-process Process, no shell. GUI tools are started and left running;
    # cryptsetup is waited for (60 s) and its exit code returned.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Command)
    $startInfo = New-Object -TypeName 'System.Diagnostics.ProcessStartInfo'
    $startInfo.FileName = $Command.Binary
    $startInfo.UseShellExecute = $false
    $quoted = @()
    foreach ($a in $Command.Arguments) { $quoted += ('"' + $a.Replace('"', '\"') + '"') }
    $startInfo.Arguments = ($quoted -join ' ')
    $startInfo.CreateNoWindow = $false
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $Command.Wait) { return [pscustomobject]@{ started = $true; exitCode = $null } }
    if (-not $process.WaitForExit(60000)) { return [pscustomobject]@{ started = $true; exitCode = $null } }
    return [pscustomobject]@{ started = $true; exitCode = $process.ExitCode }
}

function Start-VacateOsErase {
    <#
    .SYNOPSIS
        Starts the operating system's erase for this platform. -Launcher replaces the real start in tests.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][object]$SystemDisk,
        [scriptblock]$Launcher
    )
    $cmd = Get-VacateEraseCommand -Platform $Platform -SystemDisk $SystemDisk
    $method = $script:VacateEraseMethodByPlatform[$Platform]
    if (-not $PSCmdlet.ShouldProcess($cmd.Binary, 'Start operating system erase')) {
        return [pscustomobject][ordered]@{ started = $false; method = $method; detail = 'skipped (WhatIf)' }
    }
    $run = $null
    if ($null -ne $Launcher) { $run = & $Launcher $cmd } else { $run = Invoke-VacateEraseProcess -Command $cmd }
    $detail = ('opened the operating system erase ({0}). The erase only happens if you complete it there: choose Remove everything and Clean data (Windows) or Erase All Content and Settings (macOS).' -f $cmd.Binary)
    $started = [bool]$run.started
    $exitCode = $null
    if ($null -ne $run -and $null -ne $run.PSObject.Properties['exitCode']) { $exitCode = $run.exitCode }
    if ($cmd.Wait) {
        if ($null -eq $exitCode) { $started = $false; $detail = 'cryptsetup did not finish within 60 seconds' }
        elseif ([int]$exitCode -ne 0) { $started = $false; $detail = ('cryptsetup exited with code {0}' -f $exitCode) }
        else { $detail = 'all LUKS key slots erased; the data can no longer be decrypted' }
    }
    return [pscustomobject][ordered]@{ started = $started; method = $method; detail = $detail }
}
