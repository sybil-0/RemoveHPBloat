<#
============================================================================
 Remove-HPBloatware.ps1  -  HP Pavilion Gaming / Windows 11 de-bloat
 ---------------------------------------------------------------------------
 Removes HP Inc. / OMEN bloatware DRIVER PACKAGES plus the matching software
 layer (services, scheduled tasks, Store apps, autoruns) and then blocks
 Windows Update from silently re-delivering them.

 REMOVAL TARGETS (14 driver packages, matched by ORIGINAL inf name so the
 script works even if oemNN numbering changed since the dump was taken):
   dxp_metadata_universal_driver_x64_extension.inf   HP device metadata popups
   hdx_hpext_hsa.inf                                 Realtek-for-HP audio ext
   hdx_hpext_srold_rtkold.inf                        Realtek-for-HP audio ext (stale)
   hpanalyticsext.inf                                HP Analytics (telemetry)
   hpanalyticscomp.inf                               HP Touchpoint Analytics
   hpaudiocenterhsa.inf                              HP Audio Center
   hpcustomcapdriver.inf / hpcustomcapext.inf / hpcustomcapcomp.inf
                                                     HP Custom Capabilities
   hpomencustomcapdriver.inf / hpomencustomcapext.inf / hpomencustomcapcomp.inf
                                                     OMEN Gaming Hub stack
   hpygid20_v4.inf                                   HP printer class driver
   vigembusext.inf                                   HP virtual gamepad (OMEN)

 PROTECTED: 08860f21.inf (HP firmware capsule = BIOS updates via Windows
 Update). Pass -RemoveFirmware only if you REALLY want that gone too.

 USAGE
   1) Dry run (changes nothing, writes HP_Driver_Audit.csv + transcript):
        powershell -ExecutionPolicy Bypass -File .\Remove-HPBloatware.ps1 -DryRun
   2) Real run (asks for confirmation, or use -AcceptAll):
        powershell -ExecutionPolicy Bypass -File .\Remove-HPBloatware.ps1
   Optional switches:
        -SkipDriverBackup   skip exporting all 3rd-party drivers first
        -SkipAppx           leave HP/OMEN Store apps installed
        -SkipWin32Apps      leave desktop apps (HP Support Assistant etc.) alone
        -RemoveFirmware     also delete the HP firmware capsule (not advised)
        -AcceptAll          no interactive confirmation
        -Restart            reboot automatically when finished

 WHAT YOU LOSE (expected):
   - OMEN/Pavilion Gaming Hub fan curves + performance modes (fans fall back
     to firmware defaults), HP hotkey extras, HP Audio Center enhancements,
     HP Support Assistant, HP Analytics telemetry, HP metadata popups.
 WHAT KEEPS WORKING:
   - Base Realtek audio (hdxcpc.inf kept), Ethernet/Wi-Fi/Bluetooth,
     NVIDIA GPU + HDMI audio, Intel chipset/ME/DPTF thermals, peripherals.

 ROLLBACK (all backups land on your Desktop under HP_Bloatware_Removal_*):
   Drivers : pnputil /add-driver "<dir>\DriverStoreExport\*.inf" /subdirs /install
   Services: import the .reg files in <dir>\RegBackup (reboot)
   Tasks   : Register-ScheduledTask -Xml (Get-Content <dir>\TaskBackup\x.xml)

 MUST be run from an elevated PowerShell on the target machine.
============================================================================
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipDriverBackup,
    [switch]$SkipAppx,
    [switch]$SkipWin32Apps,
    [switch]$RemoveFirmware,
    [switch]$AcceptAll,
    [switch]$Restart
)

$ErrorActionPreference = 'Continue'

# ----------------------------------------------------------------- logging
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $ts, $Message) -ForegroundColor $color
}

