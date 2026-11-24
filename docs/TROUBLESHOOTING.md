# Troubleshooting vacate

This guide explains errors and warning messages you might see while running vacate, why they
happen, and how to fix them.

---

## 1. Starting vacate

### "running scripts is disabled on this system"
- **Message:**
  `File ...\vacate.ps1 cannot be loaded because running scripts is disabled`
  `on this system.`
- **Why:** Windows PowerShell restricts script execution by default to protect against
  unauthorized scripts.
- **Fix:**
  1. Open PowerShell.
  2. Run vacate with the bypass flag:
     `powershell -ExecutionPolicy Bypass -File .\vacate.ps1 <command>`

### Double-clicking vacate.ps1 or running from cmd.exe
- **Symptom:** Double-clicking `vacate.ps1` opens Notepad, opens a "How do you want to open this
  file?" prompt, or briefly flashes a black window and closes. Running from Command Prompt
  (`cmd.exe`) shows an error or opens an editor.
- **Why:** `vacate.ps1` is a PowerShell script. It cannot run directly from Windows Explorer or the
  legacy Command Prompt.
- **Fix:**
  1. Press `Win + X` and select **Terminal** or **PowerShell**.
  2. Change to the folder where you unpacked vacate:
     `cd C:\vacate`
  3. Run vacate using PowerShell:
     `powershell -ExecutionPolicy Bypass -File .\vacate.ps1 <command>`

### "'vacate' is not recognized as an internal or external command"
- **Message:** `'vacate' is not recognized as an internal or external command, operable program
  or batch file.`
- **Why:** Command Prompt is not in the unzipped vacate folder, or Windows is set not to run
  programs from the current folder (the NoDefaultCurrentDirectoryInExePath setting).
- **Fix:**
  1. Go to the unzipped folder: `cd /d C:\vacate\vacate-<version>` (your folder may differ).
  2. Run `.\vacate.cmd scan` instead of `vacate scan`.

### "-Elevated was passed but this session is not elevated"
- **Message:**
  `vacate: -Elevated was passed but this session is not elevated.`
  `vacate never elevates itself; start an elevated shell first.`
- **Why:** You added `-Elevated` to scan, but the terminal window was opened without
  administrator rights. vacate never elevates itself.
- **Fix:**
  1. Press `Win + X` on your keyboard.
  2. Select **Terminal (Admin)** or **PowerShell (Admin)**.
  3. Confirm the User Account Control prompt.
  4. Run your command again with `-Elevated`.

### "vacate refuses to run as root"
- **Message:**
  `vacate: vacate refuses to run as root: root can read other users' data.`
  `Run as your normal user, or pass -AllowRoot if you really mean it.`
- **Why:** On macOS and Linux, running as root lets vacate see other users' files, which breaks
  the privacy boundary.
- **Fix:**
  1. Close the root terminal or exit `sudo`.
  2. Run vacate as your standard user account: `pwsh ./vacate.ps1 scan`.
  3. If you intentionally want to audit the entire system as root, add `-AllowRoot`.

---

## 2. Scanning and Reports

### macOS: Folders missing from report
- **Symptom:** On macOS, rules for Safari, Mail, Messages, or Time Machine report no traces even
  though you use those apps.
- **Why:** macOS Transparency, Consent, and Control (TCC) blocks access to protected user data
  unless the terminal application has Full Disk Access.
- **Fix:**
  1. Open **System Settings** > **Privacy & Security** > **Full Disk Access**.
  2. Click the lock or authenticate to allow changes.
  3. Enable the switch next to **Terminal** (or **iTerm** / your terminal application).
  4. Restart your terminal application and re-run `pwsh ./vacate.ps1 scan`.

### "the scan did not finish (time budget)"
- **Message:** `WARNING: the scan did not finish (time budget). The report is incomplete.`
- **Why:** Your computer has many files, and the scan hit the default 120-second time limit.
- **Fix:**
  1. Run the scan again with a longer budget:
     `powershell -ExecutionPolicy Bypass -File .\vacate.ps1 scan -BudgetSeconds 300`

### Missing -Run parameter
- **Message:** `<command> needs -Run <dir>.`
  (for report, checklist, plan, clean, undo, or erase)
- **Why:** These commands process an existing scan folder and require `-Run` pointing to
  that folder.
- **Fix:**
  1. Find your scan folder under `runs/` (for example, `runs/20261120-101500`).
  2. Pass the folder path to the command:
     `powershell -ExecutionPolicy Bypass -File .\vacate.ps1 plan -Run .\runs\20261120-101500`

### Missing or invalid run folder
- **Message:**
  `vacate: No report.json in <dir>`
  or `vacate: No report.json in <dir>. Run scan and plan first.`
- **Why:** The folder specified with `-Run` does not exist or does not contain `report.json`.
- **Fix:**
  1. Verify the folder path exists under `runs/`.
  2. If you have not scanned yet, run `vacate.ps1 scan` first.
  3. Check for typos in the path.

