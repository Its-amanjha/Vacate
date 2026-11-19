# Vacate.psm1 - module loader. Owner: Claude.
# Loads Models.ps1, then Private/, Platforms/, Public/ in ordinal-sorted order.
# Do not register files here by hand; drop a .ps1 into the right folder instead.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:VacateModuleRoot = $PSScriptRoot
$script:VacateRulesRoot = Join-Path $PSScriptRoot 'rules'

. (Join-Path $PSScriptRoot 'Models.ps1')

foreach ($folder in @('Private', 'Platforms', 'Public')) {
    $dir = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object -Property Name -CaseSensitive)
    foreach ($file in $files) {
        . $file.FullName
    }
}

# Public surface. Everything else is reached in tests through InModuleScope.
$publicDir = Join-Path $PSScriptRoot 'Public'
$public = @()
if (Test-Path -LiteralPath $publicDir) {
    $public = @(Get-ChildItem -LiteralPath $publicDir -Filter '*.ps1' -File | ForEach-Object { $_.BaseName })
}
Export-ModuleMember -Function $public
