[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Archived incident helper for the exact signed 8.5.8 artifacts below.
# It deliberately has no restart, process-stop, install, or persistence path.
$expectedRoot = [IO.Path]::GetFullPath(
    (Join-Path $env:APPDATA 'baidu\BaiduNetdisk')
).TrimEnd('\')
$expectedRootPrefix = $expectedRoot + '\'
$expectedSigner = 'Beijing Duyou Science and Technology'
$expectedArtifacts = @(
    @{
        Path = (Join-Path $expectedRoot 'BaiduNetdisk.exe')
        Version = '8.5.8.107'
        Sha256 = 'F2E50ECD012C7B8D4269045C3937BAFDEBE2E2B3ED938F1AE03CAE28075F16C6'
    },
    @{
        Path = (Join-Path $expectedRoot 'module\BrowserEngine\BaiduNetdiskUnite.exe')
        Version = '8.5.8.443'
        Sha256 = '380DF87F28850FD284DAEB9C10354AC503D23F7CDD193B8BE4D6E883970A6C68'
    },
    @{
        Path = (Join-Path $expectedRoot 'kernel_btsdk.dll')
        Version = $null
        Sha256 = 'EF50D1EFE473851442C10448BF120529C5491AA8B5FB4D373B8D9469024F8DCB'
    }
)
$expectedExe = $expectedArtifacts[0].Path
$processNames = @(
    'BaiduNetdisk',
    'BaiduNetdiskUnite',
    'baidunetdiskhost',
    'YunDetectService'
)

function Assert-ExpectedArtifact {
    param([hashtable]$Artifact)

    if (-not (Test-Path -LiteralPath $Artifact.Path -PathType Leaf)) {
        throw "Required archived Baidu component not found: $($Artifact.Path)"
    }

    $item = Get-Item -LiteralPath $Artifact.Path
    if ($Artifact.Version -and
        $item.VersionInfo.FileVersion -ne $Artifact.Version) {
        throw (
            "This helper is archived for version {0}; found {1} at {2}. " +
            "Use Baidu's normal launcher for another release."
        ) -f $Artifact.Version, $item.VersionInfo.FileVersion, $Artifact.Path
    }

    $actualHash = (Get-FileHash -LiteralPath $Artifact.Path -Algorithm SHA256).Hash
    if ($actualHash -ne $Artifact.Sha256) {
        throw "Archived artifact hash mismatch at $($Artifact.Path): $actualHash"
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Artifact.Path
    $signerSubject = if ($signature.SignerCertificate) {
        $signature.SignerCertificate.Subject
    } else {
        '<none>'
    }
    if ($signature.Status -ne 'Valid' -or
        $signerSubject -notlike "*$expectedSigner*") {
        throw (
            "Refusing untrusted archived component: {0} ({1}, {2})"
        ) -f $Artifact.Path, $signature.Status, $signerSubject
    }
}

function Get-ActiveBaiduProcesses {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        if ($_.ProcessName -notin $processNames) {
            return $false
        }

        try {
            return -not $_.HasExited
        } catch {
            return $false
        }
    })
}

foreach ($artifact in $expectedArtifacts) {
    Assert-ExpectedArtifact -Artifact $artifact
}

$running = @(Get-ActiveBaiduProcesses)
foreach ($process in $running) {
    try {
        $processPath = [IO.Path]::GetFullPath($process.Path)
    } catch {
        throw (
            "Baidu process PID {0} has an inaccessible path. " +
            "The checked launcher will not act while process scope is ambiguous."
        ) -f $process.Id
    }

    if (-not $processPath.StartsWith(
        $expectedRootPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw (
            "Baidu process PID {0} is outside the archived 8.5.8 root: {1}"
        ) -f $process.Id, $processPath
    }
}

$hungVisibleUi = @($running | Where-Object {
    $_.ProcessName -eq 'BaiduNetdiskUnite' -and
    $_.MainWindowHandle -ne 0 -and
    -not $_.Responding
})
if ($hungVisibleUi.Count -gt 0) {
    throw (
        "The Baidu UI is not responding (PID {0}). This launcher never stops " +
        "processes; resolve active transfers and close/restart Baidu normally."
    ) -f ($hungVisibleUi.Id -join ', ')
}

# Starting the same exact signed build lets Baidu's own single-instance
# handling focus a healthy instance. If none exists, it starts normally.
Start-Process -FilePath $expectedExe -WorkingDirectory $expectedRoot

Start-Sleep -Seconds 2
foreach ($artifact in $expectedArtifacts) {
    Assert-ExpectedArtifact -Artifact $artifact
}
