# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

#requires -version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Audit','Remediate')]
    [string]$Mode = 'Audit',

    [ValidateRange(1,500)] [int]$MinimumFreeGB = 40,
    [ValidateRange(1,500)] [int]$TargetFreeGB = 45,
    [ValidateRange(1,60)]  [int]$LargeFileGB = 2,
    [ValidateRange(1,100)] [int]$LargeFolderGB = 5,
    [ValidateRange(1,365)] [int]$TempRetentionDays = 7,
    [ValidateRange(1,100)] [int]$OversizedOstGB = 10,
    [ValidateRange(1,90)]  [int]$DeferredTaskExpiryDays = 14,
    [ValidateRange(1,365)] [int]$ReportRetentionDays = 30,

    [switch]$ApplyOutlookCachePolicy,
    [switch]$AllowOstDeletion,

    [switch]$ForceDeepScan
)

if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem -and $PSCommandPath) {
    $relaunch = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $relaunch += "-$($kv.Key)" } }
        else { $relaunch += "-$($kv.Key)"; $relaunch += [string]$kv.Value }
    }
    & "$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @relaunch
    exit $LASTEXITCODE
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($TargetFreeGB -lt $MinimumFreeGB) {
    Write-Host "ERROR: TargetFreeGB ($TargetFreeGB) must be >= MinimumFreeGB ($MinimumFreeGB)."
    exit 2
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'ERROR: must run elevated (Administrator or SYSTEM).'; exit 3 }

$ToolName        = 'StorageRemediation'
$ReportRoot      = Join-Path $env:ProgramData $ToolName
$RunStamp        = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunRoot         = Join-Path $ReportRoot ("{0}_{1}" -f $env:COMPUTERNAME,$RunStamp)
$LogPath         = Join-Path $RunRoot 'StorageRemediation.log'
$SummaryPath     = Join-Path $RunRoot 'Summary.json'
$LargeFileCsv    = Join-Path $RunRoot 'LargeFiles.csv'
$LargeFolderCsv  = Join-Path $RunRoot 'LargeFolders.csv'
$ProfileCsv      = Join-Path $RunRoot 'Profiles.csv'
$OstCsv          = Join-Path $RunRoot 'OutlookDataFiles.csv'
$ActionCsv       = Join-Path $RunRoot 'Actions.csv'
$DeferredRoot    = Join-Path $ReportRoot 'DeferredOutlook'
$DeferredScript  = Join-Path $DeferredRoot 'Invoke-DeferredOstRebuild.ps1'
$DeferredManifest= Join-Path $DeferredRoot 'OversizedOstTargets.json'
$DeferredExpiry  = Join-Path $DeferredRoot 'ExpiryUtc.txt'
$DeferredTaskName= "$ToolName-DeferredOstRebuild"

$Actions    = New-Object System.Collections.Generic.List[object]
$Warnings   = New-Object System.Collections.Generic.List[string]
$OstTargets = New-Object System.Collections.Generic.List[object]

$script:SkipFileMask = 0x1000 -bor 0x40000 -bor 0x400000

function Write-Log {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR','ACTION','PASS')][string]$Level='INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $line
    if ($LogPath -and (Test-Path -LiteralPath (Split-Path -Path $LogPath -Parent))) {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
}

function Add-ActionRecord {
    param([string]$Action,[string]$Path,[double]$BeforeGB,[double]$AfterGB,[string]$Result,[string]$Detail='')
    $Actions.Add([pscustomobject]@{
        Time=(Get-Date); Action=$Action; Path=$Path; BeforeGB=$BeforeGB; AfterGB=$AfterGB
        ReclaimedGB=[math]::Round([math]::Max(0,($BeforeGB-$AfterGB)),2); Result=$Result; Detail=$Detail
    })
}

function Initialize-SecureRoot {

    param([Parameter(Mandatory)][string]$Path)
    $adminsAndSystem = @('S-1-5-18','S-1-5-32-544')
    if (Test-Path -LiteralPath $Path) {
        $item  = Get-Item -LiteralPath $Path -Force
        $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($owner -notin $adminsAndSystem)) {
            throw "Refusing to use '$Path': reparse point or not owned by SYSTEM/Administrators (owner SID $owner)."
        }
    } else {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        & icacls.exe $Path /setowner '*S-1-5-32-544' | Out-Null
    }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on '$Path' (exit $LASTEXITCODE)" }
}

