# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

$KBFileName     = "Windows11.0-KB5121794-x64_5e20a3cce48d6611b16bdec42b07167f5456586a.msu"
$RequiredBuild  = "26200"
$LogDir = "C:\ProgramData\YourCompany\Logs"
if (-not (Test-Path $LogDir)) {
   New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogDir ("Win11-26200-Upgrade-{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {
   Write-Host "Could not start logging transcript (non-fatal, continuing): $($_.Exception.Message)" -ForegroundColor DarkYellow
}
Get-ChildItem -Path $LogDir -Filter "Win11-26200-Upgrade-*.log" -ErrorAction SilentlyContinue |
   Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
$DeviceName = $env:COMPUTERNAME
Write-Host "=== Windows 11 26200 Upgrade - $DeviceName ===" -ForegroundColor Cyan
Write-Host "Run started: $(Get-Date)"
$BranchMap = @(
   [PSCustomObject]@{ Name = "Branch01";      Subnet = "<BRANCH01_SUBNET>";      ProbeShare = "\\<BRANCH01_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch02";      Subnet = "<BRANCH02_SUBNET>";      ProbeShare = "\\<BRANCH02_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch03";      Subnet = "<BRANCH03_SUBNET>";      ProbeShare = "\\<BRANCH03_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch04";      Subnet = "<BRANCH04_SUBNET>";      ProbeShare = "\\<BRANCH04_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch05";      Subnet = "<BRANCH05_SUBNET>";      ProbeShare = "\\<BRANCH05_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch06";      Subnet = "<BRANCH06_SUBNET>";      ProbeShare = "\\<BRANCH06_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch07";      Subnet = "<BRANCH07_SUBNET>";      ProbeShare = "\\<BRANCH07_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch08";      Subnet = "<BRANCH08_SUBNET>";      ProbeShare = "\\<BRANCH08_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch09";      Subnet = "<BRANCH09_SUBNET>";      ProbeShare = "\\<BRANCH09_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch10";      Subnet = "<BRANCH10_SUBNET>";      ProbeShare = "\\<BRANCH10_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch11";      Subnet = "<BRANCH11_SUBNET>";      ProbeShare = "\\<BRANCH11_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch12";      Subnet = "<BRANCH12_SUBNET>";      ProbeShare = "\\<BRANCH11_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch13";      Subnet = "<BRANCH13_SUBNET>";      ProbeShare = "\\<BRANCH13_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch14";      Subnet = "<BRANCH14_SUBNET>";      ProbeShare = "\\<BRANCH14_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch15";      Subnet = "<BRANCH15_SUBNET>";      ProbeShare = "\\<BRANCH15_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Branch16";      Subnet = "<BRANCH16_SUBNET>";      ProbeShare = "\\<BRANCH16_PROBE>\Share" }
   [PSCustomObject]@{ Name = "Head Office";   Subnet = "<HEAD_OFFICE_SUBNET>";   ProbeShare = "\\<HEAD_OFFICE_SERVER>\Share" }
)
function Get-LocalIPv4 {
   $config = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
             Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway } |
             Select-Object -First 1
   if ($config -and $config.IPv4Address) { return $config.IPv4Address.IPAddress }
   return $null
}
function Write-Result {
   param([string]$Status, [string]$Detail = "")
   Write-Host "RESULT: $DeviceName - $Status $Detail" -ForegroundColor $(
       switch ($Status) { "SUCCESS" {"Green"}; "SKIPPED" {"Yellow"}; default {"Red"} }
   )
}
$LocalIP = Get-LocalIPv4
Write-Host "Detected local IP: $LocalIP"
$MatchedBranch = $null
if ($LocalIP) {
   $ipPrefix = ($LocalIP -split '\.')[0..2] -join '.'
   $MatchedBranch = $BranchMap | Where-Object { $_.Subnet -eq $ipPrefix } | Select-Object -First 1
}
if (-not $MatchedBranch) {
   Write-Host "No known branch matches this IP ($LocalIP)." -ForegroundColor Red
   Write-Result "SKIPPED" "(no matching branch for IP $LocalIP)"
   try { Stop-Transcript | Out-Null } catch {}
   exit
}
Write-Host "Matched branch: $($MatchedBranch.Name) - using probe $($MatchedBranch.ProbeShare)" -ForegroundColor Green
$KBPath = Join-Path (Join-Path $MatchedBranch.ProbeShare "Applications") $KBFileName
$CurrentBuild = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).CurrentBuild
$UBR          = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).UBR
Write-Host "Current OS build: 10.0.$CurrentBuild.$UBR"
if ($CurrentBuild -ne $RequiredBuild) {
   Write-Host "This machine is NOT on build $RequiredBuild (25H2) - this KB does not apply here." -ForegroundColor Yellow
   Write-Result "SKIPPED" "(wrong build: 10.0.$CurrentBuild.$UBR, required $RequiredBuild)"
   try { Stop-Transcript | Out-Null } catch {}
   exit
}
Write-Host "Build check passed - machine is on 25H2 (build $RequiredBuild)." -ForegroundColor Green
if (-not (Test-Path $KBPath)) {
   Write-Host "KB file not found at: $KBPath" -ForegroundColor Red
   Write-Result "FAILED" "(KB file missing on probe: $KBPath)"
   try { Stop-Transcript | Out-Null } catch {}
   exit
}
Write-Host "Found KB file: $KBPath"
Write-Host "Running wusa.exe silently - this can take a while, do not interrupt..."
$proc = Start-Process "wusa.exe" -ArgumentList "`"$KBPath`" /quiet /norestart" -Wait -PassThru
$exitCode = $proc.ExitCode
Write-Host "Exit code: $exitCode"
Start-Sleep -Seconds 10
$RebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
Write-Host "Reboot required: $RebootPending"
switch ($exitCode) {
   0 {
       Write-Host "Update installed successfully." -ForegroundColor Green
       Write-Result "SUCCESS" "(reboot required: $RebootPending)"
   }
   3010 {
       Write-Host "Update installed successfully - reboot required to finish." -ForegroundColor Green
       Write-Result "SUCCESS" "(reboot required: $RebootPending)"
   }
   2359302 {
       Write-Host "Update was already installed on this machine." -ForegroundColor Green
       Write-Result "SUCCESS" "(already installed)"
   }
   2149842967 {
       Write-Host "Update is not applicable to this machine, despite passing the build check - worth investigating this one specifically." -ForegroundColor Red
       Write-Result "FAILED" "(not applicable - exit 2149842967, despite build check passing)"
   }
   default {
       Write-Host "Unexpected exit code - treat as failure and investigate." -ForegroundColor Red
       Write-Result "FAILED" "(unexpected exit code $exitCode)"
   }
}
Write-Host "`nRun finished: $(Get-Date)"
try { Stop-Transcript | Out-Null } catch {}
