# Checklist.ps1 - builds the ordered de-link checklist from a report. Owner: Claude.
# PowerShell 5.1 compatible. ASCII only.
# Order follows docs/SPEC.md "Checklist generation": export and sign out BEFORE uninstalling,
# because uninstalling can remove the session you need to sign out of.
# Vendor guidance is named by article title only; no URLs are embedded (they go stale and
# cannot be verified offline - DECISIONS D17).

function New-VacateChecklistStep {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory object; changes no state.')]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Detail,
        [string[]]$Categories = @(),
        [bool]$Always = $false,
        [bool]$OutOfScope = $false
    )
    return [pscustomobject][ordered]@{ Id = $Id; Title = $Title; Detail = $Detail; Categories = $Categories; Always = $Always; OutOfScope = $OutOfScope }
}

function Get-VacateChecklistTemplate {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Platform)
    switch ($Platform) {
        'windows' {
            return @(
                (New-VacateChecklistStep 'backup' 'Back up your files and wallet recovery phrases' 'Copy personal files somewhere safe. For any crypto wallet, make sure you have its recovery phrase written down before you touch it.' @('personal-files', 'wallets') $true)
                (New-VacateChecklistStep 'browsers' 'Export browser data and sign out of browser sync' 'Export bookmarks and passwords you want to keep, then sign out of sync in every browser so the next user cannot pull your synced data.' @('browsers'))
                (New-VacateChecklistStep 'microsoft-account' 'Sign out of your Microsoft account' 'Remove your Microsoft account from Settings > Accounts, and remove this device from your account online.' @('ai-assistants') $true)
                (New-VacateChecklistStep 'bitlocker' 'Record your BitLocker recovery key status' 'Check whether the drive is encrypted and where its recovery key is stored, before you reset.' @('disk-encryption') $true)
                (New-VacateChecklistStep 'licenses' 'Transfer or deactivate software licences' 'Deactivate paid software and game stores so the licence is not lost or left on this machine.' @('games-licenses', 'installed-programs'))
                (New-VacateChecklistStep 'cloud' 'Sign out of cloud, mail and developer accounts' 'Sign out of OneDrive and other sync clients, mail apps, and revoke or remove cloud and developer credentials (AWS, Azure, kube, Docker, npm, git).' @('cloud-sync', 'email', 'developer-secrets'))
                (New-VacateChecklistStep 'uninstall' 'Sign out of, then uninstall, apps that hold a session' 'Log out inside each chat app first, then uninstall it. Uninstalling alone can leave the session files behind.' @('messaging', 'installed-programs', 'autostart', 'containers-vms'))
                (New-VacateChecklistStep 'network' 'Remove Wi-Fi, VPN, mapped drives, printers and Bluetooth devices' 'Forget saved Wi-Fi networks, remove VPN profiles, disconnect mapped drives and remote desktop entries, and unpair devices.' @('network'))
                (New-VacateChecklistStep 'clear' 'Clear browser data, stored credentials and activity traces' 'Clear browsing data, remove saved credentials, and clear recent-items, AI assistant history and temporary files. Remove other user accounts you created.' @('browsers', 'credentials', 'activity', 'ai-assistants', 'system-traces', 'user-profiles'))
                (New-VacateChecklistStep 'erase' 'Reset or erase the PC (not done by this tool)' 'Use Windows "Reset this PC" with the option to remove everything and clean the drive. See the Microsoft support article "Recovery options in Windows". This tool does not erase anything.' @() $true $true)
            )
        }
        'macos' {
            return @(
                (New-VacateChecklistStep 'backup' 'Back up your files and wallet recovery phrases' 'Copy personal files somewhere safe. For any crypto wallet, make sure you have its recovery phrase written down before you touch it.' @('personal-files', 'wallets') $true)
                (New-VacateChecklistStep 'browsers' 'Export browser data and sign out of browser sync' 'Export bookmarks and passwords you want to keep, then sign out of sync in Safari/iCloud, Chrome, Firefox and others.' @('browsers'))
                (New-VacateChecklistStep 'find-my' 'Turn off Find My Mac and Activation Lock' 'In System Settings > Apple ID > iCloud, turn off Find My Mac. Otherwise the next owner cannot activate the Mac.' @() $true)
                (New-VacateChecklistStep 'filevault' 'Record your FileVault recovery key status' 'Check whether FileVault is on and where its recovery key is held, before you erase.' @('disk-encryption') $true)
                (New-VacateChecklistStep 'apple-id' 'Sign out of your Apple ID and iCloud' 'Sign out of iCloud, Messages, FaceTime and Mail accounts tied to your Apple ID.' @('email') $true)
                (New-VacateChecklistStep 'licenses' 'Transfer or deactivate software licences' 'Deauthorise purchases and deactivate paid software and game stores.' @('games-licenses', 'installed-programs'))
                (New-VacateChecklistStep 'cloud' 'Sign out of cloud and developer accounts' 'Sign out of Dropbox, Google Drive, OneDrive and similar clients, and revoke or remove cloud and developer credentials.' @('cloud-sync', 'developer-secrets'))
                (New-VacateChecklistStep 'uninstall' 'Sign out of, then uninstall, apps that hold a session' 'Log out inside each chat app first, then remove it. Remove launch agents you added.' @('messaging', 'installed-programs', 'autostart', 'containers-vms'))
                (New-VacateChecklistStep 'network' 'Remove Wi-Fi, VPN, printers and Bluetooth devices' 'Forget saved networks, remove VPN profiles and printers, and unpair devices.' @('network'))
                (New-VacateChecklistStep 'clear' 'Clear browser data, Keychain items and SSH keys' 'Clear browsing data, remove your Keychain items and SSH keys, empty the Trash, and remove other user accounts you created.' @('browsers', 'credentials', 'developer-secrets', 'activity', 'system-traces', 'user-profiles', 'ai-assistants'))
                (New-VacateChecklistStep 'erase' 'Erase All Content and Settings (not done by this tool)' 'Use "Erase All Content and Settings" in System Settings > General > Transfer or Reset. See the Apple support article "Erase your Mac". This tool does not erase anything.' @() $true $true)
            )
        }
        'linux' {
            return @(
                (New-VacateChecklistStep 'backup' 'Back up your files and wallet recovery phrases' 'Copy personal files somewhere safe. For any crypto wallet, make sure you have its recovery phrase written down before you touch it.' @('personal-files', 'wallets') $true)
                (New-VacateChecklistStep 'browsers' 'Export browser data and sign out of browser sync' 'Export bookmarks and passwords you want to keep, then sign out of sync in every browser.' @('browsers'))
                (New-VacateChecklistStep 'licenses' 'Transfer licences (Steam and others)' 'Sign out of Steam and other stores, and deactivate paid software.' @('games-licenses'))
                (New-VacateChecklistStep 'cloud' 'Sign out of cloud, mail and chat clients' 'Sign out of sync clients, mail and chat apps, and revoke cloud and developer tokens (AWS, Azure, kube, Docker, npm, git).' @('cloud-sync', 'email', 'messaging', 'developer-secrets'))
                (New-VacateChecklistStep 'keys' 'Remove SSH and GPG keys and keyrings' 'Remove or revoke SSH keys (also from the servers that trust them), GPG keys and desktop keyrings.' @('credentials', 'developer-secrets'))
                (New-VacateChecklistStep 'history' 'Clear shell history, recent files and logs you own' 'Clear shell histories and the recently-used list, empty the Trash, and clear caches.' @('activity', 'system-traces', 'ai-assistants'))
                (New-VacateChecklistStep 'autostart' 'Disable autostart entries and user services' 'Remove autostart entries and disable systemd user units you created.' @('autostart'))
                (New-VacateChecklistStep 'uninstall' 'Uninstall apps, containers and virtual machines' 'Uninstall apps that hold sessions, and remove container images and VMs you do not want to hand over.' @('installed-programs', 'messaging', 'containers-vms'))
                (New-VacateChecklistStep 'network' 'Remove Wi-Fi, VPN, printers and Bluetooth devices' 'Forget saved networks, remove VPN connections and printers, and unpair devices.' @('network', 'user-profiles'))
                (New-VacateChecklistStep 'erase' 'Reinstall, or destroy the LUKS header (not done by this tool)' "Reinstall the system over the whole disk, or, if the disk uses LUKS, destroy its header with your distribution's documented procedure. This tool does not erase anything." @('disk-encryption') $true $true)
            )
        }
        default { throw "checklist: unknown platform '$Platform'." }
    }
}

