# Writing cleanup guidance for a rule

Phase 2 of vacate turns a scan report into a **cleanup plan**: for every trace, what to save,
what to sign out of, what to remove by hand, and what can break. vacate still deletes nothing.
The plan is instructions for a person.

The knowledge comes from an optional `cleanup` object in each rule file
(`src/Vacate/rules/<platform>/<id>.json`). This guide says how to write one.

## The object

```json
"cleanup": {
  "action": "export-then-remove",
  "exportFirst": "Export saved passwords from Chrome Password Manager settings and save bookmarks with Bookmark manager > Export bookmarks.",
  "signOut": "In Chrome, open Settings > You and Google and choose Turn off, so synced data stays in your Google account but leaves this PC.",
  "steps": [
    "Close every Chrome window.",
    "Uninstall Google Chrome from Settings > Apps > Installed apps.",
    "Delete the folder named in the plan (Google\\Chrome\\User Data) if it is still there."
  ],
  "risk": "Removes every Chrome profile on this PC: history, saved logins, cookies and extensions.",
  "closeApps": ["Google Chrome"],
  "resetCovers": true,
  "reason": null,
  "source": "Google Chrome Help, Sign in and sync in Chrome: https://support.google.com/chrome/answer/185277"
}
```

Every field is required. Use `null` or `[]` where the field does not apply.

| Field | What to write |
|---|---|
| `action` | One of the actions below. |
| `exportFirst` | What the person should save before removing anything, and where in the app to do it. `null` if there is nothing worth saving. |
| `signOut` | Where to sign out, de-link or deauthorize, so the account no longer trusts this device. `null` if there is no account. |
| `steps` | 1-6 short manual steps, in order. Empty only when `action` is `none`. |
| `risk` | What is lost or breaks if the person follows the steps. Always write one. |
| `closeApps` | Display names of apps that must be closed first because they lock the files. |
| `resetCovers` | `true` if a full operating-system reset ("Reset this PC", "Erase All Content and Settings", a reinstall that erases the disk) removes this trace. |
| `reason` | Only for `action: none`: why no action is needed. `null` otherwise. |
| `source` | The vendor's own help page, as "Vendor, page title: URL". |

## Actions

| Action | Use when | Must have |
|---|---|---|
| `export-then-remove` | There is personal data worth keeping (passwords, wallets, photos, mail). | `exportFirst` |
| `sign-out-then-remove` | An account trusts this device (sync, chat sessions, cloud clients, licences). | `signOut` |
| `uninstall` | Removing the app is the cleanup, and uninstalling removes the trace. | `steps` |
| `remove` | Removing the files or entries is enough, with no account or export involved. | `steps` |
| `review` | Only the person can decide, for example a folder of their own files. | `steps` |
| `none` | Nothing to do, for example hardware status or a fact about the system. | `reason`, empty `steps` |

When both apply, pick the earlier action in this table and still fill both fields. A wallet
with an account is `export-then-remove` with `signOut` filled.

## Rules

1. **Words, not commands.** No shell commands to paste, no backticks. Write "Delete the folder"
   or "Settings > Apps > Installed apps", never `rm -rf` or `Remove-Item`. The loader rejects
   text that looks like a delete command (DECISIONS D47). Removal commands are Phase 3.
2. **Plain ASCII**, no emoji or smart quotes. Write `>` between menu levels.
3. **Vendor sources only.** The `source` must be the vendor's own help or documentation page.
   If no vendor page exists, use the operating system vendor's page and say so in `risk` or a
   step. Never invent menu names: if you are not sure a menu path exists in the current version,
   describe the goal instead ("sign out in the app's account settings").
4. **Export before sign-out before removal.** Steps that destroy data come last.
5. **Wallets and recovery phrases**: always tell the person to confirm they have the recovery
   phrase or backup before anything else. Never tell them to type a phrase anywhere.
6. **Short.** Each step is one action, at most 200 characters. The person reads this on the
   machine they are cleaning.
7. **No hand-deleting system files.** Never tell the person to delete files under system
   locations (`/Library`, `/etc`, `/var`, `HKLM`, `C:\Windows`, `C:\ProgramData`) or anything
   that needs an administrator account. Use the app or Settings, and otherwise say the full
   reset at the end of the plan clears it.
8. **Do not repeat the path.** The plan prints the exact locations vacate found next to the
   steps. Refer to "the folder named in the plan".

## Check your work

```powershell
pwsh -File vacate.ps1 rules validate
```

A rule with a bad `cleanup` object fails validation with the field and the reason.
