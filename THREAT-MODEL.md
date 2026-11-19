# Threat model

This page describes what can go wrong with vacate, what the tool does about it, and what is left
for you to handle. It covers Phase 1: a read-only audit that writes a report and a checklist.

The people and things this model considers:

- the next owner of the machine, who gets the disk and anything left on it;
- anyone who receives a report you shared;
- a mistaken or malicious rule file, or a tampered copy of the tool;
- your own mistake: running it with more access than you meant to, or trusting a clean report.

Two kinds of attacker are outside this model. A compromised operating system can lie to any
program running on it, including this one. A person with physical access to the disk can bypass
the tool entirely.

## Status

The scan engine, providers and CLI are still being built. Built and tested today: the rule
loader, the path jail, platform detection, report rendering, the checklist generator and report
redaction. Everything that would actually run a scan is (planned). Where a control exists as a
tested component but is not yet wired into a scan, this page says so. `(planned)` marks
behaviour that no code performs yet.

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
report instead of being presented as certain.

**What remains.** vacate cannot tell whether an app is used, a file is empty, or a session is
still live; that judgement belongs to the reader. A rule verified on one OS version can drift on
another, and `verifiedOn` names the version but never expires. The false-positive rate is not
measured yet. A badly written but valid rule can still produce noise inside the allowed roots.
The scan engine that would create these traces is (planned).

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
locations are outside the scan, as listed in [LIMITS.md](LIMITS.md). Budget exhaustion and
per-rule timeouts will cut a scan short; the report says so, but the missing part stays missing.
The catalog is still being filled in: the Linux pack is (planned), and no rule is presented as
verified until someone has seen its path on a real machine. The engine that records skips and
incomplete scans is (planned).

## Report leakage

**Risk.** `report.json`, `report.html`, `summary.md`, `checklist.md` and `scan.log` are a map of
where the valuables are. They can contain the machine name, the user name, exact paths, file
names, sizes, timestamps and installed programs. Sending an unredacted report to a buyer, a
repair shop or a chat group hands over that map.

**What vacate does.** The HTML header prints a sensitivity warning whenever the report is not
redacted, and [README.md](README.md) prints the same warning. `-Redact` is built (`Redaction.ps1`)
and tested: names, user and host names, volume names, path segments, samples and string properties
become `h-` plus 10 hex characters from HMAC-SHA256 under a fresh random key per call. The key is
never stored, so hashes cannot be reversed or matched across two reports. Drive letters, registry
hives, WMI namespaces, rule ids, counts, sizes and times are kept, so the report stays readable.
Free text is scrubbed for paths first and then for known names; a real leak found by a test (a
drive letter replaced before the path detector ran) is fixed (D25). The report contains no
network references, and the tool makes no network calls.

**What remains.** An unredacted report is plain text. Anyone who can read the `runs` folder, or a
backup or sync copy of it, can read everything. Redaction is not encryption: sizes, times,
structure and drive letters remain, and someone who knows the machine may still infer things.
Hashes are stable within one report, so repeated names stand out, and a 40-bit hash can collide
in theory. How `scan.log` is handled under `-Redact` is not defined yet (planned). A report you
have already shared cannot be recalled. The report has no password protection.

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
fuzzing yet. The scan engine that calls the jail is (planned), so the jail's checks are tested in
isolation but not yet proven in a real scan. Path handling is tested for the forms listed above;
other platform quirks are not covered. A rule that is valid but points at a harmless allowed
folder is a false positive, not an escape.

## Symlink and junction escapes

**Risk.** A symlink or junction inside a scanned folder points at another user's profile, another
volume or the whole disk. Following it escapes the path jail. A cloud placeholder can also make
the tool download a file, which would both use the network and change the disk.

**What vacate does.** Every resolved target is checked for the reparse-point attribute at every
level, and a link is rejected with reason `link`; it is never followed (`PathJail.ps1`). The real
junction and symlink tests pass. The walker contract refuses to descend into a reparse point,
counts it in `SkippedLinks`, and treats cloud placeholders by metadata only, never opening them
(`docs/CONTRACTS.md`). macOS path normalization treats `/var` and `/private/var` as the same place.

