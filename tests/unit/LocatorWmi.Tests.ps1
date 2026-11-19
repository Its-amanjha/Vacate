# WMI/CIM locator tests, plus the static read-only checks for all locator sources.
# Pester 5 runs It bodies in a scope that does not see the file body, so helpers live in BeforeAll.
# -Skip is evaluated at discovery time, so the runtime platform is computed here.

$script:runtimePlatform = 'linux'
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $script:runtimePlatform = 'windows'
}
else {
    $runtime = [System.Runtime.InteropServices.RuntimeInformation]
    if ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $script:runtimePlatform = 'windows' }
    elseif ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { $script:runtimePlatform = 'macos' }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/Vacate/Vacate.psm1') -Force

    function Get-TestProfile {
        param([string]$Name = 'windows')
        return [pscustomobject][ordered]@{
            Name          = $Name
            CaseSensitive = $false
            Comparison    = [StringComparison]::OrdinalIgnoreCase
            Separator     = [char]'\'
            Roots         = [ordered]@{}
            HomePath      = 'C:\Users\ann'
            UsersRoot     = 'C:\Users'
            UserName      = 'ann'
        }
    }

    function Get-TestContext {
        param(
            [object]$Registry = $null,
            [object]$Cim = $null,
            [object]$SystemQuery = $null,
            [string]$Platform = 'windows'
        )
        return [pscustomobject][ordered]@{
            Platform    = (Get-TestProfile -Name $Platform)
            FileSystem  = $null
            Registry    = $Registry
            Cim         = $Cim
            SystemQuery = $SystemQuery
            Elevated    = $false
            MountPoints = @()
            Exclude     = @()
        }
    }

    function Get-TestRule {
        param(
            [Parameter(Mandatory)][System.Collections.IDictionary]$Locator,
            [string]$Id = 'test.wmi',
            [string]$Platform = 'windows'
        )
        return [pscustomobject][ordered]@{
            id                = $Id
            platforms         = @($Platform)
            category          = 'encryption'
            title             = 'Test WMI rule'
            whyItMatters      = 'Unit test rule for a locator executor.'
            sensitivity       = 'high'
            locator           = [pscustomobject]$Locator
            measure           = @('properties')
            maxEntries        = 10
            requiresElevation = $false
            verifiedOn        = @()
            verified          = $false
            source            = 'Unit test source, not a real rule'
            notes             = $null
        }
    }

    function Get-TestDeadline {
        param([int]$Minutes = 5)
        return [datetime]::UtcNow.AddMinutes($Minutes)
    }

    function Invoke-TestWmiLocator {
        param([object]$Rule, [object]$Context, [datetime]$Deadline)
        return (InModuleScope Vacate -Parameters @{ R = $Rule; C = $Context; D = $Deadline } {
                param($R, $C, $D)
                Invoke-VacateWmiLocator -Rule $R -Context $C -Deadline $D
            })
    }

    $script:volumeLocator = [ordered]@{
        kind      = 'wmi'
        namespace = 'root/CIMV2/Security/MicrosoftVolumeEncryption'
        className = 'Win32_EncryptableVolume'
        properties = @('DriveLetter', 'ProtectionStatus')
    }
}

