[CmdletBinding()]
param(
    [ValidateSet("Audit", "Cleanup")]
    [string]$Mode = "Audit",

    [string]$Confirm = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ExpectedDescription = "Monterey Native Graphics Test"
$ExpectedPath = "\EFI\OC\OpenCore.efi"
$ExpectedDiskModel = "Samsung SSD 860 PRO 256GB"
$ExpectedOpenCoreSha256 =
    "8e83a3dd984a4196c1fd9e40d75a6550111a959e44c0668bd9e08098bf0a1ae6"
$ExpectedMarker = "optiplex-3040-monterey-native-v1"
$CleanupConfirmation = "CLEANUP-3040-NATIVE-TEST"

function Fail {
    param([string]$Message)
    throw $Message
}

function Invoke-BcdEdit {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $output = & bcdedit @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "bcdedit $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    return @($output)
}

function Get-TemporaryEntry {
    $firmwareText = (Invoke-BcdEdit /enum firmware /v) -join "`n"
    $blocks = $firmwareText -split "(?:\r?\n){2,}"
    $matchingBlocks = @(
        $blocks | Where-Object {
            $_ -match (
                "(?m)^description\s+" +
                [Regex]::Escape($ExpectedDescription) +
                "\s*$"
            )
        }
    )

    if ($matchingBlocks.Count -eq 0) {
        return $null
    }
    if ($matchingBlocks.Count -ne 1) {
        Fail "found $($matchingBlocks.Count) temporary firmware entries"
    }

    $block = $matchingBlocks[0]
    $identifierMatch = [Regex]::Match(
        $block,
        "(?m)^identifier\s+(\{[0-9a-fA-F-]{36}\})\s*$"
    )
    $pathMatch = [Regex]::Match($block, "(?m)^path\s+(.+?)\s*$")
    $deviceMatch = [Regex]::Match($block, "(?m)^device\s+(.+?)\s*$")
    if (-not $identifierMatch.Success -or -not $pathMatch.Success) {
        Fail "temporary firmware entry is missing its identifier or path"
    }
    if ($pathMatch.Groups[1].Value -ne $ExpectedPath) {
        Fail "temporary firmware entry has unexpected path: $($pathMatch.Groups[1].Value)"
    }
    if (-not $deviceMatch.Success) {
        Fail "temporary firmware entry has no device"
    }

    return [PSCustomObject]@{
        Identifier = $identifierMatch.Groups[1].Value
        Path = $pathMatch.Groups[1].Value
        Device = $deviceMatch.Groups[1].Value
        FirmwareText = $firmwareText
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
if (-not $principal.IsInRole($adminRole)) {
    Fail "run from an elevated PowerShell or administrative OpenSSH session"
}
$computerSystem = Get-CimInstance Win32_ComputerSystem
if ($computerSystem.Manufacturer -notmatch "Dell" -or
    $computerSystem.Model -notmatch "OptiPlex 3040") {
    Fail "this script is limited to the reviewed Dell OptiPlex 3040"
}

$disk = Get-Disk |
    Where-Object { $_.FriendlyName -eq $ExpectedDiskModel }
if (@($disk).Count -ne 1) {
    Fail "could not uniquely identify the Samsung system SSD"
}
$partition = Get-Partition -DiskNumber $disk.Number |
    Where-Object { $_.Type -eq "System" }
if (@($partition).Count -ne 1 -or $partition.Type -ne "System") {
    Fail "could not uniquely identify the reviewed Windows ESP"
}

$mountLetter = "S"
$existingDrive = Get-PSDrive -Name $mountLetter -ErrorAction SilentlyContinue
if ($null -ne $existingDrive) {
    Fail "$($mountLetter): is already in use"
}

try {
    $mountOutput = & mountvol "${mountLetter}:" /S 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "could not mount the Windows ESP: $($mountOutput -join ' ')"
    }
    # mountvol-assigned ESP letters are not reflected by Get-Partition
    # -DriveLetter on all Windows builds. Compare stable volume GUID paths.
    $mountedVolumeOutput = @(& mountvol "${mountLetter}:" /L 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Fail "could not identify the mounted ESP: $($mountedVolumeOutput -join ' ')"
    }
    $mountedVolume = (
        ($mountedVolumeOutput -join "").Trim()
    ).TrimEnd([char]92)
    $expectedVolumePaths = @(
        $partition.AccessPaths |
            ForEach-Object { $_.Trim().TrimEnd([char]92) }
    )
    if ($expectedVolumePaths -notcontains $mountedVolume) {
        Fail "mountvol selected an unexpected EFI System Partition"
    }

    $candidateRoot = "${mountLetter}:\EFI\OC"
    $candidateLoader = Join-Path $candidateRoot "OpenCore.efi"
    $candidateMarker = Join-Path $candidateRoot ".optiplex-3040-monterey-native"
    if (-not (Test-Path -LiteralPath $candidateLoader -PathType Leaf)) {
        Fail "reviewed candidate loader is missing"
    }
    if (-not (Test-Path -LiteralPath $candidateMarker -PathType Leaf)) {
        Fail "reviewed candidate marker is missing"
    }
    $marker = (Get-Content -Raw -LiteralPath $candidateMarker).Trim()
    if ($marker -ne $ExpectedMarker) {
        Fail "candidate marker has unexpected contents"
    }
    $loaderHash = (
        Get-FileHash -Algorithm SHA256 -LiteralPath $candidateLoader
    ).Hash.ToLowerInvariant()
    if ($loaderHash -ne $ExpectedOpenCoreSha256) {
        Fail "candidate OpenCore hash changed: $loaderHash"
    }

    $entry = Get-TemporaryEntry
    Write-Output "Candidate ESP: disk $($disk.Number), partition $($partition.PartitionNumber)"
    Write-Output "Candidate OpenCore SHA-256: $loaderHash"
    if ($null -eq $entry) {
        Write-Output "Temporary firmware entry: absent"
        if ($Mode -eq "Cleanup") {
            Write-Output "Nothing to clean."
        }
        exit 0
    }

    Write-Output "Temporary firmware entry: $($entry.Identifier)"
    Write-Output "Temporary firmware device: $($entry.Device)"
    Write-Output "Temporary firmware path: $($entry.Path)"
    if ($Mode -eq "Audit") {
        exit 0
    }
    if ($Confirm -ne $CleanupConfirmation) {
        Fail "Cleanup requires -Confirm $CleanupConfirmation"
    }

    $timestamp = Get-Date -Format "yyyyMMddTHHmmss"
    $backupRoot = Join-Path $env:USERPROFILE (
        "Documents\OptiPlex-3040-Boot-Backups\" +
        "$timestamp-native-firmware-cleanup"
    )
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Invoke-BcdEdit /export (Join-Path $backupRoot "BCD") | Out-Null
    $entry.FirmwareText |
        Set-Content -Encoding Unicode (Join-Path $backupRoot "firmware-before.txt")

    $firmwareManager = (
        Invoke-BcdEdit /enum "{fwbootmgr}" /v
    ) -join "`n"
    if ($firmwareManager -match (
        "(?ms)^bootsequence\s+.*" +
        [Regex]::Escape($entry.Identifier)
    )) {
        Invoke-BcdEdit /deletevalue "{fwbootmgr}" bootsequence | Out-Null
    }
    Invoke-BcdEdit /set "{fwbootmgr}" displayorder $entry.Identifier /remove |
        Out-Null
    Invoke-BcdEdit /delete $entry.Identifier | Out-Null

    if ($null -ne (Get-TemporaryEntry)) {
        Fail "temporary firmware entry remained after cleanup"
    }
    $firmwareAfter = (Invoke-BcdEdit /enum firmware /v) -join "`n"
    $firmwareAfter |
        Set-Content -Encoding Unicode (Join-Path $backupRoot "firmware-after.txt")
    if ($firmwareAfter -notmatch [Regex]::Escape("\EFI\Microsoft\Boot\bootmgfw.efi")) {
        Fail "Windows Boot Manager disappeared during cleanup"
    }

    Write-Output "Temporary native-test firmware entry removed."
    Write-Output "Backup: $backupRoot"
    Write-Output "No loader, partition, normal default, or Windows OS entry was changed."
}
finally {
    & mountvol "${mountLetter}:" /D 2>&1 | Out-Null
}