# ----------------------------------------------------------------- targets
$script:RemoveInfs = @(
    'dxp_metadata_universal_driver_x64_extension.inf',
    'hdx_hpext_hsa.inf',
    'hdx_hpext_srold_rtkold.inf',
    'hpanalyticsext.inf',
    'hpanalyticscomp.inf',
    'hpaudiocenterhsa.inf',
    'hpcustomcapdriver.inf',
    'hpcustomcapext.inf',
    'hpcustomcapcomp.inf',
    'hpomencustomcapdriver.inf',
    'hpomencustomcapext.inf',
    'hpomencustomcapcomp.inf',
    'hpygid20_v4.inf',
    'vigembusext.inf'
)

$script:CategoryMap = @{
    'dxp_metadata_universal_driver_x64_extension.inf' = 'HP device metadata extension (popups/info)'
    'hdx_hpext_hsa.inf'                               = 'Realtek-for-HP audio extension'
    'hdx_hpext_srold_rtkold.inf'                      = 'Realtek-for-HP audio extension (stale copy)'
    'hpanalyticsext.inf'                              = 'HP Analytics extension (telemetry)'
    'hpanalyticscomp.inf'                             = 'HP Touchpoint Analytics client (telemetry)'
    'hpaudiocenterhsa.inf'                            = 'HP Audio Center software component'
    'hpcustomcapdriver.inf'                           = 'HP Custom Capabilities kernel driver'
    'hpcustomcapext.inf'                              = 'HP Custom Capabilities extension'
    'hpcustomcapcomp.inf'                             = 'HP Custom Capabilities service host'
    'hpomencustomcapdriver.inf'                       = 'OMEN Gaming Hub kernel driver'
    'hpomencustomcapext.inf'                          = 'OMEN Gaming Hub extension'
    'hpomencustomcapcomp.inf'                         = 'OMEN Gaming Hub capability service (OmenCap)'
    'hpygid20_v4.inf'                                 = 'HP printer class driver'
    'vigembusext.inf'                                 = 'HP virtual gamepad extension (OMEN)'
}

# HP firmware capsule (BIOS via WU) - kept unless -RemoveFirmware
$script:ProtectedInfs = @('08860f21.inf')

# service name/display patterns
$script:SvcNameRegex = '^(hp|hpq|omen|touchpoint)'
$script:SvcDispRegex = '\b(HP|OMEN)\b|Touchpoint'

# scheduled task path/name pattern
$script:TaskRegex = 'hp|hewlett|omen|touchpoint'

# Store app name patterns
$script:AppxPatterns = @('HP*', '*OMEN*', 'AD2F2B6B*')

# Win32 uninstall display-name pattern
$script:Win32Regex = 'HP Support Assistant|Support Solutions Framework|HP Analytics|HP System Event|HP Documentation|HP QuickDrop|HP Notifications|HP Hotkey|Hotkey Support|HP Audio|OMEN|HP Easy Clean|HP Print and Scan|HP CoolSense|HP Welcome|HP Setup|HP Connection Manager|HP Sure Connect|HP WorkWell|HP System Default|HP Registration|HP Support Framework|HP Privacy Settings|Touchpoint'

# ----------------------------------------------------------------- checks
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: Run this script from an ELEVATED PowerShell (Run as Administrator).' -ForegroundColor Red
    exit 1
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host 'ERROR: PowerShell 5.1 or newer is required.' -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------- folders
$script:Stamp        = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:BaseDir      = Join-Path ([Environment]::GetFolderPath('Desktop')) ("HP_Bloatware_Removal_{0}" -f $script:Stamp)
$script:DriverBackup = Join-Path $script:BaseDir 'DriverStoreExport'
$script:RegBackup    = Join-Path $script:BaseDir 'RegBackup'
$script:TaskBackup   = Join-Path $script:BaseDir 'TaskBackup'
$script:AuditCsv     = Join-Path $script:BaseDir 'HP_Driver_Audit.csv'
New-Item -ItemType Directory -Path $script:DriverBackup, $script:RegBackup, $script:TaskBackup -Force | Out-Null

