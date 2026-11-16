# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

$KBFileName    = "windows11.0-kb5054156-x64_a0c1638cbcf4cf33dbe9a5bef69db374b4786974.msu"
$RequiredBuild = 26100
$MinimumUBR    = 5074
$TargetBuild   = 26200

$LogDir = "C:\ProgramData\YourCompany\Logs"

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

$LogFile = Join-Path $LogDir (
    "Win11-24H2-to-25H2-{0}.log" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
)

try {
    Start-Transcript -Path $LogFile -Force | Out-Null
}
catch {
    Write-Host "Could not start logging transcript (non-fatal): $($_.Exception.Message)"
}

Get-ChildItem -Path $LogDir `
    -Filter "Win11-24H2-to-25H2-*.log" `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 10 |
    Remove-Item -Force -ErrorAction SilentlyContinue

$DeviceName = $env:COMPUTERNAME

Write-Host "=== Windows 11 24H2 to 25H2 Enablement - $DeviceName ==="
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
    $Config = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object {
            $_.NetAdapter.Status -eq "Up" -and
            $_.IPv4DefaultGateway -and
            $_.IPv4Address
        } |
        Select-Object -First 1

    if ($Config -and $Config.IPv4Address) {
        return [string]$Config.IPv4Address.IPAddress
    }

    return $null
}

function Write-Result {
    param(
        [string]$Status,
        [string]$Detail = ""
    )

    Write-Host "RESULT: $DeviceName - $Status $Detail"
}

function Stop-Script {
    param(
        [int]$ExitCode,
        [string]$Status,
        [string]$Detail
    )

    Write-Result -Status $Status -Detail $Detail
    Write-Host "Run finished: $(Get-Date)"

    try {
        Stop-Transcript | Out-Null
    }
    catch {}

    exit $ExitCode
}

function Test-PendingReboot {
    $CBS = Test-Path `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"

    $WindowsUpdate = Test-Path `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"

    $PendingRename = $null

    try {
        $PendingRename = (
            Get-ItemProperty `
                "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
                -Name "PendingFileRenameOperations" `
                -ErrorAction Stop
        ).PendingFileRenameOperations
    }
    catch {}

    return $CBS -or $WindowsUpdate -or $PendingRename
}

$LocalIP = Get-LocalIPv4
Write-Host "Detected local IP: $LocalIP"

if (-not $LocalIP) {
    Stop-Script 10 "SKIPPED" "(could not detect an active IPv4 address with a default gateway)"
}

$IPParts = $LocalIP -split "\."

if ($IPParts.Count -lt 3) {
    Stop-Script 11 "SKIPPED" "(invalid detected IPv4 address: $LocalIP)"
}

$IPPrefix = $IPParts[0..2] -join "."

$MatchedBranch = $BranchMap |
    Where-Object { $_.Subnet -eq $IPPrefix } |
    Select-Object -First 1

if (-not $MatchedBranch) {
    Stop-Script 12 "SKIPPED" "(no matching branch for IP $LocalIP)"
}

Write-Host "Matched branch: $($MatchedBranch.Name)"
Write-Host "Using probe: $($MatchedBranch.ProbeShare)"

$KBPath = Join-Path `
    (Join-Path $MatchedBranch.ProbeShare "Applications") `
    $KBFileName

Write-Host "Expected package: $KBPath"

$OSPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$OSInfo = Get-ItemProperty -Path $OSPath -ErrorAction SilentlyContinue

if (-not $OSInfo) {
    Stop-Script 20 "FAILED" "(could not read Windows version information)"
}

$CurrentBuild  = [int]$OSInfo.CurrentBuildNumber
$UBR           = [int]$OSInfo.UBR
$DisplayVersion = [string]$OSInfo.DisplayVersion
$EditionID     = [string]$OSInfo.EditionID
$ProductName   = [string]$OSInfo.ProductName
$InstallationType = [string]$OSInfo.InstallationType

Write-Host "Product: $ProductName"
Write-Host "Edition: $EditionID"
Write-Host "Version: $DisplayVersion"
Write-Host "Build: 10.0.$CurrentBuild.$UBR"
Write-Host "Installation type: $InstallationType"
Write-Host "Architecture: $env:PROCESSOR_ARCHITECTURE"

if ($InstallationType -ne "Client") {
    Stop-Script 21 "SKIPPED" "(not a Windows client installation)"
}

