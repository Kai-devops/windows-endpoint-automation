# Copyright (c) 2026 Cáden/Kai Samputh. All rights reserved.
# Created and owned by Cáden/Kai Samputh.
# GitHub: https://github.com/Kai-devops

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PackageName = 'Microsoft.WebMediaExtensions'
$MinimumV1 = [version]'1.2.42.0'
$MinimumV2 = [version]'2.1.51.0'

$SourceBundle = '\\<HEAD_OFFICE_SERVER>\Share\Applications\Microsoft.WebMediaExtensions_2.1.51.0_neutral_~_8wekyb3d8bbwe_7788.AppxBundle'
$WorkDir = 'C:\ProgramData\YourCompany\WebMediaUpdate'
$LocalBundle = Join-Path $WorkDir 'Microsoft.WebMediaExtensions_2.1.51.0.AppxBundle'
$DismLog = Join-Path $WorkDir 'Dism-WebMediaExtensions.log'

function Test-PatchedVersion {
    param([version]$Version)

    if (-not $Version) { return $false }
    if ($Version.Major -eq 1) { return ($Version -ge $MinimumV1) }
    if ($Version.Major -ge 2) { return ($Version -ge $MinimumV2) }
    return $false
}

function Get-WebMediaPackages {
    return @(
        Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending
    )
}

function Get-ProvisionedWebMediaPackages {
    return @(
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $PackageName }
    )
}

function Show-State {
    param([string]$Label)

    Write-Host "--- $Label ---"

    $installed = @(Get-WebMediaPackages)
    if ($installed.Count -eq 0) {
        Write-Host 'Installed AppX: none'
    }
    else {
        foreach ($pkg in $installed) {
            Write-Host ("Installed AppX: {0} | {1}" -f $pkg.Version, $pkg.PackageFullName)
        }
    }

    $provisioned = @(Get-ProvisionedWebMediaPackages)
    if ($provisioned.Count -eq 0) {
        Write-Host 'Provisioned AppX: none'
    }
    else {
        foreach ($pkg in $provisioned) {
            Write-Host ("Provisioned AppX: {0} | {1}" -f $pkg.Version, $pkg.PackageName)
        }
    }
}

function Test-AllPackagesPatched {
    $items = @()
    $items += @(Get-WebMediaPackages | ForEach-Object { [version]$_.Version })
    $items += @(Get-ProvisionedWebMediaPackages | ForEach-Object { [version]$_.Version })

    if ($items.Count -eq 0) { return $true }

    foreach ($version in $items) {
        if (-not (Test-PatchedVersion $version)) { return $false }
    }

    return $true
}

Write-Host '=== Web Media Extensions CVE-2026-81352 Remediation ==='

$currentPackages = @(Get-WebMediaPackages)
$currentProvisioned = @(Get-ProvisionedWebMediaPackages)

if (($currentPackages.Count + $currentProvisioned.Count) -eq 0) {
    Write-Host 'COMPLIANT: Microsoft.WebMediaExtensions is not installed or provisioned.'
    exit 0
}

Show-State -Label 'Before'

if (Test-AllPackagesPatched) {
    Write-Host 'COMPLIANT: Every detected Microsoft.WebMediaExtensions package meets its branch threshold.'
    exit 0
}

$allVersions = @()
$allVersions += @($currentPackages | ForEach-Object { [version]$_.Version })
$allVersions += @($currentProvisioned | ForEach-Object { [version]$_.Version })

$vulnerableV1 = @($allVersions | Where-Object { $_.Major -eq 1 -and $_ -lt $MinimumV1 })
$vulnerableV2 = @($allVersions | Where-Object { $_.Major -ge 2 -and $_ -lt $MinimumV2 })

if ($vulnerableV1.Count -gt 0) {
    Write-Host ('FAILED: A vulnerable 1.x package was detected: {0}' -f (($vulnerableV1 | Sort-Object -Unique) -join ', '))
    Write-Host "This deployment contains the 2.x bundle. It will not force a 2.x package onto a 1.x branch. Required 1.x minimum: $MinimumV1"
    exit 8
}

if ($vulnerableV2.Count -eq 0) {
    Write-Host 'FAILED: A noncompliant package was detected, but it is not a supported 1.x or 2.x remediation case.'
    exit 9
}

Write-Host ('VULNERABLE: 2.x package(s) below {0}: {1}' -f $MinimumV2, (($vulnerableV2 | Sort-Object -Unique) -join ', '))

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

    Write-Host ("Staged AppxBundle: {0} bytes" -f $localFile.Length)

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
        throw 'DISM completed, but one or more installed/provisioned packages remain below the patched threshold.'
    }

    Remove-Item -LiteralPath $LocalBundle -Force -ErrorAction SilentlyContinue
    Write-Host 'SUCCESS: Microsoft.WebMediaExtensions is compliant.'
    exit 0
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
    Write-Host "Staged package retained if present: $LocalBundle"
    Write-Host "DISM log: $DismLog"
    exit 1
}