# ------------------------------------------------- driver inventory parsing
function Get-DriverInventory {
    # Parses "pnputil /enum-drivers" positionally (works on localized systems),
    # with Get-WindowsDriver as fallback.
    $packages = New-Object System.Collections.Generic.List[object]
    $raw = & pnputil.exe /enum-drivers 2>$null
    if ($raw) {
        $blocks = New-Object System.Collections.Generic.List[object]
        $cur = New-Object System.Collections.Generic.List[string]
        foreach ($line in $raw) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                if ($cur.Count -gt 0) { $blocks.Add(@($cur.ToArray())); $cur = New-Object System.Collections.Generic.List[string] }
            } else {
                $cur.Add(($line -replace '\s+$', ''))
            }
        }
        if ($cur.Count -gt 0) { $blocks.Add(@($cur.ToArray())) }

        foreach ($b in $blocks) {
            if ($b.Count -lt 4) { continue }
            $pub = $null; $orig = $null; $prov = $null; $cls = $null; $ver = $null
            $origIdx = -1
            for ($i = 0; $i -lt $b.Count; $i++) {
                $t = $b[$i]
                if (-not $pub -and $t -match '(oem\d+\.inf)') { $pub = $Matches[1]; continue }
                if ($pub -and $origIdx -lt 0 -and $t -match '([A-Za-z0-9_\-\.]+\.inf)' -and $Matches[1] -notmatch '^oem\d+\.inf$') {
                    $orig = $Matches[1]; $origIdx = $i; continue
                }
                if ($t -match '\d{2}/\d{2}/\d{4}\s+([0-9\.]+)') { $ver = $Matches[1] }
            }
            if ($origIdx -ge 0 -and $b.Count -gt ($origIdx + 2)) {
                $pv = $b[$origIdx + 1]; $cv = $b[$origIdx + 2]
                if ($pv -match '^[^:]+:\s*(.*)$') { $prov = $Matches[1].Trim() } else { $prov = $pv.Trim() }
                if ($cv -match '^[^:]+:\s*(.*)$') { $cls = $Matches[1].Trim() } else { $cls = $cv.Trim() }
            }
            if ($pub -and $orig) {
                $packages.Add([pscustomobject]@{
                    Published = $pub; Original = $orig; Provider = $prov; Class = $cls; Version = $ver
                })
            }
        }
    }
    if ($packages.Count -eq 0) {
        Write-Log 'pnputil parse came back empty - falling back to Get-WindowsDriver' 'WARN'
        try {
            foreach ($d in (Get-WindowsDriver -Online -ErrorAction Stop)) {
                if ("$($d.Driver)" -notmatch '^oem\d+\.inf$') { continue }
                $orig = "$($d.OriginalFileName)"
                try {
                    $full = Get-WindowsDriver -Online -Driver $d.Driver -ErrorAction Stop
                    if ($full.OriginalFileName) { $orig = Split-Path -Leaf "$($full.OriginalFileName)" }
                } catch { }
                $packages.Add([pscustomobject]@{
                    Published = $d.Driver; Original = (Split-Path -Leaf $orig); Provider = $d.ProviderName; Class = $d.ClassName; Version = $d.Version
                })
            }
        } catch {
            Write-Log ("Get-WindowsDriver fallback failed: {0}" -f $_.Exception.Message) 'ERROR'
        }
    }
    return ,$packages
}

# ------------------------------------------------- device -> INF mapping
function Get-DeviceInfMap {
    $map = @{}
    $all = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
    foreach ($d in $all) {
        try {
            $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop).Data
        } catch { continue }
        if (-not $inf) { continue }
        $k = "$inf".ToLowerInvariant()
        if (-not $map.ContainsKey($k)) { $map[$k] = New-Object System.Collections.Generic.List[object] }
        $map[$k].Add($d)
    }
    return $map
}

# ------------------------------------------------- restore point
function New-RestorePoint {
    Write-Log 'Creating a system restore point...' 'STEP'
    if ($DryRun) { Write-Log '[DRYRUN] Would create a restore point'; return }
    try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue } catch { }
    try {
        Checkpoint-Computer -Description 'HP Bloatware Removal' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created.' 'OK'
    } catch {
        Write-Log ("Could not create a restore point (System Restore disabled or 24h limit?). Continuing. Details: {0}" -f $_.Exception.Message) 'WARN'
    }
}

