# Create an inert Windows 11 25H2 kit on the OptiPlex 3040 data disk.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DestinationDrive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$administrator = [Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $principal.IsInRole($administrator)) {
    throw 'Open Windows PowerShell as Administrator, then run this script again.'
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystem
if ($computer.Manufacturer -notmatch '(?i)Dell' -or $computer.Model -notmatch '(?i)OptiPlex 3040') {
    throw "Machine lock failed: found '$($computer.Manufacturer) $($computer.Model)', expected Dell OptiPlex 3040."
}

$driveLetter = $DestinationDrive.TrimEnd(':').ToUpperInvariant()
$systemDriveLetter = $env:SystemDrive.TrimEnd(':').ToUpperInvariant()
if ($driveLetter -eq $systemDriveLetter) {
    throw "Refusing the Windows system volume $driveLetter`:."
}

$targetPartition = Get-Partition -DriveLetter $driveLetter
$targetDisk = Get-Disk -Number $targetPartition.DiskNumber
$systemPartition = Get-Partition -DriveLetter $systemDriveLetter

if ($targetDisk.Number -eq $systemPartition.DiskNumber) {
    throw "Refusing disk $($targetDisk.Number): it also contains the running Windows system volume."
}

if ($targetDisk.Size -lt 800GB -or $targetDisk.Size -gt 1.2TB) {
    throw "Destination disk size $([math]::Round($targetDisk.Size / 1GB, 2)) GiB is outside the expected 1 TB data-disk range."
}

if ($targetDisk.IsBoot -or $targetDisk.IsSystem) {
    throw "Refusing disk $($targetDisk.Number): Windows marks it boot or system."
}

$targetVolume = Get-Volume -DriveLetter $driveLetter
if ($targetVolume.FileSystem -ne 'NTFS') {
    throw "Destination $driveLetter`: must be NTFS; found '$($targetVolume.FileSystem)'."
}

if ($targetVolume.SizeRemaining -lt 15GB) {
    throw "Destination $driveLetter`: has less than 15 GiB free."
}

$kitRoot = "$driveLetter`:\UpgradeKits\Windows11-25H2"
$scriptsRoot = Join-Path $kitRoot 'scripts'
$reportsRoot = Join-Path $kitRoot 'reports'
$mediaRoot = Join-Path $kitRoot 'media'
$sourceRoot = $PSScriptRoot

if (-not $PSCmdlet.ShouldProcess($kitRoot, 'Create inert Windows 11 25H2 staging kit')) {
    return
}

New-Item -ItemType Directory -Path $scriptsRoot, $reportsRoot, $mediaRoot -Force |
    Out-Null

$scriptNames = @(
    'Get-Optiplex3040Windows11Readiness.ps1',
    'Initialize-Optiplex3040Windows11Kit.ps1',
    'Register-Windows11Iso.ps1'
)

foreach ($name in $scriptNames) {
    $source = Join-Path $sourceRoot $name
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required source script is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $scriptsRoot $name) -Force
}

$doNotRun = @'
WINDOWS 11 25H2 - PREPARATION ONLY

This kit targets a Dell OptiPlex 3040 with an unsupported Intel Core i7-6700.
No upgrade has been approved or started.

Do not run setup.exe, Installation Assistant, /SkipFinalize, or a hardware
requirement bypass until backups and an attended compatibility review are
complete.
'@
Set-Content -LiteralPath (Join-Path $kitRoot 'DO-NOT-RUN.txt') -Value $doNotRun -Encoding ASCII

$internetShortcut = @'
[InternetShortcut]
URL=https://www.microsoft.com/en-us/software-download/windows11
'@
Set-Content `
    -LiteralPath (Join-Path $kitRoot 'DOWNLOAD-WINDOWS-11-25H2-FROM-MICROSOFT.url') `
    -Value $internetShortcut `
    -Encoding ASCII

$kitState = [ordered]@{
    SchemaVersion = 1
    CreatedAt = (Get-Date).ToString('o')
    ComputerName = [string]$env:COMPUTERNAME
    Manufacturer = [string]$computer.Manufacturer
    Model = [string]$computer.Model
    DestinationDrive = "$driveLetter`:"
    DestinationDiskNumber = [int]$targetDisk.Number
    DestinationDiskName = [string]$targetDisk.FriendlyName
    DestinationDiskSerial = [string]$targetDisk.SerialNumber
    SystemDiskNumber = [int]$systemPartition.DiskNumber
    TargetRelease = 'Windows 11 25H2 x64'
    HardwareSupport = 'Unsupported: Intel Core i7-6700 is not on the Microsoft Windows 11 supported processor list'
    UpgradeApproved = $false
    UpgradeStarted = $false
    IsoRegistered = $false
    PersistenceCreated = $false
}
$kitState | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $kitRoot 'kit-state.json') -Encoding UTF8

& (Join-Path $scriptsRoot 'Get-Optiplex3040Windows11Readiness.ps1') `
    -OutputDirectory $reportsRoot

Write-Information '' -InformationAction Continue
Write-Information "Inert kit created: $kitRoot" -InformationAction Continue
Write-Information 'No ISO was mounted and Windows Setup was not started.' `
    -InformationAction Continue
