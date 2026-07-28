[CmdletBinding()]
param(
    [ValidateSet("Audit", "Fetch")]
    [string]$Mode = "Audit"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProgressPreference = "SilentlyContinue"

$stageRoot = "G:\UPGRADE\Windows11-25H2"
$expectedDiskModel = "TOSHIBA DT01ACA100"
$expectedDiskSize = [UInt64]1000204886016
$expectedPartitionOffset = [UInt64]703306137600
$expectedPartitionSize = [UInt64]292603035648

function Assert-StageVolume {
    $partition = Get-Partition -DriveLetter G
    $disk = Get-Disk -Number $partition.DiskNumber
    $volume = Get-Volume -DriveLetter G

    if ("$($disk.FriendlyName) $($disk.Model)" -notmatch [regex]::Escape($expectedDiskModel)) {
        throw "G: is not on the audited $expectedDiskModel disk"
    }
    if ([UInt64]$disk.Size -ne $expectedDiskSize) {
        throw "The Toshiba disk has unexpected size: $($disk.Size)"
    }
    if (
        [UInt64]$partition.Offset -ne $expectedPartitionOffset -or
        [UInt64]$partition.Size -ne $expectedPartitionSize
    ) {
        throw "G: does not match the audited Data Fire partition geometry"
    }
    if ($volume.FileSystem -ne "NTFS") {
        throw "G: is not NTFS"
    }

    [pscustomobject]@{
        Drive = "G:"
        Label = $volume.FileSystemLabel
        FileSystem = $volume.FileSystem
        Size = [UInt64]$volume.Size
        FreeBytes = [UInt64]$volume.SizeRemaining
        Disk = $expectedDiskModel
        PartitionOffset = [UInt64]$partition.Offset
        PartitionSize = [UInt64]$partition.Size
    }
}

function Get-HardwareAudit {
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $systemVolume = Get-Volume -DriveLetter C
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk

    try {
        $tpm = Get-Tpm
    }
    catch {
        $tpm = $null
    }
    try {
        $secureBoot = [bool](Confirm-SecureBootUEFI)
    }
    catch {
        $secureBoot = $false
    }
    try {
        $firmwareType = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType
    }
    catch {
        $firmwareType = $null
    }

    $memoryBytes = [UInt64]$computer.TotalPhysicalMemory
    $systemDiskBytes = [UInt64]$systemDisk.Size
    $tpmPresent = [bool]($tpm -and $tpm.TpmPresent)
    $tpmReady = [bool]($tpm -and $tpm.TpmReady)
    $uefi = $firmwareType -eq 2
    $gpt = $systemDisk.PartitionStyle -eq "GPT"
    $ramPass = $memoryBytes -ge 4GB
    $storagePass = $systemDiskBytes -ge 64GB

    [pscustomobject]@{
        CapturedAt = (Get-Date).ToString("o")
        Computer = $env:COMPUTERNAME
        Manufacturer = $computer.Manufacturer
        Model = $computer.Model
        Processor = $cpu.Name.Trim()
        ProcessorAddressWidth = $cpu.AddressWidth
        ProcessorCompatibility = "Run Microsoft's PC Health Check for the authoritative supported-CPU result; Intel Core i7-6700 is not on Microsoft's Windows 11 supported Intel processor list."
        MemoryBytes = $memoryBytes
        MemoryMinimumPass = $ramPass
        OperatingSystem = $os.Caption
        OperatingSystemVersion = $os.Version
        OperatingSystemBuild = $os.BuildNumber
        SystemDriveFreeBytes = [UInt64]$systemVolume.SizeRemaining
        SystemDiskBytes = $systemDiskBytes
        SystemDiskStyle = "$($systemDisk.PartitionStyle)"
        StorageMinimumPass = $storagePass
        FirmwareType = "$firmwareType"
        UefiPass = $uefi
        SecureBootEnabled = $secureBoot
        TpmPresent = $tpmPresent
        TpmReady = $tpmReady
        BiosVersion = $bios.SMBIOSBIOSVersion
        MicrosoftMinimumGatesPass = (
            $ramPass -and
            $storagePass -and
            $uefi -and
            $gpt -and
            $secureBoot -and
            $tpmPresent -and
            $tpmReady
        )
        UpgradeStarted = $false
    }
}

function Get-VerifiedMicrosoftDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $temporary = "$Destination.download"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary

    $signature = Get-AuthenticodeSignature -FilePath $temporary
    if ($signature.Status -ne "Valid") {
        Remove-Item -LiteralPath $temporary -Force
        throw "Authenticode validation failed for $Uri`: $($signature.Status)"
    }
    if (-not $signature.SignerCertificate.Subject.Contains("Microsoft Corporation")) {
        Remove-Item -LiteralPath $temporary -Force
        throw "The downloaded executable was not signed by Microsoft Corporation"
    }

    Move-Item -LiteralPath $temporary -Destination $Destination -Force
    [pscustomobject]@{
        File = Split-Path -Leaf $Destination
        Source = $Uri
        Bytes = (Get-Item -LiteralPath $Destination).Length
        SHA256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        SignatureStatus = "$($signature.Status)"
        Signer = $signature.SignerCertificate.Subject
        ProductVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($Destination).ProductVersion
        Executed = $false
    }
}

$stageVolume = Assert-StageVolume
$audit = Get-HardwareAudit

if ($Mode -eq "Audit") {
    [pscustomobject]@{
        StageVolume = $stageVolume
        Hardware = $audit
        Mode = $Mode
    } | ConvertTo-Json -Depth 6
    exit 0
}

New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
$downloads = @(
    Get-VerifiedMicrosoftDownload `
        -Uri "https://go.microsoft.com/fwlink/?linkid=2156295" `
        -Destination (Join-Path $stageRoot "MediaCreationTool-Windows11-25H2.exe")
    Get-VerifiedMicrosoftDownload `
        -Uri "https://aka.ms/GetPCHealthCheckApp" `
        -Destination (Join-Path $stageRoot "WindowsPCHealthCheckSetup.msi")
)

$record = [pscustomobject]@{
    PreparedAt = (Get-Date).ToString("o")
    StageRoot = $stageRoot
    StageVolume = $stageVolume
    Hardware = $audit
    Downloads = $downloads
    UpgradeStarted = $false
    Warning = "Preparation only. No installer was executed. Do not run these tools until the unsupported CPU, missing TPM 2.0, Secure Boot/OpenCore compatibility, backup, and rollback plan have been reviewed."
}
$recordPath = Join-Path $stageRoot "windows11-readiness.json"
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding UTF8

@"
WINDOWS 11 UPGRADE IS NOT STARTED

This directory contains only staged, Microsoft-signed readiness tools.
The preparation script never executes either file.

Current audited blockers:
- Intel Core i7-6700 is not on Microsoft's supported Windows 11 CPU list.
- No TPM is detected.
- Secure Boot is disabled because this machine also uses OpenCore.

Do not enable Secure Boot or start an upgrade without revalidating the
OpenCore boot path, complete backups, and a tested rollback procedure.
Read windows11-readiness.json before doing anything.
"@ | Set-Content -LiteralPath (Join-Path $stageRoot "DO-NOT-RUN-YET.txt") -Encoding UTF8

$record | ConvertTo-Json -Depth 8