# ------------------------------------------------- full driver backup
function Backup-DriverStore {
    if ($SkipDriverBackup) {
        Write-Log 'Skipping driver backup (-SkipDriverBackup). There is NO driver rollback if something breaks.' 'WARN'
        return $true
    }
    Write-Log ("Exporting ALL third-party drivers to: {0} (can take a few minutes)" -f $script:DriverBackup) 'STEP'
    if ($DryRun) { Write-Log '[DRYRUN] Would run: dism /Online /Export-Driver'; return $true }
    $out = & dism.exe /Online /Export-Driver /Destination:"$($script:DriverBackup)" 2>&1
    foreach ($l in @($out)) { if ("$l".Trim()) { Write-Log ("  dism: {0}" -f "$l".Trim()) } }
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'Driver backup FAILED - aborting before any removal. Nothing was changed.' 'ERROR'
        return $false
    }
    Write-Log 'Driver backup complete.' 'OK'
    return $true
}

# ------------------------------------------------- driver removal
function Invoke-DriverRemoval {
    param([object[]]$Targets, [hashtable]$DevMap)
    Write-Log '--- Driver removal (disable devices, then delete + uninstall packages) ---' 'STEP'
    $ok = 0; $bad = 0
    foreach ($t in $Targets) {
        Write-Log ("Target {0}  <- {1}" -f $t.Published, $t.Category)
        $key = "$($t.Published)".ToLowerInvariant()
        $devs = $null
        if ($DevMap -and $DevMap.ContainsKey($key)) { $devs = $DevMap[$key] }
        if ($devs) {
            foreach ($d in $devs) {
                $hw = ''
                try { $hw = ((Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop).Data) -join '; ' } catch { }
                Write-Log ("  device: {0}  [{1}]" -f $d.FriendlyName, $d.InstanceId)
                if ($hw) { Write-Log ("    HWIDs: {0}" -f $hw) }
                if ($DryRun) {
                    Write-Log '    [DRYRUN] would disable this device'
                } else {
                    try {
                        Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
                        Write-Log '    device disabled' 'OK'
                    } catch {
                        Write-Log ("    disable failed: {0}" -f $_.Exception.Message) 'WARN'
                    }
                }
            }
        } else {
            Write-Log '  no present devices currently bound to this package (extension/software component)'
        }
        if ($DryRun) {
            Write-Log ("  [DRYRUN] would run: pnputil /delete-driver {0} /uninstall /force" -f $t.Published)
        } else {
            $out = & pnputil.exe /delete-driver $t.Published /uninstall /force 2>&1
            foreach ($l in @($out)) { if ("$l".Trim()) { Write-Log ("    pnputil: {0}" -f "$l".Trim()) } }
            if ($LASTEXITCODE -eq 0) { $ok++; Write-Log '  package deleted and uninstalled' 'OK' }
            else { $bad++; Write-Log ("  pnputil exited with code {0}" -f $LASTEXITCODE) 'ERROR' }
        }
    }
    Write-Log ("Driver removal finished: {0} ok, {1} failed." -f $ok, $bad) 'STEP'
}

# ------------------------------------------------- services sweep
function Invoke-ServiceSweep {
    Write-Log '--- Services sweep (HP/OMEN services) ---' 'STEP'
    $svcs = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        ("$($_.Name)" -match $script:SvcNameRegex) -or ("$($_.DisplayName)" -match $script:SvcDispRegex)
    }
    if (-not $svcs) { Write-Log 'No HP/OMEN services found.'; return }
    foreach ($s in $svcs) {
        Write-Log ("Service: {0}  ({1})  State={2} StartMode={3}" -f $s.Name, $s.DisplayName, $s.State, $s.StartMode)
        if ($DryRun) { Write-Log '  [DRYRUN] would backup, disable and delete this service'; continue }
        $safe = "$($s.Name)" -replace '[^\w\-\.]', '_'
        & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\$($s.Name)" (Join-Path $script:RegBackup ("svc_{0}.reg" -f $safe)) /y 2>$null | Out-Null
        try { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue } catch { }
        try { Set-Service -Name $s.Name -StartupType Disabled -ErrorAction SilentlyContinue } catch { }
        & sc.exe delete "$($s.Name)" | Out-Null
        Write-Log '  stopped / disabled / delete queued (takes full effect after reboot)' 'OK'
    }
}

