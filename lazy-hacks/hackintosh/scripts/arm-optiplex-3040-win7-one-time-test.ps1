[CmdletBinding()]
param(
    [ValidateSet("Audit", "Arm", "Clear")]
    [string]$Mode = "Audit",

    [Parameter(Mandatory = $true)]
    [string]$RepairState,

    [ValidatePattern("^[A-Za-z]$")]
    [string]$Win7DriveLetter = "D"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$TestDescription = "Windows 7 SSH validation (one boot)"
$TestStatePath = Join-Path $RepairState "one-time-win7-test.json"
$Win7Root = "$($Win7DriveLetter.ToUpperInvariant()):"
$Win7Partition = "partition=$Win7Root"
$Win7Bcd = Join-Path $Win7Root "EFI\Microsoft\Boot\BCD"

function Invoke-Bcd {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$SuccessCodes = @(0)
    )

    $output = @(& bcdedit.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($SuccessCodes -notcontains $exitCode) {
        throw "bcdedit failed ($exitCode):`n$($output -join "`n")"
    }
    return $output
}

function Get-Win7LoaderId {
    $output = Invoke-Bcd -Arguments @(
        "/store",
        $Win7Bcd,
        "/enum",
        "osloader",
        "/v"
    )
    $text = $output -join "`n"
    $identifierMatches = [regex]::Matches(
        $text,
        "(?im)^identifier\s+(\{[0-9a-f-]{36}\})\s*$"
    )
    if ($identifierMatches.Count -ne 1) {
        throw "Expected exactly one repaired Win7 UEFI OS loader."
    }
    if (
        $text -notmatch
            "(?im)^path\s+\\Windows\\system32\\winload\.efi\s*$"
    ) {
        throw "The isolated Win7 loader does not use winload.efi."
    }
    return $identifierMatches[0].Groups[1].Value
}

function Assert-Environment {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )) {
        throw "Run from the existing elevated Win10 SSH account."
    }

    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    if ($operatingSystem.Caption -notmatch "Windows 10") {
        throw "The one-time Win7 test must be armed from Windows 10."
    }
    $computer = Get-CimInstance Win32_ComputerSystem
    if (
        $computer.Manufacturer -notmatch "Dell" -or
        $computer.Model -notmatch "OptiPlex 3040"
    ) {
        throw "This is not the audited Dell OptiPlex 3040."
    }
    if (-not (Test-Path -LiteralPath $Win7Bcd -PathType Leaf)) {
        throw "The repaired Win7 UEFI BCD is missing."
    }

    $win7Loader = Get-Win7LoaderId
    $win7LoaderText = (
        Invoke-Bcd -Arguments @(
            "/store", $Win7Bcd, "/enum", $win7Loader, "/v"
        )
    ) -join "`n"
    $partitionPattern = [regex]::Escape($Win7Partition)
    if (
        $win7LoaderText -notmatch
            "(?im)^device\s+$partitionPattern\s*$" -or
        $win7LoaderText -notmatch
            "(?im)^osdevice\s+$partitionPattern\s*$" -or
        $win7LoaderText -notmatch
            "(?im)^path\s+\\Windows\\system32\\winload\.efi\s*$"
    ) {
        throw "The offline Win7 OS loader has not passed the GPT repair."
    }

    $state = Get-Content -LiteralPath (Join-Path $RepairState "state.json") `
        -Raw | ConvertFrom-Json
    if (
        -not [bool]$state.ApplyCompleted -or
        -not [bool]$state.VerificationCompleted
    ) {
        throw "The selected offline repair state is not completed and verified."
    }
    return $win7Loader
}

function Clear-BootSequence {
    param([Parameter(Mandatory = $true)][string]$Manager)

    $output = @(& bcdedit.exe /deletevalue $Manager bootsequence 2>&1)
    if ($LASTEXITCODE -notin @(0, 1)) {
        throw "Could not clear $Manager bootsequence: $($output -join "`n")"
    }
}

$Win7Loader = Assert-Environment

