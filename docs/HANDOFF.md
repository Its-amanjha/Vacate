# vacate - hand-off report (Phases 1-3)

Phase 1: 2026-11-19 · Phase 2: 2026-11-20 · Phase 3: 2026-11-23 · Repository: https://github.com/Its-amanjha/Vacate ·
Spec: [docs/SPEC.md](SPEC.md) · User guide: [docs/GUIDE.md](GUIDE.md)

Sections 1-7 are the Phase 1 report the spec asks for. Section 8 is Phase 2, section 9 Phase 3.

Phase 1 is a **read-only audit**. vacate scans a Windows, Linux or macOS computer for the personal
data and traces a person leaves behind, and writes a report plus an ordered de-link checklist. It
never deletes, moves or changes anything, never opens file contents, and never uses the network.

## 1. What works per platform

| | Windows 11 | Linux (Ubuntu 24.04) | macOS |
|---|---|---|---|
| `scan` end to end | yes, PowerShell 5.1 and 7 (real PC: 22 s) | yes, PowerShell 7 (WSL: 14 s) | yes, PowerShell 7 (GitHub Actions runner, macOS 26.7.2 arm64) |
| Rules | 87 | 74 | 62 |
| Verified on a real machine | **43** (owner's PC, Windows 11 Pro 26300) | **20** (owner's WSL Ubuntu 24.04) | **24** ci-verified (CI runner only) |
| Not yet verified | 44 | 54 | 38 |
| Root / admin | runs unelevated; admin-only rules skipped with a reason | refuses root unless `-AllowRoot` | refuses root unless `-AllowRoot` |
| System queries | read-only CIM (BitLocker, TPM, OS, volumes) | `lsblk`, `findmnt` | `fdesetup status` |

Commands that work on all three: `scan [-Redact] [-BudgetSeconds n] [-Elevated] [-AllowRoot]`,
`rules list | show <id> | validate`, `report -Run <dir>`, `checklist -Run <dir>`, `version`.
Each scan writes `report.json` (schema-valid), `report.html` (self-contained, no JavaScript,
prints), `summary.md`, `checklist.md` and `scan.log` into `runs/<timestamp>/`.

## 2. What is unverified or CI-only

- **136 of 223 rules are unverified.** They still run; every report lists them by id.
  A rule becomes verified only when a real scan on that platform found its data (D32).
- **macOS is ci-verified only.** The 24 verified macOS rules were confirmed on a clean GitHub
  Actions runner with Full Disk Access. Privacy prompts (TCC) on a personal Mac are untested.
- **Admin-only Windows rules:** an elevated scan (`.\vacate.ps1 scan -Elevated` from an
  Administrator shell) on 2026-11-20 verified encryption.bitlocker.status, encryption.tpm.presence, network.wifi.profiles, system.prefetch.
  `network.wireguard.configs` stays unverified because WireGuard is not installed on that PC.
- **Linux was verified in WSL**, not on a desktop install. Two rules stayed unverified because the
  tools never wrote the file without an interactive session (zsh and fish history).
- **No personal Mac and no real desktop Linux** have been scanned.

## 3. Test summary lines

Run on 2026-11-23 against the code published in this report (Phases 1-3):

```
SUMMARY [Desktop 5.1.26100.9818] passed=610 failed=0 skipped=31
SUMMARY [Core 7.7.0] passed=624 failed=0 skipped=17 (Windows, sabotage baseline)
SUMMARY [Core 7.7.0] passed=602 failed=0 skipped=39 (Ubuntu 24.04, WSL)
LINT issues=0
```

- Last CI run checked by hand: GitHub Actions run `44559222971` on `292ee21` (Phase 1
  code): **completed/success** - test (ubuntu-pwsh)=success, test (windows-pwsh)=success, test (macos-pwsh)=success, test (windows-powershell)=success. Each job also runs a redacted sample scan and,
  since Phase 2, builds a plan from it, and uploads both as an artifact.
- Sabotage self-test (`tools/Invoke-SabotageTest.ps1`): **all 11 mutations caught** (force
  exists, drop a rule, skip the link guard, ignore the budget, disable redaction, let a
  wrong-platform rule run; Phase 2: the plan drops a trace, the cleanup check allows delete
  commands; Phase 3: clean ignores the machine-name confirm, lets wallets through, follows a link). Details in [SABOTAGE.md](SABOTAGE.md).
- Performance (`tests/perf`, opt-in): a 50,000-file synthetic profile scans in 26.7 s on
  PowerShell 5.1, 13.6 s on PowerShell 7 (Windows) and 13.4 s on Ubuntu, well inside the 120 s budget.
- Static safety test: no network calls, no dynamic code, no shell, no writes outside the single
  output writer, no unlisted binaries. A planted `CreateDirectory` + `Invoke-WebRequest` was caught.

