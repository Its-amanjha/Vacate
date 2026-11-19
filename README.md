# vacate

vacate is a read-only audit tool for a computer you are about to sell, return, recycle, or give
away. It looks in the known places where Windows, macOS and Linux keep personal data - browser
profile folders, saved Wi-Fi networks, chat and mail apps, cloud-sync folders, crypto wallets,
SSH keys and cloud tokens, and lists of recently used files - then writes a report and an ordered
checklist of what to sign out of and remove. It never deletes, moves, or changes anything.

> **Warning: the report is as sensitive as the data it describes.**
>
> `report.json` and `report.html` list where your private data lives, including file and folder
> names. Treat them like a password. Do not email them, upload them, or paste them into a chat.
> To share a report, run `scan -Redact` and share that copy instead. Delete the `runs` folder when
> you no longer need it.

A trace in the report means "this known location exists on this machine". It does not mean the
file is full, current, or still signed in, because vacate cannot see inside it. A short or empty
report is not proof that the computer is clean. Read [LIMITS.md](LIMITS.md) before you rely on a
result.

## Status

Phase 1 is still being built. Today only `vacate.ps1 version` works. `scan`, `rules`, `report`
and `checklist` are **(planned)** and do not run yet. The rule catalog is still being filled in;
the Linux pack is (planned). Tests run on Windows 11 with PowerShell 5.1 and 7, and on Ubuntu
24.04 in WSL with PowerShell 7. macOS is **not yet verified on a real Mac**.

Do not use this for a real handover until the quickstart below works end to end.

## Quickstart (planned)

Run it as your normal user. Do not open an administrator or root shell: vacate will not ask for
admin rights, and it never elevates itself.

**Windows, PowerShell 5.1**

```powershell
cd C:\path\to\vacate
.\vacate.ps1 scan
```

Open `runs/<timestamp>/report.html` in your browser.

**Windows, PowerShell 7**

```powershell
cd C:\path\to\vacate
pwsh ./vacate.ps1 scan
```

Open `runs/<timestamp>/report.html` in your browser.

**Linux**

```bash
cd ~/vacate
pwsh ./vacate.ps1 scan
```

Open `runs/<timestamp>/report.html` in your browser.

**macOS** - not yet verified on a real Mac

```bash
cd ~/vacate
pwsh ./vacate.ps1 scan
```

Open `runs/<timestamp>/report.html` in your browser.

`<timestamp>` is the name of the run folder, for example `runs/20261119-143000`. If Windows
blocks the script with an execution-policy message, run
`powershell -NoProfile -ExecutionPolicy Bypass -File .\vacate.ps1 scan` instead.

## What it does

- Checks the known locations where personal data is kept: browser history, cookies and
  saved-login files, Wi-Fi profiles, messaging and mail apps, cloud-sync folders, crypto wallets,
  key and token files, personal folders, and recent-activity lists.
- Reads names, sizes, counts and timestamps only. It never opens a file.
- Writes a report, a short summary and a de-link checklist into `runs/<timestamp>/`.
- Marks each rule as verified on a real machine or not, lists what was skipped and why, and
  prints what it cannot see in plain words.
- Makes a shareable copy with `-Redact`: names and path segments become hashes, while counts,
  sizes, times and rule ids stay.

## What it never does

- Deletes, moves, renames or overwrites your files.
- Changes settings, the registry, plists, services, startup items or scheduled tasks.
- Opens or reads the contents of a file. It does not parse databases, keychains, archives or
  documents.
- Uses the network. No uploads, no telemetry, no accounts, no update check.
- Runs as administrator or root by default, and never elevates itself or asks for a password.
- Erases, resets or cleans the disk. Phase 1 is an audit only; the checklist points to the
  operating system's own erase steps.

## Commands (planned)

On Windows use `.\vacate.ps1 <command>`. On macOS and Linux use `pwsh ./vacate.ps1 <command>`.

| Command | What it does |
|---|---|
| `scan` | Detects the platform, runs that platform's rules, and writes a run folder. |
| `scan -Redact` | Same scan, but names and path segments in the report are hashed. |
| `scan -BudgetSeconds n` | Whole-scan time limit in seconds. Default 120. On timeout the report is marked incomplete. |
| `scan -Elevated` | Says the session is already elevated. vacate never elevates itself. |
| `scan -AllowRoot` | On macOS and Linux, allows a root session. Without it, vacate refuses to run as root. |
| `rules list` | Lists rule ids and titles. |
| `rules show <id>` | Shows one rule: location, why it matters, source, verified status. |
| `rules validate` | Checks every rule file. Exits 1 if any file is invalid. |
| `report -Run <dir>` | Rebuilds `report.html` and `summary.md` from an existing `report.json`. |
| `checklist -Run <dir>` | Rebuilds `checklist.md` from an existing `report.json`. |
| `version` | Prints the version. This is the only command that works today. |

## Output files (planned)

Each scan writes one folder, `runs/<timestamp>/`:

| File | What it is |
|---|---|
| `report.json` | Everything the scan found, in machine-readable form. The most sensitive file. |
| `report.html` | One self-contained page. No JavaScript, no external files, prints cleanly. |
| `summary.md` | A short summary for a handover note. No file paths, but it does name the machine and the user. |
| `checklist.md` | The de-link checklist on its own. |
| `scan.log` | What ran, what was skipped, and any errors. Can contain names and paths, so treat it as sensitive. |

Read the HTML report in this order: Summary, By category, Details, De-link checklist, What this
does not see. The last section is the one that tells you what the scan missed.

## More documentation

- [LIMITS.md](LIMITS.md) - every blind spot, per platform, in plain words.
- [THREAT-MODEL.md](THREAT-MODEL.md) - what could go wrong and what the tool does about it.
- [RULES.md](RULES.md) - the rule catalog, generated from the rule files.
- [DECISIONS.md](DECISIONS.md) - design choices and the reason for each one.
- [docs/SPEC.md](docs/SPEC.md) - the full Phase 1 specification.

## Legal and ethical scope

vacate is for devices you own or are authorised to hand over or erase. Do not use it to destroy
evidence, defeat a legal hold, or falsify records. vacate is not a secure-erase tool and does not
certify that a device is clean.
