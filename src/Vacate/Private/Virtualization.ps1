# Virtualization.ps1 - Phase 4: is this a virtual machine, WSL or container? (DECISIONS D54, D57)
# PowerShell 5.1 compatible. ASCII only. Read-only.
# An erase inside a VM or WSL erases a virtual disk while the real computer stays untouched, and the
# erase record would wrongly claim an erase, so readiness blocks unless this returns $false.

$script:VacateVmPattern = '(?i)(virtual machine|vmware|virtualbox|vbox|qemu|kvm|xen|bochs|parallels|hyper-v|apple virtual|utm\b|bhyve|openstack|google compute|amazon ec2)'

function Get-VacateVirtualization {
    <#
    .SYNOPSIS
        Returns { virtualized = $true | $false | $null; evidence }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Platform,
        [scriptblock]$CimRunner,
        [AllowNull()][object]$SystemDisk,
        # Tests only: replaces the OS description and the Linux DMI/container file reads.
        [string]$OsDescription,
        [scriptblock]$ReadSystemFile
    )
    $result = { param($v, $e) [pscustomobject][ordered]@{ virtualized = $v; evidence = $e } }

    # A disk model that names a hypervisor is evidence on every platform.
    if ($null -ne $SystemDisk -and $null -ne $SystemDisk.PSObject.Properties['model'] -and [string]$SystemDisk.model -match $script:VacateVmPattern) {
        return (& $result $true ("system disk model '{0}'" -f $SystemDisk.model))
    }

    switch ($Platform) {
        'windows' {
            if ($null -eq $CimRunner) { return (& $result $null 'no CIM access') }
            try {
                $cs = @(& $CimRunner 'root/CIMV2' 'Win32_ComputerSystem' ([string[]]@('Manufacturer', 'Model')))
            }
            catch { return (& $result $null ('CIM query failed: ' + $_.Exception.Message)) }
            if ($cs.Count -eq 0) { return (& $result $null 'Win32_ComputerSystem returned nothing') }
            $text = ('{0} {1}' -f $cs[0].Manufacturer, $cs[0].Model)
            if ($text -match $script:VacateVmPattern) { return (& $result $true "computer '$text'") }
            return (& $result $false "computer '$text'")
        }
        'linux' {
            $desc = $OsDescription
            if (-not $desc) { $desc = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription }
            if ($desc -match '(?i)microsoft|wsl') { return (& $result $true "WSL kernel '$desc'") }
            $read = $ReadSystemFile
            if ($null -eq $read) {
                $read = {
                    param([string]$p)
                    if (-not [IO.File]::Exists($p)) { return $null }
                    try { return ([IO.File]::ReadAllText($p)).Trim() } catch { return $null }
                }
            }
            $rel = & $read '/proc/sys/kernel/osrelease'
            if ($null -ne $rel -and $rel -match '(?i)microsoft|wsl') { return (& $result $true "WSL kernel '$rel'") }
            if ($null -ne (& $read '/.dockerenv') -or $null -ne (& $read '/run/.containerenv')) { return (& $result $true 'container marker file') }
            $vendor = & $read '/sys/class/dmi/id/sys_vendor'
            $product = & $read '/sys/class/dmi/id/product_name'
            if ($null -eq $vendor -and $null -eq $product) { return (& $result $null 'no DMI information readable') }
            $text = ('{0} {1}' -f $vendor, $product).Trim()
            if ($text -match $script:VacateVmPattern) { return (& $result $true "hardware '$text'") }
            return (& $result $false "hardware '$text'")
        }
        'macos' {
            # macOS exposes no unprivileged hardware-model API without a new binary; the disk model
            # check above is the evidence used (Apple virtual disks and hypervisor disks name themselves).
            if ($null -eq $SystemDisk -or [string]::IsNullOrEmpty([string]$SystemDisk.model)) { return (& $result $null 'system disk model unknown') }
            return (& $result $false ("system disk model '{0}'" -f $SystemDisk.model))
        }
        default { return (& $result $null "unknown platform '$Platform'") }
    }
}
