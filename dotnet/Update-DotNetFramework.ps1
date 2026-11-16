# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

$UpdateRoot = "\\<HEAD_OFFICE_SERVER>\Share\Applications\DotNetFrameworkUpdates"
$ManifestFile = Join-Path $UpdateRoot "UpdateManifest.csv"

$LogFile = "C:\Windows\Temp\DotNetFramework_Remediation_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

$AllowWindowsUpdateFallback = $true

$AutomaticReboot = $false

function Write-Log {
    param(
        [string]$Message = ""
    )

    $Line = "{0} - {1}" -f (
        Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ), $Message

    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
}

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Test-PendingReboot {
    $PendingPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )

    foreach ($Path in $PendingPaths) {
        if (Test-Path $Path) {
            return $true
        }
    }

    try {
        $PendingRename = Get-ItemProperty `
            -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
            -Name PendingFileRenameOperations `
            -ErrorAction SilentlyContinue

        if ($PendingRename.PendingFileRenameOperations) {
            return $true
        }
    }
    catch {
    }

    return $false
}

function Get-FrameworkInformation {
    $RegistryPath = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"

    try {
        $Framework = Get-ItemProperty `
            -Path $RegistryPath `
            -ErrorAction Stop

        $Release = [int]$Framework.Release
        $Version = [string]$Framework.Version
    }
    catch {
        return $null
    }

    if ($Release -ge 533320) {
        $Branch = "4.8.1"
    }
    elseif ($Release -ge 528040) {
        $Branch = "4.8"
    }
    else {
        $Branch = "Unsupported"
    }

    return [PSCustomObject]@{
        Release = $Release
        Version = $Version
        Branch  = $Branch
    }
}

function Test-KBInUpdateHistory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KB
    )

    try {
        $Session = New-Object -ComObject Microsoft.Update.Session
        $Searcher = $Session.CreateUpdateSearcher()
        $Count = $Searcher.GetTotalHistoryCount()

        if ($Count -eq 0) {
            return $false
        }

        $History = $Searcher.QueryHistory(0, $Count)
        $EscapedKB = [System.Text.RegularExpressions.Regex]::Escape($KB)

        $HistoryMatch = $History | Where-Object {
            $_.Title -match $EscapedKB -and
            $_.ResultCode -in 2, 3
        }

        return [bool]$HistoryMatch
    }
    catch {
        Write-Log "WARNING: Unable to query Windows Update history."
        Write-Log $_.Exception.Message
        return $false
    }
}

function Test-KBInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KB
    )

    try {
        if (Get-HotFix -Id $KB -ErrorAction Stop) {
            return $true
        }
    }
    catch {
    }

    $KBNumber = $KB -replace "^KB", ""
    $EscapedKBNumber = [System.Text.RegularExpressions.Regex]::Escape($KBNumber)

    try {
        $Packages = Get-WindowsPackage `
            -Online `
            -ErrorAction Stop

        $PackageMatch = $Packages | Where-Object {
            $_.PackageName -match $EscapedKBNumber -and
            $_.PackageState -eq "Installed"
        }

        if ($PackageMatch) {
            return $true
        }
    }
    catch {
        Write-Log "WARNING: Could not query Windows package inventory."
        Write-Log $_.Exception.Message
    }

    if (Test-KBInUpdateHistory -KB $KB) {
        return $true
    }

    return $false
}

function Install-ProbeMSU {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFile
    )

    $LocalDirectory = "C:\Windows\Temp\DotNetFrameworkUpdates"
    $LocalFile = Join-Path $LocalDirectory (
        Split-Path $SourceFile -Leaf
    )

    try {
        if (-not (Test-Path $LocalDirectory)) {
            New-Item `
                -Path $LocalDirectory `
                -ItemType Directory `
                -Force | Out-Null
        }

        Write-Log "Copying update locally."
        Write-Log "Source : $SourceFile"
        Write-Log "Local  : $LocalFile"

        Copy-Item `
            -Path $SourceFile `
            -Destination $LocalFile `
            -Force `
            -ErrorAction Stop

        Unblock-File `
            -Path $LocalFile `
            -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "ERROR: Could not copy the MSU locally."
        Write-Log $_.Exception.Message
        return 1
    }

    try {
        Write-Log "Starting silent MSU installation."

        $Process = Start-Process `
            -FilePath "$env:SystemRoot\System32\wusa.exe" `
            -ArgumentList "`"$LocalFile`" /quiet /norestart" `
            -PassThru `
            -Wait `
            -ErrorAction Stop

        $ExitCode = $Process.ExitCode
    }
    catch {
        Write-Log "ERROR: WUSA could not be started."
        Write-Log $_.Exception.Message
        $ExitCode = 1
    }

    Remove-Item `
        -Path $LocalFile `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Log "WUSA exit code: $ExitCode"

    switch ($ExitCode) {
        0 {
            Write-Log "Installation completed successfully."
        }

        3010 {
            Write-Log "Installation successful. Restart required."
        }

        1641 {
            Write-Log "Installation successful. Restart initiated."
        }

        2359302 {
            Write-Log "Update is already installed."
        }

        2149842967 {
            Write-Log "Update is not applicable to this device."
        }

        -2145124329 {
            Write-Log "Update is not applicable to this device."
        }

        default {
            Write-Log "WUSA returned an unexpected exit code."
        }
    }

    return $ExitCode
}

