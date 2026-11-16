# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

$DesktopInstaller = "\\<HEAD_OFFICE_SERVER>\Share\Applications\windowsdesktop-runtime-10.0.12-win-x64.exe"
$AspNetInstaller  = "\\<HEAD_OFFICE_SERVER>\Share\Applications\aspnetcore-runtime-10.0.12-win-x64.exe"

$UninstallTool = "\\<HEAD_OFFICE_SERVER>\Share\Applications\dotnet_uninstall\dotnet-core-uninstall.exe"

$LogFile = "C:\Windows\Temp\DotNet_Remediation_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

$DotNetExe = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"

$TargetVersion = "10.0.12"

$VersionsConfiguredForRemoval = @(
    "2.1",
    "2.2",
    "3.0",
    "3.1",
    "5.0",
    "6.0",
    "7.0",
    "8.0",
    "9.0"
)

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

function Get-MajorMinor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $Parts = $Version -split "\."

    if ($Parts.Count -lt 2) {
        return $Version
    }

    return "$($Parts[0]).$($Parts[1])"
}

function Get-InstalledRuntimes {
    if (-not (Test-Path $DotNetExe)) {
        return @()
    }

    return @(& $DotNetExe --list-runtimes 2>$null)
}

function Test-Runtime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Framework,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $RuntimeLines = Get-InstalledRuntimes

    $Pattern = "^{0}\s+{1}\s+\[" -f (
        [System.Text.RegularExpressions.Regex]::Escape($Framework)
    ), (
        [System.Text.RegularExpressions.Regex]::Escape($Version)
    )

    return $RuntimeLines -match $Pattern
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

function Install-DotNetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $true)]
        [string]$ComponentName
    )

    if (-not (Test-Path $InstallerPath)) {
        Write-Log "ERROR: $ComponentName installer not found."
        Write-Log $InstallerPath

        return [PSCustomObject]@{
            Success        = $false
            ExitCode       = 1
            RebootRequired = $false
        }
    }

    $LocalDirectory = "C:\Windows\Temp\DotNet10Installers"
    $LocalInstaller = Join-Path $LocalDirectory (
        Split-Path $InstallerPath -Leaf
    )

    try {
        if (-not (Test-Path $LocalDirectory)) {
            New-Item `
                -Path $LocalDirectory `
                -ItemType Directory `
                -Force | Out-Null
        }

        Write-Log ""
        Write-Log "COPYING $ComponentName INSTALLER"
        Write-Log "Source : $InstallerPath"
        Write-Log "Local  : $LocalInstaller"

        Copy-Item `
            -Path $InstallerPath `
            -Destination $LocalInstaller `
            -Force `
            -ErrorAction Stop

        Unblock-File `
            -Path $LocalInstaller `
            -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "ERROR: Failed to copy $ComponentName installer."
        Write-Log $_.Exception.Message

        return [PSCustomObject]@{
            Success        = $false
            ExitCode       = 1
            RebootRequired = $false
        }
    }

    try {
        Write-Log "STARTING $ComponentName INSTALLATION"

        $Process = Start-Process `
            -FilePath $LocalInstaller `
            -ArgumentList "/install", "/quiet", "/norestart" `
            -PassThru `
            -Wait `
            -ErrorAction Stop

        $ExitCode = $Process.ExitCode
    }
    catch {
        Write-Log "ERROR: Failed to start $ComponentName installer."
        Write-Log $_.Exception.Message
        $ExitCode = 1
    }

    Remove-Item `
        -Path $LocalInstaller `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Log "$ComponentName EXIT CODE: $ExitCode"

    switch ($ExitCode) {
        0 {
            Write-Log "$ComponentName installation successful."
        }

        3010 {
            Write-Log "$ComponentName installation successful. Restart required."
        }

        1641 {
            Write-Log "$ComponentName installation successful. Restart initiated."
        }

        default {
            Write-Log "$ComponentName installation failed."
        }
    }

    return [PSCustomObject]@{
        Success        = ($ExitCode -in 0, 3010, 1641)
        ExitCode       = $ExitCode
        RebootRequired = ($ExitCode -in 3010, 1641)
    }
}

