# Checking a vacate download

Every release on https://github.com/Its-amanjha/Vacate/releases has two files:

- `vacate-<version>.zip` - the program.
- `SHA256SUMS` - the ZIP's fingerprint (a SHA-256 hash).

The ZIP is built by GitHub from the tagged code, not on anyone's own computer, and GitHub records
a signed note (an "attestation") saying which repository and commit it came from. vacate's
scripts are not code-signed (D61), so on Windows this check is how you know the download is the
real one.

## 1. Compare the fingerprint (no extra tools)

**Windows (PowerShell)**
```powershell
(Get-FileHash .\vacate-0.5.0.zip -Algorithm SHA256).Hash.ToLower()
Get-Content .\SHA256SUMS
```

**macOS**
```bash
shasum -a 256 vacate-0.5.0.zip
cat SHA256SUMS
```

**Linux**
```bash
sha256sum -c SHA256SUMS
```

The two long values must be exactly the same. If they differ, delete the download and do not run
it. A matching hash only shows the file was not damaged or swapped on the way, if you also got
SHA256SUMS from the official release page.

## 2. Check where it was built (optional, needs the GitHub CLI)

Install the GitHub CLI (`gh`) from https://cli.github.com, then:

```bash
gh attestation verify vacate-0.5.0.zip --repo Its-amanjha/Vacate
```

It must say the attestation was verified and name the `Release` workflow of
`Its-amanjha/Vacate`. This proves GitHub built the ZIP from this repository; it does not prove
the code is free of bugs.

## 3. Check the unzipped files (optional)

The ZIP holds `MANIFEST.sha256`, the hash of every file inside it. From the unzipped folder:

**macOS**
```bash
shasum -a 256 -c MANIFEST.sha256
```

**Linux**
```bash
sha256sum -c MANIFEST.sha256
```

**Windows (PowerShell)**
```powershell
Get-Content .\MANIFEST.sha256 | ForEach-Object {
    $hash, $file = $_ -split '  ', 2
    if ((Get-FileHash $file -Algorithm SHA256).Hash.ToLower() -ne $hash) { "CHANGED: $file" }
}
```

No output on Windows (or every line `OK` on macOS/Linux) means no file was changed after the build.

## 4. Rebuild it yourself (optional, for developers)

The build is reproducible: the same commit always gives the same ZIP. With git and PowerShell 7:

```bash
git clone https://github.com/Its-amanjha/Vacate.git && cd Vacate
git checkout v0.5.0
pwsh -NoProfile -File tools/Build-Release.ps1 -Version 0.5.0
cat dist/SHA256SUMS
```

The hash should match the release's SHA256SUMS. The compression behind the ZIP differs between
PowerShell 7 versions and platforms (the builder refuses to run on Windows PowerShell 5.1), so
compare a rebuild with the one GitHub made only when it runs the same pwsh: the release workflow
builds on `ubuntu-latest` with that runner's PowerShell 7 (see `pwsh --version`). A different
pwsh or operating system may give a different, equally valid ZIP.
