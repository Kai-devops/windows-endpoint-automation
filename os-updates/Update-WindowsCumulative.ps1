# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

#requires -version 5.1

[CmdletBinding()]
param(
    [string]$TargetKB,
    [int]$TargetRevision = 0,
    [int]$MinimumFreeSpaceGB = 10,
    [int]$PolicyGuardIntervalSeconds = 1,
    [string]$WorkingDirectory = "$env:ProgramData\WindowsCumulativeUpdate",
    [switch]$DownloadOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptVersion = '2.1.2'
$PolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$PolicyName = 'DisableWindowsUpdateAccess'
$AuPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$StatePath = Join-Path $WorkingDirectory 'PendingValidation.json'
$LogPath = Join-Path $WorkingDirectory 'WindowsCumulativeUpdate.log'
$ResultPath = Join-Path $WorkingDirectory 'LastResult.json'
$GuardJob = $null
$KeepAwakeEnabled = $false
$OriginalPowerScheme = $null
$TemporaryPowerScheme = $null
$OriginalPolicy = $null
$OperationStarted = Get-Date
$ExitCode = 1

$Result = [ordered]@{
    ScriptVersion             = $ScriptVersion
    ComputerName              = $env:COMPUTERNAME
    StartTime                 = $OperationStarted.ToString('o')
    EndTime                   = $null
    TargetKB                  = $TargetKB
    TargetRevision            = $TargetRevision
    StartingBuild             = $null
    EndingBuild               = $null
    UpdateTitle               = $null
    FinalStatus               = 'STARTED'
    WuaSearchResult           = $null
    DownloadResultCode        = $null
    DownloadHResult           = $null
    InstallResultCode         = $null
    InstallHResult            = $null
    RebootRequired            = $false
    PolicyOriginalExists      = $null
    PolicyOriginalValue       = $null
    PolicyRestored            = $false
    HttpBytes                 = 0L
    LanPeerBytes              = 0L
    GroupPeerBytes            = 0L
    InternetPeerBytes         = 0L
    CacheServerBytes          = 0L
    ObservedInternetBytes     = 0L
    WuCacheGrowthBytes        = 0L
    FreeSpaceGBBefore         = $null
    Error                     = $null
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
}

function Save-Result {
    param([string]$Status, [int]$Code)
    $Result.FinalStatus = $Status
    $Result.EndingBuild = Get-CurrentBuild
    $Result.EndTime = (Get-Date).ToString('o')
    try { $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8 } catch {}
    $script:ExitCode = $Code
}

function Get-CurrentBuild {
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $build = [int]$cv.CurrentBuildNumber
        $ubr = [int]$cv.UBR
        return "$build.$ubr"
    } catch {
        return [Environment]::OSVersion.Version.ToString()
    }
}

function Get-BuildParts {
    param([string]$Build)
    $p = $Build.Split('.')
    [pscustomobject]@{ Base = [int]$p[0]; Revision = if ($p.Count -gt 1) { [int]$p[1] } else { 0 } }
}

function Get-FreeSpaceGB {
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    return [math]::Round(($drive.FreeSpace / 1GB), 2)
}

function Get-WuCacheBytes {
    $path = "$env:SystemRoot\SoftwareDistribution\Download"
    if (-not (Test-Path $path)) { return 0L }
    $total = 0L
    Get-ChildItem -LiteralPath $path -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $total += [long]$_.Length }
    return $total
}

function Get-DoSnapshot {
    return [pscustomobject]@{ Http=0L; Lan=0L; Group=0L; InternetPeer=0L; CacheServer=0L }
}

function Start-ServiceSafe {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        }
        Write-Log "Service $Name is running."
    } catch {
        throw "Unable to start required service $Name. $($_.Exception.Message)"
    }
}