function Wait-ForRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Framework,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [int]$TimeoutSeconds = 120
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        if (Test-Runtime -Framework $Framework -Version $Version) {
            return $true
        }

        Start-Sleep -Seconds 5
    }
    until ((Get-Date) -ge $Deadline)

    return $false
}

Write-Log "========================================================="
Write-Log "DOTNET FULL-STACK REMEDIATION STARTED"
Write-Log "========================================================="
Write-Log "Computer Name : $env:COMPUTERNAME"
Write-Log "Running As    : $(whoami)"
Write-Log "PowerShell    : $($PSVersionTable.PSVersion)"
Write-Log "Target        : .NET $TargetVersion"

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$Principal = New-Object `
    Security.Principal.WindowsPrincipal($Identity)

$IsAdmin = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdmin) {
    Write-Log "ERROR: Script must run as Administrator or SYSTEM."
    Write-Log "Exit Code : 1"
    exit 1
}

$AnyRebootRequired = Test-PendingReboot

if ($AnyRebootRequired) {
    Write-Log "WARNING: A restart was already pending before remediation."
}

Write-Log ""
Write-Log "CURRENT INSTALLED RUNTIMES"

$CurrentRuntimes = Get-InstalledRuntimes

if ($CurrentRuntimes.Count -eq 0) {
    Write-Log "No existing dotnet shared runtimes were detected."
}
else {
    $CurrentRuntimes | ForEach-Object {
        Write-Log $_
    }
}

$InstalledRuntimeObjects = foreach ($Line in $CurrentRuntimes) {
    if ($Line -match "^(?<RuntimeName>\S+)\s+(?<RuntimeVersion>\d+\.\d+\.\d+\S*)\s+\[") {
        [PSCustomObject]@{
            Name       = $Matches["RuntimeName"]
            Version    = $Matches["RuntimeVersion"]
            MajorMinor = Get-MajorMinor -Version $Matches["RuntimeVersion"]
        }
    }
}

$VersionsToRemove = @(
    $InstalledRuntimeObjects |
    Where-Object {
        $VersionsConfiguredForRemoval -contains $_.MajorMinor
    } |
    Select-Object -ExpandProperty MajorMinor -Unique |
    Sort-Object
)

Write-Log ""
Write-Log "OLDER RUNTIME FAMILIES DETECTED"

if ($VersionsToRemove.Count -eq 0) {
    Write-Log "No configured older runtime families were detected."
}
else {
    $VersionsToRemove | ForEach-Object {
        Write-Log $_
    }
}

Write-Log ""
Write-Log "INSTALLED RUNTIME LOCATIONS"

$SharedRuntimeRoot = Join-Path $env:ProgramFiles "dotnet\shared"

if (Test-Path $SharedRuntimeRoot) {
    Get-ChildItem `
        -Path $SharedRuntimeRoot `
        -Directory `
        -ErrorAction SilentlyContinue |
    ForEach-Object {
        Write-Log $_.FullName

        Get-ChildItem `
            -Path $_.FullName `
            -Directory `
            -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Log "    $($_.FullName)"
        }
    }
}
else {
    Write-Log "Shared runtime directory does not currently exist."
}

Write-Log ""
Write-Log "SCANNING FOR APPLICATION DEPENDENCIES"

$DependencyList = @()

if ($VersionsToRemove.Count -gt 0) {
    $SearchRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object {
        $_ -and (Test-Path $_)
    }

    $RuntimeFiles = @(
        Get-ChildItem `
            -Path $SearchRoots `
            -Filter "*.runtimeconfig.json" `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike "$env:ProgramFiles\dotnet*" -and
            $_.FullName -notlike "${env:ProgramFiles(x86)}\dotnet*"
        }
    )

    foreach ($File in $RuntimeFiles) {
        try {
            $Json = Get-Content `
                -Path $File.FullName `
                -Raw `
                -ErrorAction Stop |
                ConvertFrom-Json

            $Frameworks = @()

            if ($Json.runtimeOptions.framework) {
                $Frameworks += $Json.runtimeOptions.framework
            }

            if ($Json.runtimeOptions.frameworks) {
                $Frameworks += $Json.runtimeOptions.frameworks
            }

            foreach ($Framework in $Frameworks) {
                if (-not $Framework.version) {
                    continue
                }

                $MajorMinor = Get-MajorMinor `
                    -Version ([string]$Framework.version)

                if ($VersionsToRemove -contains $MajorMinor) {
                    $DependencyList += [PSCustomObject]@{
                        RuntimeVersion = $MajorMinor
                        Framework      = $Framework.name
                        ConfigFile     = $File.FullName
                        RollForward    = $Json.runtimeOptions.rollForward
                    }
                }
            }
        }
        catch {
            Write-Log "WARNING: Could not parse $($File.FullName)"
            Write-Log $_.Exception.Message
        }
    }
}