---

## 3. Clean and Undo Refusals

### Elevated session refused for clean or undo
- **Message:**
  `vacate: Run clean and undo as your normal user, not as administrator or root:`
  `elevated rights reach other users' data.`
- **Why:** `clean` and `undo` are strictly scoped to your own user profile. Running as
  administrator could accidentally alter files belonging to other accounts.
- **Fix:**
  1. Close the administrator terminal.
  2. Open a standard, non-elevated user terminal.
  3. Re-run the `clean` or `undo` command.

### Machine name mismatch
- **Message:**
  `vacate: This run was made on machine '<machine>', not on this machine (<current>).`
  `Clean only runs on the machine it scanned.`
  or `-Execute needs -Confirm with this machine's name (<current>). Nothing was moved.`
- **Why:** To protect against accidentally deleting files on the wrong computer, vacate
  verifies that the run was created on the current computer, and requires typing the machine name.
- **Fix:**
  1. Ensure you are running on the same computer that performed the scan.
  2. Add `-Confirm <current>` using the exact machine name shown in the error message.

### Redacted run cannot be cleaned
- **Message:**
  `vacate: This run is redacted (paths are hashes). Scan again without -Redact to clean.`
- **Why:** Scans run with `-Redact` replace file paths with irreversible hashes. vacate cannot
  move files if it does not have their real paths.
- **Fix:**
  1. Run a fresh scan without `-Redact`:
     `powershell -ExecutionPolicy Bypass -File .\vacate.ps1 scan`
  2. Generate a new plan:
     `powershell -ExecutionPolicy Bypass -File .\vacate.ps1 plan -Run .\runs\<new-folder>`
  3. Run `clean` using the new unredacted run folder.

### Missing undo.json
- **Message:** `vacate: No undo.json in <dir>; nothing was moved from this run.`
- **Why:** You ran `undo` on a run folder where no files were ever moved by `clean -Execute`.
- **Fix:**
  1. Check `clean-preview.md` in the run folder to see whether `clean -Execute` was ever run.
  2. If files were moved in a different run, pass that run's folder to `undo -Run`.

### Clean eligibility refusal codes
When running `clean`, some plan steps cannot be moved automatically. `clean-preview.md` lists the
eligibility code for each step:

1. **`rule-missing`**
   - *Reason:* The rule for this step is not in this version's catalog.
   - *Fix:* Re-run `scan` and `plan` with the current version, or delete the items by hand.
2. **`not-remove-action`**
   - *Reason:* The rule's cleanup action is not 'remove' (e.g. export or sign-out).
   - *Fix:* Follow the manual instructions in `plan.html`.
3. **`wallet`**
   - *Reason:* Crypto wallet data is never moved automatically.
   - *Fix:* Ensure you have your recovery seed phrase safely written down, then remove by hand.
4. **`personal-folder`**
   - *Reason:* Personal folders (Documents, Desktop, Downloads) are never moved automatically.
   - *Fix:* Copy the files you want to keep to an external drive, then remove them yourself.
5. **`review`**
   - *Reason:* The plan marked this step for manual review.
   - *Fix:* Inspect the items and decide yourself whether to delete them.
6. **`kind-not-path`**
   - *Reason:* The location is a registry key, system query, or installed app, not a file.
   - *Fix:* Follow the plan step by hand (e.g. uninstall the program from Settings).
7. **`root-not-user`**
   - *Reason:* The location is outside your user profile (e.g. ProgramData or /etc).
   - *Fix:* Follow the plan step by hand; vacate never touches files outside your user folder.
8. **`not-exact-target`**
   - *Reason:* The rule matched a whole directory instead of specific files.
   - *Fix:* Remove the individual items by hand to avoid deleting the entire folder.
9. **`manual-only`**
   - *Reason:* The location holds credentials or shared system caches.
   - *Fix:* Follow the instructions in the plan to clear or remove the data manually.
10. **`requires-elevation`**
    - *Reason:* The rule requires administrator permissions.
    - *Fix:* Follow the plan step by hand using an administrative tool.
11. **`export-not-confirmed`**
    - *Reason:* The step requires exporting data first before removing.
    - *Fix:* Export your data, then pass `-ExportDone <step-number>` when running `clean`.

---

## 4. Erase Refusals and Readiness Blocks

### Readiness check blocks
Before starting an erase, `vacate erase -Run <dir>` performs 14 safety checks. If any blocking
check fails, the erase is refused and details are saved to `erase-readiness.md`:

1. **`elevated`**
   - *Message:*
     `vacate needs an administrator (root) session to start the erase.`
     `Close this window and open one with elevation.`
   - *Fix:* Open PowerShell as Administrator (Win+X > Terminal (Admin)) or run `sudo -E pwsh`.
2. **`same-platform`**
   - *Message:*
     `The report was made on '<shown>', not on this platform.`
     `Scan again on the machine you want to erase.`
   - *Fix:* Run `vacate.ps1 scan` on this machine; do not copy run folders across different OSes.
