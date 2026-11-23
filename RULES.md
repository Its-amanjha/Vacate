# Rule catalog

Generated from `src/Vacate/rules/` by `tools/Update-RulesDoc.ps1`. Do not edit by hand.

`verified` means the location was confirmed on a real machine of that platform. Unverified rules still run; the report lists them.

## Windows (98 rules, 45 verified)

| id | category | sensitivity | locator | elevation | verified |
|---|---|---|---|---|---|
| `activity.featureusage` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage` | no | yes (Windows 11 Pro 26300) |
| `activity.jumplists.automatic` | activity | medium | `APPDATA/Microsoft/Windows/Recent/AutomaticDestinations` | no | yes (Windows 11 Pro 26300) |
| `activity.muicache` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MuiCache` | no | no |
| `activity.recent-items` | activity | medium | `APPDATA/Microsoft/Windows/Recent` | no | yes (Windows 11 Pro 26300) |
| `activity.runmru` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU` | no | yes (Windows 11 Pro 26300) |
| `activity.shellbags` | activity | medium | `HKCU\Software\Microsoft\Windows\Shell\BagMRU` | no | yes (Windows 11 Pro 26300) |
| `activity.typedpaths` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths` | no | yes (Windows 11 Pro 26300) |
| `activity.userassist` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist` | no | yes (Windows 11 Pro 26300) |
| `activity.wordwheelquery` | activity | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery` | no | no |
| `ai.claude.desktop` | ai-assistants | high | `APPDATA/Claude` | no | no |
| `ai.copilot.history` | ai-assistants | high | `LOCALAPPDATA/Packages/Microsoft.Copilot_*` | no | no |
| `ai.recall.data` | ai-assistants | high | `LOCALAPPDATA/CoreAIPlatform.00/UKP` | no | no |
| `autostart.run-key-machine` | autostart | low | `HKLM\Software\Microsoft\Windows\CurrentVersion\Run` | no | yes (Windows 11 Pro 26300) |
| `autostart.run-key-user` | autostart | low | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | no | yes (Windows 11 Pro 26300) |
| `autostart.startup-folder` | autostart | low | `APPDATA/Microsoft/Windows/Start Menu/Programs/Startup` | no | no |
| `browser.brave.profiles` | browsers | medium | `LOCALAPPDATA/BraveSoftware/Brave-Browser/User Data/*/Preferences` | no | no |
| `browser.chrome.cookies` | browsers | high | `LOCALAPPDATA/Google/Chrome/User Data/*/Network/Cookies` | no | yes (Windows 11 Pro 26300) |
| `browser.chrome.history` | browsers | high | `LOCALAPPDATA/Google/Chrome/User Data/*/History` | no | yes (Windows 11 Pro 26300) |
| `browser.chrome.login-data` | browsers | critical | `LOCALAPPDATA/Google/Chrome/User Data/*/Login Data` | no | yes (Windows 11 Pro 26300) |
| `browser.chrome.profiles` | browsers | medium | `LOCALAPPDATA/Google/Chrome/User Data/*/Preferences` | no | yes (Windows 11 Pro 26300) |
| `browser.chrome.web-data` | browsers | high | `LOCALAPPDATA/Google/Chrome/User Data/*/Web Data` | no | yes (Windows 11 Pro 26300) |
| `browser.edge.cookies` | browsers | high | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Network/Cookies` | no | yes (Windows 11 Pro 26300) |
| `browser.edge.history` | browsers | high | `LOCALAPPDATA/Microsoft/Edge/User Data/*/History` | no | yes (Windows 11 Pro 26300) |
| `browser.edge.login-data` | browsers | critical | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Login Data` | no | yes (Windows 11 Pro 26300) |
| `browser.edge.profiles` | browsers | medium | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Preferences` | no | yes (Windows 11 Pro 26300) |
| `browser.firefox.cookies` | browsers | high | `APPDATA/Mozilla/Firefox/Profiles/*/cookies.sqlite` | no | no |
| `browser.firefox.key4` | browsers | critical | `APPDATA/Mozilla/Firefox/Profiles/*/key4.db` | no | no |
| `browser.firefox.logins` | browsers | critical | `APPDATA/Mozilla/Firefox/Profiles/*/logins.json` | no | no |
| `browser.firefox.places` | browsers | high | `APPDATA/Mozilla/Firefox/Profiles/*/places.sqlite` | no | no |
| `browser.firefox.profiles` | browsers | medium | `APPDATA/Mozilla/Firefox/Profiles/*` | no | no |
| `browser.opera.gx` | browsers | medium | `APPDATA/Opera Software/Opera GX Stable/Default/Preferences` | no | yes (Windows 11 Pro 26300) |
| `browser.opera.profiles` | browsers | medium | `APPDATA/Opera Software/Opera Stable/Default/Preferences` | no | no |
| `browser.vivaldi.profiles` | browsers | medium | `LOCALAPPDATA/Vivaldi/User Data/*/Preferences` | no | no |
| `browser.zen.profiles` | browsers | medium | `APPDATA/zen/Profiles/*/prefs.js` | no | no |
| `cloud.onedrive` | cloud-sync | medium | `HOME/OneDrive*` | no | yes (Windows 11 Pro 26300) |
| `containers.docker-desktop` | containers-vms | medium | `LOCALAPPDATA/Docker` | no | yes (Windows 11 Pro 26300) |
| `containers.virtualbox` | containers-vms | medium | `HOME/VirtualBox VMs` | no | no |
| `containers.wsl-distros` | containers-vms | medium | `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` | no | yes (Windows 11 Pro 26300) |
| `credentials.1password.desktop` | credentials | critical | `LOCALAPPDATA/1Password` | no | no |
| `credentials.bitwarden.desktop` | credentials | critical | `APPDATA/Bitwarden` | no | no |
| `credentials.bitwarden.store` | credentials | critical | `LOCALAPPDATA/Packages/8bitSolutionsLLC.bitwardendesktop_h4e712dmw3xyy/LocalCache/Roaming/Bitwarden` | no | no |
| `credentials.keepass.config` | credentials | medium | `APPDATA/KeePass/KeePass.config.xml` | no | no |
| `credentials.keepassxc.config` | credentials | medium | `APPDATA/KeePassXC` | no | no |
| `credentials.windows.credentials-local` | credentials | critical | `LOCALAPPDATA/Microsoft/Credentials` | no | yes (Windows 11 Pro 26300) |
| `credentials.windows.credentials-roaming` | credentials | critical | `APPDATA/Microsoft/Credentials` | no | yes (Windows 11 Pro 26300) |
| `credentials.windows.dpapi-masterkeys` | credentials | critical | `APPDATA/Microsoft/Protect` | no | yes (Windows 11 Pro 26300) |
| `credentials.windows.vault` | credentials | critical | `LOCALAPPDATA/Microsoft/Vault` | no | yes (Windows 11 Pro 26300) |
| `dev.aws.config` | developer-secrets | critical | `HOME/.aws` | no | no |
| `dev.azure.config` | developer-secrets | critical | `HOME/.azure` | no | no |
| `dev.docker.config` | developer-secrets | critical | `HOME/.docker/config.json` | no | yes (Windows 11 Pro 26300) |
| `dev.git-credentials` | developer-secrets | critical | `HOME/.git-credentials` | no | no |
| `dev.kube.config` | developer-secrets | critical | `HOME/.kube` | no | no |
| `dev.npmrc` | developer-secrets | critical | `HOME/.npmrc` | no | no |
| `dev.ssh.keys` | developer-secrets | critical | `HOME/.ssh` | no | no |
| `email.outlook.data` | email | high | `LOCALAPPDATA/Microsoft/Outlook` | no | no |
| `email.outlook.new` | email | high | `LOCALAPPDATA/Packages/Microsoft.OutlookForWindows_8wekyb3d8bbwe` | no | yes (Windows 11 Pro 26300) |
| `email.thunderbird.profiles` | email | high | `APPDATA/Thunderbird/Profiles/*` | no | no |
| `encryption.bitlocker.status` | disk-encryption | low | `root/CIMV2/Security/MicrosoftVolumeEncryption:Win32_EncryptableVolume` | yes | yes (Windows 11 Pro 26300) |
| `encryption.tpm.presence` | disk-encryption | low | `root/CIMV2/Security/MicrosoftTpm:Win32_Tpm` | yes | yes (Windows 11 Pro 26300) |
| `files.desktop` | personal-files | medium | `HOME/Desktop` | no | yes (Windows 11 Pro 26300) |
| `files.documents` | personal-files | medium | `HOME/Documents` | no | yes (Windows 11 Pro 26300) |
| `files.downloads` | personal-files | medium | `HOME/Downloads` | no | yes (Windows 11 Pro 26300) |
| `files.pictures` | personal-files | medium | `HOME/Pictures` | no | yes (Windows 11 Pro 26300) |
| `files.videos` | personal-files | medium | `HOME/Videos` | no | yes (Windows 11 Pro 26300) |
| `games.battlenet` | games-licenses | medium | `PROGRAMDATA/Battle.net` | no | no |
| `games.epic` | games-licenses | medium | `LOCALAPPDATA/EpicGamesLauncher/Saved` | no | no |
| `games.steam` | games-licenses | medium | `LOCALAPPDATA/Steam` | no | no |
| `msg.discord` | messaging | high | `APPDATA/discord` | no | no |
| `msg.phone-link` | messaging | high | `LOCALAPPDATA/Packages/Microsoft.YourPhone_8wekyb3d8bbwe` | no | yes (Windows 11 Pro 26300) |
| `msg.signal` | messaging | high | `APPDATA/Signal` | no | no |
| `msg.slack` | messaging | high | `APPDATA/Slack` | no | no |
| `msg.teams` | messaging | high | `LOCALAPPDATA/Packages/MSTeams_8wekyb3d8bbwe/LocalCache/Microsoft/MSTeams` | no | yes (Windows 11 Pro 26300) |
| `msg.telegram` | messaging | high | `APPDATA/Telegram Desktop/tdata` | no | no |
| `msg.whatsapp` | messaging | high | `LOCALAPPDATA/Packages/5319275A.WhatsAppDesktop_*/LocalState` | no | no |
| `msg.zoom.desktop` | messaging | high | `APPDATA/Zoom` | no | no |
| `network.bluetooth.devices` | network | medium | `HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices` | no | yes (Windows 11 Pro 26300) |
| `network.mapped-drives` | network | high | `HKCU\Network` | no | yes (Windows 11 Pro 26300) |
| `network.networklist.profiles` | network | medium | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles` | no | no |
| `network.openvpn.configs` | network | high | `HOME/OpenVPN/config` | no | no |
| `network.printers.user` | network | low | `HKCU\Printers\Connections` | no | yes (Windows 11 Pro 26300) |
| `network.rdp.mru` | network | high | `HKCU\Software\Microsoft\Terminal Server Client\Default` | no | no |
| `network.wifi.profiles` | network | critical | `PROGRAMDATA/Microsoft/Wlansvc/Profiles/Interfaces` | yes | yes (Windows 11 Pro 26300) |
| `network.wireguard.configs` | network | high | `SYSTEMDRIVE/Program Files/WireGuard/Data/Configurations` | yes | no |
| `personal.notion.desktop` | personal-files | medium | `APPDATA/Notion` | no | no |
| `personal.obsidian.config` | personal-files | medium | `APPDATA/Obsidian` | no | no |
| `profiles.other-users` | user-profiles | low | `USERS/*` | no | no |
| `programs.installed.all` | installed-programs | low | uninstall keys (all) | no | yes (Windows 11 Pro 26300) |
| `system.crashdumps` | system-traces | high | `LOCALAPPDATA/CrashDumps` | no | no |
| `system.eventlogs` | system-traces | low | `SYSTEMDRIVE/Windows/System32/winevt/Logs` | no | yes (Windows 11 Pro 26300) |
| `system.prefetch` | system-traces | medium | `SYSTEMDRIVE/Windows/Prefetch` | yes | yes (Windows 11 Pro 26300) |
| `system.temp.user` | system-traces | medium | `LOCALAPPDATA/Temp` | no | yes (Windows 11 Pro 26300) |
| `system.windows-old` | system-traces | medium | `SYSTEMDRIVE/Windows.old` | no | no |
| `wallet.electrum` | wallets | critical | `APPDATA/Electrum/wallets` | no | no |
| `wallet.exodus` | wallets | critical | `APPDATA/Exodus/exodus.wallet` | no | no |
| `wallet.ledger-live` | wallets | critical | `APPDATA/Ledger Wallet` | no | no |
| `wallet.metamask.chrome` | wallets | critical | `LOCALAPPDATA/Google/Chrome/User Data/*/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn` | no | no |
| `wallet.metamask.edge` | wallets | critical | `LOCALAPPDATA/Microsoft/Edge/User Data/*/Local Extension Settings/ejbalbakoplchlghecdalmeeeajnimhm` | no | no |
| `wallet.monero-gui` | wallets | critical | `HOME/Documents/Monero/wallets` | no | no |