if ($DependencyList.Count -eq 0) {
    Write-Log "No dependencies discovered."
}
else {
    Write-Log "DEPENDENCIES FOUND"

    $DependencyList |
    Sort-Object RuntimeVersion, Framework, ConfigFile |
    ForEach-Object {
        Write-Log ""
        Write-Log "Version     : $($_.RuntimeVersion)"
        Write-Log "Framework   : $($_.Framework)"
        Write-Log "Roll Forward: $($_.RollForward)"
        Write-Log "Config File : $($_.ConfigFile)"
    }
}

Write-Log ""
Write-Log "CHECKING FOR RUNNING DEPENDENT APPLICATIONS"

$RunningApps = @()

if ($DependencyList.Count -gt 0) {
    $Processes = Get-CimInstance `
        -ClassName Win32_Process `
        -ErrorAction SilentlyContinue

    foreach ($Application in $DependencyList) {
        $BasePath = $Application.ConfigFile `
            -replace "\.runtimeconfig\.json$", ""

        $ExecutablePath = "$BasePath.exe"
        $DllPath = "$BasePath.dll"

        foreach ($Process in $Processes) {
            $ExecutableMatch = (
                $Process.ExecutablePath -and
                $Process.ExecutablePath -ieq $ExecutablePath
            )

            $DllMatch = (
                $Process.CommandLine -and
                $Process.CommandLine.IndexOf(
                    $DllPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            )

            if ($ExecutableMatch -or $DllMatch) {
                $RunningApps += [PSCustomObject]@{
                    Version = $Application.RuntimeVersion
                    Process = $Process.Name
                    PID     = $Process.ProcessId
                    Config  = $Application.ConfigFile
                }
            }
        }
    }
}

if ($RunningApps.Count -gt 0) {
    Write-Log ""
    Write-Log "RUNNING APPLICATIONS DEPENDENT ON AN OLDER .NET VERSION WERE DETECTED"

    $RunningApps |
    Sort-Object PID -Unique |
    ForEach-Object {
        Write-Log "Process : $($_.Process)"
        Write-Log "PID     : $($_.PID)"
        Write-Log "Version : $($_.Version)"
        Write-Log "Config  : $($_.Config)"
        Write-Log ""
    }

    Write-Log "SCRIPT TERMINATED"
    Write-Log "Close the applications and retry."
    Write-Log "Exit Code : 2"
    exit 2
}

Write-Log "No dependent applications are currently running."

Write-Log ""
Write-Log "CHECKING .NET 10 DESKTOP STACK"

$CoreInstalled = Test-Runtime `
    -Framework "Microsoft.NETCore.App" `
    -Version $TargetVersion

$DesktopInstalled = Test-Runtime `
    -Framework "Microsoft.WindowsDesktop.App" `
    -Version $TargetVersion

if ($CoreInstalled -and $DesktopInstalled) {
    Write-Log ".NET $TargetVersion Core and Desktop runtimes already installed."
}
else {
    Write-Log ".NET $TargetVersion Desktop Runtime installation required."

    $DesktopResult = Install-DotNetPackage `
        -InstallerPath $DesktopInstaller `
        -ComponentName ".NET Desktop Runtime $TargetVersion"

    if (-not $DesktopResult.Success) {
        Write-Log "ERROR: Desktop Runtime installation failed."
        Write-Log "Older runtimes will not be removed."
        Write-Log "Exit Code : 1"
        exit 1
    }

    if ($DesktopResult.RebootRequired) {
        $AnyRebootRequired = $true
    }

    Write-Log "Waiting for Core Runtime registration."

    $CoreInstalled = Wait-ForRuntime `
        -Framework "Microsoft.NETCore.App" `
        -Version $TargetVersion

    Write-Log "Waiting for Desktop Runtime registration."

    $DesktopInstalled = Wait-ForRuntime `
        -Framework "Microsoft.WindowsDesktop.App" `
        -Version $TargetVersion
}

Write-Log ""
Write-Log "CHECKING .NET 10 ASP.NET CORE RUNTIME"

$AspNetInstalled = Test-Runtime `
    -Framework "Microsoft.AspNetCore.App" `
    -Version $TargetVersion

if ($AspNetInstalled) {
    Write-Log "ASP.NET Core Runtime $TargetVersion already installed."
}
else {
    Write-Log "ASP.NET Core Runtime $TargetVersion installation required."

    $AspNetResult = Install-DotNetPackage `
        -InstallerPath $AspNetInstaller `
        -ComponentName "ASP.NET Core Runtime $TargetVersion"

    if (-not $AspNetResult.Success) {
        Write-Log "ERROR: ASP.NET Core Runtime installation failed."
        Write-Log "Older runtimes will not be removed."
        Write-Log "Exit Code : 1"
        exit 1
    }

    if ($AspNetResult.RebootRequired) {
        $AnyRebootRequired = $true
    }

    Write-Log "Waiting for ASP.NET Core Runtime registration."

    $AspNetInstalled = Wait-ForRuntime `
        -Framework "Microsoft.AspNetCore.App" `
        -Version $TargetVersion
}

Write-Log ""
Write-Log "VERIFYING COMPLETE .NET 10 STACK"

$PostInstallRuntimes = Get-InstalledRuntimes

$PostInstallRuntimes | ForEach-Object {
    Write-Log $_
}

$CoreInstalled = Test-Runtime `
    -Framework "Microsoft.NETCore.App" `
    -Version $TargetVersion

$DesktopInstalled = Test-Runtime `
    -Framework "Microsoft.WindowsDesktop.App" `
    -Version $TargetVersion

$AspNetInstalled = Test-Runtime `
    -Framework "Microsoft.AspNetCore.App" `
    -Version $TargetVersion

Write-Log ""
Write-Log "Core Runtime    : $CoreInstalled"
Write-Log "Desktop Runtime : $DesktopInstalled"
Write-Log "ASP.NET Runtime : $AspNetInstalled"

if (-not ($CoreInstalled -and $DesktopInstalled -and $AspNetInstalled)) {
    Write-Log "ERROR: Complete .NET 10 stack was not detected."
    Write-Log "Older runtimes will not be removed."
    Write-Log "Exit Code : 1"
    exit 1
}

Write-Log "COMPLETE .NET 10 STACK VERIFIED"

$PreRemovalRuntimes = Get-InstalledRuntimes

$PreRemovalObjects = foreach ($Line in $PreRemovalRuntimes) {
    if ($Line -match "^(?<RuntimeName>\S+)\s+(?<RuntimeVersion>\d+\.\d+\.\d+\S*)\s+\[") {
        [PSCustomObject]@{
            Name       = $Matches["RuntimeName"]
            Version    = $Matches["RuntimeVersion"]
            MajorMinor = Get-MajorMinor -Version $Matches["RuntimeVersion"]
        }
    }
}

$VersionsToRemove = @(
    $PreRemovalObjects |
    Where-Object {
        $VersionsConfiguredForRemoval -contains $_.MajorMinor
    } |
    Select-Object -ExpandProperty MajorMinor -Unique |
    Sort-Object
)

if ($VersionsToRemove.Count -gt 0) {
    if (-not (Test-Path $UninstallTool)) {
        Write-Log "ERROR: Uninstall tool not found."
        Write-Log $UninstallTool
        Write-Log "Exit Code : 1"
        exit 1
    }

    Write-Log ""
    Write-Log "BEGINNING OLDER RUNTIME REMOVAL"

    foreach ($Version in $VersionsToRemove) {
        Write-Log ""
        Write-Log "TARGET VERSION: $Version"
        Write-Log "RUNTIME FOLDERS"

        if (Test-Path $SharedRuntimeRoot) {
            Get-ChildItem `
                -Path $SharedRuntimeRoot `
                -Recurse `
                -Directory `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like "$Version.*"
            } |
            ForEach-Object {
                Write-Log $_.FullName
            }
        }

        $ComponentTypes = @(
            "--runtime",
            "--aspnet-runtime",
            "--hosting-bundle",
            "--windows-desktop-runtime"
        )

        foreach ($ComponentType in $ComponentTypes) {
            Write-Log ""
            Write-Log "ATTEMPTING REMOVAL: $Version $ComponentType"

            $Output = & $UninstallTool `
                remove `
                --major-minor $Version `
                $ComponentType `
                --yes 2>&1

            $UninstallExitCode = $LASTEXITCODE

            $Output | ForEach-Object {
                Write-Log "    $_"
            }

            Write-Log "    Exit code: $UninstallExitCode"
        }

        Start-Sleep -Seconds 10
    }
}
else {
    Write-Log ""
    Write-Log "No older runtime families require removal."
}

Write-Log ""
Write-Log "FINAL RUNTIME INVENTORY"

$FinalRuntimes = Get-InstalledRuntimes

$FinalRuntimes | ForEach-Object {
    Write-Log $_
}

$RemovalFailed = $false

foreach ($Version in $VersionsToRemove) {
    $Pattern = "^\S+\s+{0}\." -f (
        [System.Text.RegularExpressions.Regex]::Escape($Version)
    )

    if ($FinalRuntimes -match $Pattern) {
        Write-Log "WARNING: VERSION $Version STILL EXISTS"
        $RemovalFailed = $true
    }
    else {
        Write-Log "SUCCESS: VERSION $Version REMOVED"
    }
}

$FinalCoreInstalled = Test-Runtime `
    -Framework "Microsoft.NETCore.App" `
    -Version $TargetVersion

$FinalDesktopInstalled = Test-Runtime `
    -Framework "Microsoft.WindowsDesktop.App" `
    -Version $TargetVersion

$FinalAspNetInstalled = Test-Runtime `
    -Framework "Microsoft.AspNetCore.App" `
    -Version $TargetVersion

Write-Log ""
Write-Log "FINAL .NET 10 STACK STATUS"
Write-Log "Core Runtime    : $FinalCoreInstalled"
Write-Log "Desktop Runtime : $FinalDesktopInstalled"
Write-Log "ASP.NET Runtime : $FinalAspNetInstalled"

if (-not (
    $FinalCoreInstalled -and
    $FinalDesktopInstalled -and
    $FinalAspNetInstalled
)) {
    Write-Log "ERROR: .NET 10 stack verification failed after removal."
    Write-Log "Exit Code : 1"
    exit 1
}

$PendingReboot = Test-PendingReboot

if ($PendingReboot) {
    $AnyRebootRequired = $true
}

Write-Log ""
Write-Log "LOG FILE SAVED TO:"
Write-Log $LogFile
Write-Log ""
Write-Log "DOTNET FULL-STACK REMEDIATION COMPLETE"
Write-Log "Restart required: $AnyRebootRequired"

if ($RemovalFailed) {
    Write-Log "Exit Code : 3"
    exit 3
}

if ($AnyRebootRequired) {
    Write-Log "Exit Code : 3010"

    if ($AutomaticReboot) {
        Write-Log "Automatic reboot enabled. Restarting in 60 seconds."

        shutdown.exe `
            /r `
            /t 60 `
            /c ".NET full-stack remediation"
    }

    exit 3010
}

Write-Log "Exit Code : 0"
exit 0
