# Handing over your computer with vacate

This guide is for anyone about to sell, return, recycle or give away a computer. You do not need
to be a developer.

## 1. What vacate is

vacate looks through your computer for the personal data and accounts you leave behind: browser
logins, chat sessions, saved Wi-Fi passwords, crypto wallets, cloud folders and more. It writes a
report of what it found and a step-by-step plan for cleaning it up. vacate only reads. It never
deletes, moves or changes anything, never opens the contents of your files, and never uses the
internet.

## 2. Before you start

- Allow about an hour for the whole process, longer if you have a lot of files to copy.
- Have a USB drive or another computer ready for files you want to keep.
- Know the passwords for your main accounts (email, Apple, Google, Microsoft). You will sign out
  of things and may need to sign in again on your new device.
- If you own any crypto wallet, find its recovery phrase (the 12 or 24 words) now. Without it,
  removing the wallet can lose the money for good.

## 3. Get PowerShell and vacate

vacate is a PowerShell script.

**Windows.** PowerShell is already installed. Download vacate from
https://github.com/Its-amanjha/Vacate (green Code button > Download ZIP) and unzip it, for example
to `C:\vacate`.

**macOS.** Install PowerShell from Microsoft's page "Installing PowerShell on macOS", then
download and unzip vacate, for example to your home folder as `~/vacate`.

**Linux.** Install PowerShell from Microsoft's page "Installing PowerShell on Linux" (on Ubuntu,
`sudo snap install powershell --classic`), then download and unzip vacate to `~/vacate`.

## 4. Step 1: scan

Open a terminal (Windows: PowerShell; macOS and Linux: Terminal) and run:

**Windows**
```powershell
cd C:\vacate
powershell -ExecutionPolicy Bypass -File .\vacate.ps1 scan
```

**macOS and Linux**
```bash
cd ~/vacate
pwsh ./vacate.ps1 scan
```

The scan takes about half a minute. It prints a line like
`Report: ...\runs\20261120-101500\report.html`.
That `runs\<date-time>` folder holds everything from this scan:

| File | What it is |
|---|---|
| `report.html` | The report. Open it in your browser. |
| `checklist.md` | A short ordered list of what to do. |
| `summary.md` | A one-page summary. |
| `report.json` | The same data for other programs. |
| `scan.log` | Technical notes about the scan. |

The report shows where your private data is. Treat it like a password and do not share it.

On Windows, some locations (saved Wi-Fi, BitLocker) need administrator rights. To include them,
press Win + X, choose Terminal (Admin), and add `-Elevated` to the scan command.

## 5. Step 2: make a plan

Run this with the folder the scan printed:

**Windows**
```powershell
powershell -ExecutionPolicy Bypass -File .\vacate.ps1 plan -Run .\runs\20261120-101500
```

**macOS and Linux**
```bash
pwsh ./vacate.ps1 plan -Run ./runs/20261120-101500
```

It writes `plan.html`, `plan.md` and `plan.json` into the same folder. Open `plan.html`.

How to read the plan:

- **Before you start** lists the apps to close and any warning about wallets.
- Steps are grouped in stages, in the order you should do them: save what you want to keep, sign
  out and de-link accounts, uninstall apps, remove leftover data, decide yourself, and finally
  items that need no action.
- **Save first** tells you what to export before anything is removed.
- **Sign out** tells you where to sign out, so your account stops trusting this computer.
- **Risk** says what you lose if you follow the step.
- **Found at** shows exactly where vacate found the data.
- **Source** is the app maker's own help page for that step.

## 6. Step 3: follow the plan, top to bottom

vacate does not do any of the steps for you. Work through them in order:

1. Save and export first: passwords, bookmarks, photos, mail, wallet backups.
2. Then sign out. Removing an app first can remove the session you need to sign out of, and the
   account would still trust this computer.
3. Then uninstall apps and remove leftover data.

If a menu in a step has moved in a newer version of an app, follow the goal of the step and the
help page in **Source**.

### Optional: let vacate move the simple items

For a few "Remove leftover data" steps (caches, history files and similar, inside your own user
folder), vacate can move the items to the Recycle Bin or Trash for you. First see what it would do;
this moves nothing:

```powershell
powershell -ExecutionPolicy Bypass -File .\vacate.ps1 clean -Run .\runs\20261120-101500
```

Open `clean-preview.md` in the run folder. It lists what could be moved and why everything else is
left to you. To move the items of, say, steps 12 and 14, close the apps the plan names, then type
the step numbers and your computer's name:

```powershell
powershell -ExecutionPolicy Bypass -File .\vacate.ps1 clean -Run .\runs\20261120-101500 -Steps 12,14 -Execute -Confirm MY-PC
```

vacate checks every item again right before moving it, never deletes anything permanently, and
records each move. To put everything back:

```powershell
powershell -ExecutionPolicy Bypass -File .\vacate.ps1 undo -Run .\runs\20261120-101500 -Execute -Confirm MY-PC
```

Items in the Recycle Bin or Trash can still be restored by anyone using your account, so empty it
(or use the full reset in Step 5) before you hand the computer over.

## 7. Step 4: scan again

Run the scan from Step 1 again. The new report shows what is still left. Repeat Steps 2 and 3
for anything you missed.

## 8. Step 5: the full reset

Some things only go away when the whole system is erased: saved Wi-Fi keys, system logs, deleted
files that could still be recovered. If you are giving the whole computer away, finish with the
operating system's own reset. The last section of your plan shows the steps:

- **Windows:** Settings > System > Recovery > Reset this PC > Remove everything, with Clean data
  turned on.
- **macOS:** turn off Find My Mac, then System Settings > General > Transfer or Reset > Erase All
  Content and Settings.
- **Linux:** reinstall the system and choose to erase the whole disk.

vacate never does this itself. Erasing a disk cannot be undone, so it stays with the tool the
operating system provides.

## 9. Sharing a report safely

If you want someone to help you read a report, scan with `-Redact`:

```powershell
powershell -ExecutionPolicy Bypass -File .\vacate.ps1 scan -Redact
```

Names and folder names in that report are replaced with codes, so it can be shared. A plan made
from a redacted report is redacted too.

## 10. What vacate cannot do

- It only knows the places listed in its rules. A short report does not mean the computer is clean.
- It does not open files, so it cannot tell whether a folder is empty of anything important.
- It cannot see data that already left the computer: cloud copies, backups, email, chat servers.
- It cannot check that you followed a step or that an export worked.
- On macOS, privacy protection can hide some folders unless your terminal has Full Disk Access.

The full list is in [LIMITS.md](../LIMITS.md).

## 11. Legal

Use vacate only on a computer you own or are authorised to hand over. It is not for destroying
evidence, defeating a legal hold or falsifying records.
