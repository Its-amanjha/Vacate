# Rule catalog

Generated from `src/Vacate/rules/` by `tools/Update-RulesDoc.ps1`. Do not edit by hand.

`verified` means the location was confirmed on a real machine of that platform. Unverified rules still run; the report lists them.

## Windows (87 rules, 0 verified)

| id | category | sensitivity | locator | elevation | verified |
|---|---|---|---|---|---|
| `activity.featureusage` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage` | no | no |
| `activity.jumplists.automatic` | activity | medium | `APPDATA/Microsoft/Windows/Recent/AutomaticDestinations/*.automaticDestinations-ms` | no | no |
| `activity.muicache` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MuiCache` | no | no |
| `activity.recent-items` | activity | medium | `APPDATA/Microsoft/Windows/Recent/*.lnk` | no | no |
| `activity.runmru` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU` | no | no |
| `activity.shellbags` | activity | medium | `HKCU\Software\Microsoft\Windows\Shell\BagMRU` | no | no |
| `activity.typedpaths` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths` | no | no |
| `activity.userassist` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist` | no | no |
| `activity.wordwheelquery` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery` | no | no |
| `ai.copilot.history` | ai-assistants | high | `LOCALAPPDATA/Packages/Microsoft.Copilot_*` | no | no |
| `ai.recall.data` | ai-assistants | high | `LOCALAPPDATA/CoreAIPlatform.00/UKP` | no | no |
| `autostart.run-key-machine` | autostart | low | `HKLM\Software\Microsoft\Windows\CurrentVersion\Run` | no | no |
| `autostart.run-key-user` | autostart | low | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | no | no |
| `autostart.startup-folder` | autostart | low | `APPDATA/Microsoft/Windows/Start Menu/Programs/Startup` | no | no |
| `browser.brave.profiles` | browsers | medium | `LOCALAPPDATA/BraveSoftware/Brave-Browser/User Data/*/Preferences` | no | no |
| `browser.chrome.cookies` | browsers | high | `LOCALAPPDATA/Google/Chrome/User Data/*/Network/Cookies` | no | no |
| `browser.chrome.history` | browsers | high | `LOCALAPPDATA/Google/Chrome/User Data/*/History` | no | no |
| `browser.chrome.login-data` | browsers | critical | `LOCALAPPDATA/Google/Chrome/User Data/*/Login Data` | no | no |
| `browser.chrome.profiles` | browsers | medium | `LOCALAPPDATA/Google/Chrome/User Data/*/Preferences` | no | no |
| `browser.chrome.web-data` | browsers | high | `LOCALAPPDATA/Google/Chrome/User Data/*/Web Data` | no | no |
| `browser.edge.cookies` | browsers | high | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Network/Cookies` | no | no |
| `browser.edge.history` | browsers | high | `LOCALAPPDATA/Microsoft/Edge/User Data/*/History` | no | no |
| `browser.edge.login-data` | browsers | critical | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Login Data` | no | no |
| `browser.edge.profiles` | browsers | medium | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Preferences` | no | no |
| `browser.firefox.cookies` | browsers | high | `APPDATA/Mozilla/Firefox/Profiles/*/cookies.sqlite` | no | no |
| `browser.firefox.key4` | browsers | critical | `APPDATA/Mozilla/Firefox/Profiles/*/key4.db` | no | no |
| `browser.firefox.logins` | browsers | critical | `APPDATA/Mozilla/Firefox/Profiles/*/logins.json` | no | no |
| `browser.firefox.places` | browsers | high | `APPDATA/Mozilla/Firefox/Profiles/*/places.sqlite` | no | no |
| `browser.firefox.profiles` | browsers | medium | `APPDATA/Mozilla/Firefox/Profiles/*` | no | no |
| `browser.opera.profiles` | browsers | medium | `APPDATA/Opera Software/Opera Stable/Default/Preferences` | no | no |
| `browser.vivaldi.profiles` | browsers | medium | `LOCALAPPDATA/Vivaldi/User Data/*/Preferences` | no | no |
| `cloud.onedrive` | cloud-sync | medium | `HOME/OneDrive*` | no | no |
| `containers.docker-desktop` | containers-vms | medium | `LOCALAPPDATA/Docker` | no | no |
| `containers.virtualbox` | containers-vms | medium | `HOME/VirtualBox VMs` | no | no |
| `containers.wsl-distros` | containers-vms | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` | no | no |
| `credentials.keepass.config` | credentials | medium | `APPDATA/KeePass/KeePass.config.xml` | no | no |
| `credentials.windows.credentials-local` | credentials | critical | `LOCALAPPDATA/Microsoft/Credentials` | no | no |
| `credentials.windows.credentials-roaming` | credentials | critical | `APPDATA/Microsoft/Credentials` | no | no |
| `credentials.windows.dpapi-masterkeys` | credentials | critical | `APPDATA/Microsoft/Protect` | no | no |
| `credentials.windows.vault` | credentials | critical | `LOCALAPPDATA/Microsoft/Vault` | no | no |
| `dev.aws.config` | developer-secrets | critical | `HOME/.aws` | no | no |
| `dev.azure.config` | developer-secrets | critical | `HOME/.azure` | no | no |
| `dev.docker.config` | developer-secrets | critical | `HOME/.docker/config.json` | no | no |
| `dev.git-credentials` | developer-secrets | critical | `HOME/.git-credentials` | no | no |
| `dev.kube.config` | developer-secrets | critical | `HOME/.kube` | no | no |
| `dev.npmrc` | developer-secrets | critical | `HOME/.npmrc` | no | no |
| `dev.ssh.keys` | developer-secrets | critical | `HOME/.ssh` | no | no |
| `email.outlook.data` | email | high | `LOCALAPPDATA/Microsoft/Outlook` | no | no |
| `email.outlook.new` | email | high | `LOCALAPPDATA/Packages/Microsoft.OutlookForWindows_8wekyb3d8bbwe` | no | no |
| `email.thunderbird.profiles` | email | high | `APPDATA/Thunderbird/Profiles/*` | no | no |
| `encryption.bitlocker.status` | disk-encryption | low | `root/CIMV2/Security/MicrosoftVolumeEncryption:Win32_EncryptableVolume` | yes | no |
| `encryption.tpm.presence` | disk-encryption | low | `root/CIMV2/Security/MicrosoftTpm:Win32_Tpm` | yes | no |
| `files.desktop` | personal-files | medium | `HOME/Desktop` | no | no |
| `files.documents` | personal-files | medium | `HOME/Documents` | no | no |
| `files.downloads` | personal-files | medium | `HOME/Downloads` | no | no |
| `files.pictures` | personal-files | medium | `HOME/Pictures` | no | no |
| `files.videos` | personal-files | medium | `HOME/Videos` | no | no |
| `games.battlenet` | games-licenses | medium | `PROGRAMDATA/Battle.net` | no | no |
| `games.epic` | games-licenses | medium | `LOCALAPPDATA/EpicGamesLauncher/Saved` | no | no |
| `games.steam` | games-licenses | medium | `LOCALAPPDATA/Steam` | no | no |
| `msg.discord` | messaging | high | `APPDATA/discord` | no | no |
| `msg.signal` | messaging | high | `APPDATA/Signal` | no | no |
| `msg.slack` | messaging | high | `APPDATA/Slack` | no | no |
| `msg.teams` | messaging | high | `LOCALAPPDATA/Packages/MSTeams_8wekyb3d8bbwe/LocalCache/Microsoft/MSTeams` | no | no |
| `msg.telegram` | messaging | high | `APPDATA/Telegram Desktop/tdata` | no | no |
| `msg.whatsapp` | messaging | high | `LOCALAPPDATA/Packages/5319275A.WhatsAppDesktop_*/LocalState` | no | no |
| `network.bluetooth.devices` | network | medium | `HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices` | no | no |
| `network.mapped-drives` | network | high | `HKCU\Network` | no | no |
| `network.networklist.profiles` | network | medium | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles` | no | no |
| `network.openvpn.configs` | network | high | `HOME/OpenVPN/config` | no | no |
| `network.printers.user` | network | low | `HKCU\Printers\Connections` | no | no |
| `network.rdp.mru` | network | high | `HKCU\Software\Microsoft\Terminal Server Client\Default` | no | no |
| `network.wifi.profiles` | network | critical | `PROGRAMDATA/Microsoft/Wlansvc/Profiles/Interfaces` | yes | no |
| `network.wireguard.configs` | network | high | `SYSTEMDRIVE/Program Files/WireGuard/Data/Configurations` | yes | no |
| `profiles.other-users` | user-profiles | low | `USERS/*` | no | no |
| `programs.installed.all` | installed-programs | low | uninstall keys (all) | no | no |
| `system.crashdumps` | system-traces | high | `LOCALAPPDATA/CrashDumps` | no | no |
| `system.eventlogs` | system-traces | low | `SYSTEMDRIVE/Windows/System32/winevt/Logs` | no | no |
| `system.prefetch` | system-traces | medium | `SYSTEMDRIVE/Windows/Prefetch` | yes | no |
| `system.temp.user` | system-traces | medium | `LOCALAPPDATA/Temp` | no | no |
| `system.windows-old` | system-traces | medium | `SYSTEMDRIVE/Windows.old` | no | no |
| `wallet.electrum` | wallets | critical | `APPDATA/Electrum/wallets` | no | no |
| `wallet.exodus` | wallets | critical | `APPDATA/Exodus/exodus.wallet` | no | no |
| `wallet.ledger-live` | wallets | critical | `APPDATA/Ledger Wallet` | no | no |
| `wallet.metamask.chrome` | wallets | critical | `LOCALAPPDATA/Google/Chrome/User Data/*/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn` | no | no |
| `wallet.metamask.edge` | wallets | critical | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Local Extension Settings/ejbalbakoplchlghecdalmeeeajnimhm` | no | no |
| `wallet.monero-gui` | wallets | critical | `HOME/Documents/Monero/wallets` | no | no |

