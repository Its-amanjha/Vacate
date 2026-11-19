# ReportText.ps1 - fixed wording used by the report: category meanings and honest limits.
# PowerShell 5.1 compatible. ASCII only.
# Limitations follow docs/SPEC.md "Platform limitations to write down". Do not soften them.

$script:VacateCategoryMeaning = [ordered]@{
    'browsers'           = 'Browsing history, cookies and saved logins. Cookies can keep you signed in to websites on this machine.'
    'credentials'        = 'Stored passwords and the keys that unlock them.'
    'developer-secrets'  = 'Keys and tokens for servers and cloud accounts (SSH, AWS, Azure, Kubernetes, Docker, npm, git).'
    'network'            = 'Saved Wi-Fi networks, mapped drives and remote desktop targets.'
    'activity'           = 'Records of files, programs and searches you opened recently.'
    'personal-files'     = 'Your own documents, photos, videos and downloads.'
    'cloud-sync'         = 'Folders synced with cloud accounts. Signed-in clients can keep syncing to whoever uses the machine next.'
    'messaging'          = 'Chat apps. Their data folders often hold a live session, so the next user could read your chats.'
    'email'              = 'Mail data and accounts.'
    'wallets'            = 'Cryptocurrency wallet files. Anyone with these files may be able to move your funds.'
    'installed-programs' = 'Programs installed on the machine. Some hold licences or signed-in sessions.'
    'user-profiles'      = 'Other accounts on this machine (names only; their contents are not read).'
    'disk-encryption'    = 'Whether the disk is encrypted, which decides how recoverable deleted data is.'
    'system-traces'      = 'Logs, temporary files, crash dumps and caches that can hold fragments of your activity.'
    'autostart'          = 'Programs and services that start automatically for your account.'
    'containers-vms'     = 'Container images and virtual machines, which can hold whole copies of other systems.'
    'games-licenses'     = 'Game stores and licences that may need to be signed out or transferred.'
    'ai-assistants'      = 'AI assistant history and snapshots (for example Windows Recall or Copilot).'
}

$script:VacateLimitations = @(
    [ordered]@{ scope = 'all'; text = 'SSD spare area and wear-levelled blocks: old copies of data can survive outside any folder this tool can see.' }
    [ordered]@{ scope = 'all'; text = 'Cloud and backup copies: files already synced or backed up elsewhere are not on this disk and are not checked.' }
    [ordered]@{ scope = 'all'; text = 'Firmware, TPM, BIOS/UEFI and EFI partitions are not inspected.' }
    [ordered]@{ scope = 'all'; text = 'Data that was deleted but not overwritten can still be recovered with forensic tools. This tool only sees files that exist now.' }
    [ordered]@{ scope = 'all'; text = 'Other operating systems installed on this machine, and other disks, are not scanned.' }
    [ordered]@{ scope = 'all'; text = 'Encrypted containers (VeraCrypt volumes, encrypted archives) are seen at most as files; their contents are not.' }
    [ordered]@{ scope = 'all'; text = 'Swap, page and hibernation files can hold fragments of anything that was in memory. They are not read.' }
    [ordered]@{ scope = 'all'; text = 'Memory (RAM) is not inspected.' }
    [ordered]@{ scope = 'all'; text = 'Only known locations are checked. An app this tool has no rule for is invisible to it. A clean report is not proof the machine is clean.' }
    [ordered]@{ scope = 'all'; text = 'File contents are never opened, so this tool cannot tell whether a file is empty, still signed in, or holds anything personal.' }
    [ordered]@{ scope = 'windows'; text = 'BitLocker recovery keys stored in your Microsoft account, Entra ID or Active Directory are not visible from this machine.' }
    [ordered]@{ scope = 'windows'; text = 'TPM ownership and its stored keys are not inspected.' }
    [ordered]@{ scope = 'windows'; text = 'Drives other than the system drive are not scanned.' }
    [ordered]@{ scope = 'windows'; text = "Other user profiles are listed by name only; their contents are not checked." }
    [ordered]@{ scope = 'windows'; text = 'Without administrator rights, admin-only locations (for example Wi-Fi profiles, Prefetch, BitLocker status) are skipped and listed as skipped.' }
    [ordered]@{ scope = 'macos'; text = 'Folders protected by macOS privacy controls (TCC) are skipped unless the terminal has Full Disk Access.' }
    [ordered]@{ scope = 'macos'; text = 'FileVault recovery keys held by Apple or iCloud are not visible from this machine.' }
    [ordered]@{ scope = 'macos'; text = 'APFS local snapshots can keep old copies of files and are not inspected.' }
    [ordered]@{ scope = 'macos'; text = 'The Secure Enclave and its keys are not inspected.' }
    [ordered]@{ scope = 'macos'; text = 'Keychain items are seen only as keychain files; individual items, especially ones that need unlocking, are not.' }
    [ordered]@{ scope = 'linux'; text = 'Root-only files are skipped when the tool runs without root, which is the default.' }
    [ordered]@{ scope = 'linux'; text = 'LUKS keyslots and headers are not inspected.' }
    [ordered]@{ scope = 'linux'; text = 'Swap partitions and swap files are not read.' }
    [ordered]@{ scope = 'linux'; text = 'System journal contents are not read; at most their size is reported.' }
    [ordered]@{ scope = 'linux'; text = 'Container images and layers are seen as folders and sizes only.' }
    [ordered]@{ scope = 'linux'; text = 'Distribution-specific package state (which packages hold your data) is not analysed.' }
    [ordered]@{ scope = 'linux'; text = 'Other mounted file systems are not scanned.' }
)