function Get-VacateChecklist {
    # Returns ordered steps that apply to this report. A step is included when it is marked
    # Always or when at least one trace falls in its categories. Each step names its traces.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][object]$Report)

    $platform = [string]$Report.scan.platform
    $template = Get-VacateChecklistTemplate -Platform $platform
    $traces = @($Report.traces)
    $steps = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($t in $template) {
        $groups = @{}
        foreach ($tr in $traces) {
            if ($t.Categories -ccontains [string]$tr.category) {
                $id = [string]$tr.ruleId
                if (-not $groups.ContainsKey($id)) { $groups[$id] = [ordered]@{ ruleId = $id; title = [string]$tr.title; count = 0 } }
                $groups[$id].count++
            }
        }
        if (-not $t.Always -and $groups.Count -eq 0) { continue }
        $ids = [string[]]@($groups.Keys)
        [Array]::Sort($ids, [StringComparer]::Ordinal)
        $refs = New-Object System.Collections.Generic.List[object]
        foreach ($id in $ids) { $refs.Add([pscustomobject]$groups[$id]) }
        $n++
        $steps.Add([pscustomobject][ordered]@{
                step       = $n
                id         = $t.Id
                title      = $t.Title
                detail     = $t.Detail
                outOfScope = $t.OutOfScope
                traces     = $refs.ToArray()
            })
    }
    return $steps.ToArray()
}

