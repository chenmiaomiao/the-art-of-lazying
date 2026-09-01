[CmdletBinding()]
param(
    [ValidateSet("Apply", "Status", "Restore")]
    [string]$Mode = "Status",

    [string]$StateRoot = "$env:ProgramData\LazyingArt\WindowsAlwaysOn",

    [string]$BackupPath = "",

    [string]$ResultPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$scriptFilePath = $PSCommandPath

$powerSettings = @(
    [pscustomobject]@{
        Name = "Display timeout"
        Subgroup = "7516b95f-f776-4464-8c53-06167f40cc99"
        Setting = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"
        MachinePolicy = $true
    },
    [pscustomobject]@{
        Name = "Console-lock display timeout"
        Subgroup = "7516b95f-f776-4464-8c53-06167f40cc99"
        Setting = "8ec4b3a5-6868-48c2-be75-4f3044be88a7"
        MachinePolicy = $false
    },
    [pscustomobject]@{
        Name = "Sleep timeout"
        Subgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
        Setting = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"
        MachinePolicy = $true
    },
    [pscustomobject]@{
        Name = "Unattended sleep timeout"
        Subgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
        Setting = "7bc4a2f9-d8fc-4469-b07b-33eb785aaca0"
        MachinePolicy = $true
    },
    [pscustomobject]@{
        Name = "Hibernate timeout"
        Subgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
        Setting = "9d7815a6-7ee4-497e-8888-515a05f02364"
        MachinePolicy = $true
    },
    [pscustomobject]@{
        Name = "Hybrid sleep"
        Subgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
        Setting = "94ac6d29-73ce-41a6-809f-6363ba21b47e"
        MachinePolicy = $true
    }
)

$installStatePath = Join-Path $StateRoot "install-state.json"
$defaultBackupPath = Join-Path $StateRoot "state-before-first-apply.json"
$powerPolicyBase = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings"
$windowsUpdatePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$automaticUpdatePolicy = Join-Path $windowsUpdatePolicy "AU"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 12
    $temporaryPath = Join-Path $parent (".{0}.tmp-{1}" -f ([IO.Path]::GetFileName($fullPath)), ([guid]::NewGuid()))
    $replacementBackupPath = Join-Path $parent (".{0}.bak-{1}" -f ([IO.Path]::GetFileName($fullPath)), ([guid]::NewGuid()))
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            $json + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false))
        )
        if (Test-Path -LiteralPath $fullPath) {
            [IO.File]::Replace($temporaryPath, $fullPath, $replacementBackupPath)
            Remove-Item -LiteralPath $replacementBackupPath -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replacementBackupPath) {
            Remove-Item -LiteralPath $replacementBackupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ElevatedSelf {
    $scriptPath = $script:scriptFilePath
    if (-not $scriptPath) {
        throw "The script path could not be determined for elevation."
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $scriptPath),
        "-Mode", $Mode,
        "-StateRoot", ('"{0}"' -f $StateRoot)
    )
    if ($BackupPath) {
        $arguments += @("-BackupPath", ('"{0}"' -f $BackupPath))
    }
    if ($ResultPath) {
        $arguments += @("-ResultPath", ('"{0}"' -f $ResultPath))
    }

    try {
        $process = Start-Process powershell.exe `
            -Verb RunAs `
            -WindowStyle Hidden `
            -ArgumentList ($arguments -join " ") `
            -PassThru `
            -Wait
    }
    catch {
        $failure = [ordered]@{
            SchemaVersion = 1
            Success = $false
            Mode = $Mode
            Computer = $env:COMPUTERNAME
            Error = "Elevation failed or was cancelled: $($_.Exception.Message)"
        }
        try {
            if ($ResultPath) {
                Write-JsonFile -Value $failure -Path $ResultPath
            }
        } catch {}
        $failure | ConvertTo-Json -Depth 6
        exit 1
    }

    if ($ResultPath -and (Test-Path -LiteralPath $ResultPath)) {
        Get-Content -LiteralPath $ResultPath -Raw
    }
    exit $process.ExitCode
}

function Invoke-PowerCfg {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & "$env:SystemRoot\System32\powercfg.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    return @($output)
}

function Get-ActivePowerSchemeGuid {
    $output = Invoke-PowerCfg -Arguments @("/getactivescheme")
    $match = [regex]::Match(($output -join " "), "[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
    if (-not $match.Success) {
        throw "Could not parse the active power-scheme GUID."
    }
    return $match.Value.ToLowerInvariant()
}

function Test-PowerSchemeExists {
    param([Parameter(Mandatory = $true)][string]$SchemeGuid)

    $output = Invoke-PowerCfg -Arguments @("/list")
    return ($output -join " ") -match [regex]::Escape($SchemeGuid)
}

function Get-PowerSettingState {
    param(
        [Parameter(Mandatory = $true)][string]$SchemeGuid,
        [Parameter(Mandatory = $true)]$Definition
    )

    $output = Invoke-PowerCfg -Arguments @(
        "/qh",
        $SchemeGuid,
        $Definition.Subgroup,
        $Definition.Setting
    )
    $matches = [regex]::Matches(($output -join [Environment]::NewLine), "0x[0-9a-fA-F]{8}")
    if ($matches.Count -lt 2) {
        throw "Could not read $($Definition.Name) from power scheme $SchemeGuid."
    }

    return [pscustomobject]@{
        Name = $Definition.Name
        Subgroup = $Definition.Subgroup
        Setting = $Definition.Setting
        AC = [Convert]::ToUInt32($matches[$matches.Count - 2].Value.Substring(2), 16)
        DC = [Convert]::ToUInt32($matches[$matches.Count - 1].Value.Substring(2), 16)
    }
}

function Get-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $exists = $false
    $kind = $null
    $data = $null
    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if (@($key.GetValueNames()) -contains $Name) {
            $exists = $true
            $kind = [string]$key.GetValueKind($Name)
            $data = Get-ItemPropertyValue -LiteralPath $Path -Name $Name
        }
    }

    return [pscustomobject]@{
        Path = $Path
        Name = $Name
        Exists = $exists
        Kind = $kind
        Data = $data
    }
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("DWord", "String")][string]$Kind,
        [Parameter(Mandatory = $true)]$Data
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Kind -Value $Data -Force | Out-Null
}

function Restore-RegistryValue {
    param([Parameter(Mandatory = $true)]$Snapshot)

    if (-not [bool]$Snapshot.Exists) {
        if (Test-Path -LiteralPath $Snapshot.Path) {
            Remove-ItemProperty -LiteralPath $Snapshot.Path -Name $Snapshot.Name -ErrorAction SilentlyContinue
        }
        return
    }

    switch ([string]$Snapshot.Kind) {
        "DWord" {
            Set-RegistryValue -Path $Snapshot.Path -Name $Snapshot.Name -Kind DWord -Data ([uint32]$Snapshot.Data)
        }
        "String" {
            Set-RegistryValue -Path $Snapshot.Path -Name $Snapshot.Name -Kind String -Data ([string]$Snapshot.Data)
        }
        default {
            throw "Unsupported saved registry kind '$($Snapshot.Kind)' for $($Snapshot.Path)\$($Snapshot.Name)."
        }
    }
}

function Assert-RollbackBackup {
    param([Parameter(Mandatory = $true)]$Backup)

    $properties = @($Backup.PSObject.Properties.Name)
    foreach ($required in @("SchemaVersion", "Computer", "UserSid", "OriginalActivePowerSchemeGuid", "HibernateEnabled", "RegistryValues")) {
        if ($properties -notcontains $required) {
            throw "Rollback backup is missing required property '$required'."
        }
    }
    if ([int]$Backup.SchemaVersion -ne 1) {
        throw "Unsupported rollback-backup schema version."
    }
    if ([string]$Backup.OriginalActivePowerSchemeGuid -notmatch "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$") {
        throw "Rollback backup contains an invalid original power-scheme GUID."
    }

    $snapshots = @($Backup.RegistryValues)
    $expected = @(Get-DesiredRegistryValues | ForEach-Object { "$($_.Path)|$($_.Name)" })
    $actual = @($snapshots | ForEach-Object { "$($_.Path)|$($_.Name)" })
    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Rollback backup is incomplete; missing $($missing -join ', ')."
    }
    foreach ($snapshot in $snapshots) {
        $snapshotProperties = @($snapshot.PSObject.Properties.Name)
        foreach ($required in @("Path", "Name", "Exists", "Kind", "Data")) {
            if ($snapshotProperties -notcontains $required) {
                throw "A rollback registry snapshot is missing '$required'."
            }
        }
        if ($snapshot.Exists -and [string]$snapshot.Kind -notin @("DWord", "String")) {
            throw "Rollback registry kind '$($snapshot.Kind)' is unsupported."
        }
    }
}

function Get-DesiredRegistryValues {
    $os = Get-CimInstance Win32_OperatingSystem
    $currentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $productVersion = "Windows 10"
    if ($os.Caption -match "Windows 11") {
        $productVersion = "Windows 11"
    }
    $displayVersion = [string]$currentVersion.DisplayVersion
    if (-not $displayVersion) {
        throw "Windows DisplayVersion is empty; refusing to create a feature-version pin."
    }

    $desired = @(
        [pscustomobject]@{ Path = $automaticUpdatePolicy; Name = "NoAutoUpdate"; Kind = "DWord"; Data = 1 },
        [pscustomobject]@{ Path = $automaticUpdatePolicy; Name = "AUOptions"; Kind = "DWord"; Data = 2 },
        [pscustomobject]@{ Path = $automaticUpdatePolicy; Name = "NoAutoRebootWithLoggedOnUsers"; Kind = "DWord"; Data = 1 },
        [pscustomobject]@{ Path = $automaticUpdatePolicy; Name = "AlwaysAutoRebootAtScheduledTime"; Kind = "DWord"; Data = 0 },
        [pscustomobject]@{ Path = $windowsUpdatePolicy; Name = "ProductVersion"; Kind = "String"; Data = $productVersion },
        [pscustomobject]@{ Path = $windowsUpdatePolicy; Name = "TargetReleaseVersion"; Kind = "DWord"; Data = 1 },
        [pscustomobject]@{ Path = $windowsUpdatePolicy; Name = "TargetReleaseVersionInfo"; Kind = "String"; Data = $displayVersion },
        [pscustomobject]@{ Path = $windowsUpdatePolicy; Name = "SetComplianceDeadlineForFU"; Kind = "DWord"; Data = 0 },
        [pscustomobject]@{ Path = $windowsUpdatePolicy; Name = "SetComplianceDeadlineForQU"; Kind = "DWord"; Data = 0 },
        [pscustomobject]@{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; Name = "AutoReboot"; Kind = "DWord"; Data = 0 },
        [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "InactivityTimeoutSecs"; Kind = "DWord"; Data = 0 },
        [pscustomobject]@{ Path = "HKCU:\Control Panel\Desktop"; Name = "ScreenSaveActive"; Kind = "String"; Data = "0" },
        [pscustomobject]@{ Path = "HKCU:\Control Panel\Desktop"; Name = "ScreenSaveTimeOut"; Kind = "String"; Data = "0" },
        [pscustomobject]@{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop"; Name = "ScreenSaveActive"; Kind = "String"; Data = "0" },
        [pscustomobject]@{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop"; Name = "ScreenSaverIsSecure"; Kind = "String"; Data = "0" }
    )

    foreach ($definition in $powerSettings | Where-Object MachinePolicy) {
        $path = Join-Path $powerPolicyBase $definition.Setting
        $desired += [pscustomobject]@{ Path = $path; Name = "ACSettingIndex"; Kind = "DWord"; Data = 0 }
        $desired += [pscustomobject]@{ Path = $path; Name = "DCSettingIndex"; Kind = "DWord"; Data = 0 }
    }

    return $desired
}

function Get-WindowsAlwaysOnStatus {
    $activeScheme = Get-ActivePowerSchemeGuid
    $settings = @(
        foreach ($definition in $powerSettings) {
            Get-PowerSettingState -SchemeGuid $activeScheme -Definition $definition
        }
    )
    $desired = @(Get-DesiredRegistryValues)
    $registry = @(
        foreach ($item in $desired) {
            Get-RegistryValueSnapshot -Path $item.Path -Name $item.Name
        }
    )

    $powerCompliant = $true
    foreach ($setting in $settings) {
        if ($setting.AC -ne 0 -or $setting.DC -ne 0) {
            $powerCompliant = $false
        }
    }

    $registryCompliant = $true
    foreach ($target in $desired) {
        $actual = $registry | Where-Object { $_.Path -eq $target.Path -and $_.Name -eq $target.Name } | Select-Object -First 1
        if (-not $actual -or -not $actual.Exists -or [string]$actual.Data -ne [string]$target.Data) {
            $registryCompliant = $false
        }
    }

    $hibernateValue = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    $hibernateEnabled = [bool]$hibernateValue
    $services = @(
        Get-Service wuauserv, UsoSvc, WaaSMedicSvc, bits -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType
    )
    $pendingReboot = [ordered]@{
        ComponentBasedServicing = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
        WindowsUpdate = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        PendingFileRename = [bool](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
    }

    $configurationCompliant = $powerCompliant -and -not $hibernateEnabled -and $registryCompliant
    $pendingRebootDetected = [bool](
        $pendingReboot.ComponentBasedServicing -or
        $pendingReboot.WindowsUpdate -or
        $pendingReboot.PendingFileRename
    )

    return [ordered]@{
        SchemaVersion = 1
        CheckedAt = [DateTimeOffset]::Now.ToString("o")
        Computer = $env:COMPUTERNAME
        CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ActivePowerSchemeGuid = $activeScheme
        PowerSettings = $settings
        HibernateEnabled = $hibernateEnabled
        RegistryValues = $registry
        WindowsUpdateServices = $services
        PendingReboot = $pendingReboot
        PowerCompliant = $powerCompliant -and -not $hibernateEnabled
        RegistryCompliant = $registryCompliant
        ConfigurationCompliant = $configurationCompliant
        PendingRebootDetected = $pendingRebootDetected
        SafeForUnattendedUptime = $configurationCompliant -and -not $pendingRebootDetected
        Compliant = $configurationCompliant
    }
}

function Save-InitialBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$DesiredRegistryValues
    )

    if (Test-Path -LiteralPath $Path) {
        return
    }

    $snapshots = @(
        foreach ($item in $DesiredRegistryValues) {
            Get-RegistryValueSnapshot -Path $item.Path -Name $item.Name
        }
    )
    $hibernateValue = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    $backup = [ordered]@{
        SchemaVersion = 1
        CreatedAt = [DateTimeOffset]::Now.ToString("o")
        Computer = $env:COMPUTERNAME
        UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        OriginalActivePowerSchemeGuid = Get-ActivePowerSchemeGuid
        HibernateEnabled = [bool]$hibernateValue
        RegistryValues = $snapshots
    }
    Write-JsonFile -Value $backup -Path $Path
}

function Get-OrCreateAlwaysOnScheme {
    param([Parameter(Mandatory = $true)][string]$SourceSchemeGuid)

    if (Test-Path -LiteralPath $installStatePath) {
        $state = Get-Content -LiteralPath $installStatePath -Raw | ConvertFrom-Json
        if ($state.Computer -and $state.Computer -ne $env:COMPUTERNAME) {
            throw "The install state belongs to computer '$($state.Computer)'."
        }
        if ($state.OriginalActivePowerSchemeGuid -and $state.OriginalActivePowerSchemeGuid -ne $SourceSchemeGuid) {
            throw "The install state refers to a different original power scheme."
        }
        if ($state.AlwaysOnPowerSchemeGuid -and (Test-PowerSchemeExists -SchemeGuid $state.AlwaysOnPowerSchemeGuid)) {
            return [string]$state.AlwaysOnPowerSchemeGuid
        }
    }

    $requestedGuid = ([guid]::NewGuid()).ToString()
    $output = Invoke-PowerCfg -Arguments @("/duplicatescheme", $SourceSchemeGuid, $requestedGuid)
    $createdGuid = $requestedGuid
    if (-not (Test-PowerSchemeExists -SchemeGuid $createdGuid)) {
        $match = [regex]::Match(($output -join " "), "[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
        if (-not $match.Success) {
            throw "Could not identify the cloned always-on power scheme."
        }
        $createdGuid = $match.Value.ToLowerInvariant()
    }

    Invoke-PowerCfg -Arguments @(
        "/changename",
        $createdGuid,
        "LazyingArt Always On",
        "No automatic display blanking, sleep, or hibernation"
    ) | Out-Null
    return $createdGuid
}

function Invoke-PolicyRefresh {
    $process = Start-Process "$env:SystemRoot\System32\gpupdate.exe" `
        -ArgumentList @("/target:computer", "/force", "/wait:30") `
        -WindowStyle Hidden `
        -PassThru
    if (-not $process.WaitForExit(45000)) {
        $process.Kill()
        return "Timed out after 45 seconds; registry policies are already written."
    }
    return "Exit code $($process.ExitCode)"
}

function Invoke-Apply {
    $desired = @(Get-DesiredRegistryValues)
    $existingState = $null
    if (Test-Path -LiteralPath $installStatePath) {
        $existingState = Get-Content -LiteralPath $installStatePath -Raw | ConvertFrom-Json
        if ([int]$existingState.SchemaVersion -ne 1) {
            throw "Unsupported install-state schema version."
        }
        if ($existingState.Computer -ne $env:COMPUTERNAME) {
            throw "The install state belongs to computer '$($existingState.Computer)'."
        }
        $effectiveBackupPath = [IO.Path]::GetFullPath([string]$existingState.BackupPath)
        if ($BackupPath -and [IO.Path]::GetFullPath($BackupPath) -ne $effectiveBackupPath) {
            throw "This installation is bound to backup '$effectiveBackupPath'; a different -BackupPath is unsafe."
        }
    } else {
        $effectiveBackupPath = $BackupPath
        if (-not $effectiveBackupPath) {
            $effectiveBackupPath = $defaultBackupPath
        }
        $effectiveBackupPath = [IO.Path]::GetFullPath($effectiveBackupPath)
    }

    Save-InitialBackup -Path $effectiveBackupPath -DesiredRegistryValues $desired
    $backup = Get-Content -LiteralPath $effectiveBackupPath -Raw | ConvertFrom-Json
    Assert-RollbackBackup -Backup $backup
    if ($backup.Computer -ne $env:COMPUTERNAME) {
        throw "The backup belongs to computer '$($backup.Computer)', not '$env:COMPUTERNAME'."
    }
    if ($backup.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw "The backup belongs to a different Windows user."
    }
    if ($existingState -and $existingState.OriginalActivePowerSchemeGuid -ne $backup.OriginalActivePowerSchemeGuid) {
        throw "Install state and rollback backup disagree about the original power scheme."
    }

    $schemeGuid = Get-OrCreateAlwaysOnScheme -SourceSchemeGuid $backup.OriginalActivePowerSchemeGuid
    $createdAt = [DateTimeOffset]::Now.ToString("o")
    if ($existingState -and $existingState.CreatedAt) {
        $createdAt = [string]$existingState.CreatedAt
    }
    $state = [ordered]@{
        SchemaVersion = 1
        CreatedAt = $createdAt
        LastAppliedAt = [DateTimeOffset]::Now.ToString("o")
        Computer = $env:COMPUTERNAME
        BackupPath = $effectiveBackupPath
        OriginalActivePowerSchemeGuid = [string]$backup.OriginalActivePowerSchemeGuid
        AlwaysOnPowerSchemeGuid = $schemeGuid
    }
    Write-JsonFile -Value $state -Path $installStatePath

    foreach ($definition in $powerSettings) {
        Invoke-PowerCfg -Arguments @("/setacvalueindex", $schemeGuid, $definition.Subgroup, $definition.Setting, "0") | Out-Null
        Invoke-PowerCfg -Arguments @("/setdcvalueindex", $schemeGuid, $definition.Subgroup, $definition.Setting, "0") | Out-Null
    }
    Invoke-PowerCfg -Arguments @("/setactive", $schemeGuid) | Out-Null
    Invoke-PowerCfg -Arguments @("/hibernate", "off") | Out-Null

    foreach ($target in $desired) {
        Set-RegistryValue -Path $target.Path -Name $target.Name -Kind $target.Kind -Data $target.Data
    }

    & "$env:SystemRoot\System32\rundll32.exe" user32.dll,UpdatePerUserSystemParameters 1, True | Out-Null
    $policyRefresh = Invoke-PolicyRefresh
    $status = Get-WindowsAlwaysOnStatus
    if (-not $status.ConfigurationCompliant) {
        throw "Settings were written, but post-apply verification is not compliant."
    }

    return [ordered]@{
        SchemaVersion = 1
        Success = $true
        Mode = "Apply"
        FinishedAt = [DateTimeOffset]::Now.ToString("o")
        BackupPath = $effectiveBackupPath
        InstallStatePath = $installStatePath
        AlwaysOnPowerSchemeGuid = $schemeGuid
        PolicyRefresh = $policyRefresh
        Status = $status
    }
}

function Get-RestoreVerification {
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [string]$CreatedSchemeGuid
    )

    $registryMismatches = @()
    foreach ($snapshot in $Backup.RegistryValues) {
        $actual = Get-RegistryValueSnapshot -Path $snapshot.Path -Name $snapshot.Name
        $matches = [bool]$actual.Exists -eq [bool]$snapshot.Exists
        if ($matches -and $snapshot.Exists) {
            $matches = ([string]$actual.Kind -eq [string]$snapshot.Kind) -and
                ([string]$actual.Data -eq [string]$snapshot.Data)
        }
        if (-not $matches) {
            $registryMismatches += "$($snapshot.Path)\$($snapshot.Name)"
        }
    }

    $hibernateValue = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    $hibernateRestored = [bool]$hibernateValue -eq [bool]$Backup.HibernateEnabled
    $activeSchemeRestored = (Get-ActivePowerSchemeGuid) -eq [string]$Backup.OriginalActivePowerSchemeGuid
    $createdSchemeRemoved = $true
    if ($CreatedSchemeGuid -and $CreatedSchemeGuid -ne $Backup.OriginalActivePowerSchemeGuid) {
        $createdSchemeRemoved = -not (Test-PowerSchemeExists -SchemeGuid $CreatedSchemeGuid)
    }

    return [ordered]@{
        RegistryRestored = $registryMismatches.Count -eq 0
        RegistryMismatches = $registryMismatches
        HibernateRestored = $hibernateRestored
        ActivePowerSchemeRestored = $activeSchemeRestored
        CreatedPowerSchemeRemoved = $createdSchemeRemoved
        Verified = ($registryMismatches.Count -eq 0) -and $hibernateRestored -and $activeSchemeRestored -and $createdSchemeRemoved
    }
}

