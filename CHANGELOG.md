# Changelog

All notable changes to vacate are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-11-24

First public release. vacate runs on Windows (Windows PowerShell 5.1 or PowerShell 7), and on
macOS and Linux (PowerShell 7).

### Scan (Phase 1)

- Finds the known places where personal data is kept: browser profiles, saved logins, cookies and
  history, chat and mail apps, saved Wi-Fi networks, crypto wallets, SSH keys, cloud tokens,
  cloud-sync folders, recent-files lists and shell history.
- Reads names, sizes, counts and timestamps only. It never opens a file, never changes anything,
  and never uses the network.
- Writes `runs/<timestamp>/` with `report.html`, `report.json`, `summary.md`, `checklist.md` and
  `scan.log`. The HTML report is one self-contained page with no JavaScript or external files.
- `scan -Redact` replaces names and path segments with hashes so a report can be shared;
  `scan -BudgetSeconds <n>` caps the whole scan (120 seconds by default) and marks the report
  incomplete when the budget runs out.
- `scan -Elevated` includes administrator-only locations on Windows, and `scan -AllowRoot` permits
  a root session on macOS and Linux, which vacate refuses by default.
- `rules list`, `rules show <id>` and `rules validate` inspect the catalog; `report -Run <dir>` and
  `checklist -Run <dir>` rebuild output from an existing `report.json`.
- Marks each rule as verified on a real machine or not, and lists skipped and failed rules with
  the reason, so a partial result is visible instead of silent.

### Plan (Phase 2)

- `plan -Run <dir>` writes `plan.html`, `plan.md` and `plan.json`, with one step for every trace
  the scan found.
- Steps are ordered: save and export first, then sign out and de-link accounts, then uninstall
  apps, then remove leftover data, then items to decide yourself.
- Each step names the risk, the exact locations found, and the app maker's own help page.
- The plan is advice only. vacate does not check that a step was followed or that an export
  worked, and vacate still changes nothing.

### Clean and undo (Phase 3)

- `clean -Run <dir>` is a dry run that lists which plan items vacate could move to the Recycle Bin
  or Trash, and why every other item is left to you.
- `clean -Run <dir> -Steps 3,5 -Execute -Confirm <MACHINENAME>` moves only `remove` steps for a
  single file or folder inside your own profile. It never deletes permanently, re-checks every
  item before moving it, re-scans afterwards, and records each move in `undo.json`.
- `-ExportDone <step>` lets a step that says "Save first" proceed only after you confirm the
  export.
- `undo -Run <dir>` puts back everything it can and names anything it cannot restore. It never
  overwrites a newer file at the old path.
- `clean` and `undo` refuse a report from another machine or platform, a redacted report, and an
  administrator or root session.

### Erase (Phase 4)

- `erase -Run <dir>` is a readiness check: 16 checks, 12 of which can block, covering an
  administrator session, a clean scan less than a day old, an encrypted and identified system
  disk, wallets backed up, and a refusal to run in a virtual machine, WSL or a container. It
  erases nothing.
- `erase ... -Execute -Confirm <MACHINENAME> -DiskSerial <serial> -RecordTo <usb folder>` asks you
  to type YES and writes an erase record to the run folder and the USB drive, then opens the
  operating system's own erase: Reset this PC on Windows, Erase All Content and Settings on macOS,
  or `cryptsetup luksErase` on Linux.
- Only encrypted system disks qualify. An unencrypted disk is refused; an internal Apple SSD
  counts as encrypted because Apple silicon and T2 Macs encrypt it in hardware.
- On Linux, only a system disk whose root sits on a single LUKS device is supported.

### Compare

- `compare -Run <newer> -Against <older>` shows what is gone, still there or new between two scans of
  the same computer, so you can check that a cleanup worked. It only reads the two reports and writes
  `compare.md` and `compare.json` into the newer run folder. Rules that did not run in both scans are
  listed as not comparable, never as gone.

### Releases (Phase 5)

- Published on the GitHub Releases page as `vacate-<version>.zip`, built by GitHub Actions from
  the tagged commit, with `SHA256SUMS` beside it.
- The build is reproducible: the same commit gives the same ZIP, and the archive holds
  `MANIFEST.sha256`, with a hash for each file it ships.
- GitHub's build-provenance attestation records which repository, commit and workflow produced
  the ZIP. The scripts are not code-signed, so the checksums and the attestation are how you
  confirm the download; see `docs/VERIFY.md`.
- `vacate.cmd` starts `vacate.ps1` with `-ExecutionPolicy Bypass` for that one process only, so on
  Windows you can run `vacate scan` from the unzipped folder without changing the system policy.

### Rules

- 284 rules: 113 for Windows, 82 for macOS and 89 for Linux.
- Categories include browsers, messaging, mail, cloud sync, developer secrets, file transfer,
  remote access, crypto wallets, system history and games.
- Rules marked `verified: true` were confirmed by a scan on a real machine or on the GitHub
  Actions macOS runner; the rest still run and are listed as unverified in every report.

### Known limits

- Erase has never been run on a real Windows or macOS disk. Only its readiness checks, its record
  and the Linux LUKS path (on a loop-file disk in WSL) have been exercised.
- The macOS clean mover has not been run on a real Mac.
- The erase record is unsigned and is written before the erase starts, so it records what vacate
  checked and launched, not that the erase finished.
- On Linux, erase supports only a system disk whose root is on a single LUKS device; LUKS header
  backups and other keyslot copies are out of scope.
- Many rules are still unverified. They run, but their locations have not been confirmed on a
  real machine.
- A clean report means only that nothing was found in the locations vacate has rules for. It is
  not proof that the computer is clean. `LIMITS.md` lists every blind spot.