function Get-FreeGB {
    $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    if (-not $d) { throw "Could not query free space for $env:SystemDrive" }
    [math]::Round(($d.FreeSpace / 1GB),2)
}

function Test-PathHasNoReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $current = $Path.TrimEnd('\')
    while ($current -and $current.Length -gt 3) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $item) { return $false }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $current = Split-Path -Path $current -Parent
    }
    return $true
}

function Get-SafeItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[ValidateSet('File','Directory')][string]$Type='File')
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (-not (Test-PathHasNoReparsePoint -Path $Path)) { return }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dirPath = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo -ArgumentList $dirPath
            foreach ($e in $di.EnumerateFileSystemInfos()) {
                $attr = [int]$e.Attributes
                if ($e -is [System.IO.DirectoryInfo]) {
                    if ($attr -band 0x400) { continue }
                    $stack.Push($e.FullName)
                    if ($Type -eq 'Directory') { $e }
                } elseif ($Type -eq 'File') {
                    if ($attr -band $script:SkipFileMask) { continue }
                    $e
                }
            }
        } catch { }
    }
}

function Get-PathSizeGB {
    param([Parameter(Mandatory)][string]$Path)
    $sum = [int64]0
    Get-SafeItem -Path $Path -Type File | ForEach-Object { $sum += $_.Length }
    [math]::Round(($sum / 1GB),2)
}

function Remove-OldFilesSafely {
    param([Parameter(Mandatory)][string]$Path,[int]$OlderThanDays,[string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (-not (Test-PathHasNoReparsePoint -Path $Path)) {
        $Warnings.Add("Skipped '$Path': path contains a junction/symlink.")
        return
    }
    $before = Get-PathSizeGB -Path $Path
    if ($Mode -eq 'Audit') {
        Add-ActionRecord -Action $Label -Path $Path -BeforeGB $before -AfterGB $before -Result 'AuditOnly' -Detail "Would remove files older than $OlderThanDays days; locked files skipped."
        return
    }
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $removed = 0
    Get-SafeItem -Path $Path -Type File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $removed++ } catch { }
        }
    Get-SafeItem -Path $Path -Type Directory |
        Sort-Object FullName -Descending |
        ForEach-Object {
            try {
                if ($_.LastWriteTime -lt $cutoff -and -not ($_.EnumerateFileSystemInfos() | Select-Object -First 1)) {
                    $_.Delete()
                }
            } catch { }
        }
    $after = Get-PathSizeGB -Path $Path
    Add-ActionRecord -Action $Label -Path $Path -BeforeGB $before -AfterGB $after -Result 'Completed' -Detail "Removed $removed old files; locked files skipped."
}

function Remove-OldReportRuns {
    $cutoff = (Get-Date).AddDays(-$ReportRetentionDays)
    Get-ChildItem -LiteralPath $ReportRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '_\d{8}_\d{6}$' -and $_.LastWriteTime -lt $cutoff -and $_.FullName -ne $RunRoot } |
        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { } }
}

function Get-RealProfiles {
    $excluded = @('Default','Default User','Public','All Users','defaultuser0','WDAGUtilityAccount')
    Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Special -and $_.LocalPath -like "$env:SystemDrive\Users\*" -and
            (Split-Path $_.LocalPath -Leaf) -notin $excluded -and
            (Test-Path -LiteralPath $_.LocalPath)
        }
}

function Invoke-InUserHive {
    param(
        [Parameter(Mandatory)]$UserProfile,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    $sid = [string]$UserProfile.SID
    $hkuPath = "Registry::HKEY_USERS\$sid"
    $loadedHere = $false
    try {
        if (-not (Test-Path $hkuPath)) {
            $ntUser = Join-Path $UserProfile.LocalPath 'NTUSER.DAT'
            if (-not (Test-Path -LiteralPath $ntUser)) { throw "NTUSER.DAT not found" }
            & reg.exe load "HKU\$sid" "$ntUser" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg load failed with exit code $LASTEXITCODE" }
            $loadedHere = $true
        }
        & $ScriptBlock $sid
    } finally {
        if ($loadedHere) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$sid" | Out-Null
        }
    }
}