function Get-VacateLimitation {
    # Limitations for a platform: everything with scope 'all' first, then the platform's own.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Platform)
    if ($script:VacatePlatforms -cnotcontains $Platform) { throw "report: unknown platform '$Platform'." }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($l in $script:VacateLimitations) { if ($l.scope -ceq 'all') { $out.Add([pscustomobject]$l) } }
    foreach ($l in $script:VacateLimitations) { if ($l.scope -ceq $Platform) { $out.Add([pscustomobject]$l) } }
    return $out.ToArray()
}

function Get-VacateCategoryMeaning {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Category)
    if ($script:VacateCategoryMeaning.Contains($Category)) { return [string]$script:VacateCategoryMeaning[$Category] }
    return ''
}

function Format-VacateByteSize {
    # 1024-based, invariant culture: 0 B, 512 B, 1.5 KB, 12.3 MB, 4.0 GB.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Bytes)
    if ($null -eq $Bytes) { return '-' }
    $b = [double]$Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($b -ge 1024 -and $i -lt ($units.Count - 1)) { $b = $b / 1024; $i++ }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($i -eq 0) { return ([string]::Format($inv, '{0} B', [long]$Bytes)) }
    return ([string]::Format($inv, '{0:0.0} {1}', $b, $units[$i]))
}

function Format-VacateWrappedText {
    # Wraps plain text to lines no wider than -Width (default 100). Long words are hard-split.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][string]$Text, [int]$Width = 100, [string]$Indent = '')
    $lines = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { $lines.Add(''); return $lines.ToArray() }
    $current = ''
    foreach ($word in ($Text -split '\s+')) {
        if ($word -eq '') { continue }
        while (($Indent.Length + $word.Length) -gt $Width) {
            if ($current -ne '') { $lines.Add($current); $current = '' }
            $cut = $Width - $Indent.Length
            $lines.Add($Indent + $word.Substring(0, $cut))
            $word = $word.Substring($cut)
        }
        if ($current -eq '') { $candidate = $Indent + $word } else { $candidate = $current + ' ' + $word }
        if ($candidate.Length -gt $Width) { $lines.Add($current); $current = $Indent + $word }
        else { $current = $candidate }
    }
    if ($current -ne '') { $lines.Add($current) }
    return $lines.ToArray()
}
