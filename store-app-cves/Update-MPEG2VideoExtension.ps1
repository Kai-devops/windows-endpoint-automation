# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PackageName = 'Microsoft.MPEG2VideoExtension'
$MinimumVersion = [version]'1.2.32.0'
$DeploymentVersion = [version]'1.2.32.0'

$SourceBundle = '\\<HEAD_OFFICE_SERVER>\Share\Applications\Microsoft.MPEG2VideoExtension_1.2.32.0_neutral_~_8wekyb3d8bbwe_2211.AppxBundle'
$WorkDir = 'C:\ProgramData\YourCompany\MPEG2VideoUpdate'
$LocalBundle = Join-Path $WorkDir 'Microsoft.MPEG2VideoExtension_1.2.32.0.AppxBundle'
$DismLog = Join-Path $WorkDir 'Dism-MPEG2VideoExtension.log'

function Get-InstalledPackages {
    return @(
        Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending
    )
}

function Get-ProvisionedPackages {
    return @(
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $PackageName }
    )
}

function Test-AllPackagesPatched {
    $versions = @()
    $versions += @(Get-InstalledPackages | ForEach-Object { [version]$_.Version })
    $versions += @(Get-ProvisionedPackages | ForEach-Object { [version]$_.Version })

    if ($versions.Count -eq 0) { return $true }

    foreach ($version in $versions) {
        if ($version -lt $MinimumVersion) { return $false }
    }

    return $true
}

function Show-State {
    param([string]$Label)

    Write-Host "--- $Label ---"

    $installed = @(Get-InstalledPackages)
    $provisioned = @(Get-ProvisionedPackages)

    if ($installed.Count -eq 0) {
        Write-Host 'Installed AppX: none'
    }
    else {
        foreach ($pkg in $installed) {
            Write-Host ("Installed AppX: {0} | {1}" -f $pkg.Version, $pkg.PackageFullName)
        }
    }

    if ($provisioned.Count -eq 0) {
        Write-Host 'Provisioned AppX: none'
    }
    else {
        foreach ($pkg in $provisioned) {
            Write-Host ("Provisioned AppX: {0} | {1}" -f $pkg.Version, $pkg.PackageName)
        }
    }
}

Write-Host '=== MPEG-2 Video Extension CVE-2026-70343 Remediation ==='

$installedBefore = @(Get-InstalledPackages)
$provisionedBefore = @(Get-ProvisionedPackages)

if (($installedBefore.Count + $provisionedBefore.Count) -eq 0) {
    Write-Host 'COMPLIANT: Microsoft.MPEG2VideoExtension is not installed or provisioned.'
    exit 0
}

Show-State -Label 'Before'

if (Test-AllPackagesPatched) {
    Write-Host "COMPLIANT: Every detected Microsoft.MPEG2VideoExtension package is >= $MinimumVersion."
    exit 0
}

$badVersions = @()
$badVersions += @($installedBefore | ForEach-Object { [version]$_.Version } | Where-Object { $_ -lt $MinimumVersion })
$badVersions += @($provisionedBefore | ForEach-Object { [version]$_.Version } | Where-Object { $_ -lt $MinimumVersion })

Write-Host ('VULNERABLE: package version(s) below {0}: {1}' -f $MinimumVersion, (($badVersions | Sort-Object -Unique) -join ', '))

try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    if (-not (Test-Path -LiteralPath $SourceBundle -PathType Leaf)) {
        throw "Source AppxBundle was not found: $SourceBundle"
    }

    Copy-Item -LiteralPath $SourceBundle -Destination $LocalBundle -Force

    $localFile = Get-Item -LiteralPath $LocalBundle -ErrorAction Stop
    if ($localFile.Length -le 0) {
        throw 'The staged AppxBundle is empty.'
    }

    Write-Host ("Staged MPEG-2 AppxBundle: {0} bytes" -f $localFile.Length)

    $dismArgs = @(
        '/Online',
        '/Add-ProvisionedAppxPackage',
        "/PackagePath:$LocalBundle",
        '/SkipLicense',
        "/LogPath:$DismLog"
    )

    $process = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList $dismArgs -Wait -PassThru -WindowStyle Hidden
    Write-Host "DISM exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0) {
        throw "DISM failed with exit code $($process.ExitCode). Log: $DismLog"
    }

    Start-Sleep -Seconds 3
    Show-State -Label 'After'

    if (-not (Test-AllPackagesPatched)) {
        throw 'DISM completed, but one or more installed/provisioned MPEG-2 packages remain below the patched threshold.'
    }

    Remove-Item -LiteralPath $LocalBundle -Force -ErrorAction SilentlyContinue
    Write-Host "SUCCESS: Microsoft.MPEG2VideoExtension is compliant (minimum $MinimumVersion; deployed $DeploymentVersion)."
    exit 0
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
    Write-Host "Staged package retained if present: $LocalBundle"
    Write-Host "DISM log: $DismLog"
    exit 1
}
