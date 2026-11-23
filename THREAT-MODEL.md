# Threat model

This page describes what can go wrong with vacate, what the tool does about it, and what is left
for you to handle. It covers Phases 1-4: the read-only audit and plan, `clean` (moves a few items to the Recycle Bin or Trash) and `erase` (opens the operating system's own erase).

The people and things this model considers:

- the next owner of the machine, who gets the disk and anything left on it;
- anyone who receives a report you shared;
- a mistaken or malicious rule file, or a tampered copy of the tool;
- your own mistake: running it with more access than you meant to, or trusting a clean report.

Two kinds of attacker are outside this model. A compromised operating system can lie to any
program running on it, including this one. A person with physical access to the disk can bypass
the tool entirely.

## Status

Phase 1 works end to end on Windows 11 (PowerShell 5.1 and 7) and on Ubuntu 24.04 in WSL
(PowerShell 7). The scan engine, path locator, filesystem walker, providers, CLI, report rendering,
checklist and redaction all run, and real scans wrote all five output files on both systems.

Done since: the sabotage self-test (6 deliberate breakages, all caught), the integration suite (fixture scans, write-spy, run-twice determinism) and the 50,000-file performance test. CI runs on Windows (PowerShell 5.1 and 7), Ubuntu and macOS. Still `(planned)`: verification on a personal Mac (macOS is verified only on the CI runner), report signing and reproducible builds (Phase 5). Where a control exists but is not proven in a scan, this page says so. `(planned)` marks behaviour that no code performs yet.

## False positives

**Risk.** A listed location exists but holds nothing personal: an app was installed and never
used, a folder is empty, a file is stale, or the session was signed out long ago. A report full of
noise wastes time and teaches the reader to ignore it. A wrong path in a rule can also point at a
harmless file and make it look sensitive.

**What vacate does.** Every rule needs a concrete locator and a source; the loader rejects a rule
with an empty locator or a missing source (CLAUDE.md rule 5, `RuleLoader.ps1`). A scan produces one
trace per matched target, so the report shows the exact path that exists (D10). Each trace carries
size, count, last-modified time, the rule id, the rule source and its verified status (D18). The
report prints the fixed line that file contents are never opened, so a trace is a place to look,
not a claim that the file holds anything. Rules not verified on a real machine are listed in the
report instead of being presented as certain. A real scan found one false-positive class: built-in
profile folders (`Public`, `Default`, `Default User`) were reported as other people; the rule now
drops them (D31).

**What remains.** vacate cannot tell whether an app is used, a file is empty, or a session is
still live; that judgement belongs to the reader. A rule verified on one OS version can drift on
another, and `verifiedOn` names the version but never expires (D32). The false-positive rate is not
measured yet. A badly written but valid rule can still produce noise inside the allowed roots.
Scan output exists today, so these risks apply to a report you can read now.

## False negatives

**Risk.** Real personal data is not reported, and the person hands over the machine believing it
is clean. This is the most damaging failure for this tool, because the report is supposed to be
complete about what it can see.

**What vacate does.** Every report carries a mandatory "What this does not see" section built from
`ReportText.ps1`, and the renderers always print it. Unreadable locations are recorded as skips
with a reason and a detail, never as errors or silence (D11). A rule that needs elevation is
skipped and listed when the session is not elevated. The report labels an incomplete scan as
incomplete and marks a trace whose count stopped at the entry cap. Rules that are not verified are
listed by the report. The limitation text says in plain words that only known locations
are checked and that a clean report is not proof.

**What remains.** The catalog is finite: an app with no rule is invisible. File contents are never
read, so vacate cannot tell a full folder from an empty one. Other operating systems, other disks,
encrypted containers, swap, snapshots, TCC-protected folders, root-only files and admin-only
locations are outside the scan, as listed in [LIMITS.md](LIMITS.md). A single rule stops at its
10-second limit, and the whole scan stops at its budget; the report marks the scan incomplete and
lists the rule as skipped, but the missing part stays missing (D2, D27). The catalog is still being
filled in: Windows has the most verified rules, Linux is tested in WSL only, and no macOS rule is
verified. No rule is presented as verified until a real scan has seen its path (D32).

## Report leakage

**Risk.** `report.json`, `report.html`, `summary.md`, `checklist.md` and `scan.log` are a map of
where the valuables are. They can contain the machine name, the user name, exact paths, file
names, sizes, timestamps and installed programs. Sending an unredacted report to a buyer, a
repair shop or a chat group hands over that map.

**What vacate does.** The HTML header prints a sensitivity warning whenever the report is not
redacted, and [README.md](README.md) prints the same warning. `-Redact` is built into `scan`
(`Redaction.ps1`) and tested: names, user and host names, volume names, path segments, samples and
string properties become `h-` plus 10 hex characters from HMAC-SHA256 under a fresh random key per
call. The key is never stored, so hashes cannot be reversed or matched across two reports. Drive
letters, registry hives, WMI namespaces, rule ids, counts, sizes and times are kept, so the report
stays readable. Free text is scrubbed for paths first and then for known names; a real leak found
by a test (a drive letter replaced before the path detector ran) is fixed (D25). Under `-Redact`,
`scan.log` keeps only its first summary line and a note that the details were omitted, so it does
not undo the redaction. The report contains no network references, and the tool makes no network
calls.

**What remains.** An unredacted report is plain text. Anyone who can read the `runs` folder, or a
backup or sync copy of it, can read everything. Redaction is not encryption: sizes, times,
structure and drive letters remain, and someone who knows the machine may still infer things.
Hashes are stable within one report, so repeated names stand out, and a 40-bit hash can collide
in theory. A report you have already shared cannot be recalled. The report has no password
protection.

## Path traversal

**Risk.** A rule path containing `..`, an absolute path, a drive letter or a UNC name could take
the scan outside the allowed roots and into another user's profile, a system folder or another
disk. A crafted rule could use this to turn a privacy audit into a system-wide file listing.

**What vacate does.** Rule paths are checked twice (D14). The loader rejects `..`, absolute paths,
drive letters, UNC paths, backslashes, `**`, illegal characters, an unknown locator kind, an
unknown or undefined root token for a declared platform, and an oversized `maxEntries`. At scan
time `Split-VacateRulePath` throws on the same forms, and `Resolve-VacateRuleTargets` expands one
segment at a time under the resolved root. `Test-VacatePathUnderRoot` normalizes separators and
compares with the platform's case rules, so `C:\Users\ab` is not accepted as being under
`C:\Users\a`. `Test-VacateOtherUserPath` refuses anything deeper than a direct child of the users
root, so other profiles can be named but their contents cannot be listed. `Test-VacateCrossesMount`
refuses a path that crosses a mount point, and the jail tests cover these cases.

**What remains.** Rules are data shipped with the tool, and the loader checks their form, not
their intent. A bug in normalization or glob expansion could still let a path through; there is no
fuzzing yet. The jail now runs in every real scan; it was exercised on Windows 11 and Ubuntu 24.04
(WSL), but path handling is tested for the forms listed above, and other platform quirks are not
covered. A rule that is valid but points at a harmless allowed folder is a false positive, not an
escape.

## Symlink and junction escapes

**Risk.** A symlink or junction inside a scanned folder points at another user's profile, another
volume or the whole disk. Following it escapes the path jail. A cloud placeholder can also make
the tool download a file, which would both use the network and change the disk.

**What vacate does.** Every resolved target is checked for the reparse-point attribute at every
level, and a link is rejected with reason `link`; it is never followed (`PathJail.ps1`). Real
junction and symlink tests pass on Windows and Ubuntu. The walker refuses to descend into a
reparse point, counts it in `SkippedLinks`, and treats cloud placeholders by metadata only, never
opening them. macOS path normalization treats `/var` and `/private/var` as
the same place.

**What remains.** The walker half now runs in real scans, but there is a time-of-check to
time-of-use gap: a link can be created or swapped between the jail check and the read; the audit
is local and short, but the tool does not lock the tree. Placeholder detection is attribute-based,
and cloud clients do not all mark files the same way. A hard link looks like an ordinary file to
metadata, so vacate could report the name and size of a file whose data lives at another path; it
still does not read the contents.

## Permission gaps

**Risk.** A folder the user cannot read is silently missing from the report, which then looks
cleaner than the machine really is. On macOS this includes folders behind privacy controls. On
Linux it includes root-only files. On Windows it includes admin-only locations.

**What vacate does.** Access denied is recorded as a skip with reason `permission`, not as an
error and not as a crash. A rule that needs elevation is recorded as `requires-elevation` when the
session is not elevated. A missing system-query binary is `unavailable`, and a query that runs too
long is `timeout`; the skip reasons are a fixed list in the model. The report has a "Skipped and
failed" section listing every skip with its rule id, reason and detail (D11). The limitation text
names the platform-specific gaps in plain words.

**What remains.** A reader can ignore the skip list. A skip says that something was not read; it
cannot say what is behind it. Skips are produced by the engine today, and the walker records a
denied subfolder and continues with the rest of the tree. Some platform APIs may return an empty
result without raising access denied; that case is not audited. There is no retry and no way to
grant the missing permission from inside the tool.

## Elevation and root

**Risk.** An administrator or root scan can read more than the person expects, and root on Linux
or macOS can read other users' data. That breaks the least-privilege promise and can put other
people's data into a report made for one person.

**What vacate does.** It never elevates itself, never calls `sudo`, and never prompts for
credentials (CLAUDE.md rule 7, SPEC non-negotiable 9). Elevation is detected once. A rule that
needs it is skipped and listed when the session is not elevated. On macOS and Linux, `scan`
refuses a root session unless `-AllowRoot` is passed. `-Elevated` only asserts that the session is
already elevated; `scan` fails if it is not, and neither flag changes the session. Root detection
uses the effective user name without an external `id` binary (D13). Independently of elevation,
the path jail refuses the contents of other user profiles, so elevation does not unlock them. The
report header records whether the scan was elevated.

**What remains.** `-AllowRoot` exists for a reason: a person who owns the machine may need it to
see root-only files. Passing it widens the scan, and the report does not warn more loudly than the
header field. Windows administrators often work from an elevated shell without thinking about it;
the tool cannot stop that. A refusal is policy, not a security boundary: the person running the
tool owns the machine and can change the environment. `scan` enforces the refusal today; it does
not ask for confirmation.

## Malicious rule files

**Risk.** Someone edits or adds a rule to point at a sensitive folder, to flood the report, to
make a scan run for a long time, or to execute code. A pull request from an untrusted source is
the realistic route.

**What vacate does.** Rules are JSON data, and the locator kinds are a fixed list; no rule can
carry a command, a script block or an expression (CLAUDE.md rule 4, SPEC non-negotiable 8). The
only external binaries are the three named system queries in `SystemQueries.ps1`, each with an
absolute path, fixed arguments and no shell. The loader validates each rule against the schema and
its own checks; an invalid file never loads, the rest of the catalog still loads, and the errors
are listed (D15). One rule per file and the file name must equal the id (D7). Root tokens must be
defined for every declared platform. `maxEntries` is capped by the loader, and the engine gives
every rule a 10-second deadline (D2). At scan time the path jail checks the path again (D14).

**What remains.** A well-formed rule inside an allowed root can still produce false positives or a
slow, capped scan; it cannot execute code. Rule files are not signed (Phase 5 packaging is
planned). If an attacker can edit rule files, they can usually edit the PowerShell as well, so the
real control is repository review and file permissions. Schema validation runs under PowerShell 7
only (D4); Windows PowerShell 5.1 relies on the loader's own structural checks. `rules validate`
runs today, and CI runs `tests/Test-RuleFiles.ps1` for each platform (`.github/workflows/ci.yml`).

## Output written inside scanned roots

**Risk.** Writing the report inside the tree being scanned changes what is being audited, puts the
report into the next scan, and can copy the report into a backup or cloud sync. A scan that writes
where it reads also weakens the "writes nothing" promise.

**What vacate does.** `Output.ps1` is the only writer. It writes one run folder,
`runs/<timestamp>/`, and refuses any path outside it, including a path whose parent is a link
(D28). The scan context carries an `Exclude` list of absolute paths that are never scanned: the
tool folder and `runs/`, so the tool may live inside a scanned root without auditing its own
files (D28). A static safety test forbids write calls outside
`Output.ps1` and was checked by planting a write in another file (D30). Report files are UTF-8
without a BOM. `report -Run` and `checklist -Run` read an existing run folder and rewrite only
`report.html`, `summary.md` and `checklist.md` inside that folder.

**What remains.** The exclusion depends on absolute path comparison and the platform's case rules;
it is covered by unit tests, not by a full scan that plants a file in the tool folder. A user can
point `-Run <dir>` at any folder, but writes stay inside that folder. The integration suite runs a full
scan with a write-spy and checks the scanned tree is unchanged. A crash during a write can leave a partial
report, but only inside `runs/`.

## HTML injection via file names

**Risk.** A file, folder, user or machine name contains HTML or a script. The report renders it,
the browser runs it when the report is opened, and the script reads the report or sends it
somewhere. The report is a local file, but a browser can still make network requests.

**What vacate does.** Every value taken from the report goes through `ConvertTo-VacateHtmlText`,
which calls `[System.Net.WebUtility]::HtmlEncode`, in every section of the HTML
(`ReportRenderer.ps1`). The test with `<script>` in a filename passes. The page has no JavaScript,
no external stylesheet, no external font, no CDN and no links (D17). It sets
`<meta name="robots" content="noindex">`. The Markdown summary has no file paths, but it does
print the machine name and the user name unless the scan was redacted.

**What remains.** Encoding is applied value by value, so a future renderer change could forget
one; the test suite covers the current fields, not future ones. There is no Content-Security-Policy
meta tag. A browser extension, or a viewer other than a browser, may treat the file differently.
The `class="sev-..."` attribute uses the sensitivity value, which is a fixed enum today; adding a
free-text class name later would need the same care. `scan.log` is plain text and is not HTML.

## Determinism and tampering

**Risk.** Two scans of the same machine disagree, so the reader cannot tell which one is true.
Someone edits `report.json` or `report.html` to hide a trace or add one. A redacted report cannot
be checked against the original. A scan cut short by the budget is mistaken for a complete one.

**What vacate does.** Sorting is ordinal and serialized objects use ordered dictionaries
(CLAUDE.md rule 8, SPEC non-negotiable 10). Traces are sorted by category and then rule id. JSON
dates are normalized when read, so a re-render does not change text (D26). `report -Run` rebuilds
the HTML and Markdown from `report.json` alone (D18). The scan flags `complete`, `truncated` and
the skip reasons, and the summary sentence says when the scan did not finish. `-Redact` uses a
fresh key per call, so two redacted reports cannot be matched by their hashes (D25).

**What remains.** There is no signature, checksum or append-only log. Anyone who can write the run
folder can edit the report; the tool cannot detect it. The redaction key is not stored, so hashes
cannot be re-derived or checked later. Timestamps and durations legitimately differ between runs.
The engine sorts traces and serializes ordered objects, and an integration test runs the same scan
twice and checks the reports match with time fields blanked. There is no proof that a report came from
a particular machine. Report signing and reproducible builds are Phase 5 (planned).

## Cleanup plan advice (Phase 2)

**Threat.** A cleanup plan tells a person to delete something. Wrong advice can lose data that was
never exported, lock someone out of their accounts, or break the operating system.

**Control.** The plan is words only (D47): the rule loader rejects cleanup text that contains a
shell delete command or a backtick, so no step can be pasted into a terminal. Steps are ordered so
saving and signing out come before anything that removes data (D49). Wallet rules start with
confirming the recovery phrase. Guidance never tells a person to hand-delete system-managed data
(system folders, the machine registry hive, the login keychain, DPAPI keys); it points to the app,
the system settings, or the full reset at the end of the plan. Every trace gets a step, so nothing
is dropped silently (D45). `vacate plan` reads `report.json` and writes three files into the run
folder; it does not scan or change anything else.

**What remains.** Menu paths change with app and operating system updates, and the guidance was
written from vendor documentation, not tested step by step on each platform. A person can still
follow a step on the wrong item. The plan cannot see whether an export actually worked.

## Clean and undo (Phase 3)

**Threat.** Phase 3 moves files. A wrong move can lose data that was never exported, reach files
the rule never meant (through an edited plan, a link swapped in at the last second, or an
environment variable pointing at the whole disk), turn into a permanent delete, or run on the
wrong machine.

**Control.** Dry run by default; moving needs the step numbers, `-Execute` and `-Confirm` with the
machine name (D52). Only `remove` steps for one exact file or folder in the user's own profile are
eligible (D51); wallets, personal folders, folder-searching rules and manual-only rules never are.
Every path must be one the rule resolves now, under that rule's root, inside the real home folder,
outside vacate's own folders. Right before each move the path is checked again: canonical,
absolute, no link or junction anywhere on the way. Movers only move into the Recycle Bin or Trash
and never overwrite (D50); the Windows mover refuses drives, settings, sizes and path lengths where
Windows would delete permanently and confirms the bin entry afterwards; the Linux mover refuses
moves across filesystems. Redacted reports, reports from another machine, and administrator or root
sessions are refused. Each move is written to `undo.json` before the next starts (D53); undo
restores newest first and never overwrites.

**What remains.** Windows bin settings cannot be mapped to a single drive without COM, so the check
is stricter than needed. A Linux `.trashinfo` write and a folder restore keep a very small race
window. A file in use may make Windows show an error dialog (the move then fails, nothing is
deleted). The Recycle Bin and Trash are not erasure. The macOS mover has not run on a real Mac.

## Erase (Phase 4)

**Threat.** An erase destroys everything and cannot be undone. It can hit the wrong machine or the
wrong disk, run inside a VM or WSL and erase only a virtual disk while claiming success, destroy
data that was never exported, lose its own record with the disk, or be started by a script.

**Control.** vacate never sends raw commands to a disk; it opens the operating system's own erase
(D54), and the person confirms it there. Readiness blocks unless the session is elevated, the run
is a recent, complete, unredacted scan of this machine with a plan, the system disk is fully
identified and encrypted with protection on, the machine is not a VM, WSL or container, and wallets
are confirmed backed up (D55, D58). Starting needs `-Confirm` with the machine name, `-DiskSerial`
matching the system disk, `-RecordTo` on another volume, and a YES typed at an interactive console.
The erase record is written to both places and verified before the OS tool opens (D56). Only
EraseLauncher.ps1 may start the three tools, with fixed paths and no shell; tests replace the
launcher, and the only real erase in development is a LUKS key erase on a throwaway loop file (D57).

**What remains.** vacate cannot see whether the person completed the erase, and the record is
unsigned and written before it. Microsoft says Reset this PC's erasure does not meet industry
standards. LUKS header backups or extra keyslot copies would still unlock a key-erased disk. Other
disks in the computer are not erased. Activation Lock, Find My and account sign-out stay manual.

## Outside this model

- A compromised operating system, kernel, PowerShell or .NET runtime can hide files, fake
  metadata or change the report after it is written.
- Physical access, firmware implants, hardware keyloggers and drive-level attacks are not
  addressed.
- A person who can edit the tool's own code or rule files can change what it does; repository
  review and file permissions are the control, not the tool.
- Data that has already left the machine (cloud copies, backups, email, chat) is outside the scan.
- Phase 1 does not erase anything. A report and a checklist are not a certificate of erasure.