function Set-OutlookThreeMonthCache {
    param([Parameter(Mandatory)]$UserProfile)
    try {
        Invoke-InUserHive -UserProfile $UserProfile -ScriptBlock {
            param($sid)
            $policy = "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode"
            if (-not (Test-Path $policy)) { New-Item -Path $policy -Force | Out-Null }
            New-ItemProperty -Path $policy -Name 'SyncWindowSetting' -PropertyType DWord -Value 3 -Force | Out-Null
            Remove-ItemProperty -Path $policy -Name 'SyncWindowSettingDays' -Force -ErrorAction SilentlyContinue
        }
        Add-ActionRecord -Action 'Set Outlook cache window' -Path $UserProfile.LocalPath -BeforeGB 0 -AfterGB 0 -Result 'Completed' -Detail 'Classic Outlook policy set to 3 months; Outlook restart required.'
    } catch {
        $msg = "Could not set Outlook cache policy for $($UserProfile.LocalPath): $($_.Exception.Message)"
        $Warnings.Add($msg); Write-Log $msg 'WARN'
    }
}

function Get-OutlookDataFiles {
    param([Parameter(Mandatory)]$UserProfile)
    $outlookPath = Join-Path $UserProfile.LocalPath 'AppData\Local\Microsoft\Outlook'
    if (-not (Test-Path -LiteralPath $outlookPath -PathType Container)) { return }
    if (-not (Test-PathHasNoReparsePoint -Path $outlookPath)) { return }
    Get-ChildItem -LiteralPath $outlookPath -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ost','.pst','.nst' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object {
            [pscustomobject]@{
                User=(Split-Path $UserProfile.LocalPath -Leaf)
                SID=[string]$UserProfile.SID
                ProfilePath=$UserProfile.LocalPath
                ProfileLoaded=[bool]$UserProfile.Loaded
                Extension=$_.Extension.ToLowerInvariant()
                FullName=$_.FullName
                SizeGB=[math]::Round($_.Length/1GB,2)
                LastWriteTime=$_.LastWriteTime
                AutomatedAction= if ($_.Extension -ieq '.ost') {'Eligible only if oversized, opted in, and Outlook is closed'} else {'Report only; never delete automatically'}
            }
        }
}

function Clear-NCentralAgentCache {
    $cache = 'C:\ProgramData\MspPlatform\FileCacheServiceAgent\cache'
    $serviceName = 'SolarWinds.MSP.CacheService'
    if (-not (Test-Path -LiteralPath $cache)) { return }
    $before = Get-PathSizeGB -Path $cache
    if ($before -le 0) { return }
    if ($Mode -eq 'Audit') {
        Add-ActionRecord -Action 'Clear N-central agent cache' -Path $cache -BeforeGB $before -AfterGB $before -Result 'AuditOnly' -Detail 'Would stop File Cache Service Agent, clear cache contents, and restart it.'
        return
    }
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $Warnings.Add("N-central cache exists but service $serviceName was not found; cache was not changed.")
        return
    }
    $wasRunning = $svc.Status -eq 'Running'
    try {
        if ($wasRunning) { Stop-Service -Name $serviceName -Force -ErrorAction Stop; (Get-Service $serviceName).WaitForStatus('Stopped',[timespan]::FromSeconds(45)) }
        Get-ChildItem -LiteralPath $cache -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        $Warnings.Add("N-central cache cleanup failed: $($_.Exception.Message)")
    } finally {
        if ($wasRunning) {
            try {
                Start-Service -Name $serviceName -ErrorAction Stop
                (Get-Service $serviceName).WaitForStatus('Running',[timespan]::FromSeconds(45))
            } catch {
                $Warnings.Add("CRITICAL: File Cache Service Agent did not return to Running: $($_.Exception.Message)")
            }
        }
    }
    $after = Get-PathSizeGB -Path $cache
    $status = (Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    Add-ActionRecord -Action 'Clear N-central agent cache' -Path $cache -BeforeGB $before -AfterGB $after -Result 'Completed' -Detail "Service status after cleanup: $status"
}