3. **`same-machine`**
   - *Message:*
     `The report was made on machine '<shown>', not on this one.`
     `Scan again on the machine you want to erase.`
   - *Fix:* Run `vacate.ps1 scan` directly on the computer you are preparing to erase.
4. **`not-redacted`**
   - *Message:* `This report is redacted, so its locations are hashes. Scan again without -Redact.`
   - *Fix:* Re-scan without `-Redact` so disk serial and paths can be verified.
5. **`scan-complete`**
   - *Message:*
     `The scan did not finish, so the report is incomplete.`
     `Scan again with a larger -BudgetSeconds.`
   - *Fix:* Re-scan with `-BudgetSeconds 300` to allow the scanner to finish completely.
6. **`scan-recent`**
   - *Message:* `The scan finished at ..., more than 24 hours ago. Scan again.`
   - *Fix:* Run `vacate.ps1 scan` again so the audit evidence is less than 24 hours old.
7. **`plan-present`**
   - *Message:* `This run has no plan. Make one with "vacate plan -Run <dir>" and read it first.`
   - *Fix:* Run `vacate.ps1 plan -Run <dir>` and review the generated `plan.html`.
8. **`disk-identified`**
   - *Message:*
     `vacate could not read the system disk model or serial.`
     `It will not erase a disk it cannot name.`
   - *Fix:* Ensure disk information is queryable (run elevated; verify CIM/lsblk/diskutil works).
9. **`disk-complete`**
   - *Message:*
     `vacate could not fully read the system disk: .... It will not erase on partial information.`
   - *Fix:* Check `erase-readiness.md` for specific disk query errors and resolve them.
10. **`not-virtualized`**
    - *Message:*
      `This is a virtual machine, WSL or container.`
      `Erasing here would not erase the real computer, so vacate refuses.`
    - *Why:* Erasing a virtual machine only resets the guest disk image, leaving all real
      personal data intact on the physical host machine.
    - *Fix:* Run vacate on the physical host operating system, not inside a VM or WSL.
11. **`disk-encrypted`**
    - *Message:*
      `System disk encryption is '<kind>'. vacate only starts a cryptographic erase,`
      `so turn on BitLocker, FileVault or LUKS first.`
    - *Fix:* Turn on BitLocker (Windows), FileVault (macOS), or LUKS (Linux) and let encryption
      complete before attempting an erase.
12. **`protection-on`**
    - *Message:*
      `Encryption protection is not on, so the keys may not be the only copy of the data.`
      `Turn protection on and let it finish before erasing.`
    - *Fix:* Resume or enable BitLocker/FileVault protection and confirm encryption is active.
13. **`wallets`**
    - *Message:*
      `The scan found <n> wallet location(s). Confirm you have every recovery phrase`
      `or backup off this machine, then repeat with -WalletsBackedUp.`
    - *Fix:* Save all cryptocurrency recovery seed phrases off the computer, then add
      `-WalletsBackedUp` to the erase command.
14. **`cloud-sync`, `account-sign-out`, `power` (Warnings)**
    - *Why:* These warnings do not block the erase, but remind you to keep mains power plugged in,
      sign out of Apple/Microsoft accounts, and verify files stored in cloud sync.

### -RecordTo volume refusal
- **Message:*
  `vacate: -RecordTo is on the disk being erased; the record would be erased too.`
  `Use a USB drive. Nothing was erased.`
  or `-RecordTo must be an existing folder on a USB drive or other disk, to keep the`
  `erase record. Nothing was erased.`
- **Why:** The erase procedure destroys everything on the system drive. The erase certificate
  must be saved to an external drive so you have proof after the computer restarts.
- **Fix:**
  1. Insert a USB flash drive.
  2. Point `-RecordTo` to a folder on that USB drive (e.g. `-RecordTo E:\` on Windows or
     `-RecordTo /Volumes/MyUSB` on macOS).

### Typed confirmation required
- **Message:**
  `erase -Execute needs a person at an interactive console; input or output is redirected.`
  `Nothing was erased.`
  or `vacate: The final confirmation was not YES. Nothing was erased.`
- **Why:** Erasing a computer is permanent and destroys all data. It cannot be automated via
  scripts or background jobs; a person must interactively type `YES`.
- **Fix:**
  1. Open an interactive terminal window.
  2. Do not pipe input (`|`) or redirect output (`>`).
  3. When prompted `Type YES to continue`, type uppercase `YES` and press Enter.

### System disk serial mismatch
- **Message:**
  `vacate: -DiskSerial does not match the system disk serial (<serial>). Nothing was erased.`
- **Why:** You must provide the exact serial number of the disk to confirm you are targeting
  the intended drive.
- **Fix:**
  1. Check `erase-readiness.md` in the run folder for the exact disk serial string.
  2. Provide `-DiskSerial "<serial>"` exactly as displayed.
