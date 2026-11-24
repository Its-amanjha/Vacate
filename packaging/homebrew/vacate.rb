class Vacate < Formula
  desc "Find the personal data and traces left on a computer before handing it over"
  homepage "https://github.com/Its-amanjha/Vacate"
  # VERSION and SHA256 are replaced after each release; see README.md next to this file.
  # The version is read from this URL (there is no separate version stanza: a stanza plus
  # "#{version}" inside the URL does not resolve, because url is evaluated first).
  url "https://github.com/Its-amanjha/Vacate/releases/download/vVERSION/vacate-VERSION.zip"
  sha256 "SHA256"
  license "MIT"

  # No depends_on here: Homebrew formulae cannot depend on casks, and pwsh ships as the
  # powershell cask (https://github.com/Homebrew/brew/issues/17326). The wrapper below
  # checks for pwsh and says what to install instead of failing with "command not found".

  def install
    # Homebrew strips the archive's single top-level folder (vacate-<version>), so the staged
    # tree normally starts at vacate.ps1; keep the folder name as a fallback.
    root = File.directory?("vacate-#{version}") ? "vacate-#{version}" : "."
    libexec.install Dir["#{root}/*"]

    (bin/"vacate").write <<~SH
      #!/bin/sh
      # vacate is a PowerShell script; this wrapper runs it from the installed tree.
      # PowerShell 7 is a cask, so a formula cannot depend on it: check and explain.
      if ! command -v pwsh >/dev/null 2>&1; then
        echo "vacate needs PowerShell 7 (pwsh), which Homebrew ships as a cask." >&2
        echo "Install it once with:  brew install --cask powershell" >&2
        echo "Then run:              vacate version" >&2
        exit 1
      fi
      exec pwsh -NoProfile -File "#{libexec}/vacate.ps1" "$@"
    SH
  end

  def caveats
    <<~EOS
      vacate runs on PowerShell 7, which Homebrew ships as a cask rather than a
      formula. If `pwsh` is not on your PATH, install it once:

        brew install --cask powershell

      vacate never runs as root and never writes outside its own run folder.
      Start with the guide: https://github.com/Its-amanjha/Vacate/blob/main/docs/GUIDE.md
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/vacate version")
    system bin/"vacate", "rules", "validate"
  end
end
