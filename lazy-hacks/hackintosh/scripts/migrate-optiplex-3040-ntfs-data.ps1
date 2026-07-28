[CmdletBinding()]
param(
    [ValidateSet("Audit", "Copy", "Verify")]
    [string]$Mode = "Audit",

    [switch]$FullHash,

    [switch]$SetLabels
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-ExactSize {
    param(
        [Parameter(Mandatory = $true)]$Partition,
        [Parameter(Mandatory = $true)][UInt64]$ExpectedBytes
    )

    if ([UInt64]$Partition.Size -ne $ExpectedBytes) {
        throw "Partition $($Partition.PartitionNumber) has unexpected size: $($Partition.Size) bytes, expected $ExpectedBytes"
    }
}

function Assert-OneOfExactSizes {
    param(
        [Parameter(Mandatory = $true)]$Partition,
        [Parameter(Mandatory = $true)][UInt64[]]$ExpectedBytes
    )

    if ([UInt64]$Partition.Size -notin $ExpectedBytes) {
        throw "Partition $($Partition.PartitionNumber) has unexpected size: $($Partition.Size) bytes"
    }
}

function Assert-Windows7Installation {
    param([Parameter(Mandatory = $true)]$Volume)

    $root = "$($Volume.DriveLetter):\"
    $requiredPaths = @(
        (Join-Path $root "bootmgr"),
        (Join-Path $root "Boot\BCD"),
        (Join-Path $root "Windows\System32\winload.exe"),
        (Join-Path $root "Windows\System32\ntoskrnl.exe")
    )
    foreach ($path in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The Windows 7 candidate is missing a required boot file: $path"
        }
    }

    $kernelPath = Join-Path $root "Windows\System32\ntoskrnl.exe"
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($kernelPath)
    if (
        $version.FileMajorPart -ne 6 -or
        $version.FileMinorPart -ne 1 -or
        $version.FileBuildPart -ne 7601
    ) {
        throw "Partition 1 is not the audited Windows 7 SP1 installation: $($version.FileVersion)"
    }

    [pscustomobject]@{
        Root = $root
        Kernel = $kernelPath
        FileVersion = $version.FileVersion
        ProductVersion = $version.ProductVersion
    }
}

function Assert-RunningWindows10 {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($operatingSystem.Caption -notmatch "Windows 10") {
        throw "The running system is not Windows 10: $($operatingSystem.Caption)"
    }
    return $operatingSystem
}

function Get-VolumeForPartition {
    param([Parameter(Mandatory = $true)]$Partition)

    if (-not $Partition.DriveLetter) {
        throw "Partition $($Partition.PartitionNumber) has no drive letter. Assign one in Disk Management and rerun Audit."
    }

    $volume = Get-Volume -DriveLetter $Partition.DriveLetter
    if ($volume.FileSystem -ne "NTFS") {
        throw "Partition $($Partition.PartitionNumber) is not NTFS: $($volume.FileSystem)"
    }
    return $volume
}

function Get-DataFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $excluded = @('$RECYCLE.BIN', 'System Volume Information')
    $children = Get-ChildItem -LiteralPath $Root -Force |
        Where-Object { $excluded -notcontains $_.Name }

    foreach ($child in $children) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning "Skipping reparse point: $($child.FullName)"
            continue
        }
        if ($child.PSIsContainer) {
            Get-ChildItem -LiteralPath $child.FullName -File -Recurse -Force
        }
        else {
            $child
        }
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $prefix = $Root.TrimEnd('\') + '\'
    if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside root: $Path"
    }
    return $Path.Substring($prefix.Length)
}

