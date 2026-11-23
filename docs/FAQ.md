# Frequently asked questions

These answers are for people handing over a computer, not for developers. They describe the
current build; the full detail is in [README.md](../README.md), [LIMITS.md](../LIMITS.md) and
[docs/GUIDE.md](GUIDE.md).

## What is vacate?

vacate is a PowerShell tool that looks for personal data and accounts left on a computer before
you sell, return, recycle or give it away. It writes an HTML report and a step-by-step cleanup
plan. Scanning, reporting and planning only read; the optional `clean` command moves a few
leftovers to the Recycle Bin or Trash, and `erase` opens the operating system's own erase. It is
not a certified secure-erase product.

## Does vacate upload or send my data?

No. It has no accounts, telemetry, update check or network calls, and the HTML report is
self-contained with no external files. Everything runs on the computer you are cleaning.

## Does it read my files?

No. It records metadata only: names, sizes, timestamps and counts. It never opens, parses,
decrypts or uploads the contents of the files it scans. It does read its own report, plan, undo
and erase-record JSON files so it can do its job. For example, a browser history file is reported
by name and size, not by the sites inside it.

## Is the report safe to share?

The normal report is not safe to share: it lists your machine name, user name, folder names and
file names, and should be treated like a password. Run `scan -Redact` to make a shareable copy; it
replaces machine and user names, path segments and sample names with codes that cannot be reversed
or matched to another report, while keeping counts, sizes, times and rule ids. The redacted log
keeps only a summary line. Even a redacted report shows which kinds of data were found, so share
it only with someone you trust.

## Why did clean refuse an item?

`clean` only moves a single file or folder inside your own profile, and only for plan steps whose
action is `remove`. It refuses wallets, personal folders such as Documents, registry and system
locations, steps that ask you to save or sign out first, and steps that search inside a folder.
It also refuses a report from another machine or platform, a redacted report, an administrator
session when it moves, and any path that changed or leads through a link. A save-first step needs
`-ExportDone <step>` before it can move.

## Can I undo clean?

Yes, if `clean` moved something from that run. Run `undo -Run <dir>` first to see the dry run, then
add `-Execute -Confirm <MACHINENAME>` to restore; it must run on the same machine, platform and
normal user account. If something new now exists at an original path, undo leaves that item in the
Recycle Bin or Trash and lists it instead of overwriting. Items in the bin are still restorable by
anyone using your account, so empty it or use the full reset before handover.

## Why does erase need my disk serial?

The serial ties the erase command and the erase record to the exact physical system disk, so a typo
or a different disk cannot start an erase. `erase -Execute` compares `-DiskSerial` with the disk
vacate identified and stops before writing the record if they do not match. Copy the serial shown
in `erase-readiness.md`; do not guess it.

## Why won't erase run in a VM or WSL?

Erasing inside a virtual machine, WSL or a container would destroy only the virtual disk while the
real computer and its data stay untouched. The readiness check therefore requires confirmed
bare-metal hardware and refuses when it cannot tell. Erase also refuses a disk it cannot fully
identify.

## Is the erase certified?

No. vacate starts the operating system's own cryptographic erase and calls the result a
NIST SP 800-88 Rev. 2 style cryptographic erase, but it is not independently verified or
certified. Microsoft also says Reset this PC does not meet industry erasure standards. Treat it
as a strong consumer erase, not a certificate.

## What does the erase record prove?

The record is written before the operating system erase starts. It says what vacate checked and
which erase it was about to open, and it includes a SHA-256 fingerprint of the record body. It is
unsigned (`signed` is false), it cannot prove the erase finished, and anyone can create a similar
record; it is not independent proof.

## Does vacate sign me out of accounts?

No. The plan and checklist tell you where to sign out or de-link a device, but you do it yourself.
Erase shows a warning to sign out of your Microsoft or Apple account, turn off Find My, and handle
browser sync by hand. vacate cannot sign in to your accounts.

## What about my phone, cloud copies and backups?