if ($Mode -eq "Clear") {
    Clear-BootSequence -Manager "{fwbootmgr}"
    Clear-BootSequence -Manager "{bootmgr}"
    if (Test-Path -LiteralPath $TestStatePath) {
        $testState = Get-Content -LiteralPath $TestStatePath -Raw |
            ConvertFrom-Json
        $output = @(& bcdedit.exe /delete $testState.LoaderId /cleanup 2>&1)
        if ($LASTEXITCODE -notin @(0, 1)) {
            throw "Could not remove test loader: $($output -join "`n")"
        }
        $clearedStatePath = Join-Path $RepairState (
            "one-time-win7-test-cleared-" +
            (Get-Date -Format "yyyyMMdd-HHmmss") +
            ".json"
        )
        Move-Item -LiteralPath $TestStatePath `
            -Destination $clearedStatePath
    }
    Write-Host "One-time boot sequences and the recorded test loader are clear."
    exit 0
}

$firmwareBefore = Invoke-Bcd -Arguments @("/enum", "{fwbootmgr}", "/v")
$bootManagerBefore = Invoke-Bcd -Arguments @("/enum", "{bootmgr}", "/v")

[pscustomobject]@{
    Mode = $Mode
    Computer = $env:COMPUTERNAME
    RepairState = $RepairState
    Win7Loader = $Win7Loader
    Win7LoaderDevice = $Win7Partition
    FirmwareHasBootSequence = (
        ($firmwareBefore -join "`n") -match "(?im)^bootsequence\s+"
    )
    WindowsHasBootSequence = (
        ($bootManagerBefore -join "`n") -match "(?im)^bootsequence\s+"
    )
} | Format-List

if ($Mode -eq "Audit") {
    Write-Host "Audit complete. No BCD value was changed."
    exit 0
}

if (
    ($firmwareBefore -join "`n") -match "(?im)^bootsequence\s+" -or
    ($bootManagerBefore -join "`n") -match "(?im)^bootsequence\s+"
) {
    throw "A pre-existing one-time boot sequence must be investigated first."
}
if (Test-Path -LiteralPath $TestStatePath) {
    throw "A prior Win7 test state exists. Run -Mode Clear first."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
Invoke-Bcd -Arguments @(
    "/export",
    (Join-Path $RepairState "win10-live-bcd-before-test-$timestamp")
) | Out-Null
$firmwareBefore | Out-File `
    -LiteralPath (Join-Path $RepairState "fwbootmgr-before-test-$timestamp.txt") `
    -Encoding utf8 -Width 4096
$bootManagerBefore | Out-File `
    -LiteralPath (Join-Path $RepairState "bootmgr-before-test-$timestamp.txt") `
    -Encoding utf8 -Width 4096

$testLoaderId = $null
try {
    $createOutput = Invoke-Bcd -Arguments @(
        "/create",
        "/d",
        $TestDescription,
        "/application",
        "osloader"
    )
    $identifierMatch = [regex]::Match(
        ($createOutput -join "`n"),
        "\{[0-9a-fA-F-]{36}\}"
    )
    if (-not $identifierMatch.Success) {
        throw "Could not parse the one-time Win7 loader identifier."
    }
    $testLoaderId = $identifierMatch.Value

    foreach ($setting in @(
        @("device", $Win7Partition),
        @("osdevice", $Win7Partition),
        @("path", "\Windows\system32\winload.efi"),
        @("systemroot", "\Windows"),
        @("description", $TestDescription),
        @("locale", "en-US"),
        @("inherit", "{bootloadersettings}"),
        @("nx", "OptIn"),
        @("detecthal", "Yes"),
        @("bootmenupolicy", "Legacy")
    )) {
        Invoke-Bcd -Arguments @(
            "/set",
            $testLoaderId,
            $setting[0],
            $setting[1]
        ) | Out-Null
    }

    Invoke-Bcd -Arguments @(
        "/set",
        "{bootmgr}",
        "bootsequence",
        $testLoaderId
    ) | Out-Null
    Invoke-Bcd -Arguments @(
        "/set",
        "{fwbootmgr}",
        "bootsequence",
        "{bootmgr}"
    ) | Out-Null

    $loaderAfter = Invoke-Bcd -Arguments @("/enum", $testLoaderId, "/v")
    $bootManagerAfter = Invoke-Bcd -Arguments @("/enum", "{bootmgr}", "/v")
    $firmwareAfter = Invoke-Bcd -Arguments @("/enum", "{fwbootmgr}", "/v")
    $loaderText = $loaderAfter -join "`n"
    $bootManagerText = $bootManagerAfter -join "`n"
    $firmwareText = $firmwareAfter -join "`n"
    $partitionPattern = [regex]::Escape($Win7Partition)

    if (
        $loaderText -notmatch "(?im)^device\s+$partitionPattern\s*$" -or
        $loaderText -notmatch "(?im)^osdevice\s+$partitionPattern\s*$" -or
        $bootManagerText -notmatch
            "(?im)^bootsequence\s+$([regex]::Escape($testLoaderId))\s*$" -or
        $firmwareText -notmatch
            "(?im)^bootsequence\s+\{9dea862c-5cdd-4e70-acc1-f32b344d4795\}\s*$"
    ) {
        throw "One-time Win7 boot sequence read-back failed."
    }

    $testState = [ordered]@{
        Schema = 1
        ArmedUtc = (Get-Date).ToUniversalTime().ToString("o")
        Computer = $env:COMPUTERNAME
        LoaderId = $testLoaderId
        Description = $TestDescription
        FirmwareTarget = "{bootmgr}"
        PersistentFirmwareOrderChanged = $false
        PersistentWindowsDefaultChanged = $false
    }
    $testState | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $TestStatePath -Encoding utf8
    $loaderAfter | Out-File `
        -LiteralPath (Join-Path $RepairState "test-loader-armed.txt") `
        -Encoding utf8 -Width 4096
    $bootManagerAfter | Out-File `
        -LiteralPath (Join-Path $RepairState "bootmgr-armed.txt") `
        -Encoding utf8 -Width 4096
    $firmwareAfter | Out-File `
        -LiteralPath (Join-Path $RepairState "fwbootmgr-armed.txt") `
        -Encoding utf8 -Width 4096

    [pscustomobject]@{
        LoaderId = $testLoaderId
        FirmwareOneTimeTarget = "Windows Boot Manager"
        WindowsOneTimeTarget = $TestDescription
        PersistentFirmwareOrderChanged = $false
        PersistentWindowsDefaultChanged = $false
        RebootRequested = $false
    } | Format-List
}
catch {
    Clear-BootSequence -Manager "{fwbootmgr}"
    Clear-BootSequence -Manager "{bootmgr}"
    if ($testLoaderId) {
        & bcdedit.exe /delete $testLoaderId /cleanup 1>$null 2>$null
    }
    throw
}