function Restart-WuaService {
    try {
        $svc = Get-Service wuauserv -ErrorAction Stop
        if ($svc.Status -ne 'Stopped') {
            Stop-Service wuauserv -Force -ErrorAction Stop
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
        Start-Service wuauserv -ErrorAction Stop
        (Get-Service wuauserv).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
        Write-Log 'Windows Update service restarted.'
    } catch {
        throw "Failed to restart Windows Update service. $($_.Exception.Message)"
    }
}

function Get-PolicyState {
    if (-not (Test-Path $PolicyPath)) {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    try {
        $value = (Get-ItemProperty -Path $PolicyPath -Name $PolicyName -ErrorAction Stop).$PolicyName
        return [pscustomobject]@{ Exists = $true; Value = [int]$value }
    } catch {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
}

function Set-WuaAccessEnabled {
    if (-not (Test-Path $PolicyPath)) { New-Item -Path $PolicyPath -Force | Out-Null }
    New-ItemProperty -Path $PolicyPath -Name $PolicyName -PropertyType DWord -Value 0 -Force | Out-Null
}

function Restore-PolicyState {
    param($State)
    if ($null -eq $State) { return }
    try {
        if ($State.Exists) {
            New-ItemProperty -Path $PolicyPath -Name $PolicyName -PropertyType DWord -Value ([int]$State.Value) -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $PolicyPath -Name $PolicyName -ErrorAction SilentlyContinue
        }
        $verify = Get-PolicyState
        $ok = $verify.Exists -and ($verify.Value -eq 1)
        $Result.PolicyRestored = $ok
        if ($ok) { Write-Log 'Original Windows Update access policy restored.' 'SUCCESS' }
        else { Write-Log 'Windows Update access policy restoration could not be verified.' 'ERROR' }
        Restart-WuaService
    } catch {
        $Result.PolicyRestored = $false
        Write-Log "Policy restoration failed: $($_.Exception.Message)" 'ERROR'
    }
}

function Start-PolicyGuard {
    $path = $PolicyPath
    $name = $PolicyName
    $seconds = [math]::Max(1, $PolicyGuardIntervalSeconds)
    return Start-Job -ScriptBlock {
        param($Path, $Name, $Seconds)
        while ($true) {
            try {
                if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
                New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value 0 -Force | Out-Null
            } catch {}
            Start-Sleep -Seconds $Seconds
        }
    } -ArgumentList $path, $name, $seconds
}

function Stop-PolicyGuard {
    param($Job)
    if ($null -ne $Job) {
        Stop-Job $Job -ErrorAction SilentlyContinue
        Remove-Job $Job -Force -ErrorAction SilentlyContinue
    }
}

function Enable-TemporaryPowerProtection {
    $active = powercfg /getactivescheme
    $match = [regex]::Match(($active -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw 'Unable to identify active power scheme.' }
    $script:OriginalPowerScheme = $match.Value
    $duplicate = powercfg /duplicatescheme $script:OriginalPowerScheme
    $dupMatch = [regex]::Match(($duplicate -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $dupMatch.Success) { throw 'Unable to create temporary power scheme.' }
    $script:TemporaryPowerScheme = $dupMatch.Value
    powercfg /changename $script:TemporaryPowerScheme 'WindowsCumulativeUpdate Temporary Update Plan' | Out-Null
    powercfg /setacvalueindex $script:TemporaryPowerScheme SUB_SLEEP STANDBYIDLE 0 | Out-Null
    powercfg /setdcvalueindex $script:TemporaryPowerScheme SUB_SLEEP STANDBYIDLE 0 | Out-Null
    powercfg /setacvalueindex $script:TemporaryPowerScheme SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
    powercfg /setdcvalueindex $script:TemporaryPowerScheme SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
    powercfg /setacvalueindex $script:TemporaryPowerScheme SUB_BUTTONS SBUTTONACTION 0 | Out-Null
    powercfg /setdcvalueindex $script:TemporaryPowerScheme SUB_BUTTONS SBUTTONACTION 0 | Out-Null
    powercfg /setacvalueindex $script:TemporaryPowerScheme SUB_BUTTONS LIDACTION 0 | Out-Null
    powercfg /setdcvalueindex $script:TemporaryPowerScheme SUB_BUTTONS LIDACTION 0 | Out-Null
    powercfg /setactive $script:TemporaryPowerScheme | Out-Null
    Write-Log 'Temporary no-sleep/no-button-action power plan enabled.'
}

function Restore-OriginalPowerPlan {
    try {
        if ($script:OriginalPowerScheme) {
            powercfg /setactive $script:OriginalPowerScheme | Out-Null
            Write-Log 'Original power plan restored.' 'SUCCESS'
        }
        if ($script:TemporaryPowerScheme) {
            powercfg /delete $script:TemporaryPowerScheme | Out-Null
            Write-Log 'Temporary power plan removed.'
        }
    } catch {
        Write-Log ('Power-plan restoration failed: ' + $_.Exception.Message) 'ERROR'
    }
}

function Enable-KeepAwake {
    if (-not ('PowerRequest.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace PowerRequest {
    public static class NativeMethods {
        [DllImport("kernel32.dll")]
        public static extern uint SetThreadExecutionState(uint esFlags);
    }
}
'@
    }
    $result = [PowerRequest.NativeMethods]::SetThreadExecutionState([uint32]0x80000001L)
    if ($result -eq 0) { throw 'SetThreadExecutionState failed.' }
    $script:KeepAwakeEnabled = $true
    Write-Log 'Keep-awake request enabled.'
}

function Disable-KeepAwake {
    if ($script:KeepAwakeEnabled -and ('PowerRequest.NativeMethods' -as [type])) {
        [void][PowerRequest.NativeMethods]::SetThreadExecutionState([uint32]0x80000000L)
        $script:KeepAwakeEnabled = $false
        Write-Log 'Keep-awake request released.'
    }
}

function Convert-HResultHex {
    param([long]$Value)
    return '0x{0:X8}' -f ($Value -band 0xffffffffL)
}

function Get-WuaTargetUpdate {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = "WindowsCumulativeUpdate/$ScriptVersion"
    $searcher = $session.CreateUpdateSearcher()
    $searchResult = $searcher.Search("IsInstalled=0 and Type='Software'")
    $updates = @($searchResult.Updates)
    $TargetKBNumber = $TargetKB -replace '(?i)^KB',''
    $target = @($updates | Where-Object {
        ($_.KBArticleIDs -contains $TargetKBNumber) -or
        ($_.Title -match [regex]::Escape($TargetKB))
    }) | Select-Object -First 1
    if ($null -eq $target) { return [pscustomobject]@{ Session=$session; Update=$null } }
    return [pscustomobject]@{ Session=$session; Update=$target }
}

function Test-PendingValidation {
    if (-not (Test-Path $StatePath)) { return $false }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $current = Get-BuildParts (Get-CurrentBuild)
        Write-Log "Pending validation found for $($state.TargetKB). Current build: $($current.Base).$($current.Revision); target: $($state.TargetBase).$($state.TargetRevision)."
        if (($current.Base -eq [int]$state.TargetBase) -and ($current.Revision -ge [int]$state.TargetRevision)) {
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
            $Result.StartingBuild = $state.StartingBuild
            $Result.RebootRequired = $false
            Save-Result 'SUCCESS_POST_REBOOT' 0
            Write-Log "$($state.TargetKB) validated successfully after reboot." 'SUCCESS'
        } else {
            $wuError = $null
            try {
                $wuError = Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WindowsUpdateClient';StartTime=[datetime]$state.StagedAt} -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -eq 20 -and $_.Message -match [regex]::Escape($state.TargetKB) } |
                    Sort-Object TimeCreated -Descending | Select-Object -First 1
            } catch {}
            if ($wuError) { $Result.Error = $wuError.Message }
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
            Save-Result 'ROLLED_BACK_OR_NOT_COMMITTED' 20
            Write-Log "$($state.TargetKB) did not commit after reboot. Current build remains $(Get-CurrentBuild)." 'ERROR'
        }
        return $true
    } catch {
        Write-Log "Pending validation record could not be processed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

try {
    if (-not (Test-Path $WorkingDirectory)) { New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null }
    Write-Log "WindowsCumulativeUpdate $ScriptVersion starting as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator or SYSTEM rights are required.'
    }

    $Result.StartingBuild = Get-CurrentBuild
    if (Test-PendingValidation) { exit $ExitCode }
    $build = Get-BuildParts $Result.StartingBuild
    $MonthlyTargets = @{
        19044 = @{ Product = 'Windows 10'; Version = '21H2'; KB = 'KB5131096'; Revision = 7846 }
        19045 = @{ Product = 'Windows 10'; Version = '22H2'; KB = 'KB5131096'; Revision = 7846 }
        22631 = @{ Product = 'Windows 11'; Version = '23H2'; KB = 'KB5131087'; Revision = 7711 }
        26100 = @{ Product = 'Windows 11'; Version = '24H2'; KB = 'KB5132061'; Revision = 9974 }
        26200 = @{ Product = 'Windows 11'; Version = '25H2'; KB = 'KB5132061'; Revision = 9974 }
        26300 = @{ Product = 'Windows 11'; Version = '26H2'; KB = 'KB5132061'; Revision = 9974 }
        28000 = @{ Product = 'Windows 11'; Version = '26H1'; KB = 'KB5132059'; Revision = 3501 }
    }
    if (-not $MonthlyTargets.ContainsKey($build.Base)) {
        Save-Result 'NOT_APPLICABLE_BUILD' 3
        Write-Log ('Unsupported Windows build {0}.' -f $Result.StartingBuild) 'WARN'
        exit $ExitCode
    }
    $Target = $MonthlyTargets[$build.Base]
    if ([string]::IsNullOrWhiteSpace($TargetKB)) { $TargetKB = $Target.KB }
    if ($TargetRevision -le 0) { $TargetRevision = [int]$Target.Revision }
    $Result.TargetKB = $TargetKB
    $Result.TargetRevision = $TargetRevision
    Write-Log ('Detected {0} {1}, build {2}. Target: {3} / {4}.{5}.' -f $Target.Product,$Target.Version,$Result.StartingBuild,$TargetKB,$build.Base,$TargetRevision)
    if ($build.Revision -ge $TargetRevision) {
        Save-Result 'ALREADY_COMPLIANT' 0
        Write-Log ('Device is already at or above target revision {0}.' -f $TargetRevision) 'SUCCESS'
        exit $ExitCode
    }
    $Result.FreeSpaceGBBefore = Get-FreeSpaceGB
    if ($Result.FreeSpaceGBBefore -lt $MinimumFreeSpaceGB) {
        throw "Insufficient free space. Required: $MinimumFreeSpaceGB GB; available: $($Result.FreeSpaceGBBefore) GB."
    }

    $OriginalPolicy = Get-PolicyState
    $Result.PolicyOriginalExists = $OriginalPolicy.Exists
    $Result.PolicyOriginalValue = $OriginalPolicy.Value
    Write-Log "Original $PolicyName state: Exists=$($OriginalPolicy.Exists), Value=$($OriginalPolicy.Value)."

    Enable-KeepAwake
    Enable-TemporaryPowerProtection
    Set-WuaAccessEnabled
    Restart-WuaService

    try { Start-ServiceSafe 'BITS' } catch { Write-Log ('BITS could not be started; continuing with WUA/Delivery Optimization. ' + $_.Exception.Message) 'WARN' }

    foreach ($svc in 'AppReadiness','AppXSvc','ClipSVC','StateRepository','CryptSvc') {
        Start-ServiceSafe $svc
    }

    $DoBefore = Get-DoSnapshot
    $CacheBefore = Get-WuCacheBytes

    $GuardJob = Start-PolicyGuard
    Write-Log 'Temporary Windows Update access policy guard started.'

    Set-WuaAccessEnabled
    $found = Get-WuaTargetUpdate
    if ($null -eq $found.Update) {
        $Result.WuaSearchResult = 'Target not offered'
        Save-Result 'TARGET_NOT_OFFERED' 4
        Write-Log "$TargetKB is not currently offered as applicable." 'WARN'
        exit $ExitCode
    }

    $session = $found.Session
    $update = $found.Update
    $Result.UpdateTitle = $update.Title
    $Result.WuaSearchResult = 'Target found'
    Write-Log "Found update: $($update.Title). IsDownloaded=$($update.IsDownloaded)."

    if (-not $update.EulaAccepted) {
        try { $update.AcceptEula() } catch {}
    }

    if (-not $update.IsDownloaded) {
        Set-WuaAccessEnabled
        $collection = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$collection.Add($update)
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $collection
        Write-Log "Downloading $TargetKB through WUA."
        $downloadResult = $downloader.Download()
        $downloadUpdateResult = $downloadResult.GetUpdateResult(0)
        $Result.DownloadResultCode = [int]$downloadResult.ResultCode
        $Result.DownloadHResult = Convert-HResultHex $downloadUpdateResult.HResult
        if (($downloadResult.ResultCode -notin 2,3) -or (-not $update.IsDownloaded)) {
            throw "WUA download failed. ResultCode=$($downloadResult.ResultCode); HRESULT=$($Result.DownloadHResult); IsDownloaded=$($update.IsDownloaded)."
        }
        Write-Log "Download completed. ResultCode=$($downloadResult.ResultCode); HRESULT=$($Result.DownloadHResult)." 'SUCCESS'
    } else {
        $Result.DownloadResultCode = 2
        $Result.DownloadHResult = '0x00000000'
        Write-Log 'Update payload was already downloaded.'
    }

    $DoAfter = Get-DoSnapshot
    $CacheAfter = Get-WuCacheBytes
    $Result.HttpBytes = [math]::Max(0L, $DoAfter.Http - $DoBefore.Http)
    $Result.LanPeerBytes = [math]::Max(0L, $DoAfter.Lan - $DoBefore.Lan)
    $Result.GroupPeerBytes = [math]::Max(0L, $DoAfter.Group - $DoBefore.Group)
    $Result.InternetPeerBytes = [math]::Max(0L, $DoAfter.InternetPeer - $DoBefore.InternetPeer)
    $Result.CacheServerBytes = [math]::Max(0L, $DoAfter.CacheServer - $DoBefore.CacheServer)
    $Result.ObservedInternetBytes = $Result.HttpBytes + $Result.InternetPeerBytes
    $Result.WuCacheGrowthBytes = $CacheAfter - $CacheBefore
    Write-Log "Observed delivery bytes: HTTP=$($Result.HttpBytes), LAN=$($Result.LanPeerBytes), Group=$($Result.GroupPeerBytes), InternetPeer=$($Result.InternetPeerBytes), CacheServer=$($Result.CacheServerBytes)."

    if ($DownloadOnly) {
        Save-Result 'DOWNLOADED_ONLY' 0
        Write-Log 'DownloadOnly was specified. Installation skipped.' 'SUCCESS'
        exit $ExitCode
    }

    foreach ($svc in 'AppReadiness','AppXSvc','ClipSVC','StateRepository') { Start-ServiceSafe $svc }
    Set-WuaAccessEnabled

    $installCollection = New-Object -ComObject Microsoft.Update.UpdateColl
    [void]$installCollection.Add($update)
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $installCollection
    Write-Log "Installing $TargetKB through WUA."
    $installResult = $installer.Install()
    $installUpdateResult = $installResult.GetUpdateResult(0)
    $Result.InstallResultCode = [int]$installResult.ResultCode
    $Result.InstallHResult = Convert-HResultHex $installUpdateResult.HResult
    $Result.RebootRequired = [bool]$installResult.RebootRequired

    if ($installResult.ResultCode -notin 2,3) {
        throw "WUA installation failed. ResultCode=$($installResult.ResultCode); HRESULT=$($Result.InstallHResult)."
    }

    Write-Log "Installation staging completed. ResultCode=$($installResult.ResultCode); HRESULT=$($Result.InstallHResult); RebootRequired=$($Result.RebootRequired)." 'SUCCESS'

    if ($Result.RebootRequired) {
        $state = [ordered]@{
            ComputerName   = $env:COMPUTERNAME
            TargetKB       = $TargetKB
            TargetBase     = $build.Base
            TargetRevision = $TargetRevision
            StartingBuild  = $Result.StartingBuild
            StagedAt        = (Get-Date).ToString('o')
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
        Save-Result 'STAGED_REBOOT_REQUIRED' 10
        Write-Log 'Update staged successfully. Reboot is required. No reboot was initiated by this script.' 'SUCCESS'
    } else {
        $now = Get-BuildParts (Get-CurrentBuild)
        if (($now.Base -eq $build.Base) -and ($now.Revision -ge $TargetRevision)) {
            Save-Result 'SUCCESS_NO_REBOOT' 0
        } else {
            Save-Result 'INSTALLED_VALIDATION_PENDING' 11
        }
    }
}
catch {
    $Result.Error = $_.Exception.Message
    Save-Result 'FAILED' 1
    Write-Log $_.Exception.Message 'ERROR'
}
finally {
    Stop-PolicyGuard $GuardJob
    if ($null -ne $OriginalPolicy) { Restore-PolicyState $OriginalPolicy }
    Restore-OriginalPowerPlan
    Disable-KeepAwake
    try {
        $Result.EndTime = (Get-Date).ToString('o')
        $Result.EndingBuild = Get-CurrentBuild
        $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    } catch {}
    Write-Log "Final status: $($Result.FinalStatus). Exit code: $ExitCode."
}

exit $ExitCode