function Install-FromWindowsUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KB
    )

    $KBNumber = $KB -replace "^KB", ""

    Write-Log "Searching configured Windows Update source for $KB."

    try {
        $Session = New-Object -ComObject Microsoft.Update.Session
        $Searcher = $Session.CreateUpdateSearcher()

        $SearchResult = $Searcher.Search(
            "IsInstalled=0 and IsHidden=0 and Type='Software'"
        )
    }
    catch {
        Write-Log "ERROR: Windows Update search failed."
        Write-Log $_.Exception.Message
        return 1
    }

    $MatchingUpdates = @()

    for (
        $Index = 0;
        $Index -lt $SearchResult.Updates.Count;
        $Index++
    ) {
        $Update = $SearchResult.Updates.Item($Index)

        if ($Update.KBArticleIDs -contains $KBNumber) {
            $MatchingUpdates += $Update
        }
    }

    if ($MatchingUpdates.Count -eq 0) {
        Write-Log "$KB is not currently offered by Windows Update."
        return 2
    }

    $Collection = New-Object `
        -ComObject Microsoft.Update.UpdateColl

    foreach ($Update in $MatchingUpdates) {
        Write-Log "Found: $($Update.Title)"

        if (-not $Update.EulaAccepted) {
            $Update.AcceptEula()
        }

        [void]$Collection.Add($Update)
    }

    try {
        Write-Log "Downloading update."

        $Downloader = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $Collection
        $DownloadResult = $Downloader.Download()

        Write-Log "Download result: $($DownloadResult.ResultCode)"

        if ($DownloadResult.ResultCode -notin 2, 3) {
            Write-Log "ERROR: Update download failed."
            return 1
        }

        Write-Log "Installing update silently."

        $UpdateInstaller = $Session.CreateUpdateInstaller()
        $UpdateInstaller.Updates = $Collection
        $InstallResult = $UpdateInstaller.Install()

        Write-Log "Install result : $($InstallResult.ResultCode)"
        Write-Log "Restart needed : $($InstallResult.RebootRequired)"

        for (
            $Index = 0;
            $Index -lt $Collection.Count;
            $Index++
        ) {
            $Result = $InstallResult.GetUpdateResult($Index)

            $HResultHex = "{0:X8}" -f (
                $Result.HResult -band 0xFFFFFFFF
            )

            Write-Log "Update  : $($Collection.Item($Index).Title)"
            Write-Log "Result  : $($Result.ResultCode)"
            Write-Log "HRESULT : 0x$HResultHex"
        }

        if ($InstallResult.RebootRequired) {
            return 3010
        }

        if ($InstallResult.ResultCode -in 2, 3) {
            return 0
        }

        return 1
    }
    catch {
        Write-Log "ERROR: Windows Update installation failed."
        Write-Log $_.Exception.Message
        return 1
    }
}

Write-Log "========================================================="
Write-Log ".NET FRAMEWORK REMEDIATION STARTED"
Write-Log "========================================================="
Write-Log "Computer Name : $env:COMPUTERNAME"
Write-Log "Running As    : $(whoami)"
Write-Log "PowerShell    : $($PSVersionTable.PSVersion)"

if (-not (Test-IsAdministrator)) {
    Write-Log "ERROR: Script must run as Administrator or SYSTEM."
    Write-Log "Exit Code : 1"
    exit 1
}

try {
    $OS = Get-CimInstance `
        -ClassName Win32_OperatingSystem `
        -ErrorAction Stop
}
catch {
    Write-Log "ERROR: Could not retrieve operating-system information."
    Write-Log $_.Exception.Message
    Write-Log "Exit Code : 1"
    exit 1
}

$BuildNumber = [string]$OS.BuildNumber
$Architecture = $env:PROCESSOR_ARCHITECTURE

$DisplayVersion = (
    Get-ItemProperty `
        -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
        -ErrorAction SilentlyContinue
).DisplayVersion