function ConvertTo-VacateChecklistMarkdown {
    # Plain Markdown, no line wider than 100 characters.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Checklist
    )
    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    [void]$sb.Append('# Handover checklist' + $nl + $nl)
    foreach ($line in (Format-VacateWrappedText -Text ('Generated by vacate {0} for {1} on {2}. Do the steps in order: sign out and export before you uninstall anything.' -f $Report.tool.version, $Report.scan.platform, $Report.scan.finishedAt))) { [void]$sb.Append($line + $nl) }
    [void]$sb.Append($nl)
    foreach ($s in $Checklist) {
        $head = ('{0}. {1}' -f $s.step, $s.title)
        foreach ($line in (Format-VacateWrappedText -Text $head)) { [void]$sb.Append($line + $nl) }
        foreach ($line in (Format-VacateWrappedText -Text $s.detail -Indent '   ')) { [void]$sb.Append($line + $nl) }
        if (@($s.traces).Count -gt 0) {
            [void]$sb.Append('   Found:' + $nl)
            foreach ($r in $s.traces) {
                $txt = ('- {0} ({1}, {2} found)' -f $r.title, $r.ruleId, $r.count)
                foreach ($line in (Format-VacateWrappedText -Text $txt -Indent '   ')) { [void]$sb.Append($line + $nl) }
            }
        }
        [void]$sb.Append($nl)
    }
    foreach ($line in (Format-VacateWrappedText -Text 'This checklist is for a device you own or are authorised to hand over. It is not for destroying evidence or defeating a legal hold.')) { [void]$sb.Append($line + $nl) }
    return $sb.ToString()
}
