# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

$LogDir = "C:\ProgramData\YourCompany\Logs"
if (-not (Test-Path $LogDir)) {
  New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogDir ("Update-{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
try {
  Start-Transcript -Path $LogFile -Force | Out-Null
} catch {
  Write-Host "Could not start logging transcript (non-fatal, continuing): $($_.Exception.Message)" -ForegroundColor DarkYellow
}
Get-ChildItem -Path $LogDir -Filter "Update-*.log" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -Skip 10 |
  Remove-Item -Force -ErrorAction SilentlyContinue
$DeviceName = $env:COMPUTERNAME
function Write-Result {
  param([string]$AppName, [string]$Status, [string]$Detail = "")
  Write-Host "WINGET FALLBACK RESULT: $DeviceName - $AppName - $Status $Detail" -ForegroundColor $(
      switch ($Status) { "SUCCESS" {"Green"}; default {"Red"} }
  )
}
try {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class PowerHelper {
  [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
  public static extern uint SetThreadExecutionState(uint esFlags);
}
"@ -ErrorAction SilentlyContinue
  $ES_CONTINUOUS      = [uint32]0x80000000
  $ES_SYSTEM_REQUIRED = [uint32]0x00000001
  [PowerHelper]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
  Write-Host "Sleep prevention active for this run." -ForegroundColor DarkGray
} catch {
  Write-Host "Could not set sleep prevention (non-fatal, continuing): $($_.Exception.Message)" -ForegroundColor DarkYellow
}
$BranchMap = @(
 [PSCustomObject]@{ Name = "Branch01";           Subnet = "<BRANCH01_SUBNET>";           ProbeShare = "\\<BRANCH01_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch02";           Subnet = "<BRANCH02_SUBNET>";           ProbeShare = "\\<BRANCH02_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch03";           Subnet = "<BRANCH03_SUBNET>";           ProbeShare = "\\<BRANCH03_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch04";           Subnet = "<BRANCH04_SUBNET>";           ProbeShare = "\\<BRANCH04_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch05";           Subnet = "<BRANCH05_SUBNET>";           ProbeShare = "\\<BRANCH05_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch06";           Subnet = "<BRANCH06_SUBNET>";           ProbeShare = "\\<BRANCH06_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch07";           Subnet = "<BRANCH07_SUBNET>";           ProbeShare = "\\<BRANCH07_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch08";           Subnet = "<BRANCH08_SUBNET>";           ProbeShare = "\\<BRANCH08_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch09";           Subnet = "<BRANCH09_SUBNET>";           ProbeShare = "\\<BRANCH09_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch10";           Subnet = "<BRANCH10_SUBNET>";           ProbeShare = "\\<BRANCH10_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch11";           Subnet = "<BRANCH11_SUBNET>";           ProbeShare = "\\<BRANCH11_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch12";           Subnet = "<BRANCH12_SUBNET>";           ProbeShare = "\\<BRANCH11_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch13";           Subnet = "<BRANCH13_SUBNET>";           ProbeShare = "\\<BRANCH13_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch14";           Subnet = "<BRANCH14_SUBNET>";           ProbeShare = "\\<BRANCH14_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch15";           Subnet = "<BRANCH15_SUBNET>";           ProbeShare = "\\<BRANCH15_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Branch16";           Subnet = "<BRANCH16_SUBNET>";           ProbeShare = "\\<BRANCH16_PROBE>\Share" }
 [PSCustomObject]@{ Name = "Head Office";        Subnet = "<HEAD_OFFICE_SUBNET>";        ProbeShare = "\\<HEAD_OFFICE_SERVER>\Share" }
 [PSCustomObject]@{ Name = "Head Office Alt1";   Subnet = "<HEAD_OFFICE_ALT1_SUBNET>";   ProbeShare = "\\<HEAD_OFFICE_SERVER>\Share" }
 [PSCustomObject]@{ Name = "Head Office Alt2";   Subnet = "<HEAD_OFFICE_ALT2_SUBNET>";   ProbeShare = "\\<HEAD_OFFICE_SERVER>\Share" }
)
function Get-LocalIPv4 {
 $config = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
           Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway } |
           Select-Object -First 1
 if ($config -and $config.IPv4Address) { return $config.IPv4Address.IPAddress }
 return $null
}
$LocalIP = Get-LocalIPv4
Write-Host "=== Probe Resolution ===" -ForegroundColor Cyan
Write-Host "Detected local IP: $LocalIP"
$MatchedBranch = $null
if ($LocalIP) {
 $ipPrefix = ($LocalIP -split '\.')[0..2] -join '.'
 $MatchedBranch = $BranchMap | Where-Object { $_.Subnet -eq $ipPrefix } | Select-Object -First 1
}
if (-not $MatchedBranch) {
  $MatchedBranch = $BranchMap | Where-Object { $_.Name -eq "Branch02" } | Select-Object -First 1
  Write-Host "No known branch matches this IP ($LocalIP) - defaulting to Branch02 probe as fallback target." -ForegroundColor Yellow
} else {
  Write-Host "Matched branch: $($MatchedBranch.Name) - using probe $($MatchedBranch.ProbeShare)" -ForegroundColor Green
}
$AppsRoot = Join-Path $MatchedBranch.ProbeShare "Applications"
$ProbeAvailable = Test-Path $AppsRoot -ErrorAction SilentlyContinue
if ($ProbeAvailable) {
  Write-Host "Probe reachable: $AppsRoot" -ForegroundColor Green
} else {
  Write-Host "Probe NOT reachable: $AppsRoot" -ForegroundColor Red
  Write-Host "All apps this run will attempt the winget fallback path instead." -ForegroundColor Yellow
}
$FreeSpaceGB = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2)
Write-Host "=== Disk Space Check ===" -ForegroundColor Cyan
Write-Host "C: free space: $FreeSpaceGB GB"
if ($FreeSpaceGB -lt 5) {
 Write-Host "WARNING: Free space is below 5GB. Starting cleanup before updates..." -ForegroundColor Yellow
 try {
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path "$env:SystemRoot\System32\cleanmgr.exe") {
       Start-Process cleanmgr.exe -ArgumentList "/sagerun:1" -Wait
    }
    Start-Sleep -Seconds 10
    $FreeSpaceGB = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2)
    Write-Host "Free space after cleanup: $FreeSpaceGB GB" -ForegroundColor Green
 }
 catch {
    Write-Host "Cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
 }
} else {
 Write-Host "Free space looks OK." -ForegroundColor Green
}
function Get-ChromiumAppVersion {
 param([string]$AppId, [string]$FilePath)
 $regPaths = @(
     "HKLM:\SOFTWARE\WOW6432Node\Google\Update\ClientState\$AppId",
     "HKLM:\SOFTWARE\Google\Update\ClientState\$AppId",
     "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\$AppId",
     "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\$AppId"
 )
 foreach ($path in $regPaths) {
     $val = Get-ItemProperty -Path $path -Name pv -ErrorAction SilentlyContinue
     if ($val) { return $val.pv }
 }
 if ($FilePath -and (Test-Path $FilePath)) { return (Get-Item $FilePath).VersionInfo.FileVersion }
 return $null
}
function Resolve-VersionedInstaller {
 param([string]$FolderPath, [string]$Pattern)
 if (-not (Test-Path $FolderPath)) { return $null }
 $match = Get-ChildItem -Path $FolderPath -Filter $Pattern -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
 if ($match) { return $match.FullName }
 return $null
}
function Get-InstalledAppByDisplayName {
 param([string]$Pattern)
 return Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $Pattern } | Select-Object -First 1
}
function Get-TeamsVersion {
 $pkg = Get-AppxPackage -AllUsers -Name MSTeams -ErrorAction SilentlyContinue | Select-Object -First 1
 if ($pkg -and $pkg.Version) { return $pkg.Version }
 $folder = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Directory -Filter "MSTeams_*_x64__8wekyb3d8bbwe" -ErrorAction SilentlyContinue | Select-Object -First 1
 if ($folder -and $folder.Name -match "MSTeams_(?<ver>[\d\.]+)_x64") { return $Matches['ver'] }
 return $null
}
function Invoke-WingetFallback {
  param($App)
  if (-not $App.WingetId) {
      Write-Host "No WingetId configured for $($App.Name) - cannot attempt winget fallback." -ForegroundColor Red
      Write-Result -AppName $App.Name -Status "FAILED" -Detail "(no WingetId configured)"
      return
  }
  Write-Host "Attempting winget fallback for $($App.Name) [$($App.WingetId)]..."
  $listOutput = & winget list --id $App.WingetId --accept-source-agreements 2>$null
  $foundInWinget = $listOutput | Select-String -SimpleMatch $App.WingetId
  $finalExitCode = $null
  if ($foundInWinget) {
      Write-Host "winget recognizes this app as installed - running upgrade..."
& winget upgrade --id $App.WingetId --silent --accept-package-agreements --accept-source-agreements | Out-Null
      $finalExitCode = $LASTEXITCODE
  } else {
      Write-Host "winget list returned empty for this app - checking local detection..." -ForegroundColor Yellow
      $locallyInstalled = $false
      foreach ($p in $App.DetectPaths) {
          if (Get-Item -Path $p -ErrorAction SilentlyContinue) { $locallyInstalled = $true; break }
      }
      if (-not $locallyInstalled -and $App.DetectRegistryPattern) {
          if (Get-InstalledAppByDisplayName -Pattern $App.DetectRegistryPattern) { $locallyInstalled = $true }
      }
      if ($locallyInstalled) {
          Write-Host "App is installed locally but winget's source doesn't reflect it - refreshing source and retrying upgrade..."
& winget source update | Out-Null
& winget upgrade --id $App.WingetId --silent --accept-package-agreements --accept-source-agreements | Out-Null
          $finalExitCode = $LASTEXITCODE
      } else {
          Write-Host "Not installed locally either - installing fresh via winget..."
& winget install --id $App.WingetId --silent --accept-package-agreements --accept-source-agreements | Out-Null
          $finalExitCode = $LASTEXITCODE
      }
  }
  Write-Host "winget fallback final exit code: $finalExitCode"
  if ($finalExitCode -eq 0 -or $finalExitCode -eq -1978335212) {
      Write-Host "winget fallback succeeded for $($App.Name)." -ForegroundColor Green
      Write-Result -AppName $App.Name -Status "SUCCESS"
  } else {
      Write-Host "winget fallback FAILED for $($App.Name) (exit code $finalExitCode)." -ForegroundColor Red
      Write-Result -AppName $App.Name -Status "FAILED" -Detail "(exit code $finalExitCode)"
  }
}
$Apps = @(
[PSCustomObject]@{
    Name        = "Microsoft Teams"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\WindowsApps\MSTeams_*\ms-teams.exe",
        "C:\Users\*\AppData\Local\Microsoft\WindowsApps\ms-teams.exe"
    )
    SkipInstall  = $true
    WingetId     = "Microsoft.Teams"
    MsiFile      = $null
    ExeFile      = "teamsbootstrapper.exe"
    ExeArgs      = "-p"
    RetryExitCodes = @(-2147009287)
    VersionCheck = { Get-TeamsVersion }
},
[PSCustomObject]@{
    Name        = "Google Chrome"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    WingetId     = "Google.Chrome"
    MsiFile      = "ChromeInstaller.msi"
    ExeFile      = "chrome_installer.exe"
    ExeArgs      = "/silent /install"
    VersionCheck = {
        $exePath = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        Get-ChromiumAppVersion -AppId "{8A69D345-D564-463C-AFF1-A69D9E530F96}" -FilePath $exePath
    }
},
[PSCustomObject]@{
    Name        = "Microsoft Edge"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    WingetId     = "Microsoft.Edge"
    MsiFile      = "MicrosoftEdgeEnterpriseX64.msi"
    ExeFile      = "MicrosoftEdgeSetup.exe"
    ExeArgs      = "/silent /install"
    VersionCheck = {
        $exePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        Get-ChromiumAppVersion -AppId "{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -FilePath $exePath
    }
},
  [PSCustomObject]@{
    Name        = "Adobe Reader DC"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
    )
    WingetId     = "Adobe.Acrobat.Reader.64-bit"
    CustomScript     = "AdobeReaderDC\Deploy-AdobeReaderDC.ps1"
    CustomScriptArgs = "-DeploymentType Install -DeployMode Silent"
    MsiFile     = $null
    ExeFile     = $null
    VersionCheck = {
        $p86 = "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
        $p64 = "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe"
        if (Test-Path $p86) { (Get-Item $p86).VersionInfo.FileVersion }
        elseif (Test-Path $p64) { (Get-Item $p64).VersionInfo.FileVersion }
    }
},
[PSCustomObject]@{
    Name        = "TeamViewer"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\TeamViewer\TeamViewer.exe",
        "${env:ProgramFiles(x86)}\TeamViewer\TeamViewer.exe"
    )
    WingetId     = "TeamViewer.TeamViewer"
    MsiFile      = "TeamViewer_Full.msi"
    ExeArgs      = "/S"
    VersionCheck = {
        $p = "$env:ProgramFiles\TeamViewer\TeamViewer.exe"
        if (Test-Path $p) { (Get-Item $p).VersionInfo.FileVersion }
    }
},
[PSCustomObject]@{
    Name        = "FortiClient VPN"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\Fortinet\FortiClient\FortiClient.exe",
        "${env:ProgramFiles(x86)}\Fortinet\FortiClient\FortiClient.exe"
    )

    WingetId     = "Fortinet.FortiClient"
    MsiFile      = "FortiClientVPN.msi"
    ExeFile      = $null
    VersionCheck = {
        $p64 = "$env:ProgramFiles\Fortinet\FortiClient\FortiClient.exe"
        $p86 = "${env:ProgramFiles(x86)}\Fortinet\FortiClient\FortiClient.exe"
        if (Test-Path $p64) { (Get-Item $p64).VersionInfo.ProductVersion }
        elseif (Test-Path $p86) { (Get-Item $p86).VersionInfo.ProductVersion }
    }
},
[PSCustomObject]@{
    Name        = "Oracle Java SE"
    Enabled     = $true
    DetectRegistryPattern = "Java 8 Update*"
    WingetId     = "Oracle.JavaRuntimeEnvironment"
    MsiFolder    = "OracleJava"
    MsiPattern   = "jre-*-windows-x64.msi"
    ExeFile      = $null
    VersionCheck = {
        $regApp = Get-InstalledAppByDisplayName -Pattern "Java 8 Update*"
        if ($regApp) { $regApp.DisplayVersion }
    }
},
[PSCustomObject]@{
    Name        = "Oracle Java 8"
    Enabled     = $true

    DetectPaths = @(
        "$env:ProgramFiles\Java\jre1.8.0_*\bin\java.exe",
        "${env:ProgramFiles(x86)}\Java\jre1.8.0_*\bin\java.exe"
    )

    DetectRegistryPattern = "Java 8 Update*"

    WingetId = "Oracle.JavaRuntimeEnvironment"

    MsiFile    = $null
    ExeFile    = $null
    ExePattern = "jre-8u*-windows-x64.exe"
    ExeArgs    = "/s REBOOT=0 SPONSORS=0 AUTO_UPDATE=0"

    VersionCheck = {
        $regApp = Get-ItemProperty `
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -like "Java 8 Update*64-bit*"
            } |
            Sort-Object {
                try { [version]$_.DisplayVersion }
                catch { [version]"0.0" }
            } -Descending |
            Select-Object -First 1

        if ($regApp) {
            $regApp.DisplayVersion
        }
    }
},
[PSCustomObject]@{
    Name        = "7-Zip"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\7-Zip\7zFM.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7zFM.exe"
    )
    WingetId     = "7zip.7zip"
    MsiFile      = "7z-x64.msi"
    ExeFile      = "7z-x64.exe"
    ExeArgs      = "/S"
    VersionCheck = {
        $p = "$env:ProgramFiles\7-Zip\7zFM.exe"
        if (Test-Path $p) { (Get-Item $p).VersionInfo.FileVersion }
    }
},
[PSCustomObject]@{
    Name        = "QZ Tray"
    Enabled     = $true
    DetectPaths = @(
        "$env:ProgramFiles\QZ Tray\QZ Tray.exe",
        "${env:ProgramFiles(x86)}\QZ Tray\QZ Tray.exe",
        "$env:ProgramFiles\QZ Tray*\qz-tray.exe",
        "${env:ProgramFiles(x86)}\QZ Tray*\qz-tray.exe"
    )
    DetectRegistryPattern = "*QZ Tray*"
    UseWinget    = $false
    WingetId     = "QZIndustries.QZTray"
    MsiFile      = "QZ Tray.msi"
    ExeFile      = "qz-tray.exe"
    ExeArgs      = "/S"
    VersionCheck = {
        $regApp = Get-InstalledAppByDisplayName -Pattern "*QZ Tray*"
        if ($regApp) { $regApp.DisplayVersion }
    }
}
)
function Test-AppInstalled {
param([string[]]$Paths, [string]$RegistryPattern = $null)
foreach ($p in $Paths) {
    if (Get-Item -Path $p -ErrorAction SilentlyContinue) { return $true }
}
if ($RegistryPattern) {
    if (Get-InstalledAppByDisplayName -Pattern $RegistryPattern) { return $true }
}
return $false
}
function Update-App {
param($App)
Write-Host "`n=== $($App.Name) ===" -ForegroundColor Cyan
if (-not $App.Enabled) {
    Write-Host "Skipped (disabled in config)." -ForegroundColor DarkGray
    return
}
if (-not (Test-AppInstalled -Paths $App.DetectPaths -RegistryPattern $App.DetectRegistryPattern)) {
    Write-Host "Not installed on this machine - skipping." -ForegroundColor Yellow
    return
}
$before = & $App.VersionCheck
Write-Host "Current version: $before"
if ($App.SkipInstall) {
    Write-Host "This app self-updates in the background - reporting version only, no install attempted." -ForegroundColor Cyan
    return
}

if (-not $ProbeAvailable) {
    Invoke-WingetFallback -App $App
    return
}
if ($App.MsiFolder -and $App.MsiPattern) {
    $msiPath = Resolve-VersionedInstaller -FolderPath (Join-Path $AppsRoot $App.MsiFolder) -Pattern $App.MsiPattern
} else {
    $msiPath = if ($App.MsiFile) { Join-Path $AppsRoot $App.MsiFile } else { $null }
}
if ($App.ExePattern) {
    $exeFolderPath = if ($App.ExeFolder) {
        Join-Path $AppsRoot $App.ExeFolder
    } else {
        $AppsRoot
    }

    $exePath = Resolve-VersionedInstaller -FolderPath $exeFolderPath -Pattern $App.ExePattern

    if (-not $exePath) {
        Write-Host "No file matching pattern '$($App.ExePattern)' found in $exeFolderPath" -ForegroundColor Yellow
    }
} else {
    $exePath = if ($App.ExeFile) { Join-Path $AppsRoot $App.ExeFile } else { $null }
}
$maxAttempts = 2
try {
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $exitCode = $null
        $isMsi = $false
        if ($App.LocalExePath) {
            $foundLocalExe = $App.LocalExePath | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($foundLocalExe) {
                Write-Host "Running local updater already on this machine: $foundLocalExe"
                $proc = Start-Process -FilePath $foundLocalExe -ArgumentList $App.LocalExeArgs -Wait -PassThru
                $exitCode = $proc.ExitCode
                Write-Host "Exit code: $exitCode"
            } else {
                throw "Local updater not found on this machine at any of the expected paths for $($App.Name)."
            }
        }
        elseif ($App.CustomScript) {
            $scriptPath = Join-Path $AppsRoot $App.CustomScript
            if (Test-Path $scriptPath) {
                Write-Host "Running custom deployment script: $(Split-Path $scriptPath -Leaf) $($App.CustomScriptArgs)"
                $proc = Start-Process "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`" $($App.CustomScriptArgs)" -Wait -PassThru
                $exitCode = $proc.ExitCode
                Write-Host "Custom script exit code: $exitCode"
            } else {
                throw "Custom deployment script not found at $scriptPath"
            }
        }
        elseif ($App.UseWinget -and $App.WingetId) {
            Write-Host "Updating via winget (bandwidth exception for this app): $($App.WingetId)"
& winget upgrade --id $App.WingetId --silent --accept-package-agreements --accept-source-agreements | Out-Null
            $exitCode = $LASTEXITCODE
            Write-Host "winget exit code: $exitCode"
        }
        elseif ($msiPath -and (Test-Path $msiPath)) {
            $isMsi = $true
            Write-Host "Installing via MSI (silent): $(Split-Path $msiPath -Leaf)"
            $proc = Start-Process "msiexec.exe" -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru
            $exitCode = $proc.ExitCode
            Write-Host "msiexec exit code: $exitCode"
        }
        elseif ($exePath -and (Test-Path $exePath)) {
            Write-Host "No MSI found - falling back to EXE: $(Split-Path $exePath -Leaf)"
            $proc = Start-Process -FilePath $exePath -ArgumentList $App.ExeArgs -Wait -PassThru
            $exitCode = $proc.ExitCode
            Write-Host "Installer exit code: $exitCode"
        }
        else {
            $searchedIn = if ($App.ExeFolder) { Join-Path $AppsRoot $App.ExeFolder } else { $AppsRoot }
            throw "No MSI or EXE installer found for $($App.Name) (looked in $searchedIn). Check the probe share contents."
        }
        if ($isMsi -and $exitCode -eq 1638) {
            Write-Host "Already up to date (same product/version already installed)." -ForegroundColor Green
            return
        }
        if ($exitCode -eq 0) { break }
        $shouldRetry = ($App.RetryExitCodes -and ($App.RetryExitCodes -contains $exitCode) -and ($attempt -lt $maxAttempts))
        if ($shouldRetry) {
            Write-Host "Exit code $exitCode is a known transient condition for this app - retrying (attempt $($attempt + 1) of $maxAttempts) in 15 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 15
            continue
        }
        Write-Host "Installer reported a non-zero exit code ($exitCode) - treating as failure. Check logs for this app before assuming it's fine." -ForegroundColor Red
        return
    }
    Write-Host "Waiting for background install/handoff to finish..."
    Start-Sleep -Seconds 30
    $after = & $App.VersionCheck
    Write-Host "Version after update: $after"
    if ($after -and ($after -ne $before)) {
        Write-Host "Updated successfully." -ForegroundColor Green
    } else {
        Write-Host "No version change detected (may already have been current)." -ForegroundColor DarkYellow
    }
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
}
foreach ($app in $Apps) {
Update-App -App $app
}
Write-Host "`nDone. Review output above for per-app results." -ForegroundColor Cyan
try { Stop-Transcript | Out-Null } catch {}