Write-Log ""
Write-Log "OPERATING SYSTEM"
Write-Log "Caption         : $($OS.Caption)"
Write-Log "Display Version : $DisplayVersion"
Write-Log "Build Number    : $BuildNumber"
Write-Log "Architecture    : $Architecture"

if ($Architecture -ne "AMD64") {
    Write-Log "ERROR: Only x64 devices are currently approved."
    Write-Log "Exit Code : 4"
    exit 4
}

$Framework = Get-FrameworkInformation

if ($null -eq $Framework) {
    Write-Log "ERROR: .NET Framework v4 Full was not detected."
    Write-Log "Exit Code : 4"
    exit 4
}

Write-Log ""
Write-Log ".NET FRAMEWORK"
Write-Log "Version : $($Framework.Version)"
Write-Log "Release : $($Framework.Release)"
Write-Log "Branch  : $($Framework.Branch)"

if ($Framework.Branch -eq "Unsupported") {
    Write-Log "ERROR: Framework is older than 4.8."
    Write-Log "This script will not upgrade the base Framework."
    Write-Log "Exit Code : 4"
    exit 4
}

if (-not (Test-Path $ManifestFile)) {
    Write-Log "ERROR: Manifest not found."
    Write-Log $ManifestFile
    Write-Log "Exit Code : 1"
    exit 1
}

try {
    $Manifest = Import-Csv `
        -Path $ManifestFile `
        -ErrorAction Stop
}
catch {
    Write-Log "ERROR: Could not read the manifest."
    Write-Log $_.Exception.Message
    Write-Log "Exit Code : 1"
    exit 1
}

$RequiredColumns = @(
    "Build",
    "FrameworkBranch",
    "TargetKB",
    "FilePattern",
    "Description"
)

$ManifestColumns = @(
    $Manifest |
    Select-Object -First 1 |
    ForEach-Object {
        $_.PSObject.Properties.Name
    }
)

$MissingColumns = @(
    $RequiredColumns | Where-Object {
        $_ -notin $ManifestColumns
    }
)

if ($MissingColumns.Count -gt 0) {
    Write-Log "ERROR: Manifest is missing required columns:"
    Write-Log ($MissingColumns -join ", ")
    Write-Log "Exit Code : 4"
    exit 4
}

$ManifestMatches = @(
    $Manifest | Where-Object {
        $_.Build -eq $BuildNumber -and
        $_.FrameworkBranch -eq $Framework.Branch
    }
)

if ($ManifestMatches.Count -eq 0) {
    Write-Log "ERROR: No approved mapping exists for:"
    Write-Log "Build     : $BuildNumber"
    Write-Log "Framework : $($Framework.Branch)"
    Write-Log "Exit Code : 4"
    exit 4
}

if ($ManifestMatches.Count -gt 1) {
    Write-Log "ERROR: Duplicate manifest mappings were found."

    $ManifestMatches | ForEach-Object {
        Write-Log "Build=$($_.Build), Framework=$($_.FrameworkBranch), KB=$($_.TargetKB), Pattern=$($_.FilePattern)"
    }

    Write-Log "Exit Code : 4"
    exit 4
}

$Target = $ManifestMatches[0]
$TargetKB = [string]$Target.TargetKB
$TargetFilePattern = [string]$Target.FilePattern
$TargetDescription = [string]$Target.Description

if ([System.String]::IsNullOrWhiteSpace($TargetKB)) {
    Write-Log "ERROR: TargetKB is missing from the manifest entry."
    Write-Log "Exit Code : 4"
    exit 4
}

if ([System.String]::IsNullOrWhiteSpace($TargetFilePattern)) {
    Write-Log "ERROR: FilePattern is missing from the manifest entry."
    Write-Log "Build     : $BuildNumber"
    Write-Log "Framework : $($Framework.Branch)"
    Write-Log "KB        : $TargetKB"
    Write-Log "Exit Code : 4"
    exit 4
}

if ($TargetFilePattern -match "[\\/]") {
    Write-Log "ERROR: FilePattern must be a filename wildcard only."
    Write-Log "Do not include backslashes or folder paths."
    Write-Log "Pattern: $TargetFilePattern"
    Write-Log "Exit Code : 4"
    exit 4
}

Write-Log ""
Write-Log "TARGET UPDATE"
Write-Log "KB           : $TargetKB"
Write-Log "File Pattern : $TargetFilePattern"
Write-Log "Description  : $TargetDescription"

if (Test-KBInstalled -KB $TargetKB) {
    Write-Log ""
    Write-Log "$TargetKB is already installed."
    Write-Log "No remediation is required."
    Write-Log "LOG FILE: $LogFile"
    Write-Log "Exit Code : 0"
    exit 0
}

