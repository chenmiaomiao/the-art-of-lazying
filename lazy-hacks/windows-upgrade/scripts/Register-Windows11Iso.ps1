# Hash and register an already downloaded Microsoft Windows 11 ISO. Never mounts it.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$KitRoot,

    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$MicrosoftSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedKitRoot = (Resolve-Path -LiteralPath $KitRoot).Path
$statePath = Join-Path $resolvedKitRoot 'kit-state.json'
$markerPath = Join-Path $resolvedKitRoot 'DO-NOT-RUN.txt'

if (-not (Test-Path -LiteralPath $statePath) -or -not (Test-Path -LiteralPath $markerPath)) {
    throw "Not an initialized upgrade kit: $resolvedKitRoot"
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.TargetRelease -ne 'Windows 11 25H2 x64') {
    throw "Unexpected target release in kit state: $($state.TargetRelease)"
}

if ([bool]$state.UpgradeStarted -or [bool]$state.PersistenceCreated) {
    throw 'Kit state is not inert; refusing media registration.'
}

$resolvedIso = (Resolve-Path -LiteralPath $IsoPath).Path
$isoItem = Get-Item -LiteralPath $resolvedIso
if ($isoItem.Extension -ne '.iso') {
    throw "Expected an .iso file: $resolvedIso"
}

if ($isoItem.Length -lt 4GB -or $isoItem.Length -gt 9GB) {
    throw "ISO size $([math]::Round($isoItem.Length / 1GB, 2)) GiB is outside the expected range."
}

$kitDrive = [System.IO.Path]::GetPathRoot($resolvedKitRoot)
$isoDrive = [System.IO.Path]::GetPathRoot($resolvedIso)
if ($kitDrive -ne $isoDrive) {
    throw "ISO must already be on the kit's data drive $kitDrive; found $isoDrive."
}

Write-Information 'Computing SHA-256. This can take several minutes...' `
    -InformationAction Continue
$actualSha256 = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash.ToUpperInvariant()
$expectedSha256 = $MicrosoftSha256.ToUpperInvariant()

if ($actualSha256 -ne $expectedSha256) {
    throw "SHA-256 mismatch. Microsoft: $expectedSha256; actual: $actualSha256"
}

$manifest = [ordered]@{
    RegisteredAt = (Get-Date).ToString('o')
    IsoPath = $resolvedIso
    FileName = $isoItem.Name
    SizeBytes = [int64]$isoItem.Length
    Sha256 = $actualSha256
    Sha256Source = 'Manually transcribed from the Microsoft Windows 11 download verification section'
    Mounted = $false
    SetupExecuted = $false
}

if (-not $PSCmdlet.ShouldProcess($resolvedKitRoot, 'Record verified Windows 11 ISO manifest')) {
    return
}

$manifestPath = Join-Path $resolvedKitRoot 'iso-manifest.json'
$manifest | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $manifestPath -Encoding UTF8

$state.IsoRegistered = $true
$state.IsoPath = $resolvedIso
$state.IsoSha256 = $actualSha256
$state.IsoRegisteredAt = $manifest.RegisteredAt
$state.UpgradeApproved = $false
$state.UpgradeStarted = $false
$state.PersistenceCreated = $false
$state | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Information "Registered verified ISO: $resolvedIso" `
    -InformationAction Continue
Write-Information "Manifest: $manifestPath" -InformationAction Continue
Write-Information 'The ISO was not mounted and Windows Setup was not started.' `
    -InformationAction Continue
