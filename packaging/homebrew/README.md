# Homebrew formula for vacate

`vacate.rb` is the formula published in the tap repository
[`Its-amanjha/homebrew-vacate`](https://github.com/Its-amanjha/homebrew-vacate). Users install
it with:

```bash
brew install Its-amanjha/vacate/vacate
```

or, with the tap added first:

```bash
brew tap Its-amanjha/vacate
brew install vacate
```

This folder is the source of truth for the formula. The tap holds a copy at `Formula/vacate.rb`
with the version and checksum filled in.

## PowerShell is a cask, not a formula

Homebrew formulae cannot depend on casks, by design
([Homebrew/brew#17326](https://github.com/Homebrew/brew/issues/17326)); `pwsh` ships as the
`powershell` cask. So the formula does two things instead of declaring a dependency:

- a `caveats` block tells the user to run `brew install --cask powershell` if `pwsh` is missing;
- the installed `vacate` wrapper checks for `pwsh` and, when it is missing, prints the install
  command and exits 1 instead of failing with "command not found".

On Linux the `powershell` cask does not apply (casks are macOS-only). Install PowerShell 7 from
Microsoft's package for the distribution, for example `snap install powershell --classic`, and
check it with `pwsh -v`.

## Trusting a third-party tap

Homebrew 6 asks for explicit trust before installing from a tap that is not `homebrew/core` or
`homebrew/cask`:

```bash
brew trust Its-amanjha/vacate
```

A fully qualified `brew install Its-amanjha/vacate/vacate` prompts for the same trust. This is a
deliberate Homebrew security change, not a problem with the formula.

## macOS quarantine

`brew` downloads and unpacks the release ZIP itself, so the archive does not get the
`com.apple.quarantine` attribute and the scripts run. If a ZIP was downloaded in a browser and
unzipped with Finder instead, macOS may refuse to run `vacate.ps1` until the attribute is
removed: `xattr -d com.apple.quarantine ./vacate.ps1`.

## What the formula installs

| Path | Content |
|---|---|
| `libexec/` | the whole release tree: `vacate.ps1`, `src/Vacate/**`, `schemas/`, docs |
| `bin/vacate` | a `sh` wrapper that runs `pwsh -NoProfile -File <libexec>/vacate.ps1 "$@"` |

Everything sits under the keg, so `brew uninstall vacate` removes it completely. There is no
post-install script, no `brew` call at run time and no network access at run time.

## Publishing a release (the step that fills the placeholders)

1. Tag and release: pushing a tag such as `v0.1.0` runs `.github/workflows/release.yml`, which
   builds the reproducible `vacate-0.1.0.zip`, attests it and publishes it with `SHA256SUMS`.
2. Get the checksum:

   ```bash
   gh release download v0.1.0 --pattern SHA256SUMS --output -
   ```

3. Fill in this copy of the formula (macOS needs the empty `-i ''` argument). `VERSION` appears
   twice, in the release tag and in the ZIP file name, and Homebrew reads the version from that
   URL, so there is no separate version stanza to update:

   ```bash
   VERSION=0.1.0
   SHA256=<the hash of vacate-0.1.0.zip from SHA256SUMS>
   # macOS
   sed -i '' -e "s/VERSION/$VERSION/g"              -e "s/SHA256/$SHA256/" packaging/homebrew/vacate.rb
   # Linux
   sed -i    -e "s/VERSION/$VERSION/g"              -e "s/SHA256/$SHA256/" packaging/homebrew/vacate.rb
   ```

   Do not add `version "..."`: `url` is evaluated before any version stanza, so `#{version}`
   inside the URL would expand to nothing and the download would fail; Homebrew detects `0.1.0`
   from the URL on its own.

   The ZIP's top folder is `vacate-<version>/`, and Homebrew strips that single top folder when
   it unpacks the archive, so the `install` block copies the staged tree (it keeps a fallback to
   the folder name in case that ever changes). The version in the URL must match the ZIP name.
4. Copy the file into the tap repository as `Formula/vacate.rb`, commit (`vacate $VERSION`) and
   push.
5. Verify before announcing it:

   ```bash
   brew audit --strict --formula its-amanjha/vacate/vacate
   brew install --formula its-amanjha/vacate/vacate
   vacate version
   vacate rules validate
   brew test vacate
   ```

   `brew audit` has to be given a formula name, not a path: current Homebrew answers a path with
   "Calling `brew audit [path ...]` is disabled". The tap must be added first (`brew tap`), and
   the audit needs network access for the homepage check.

Only `version` and `sha256` change between releases. If `pwsh` handling or the install layout
changes, update this file and the tap copy together.

## Testing the formula locally, without a release

The same steps the test run used, with no GitHub release and no committed changes. Current
Homebrew rejects a formula that is not inside a tap ("Homebrew requires formulae to be in a
tap", [Homebrew/brew#20521](https://github.com/Homebrew/brew/issues/20521)), so the local copy
is installed from a throwaway local tap:

```bash
# In the vacate worktree
pwsh -NoProfile -File tools/Build-Release.ps1 -Version 0.1.0 -AllowDirty
sha256sum dist/vacate-0.1.0.zip

# A copy of the formula, pointed at the local file; do not commit this copy.
# The formula has no version stanza (the version comes from the URL), so the ZIP
# file name vacate-0.1.0.zip is what Homebrew reads as 0.1.0.
sed -e 's#^  sha256 "SHA256"$#  sha256 "<hash from the line above>"#' \
    -e 's#^  url .*#  url "file:///path/to/dist/vacate-0.1.0.zip"#' \
    packaging/homebrew/vacate.rb > /tmp/vacate.rb

# A local tap is what makes brew read the formula at all
brew tap-new its-amanjha/homebrew-vacate
TAP="$(brew --repository its-amanjha/vacate)"
cp /tmp/vacate.rb "$TAP/Formula/vacate.rb"
git -C "$TAP" -c user.name=test -c user.email=test@example.invalid commit -qam 'vacate 0.1.0'

brew install --formula its-amanjha/vacate/vacate
vacate version
vacate rules validate
brew test vacate
brew audit --strict --formula its-amanjha/vacate/vacate
brew uninstall vacate
brew untap its-amanjha/vacate
```

`brew audit` needs network for the homepage check. On Linux this is Linuxbrew
(`/home/linuxbrew/.linuxbrew`), which runs as a normal user and is never invoked with `sudo`.