function Invoke-ComponentCleanup {
    if ($Mode -ne 'Remediate') { return }
    if ((Get-FreeGB) -ge $TargetFreeGB) { return }
    Write-Log 'Running supported DISM StartComponentCleanup (ResetBase is intentionally not used).' 'ACTION'
    $before = Get-FreeGB
    $p = Start-Process -FilePath "$env:WINDIR\System32\dism.exe" -ArgumentList '/Online','/Cleanup-Image','/StartComponentCleanup','/NoRestart' -Wait -PassThru -WindowStyle Hidden
    $after = Get-FreeGB
    $ok = $p.ExitCode -in 0,3010
    Add-ActionRecord -Action 'DISM StartComponentCleanup' -Path 'Windows component store' -BeforeGB $before -AfterGB $after -Result $(if($ok){'Completed'}else{"ExitCode $($p.ExitCode)"}) -Detail $(if($p.ExitCode -eq 3010){'Reboot required to finish.'}else{'Standard component cleanup only; no ResetBase.'})
}

function New-DeferredOstTask {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Targets)
    if ($Targets.Count -eq 0) { return }

    $Targets | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $DeferredManifest -Encoding UTF8
    (Get-Date).ToUniversalTime().AddDays($DeferredTaskExpiryDays).ToString('o') | Set-Content -LiteralPath $DeferredExpiry -Encoding ASCII

    $helperTemplate = @'