**What remains.** The filesystem provider and walker are not in this tree yet (planned, W1-B), so
the walker half of this control is unproven. There is a time-of-check to time-of-use gap: a link
can be created or swapped between the jail check and the read; the audit is local and short, but
the tool does not lock the tree. Placeholder detection is attribute-based, and cloud clients do
not all mark files the same way. A hard link looks like an ordinary file to metadata, so vacate
could report the name and size of a file whose data lives at another path; it still does not read
the contents.

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
cannot say what is behind it. The engine that produces the skips is (planned). A partial walk that
stops inside an unreadable subfolder is a contract detail for the walker (planned, W1-B). Some
platform APIs may return an empty result without raising access denied; that case is not audited.
There is no retry and no way to grant the missing permission from inside the tool.

## Elevation and root

**Risk.** An administrator or root scan can read more than the person expects, and root on Linux
or macOS can read other users' data. That breaks the least-privilege promise and can put other
people's data into a report made for one person.

**What vacate does.** It never elevates itself, never calls `sudo`, and never prompts for
credentials (CLAUDE.md rule 7, SPEC non-negotiable 9). Elevation is detected once. A rule that
needs it is skipped and listed when the session is not elevated. On macOS and Linux, a root
session is refused unless `-AllowRoot` is passed (planned CLI). `-Elevated` only asserts that the
session is already elevated; it does not change it (planned CLI). Root detection uses the effective
user name without an external `id` binary (D13). Independently of elevation, the path jail refuses
the contents of other user profiles, so elevation does not unlock them. The report header records
whether the scan was elevated.

**What remains.** `-AllowRoot` exists for a reason: a person who owns the machine may need it to
see root-only files. Passing it widens the scan, and the report does not warn more loudly than the
header field. Windows administrators often work from an elevated shell without thinking about it;
the tool cannot stop that. A refusal is policy, not a security boundary: the person running the
tool owns the machine and can change the environment. The CLI that enforces the refusal is
(planned).

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
defined for every declared platform. `maxEntries` is capped by the loader, and the engine is
designed to give every rule a deadline. At scan time the path jail checks the path again (D14).

**What remains.** A well-formed rule inside an allowed root can still produce false positives or a
slow, capped scan; it cannot execute code. Rule files are not signed (Phase 5 packaging is
planned). If an attacker can edit rule files, they can usually edit the PowerShell as well, so the
real control is repository review and file permissions. Schema validation runs under PowerShell 7
only (D4); Windows PowerShell 5.1 relies on the loader's own structural checks. `rules validate`
is meant to be the CI gate, and its CLI command is (planned).

## Output written inside scanned roots

**Risk.** Writing the report inside the tree being scanned changes what is being audited, puts the
report into the next scan, and can copy the report into a backup or cloud sync. A scan that writes
where it reads also weakens the "writes nothing" promise.

**What vacate does.** The design has one write target: `runs/<timestamp>/`, which must sit outside
every scanned root (SPEC non-negotiable 1). The engine context carries an `Exclude` list of
absolute paths that are never scanned: the tool folder, `runs/`, and the output folder
(`docs/CONTRACTS.md` section 9). Report files are specified as UTF-8 without a BOM. `report -Run`
and `checklist -Run` (planned) read an existing run folder and rewrite only its reports.

**What remains.** The engine and CLI that write the run folder are (planned), so no code enforces
this yet. If the tool is unpacked inside the user's home folder or inside the repository, the
output folder is inside a scanned root unless the exclusion works and is tested. Exclusion depends
on absolute path comparison and the platform's case rules. A user can point `-Run <dir>` at a
folder inside a scanned root. The write-spy test from the specification is (planned). A crash
during a write can leave a partial report, but only inside `runs/`.

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
Engine determinism is (planned): the sort and key-order rules exist on paper and in the renderers,
but the scan that produces traces is not built. There is no proof that a report came from a
particular machine. Report signing and reproducible builds are Phase 5 (planned).

## Outside this model

- A compromised operating system, kernel, PowerShell or .NET runtime can hide files, fake
  metadata or change the report after it is written.
- Physical access, firmware implants, hardware keyloggers and drive-level attacks are not
  addressed.
- A person who can edit the tool's own code or rule files can change what it does; repository
  review and file permissions are the control, not the tool.
- Data that has already left the machine (cloud copies, backups, email, chat) is outside the scan.
- Phase 1 does not erase anything. A report and a checklist are not a certificate of erasure.
