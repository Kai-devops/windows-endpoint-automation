# Windows Endpoint Automation

PowerShell scripts for patching and maintaining Windows endpoints at scale. They are written to run unattended from an RMM or deployment tool as `SYSTEM`, pull installers from a file share close to the machine, log what they do, and by default never restart the machine.

> These scripts were extracted from a real environment. Every site-specific value (server names, subnets, folder names) has been replaced with a placeholder. See [Configuration](#configuration) before running anything.

## Contents

| Folder | Script | What it does |
| --- | --- | --- |
| `os-updates` | `Update-WindowsCumulative.ps1` | Installs the monthly Windows cumulative security update through the Windows Update Agent. Target KB and revision per OS build live in the `$MonthlyTargets` table in the main block. |
| `os-updates` | `Install-Windows11-25H2-to-26H2.ps1` | Installs a staged `.msu` (set `$KBFileName`) on machines currently on build 26200 (25H2). |
| `os-updates` | `Install-Windows11-24H2-to-25H2.ps1` | Installs the 24H2 to 25H2 enablement KB on eligible machines, after checking the package signature. |
| `store-app-cves` | `Update-MPEG2VideoExtension.ps1` | Remediates CVE-2026-70343 in `Microsoft.MPEG2VideoExtension`. |
| `store-app-cves` | `Update-HEIFImageExtension.ps1` | Remediates CVE-2026-81353 in `Microsoft.HEIFImageExtension`. |
| `store-app-cves` | `Update-WebMediaExtensions.ps1` | Remediates CVE-2026-81352 in `Microsoft.WebMediaExtensions`. |
| `dotnet` | `Update-DotNetFramework.ps1` | Installs the right .NET Framework 4.8 / 4.8.1 update for the machine's OS build, using a CSV manifest. |
| `dotnet` | `Update-DotNetRuntimes.ps1` | Installs the .NET 10 Desktop and ASP.NET Core runtimes, then removes older runtime families. |
| `app-updates` | `Update-ThirdPartyApps.ps1` | Updates common third-party apps from the share, with a per-app `winget` fallback. |
| `maintenance` | `Invoke-StorageRemediation.ps1` | Audits and frees disk space on the system drive. |

## Requirements

- Windows PowerShell 5.1
- Run elevated or as `SYSTEM`
- A file share holding the installers and packages (layout below)

## Configuration

### Placeholders

| Placeholder | Replace with | Used in |
| --- | --- | --- |
| `<HEAD_OFFICE_SERVER>` | Host name of the central file server that holds the `Share\Applications` folder | Every script that reads from the share |
| `<BRANCHnn_PROBE>` | Host name of the file server for branch `nn` | Branch maps in `Install-Windows11-25H2-to-26H2.ps1`, `Install-Windows11-24H2-to-25H2.ps1`, `Update-ThirdPartyApps.ps1` |
| `<BRANCHnn_SUBNET>` | First three octets of that branch's IPv4 subnet, for example `192.0.2` | Same branch maps |
| `<HEAD_OFFICE_SUBNET>` | First three octets of the head office subnet | Same branch maps |
| `<HEAD_OFFICE_ALT1_SUBNET>`, `<HEAD_OFFICE_ALT2_SUBNET>` | Additional head office subnets | `Update-ThirdPartyApps.ps1` only |
| `YourCompany` | Folder name under `C:\ProgramData` for logs and staged files | Store-app scripts and the three branch-map scripts |

Branch map entries have the form `Name`, `Subnet`, `ProbeShare`. Add, remove or rename rows to match your sites. Two subnets can point at the same share, as `Branch11` and `Branch12` do.

### How the share is found

The branch-map scripts read the machine's IPv4 address, match its first three octets against `Subnet`, and use that row's `ProbeShare`. `Install-Windows11-25H2-to-26H2.ps1` and `Install-Windows11-24H2-to-25H2.ps1` skip the machine when nothing matches. `Update-ThirdPartyApps.ps1` falls back to the `Branch02` row instead, and falls back to `winget` for each app if that share is unreachable.

### Share layout

```
\\<server>\Share\
    Applications\
        <installers, .msu files and .AppxBundle files>
        DotNetFrameworkUpdates\
            UpdateManifest.csv
            <KB number>\<file matching the manifest's FilePattern>.msu
        dotnet_uninstall\dotnet-core-uninstall.exe
        OracleJava\
        AdobeReaderDC\Deploy-AdobeReaderDC.ps1
```

Installer file names the scripts expect are set in each script's configuration block. For `Update-ThirdPartyApps.ps1`, see the `$Apps` table.

`UpdateManifest.csv` needs these columns: `Build`, `FrameworkBranch`, `TargetKB`, `FilePattern`, `Description`. `FilePattern` must be a bare file name wildcard with no folder path.

### Values to update when new patches ship

- `Update-WindowsCumulative.ps1`: the `$MonthlyTargets` table (KB and revision per OS build)
- `Install-Windows11-25H2-to-26H2.ps1`: `$KBFileName`
- `Install-Windows11-24H2-to-25H2.ps1`: `$KBFileName`
- Store-app scripts: `$MinimumVersion` (or `$MinimumV1` / `$MinimumV2`) and the `$SourceBundle` file name
- `Update-DotNetRuntimes.ps1`: `$TargetVersion` and the installer paths

## Script notes

### Windows updates

**`Update-WindowsCumulative.ps1`** uses the Windows Update Agent only, with no `.msu` fallback. It temporarily opens the Windows Update API while keeping the Settings page restricted, keeps the device awake during the run, and restores the original policy and power plan on exit. It never reboots. If a reboot is needed, it saves a pending-validation record, and the next run checks the build and reports success or a rollback. It stores state and logs in `%ProgramData%\WindowsCumulativeUpdate`.

Parameters: `-TargetKB`, `-TargetRevision`, `-MinimumFreeSpaceGB`, `-PolicyGuardIntervalSeconds`, `-WorkingDirectory`, `-DownloadOnly`.

```powershell
.\Update-WindowsCumulative.ps1 -DownloadOnly
```

Exit codes include `0` (success, already compliant, or download only), `1` (failed), `3` (unsupported build), `4` (target KB not offered), `10` (staged, reboot required), `11` (installed, validation pending) and `20` (not committed after reboot).

**`Install-Windows11-25H2-to-26H2.ps1`** logs a transcript, keeps the ten most recent logs, checks the machine is on build 26200, runs `wusa.exe` silently with `/norestart`, and prints one greppable `RESULT:` line.

**`Install-Windows11-24H2-to-25H2.ps1`** only runs on Windows 11 client installs (not Server or LTSC), on x64, build 26100 with a minimum revision. It requires a valid Authenticode signature from Microsoft on the `.msu`. Each skip or failure reason has its own exit code.

### Store app CVEs

All three scripts check installed and provisioned packages against a minimum version. If anything is below it, they copy the `.AppxBundle` locally, provision it with `DISM /Add-ProvisionedAppxPackage /SkipLicense`, re-check, and delete the staged copy. Exit code `0` means compliant or fixed and `1` means failure.

`Update-WebMediaExtensions.ps1` has separate minimums for the 1.x and 2.x branches. It only deploys the 2.x bundle, so a vulnerable 1.x package exits with code `8` instead of being forced onto 2.x. Any other noncompliant case exits with `9`.

### .NET

**`Update-DotNetFramework.ps1`** requires .NET Framework 4.8 or later. It matches OS build and framework branch against the manifest, installs the matching `.msu`, and falls back to Windows Update if no file is found and `$AllowWindowsUpdateFallback` is `$true`. Set `$AutomaticReboot` to restart automatically. It is `$false` by default.

Exit codes: `0` success or already installed, `1` error, `3` KB not detected after install, `3010` restart required, `4` unsupported or configuration problem.

**`Update-DotNetRuntimes.ps1`** installs the .NET 10 Desktop and ASP.NET Core runtimes, confirms the whole stack, then removes the runtime families listed in `$VersionsConfiguredForRemoval` with the `dotnet-core-uninstall` tool. It stops before changing anything if applications depending on an older runtime are running, and it skips the removal step if the .NET 10 stack cannot be verified.

Exit codes: `0` success, `1` failure, `2` dependent applications running, `3` an older version was not removed, `3010` restart required.

### Applications

**`Update-ThirdPartyApps.ps1`** works through the `$Apps` table: Chrome, Edge, Adobe Reader, TeamViewer, FortiClient VPN, Oracle Java, 7-Zip and QZ Tray, plus a version check for Teams. It prefers an MSI, falls back to an EXE, and can call a custom deployment script. When free space on `C:` drops below 5 GB, it cleans temp folders first.

### Maintenance

**`Invoke-StorageRemediation.ps1`** runs in `Audit` mode by default and only reports. `-Mode Remediate` deletes temp files and Windows Error Reporting archives older than `-TempRetentionDays` (7 by default), deletes minidumps and crash dumps older than 30 days, and clears an RMM agent cache folder. That cache path and service name are hard-coded, so adjust or remove them for your environment. It runs a standard DISM component cleanup if space is still short. It writes CSV and JSON reports under `%ProgramData%\StorageRemediation`.

Optional switches:

- `-ApplyOutlookCachePolicy`: sets Classic Outlook's cached-mail window to three months.
- `-AllowOstDeletion`: if free space is still below the minimum after cleanup, queues a scheduled task that deletes oversized OST files once Outlook is closed. It never touches PST files.
- `-ForceDeepScan`: scans the whole system drive for large files and folders.

```powershell
.\Invoke-StorageRemediation.ps1
.\Invoke-StorageRemediation.ps1 -Mode Remediate -MinimumFreeGB 40 -TargetFreeGB 45
```

Exit codes: `0` pass, `1` fatal error, `2` invalid threshold values, `3` not elevated, `4` another instance running, `1001` still below the minimum free space after the run.

## Safety

These scripts install updates, change system settings, and in one case delete files. Test them on non-production machines first and review each script before deploying it. They are provided as-is, with no warranty.

## Author

Created and owned by Cáden/Kai Samputh. GitHub: [Kai-devops](https://github.com/Kai-devops)

Copyright (c) 2026 Cáden/Kai Samputh.