$PreExistingReboot = Test-PendingReboot

if ($PreExistingReboot) {
    Write-Log ""
    Write-Log "WARNING: A restart was already pending before remediation."
}

$KBFolder = Join-Path $UpdateRoot $TargetKB
$MSUFiles = @()

if (Test-Path $KBFolder) {
    $MSUFiles = @(
        Get-ChildItem `
            -Path $KBFolder `
            -Filter $TargetFilePattern `
            -File `
            -ErrorAction SilentlyContinue
    )
}
else {
    Write-Log ""
    Write-Log "WARNING: KB folder does not exist:"
    Write-Log $KBFolder
}

$InstallMethod = $null
$InstallExitCode = $null

if ($MSUFiles.Count -eq 1) {
    $InstallMethod = "Probe MSU"

    Write-Log ""
    Write-Log "Probe package found:"
    Write-Log $MSUFiles[0].FullName

    $InstallExitCode = Install-ProbeMSU `
        -SourceFile $MSUFiles[0].FullName
}
elseif ($MSUFiles.Count -gt 1) {
    Write-Log ""
    Write-Log "ERROR: Multiple matching MSUs were found."
    Write-Log "Folder  : $KBFolder"
    Write-Log "Pattern : $TargetFilePattern"

    $MSUFiles | ForEach-Object {
        Write-Log $_.FullName
    }

    Write-Log "Exit Code : 1"
    exit 1
}
elseif ($AllowWindowsUpdateFallback) {
    $InstallMethod = "Windows Update"

    Write-Log ""
    Write-Log "No probe-hosted MSU matched the manifest pattern."
    Write-Log "Folder  : $KBFolder"
    Write-Log "Pattern : $TargetFilePattern"
    Write-Log "Using Windows Update fallback."

    $InstallExitCode = Install-FromWindowsUpdate `
        -KB $TargetKB
}
else {
    Write-Log ""
    Write-Log "ERROR: No matching probe MSU was found."
    Write-Log "Folder  : $KBFolder"
    Write-Log "Pattern : $TargetFilePattern"
    Write-Log "Windows Update fallback is disabled."
    Write-Log "Exit Code : 1"
    exit 1
}

Write-Log ""
Write-Log "INSTALLATION RESULT"
Write-Log "Method    : $InstallMethod"
Write-Log "Exit code : $InstallExitCode"

$SuccessfulExitCodes = @(
    0,
    3010,
    1641,
    2359302
)

if ($InstallExitCode -notin $SuccessfulExitCodes) {
    Write-Log "ERROR: Installation was not successful."

    if (
        $InstallExitCode -eq 2149842967 -or
        $InstallExitCode -eq -2145124329
    ) {
        Write-Log "The selected update is not applicable to this device."
        Write-Log "Verify the OS build, Framework branch, architecture, and manifest mapping."
    }
    else {
        Write-Log "Check CBS.log and Windows Update events."
    }

    Write-Log "Exit Code : 1"
    exit 1
}

Write-Log ""
Write-Log "Waiting for servicing registration."

$Deadline = (Get-Date).AddSeconds(180)
$Installed = $false

do {
    Start-Sleep -Seconds 10
    $Installed = Test-KBInstalled -KB $TargetKB
}
until (
    $Installed -or
    (Get-Date) -ge $Deadline
)

$PendingReboot = Test-PendingReboot

Write-Log ""
Write-Log "VERIFICATION"

if ($Installed) {
    Write-Log "SUCCESS: $TargetKB was detected."
}
elseif (
    $InstallExitCode -in 0, 3010, 1641 -and
    $PendingReboot
) {
    Write-Log "SUCCESS: Update is installed or staged."
    Write-Log "Verification requires a restart."
}
else {
    Write-Log "WARNING: Target KB was not detected after installation."
    Write-Log "Run a vulnerability rescan after the next restart."
    Write-Log "Exit Code : 3"
    exit 3
}

Write-Log ""
Write-Log "Restart required: $PendingReboot"
Write-Log "LOG FILE SAVED TO:"
Write-Log $LogFile
Write-Log ""
Write-Log ".NET FRAMEWORK REMEDIATION COMPLETE"

if (
    $PendingReboot -or
    $InstallExitCode -in 3010, 1641
) {
    Write-Log "Exit Code : 3010"

    if ($AutomaticReboot) {
        Write-Log "Automatic restart enabled. Restarting in 60 seconds."

        shutdown.exe /r /t 60 /c ".NET Framework update"
    }

    exit 3010
}

Write-Log "Exit Code : 0"
exit 0