vacate scans this computer's disk, not your phone, cloud account or backups. It can report local
caches such as Phone Link, but messages and photos on the phone stay on the phone. Files already
synced or backed up elsewhere remain there; sign out of each service, remove this device from the
account, and check backups separately. A full reset does not reach those copies either.

## Does it work on Mac and Linux?

Yes. The same PowerShell tool runs on Windows, macOS and Linux. The scan, report and checklist flow
is tested end to end on Windows 11 and Ubuntu 24.04, while macOS is currently verified by a scan on
a GitHub Actions runner, not yet on a personal Mac. `clean`, `undo` and `erase` also run on all
three, but no erase has ever been started against a real disk in development: the Windows and
macOS launch steps are tested with the launch stubbed, and the Linux key erase on a disposable test
file. Some platform limits apply, such as privacy-protected folders on macOS and root-only files
on Linux.

## Is it free?

There is no account, subscription or paid tier in the project: you download the script and run it
yourself. The repository does not include a license file, so ask the project owner before
redistributing it or shipping it inside another product. Running it on your own machine costs
nothing.

## Who is it for, and who is it not for?

It is for people who own a computer, or are authorised to hand it over, and want to find and
remove their own traces before selling, returning, recycling or giving it away. It is not for
destroying evidence, defeating a legal hold or falsifying records. It is also not a certified
erasure service or a forensic investigation tool.

## What does a clean report mean?

It means vacate found nothing in the locations its rules know about, on the paths it was allowed
to read. It does not mean the data is gone or that the computer is clean. A short report can
simply mean an app has no rule, a folder was skipped, or the scan hit its time limit.

## What does "verified" mean in the report?

A verified rule's location was confirmed on a real machine: [RULES.md](../RULES.md) and
`rules show <id>` name the system it was checked on, and an unverified rule still runs but is
listed as unverified in every report. Treat an unverified rule as a lead rather than a fact.

## Why did the scan skip something or stop early?

Each rule has a 10-second limit and the whole scan has a budget, 120 seconds by default. A huge
folder can hit the limit, and a slow system call cannot always be interrupted, so a count may be
partial or a rule may be skipped. The report marks the scan incomplete when the budget runs out;
rerun with a larger `-BudgetSeconds` or check that folder by hand.

## What does clean actually move?

Only the plan steps you name, and only `remove` steps for a single file or folder inside your own
profile. It moves them to the Recycle Bin or Trash, records each move in `undo.json`, and re-scans
the cleaned rules to show what came back. It never falls back to a permanent delete.

## What happens to items in the Recycle Bin or Trash?

They are not erased. They still take space and anyone using your account can restore them until
the bin is emptied. Empty it, or finish with the full reset, before you hand the computer over.
If you want them back first, use `undo`.

## Does erase delete the disk itself?

No. It checks readiness, writes the erase record, and opens the operating system's own erase:
Reset this PC on Windows (Settings > System > Recovery on Windows 11 24H2 and later), Erase All
Content and Settings on macOS, or a LUKS key erase on Linux. You confirm and finish the erase in
that tool. vacate never sends raw commands to the disk and cannot tell afterwards whether the
erase completed.

## Can I run it as administrator or root?

Scan, report, plan and clean are meant to run as your normal user; only `erase -Execute` needs an
administrator or root session. `scan -Elevated` only tells vacate the session is already elevated;
vacate never elevates itself or asks for a password. On macOS and Linux, a root scan is refused
unless you pass `-AllowRoot`, because root can read other users' data.

## What should I do before I start?

Allow about an hour, connect a USB drive for files and the erase record, and know the passwords
for your main accounts. If you own a crypto wallet, find its recovery phrase or backup before
removing anything. Read the plan's Save first and Risk sections before you follow any step.

## Why does the report warn that it is sensitive?

Because it names the places your private data lives, including folders and file names, and that
is enough to help someone find it. Treat the run folder like a password, do not email or upload
it, and delete the `runs` folder when you no longer need it. Use `-Redact` when you need help
reading it.