## 4. Demo command per OS

**Windows (PowerShell 5.1 or 7)**
```powershell
cd C:\path\to\vacate
.\vacate.ps1 scan
```

**Linux**
```bash
cd ~/vacate
pwsh ./vacate.ps1 scan
```

**macOS**
```bash
cd ~/vacate
pwsh ./vacate.ps1 scan
```

Then open `runs/<timestamp>/report.html`. Add `-Redact` for a copy that is safe to share.

## 5. Every DECISIONS entry

Full text and reasons in [DECISIONS.md](../DECISIONS.md).

- **D1** Own directory walker on `DirectoryInfo.EnumerateFileSystemInfos()` instead of `EnumerationOptions`.
- **D2** Per-rule timeout is a cooperative deadline checked inside the walker on every entry.
- **D3** Registry key last-write time is reported as `null` with reason "not available without native API".
- **D4** JSON Schema validation tests run only on PowerShell 7.
- **D5** macOS is deferred until a Mac is available.
- **D6** Linux verification uses WSL Ubuntu 24.04.
- **D7** One rule per JSON file, named `<rule-id>.json`.
- **D8** Rules live per platform folder; `platforms` must include the folder's platform.
- **D9** Path locator gains optional `recurse` (sum sizes/counts below each match), `include` (file-name glob when recursing) and `excludeHome` (skip the current user's profile, for "other users" ...
- **D10** One trace per matched target (per glob match), not one per rule.
- **D11** Report gains top-level `skipped[]` (`ruleId`, `reason`, `detail`) and categories are a fixed enum of 18.
- **D12** `Glob`, reparse and cloud-placeholder checks live in `Private/Primitives.ps1`.
- **D13** Unix root detection uses `[Environment]::UserName -eq 'root'`.
- **D14** Rule paths are checked twice: syntax at load time (`RuleLoader`), and again by the path jail at scan time.
- **D15** An invalid rule file never loads; the rest of the catalog still loads and the errors are listed.
- **D16** Rule loader is `Import-VacateRuleSet` (singular noun).
- **D17** Checklist and report name vendor guidance by article title ("Recovery options in Windows", "Erase your Mac"), never by URL.
- **D18** Report carries `catalog.rules[]` (id, category, title, whyItMatters, sensitivity, source, verified).
- **D19** Each checklist step lists categories; a step appears when it is always-on (backup, account sign-out, encryption status, erase guidance) or has matching traces.
- **D20** Wallets go in the first "back up" step (write down recovery phrases).
- **D21** Rule ids are unique per platform, not globally: `browser.chrome.history` may exist once in `windows/` and once in `linux/`.
- **D22** `Invoke-VacateSystemQuery -Platform` accepts a platform name or a profile object; the "binary missing → unavailable" gate applies to the default runner only, an injected `-Runner` owns ex...
- **D23** Profiles normalise roots with string helpers, not `[IO.Path]`.
- **D24** Pester `-Skip`/`-ForEach` values are computed at file scope, not in `BeforeAll`.
- **D25** `-Redact` hashes names and path segments with HMAC-SHA256 under a random per-run key (`h-` + 10 hex).
- **D26** All JSON reading goes through `ConvertFrom-VacateJson`, which turns PowerShell 7's auto-parsed `[datetime]` values back into ISO strings.
- **D27** Rule status is recomputable from report.json: failed = distinct ruleIds in errors; skipped = distinct ruleIds in skipped with no trace and no error; run = total - failed - skipped.
- **D28** The tool may live inside a scanned root (most people unzip into Downloads).
- **D29** Paired sorts use the non-generic `[Array]::Sort([Array]keys, [Array]items, [Collections.IComparer]...)`.
- **D30** Static safety test also forbids CreateDirectory, AppendAll*, WriteAllLines, File/Directory mutators, StreamWriter, FileStream, OpenWrite and Set-Acl outside `Output.ps1`.
- **D31** "Other user profiles" drops built-in profile folders (Windows `Public`, `Default`, `Default User`, `All Users`, `defaultuser0`, `WDAGUtilityAccount`; macOS `Shared`, `Guest`; Linux `lost+...
- **D32** A rule becomes `verified: true` only when a real scan on that platform produced a trace for it; `verifiedOn` names the machine (`Windows 11 Pro 26300`, `Ubuntu 24.04 (WSL)`).
- **D33** Recent items and jump lists are one trace per folder (count, size, 3 samples), not one per file.
- **D34** Context scriptblocks are created with `Module.NewBoundScriptBlock`, never `GetNewClosure`.
- **D35** Linux verification: the owner installed real packages in WSL (zsh, fish, gnupg, npm, podman, xdg-user-dirs, glib, Firefox/kubectl/aws-cli snaps); each tool was then run once as the normal...
- **D36** GitHub receives only product files, via a `public` branch built by `tools/Publish-Public.ps1` from an allow-list; local `main` keeps team prompts, progress and research notes.
- **D37** macOS `.DS_Store` is checked per folder (Desktop, Documents, Downloads), not across the whole home.
- **D38** Harness self-test (SPEC): `tools/Invoke-SabotageTest.ps1` applies 6 mutations to a temp copy (force exists=$true, drop a rule, skip the link guard, ignore the budget, disable redaction, l...
- **D39** Performance (measured): 50,000-file synthetic profile scanned in 26.7 s on PowerShell 5.1, 13.6 s on PowerShell 7 (Windows), 13.4 s on Ubuntu; a single rule stops within ~1.06 s of a 1 s ...
- **D40** CI: the job sets `defaults.run.shell` from the matrix (a step-level `shell:` cannot use the matrix context, which made GitHub reject the workflow before any job ran).
- **D41** macOS rules found by the CI runner scan are marked `verified: true` with `verifiedOn: ["macOS 26.7.2 (GitHub Actions CI)"]`, i.e.
- **D42** Each rule's `measure` list is applied by the engine to every trace: undeclared size, date, count or properties are dropped.
- **D43** `docs/SPEC.md` (the original brief) is published with the code; internal team notes are not, and code comments no longer cite them.
- **D44** Phase 2 cleanup knowledge lives in each rule file as an optional `cleanup` object (action, exportFirst, signOut, steps, risk, closeApps, resetCovers, reason, source), validated by the loa...
- **D45** The plan accounts for every trace in the report: each trace appears in exactly one step.
- **D46** The plan ends with the platform's built-in full reset (Windows Reset this PC, macOS Erase All Content and Settings, Linux reinstall with disk erase), marked "only if you are giving the wh...
- **D47** Cleanup text is instructions in words: menu paths and plain descriptions.
- **D48** `vacate plan -Run <dir>` reads `report.json` from an existing run folder and writes `plan.json`, `plan.md` and `plan.html` into that folder through the single output writer.
- **D49** Plan steps are one per rule (all of that rule's locations listed), ordered by stage (export, sign out, uninstall, remove, review, manual, no action), then sensitivity (critical first), th...
- **D50** Phase 3 removes only files and folders under the user's own profile roots (HOME, APPDATA, LOCALAPPDATA, XDG_*, LIBRARY under the user's home), and only by moving them to the platform Recy...
- **D51** Only plan steps whose action is `remove` are eligible.
- **D52** `vacate clean -Run <dir>` is a dry run by default and lists what it would move.
- **D53** Every move is recorded in an undo log in the run folder (original path, Trash location, time, size).

## 6. Known false-positive risks

- **A trace is a location, not a fact.** vacate never opens files, so it cannot tell whether a
  profile is empty, a session is still signed in, or a key holds personal values.
- **Built-in profiles were a real false positive** (Public, Default reported as other users) and
  are now filtered (D31). Similar built-in names on other systems may still slip through.
- **Verified means "seen once".** An app update can move a path; `verifiedOn` does not expire.
- **Broad rules can match shared folders**, such as caches or vendor samples in an app's folder.
- **Cloud folders are local evidence only.** Files may be online-only or already deleted remotely.
- **Unverified rules can simply be wrong.** They are flagged in every report, but a reader may
  still treat a trace as certain.
- **The false-positive rate has not been measured** on a sample of real machines.

## 7. What Phase 2 would require

Phase 2 in the spec is **guided cleanup, dry-run only**: a plan per trace with what to remove,
how, the risk, and an export-first warning.

- Reviewed cleanup knowledge per rule (sign-out steps, what to export first, what to remove).
- A planner that reads `report.json` and writes a plan, with the same guarantees as Phase 1:
  no deletion, no writes outside `runs/`, no network.
- Ordering and risk per step (recovery phrases and exports first, sign-out before uninstall),
  building on the existing checklist order.
- "In use" checks: browsers and chat apps lock their folders; a plan must say when to close them.
- Tests that map every trace to a plan step or an explicit "no action", per platform.
- Before Phase 2: verify macOS on a personal Mac, run the elevated Windows scan, and keep rule ids
  stable so saved reports can be planned later.

## 8. Phase 2: guided cleanup (dry run)

Phase 2 is done. `vacate plan -Run <dir>` reads a saved `report.json` and writes `plan.json`,
`plan.md` and `plan.html` into the same run folder. It never scans and never changes anything.

| | |
|---|---|
| Rules with cleanup guidance | **223 of 223** (a test fails if any rule has none) |
| Real Windows scan (elevated) | 44 plan steps cover all 49 traces, 44 with guidance |
| Real Linux scan (WSL) | 20 plan steps cover all 26 traces, 20 with guidance |
| Plan schema | `schemas/plan.schema.json`, checked by tests on PowerShell 7 |
| Decisions | D44-D49 |

How the plan works:
- **Every trace is covered** (D45). One step per rule, listing all its locations. A rule without
  guidance or missing from the catalog still gets a step that says so.
- **Order** (D49): save what you want to keep, sign out, uninstall, remove, decide yourself, no
  guidance, no action; then critical before low; then rule id.
- **Words only** (D47). The loader rejects cleanup text with a shell delete command or backtick.
- **No hand-deleting system-managed data.** Guidance uses the app or system settings, or points
  to the full reset. System logs are never cleared by hand: that can look like hiding activity.
- **Ends with the built-in reset** (D46): Reset this PC, Erase All Content and Settings, or a
  reinstall over the whole disk. vacate does not erase.

How the guidance was checked: written from vendor help pages per platform, then reviewed rule by
rule by the integrator and once more by an independent reviewer, in two passes (72 findings in all:
5 high, 22 medium, 45 low). All high and medium findings and the lows that changed behaviour or
misled were fixed; 20 weak sources were replaced with exact vendor articles.

Not verified:
- **No step was followed by hand on a real machine.** Menu paths come from vendor documentation
  and can move with updates. The plan points to the vendor page for each step.
- macOS guidance has the same limit as macOS rules: no personal Mac has been used.
- The plan cannot tell whether an export worked or an account is really signed out. A second scan
  shows what is still present.

What Phase 3 (safe deletion) would require, from the spec roadmap: allow-listed roots, link
resolution, Recycle Bin or Trash by default, an exact-path registry and plist allow-list,
`-Execute -Confirm <MACHINENAME>`, a verification re-scan and an undo log. The Phase 2 plan
(`plan.json`) is the natural input: each step already names its rule, action and locations.

## 9. Phase 3: safe deletion (Recycle Bin and Trash only)

Phase 3 adds `vacate clean` and `vacate undo` (D50-D53). Both are dry runs by default.

```powershell
vacate.ps1 clean -Run <dir>                                          # preview, moves nothing
vacate.ps1 clean -Run <dir> -Steps 3,5 -Execute -Confirm <MACHINENAME>
vacate.ps1 undo  -Run <dir> -Execute -Confirm <MACHINENAME>
```

What it will move: only plan steps whose action is `remove`, for one exact file or folder
inside the user's own profile. Wallets, personal folders, rules that search inside a folder,
registry and system locations, steps that need a sign-out or a decision, and 8 manual-only rules
are never moved. On the current catalog: 4 Windows, 4 macOS and 5 Linux rules qualify.

Safety layers, in the order they run:
1. Refuses a redacted report, a report from another platform or machine, and admin/root sessions.
2. Without `-Steps`, `-Execute` and `-Confirm` equal to the machine name, nothing moves.
3. Eligibility per step (D51), with a coded reason for every refusal.
4. Each path must be one the rule finds **now**, under the rule's own root, inside the real home
   folder; vacate's own folder and `runs` are excluded. An edited or stale `plan.json` cannot
   reach other files.
5. A last check right before each move: canonical absolute path, no link or junction anywhere on
   the way, not a root, not redacted.
6. The movers only ever move into the Recycle Bin or Trash and never overwrite. Windows checks the
   drive, bin settings, size and path length first and confirms the ``/`` entry
   afterwards; Linux follows the freedesktop Trash spec and refuses moves across filesystems;
   macOS renames into `~/.Trash`.
7. `undo.json` is written after every move; `undo` restores newest first and never overwrites.

Verified:
- 9 end-to-end tests on a fake profile (dry run unchanged, confirm gate, wallet refused, link swap
  refused, full undo), plus unit tests for eligibility, target check, undo log and each mover.
- **Live on this Windows PC:** a throwaway file and folder went into the real Recycle Bin
  (`C:\$Recycle.Bin\<SID>\$R...`), a pretend wallet was refused, and `undo` restored both
  with contents intact.
- Linux mover: 70 unit tests in WSL Ubuntu 24.04. Sabotage: 11 of 11 deliberate breakages caught,
  including "ignore the machine-name confirm", "let wallets through", "follow a link".

Not verified or known limits:
- macOS mover tested only with an injected Trash folder; no real Mac.
- Windows: bin settings cannot be tied to a drive without COM, so one "delete immediately" drive
  makes vacate refuse on all drives. A locked file can still make Windows show an error dialog;
  the move then fails safely. Restore leaves the small `` record behind.
- Linux: the `.trashinfo` write and the folder restore have a tiny race window; the device check
  uses mount data, not device ids, and refuses symlinked setups.
- The Recycle Bin and Trash are not erasure: empty them, or use the full reset, before handover.

## Legal and ethical scope

For devices you own or are authorised to hand over. Not for destroying evidence, defeating a legal
hold, or falsifying records.