function Verify-Tree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][bool]$HashFiles
    )

    $sourceFiles = @(Get-DataFiles -Root $Source)
    $destinationFiles = @(Get-DataFiles -Root $Destination)
    $destinationIndex = @{}
    foreach ($file in $destinationFiles) {
        $relative = Get-RelativePath -Root $Destination -Path $file.FullName
        $destinationIndex[$relative] = $file
    }

    if ($sourceFiles.Count -ne $destinationFiles.Count) {
        throw "File count mismatch for $Source -> ${Destination}: $($sourceFiles.Count) != $($destinationFiles.Count)"
    }

    $checked = 0
    foreach ($sourceFile in $sourceFiles) {
        $relative = Get-RelativePath -Root $Source -Path $sourceFile.FullName
        if (-not $destinationIndex.ContainsKey($relative)) {
            throw "Destination is missing: $relative"
        }
        $destinationFile = $destinationIndex[$relative]
        if ($sourceFile.Length -ne $destinationFile.Length) {
            throw "Length mismatch: $relative"
        }
        if ($HashFiles) {
            $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $destinationFile.FullName -Algorithm SHA256).Hash
            if ($sourceHash -ne $destinationHash) {
                throw "SHA-256 mismatch: $relative"
            }
        }
        $checked++
        if (($checked % 500) -eq 0) {
            Write-Host "Verified $checked of $($sourceFiles.Count) files from $Source"
        }
    }

    [pscustomobject]@{
        Source = $Source
        Destination = $Destination
        FileCount = $sourceFiles.Count
        TotalBytes = [long](($sourceFiles | Measure-Object -Property Length -Sum).Sum)
        FullHash = $HashFiles
        Verified = $true
    }
}

function Invoke-SafeRobocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @(
        $Source,
        $Destination,
        "/E",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/XJ",
        "/R:2",
        "/W:2",
        "/MT:8",
        "/ZB",
        "/NP",
        "/TEE",
        "/LOG+:$LogPath",
        "/XD",
        (Join-Path $Source '$RECYCLE.BIN'),
        (Join-Path $Source 'System Volume Information')
    )
    & robocopy @arguments
    $result = $LASTEXITCODE
    if ($result -ge 8) {
        throw "Robocopy failed with exit code $result. Read $LogPath"
    }
    Write-Host "Robocopy completed with accepted exit code $result"
}

$candidates = @(
    Get-Disk |
        Where-Object {
            $_.PartitionStyle -eq "GPT" -and
            $_.Size -gt 900GB -and
            $_.Size -lt 1100GB
        }
)
if ($candidates.Count -ne 1) {
    throw "Expected exactly one 1 TB GPT disk; found $($candidates.Count)"
}
$disk = $candidates[0]
$diskIdentity = "$($disk.FriendlyName) $($disk.Model)".Trim()
if ($diskIdentity -notmatch "TOSHIBA" -or $diskIdentity -notmatch "DT01ACA100") {
    throw "The 1 TB disk is not the audited Toshiba DT01ACA100: $diskIdentity"
}
$partitions = @(Get-Partition -DiskNumber $disk.Number | Sort-Object Offset)
if ($partitions.Count -notin @(5, 6)) {
    throw "Expected five pre-staging or six post-staging partitions on disk $($disk.Number); found $($partitions.Count)"
}

$windows7Partition = $partitions | Where-Object Offset -eq 1048576
$dataDogPartition = $partitions | Where-Object Offset -eq 107377328128
$dataEarPartition = $partitions | Where-Object Offset -eq 405877555200
$appleDataPartition = $partitions | Where-Object Offset -eq 488557772800
$dataFirePartition = $partitions | Where-Object Offset -eq 703306137600
$macRecoveryPartition = $partitions | Where-Object Offset -eq 995909173248
foreach ($role in @(
    $windows7Partition,
    $dataDogPartition,
    $dataEarPartition,
    $dataFirePartition,
    $macRecoveryPartition
)) {
    if (-not $role) {
        throw "An audited partition offset is missing from the Toshiba disk"
    }
}
Assert-ExactSize $windows7Partition 107375230976
Assert-ExactSize $dataDogPartition 298499178496
Assert-OneOfExactSizes $dataEarPartition @(
    [UInt64]297427533824,
    [UInt64]6838812672
)
Assert-ExactSize $dataFirePartition 292603035648
Assert-ExactSize $macRecoveryPartition 4294967296
if ($appleDataPartition) {
    Assert-ExactSize $appleDataPartition 214748364800
    if (
        $appleDataPartition.GptType -ne
        "{7c3457ef-0000-11aa-aa11-00306543ecac}"
    ) {
        throw "The 200 GiB region is not the audited Apple APFS partition"
    }
}