#requires -version 5.1
$ErrorActionPreference = 'Stop'
$TaskName   = '__TASKNAME__'
$Root       = '__ROOT__'
$Manifest   = Join-Path $Root 'OversizedOstTargets.json'
$Log        = Join-Path $Root 'DeferredOstRebuild.log'
$ExpiryFile = Join-Path $Root 'ExpiryUtc.txt'
$SysDrive   = $env:SystemDrive
function Log([string]$m) { Add-Content -LiteralPath $Log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m) -Encoding UTF8 }
function Remove-Self {
    Remove-Item -LiteralPath $Manifest,$ExpiryFile -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
try {
    if (-not (Test-Path -LiteralPath $Manifest)) { Log 'Manifest missing; removing task.'; Remove-Self; exit 0 }
    if (Test-Path -LiteralPath $ExpiryFile) {
        $expiry = [datetime]::Parse((Get-Content -LiteralPath $ExpiryFile -Raw).Trim(),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        if ((Get-Date).ToUniversalTime() -ge $expiry.ToUniversalTime()) { Log 'Deferred action expired; no OST files were changed.'; Remove-Self; exit 0 }
    }
    if (Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue) { exit 0 }

    $targets = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $free = [math]::Round((Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$SysDrive'").FreeSpace / 1GB,2)
    $remaining = @()
    foreach ($t in $targets) {
        try {
            $free = [math]::Round((Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$SysDrive'").FreeSpace / 1GB,2)
            $path = [string]$t.FullName
            if ($free -ge [double]$t.CancelIfFreeGB) { Log "SKIP free space recovered ($free GB): $path"; continue }
            if ($path -notmatch '^[A-Za-z]:\\Users\\[^\\]+\\AppData\\Local\\Microsoft\\Outlook\\[^\\]+\.ost$') { Log "SKIP path validation failed: $path"; continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Log "Already absent: $path"; continue }
            $cur = $path; $bad = $false
            while ($cur.Length -gt 3) {
                $i = Get-Item -LiteralPath $cur -Force
                if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { $bad = $true; break }
                $cur = Split-Path -Path $cur -Parent
            }
            if ($bad) { Log "SKIP junction/symlink in path: $path"; continue }
            $file = Get-Item -LiteralPath $path -Force
            if (($file.Length/1GB) -lt [double]$t.MinimumSizeGB) { Log "SKIP below threshold: $path"; continue }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Log ('Deleted validated OST and reclaimed {0:N2} GB: {1}' -f ($file.Length/1GB),$path)
        } catch { Log "FAILED $($t.FullName): $($_.Exception.Message)"; $remaining += $t }
    }
    if ($remaining.Count -eq 0) {
        Log 'All eligible OST targets processed; one-time task removed.'
        Remove-Self
    } else {
        ($remaining | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Manifest -Encoding UTF8
        Log "$($remaining.Count) target(s) remain for retry."
    }
} catch { Log "FATAL: $($_.Exception.Message) | Line: $($_.InvocationInfo.ScriptLineNumber) | Code: $($_.InvocationInfo.Line) | Stack: $($_.ScriptStackTrace)"; exit 1 }
'@
    $helper = $helperTemplate.Replace('__TASKNAME__',$DeferredTaskName).Replace('__ROOT__',$DeferredRoot)
    Set-Content -LiteralPath $DeferredScript -Value $helper -Encoding UTF8

    $action    = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$DeferredScript`""
    $trigger   = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days ($DeferredTaskExpiryDays + 1))
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $DeferredTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'One-time deferred deletion of validated oversized Exchange OST files after Outlook exits. Never touches PST files.' -Force | Out-Null
    Add-ActionRecord -Action 'Create deferred OST rebuild task' -Path $DeferredTaskName -BeforeGB 0 -AfterGB 0 -Result 'Completed' -Detail "$($Targets.Count) target(s); checks every 5 minutes; expires after $DeferredTaskExpiryDays days."
}

function Get-DeepStorageReport {
    param([array]$Profiles)
    Write-Log 'Collecting exact large-file and deep-folder report. This is read-only.' 'INFO'
    $roots = @("$env:SystemDrive\ProgramData","$env:WINDIR\Temp","$env:SystemDrive\Temp") + @($Profiles | ForEach-Object { $_.LocalPath })
    if ($ForceDeepScan) { $roots = @("$env:SystemDrive\") }
    $roots = @($roots | Select-Object -Unique)

    $rootSet = @{}
    foreach ($r in $roots) { $rootSet[$r.TrimEnd('\')] = $true }

    $largeFiles = New-Object 'System.Collections.Generic.List[object]'
    $direct = @{}

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Write-Log "Scanning $root" 'INFO'
        Get-SafeItem -Path $root -Type File | ForEach-Object {
            if ($_.Length -ge ($LargeFileGB * 1GB)) {
                $largeFiles.Add([pscustomobject]@{
                    FullName=$_.FullName; SizeGB=[math]::Round($_.Length/1GB,2)
                    Extension=$_.Extension; LastWriteTime=$_.LastWriteTime
                })
            }
            $k = $_.DirectoryName
            if ($direct.ContainsKey($k)) { $direct[$k] += $_.Length } else { $direct[$k] = [int64]$_.Length }
        }
    }

    $largeFiles | Sort-Object SizeGB -Descending | Export-Csv -LiteralPath $LargeFileCsv -NoTypeInformation -Encoding UTF8

    $totals = @{}
    foreach ($kv in $direct.GetEnumerator()) {
        $key = $kv.Key; $size = [int64]$kv.Value
        while ($key) {
            if ($totals.ContainsKey($key)) { $totals[$key] += $size } else { $totals[$key] = $size }
            if ($rootSet.ContainsKey($key.TrimEnd('\'))) { break }
            $key = [System.IO.Path]::GetDirectoryName($key)
        }
    }

    $folderRows = @($totals.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{
            FullName=$_.Key
            SizeGB=[math]::Round($_.Value/1GB,2)
            Depth=(($_.Key.TrimEnd('\') -split '\\').Count-1)
        }
    } | Where-Object { $_.SizeGB -ge $LargeFolderGB } |
        Sort-Object @{Expression='SizeGB';Descending=$true},@{Expression='Depth';Descending=$true})

    $selected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $folderRows) {
        $prefix = $row.FullName.TrimEnd('\') + '\'
        $dominantChild = $folderRows | Where-Object {
            $_.Depth -eq ($row.Depth + 1) -and $_.SizeGB -ge ($row.SizeGB * 0.90) -and
            $_.FullName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if (-not $dominantChild -or $row.Depth -ge 5) { $selected.Add($row) }
    }
    $selected | Sort-Object SizeGB -Descending | Export-Csv -LiteralPath $LargeFolderCsv -NoTypeInformation -Encoding UTF8
}

$mutex = $null; $hasMutex = $false; $exitCode = 0
try {
    $mutex = New-Object System.Threading.Mutex($false,"Global\$ToolName")
    try { $hasMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
    if (-not $hasMutex) {
        Write-Host "Another $ToolName instance is already running; exiting."
        $exitCode = 4
    } else {
        Initialize-SecureRoot -Path $ReportRoot
        New-Item -Path $RunRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $DeferredRoot -ItemType Directory -Force | Out-Null
        Remove-OldReportRuns

        Write-Log "$ToolName started in $Mode mode on $env:COMPUTERNAME." 'INFO'
        $freeBefore = Get-FreeGB
        Write-Log "$env:SystemDrive free before: $freeBefore GB; minimum: $MinimumFreeGB GB; target: $TargetFreeGB GB." 'INFO'

        $profiles = @(Get-RealProfiles)
        $profileRows = foreach ($p in $profiles) {
            [pscustomobject]@{
                User=(Split-Path $p.LocalPath -Leaf); SID=[string]$p.SID; LocalPath=$p.LocalPath
                Loaded=[bool]$p.Loaded; LastUseTime=$p.LastUseTime; SizeGB=(Get-PathSizeGB -Path $p.LocalPath)
            }
        }
        $profileRows | Sort-Object SizeGB -Descending | Export-Csv -LiteralPath $ProfileCsv -NoTypeInformation -Encoding UTF8

        $outlookFiles = @(foreach ($p in $profiles) { Get-OutlookDataFiles -UserProfile $p })
        $outlookFiles | Sort-Object SizeGB -Descending | Export-Csv -LiteralPath $OstCsv -NoTypeInformation -Encoding UTF8
        $ostSids = @($outlookFiles | Where-Object { $_.Extension -eq '.ost' } | ForEach-Object { $_.SID } | Select-Object -Unique)

        foreach ($p in $profiles) {
            if ($ostSids -notcontains [string]$p.SID) { continue }
            if ($Mode -eq 'Remediate' -and $ApplyOutlookCachePolicy) {
                Set-OutlookThreeMonthCache -UserProfile $p
            } else {
                $res = if ($Mode -eq 'Audit') {'AuditOnly'} else {'Skipped'}
                Add-ActionRecord -Action 'Set Outlook cache window' -Path $p.LocalPath -BeforeGB 0 -AfterGB 0 -Result $res -Detail 'Would enforce 3-month Classic Outlook policy (requires -ApplyOutlookCachePolicy in Remediate mode).'
            }
        }

        foreach ($f in @($outlookFiles | Where-Object { $_.Extension -eq '.ost' -and $_.SizeGB -ge $OversizedOstGB })) {
            $OstTargets.Add([pscustomobject]@{
                User=$f.User; SID=$f.SID; ProfilePath=$f.ProfilePath; FullName=$f.FullName
                ObservedSizeGB=$f.SizeGB; MinimumSizeGB=$OversizedOstGB; CancelIfFreeGB=$TargetFreeGB
            })
        }

        if ($freeBefore -lt $MinimumFreeGB -or $Mode -eq 'Audit') {
            Clear-NCentralAgentCache
            Remove-OldFilesSafely -Path "$env:WINDIR\Temp" -OlderThanDays $TempRetentionDays -Label 'Clean Windows Temp'
            Remove-OldFilesSafely -Path "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -OlderThanDays $TempRetentionDays -Label 'Clean WER ReportArchive'
            Remove-OldFilesSafely -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -OlderThanDays $TempRetentionDays -Label 'Clean WER ReportQueue'
            Remove-OldFilesSafely -Path "$env:WINDIR\Minidump" -OlderThanDays 30 -Label 'Clean old minidumps'
            foreach ($p in $profiles) {
                Remove-OldFilesSafely -Path (Join-Path $p.LocalPath 'AppData\Local\Temp') -OlderThanDays $TempRetentionDays -Label "Clean user Temp: $(Split-Path $p.LocalPath -Leaf)"
                Remove-OldFilesSafely -Path (Join-Path $p.LocalPath 'AppData\Local\CrashDumps') -OlderThanDays 30 -Label "Clean user CrashDumps: $(Split-Path $p.LocalPath -Leaf)"
            }
            Invoke-ComponentCleanup
        }

        $deferredQueued = $false
        if ($OstTargets.Count -gt 0) {
            if ($Mode -eq 'Audit') {
                Add-ActionRecord -Action 'Create deferred OST rebuild task' -Path $DeferredTaskName -BeforeGB 0 -AfterGB 0 -Result 'AuditOnly' -Detail "$($OstTargets.Count) oversized OST target(s) would be queued if free space stays below $MinimumFreeGB GB and -AllowOstDeletion is set."
            } elseif (-not $AllowOstDeletion) {
                $Warnings.Add("$($OstTargets.Count) oversized OST file(s) found; -AllowOstDeletion not specified, nothing queued.")
            } elseif ((Get-FreeGB) -ge $MinimumFreeGB) {
                Write-Log 'Free space is above minimum after cleanup; OST rebuild not queued.' 'INFO'
            } else {
                New-DeferredOstTask -Targets $OstTargets.ToArray()
                $deferredQueued = $true
            }
        }

        Get-DeepStorageReport -Profiles $profiles

        $freeAfter = Get-FreeGB
        $Actions | Export-Csv -LiteralPath $ActionCsv -NoTypeInformation -Encoding UTF8

        $pendingGB = 0
        if ($deferredQueued) { $pendingGB = [math]::Round((($OstTargets | Measure-Object -Property ObservedSizeGB -Sum).Sum),2) }

        $summary = [ordered]@{
            Tool=$ToolName; Computer=$env:COMPUTERNAME; Mode=$Mode; Started=$RunStamp
            MinimumFreeGB=$MinimumFreeGB; TargetFreeGB=$TargetFreeGB
            FreeBeforeGB=$freeBefore; FreeAfterGB=$freeAfter; NetReclaimedGB=[math]::Round(($freeAfter-$freeBefore),2)
            ProfilesScanned=$profiles.Count; OversizedOstTargets=$OstTargets.Count
            DeferredTaskQueued=$deferredQueued; PendingOstReclaimGB=$pendingGB
            DeferredTaskName= if($deferredQueued){$DeferredTaskName}else{$null}
            ReportFolder=$RunRoot; Warnings=@($Warnings)
            Result= if($freeAfter -ge $MinimumFreeGB){'PASS'}else{'ATTENTION_REQUIRED'}
        }
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8

        Write-Log "$env:SystemDrive free after: $freeAfter GB. Net change: $([math]::Round(($freeAfter-$freeBefore),2)) GB." 'PASS'
        if ($deferredQueued) { Write-Log "Deferred OST deletion queued; up to $pendingGB GB more may be reclaimed once Outlook is closed." 'INFO' }
        Write-Log "Reports: $RunRoot" 'INFO'
        Write-Log "Result: $($summary.Result)" $(if($summary.Result -eq 'PASS'){'PASS'}else{'WARN'})
        if ($Warnings.Count -gt 0) { $Warnings | ForEach-Object { Write-Log $_ 'WARN' } }

        if ($summary.Result -ne 'PASS') { $exitCode = 1001 }
    }
} catch {
    try { Write-Log "FATAL: $($_.Exception.Message) | Line: $($_.InvocationInfo.ScriptLineNumber) | Code: $($_.InvocationInfo.Line) | Stack: $($_.ScriptStackTrace)" 'ERROR' } catch { Write-Host "FATAL: $($_.Exception.Message) | Line: $($_.InvocationInfo.ScriptLineNumber) | Code: $($_.InvocationInfo.Line) | Stack: $($_.ScriptStackTrace)" }
    $exitCode = 1
} finally {
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    if ($mutex) { $mutex.Dispose() }
}
exit $exitCode