# ------------------------------------------------- scheduled tasks sweep
function Invoke-TaskSweep {
    Write-Log '--- Scheduled task sweep (HP/OMEN/Touchpoint) ---' 'STEP'
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        ("$($_.TaskPath)" -match $script:TaskRegex) -or ("$($_.TaskName)" -match $script:TaskRegex)
    }
    if (-not $tasks) { Write-Log 'No HP/OMEN scheduled tasks found.'; return }
    foreach ($t in $tasks) {
        Write-Log ("Task: {0}{1}  State={2}" -f $t.TaskPath, $t.TaskName, $t.State)
        if ($DryRun) { Write-Log '  [DRYRUN] would export, disable and delete this task'; continue }
        $safe = ("{0}{1}" -f $t.TaskPath, $t.TaskName) -replace '[^\w\-\.]', '_'
        try {
            $xml = Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
            $xml | Out-File -FilePath (Join-Path $script:TaskBackup ("{0}.xml" -f $safe)) -Encoding Unicode
        } catch { }
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Log '  deleted' 'OK'
        } catch {
            try {
                Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
                Write-Log '  delete failed -> disabled instead' 'WARN'
            } catch { Write-Log ("  failed: {0}" -f $_.Exception.Message) 'ERROR' }
        }
    }
}

# ------------------------------------------------- Store app sweep
function Invoke-AppxSweep {
    Write-Log '--- Store app sweep (HP/OMEN Appx) ---' 'STEP'
    $pkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        $n = "$($_.Name)"
        ($n -like 'HP*') -or ($n -like '*OMEN*') -or ($n -like 'AD2F2B6B*')
    }
    foreach ($p in $pkgs) {
        Write-Log ("Appx: {0}  ({1})" -f $p.Name, $p.PackageFullName)
        if ($DryRun) { Write-Log '  [DRYRUN] would remove for all users'; continue }
        try {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
            Write-Log '  removed' 'OK'
        } catch { Write-Log ("  remove failed: {0}" -f $_.Exception.Message) 'WARN' }
    }
    $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {
        $n = "$($_.DisplayName)"
        ($n -like 'HP*') -or ($n -like '*OMEN*') -or ($n -like 'AD2F2B6B*')
    }
    foreach ($pp in $prov) {
        Write-Log ("Provisioned Appx: {0} {1}" -f $pp.DisplayName, $pp.Version)
        if ($DryRun) { Write-Log '  [DRYRUN] would de-provision (so new accounts never get it)'; continue }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
            Write-Log '  de-provisioned' 'OK'
        } catch { Write-Log ("  failed: {0}" -f $_.Exception.Message) 'WARN' }
    }
    if (-not $pkgs -and -not $prov) { Write-Log 'No HP/OMEN Store apps found.' }
}

# ------------------------------------------------- Win32 app sweep
function Invoke-Win32Sweep {
    Write-Log '--- Win32 app sweep (silent uninstall attempts) ---' 'STEP'
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -and ("$($_.DisplayName)" -match $script:Win32Regex)
    }
    if (-not $apps) { Write-Log 'No matching HP/OMEN Win32 apps found.'; return }
    foreach ($a in $apps) {
        Write-Log ("App: {0}  ({1})" -f $a.DisplayName, $a.DisplayVersion)
        if ($DryRun) { Write-Log '  [DRYRUN] would attempt a silent uninstall'; continue }
        $us = $a.QuietUninstallString
        if (-not $us -and "$($a.UninstallString)" -match '(?i)msiexec\.exe') {
            if ("$($a.UninstallString)" -match '\{[0-9A-Fa-f\-]+\}') { $us = "msiexec.exe /x $($Matches[0]) /qn /norestart" }
        }
        if (-not $us) {
            $us = $a.UninstallString
            if ($us -and "$us" -notmatch '(?i)msiexec') { $us = "$us /S" }
        }
        if (-not $us) { Write-Log '  no uninstall string available - skipped' 'WARN'; continue }
        Write-Log ("  running: {0}" -f $us)
        try {
            $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $us" -Wait -PassThru -WindowStyle Hidden
            Write-Log ("  uninstaller exit code: {0}" -f $proc.ExitCode)
        } catch { Write-Log ("  failed: {0}" -f $_.Exception.Message) 'ERROR' }
    }
}