## macOS (62 rules, 24 verified)

| id | category | sensitivity | locator | elevation | verified |
|---|---|---|---|---|---|
| `activity.calendars` | activity | high | `LIBRARY/Calendars` | no | no |
| `activity.contacts` | activity | high | `LIBRARY/Application Support/AddressBook` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `activity.download-quarantine` | activity | high | `LIBRARY/Preferences/com.apple.LaunchServices.QuarantineEventsV2` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `activity.ds-store.desktop` | activity | low | `HOME/Desktop` | no | no |
| `activity.ds-store.documents` | activity | low | `HOME/Documents` | no | no |
| `activity.ds-store.downloads` | activity | low | `HOME/Downloads` | no | no |
| `activity.recent-items` | activity | medium | `LIBRARY/Application Support/com.apple.sharedfilelist` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `activity.reminders` | activity | medium | `LIBRARY/Group Containers/group.com.apple.reminders` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `activity.saved-app-state` | activity | medium | `LIBRARY/Saved Application State` | no | no |
| `activity.shell-history.bash` | activity | medium | `HOME/.bash_history` | no | no |
| `activity.shell-history.zsh` | activity | medium | `HOME/.zsh_history` | no | no |
| `autostart.launch-agents` | autostart | low | `LIBRARY/LaunchAgents/*.plist` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `browser.brave.profiles` | browsers | medium | `LIBRARY/Application Support/BraveSoftware/Brave-Browser/*/Preferences` | no | no |
| `browser.chrome.history` | browsers | high | `LIBRARY/Application Support/Google/Chrome/*/History` | no | no |
| `browser.chrome.login-data` | browsers | critical | `LIBRARY/Application Support/Google/Chrome/*/Login Data` | no | no |
| `browser.chrome.profiles` | browsers | medium | `LIBRARY/Application Support/Google/Chrome/*/Preferences` | no | no |
| `browser.edge.profiles` | browsers | medium | `LIBRARY/Application Support/Microsoft Edge/*/Preferences` | no | no |
| `browser.firefox.profiles` | browsers | medium | `LIBRARY/Application Support/Firefox/Profiles/*/prefs.js` | no | no |
| `browser.opera.profiles` | browsers | medium | `LIBRARY/Application Support/com.operasoftware.Opera/Preferences` | no | no |
| `browser.safari.container` | browsers | high | `LIBRARY/Containers/com.apple.Safari` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `browser.safari.data` | browsers | high | `LIBRARY/Safari` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `browser.vivaldi.profiles` | browsers | medium | `LIBRARY/Application Support/Vivaldi/*/Preferences` | no | no |
| `cloud.dropbox` | cloud-sync | medium | `LIBRARY/CloudStorage/Dropbox*` | no | no |
| `cloud.google-drive` | cloud-sync | medium | `LIBRARY/CloudStorage/GoogleDrive-*` | no | no |
| `cloud.icloud-clouddocs` | cloud-sync | medium | `LIBRARY/Application Support/CloudDocs` | no | no |
| `cloud.icloud-drive` | cloud-sync | medium | `LIBRARY/Mobile Documents` | no | no |
| `cloud.onedrive` | cloud-sync | medium | `LIBRARY/CloudStorage/OneDrive-*` | no | no |
| `credentials.keychains` | credentials | critical | `LIBRARY/Keychains` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `dev.aws.config` | developer-secrets | critical | `HOME/.aws` | no | no |
| `dev.azure.config` | developer-secrets | critical | `HOME/.azure` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `dev.docker.config` | developer-secrets | critical | `HOME/.docker/config.json` | no | no |
| `dev.git-credentials` | developer-secrets | critical | `HOME/.git-credentials` | no | no |
| `dev.kube.config` | developer-secrets | critical | `HOME/.kube` | no | no |
| `dev.npmrc` | developer-secrets | critical | `HOME/.npmrc` | no | no |
| `dev.ssh.keys` | developer-secrets | critical | `HOME/.ssh` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `email.apple-mail` | email | high | `LIBRARY/Mail` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `email.apple-notes` | email | high | `LIBRARY/Group Containers/group.com.apple.notes` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `encryption.filevault.status` | disk-encryption | low | system query `filevault-status` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `files.desktop` | personal-files | medium | `HOME/Desktop` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `files.documents` | personal-files | medium | `HOME/Documents` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `files.downloads` | personal-files | medium | `HOME/Downloads` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `files.movies` | personal-files | medium | `HOME/Movies` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `files.music` | personal-files | medium | `HOME/Music` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `files.photos-library` | personal-files | medium | `HOME/Pictures/*.photoslibrary` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `files.trash` | personal-files | medium | `HOME/.Trash` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `msg.discord` | messaging | high | `LIBRARY/Application Support/discord` | no | no |
| `msg.imessage` | messaging | high | `LIBRARY/Messages` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `msg.signal` | messaging | high | `LIBRARY/Application Support/Signal` | no | no |
| `msg.slack` | messaging | high | `LIBRARY/Application Support/Slack` | no | no |
| `msg.telegram` | messaging | high | `LIBRARY/Application Support/Telegram Desktop` | no | no |
| `msg.whatsapp` | messaging | high | `LIBRARY/Group Containers/group.net.whatsapp.WhatsApp.shared` | no | no |
| `network.bluetooth.devices` | network | medium | `SYSTEM/Library/Bluetooth/Library/Preferences/com.apple.MobileBluetooth.devices.plist` | yes | no |
| `network.wifi.known-networks` | network | high | `SYSTEM/Library/Preferences/com.apple.wifi.known-networks.plist` | yes | no |
| `profiles.other-users` | user-profiles | low | `USERS/*` | no | no |
| `programs.applications` | installed-programs | low | `APPLICATIONS/*.app` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `system.caches` | system-traces | low | `LIBRARY/Caches` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `system.time-machine.prefs` | system-traces | low | `SYSTEM/Library/Preferences/com.apple.TimeMachine.plist` | no | yes (macOS 26.7.2 (GitHub Actions CI)) |
| `wallet.electrum` | wallets | critical | `HOME/.electrum` | no | no |
| `wallet.exodus` | wallets | critical | `LIBRARY/Application Support/Exodus` | no | no |
| `wallet.ledger-live` | wallets | critical | `LIBRARY/Application Support/Ledger*` | no | no |
| `wallet.monero-gui` | wallets | critical | `LIBRARY/Application Support/monero-wallet-gui` | no | no |
| `wallet.monero-gui.wallets` | wallets | critical | `HOME/Monero/wallets` | no | no |