Describe 'Invoke-VacateWmiLocator' {
    It 'returns one trace per returned instance' {
        $calls = New-Object System.Collections.ArrayList
        $cim = {
            param($Namespace, $ClassName, $Property)
            [void]$calls.Add(("{0}|{1}|{2}" -f $Namespace, $ClassName, (@($Property) -join ',')))
            return @(
                [pscustomobject]@{ DriveLetter = 'C:'; ProtectionStatus = 1; Extra = 'not requested' },
                [pscustomobject]@{ DriveLetter = 'D:'; ProtectionStatus = 0; Extra = 'not requested' }
            )
        }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 2
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0

        $first = $result.Traces[0]
        $first.ruleId | Should -Be 'test.wmi'
        $first.platform | Should -Be 'windows'
        $first.locator.kind | Should -Be 'wmi'
        $first.locator.resolved | Should -Be 'root/CIMV2/Security/MicrosoftVolumeEncryption:Win32_EncryptableVolume[0]'
        $first.itemCount | Should -Be 1
        $first.properties.DriveLetter | Should -Be 'C:'
        $first.properties.ProtectionStatus | Should -Be '1'

        $result.Traces[1].locator.resolved | Should -Be 'root/CIMV2/Security/MicrosoftVolumeEncryption:Win32_EncryptableVolume[1]'
        $result.Traces[1].properties.ProtectionStatus | Should -Be '0'

        $calls.Count | Should -Be 1
        $calls[0] | Should -Be 'root/CIMV2/Security/MicrosoftVolumeEncryption|Win32_EncryptableVolume|DriveLetter,ProtectionStatus'
    }

    It 'keeps only the property names the rule lists' {
        $cim = { return @([pscustomobject]@{ DriveLetter = 'C:'; ProtectionStatus = 2; Secret = 'peek' }) }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        $names = @($result.Traces[0].properties.Keys)
        $names | Should -Be @('DriveLetter', 'ProtectionStatus')
    }

    It 'reports a null property instead of dropping the instance' {
        $cim = { return @([pscustomobject]@{ DriveLetter = $null; ProtectionStatus = 1 }) }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 1
        $result.Traces[0].properties.DriveLetter | Should -BeNullOrEmpty
    }

    It 'joins a multi-valued property into one string' {
        $locator = [ordered]@{ kind = 'wmi'; namespace = 'root/CIMV2/Security/MicrosoftTpm'; className = 'Win32_Tpm'; properties = @('SpecVersion') }
        $cim = { return @([pscustomobject]@{ SpecVersion = @('2.0', '1.2') }) }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $locator) -Context $context -Deadline (Get-TestDeadline)

        $result.Traces[0].properties.SpecVersion | Should -Be '2.0, 1.2'
    }

    It 'returns no trace when the class has no instances' {
        $cim = { return @() }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
    }

    It 'records an error when the rule names no properties' {
        $locator = [ordered]@{ kind = 'wmi'; namespace = 'root/CIMV2'; className = 'Win32_Tpm'; properties = @() }
        $cim = { return @() }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $locator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].type | Should -Be 'InvalidRule'
    }

    It 'skips with permission when the namespace denies access' {
        $denied = New-Object -TypeName 'System.UnauthorizedAccessException' -ArgumentList 'Access is denied.'
        $cim = { throw $denied }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 1
        $result.Skips[0].reason | Should -Be 'permission'
        $result.Skips[0].ruleId | Should -Be 'test.wmi'
    }

    It 'skips with permission when CIM only says access is denied' {
        $cim = { throw 'Access is denied.' }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Errors).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'permission'
    }

    It 'skips with unavailable when the class does not exist' {
        $cim = { throw 'Invalid class' }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 1
        $result.Skips[0].reason | Should -Be 'unavailable'
        $result.Skips[0].detail | Should -Match 'Win32_EncryptableVolume'
    }

    It 'skips with unavailable when the namespace does not exist' {
        $cim = { throw 'Invalid namespace' }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        $result.Skips[0].reason | Should -Be 'unavailable'
    }

    It 'records an error for any other CIM failure' {
        $cim = { throw (New-Object -TypeName 'System.InvalidOperationException' -ArgumentList 'the WMI service stopped') }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        @($result.Skips).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].ruleId | Should -Be 'test.wmi'
        $result.Errors[0].message | Should -Match 'WMI service'
    }

    It 'skips with unavailable when the scan has no CIM provider' {
        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context (Get-TestContext -Cim $null) -Deadline (Get-TestDeadline)

        @($result.Traces).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'unavailable'
    }

    It 'returns only a timeout skip when the deadline has passed' {
        $calls = New-Object System.Collections.ArrayList
        $cim = { [void]$calls.Add('called'); return @([pscustomobject]@{ DriveLetter = 'C:' }) }
        $context = Get-TestContext -Cim $cim

        $result = Invoke-TestWmiLocator -Rule (Get-TestRule -Locator $script:volumeLocator) -Context $context -Deadline ([datetime]::UtcNow.AddMinutes(-1))

        @($result.Traces).Count | Should -Be 0
        @($result.Errors).Count | Should -Be 0
        $result.Skips[0].reason | Should -Be 'timeout'
        $calls.Count | Should -Be 0 -Because 'nothing may be queried after the deadline'
    }
}

Describe 'New-VacateCimRunner' {
    It 'returns a scriptblock that queries only the named properties' {
        $runner = InModuleScope Vacate { New-VacateCimRunner }
        $runner | Should -BeOfType [scriptblock]
        ([string]$runner) | Should -Match 'Get-CimInstance'
        ([string]$runner) | Should -Match '-Property'
        ([string]$runner) | Should -Not -Match 'Invoke-CimMethod'
    }
}

Describe 'locator sources' {
    BeforeAll {
        $script:locatorFiles = @(
            'HostInfo.ps1',
            'LocatorInstalledProgram.ps1',
            'LocatorRegistry.ps1',
            'LocatorSystemQuery.ps1',
            'LocatorWmi.ps1'
        )
        $script:srcPrivate = Join-Path $PSScriptRoot '../../src/Vacate/Private'
    }

    It 'never mutate CIM, spawn a process, evaluate code or read the environment' {
        $patterns = @(
            'Invoke-CimMethod', 'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance',
            'Invoke-Expression', 'Add-Type', 'Start-Process', 'SetValue', 'CreateSubKey',
            'DeleteSubKey', 'New-Item', 'Set-ItemProperty'
        )
        $violations = New-Object System.Collections.ArrayList
        foreach ($name in $script:locatorFiles) {
            $path = Join-Path $script:srcPrivate $name
            Test-Path -LiteralPath $path | Should -BeTrue -Because "$name must exist"
            $text = [System.IO.File]::ReadAllText($path)
            if ($text -match '\$env:') { [void]$violations.Add("$name reads an environment variable") }
            foreach ($pattern in $patterns) {
                if ($text -match [regex]::Escape($pattern)) { [void]$violations.Add("$name uses $pattern") }
            }
        }
        @($violations) | Should -BeNullOrEmpty
    }

    It 'stays ASCII only' {
        $violations = New-Object System.Collections.ArrayList
        foreach ($name in $script:locatorFiles) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:srcPrivate $name))
            foreach ($character in $text.ToCharArray()) {
                if ([int]$character -gt 127) {
                    [void]$violations.Add("$name contains a non-ASCII character")
                    break
                }
            }
        }
        @($violations) | Should -BeNullOrEmpty
    }
}

Describe 'live CIM query' {
    It 'reads Win32_OperatingSystem Caption from this machine' -Tag 'Live' -Skip:($script:runtimePlatform -ne 'windows') {
        $captions = @(InModuleScope Vacate {
                $runner = New-VacateCimRunner
                foreach ($instance in @(& $runner 'root/CIMV2' 'Win32_OperatingSystem' ([string[]]@('Caption')))) {
                    [string](Get-VacatePropertyValue -InputObject $instance -Name 'Caption')
                }
            })

        $captions.Count | Should -Be 1 -Because 'one local Windows operating system is expected'
        $captions[0].Length | Should -BeGreaterThan 0
    }
}
