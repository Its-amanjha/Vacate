# Limits

vacate only reports what it can see. This page lists what it cannot see, so you can decide what to
check by hand. A short report, or a report with nothing in it, does not mean the machine is clean.

The report's "What this does not see" section prints the design limits below. This page says the
same things and adds one sentence on what to do about each one. The last section lists limits seen
in real scans; the report shows those in its skip list and completeness flag instead.

Status: Phase 1 works end to end on Windows 11 and Ubuntu 24.04 (WSL). See [README.md](README.md).

## All platforms

- **SSD spare area.** Solid-state drives keep spare blocks outside any file or folder, so old
  copies of data can survive there, out of reach of any scanner. What to do: use the drive
  maker's secure-erase tool, or keep full-disk encryption on and erase the whole drive before
  you hand it over.

- **Cloud and backup copies.** Files that were already synced or backed up are stored somewhere
  else and are not on this disk, so vacate does not check them. What to do: sign out of each
  cloud account, remove this device from the account, and check your backups separately.

- **Firmware and boot code.** BIOS/UEFI settings, the TPM and EFI partitions are not inspected.
  What to do: reset the firmware to its defaults and clear TPM ownership using the vendor's
  instructions or your IT department's.

- **Deleted data that was not overwritten.** A deleted file can still be recovered with forensic
  tools; vacate only sees files that exist now. What to do: overwrite free space or erase the
  whole drive; do not treat deletion as erasure.

- **Other systems and disks.** Another operating system installed on the machine, and any disk
  other than the one being scanned, is not checked. What to do: scan and wipe each system and
  disk separately.

- **Encrypted containers.** VeraCrypt volumes and encrypted archives are seen at most as files;
  their contents are not. What to do: open and check them yourself, or delete the container whole,
  because vacate cannot list what is inside.

- **Swap, page and hibernation files.** These files can hold fragments of anything that was in
  memory, and they are not read. What to do: turn off hibernation and overwrite or erase the
  disk; full-disk encryption protects these files at rest.

- **Memory (RAM).** Running memory is not inspected. What to do: shut the machine down, rather
  than putting it to sleep, before you hand it over.

- **Only known locations.** vacate checks the places it has a rule for. An app it has no rule for
  is invisible to it, and a clean report is not proof that the machine is clean. What to do:
  review your installed programs and think about what else you used; treat a clean report as a
  hint, not a guarantee.

- **File contents.** File contents are never opened, so vacate cannot tell whether a file is
  empty, still signed in, or holds anything personal. What to do: open each reported item and
  decide; the trace tells you where to look, not what you will find.

## Windows

- **BitLocker recovery keys held in accounts.** Recovery keys stored in your Microsoft account,
  Entra ID or Active Directory are not visible from this machine. What to do: check the device
  page of your Microsoft account and any work or school account, and keep the recovery key
  somewhere you control.

- **TPM ownership and keys.** TPM ownership and the keys stored in it are not inspected. What to
  do: clear TPM ownership in Windows Security if the vendor or your IT department says to, and
  check separately for keys kept in the TPM.

- **Other drives.** Only the system drive is scanned. What to do: check, scan and wipe every
  other drive separately.

- **Other user profiles.** Other accounts are listed by name only; their contents are not
  checked. What to do: sign in to each account, or remove it, and check its files, browser data
  and cloud clients by hand.

- **Admin-only locations.** Without administrator rights, locations that need admin access (for
  example Wi-Fi profiles, Prefetch and BitLocker status) are skipped and listed as skipped. What
  to do: read the "Skipped" section, and if those items matter, run again from an administrator
  account you control or check them by hand.

## macOS

- **Privacy-protected folders (TCC).** Folders protected by macOS privacy controls are skipped
  unless the terminal has Full Disk Access. What to do: grant Full Disk Access to the terminal
  app you run vacate from (System Settings > Privacy & Security > Full Disk Access), or check
  those folders by hand.

- **FileVault recovery keys held by Apple or iCloud.** These keys are not visible from this
  machine. What to do: check your Apple ID devices and recovery-key settings, and store the key
  somewhere you control.

- **APFS local snapshots.** Local snapshots can keep old copies of files and are not inspected.
  What to do: list them with `tmutil listlocalsnapshots /` and delete the ones you do not need, or
  erase the Mac.

- **Secure Enclave.** The Secure Enclave and its keys are not inspected. What to do: erase the Mac
  with Erase All Content and Settings before you hand it over; that destroys the keys.

