@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Write-Output is used for CLI text; Write-Host is avoided entirely.
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