## Linux (74 rules, 20 verified)

| id | category | sensitivity | locator | elevation | verified |
|---|---|---|---|---|---|
| `activity.recently-used` | activity | medium | `XDG_DATA/recently-used.xbel` | no | no |
| `activity.shell-history.bash` | activity | high | `HOME/.bash_history` | no | yes (Ubuntu 24.04 (WSL)) |
| `activity.shell-history.fish` | activity | high | `XDG_DATA/fish/fish_history` | no | no |
| `activity.shell-history.zsh` | activity | high | `HOME/.zsh_history` | no | no |
| `activity.thumbnails` | activity | low | `HOME/.cache/thumbnails` | no | no |
| `autostart.desktop-entries` | autostart | low | `XDG_CONFIG/autostart/*.desktop` | no | no |
| `autostart.systemd-user` | autostart | low | `XDG_CONFIG/systemd/user/*` | no | no |
| `browser.brave.profiles` | browsers | medium | `XDG_CONFIG/BraveSoftware/Brave-Browser/*/Preferences` | no | no |
| `browser.chrome.cache` | browsers | low | `HOME/.cache/google-chrome` | no | no |
| `browser.chrome.profiles` | browsers | medium | `XDG_CONFIG/google-chrome/*/Preferences` | no | no |
| `browser.chromium.profiles` | browsers | medium | `XDG_CONFIG/chromium/*/Preferences` | no | no |
| `browser.chromium.profiles.snap` | browsers | medium | `HOME/snap/chromium/common/chromium/*/Preferences` | no | no |
| `browser.firefox.cache` | browsers | low | `HOME/.cache/mozilla/firefox` | no | no |
| `browser.firefox.cache.snap` | browsers | medium | `HOME/snap/firefox/common/.cache/mozilla/firefox` | no | yes (Ubuntu 24.04 (WSL)) |
| `browser.firefox.profiles` | browsers | medium | `HOME/.mozilla/firefox/*/prefs.js` | no | no |
| `browser.firefox.profiles.flatpak` | browsers | medium | `HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/*/prefs.js` | no | no |
| `browser.firefox.profiles.snap` | browsers | medium | `HOME/snap/firefox/common/.mozilla/firefox/*/prefs.js` | no | yes (Ubuntu 24.04 (WSL)) |
| `browser.firefox.profiles.xdg` | browsers | medium | `XDG_CONFIG/mozilla/firefox/*/prefs.js` | no | no |
| `browser.opera.profiles` | browsers | medium | `XDG_CONFIG/opera/*/Preferences` | no | no |
| `browser.vivaldi.profiles` | browsers | medium | `XDG_CONFIG/vivaldi/*/Preferences` | no | no |
| `cloud.dropbox` | cloud-sync | medium | `HOME/Dropbox` | no | no |
| `cloud.nextcloud` | cloud-sync | medium | `XDG_CONFIG/Nextcloud` | no | no |
| `containers.libvirt` | containers-vms | medium | `VAR/lib/libvirt/images` | yes | no |
| `containers.podman` | containers-vms | medium | `XDG_DATA/containers/storage` | no | yes (Ubuntu 24.04 (WSL)) |
| `containers.virtualbox` | containers-vms | medium | `HOME/VirtualBox VMs` | no | no |
| `credentials.gnupg` | credentials | critical | `HOME/.gnupg` | no | yes (Ubuntu 24.04 (WSL)) |
| `credentials.keyrings` | credentials | critical | `XDG_DATA/keyrings` | no | no |
| `credentials.password-store` | credentials | critical | `HOME/.password-store` | no | no |
| `dev.aws.config` | developer-secrets | critical | `HOME/.aws` | no | yes (Ubuntu 24.04 (WSL)) |
| `dev.azure.config` | developer-secrets | critical | `HOME/.azure` | no | no |
| `dev.docker.config` | developer-secrets | critical | `HOME/.docker` | no | no |
| `dev.gh-cli` | developer-secrets | critical | `XDG_CONFIG/gh/hosts.yml` | no | no |
| `dev.git-credentials` | developer-secrets | critical | `HOME/.git-credentials` | no | yes (Ubuntu 24.04 (WSL)) |
| `dev.kube.config` | developer-secrets | critical | `HOME/.kube` | no | yes (Ubuntu 24.04 (WSL)) |
| `dev.netrc` | developer-secrets | critical | `HOME/.netrc` | no | no |
| `dev.npmrc` | developer-secrets | critical | `HOME/.npmrc` | no | yes (Ubuntu 24.04 (WSL)) |
| `dev.pgpass` | developer-secrets | critical | `HOME/.pgpass` | no | no |
| `dev.ssh.keys` | developer-secrets | critical | `HOME/.ssh` | no | yes (Ubuntu 24.04 (WSL)) |
| `email.thunderbird.profiles` | email | high | `HOME/.thunderbird/*` | no | no |
| `email.thunderbird.profiles.snap` | email | high | `HOME/snap/thunderbird/common/.thunderbird/*` | no | no |
| `encryption.block-devices` | disk-encryption | medium | system query `block-devices` | no | yes (Ubuntu 24.04 (WSL)) |
| `encryption.crypttab` | disk-encryption | medium | `ETC/crypttab` | no | no |
| `files.desktop` | personal-files | medium | `HOME/Desktop` | no | yes (Ubuntu 24.04 (WSL)) |
| `files.documents` | personal-files | medium | `HOME/Documents` | no | yes (Ubuntu 24.04 (WSL)) |
| `files.downloads` | personal-files | medium | `HOME/Downloads` | no | yes (Ubuntu 24.04 (WSL)) |
| `files.pictures` | personal-files | medium | `HOME/Pictures` | no | yes (Ubuntu 24.04 (WSL)) |
| `files.trash` | personal-files | medium | `XDG_DATA/Trash` | no | yes (Ubuntu 24.04 (WSL)) |
| `files.videos` | personal-files | medium | `HOME/Videos` | no | yes (Ubuntu 24.04 (WSL)) |
| `games.steam` | games-licenses | medium | `XDG_DATA/Steam/userdata` | no | no |
| `games.steam.flatpak` | games-licenses | medium | `HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata` | no | no |
| `msg.discord` | messaging | high | `XDG_CONFIG/discord` | no | no |
| `msg.discord.flatpak` | messaging | high | `HOME/.var/app/com.discordapp.Discord/config/discord` | no | no |
| `msg.element` | messaging | high | `XDG_CONFIG/Element` | no | no |
| `msg.element.flatpak` | messaging | high | `HOME/.var/app/im.riot.Riot/config/Element` | no | no |
| `msg.signal` | messaging | high | `XDG_CONFIG/Signal` | no | no |
| `msg.signal.flatpak` | messaging | high | `HOME/.var/app/org.signal.Signal/config/Signal` | no | no |
| `msg.slack` | messaging | high | `XDG_CONFIG/Slack` | no | no |
| `msg.slack.snap` | messaging | high | `HOME/snap/slack/*/.config/Slack` | no | no |
| `msg.telegram` | messaging | high | `XDG_DATA/TelegramDesktop/tdata` | no | no |
| `msg.telegram.flatpak` | messaging | high | `HOME/.var/app/org.telegram.desktop/data/TelegramDesktop/tdata` | no | no |
| `msg.telegram.snap` | messaging | high | `HOME/snap/telegram-desktop/common/.local/share/TelegramDesktop/tdata` | no | no |
| `network.bluetooth.devices` | network | medium | `VAR/lib/bluetooth` | yes | no |
| `network.cups.printers` | network | medium | `ETC/cups/printers.conf` | yes | no |
| `network.networkmanager.connections` | network | critical | `ETC/NetworkManager/system-connections` | yes | no |
| `network.wireguard.configs` | network | critical | `ETC/wireguard` | yes | no |
| `profiles.other-users` | user-profiles | low | `USERS/*` | no | no |
| `programs.desktop-entries` | installed-programs | low | `APPLICATIONS/*.desktop` | no | yes (Ubuntu 24.04 (WSL)) |
| `programs.desktop-entries.user` | installed-programs | low | `XDG_DATA/applications/*.desktop` | no | no |
| `system.journal.user` | system-traces | low | `VAR/log/journal` | no | yes (Ubuntu 24.04 (WSL)) |
| `system.var-log` | system-traces | low | `VAR/log` | no | yes (Ubuntu 24.04 (WSL)) |
| `wallet.electrum` | wallets | critical | `HOME/.electrum/wallets` | no | no |
| `wallet.exodus` | wallets | critical | `XDG_CONFIG/Exodus` | no | no |
| `wallet.ledger-live` | wallets | critical | `XDG_CONFIG/Ledger Live` | no | no |
| `wallet.monero-gui` | wallets | critical | `HOME/Monero` | no | no |