## macOS (50 rules, 0 verified)

| id | category | sensitivity | locator | elevation | verified |
|---|---|---|---|---|---|
| `activity.ds-store` | activity | low | `HOME/` | no | no |
| `activity.recent-items` | activity | medium | `LIBRARY/Application Support/com.apple.sharedfilelist` | no | no |
| `activity.shell-history.bash` | activity | medium | `HOME/.bash_history` | no | no |
| `activity.shell-history.zsh` | activity | medium | `HOME/.zsh_history` | no | no |
| `autostart.launch-agents` | autostart | low | `LIBRARY/LaunchAgents/*.plist` | no | no |
| `browser.brave.profiles` | browsers | medium | `LIBRARY/Application Support/BraveSoftware/Brave-Browser/*/Preferences` | no | no |
| `browser.chrome.history` | browsers | high | `LIBRARY/Application Support/Google/Chrome/*/History` | no | no |
| `browser.chrome.login-data` | browsers | critical | `LIBRARY/Application Support/Google/Chrome/*/Login Data` | no | no |
| `browser.chrome.profiles` | browsers | medium | `LIBRARY/Application Support/Google/Chrome/*/Preferences` | no | no |
| `browser.edge.profiles` | browsers | medium | `LIBRARY/Application Support/Microsoft Edge/*/Preferences` | no | no |
| `browser.firefox.profiles` | browsers | medium | `LIBRARY/Application Support/Firefox/Profiles/*/prefs.js` | no | no |
| `browser.opera.profiles` | browsers | medium | `LIBRARY/Application Support/com.operasoftware.Opera/Preferences` | no | no |
| `browser.safari.container` | browsers | high | `LIBRARY/Containers/com.apple.Safari` | no | no |
| `browser.safari.data` | browsers | high | `LIBRARY/Safari` | no | no |
| `browser.vivaldi.profiles` | browsers | medium | `LIBRARY/Application Support/Vivaldi/*/Preferences` | no | no |
| `cloud.dropbox` | cloud-sync | medium | `LIBRARY/CloudStorage/Dropbox*` | no | no |
| `cloud.google-drive` | cloud-sync | medium | `LIBRARY/CloudStorage/GoogleDrive-*` | no | no |
| `cloud.icloud-drive` | cloud-sync | medium | `LIBRARY/Mobile Documents` | no | no |
| `cloud.onedrive` | cloud-sync | medium | `LIBRARY/CloudStorage/OneDrive-*` | no | no |
| `credentials.keychains` | credentials | critical | `LIBRARY/Keychains` | no | no |
| `dev.aws.config` | developer-secrets | critical | `HOME/.aws` | no | no |
| `dev.azure.config` | developer-secrets | critical | `HOME/.azure` | no | no |
| `dev.docker.config` | developer-secrets | critical | `HOME/.docker/config.json` | no | no |
| `dev.git-credentials` | developer-secrets | critical | `HOME/.git-credentials` | no | no |
| `dev.kube.config` | developer-secrets | critical | `HOME/.kube` | no | no |
| `dev.npmrc` | developer-secrets | critical | `HOME/.npmrc` | no | no |
| `dev.ssh.keys` | developer-secrets | critical | `HOME/.ssh` | no | no |
| `email.apple-mail` | email | high | `LIBRARY/Mail` | no | no |
| `encryption.filevault.status` | disk-encryption | low | system query `filevault-status` | no | no |
| `files.desktop` | personal-files | medium | `HOME/Desktop` | no | no |
| `files.documents` | personal-files | medium | `HOME/Documents` | no | no |
| `files.downloads` | personal-files | medium | `HOME/Downloads` | no | no |
| `files.movies` | personal-files | medium | `HOME/Movies` | no | no |
| `files.music` | personal-files | medium | `HOME/Music` | no | no |
| `files.photos-library` | personal-files | medium | `HOME/Pictures/*.photoslibrary` | no | no |
| `files.trash` | personal-files | medium | `HOME/.Trash` | no | no |
| `msg.discord` | messaging | high | `LIBRARY/Application Support/discord` | no | no |
| `msg.imessage` | messaging | high | `LIBRARY/Messages` | no | no |
| `msg.signal` | messaging | high | `LIBRARY/Application Support/Signal` | no | no |
| `msg.slack` | messaging | high | `LIBRARY/Application Support/Slack` | no | no |
| `msg.telegram` | messaging | high | `LIBRARY/Application Support/Telegram Desktop` | no | no |
| `msg.whatsapp` | messaging | high | `LIBRARY/Application Support/WhatsApp` | no | no |
| `profiles.other-users` | user-profiles | low | `USERS/*` | no | no |
| `programs.applications` | installed-programs | low | `APPLICATIONS/*.app` | no | no |
| `system.caches` | system-traces | low | `LIBRARY/Caches` | no | no |
| `system.time-machine.prefs` | system-traces | low | `SYSTEM/Library/Preferences/com.apple.TimeMachine.plist` | no | no |
| `wallet.electrum` | wallets | critical | `LIBRARY/Application Support/Electrum` | no | no |
| `wallet.exodus` | wallets | critical | `LIBRARY/Application Support/Exodus` | no | no |
| `wallet.ledger-live` | wallets | critical | `LIBRARY/Application Support/Ledger*` | no | no |
| `wallet.monero-gui` | wallets | critical | `LIBRARY/Application Support/monero-wallet-gui` | no | no |

## Linux (0 rules, 0 verified)

_No rules yet._