- **Keychain items.** Keychain items are seen only as keychain files; individual items,
  especially ones that need unlocking, are not. What to do: remove the items you do not need in
  Keychain Access, sign out of the accounts, and let the erase step destroy the rest.

## Linux

- **Root-only files.** Files only root can read are skipped when vacate runs without root, which
  is the default. What to do: read the "Skipped" section and check `/etc` and `/var` by hand, or
  run with `-AllowRoot` only on a machine you own and only if you accept the wider access.

- **LUKS keyslots and headers.** The LUKS header and its keyslots are not inspected. What to do:
  reinstall the system over the disk, or destroy the LUKS header using your distribution's
  documented procedure, if the disk leaves your control.

- **Swap partitions and files.** Swap is not read. What to do: turn swap off, use encrypted swap,
  or reinstall the system.

- **System journal contents.** The journal is not read; at most its size is reported. What to do:
  reduce or clear it as root (`journalctl --rotate`, then `journalctl --vacuum-time=1s`), or
  reinstall.

- **Container images and layers.** Container data is seen as folders and sizes only. What to do:
  remove the images, layers and volumes you do not need, or wipe the disk.

- **Distribution-specific package state.** vacate does not analyse which packages hold your data.
  What to do: review your installed packages with your package manager and remove the apps you
  used.

- **Other mounted file systems.** Other mounts are not scanned. What to do: unmount each one and
  check or wipe it separately.

## Limits seen in real scans

- **Time limits on a huge folder.** Each rule has a 10-second limit and the whole scan has a
  budget (120 seconds by default). The limit is checked between files while a folder is walked, so
  a rule stops within one file of it. A single slow system call (one registry or WMI read) cannot be
  interrupted and may run past the limit; PowerShell 5.1 has no way to cancel it (DECISIONS D2). A folder such as Temp can be so large that a rule stops before
  it has counted everything. The rule is then recorded with reason `timeout` in the skip list
  (with a partial trace, if it produced one), or the remaining rules are skipped with reason
  `budget`, and the report says the scan did not finish.
  What to do: read the "Skipped and failed" section, run again, or check that folder by hand. A
  partial count is not a clean result.

- **WSL is not a desktop Linux.** In WSL, Windows drives mounted under `/mnt/*` are outside the
  scanned roots, and a fresh WSL install usually has no desktop browser, mail or chat apps. A scan
  there finds far less than the same scan on a desktop Linux install. What to do: scan the Windows
  side separately, and check any app you installed inside WSL by hand.

## Cleanup plan (Phase 2)

- **Advice, not action.** `vacate plan` writes instructions. It does not check that you followed
  them, that an export worked, or that an account is really signed out. Run a new scan afterwards
  to see what is left.
- **Menu paths age.** Steps name menus from vendor documentation at the time of writing. If a menu
  has moved, follow the goal the step describes and the vendor page in `source`.
- **Only what the scan found.** A plan has one step per rule that found something. Data in places
  vacate does not know about gets no step.
- **A redacted report gives a redacted plan.** Locations show as hashes; run `plan` on the
  unredacted report on the machine itself to see real paths.

## Clean and undo (Phase 3)

- **Few steps qualify.** Only plan steps whose action is `remove`, for a single file or folder
  inside your own profile, can be moved. Wallets, personal folders (Desktop, Documents and so on),
  registry and system locations, rules that search inside a folder, and steps that need you to
  sign out or decide are always left to you. On the current catalog that is 4 Windows, 4 macOS
  and 5 Linux rules.
- **The Recycle Bin or Trash is not erasure.** Moved items still take space and anyone using your
  account can restore them until it is emptied. Empty it, or use the full reset, before handover.
- **Apps can recreate data.** If an app is still running it may write its folder again; the
  re-scan after `clean` shows what came back. Close the apps the plan names first.
- **A moved item can fail to move.** A file in use, a permission problem or a drive without a
  Recycle Bin makes vacate leave the item where it is and say so. It never falls back to a
  permanent delete.
- **Undo needs the original place to be free.** If something new exists at the old path, undo
  leaves the item in the Recycle Bin/Trash and reports it instead of overwriting.
- **Run it on the machine that was scanned, as your normal user.** Clean refuses a report from
  another machine or platform, a redacted report, and administrator or root sessions.

## What a clean report means

Nothing was found in the locations vacate knows about, on the paths it was allowed to read. It
does not mean the data is gone. For a machine that leaves your control, use full-disk encryption
and the operating system's own erase or reset step, and read the remaining limits above first.
