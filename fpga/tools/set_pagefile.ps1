# Size the C: pagefile explicitly instead of leaving it to Windows.
#
# On this machine (8 GB RAM) the automatic setting produced 1792 MB, so the
# commit limit was ~9.8 GB. A Quartus map or a runaway simulation then did not
# fail with an allocation error: Windows logged a low-virtual-memory condition
# and bugchecked (event log: vvp.exe holding 28 GB, bugcheck 0xa5). An explicit
# initial size that fits the disk gives a commit limit the build cannot walk
# past silently.
#
# Takes effect at the next reboot. Run elevated.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/set_pagefile.ps1
#   ... -InitialMB 16384 -MaximumMB 32768      (defaults)
#   ... -Revert                                (back to system-managed)
param(
    [int]$InitialMB = 16384,
    [int]$MaximumMB = 32768,
    [string]$Drive = 'C:',
    [switch]$Revert
)

function Show-State($label) {
    $cs = Get-CimInstance Win32_ComputerSystem
    $use = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    $set = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
    Write-Output "--- $label"
    Write-Output ("automatic-managed : {0}" -f $cs.AutomaticManagedPagefile)
    foreach ($u in $use) {
        Write-Output ("in use            : {0}  allocated {1} MB, peak {2} MB" -f $u.Name, $u.AllocatedBaseSize, $u.PeakUsage)
    }
    foreach ($s in $set) {
        Write-Output ("configured        : {0}  initial {1} MB, max {2} MB" -f $s.Name, $s.InitialSize, $s.MaximumSize)
    }
    if (-not $set) { Write-Output "configured        : (none - Windows chooses the size)" }
    $ram = [int]($cs.TotalPhysicalMemory / 1MB)
    Write-Output ("physical RAM      : {0} MB" -f $ram)
}

Show-State 'before'

$cs = Get-CimInstance Win32_ComputerSystem

if ($Revert) {
    if (-not $cs.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
        Write-Output "restored system-managed pagefile"
    } else {
        Write-Output "already system-managed; nothing to do"
    }
    Show-State 'after'
    exit 0
}

$disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Drive)
$freeMB = [int]($disk.FreeSpace / 1MB)
if ($freeMB -lt ($MaximumMB + 4096)) {
    Write-Output ("REFUSED: only {0} MB free on {1}; need {2} MB plus 4 GB headroom" -f $freeMB, $Drive, $MaximumMB)
    exit 2
}

# An explicit setting and automatic management are mutually exclusive.
if ($cs.AutomaticManagedPagefile) {
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
    Write-Output "turned off automatic pagefile management"
}

$name = "$Drive\pagefile.sys"

# Win32_PageFileSetting takes UInt32 sizes; without the cast New-CimInstance and
# Set-CimInstance both fail with "Type mismatch" and the value silently stays 0
# (0/0 is 'system managed', i.e. exactly what we are replacing).
$want = @{ InitialSize = [uint32]$InitialMB; MaximumSize = [uint32]$MaximumMB }

function Find-Setting([string]$n) {
    # a WQL -Filter on this class needs the backslashes doubled; matching in
    # PowerShell avoids that entirely
    Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $n }
}

$pf = Find-Setting $name
if (-not $pf) {
    New-CimInstance -ClassName Win32_PageFileSetting -Property @{
        Name        = $name
        InitialSize = [uint32]$InitialMB
        MaximumSize = [uint32]$MaximumMB
    } -ErrorAction Stop | Out-Null
    Write-Output ("created {0}" -f $name)
    $pf = Find-Setting $name
}
if ($pf) {
    Set-CimInstance -InputObject $pf -Property $want -ErrorAction Stop
}

# read it back: the only thing that matters is what is stored
$pf = Find-Setting $name
if (-not $pf -or $pf.InitialSize -ne $InitialMB -or $pf.MaximumSize -ne $MaximumMB) {
    Write-Output ("FAILED: stored size is {0}/{1} MB, wanted {2}/{3}" -f `
        $(if ($pf) { $pf.InitialSize } else { '-' }), $(if ($pf) { $pf.MaximumSize } else { '-' }), `
        $InitialMB, $MaximumMB)
    Show-State 'after (FAILED)'
    exit 3
}
Write-Output ("{0} set to {1} MB initial / {2} MB max" -f $name, $pf.InitialSize, $pf.MaximumSize)

Show-State 'after (takes effect at the next reboot)'
Write-Output ""
Write-Output ("Commit limit after reboot will be about {0} MB of RAM plus {1} MB of pagefile." -f `
    [int]($cs.TotalPhysicalMemory / 1MB), $InitialMB)
