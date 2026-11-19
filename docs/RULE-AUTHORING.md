# How to write a vacate rule

Owner: Claude. For rule authors (Freebuff, OpenCode, anyone). Read `CLAUDE.md` first.

## One rule = one file

`src/Vacate/rules/<platform>/<rule-id>.json`, ASCII only, 2-space indent, keys in exactly this order:

```json
{
  "id": "browser.chrome.history",
  "platforms": ["windows"],
  "category": "browsers",
  "title": "Chrome history database",
  "whyItMatters": "Lists every site visited and when. Anyone with the disk can read it.",
  "sensitivity": "high",
  "locator": {
    "kind": "path",
    "root": "LOCALAPPDATA",
    "path": "Google/Chrome/User Data/*/History",
    "match": "files"
  },
  "measure": ["exists", "sizeBytes", "lastWriteTime", "itemCount"],
  "maxEntries": 5000,
  "requiresElevation": false,
  "verifiedOn": [],
  "verified": false,
  "source": "Chromium docs, User Data Directory: https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md",
  "notes": null
}
```

## Field rules

| Field | Rule |
|---|---|
| `id` | lowercase, dot-separated, e.g. `msg.signal.data`. Must equal the file name. |
| `platforms` | must include the folder's platform. For now: only that one platform. |
| `category` | one of the 18 in `schemas/rule.schema.json`. |
| `title` | short noun phrase a normal person understands. |
| `whyItMatters` | one or two plain sentences: what a stranger could do with it. No hype. |
| `sensitivity` | `critical` = passwords, keys, wallets, session tokens. `high` = history, messages, cookies. `medium` = personal files, activity traces. `low` = caches, logs, names only. |
| `locator.path` | forward slashes, relative to `root`. `*` matches **one** folder or file name, `?` one character. No `..`, no `**`, no leading `/`, no drive letters, no backslashes. `""` = the root itself. |
| `locator.match` | `files`, `directories` or `any`: what the **last** segment must be. |
| `locator.recurse` | `true` to add up size and count of everything inside each matched folder. |
| `locator.include` | with `recurse`, only count files whose name matches this glob (e.g. `*.sqlite`). |
| `locator.excludeHome` | `true` only for "other user profiles" rules on `USERS`. |
| `measure` | `path`: subset of `exists, sizeBytes, lastWriteTime, itemCount`. `registry`: `exists, valueCount, subkeyCount`. `wmi`: `exists, properties`. |
| `maxEntries` | default 5000. Big folders (Documents, Downloads): 20000. Max 50000. |
| `requiresElevation` | `true` only if a normal user cannot read it (e.g. `ProgramData/Microsoft/Wlansvc`, `Windows/Prefetch`, BitLocker WMI). |
| `verified` / `verifiedOn` | **Always `false` / `[]` when you draft.** Claude flips them after checking on a real machine. |
| `source` | where the path comes from: vendor docs URL, well-known forensics reference, or "observed on Windows 11 by <agent>" if you saw it with a read-only `Test-Path`. Never empty, never made up. |
| `notes` | variants (Store app vs installer, old vs new path), caveats, or `null`. |

## Locator kinds

```json
{ "kind": "path", "root": "HOME", "path": ".ssh", "match": "directories", "recurse": true }
{ "kind": "registry", "hive": "HKCU", "key": "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\RunMRU" }
{ "kind": "wmi", "namespace": "root/CIMV2/Security/MicrosoftVolumeEncryption", "className": "Win32_EncryptableVolume", "properties": ["DriveLetter", "ProtectionStatus"] }
{ "kind": "installed-program", "scope": "all" }
{ "kind": "system-query", "name": "block-devices" }
```

Registry keys: backslashes (escaped as `\\` in JSON), no leading/trailing backslash, no hive prefix.

## Variants

If an app stores data in different places (installer vs Microsoft Store, old vs new version),
write **one rule per variant** with ids like `msg.whatsapp.store` and `msg.whatsapp.desktop`, and
say which is which in `notes`.

## Browser profiles

Chromium browsers keep non-profile folders next to profiles (`Crash Reports`, `ShaderCache`, ...).
To match only real profiles, match a file every profile has, e.g. `User Data/*/Preferences`.

## Checking your files

```powershell
pwsh -NoProfile -File tests/Test-RuleFiles.ps1 -Platform windows
```

Must end with `failed=0`. You may check whether a path exists on this PC with **read-only**
`Test-Path -LiteralPath <path>`. Never open, read, copy or list the contents of what you find.
Record what you saw in your research notes file, not by setting `verified`.
