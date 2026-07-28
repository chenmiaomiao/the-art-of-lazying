# Read-only Windows 11 and multi-boot readiness inventory for a Dell OptiPlex 3040.
[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Optional {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        $Fallback
    )

    try {
        & $Action
    } catch {
        $Fallback
    }
}

function Get-RegistryValueDescription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item -or $null -eq $item.PSObject.Properties[$Name]) {
        return $null
    }

    [pscustomobject]@{
        Path = $Path
        Name = $Name
        Value = [string]$item.$Name
    }
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$processors = @(Get-CimInstance -ClassName Win32_Processor)
$bios = Get-CimInstance -ClassName Win32_BIOS
$currentVersion = Get-ItemProperty `
    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$systemDriveLetter = $env:SystemDrive.TrimEnd(':')
$systemPartition = Get-Partition -DriveLetter $systemDriveLetter
$systemDisk = Get-Disk -Number $systemPartition.DiskNumber
$disks = @(Get-Disk | Sort-Object Number)
$volumes = @(Get-Volume | Sort-Object DriveLetter, FileSystemLabel)

$firmwareType = Invoke-Optional {
    $value = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control').PEFirmwareType
    switch ($value) {
        1 { 'BIOS' }
        2 { 'UEFI' }
        default { "Unknown ($value)" }
    }
} 'Unknown'

$secureBoot = Invoke-Optional {
    [bool](Confirm-SecureBootUEFI)
} 'Unavailable'

$tpm = Invoke-Optional {
    $value = Get-Tpm
    [pscustomobject]@{
        Present = [bool]$value.TpmPresent
        Ready = [bool]$value.TpmReady
        Enabled = [bool]$value.TpmEnabled
        Activated = [bool]$value.TpmActivated
        ManufacturerVersion = [string]$value.ManufacturerVersion
    }
} ([pscustomobject]@{
    Present = $false
    Ready = $false
    Enabled = $false
    Activated = $false
    ManufacturerVersion = 'Unavailable'
})

$tpmSpecVersion = Invoke-Optional {
    [string](Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm).SpecVersion
} 'Unavailable'

$bitLocker = Invoke-Optional {
    @(Get-BitLockerVolume | ForEach-Object {
        [pscustomobject]@{
            MountPoint = [string]$_.MountPoint
            VolumeStatus = [string]$_.VolumeStatus
            ProtectionStatus = [string]$_.ProtectionStatus
            EncryptionMethod = [string]$_.EncryptionMethod
        }
    })
} @()

$activation = Invoke-Optional {
    $windowsApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    @(Get-CimInstance -ClassName SoftwareLicensingProduct |
        Where-Object {
            $_.ApplicationID -eq $windowsApplicationId -and
            $null -ne $_.PartialProductKey
        } |
        ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                Description = [string]$_.Description
                PartialProductKey = [string]$_.PartialProductKey
                LicenseStatus = [int]$_.LicenseStatus
                Licensed = ([int]$_.LicenseStatus -eq 1)
            }
        })
} @()

$activeSetupProcesses = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match '^(setup|setupprep|Windows10UpgraderApp|Windows11InstallationAssistant)$'
        } |
        Select-Object ProcessName, Id, StartTime
)

$automaticStartEntries = @()
$runLocations = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)

foreach ($location in $runLocations) {
    if (-not (Test-Path -LiteralPath $location)) {
        continue
    }

    $properties = (Get-ItemProperty -LiteralPath $location).PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }

    foreach ($property in $properties) {
        if ([string]$property.Value -match '(?i)Windows11|InstallationAssistant|setup\.exe|setupprep') {
            $automaticStartEntries += [pscustomobject]@{
                Path = $location
                Name = $property.Name
                Value = [string]$property.Value
            }
        }
    }
}

$upgradeTaskMatches = @(
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -match '(?i)Windows11|InstallationAssistant' -or
            $_.TaskPath -match '(?i)Windows11|InstallationAssistant'
        } |
        Select-Object TaskPath, TaskName, State
)

$pendingRebootIndicators = @()
$pendingPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
    'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
)

foreach ($path in $pendingPaths) {
    if (Test-Path -LiteralPath $path) {
        $pendingRebootIndicators += $path
    }
}

$windowsUpdateTargets = @(
    Get-RegistryValueDescription `
        -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
        -Name 'ProductVersion'
    Get-RegistryValueDescription `
        -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
        -Name 'TargetReleaseVersionInfo'
) | Where-Object { $null -ne $_ }

$diskReport = @($disks | ForEach-Object {
    [pscustomobject]@{
        Number = [int]$_.Number
        FriendlyName = [string]$_.FriendlyName
        SerialNumber = [string]$_.SerialNumber
        BusType = [string]$_.BusType
        PartitionStyle = [string]$_.PartitionStyle
        OperationalStatus = [string]$_.OperationalStatus
        IsBoot = [bool]$_.IsBoot
        IsSystem = [bool]$_.IsSystem
        SizeGiB = [math]::Round($_.Size / 1GB, 2)
    }
})

$volumeReport = @($volumes | ForEach-Object {
    [pscustomobject]@{
        DriveLetter = [string]$_.DriveLetter
        FileSystemLabel = [string]$_.FileSystemLabel
        FileSystem = [string]$_.FileSystem
        HealthStatus = [string]$_.HealthStatus
        SizeGiB = [math]::Round($_.Size / 1GB, 2)
        FreeGiB = [math]::Round($_.SizeRemaining / 1GB, 2)
    }
})

$cpuNames = @($processors | ForEach-Object { [string]$_.Name.Trim() })
$cpuStatus = if ($cpuNames -match 'i7-6700') {
    'Unsupported'
} else {
    'Unknown - compare the exact CPU with the current Microsoft list'
}

$memoryGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
$systemVolume = Get-Volume -DriveLetter $systemDriveLetter
$minimumChecks = [ordered]@{
    MemoryAtLeast4GiB = ($memoryGiB -ge 4)
    SystemVolumeAtLeast64GiB = ($systemVolume.Size -ge 64GB)
    FirmwareIsUefi = ($firmwareType -eq 'UEFI')
    SecureBootEnabled = ($secureBoot -eq $true)
    TpmPresentAndReady = ($tpm.Present -and $tpm.Ready)
    TpmSpecIncludes20 = ($tpmSpecVersion -match '(^|,\s*)2\.0(,|$)')
    CpuOnSupportedList = ($cpuStatus -eq 'Supported')
}

$report = [ordered]@{
    GeneratedAt = (Get-Date).ToString('o')
    ReadOnlyAudit = $true
    Computer = [ordered]@{
        Manufacturer = [string]$computer.Manufacturer
        Model = [string]$computer.Model
        Name = [string]$computer.Name
        BiosVersion = [string]($bios.SMBIOSBIOSVersion)
        BiosDate = [string]$bios.ReleaseDate
        FirmwareType = $firmwareType
        SecureBoot = $secureBoot
        MemoryGiB = $memoryGiB
    }
    Windows = [ordered]@{
        Caption = [string]$operatingSystem.Caption
        ProductName = [string]$currentVersion.ProductName
        EditionId = [string]$currentVersion.EditionID
        DisplayVersion = [string]$currentVersion.DisplayVersion
        Version = [string]$operatingSystem.Version
        BuildNumber = [string]$operatingSystem.BuildNumber
        Architecture = [string]$operatingSystem.OSArchitecture
        InstalledUiLanguage = [string][cultureinfo]::InstalledUICulture.Name
        SystemDrive = [string]$env:SystemDrive
        SystemDiskNumber = [int]$systemDisk.Number
        SystemDiskName = [string]$systemDisk.FriendlyName
        SystemVolumeFreeGiB = [math]::Round($systemVolume.SizeRemaining / 1GB, 2)
    }
    Cpu = [ordered]@{
        Names = $cpuNames
        MicrosoftListStatus = $cpuStatus
    }
    Tpm = [ordered]@{
        Present = $tpm.Present
        Ready = $tpm.Ready
        Enabled = $tpm.Enabled
        Activated = $tpm.Activated
        SpecVersion = $tpmSpecVersion
        ManufacturerVersion = $tpm.ManufacturerVersion
    }
    MinimumChecks = $minimumChecks
    Disks = $diskReport
    Volumes = $volumeReport
    BitLocker = $bitLocker
    Activation = $activation
    ActiveSetupProcesses = $activeSetupProcesses
    AutomaticStartEntries = $automaticStartEntries
    UpgradeScheduledTasks = $upgradeTaskMatches
    PendingRebootIndicators = $pendingRebootIndicators
    WindowsUpdateTargets = $windowsUpdateTargets
    Conclusion = 'Unsupported CPU: preparation only; no Windows 11 upgrade was started.'
}

$json = $report | ConvertTo-Json -Depth 8
$report

if ($OutputDirectory) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path $resolvedOutput "windows11-readiness-$stamp.json"
    $textPath = Join-Path $resolvedOutput "windows11-readiness-$stamp.txt"
    Set-Content -LiteralPath $jsonPath -Value $json -Encoding UTF8
    $report | Format-List * | Out-String -Width 240 |
        Set-Content -LiteralPath $textPath -Encoding UTF8
    Write-Information "Reports: $jsonPath" -InformationAction Continue
    Write-Information "         $textPath" -InformationAction Continue
}