# ------------------------------------------------- autorun sweep
function Invoke-RunKeySweep {
    Write-Log '--- Autorun sweep (Run keys) ---' 'STEP'
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    $sysProps = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    foreach ($k in $keys) {
        if (-not (Test-Path $k)) { continue }
        $regPath = $k -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
        & reg.exe export "$regPath" (Join-Path $script:RegBackup ("run_{0}.reg" -f ($regPath -replace '[^\w]', '_'))) /y 2>$null | Out-Null
        $props = Get-ItemProperty -Path $k
        foreach ($p in $props.PSObject.Properties) {
            if ($sysProps -icontains $p.Name) { continue }
            $hit = ("$($p.Name)" -match $script:SvcNameRegex) -or ("$($p.Value)" -match '\\(HP|OMEN)\\')
            if (-not $hit) { continue }
            Write-Log ("Autorun: {0}\{1} = {2}" -f $k, $p.Name, $p.Value)
            if ($DryRun) { Write-Log '  [DRYRUN] would remove this autorun value'; continue }
            Remove-ItemProperty -Path $k -Name $p.Name -ErrorAction SilentlyContinue
            Write-Log '  removed' 'OK'
        }
    }
}

# ------------------------------------------------- re-install blocking
function Set-ReinstallBlock {
    Write-Log '--- Blocking re-delivery via Windows Update ---' 'STEP'
    $settings = @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';        Name = 'ExcludeWUDriversInQualityUpdate';   Value = 1 },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'; Name = 'SearchOrderConfig';                 Value = 0 },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata';       Name = 'PreventDeviceMetadataFromNetwork';  Value = 1 }
    )
    foreach ($s in $settings) {
        if (-not (Test-Path $s.Path)) { New-Item -Path $s.Path -Force | Out-Null }
        $regPath = $s.Path -replace '^HKLM:', 'HKLM'
        & reg.exe export "$regPath" (Join-Path $script:RegBackup ("policy_{0}.reg" -f ($regPath -replace '[^\w]', '_'))) /y 2>$null | Out-Null
        if ($DryRun) {
            Write-Log ("[DRYRUN] would set {0} -> {1} = {2}" -f $s.Path, $s.Name, $s.Value)
            continue
        }
        New-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -PropertyType DWord -Force | Out-Null
        Write-Log ("Set {0} -> {1} = {2}" -f $s.Path, $s.Name, $s.Value) 'OK'
    }
    Write-Log 'Windows Update will no longer auto-install drivers (GPU/chipset updates are now manual).' 'WARN'
}

# ================================================================= main
Write-Host ''
Write-Log '=== HP / OMEN bloatware removal - HP Pavilion Gaming (Windows 11) ===' 'STEP'
if ($DryRun) { Write-Log 'Mode: DRY RUN - nothing on your system will be changed.' 'WARN' }

Start-Transcript -Path (Join-Path $script:BaseDir 'Transcript.txt') -ErrorAction SilentlyContinue | Out-Null