function Invoke-Restore {
    $effectiveBackupPath = $null
    if (Test-Path -LiteralPath $installStatePath) {
        $installState = Get-Content -LiteralPath $installStatePath -Raw | ConvertFrom-Json
        if ([int]$installState.SchemaVersion -ne 1 -or $installState.Computer -ne $env:COMPUTERNAME) {
            throw "Install state is invalid or belongs to another computer."
        }
        $effectiveBackupPath = [IO.Path]::GetFullPath([string]$installState.BackupPath)
        if ($BackupPath -and [IO.Path]::GetFullPath($BackupPath) -ne $effectiveBackupPath) {
            throw "This installation is bound to backup '$effectiveBackupPath'; a different -BackupPath is unsafe."
        }
    } elseif ($BackupPath) {
        $effectiveBackupPath = [IO.Path]::GetFullPath($BackupPath)
    }
    if (-not $effectiveBackupPath) {
        $effectiveBackupPath = $defaultBackupPath
    }
    if (-not (Test-Path -LiteralPath $effectiveBackupPath)) {
        throw "Rollback backup not found: $effectiveBackupPath"
    }

    $backup = Get-Content -LiteralPath $effectiveBackupPath -Raw | ConvertFrom-Json
    Assert-RollbackBackup -Backup $backup
    if ($backup.Computer -ne $env:COMPUTERNAME) {
        throw "The backup belongs to computer '$($backup.Computer)', not '$env:COMPUTERNAME'."
    }
    if ($backup.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw "The backup belongs to a different Windows user."
    }
    if (-not (Test-PowerSchemeExists -SchemeGuid $backup.OriginalActivePowerSchemeGuid)) {
        throw "Original power scheme $($backup.OriginalActivePowerSchemeGuid) no longer exists."
    }

    foreach ($snapshot in $backup.RegistryValues) {
        Restore-RegistryValue -Snapshot $snapshot
    }

    if ([bool]$backup.HibernateEnabled) {
        Invoke-PowerCfg -Arguments @("/hibernate", "on") | Out-Null
    } else {
        Invoke-PowerCfg -Arguments @("/hibernate", "off") | Out-Null
    }

    Invoke-PowerCfg -Arguments @("/setactive", [string]$backup.OriginalActivePowerSchemeGuid) | Out-Null

    $removedScheme = $null
    $createdScheme = $null
    if (Test-Path -LiteralPath $installStatePath) {
        $installState = Get-Content -LiteralPath $installStatePath -Raw | ConvertFrom-Json
        $candidate = [string]$installState.AlwaysOnPowerSchemeGuid
        $createdScheme = $candidate
        if ($candidate -and $candidate -ne $backup.OriginalActivePowerSchemeGuid -and (Test-PowerSchemeExists -SchemeGuid $candidate)) {
            Invoke-PowerCfg -Arguments @("/delete", $candidate) | Out-Null
            $removedScheme = $candidate
        }
    }

    & "$env:SystemRoot\System32\rundll32.exe" user32.dll,UpdatePerUserSystemParameters 1, True | Out-Null
    $policyRefresh = Invoke-PolicyRefresh
    $verification = Get-RestoreVerification -Backup $backup -CreatedSchemeGuid $createdScheme
    if (-not $verification.Verified) {
        throw "Rollback completed with verification mismatches: $($verification | ConvertTo-Json -Compress -Depth 6)"
    }

    return [ordered]@{
        SchemaVersion = 1
        Success = $true
        Mode = "Restore"
        FinishedAt = [DateTimeOffset]::Now.ToString("o")
        BackupPath = $effectiveBackupPath
        RestoredPowerSchemeGuid = [string]$backup.OriginalActivePowerSchemeGuid
        RemovedAlwaysOnPowerSchemeGuid = $removedScheme
        PolicyRefresh = $policyRefresh
        RestoreVerification = $verification
        Status = Get-WindowsAlwaysOnStatus
    }
}

if ($Mode -ne "Status" -and -not $ResultPath) {
    $ResultPath = Join-Path $StateRoot ("last-{0}-result.json" -f $Mode.ToLowerInvariant())
}

if ($Mode -ne "Status" -and -not (Test-Administrator)) {
    Invoke-ElevatedSelf
}

$startedAt = [DateTimeOffset]::Now
try {
    switch ($Mode) {
        "Status" {
            $result = Get-WindowsAlwaysOnStatus
        }
        "Apply" {
            $result = Invoke-Apply
        }
        "Restore" {
            $result = Invoke-Restore
        }
    }

    $json = $result | ConvertTo-Json -Depth 12
    if ($ResultPath) {
        Write-JsonFile -Value $result -Path $ResultPath
    }
    $json
}
catch {
    $failure = [ordered]@{
        SchemaVersion = 1
        Success = $false
        Mode = $Mode
        StartedAt = $startedAt.ToString("o")
        FinishedAt = [DateTimeOffset]::Now.ToString("o")
        Computer = $env:COMPUTERNAME
        Error = $_.Exception.Message
    }
    if ($ResultPath) {
        Write-JsonFile -Value $failure -Path $ResultPath
    }
    $failure | ConvertTo-Json -Depth 8
    exit 1
}