$windows7Volume = Get-VolumeForPartition $windows7Partition
$dataDogVolume = Get-VolumeForPartition $dataDogPartition
$dataEarVolume = Get-VolumeForPartition $dataEarPartition
$dataFireVolume = Get-VolumeForPartition $dataFirePartition
$windows7Identity = Assert-Windows7Installation $windows7Volume
$windows10Identity = Assert-RunningWindows10
if (
    $macRecoveryPartition.GptType -ne
    "{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}"
) {
    throw "The final partition is not the audited MACRECOVERY EFI partition"
}

$source2 = "$($dataDogVolume.DriveLetter):\"
$source3 = "$($dataEarVolume.DriveLetter):\"
$destinationRoot = "$($dataFireVolume.DriveLetter):\"
$destination2 = Join-Path $destinationRoot "data dog"
$destination3 = Join-Path $destinationRoot "data ear"
$statusRoot = Join-Path $destinationRoot "DISK-MIGRATION"

$summary = [pscustomobject]@{
    Timestamp = (Get-Date).ToUniversalTime().ToString("o")
    Mode = $Mode
    DiskNumber = $disk.Number
    DiskModel = $disk.Model
    Windows7 = "$($windows7Volume.DriveLetter):"
    Windows7Version = $windows7Identity.FileVersion
    Windows10 = $windows10Identity.Caption
    Windows10Version = $windows10Identity.Version
    SourcePartition2 = $source2
    SourcePartition3 = $source3
    DestinationPartition4 = $destinationRoot
    Destination2 = $destination2
    Destination3 = $destination3
    AppleDataStaging = if ($appleDataPartition) { "200 GiB APFS-type partition present" } else { "not staged" }
    FullHash = [bool]$FullHash
}
$summary | Format-List

if ($Mode -eq "Audit") {
    Write-Host "Audit complete. No label, file, or partition was changed."
    exit 0
}

if ($SetLabels) {
    Set-Volume -DriveLetter $windows7Volume.DriveLetter -NewFileSystemLabel "Windows 7"
    Set-Volume -DriveLetter $dataDogVolume.DriveLetter -NewFileSystemLabel "data dog"
    Set-Volume -DriveLetter $dataEarVolume.DriveLetter -NewFileSystemLabel "data ear"
    Set-Volume -DriveLetter $dataFireVolume.DriveLetter -NewFileSystemLabel "data fire"
    Set-Content -LiteralPath "$($windows7Volume.DriveLetter):\.contentDetails" -Value "Windows 7" -Encoding Ascii -NoNewline
    Set-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -NewFileSystemLabel "Windows 10"
    if ((Get-Content -LiteralPath "$($windows7Volume.DriveLetter):\.contentDetails" -Raw) -ne "Windows 7") {
        throw "The Windows 7 OpenCore label did not verify after writing"
    }
}

New-Item -ItemType Directory -Force -Path $statusRoot | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $statusRoot "robocopy-$timestamp.log"

if ($Mode -eq "Copy") {
    Invoke-SafeRobocopy -Source $source2 -Destination $destination2 -LogPath $logPath
    Invoke-SafeRobocopy -Source $source3 -Destination $destination3 -LogPath $logPath
}

$verification = @(
    Verify-Tree -Source $source2 -Destination $destination2 -HashFiles ([bool]$FullHash)
    Verify-Tree -Source $source3 -Destination $destination3 -HashFiles ([bool]$FullHash)
)
$record = [pscustomobject]@{
    Summary = $summary
    Verification = $verification
    ConversionApproved = [bool]$FullHash
}
$recordPath = Join-Path $statusRoot "verified-$timestamp.json"
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recordPath -Encoding UTF8
Write-Host "Verification record: $recordPath"
Write-Host "No source file or partition was deleted or formatted."