if ($ProductName -match "Server") {
    Stop-Script 22 "SKIPPED" "(Windows Server is not eligible)"
}

if ($ProductName -match "LTSC" -or $EditionID -match "LTSC") {
    Stop-Script 23 "SKIPPED" "(LTSC editions are excluded)"
}

if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    Stop-Script 24 "SKIPPED" "(package is x64 but device architecture is $env:PROCESSOR_ARCHITECTURE)"
}

if ($CurrentBuild -eq $TargetBuild -or $DisplayVersion -eq "25H2") {
    Stop-Script 0 "SUCCESS" "(device is already running Windows 11 25H2)"
}

if ($CurrentBuild -gt $TargetBuild) {
    Stop-Script 0 "SKIPPED" "(device is already newer than 25H2: build $CurrentBuild)"
}

if ($DisplayVersion -ne "24H2") {
    Stop-Script 25 "SKIPPED" "(wrong Windows version: $DisplayVersion; required 24H2)"
}

if ($CurrentBuild -ne $RequiredBuild) {
    Stop-Script 26 "SKIPPED" "(wrong base build: $CurrentBuild; required $RequiredBuild)"
}

if ($UBR -lt $MinimumUBR) {
    Stop-Script 27 "SKIPPED" "(build too old: 26100.$UBR; minimum required is 26100.$MinimumUBR)"
}

Write-Host "Eligibility checks passed."
Write-Host "Device is eligible: Windows 11 24H2 build 26100.$UBR"

if (-not (Test-Path -LiteralPath $KBPath)) {
    Stop-Script 30 "FAILED" "(KB5054156 package missing: $KBPath)"
}

$Signature = Get-AuthenticodeSignature `
    -FilePath $KBPath `
    -ErrorAction SilentlyContinue

Write-Host "Package signature status: $($Signature.Status)"
Write-Host "Package signer: $($Signature.SignerCertificate.Subject)"

if ($Signature.Status -ne "Valid") {
    Stop-Script 31 "FAILED" "(MSU signature is not valid: $($Signature.Status))"
}

if ($Signature.SignerCertificate.Subject -notmatch "Microsoft") {
    Stop-Script 32 "FAILED" "(MSU is not signed by Microsoft)"
}

$PackageSizeKB = 0

Write-Host "Found package: $KBPath"
Write-Host "Package size: $PackageSizeKB KB"
Write-Host "Package signature validation passed."

Write-Host "Installing KB5054156 silently."
Write-Host "No restart will be initiated by this script."

$Process = Start-Process `
    -FilePath "$env:SystemRoot\System32\wusa.exe" `
    -ArgumentList "`"$KBPath`" /quiet /norestart" `
    -WindowStyle Hidden `
    -Wait `
    -PassThru

$SignedExitCode = [int]$Process.ExitCode
$ExitCode = [uint32]$SignedExitCode

Write-Host "WUSA signed exit code: $SignedExitCode"
Write-Host "WUSA unsigned exit code: $ExitCode"

Start-Sleep -Seconds 10

$RebootPending = Test-PendingReboot
Write-Host "Reboot pending: $RebootPending"

switch ($ExitCode) {
    0 {
        Write-Host "KB5054156 installed successfully."
        Stop-Script 0 "SUCCESS" "(KB5054156 staged; reboot pending: $RebootPending; no restart forced)"
    }

    3010 {
        Write-Host "KB5054156 installed successfully and requires a restart."
        Stop-Script 0 "SUCCESS" "(KB5054156 staged; reboot required; no restart forced)"
    }

    2359302 {
        Write-Host "KB5054156 is already installed."
        Stop-Script 0 "SUCCESS" "(KB5054156 already installed; reboot pending: $RebootPending)"
    }

    2149842967 {
        Write-Host "KB5054156 is not applicable to this device."
        Stop-Script 40 "FAILED" "(not applicable; WUSA exit code 0x80240017)"
    }

    2147942405 {
        Write-Host "Access denied while installing the update."
        Stop-Script 41 "FAILED" "(access denied; ensure the script runs as SYSTEM or administrator)"
    }

    default {
        $HexExitCode = "0x{0:X8}" -f $ExitCode
        Write-Host "Unexpected WUSA exit code: $ExitCode / $HexExitCode"
        Stop-Script 42 "FAILED" "(unexpected WUSA exit code $ExitCode / $HexExitCode)"
    }
}