try {
    Write-Log 'Expected side effects after removal:' 'WARN'
    Write-Log ' - OMEN/Pavilion Gaming Hub fan curves + performance modes are gone (firmware defaults apply)'
    Write-Log ' - HP hotkey extras, HP Audio Center enhancements and HP metadata popups are gone'
    Write-Log ' - HP Support Assistant + HP Analytics telemetry are gone'
    Write-Log ' - Audio (base Realtek), LAN/WiFi/BT, NVIDIA GPU, Intel chipset/thermals: UNTOUCHED'
    Write-Log ("Backup + log folder: {0}" -f $script:BaseDir)

    New-RestorePoint
    if (-not (Backup-DriverStore)) { throw 'Driver backup failed - nothing was removed.' }

    # ---- inventory + classification
    $inventory = Get-DriverInventory
    Write-Log ("Third-party driver packages detected: {0}" -f $inventory.Count)

    $audit = @()
    foreach ($p in $inventory) {
        $o = "$($p.Original)".ToLowerInvariant()
        $verdict = 'KEEP'
        $cat = 'Third-party (out of scope)'
        if ($script:RemoveInfs -icontains $o) {
            $verdict = 'REMOVE'; $cat = "$($script:CategoryMap[$o])"
        } elseif ($script:ProtectedInfs -icontains $o) {
            if ($RemoveFirmware) { $verdict = 'REMOVE'; $cat = 'HP firmware capsule (-RemoveFirmware given)' }
            else { $verdict = 'PROTECTED'; $cat = 'HP firmware capsule (BIOS via WU) - protected' }
        } elseif ("$($p.Original)" -match '(?i)^(hp|omen)') {
            $cat = 'Other HP-related (left alone, review manually)'
        }
        $audit += $p | Select-Object @{ n = 'Verdict'; e = { $verdict } }, @{ n = 'Category'; e = { $cat } }, *
    }
    $audit | Export-Csv -Path $script:AuditCsv -NoTypeInformation -Encoding UTF8

    $rem  = @($audit | Where-Object { $_.Verdict -eq 'REMOVE' })
    $prot = @($audit | Where-Object { $_.Verdict -eq 'PROTECTED' })
    $keep = $audit.Count - $rem.Count - $prot.Count
    Write-Log ("Verdicts - REMOVE: {0}   PROTECTED: {1}   KEEP: {2}" -f $rem.Count, $prot.Count, $keep) 'OK'
    Write-Log ("Full audit written to: {0}" -f $script:AuditCsv)
    foreach ($r in $rem) { Write-Log ("  plan: {0}  <-  {1}" -f $r.Published, $r.Category) }

    # ---- warn about HP printer queues
    $hppr = Get-Printer -ErrorAction SilentlyContinue | Where-Object { "$($_.DriverName)" -match '(?i)\bHP\b' }
    foreach ($q in $hppr) {
        Write-Log ("WARNING: printer queue '{0}' uses HP driver '{1}' - removal may affect printing." -f $q.Name, $q.DriverName) 'WARN'
    }

    # ---- confirmation
    if (-not $DryRun -and -not $AcceptAll) {
        $ans = Read-Host 'Type REMOVE to delete the drivers and run the full software sweep'
        if ($ans -cne 'REMOVE') { Write-Log 'Aborted by user - no changes were made.' 'WARN'; return }
    }

    # ---- execute
    $devMap = Get-DeviceInfMap
    Invoke-DriverRemoval -Targets $rem -DevMap $devMap
    Invoke-ServiceSweep
    Invoke-TaskSweep
    if (-not $SkipAppx)      { Invoke-AppxSweep }
    if (-not $SkipWin32Apps) { Invoke-Win32Sweep }
    Invoke-RunKeySweep
    Set-ReinstallBlock

    Write-Log '=== DONE ===' 'OK'
    Write-Log ("Everything (backups, audit CSV, transcript) is in: {0}" -f $script:BaseDir) 'OK'
    Write-Log 'A REBOOT is strongly recommended to finish service + device cleanup.' 'WARN'
    Write-Log 'Rollback drivers anytime with:'
    Write-Log '  pnputil /add-driver "<BackupDir>\DriverStoreExport\*.inf" /subdirs /install'
}
catch {
    Write-Log ("FATAL: {0}" -f $_.Exception.Message) 'ERROR'
}
finally {
    if ($Restart -and -not $DryRun) { Restart-Computer -Force }
    Stop-Transcript | Out-Null
}
