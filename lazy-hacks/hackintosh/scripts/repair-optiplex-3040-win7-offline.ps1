[CmdletBinding()]
param(
    [ValidateSet("Audit", "Apply", "Verify", "Rollback")]
    [string]$Mode = "Audit",

    [string]$OpenSshZip = (
        Join-Path $env:USERPROFILE "Downloads\OpenSSH-Win64-8.9.1.0p1.zip"
    ),

    [string]$PublicKeyPath = (
        Join-Path $env:USERPROFILE "Downloads\optiplex-3040-admin.pub"
    ),

    [string]$Win7User = "Dell",

    [string]$BackupVolumeLabel = "Data Fire",

    [string]$ExpectedWin7PartitionGuid = "",

    [string]$RollbackStatePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ExpectedOpenSshSha256 =
    "B3D31939ACB93C34236F420A6F1396E7CF2EEAD7069EF67742857A5A0BEFB9FC"
$ExpectedDiskSize = [UInt64]1000204886016
$ExpectedWin7Offset = [UInt64]1048576
$ExpectedWin7Size = [UInt64]107375230976
$SshUser = $Win7User
$OfflineSystemHiveName = "OFF3040SYSTEM"
$OfflineSoftwareHiveName = "OFF3040SOFTWARE"
$FirewallRuleName = "OpenSSH-Server-In-TCP-Win7-KeyOnly"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$SuccessCodes = @(0)
    )

    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($SuccessCodes -notcontains $exitCode) {
        throw (
            "{0} failed with exit code {1}:`n{2}" -f
            $FilePath,
            $exitCode,
            ($output -join "`n")
        )
    }
    return $output
}

function Invoke-BcdEdit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return Invoke-Checked -FilePath "bcdedit.exe" -Arguments $Arguments
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Mirror
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @(
        $Source,
        $Destination,
        $(if ($Mirror) { "/MIR" } else { "/E" }),
        "/COPYALL",
        "/DCOPY:DAT",
        "/R:2",
        "/W:2",
        "/XJ",
        "/NP"
    )
    Invoke-Checked -FilePath "robocopy.exe" -Arguments $arguments `
        -SuccessCodes (0..7) | Out-Null
}

function Write-AsciiFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [switch]$NoFinalNewline
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $text = $Content
    if (-not $NoFinalNewline) {
        $text = $text.TrimEnd("`r", "`n") + "`r`n"
    }
    $encoding = New-Object System.Text.ASCIIEncoding
    [IO.File]::WriteAllText($Path, $text, $encoding)
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    Assert-True `
        -Condition $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        ) `
        -Message "Run this script from the existing elevated Win10 SSH account."
}

function Get-MachineContext {
    Assert-Administrator

    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    Assert-True `
        -Condition ($operatingSystem.Caption -match "Windows 10") `
        -Message "The repair must run from the working Windows 10 installation."

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    Assert-True `
        -Condition (
            $computer.Manufacturer -match "Dell" -and
            $computer.Model -match "OptiPlex 3040"
        ) `
        -Message "This is not the audited Dell OptiPlex 3040."

    $disks = @(
        Get-Disk |
            Where-Object {
                $_.PartitionStyle -eq "GPT" -and
                [UInt64]$_.Size -eq $ExpectedDiskSize -and
                ("$($_.FriendlyName) $($_.Model)" -match "TOSHIBA") -and
                ("$($_.FriendlyName) $($_.Model)" -match "DT01ACA100")
            }
    )
    Assert-True `
        -Condition ($disks.Count -eq 1) `
        -Message "Expected exactly one audited 1 TB Toshiba GPT disk."
    $disk = $disks[0]

    $win7Partitions = @(
        Get-Partition -DiskNumber $disk.Number |
            Where-Object {
                [UInt64]$_.Offset -eq $ExpectedWin7Offset -and
                [UInt64]$_.Size -eq $ExpectedWin7Size
            }
    )
    Assert-True `
        -Condition ($win7Partitions.Count -eq 1) `
        -Message "The audited Windows 7 partition geometry is missing."
    $win7Partition = $win7Partitions[0]
    if ($ExpectedWin7PartitionGuid) {
        Assert-True `
            -Condition (
                $win7Partition.Guid.ToString().ToLowerInvariant() -eq
                $ExpectedWin7PartitionGuid.ToLowerInvariant()
            ) `
            -Message "The Windows 7 GPT partition GUID changed."
    }
    Assert-True `
        -Condition ([bool]$win7Partition.DriveLetter) `
        -Message "The Windows 7 partition has no Win10 drive letter."

    $win7Volume = Get-Volume -DriveLetter $win7Partition.DriveLetter
    Assert-True `
        -Condition (
            $win7Volume.FileSystem -eq "NTFS" -and
            $win7Volume.FileSystemLabel -eq "Windows 7"
        ) `
        -Message "The audited Windows 7 NTFS volume label or filesystem changed."

    $win7Root = "$($win7Partition.DriveLetter):"
    $kernelPath = Join-Path $win7Root "Windows\System32\ntoskrnl.exe"
    $requiredFiles = @(
        $kernelPath,
        (Join-Path $win7Root "Windows\System32\winload.efi"),
        (Join-Path $win7Root "EFI\Boot\bootx64.efi"),
        (Join-Path $win7Root "EFI\Microsoft\Boot\bootmgfw.efi"),
        (Join-Path $win7Root "EFI\Microsoft\Boot\BCD")
    )
    foreach ($requiredFile in $requiredFiles) {
        Assert-True `
            -Condition (Test-Path -LiteralPath $requiredFile -PathType Leaf) `
            -Message "Required Windows 7 file is missing: $requiredFile"
    }

    $kernelVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($kernelPath)
    Assert-True `
        -Condition (
            $kernelVersion.FileMajorPart -eq 6 -and
            $kernelVersion.FileMinorPart -eq 1 -and
            $kernelVersion.FileBuildPart -eq 7601
        ) `
        -Message "The offline system is not the audited Windows 7 SP1 build."
    Assert-True `
        -Condition (
            Test-Path -LiteralPath (Join-Path $win7Root "Users\$SshUser") `
                -PathType Container
        ) `
        -Message "The expected Windows 7 user profile '$SshUser' is missing."

    $dataFireVolumes = @(
        Get-Volume |
            Where-Object {
                $_.FileSystem -eq "NTFS" -and
                $_.FileSystemLabel -eq $BackupVolumeLabel -and
                [bool]$_.DriveLetter
            }
    )
    Assert-True `
        -Condition ($dataFireVolumes.Count -eq 1) `
        -Message "Expected one writable '$BackupVolumeLabel' backup volume."
    Assert-True `
        -Condition ([UInt64]$dataFireVolumes[0].SizeRemaining -gt 5GB) `
        -Message "'$BackupVolumeLabel' lacks space for rollback data."

    return [pscustomobject]@{
        Computer = $computer
        OperatingSystem = $operatingSystem
        Disk = $disk
        Win7Partition = $win7Partition
        Win7Volume = $win7Volume
        Win7Root = $win7Root
        KernelVersion = $kernelVersion
        UefiBcd = Join-Path $win7Root "EFI\Microsoft\Boot\BCD"
        RootBcd = Join-Path $win7Root "Boot\BCD"
        ProgramFilesOpenSsh = Join-Path $win7Root "Program Files\OpenSSH"
        ProgramDataSsh = Join-Path $win7Root "ProgramData\ssh"
        RepairData = Join-Path $win7Root "ProgramData\Win7OfflineRepair"
        DataFire = "$($dataFireVolumes[0].DriveLetter):"
    }
}

function Get-Win7LoaderId {
    param([Parameter(Mandatory = $true)]$Context)

    $output = Invoke-BcdEdit -Arguments @(
        "/store",
        $Context.UefiBcd,
        "/enum",
        "osloader",
        "/v"
    )
    $text = $output -join "`n"
    $identifierMatches = [regex]::Matches(
        $text,
        "(?im)^identifier\s+(\{[0-9a-f-]{36}\})\s*$"
    )
    Assert-True `
        -Condition ($identifierMatches.Count -eq 1) `
        -Message "Expected exactly one Windows 7 UEFI OS loader."
    $loaderId = $identifierMatches[0].Groups[1].Value
    Assert-True `
        -Condition ($text -match "(?im)^path\s+\\Windows\\system32\\winload\.efi\s*$") `
        -Message "The Windows 7 UEFI loader path is not winload.efi."
    return $loaderId
}

function Get-OpenSshAsset {
    Assert-True `
        -Condition (Test-Path -LiteralPath $OpenSshZip -PathType Leaf) `
        -Message "The pinned OpenSSH package is missing: $OpenSshZip"
    Assert-True `
        -Condition (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf) `
        -Message "The dedicated SSH public key is missing: $PublicKeyPath"

    $zipHash = (Get-FileHash -LiteralPath $OpenSshZip -Algorithm SHA256).Hash
    Assert-True `
        -Condition ($zipHash -eq $ExpectedOpenSshSha256) `
        -Message "The OpenSSH package SHA-256 does not match the pinned release."

    $extractRoot = Join-Path $env:USERPROFILE "Win7Repair\asset"
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $OpenSshZip -DestinationPath $extractRoot -Force
    $assetRoot = Join-Path $extractRoot "OpenSSH-Win64"

    $signedFiles = @(
        (Join-Path $assetRoot "sshd.exe"),
        (Join-Path $assetRoot "ssh.exe"),
        (Join-Path $assetRoot "ssh-keygen.exe"),
        (Join-Path $assetRoot "sftp-server.exe")
    )
    foreach ($signedFile in $signedFiles) {
        Assert-True `
            -Condition (Test-Path -LiteralPath $signedFile -PathType Leaf) `
            -Message "The OpenSSH package is incomplete: $signedFile"
        $signature = Get-AuthenticodeSignature -FilePath $signedFile
        Assert-True `
            -Condition (
                $signature.Status -eq "Valid" -and
                $signature.SignerCertificate.Subject -match
                    "CN=Microsoft Corporation"
            ) `
            -Message "Microsoft Authenticode validation failed: $signedFile"
    }

    $sshdVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo(
        (Join-Path $assetRoot "sshd.exe")
    )
    Assert-True `
        -Condition ($sshdVersion.FileVersion -eq "8.9.1.0") `
        -Message "The extracted sshd version is not the pinned 8.9.1.0 build."

    $publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
    Assert-True `
        -Condition ($publicKey -match "^ssh-ed25519\s+[A-Za-z0-9+/=]+(\s+.*)?$") `
        -Message "The supplied public key is not one valid Ed25519 public key."

    return [pscustomobject]@{
        Root = $assetRoot
        ZipHash = $zipHash
        SshdVersion = $sshdVersion.FileVersion
        PublicKey = $publicKey
    }
}

function Save-TextEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $Value | Out-File -LiteralPath $Path -Encoding utf8 -Width 4096
}

function New-RepairBackup {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Asset
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $stateRoot = Join-Path $Context.DataFire `
        "SYSTEM-REPAIR\win7-uefi-ssh\$timestamp"
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $stateRoot)) `
        -Message "Refusing to reuse repair state: $stateRoot"
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

    Copy-Item -LiteralPath $PSCommandPath `
        -Destination (Join-Path $stateRoot "repair-script.ps1")
    Copy-Item -LiteralPath $OpenSshZip `
        -Destination (Join-Path $stateRoot "OpenSSH-Win64.zip")
    Copy-Item -LiteralPath $PublicKeyPath `
        -Destination (Join-Path $stateRoot "authorized-key.pub")

    $efiBackup = Join-Path $stateRoot "win7-efi"
    Invoke-Robocopy `
        -Source (Join-Path $Context.Win7Root "EFI") `
        -Destination $efiBackup

    $rootBcdBackup = Join-Path $stateRoot "win7-root-bcd"
    New-Item -ItemType Directory -Force -Path $rootBcdBackup | Out-Null
    Copy-Item -LiteralPath $Context.RootBcd `
        -Destination (Join-Path $rootBcdBackup "BCD")

    $registryBackup = Join-Path $stateRoot "registry"
    New-Item -ItemType Directory -Force -Path $registryBackup | Out-Null
    foreach ($hiveName in @("SYSTEM", "SOFTWARE", "SAM", "SECURITY", "DEFAULT")) {
        Copy-Item `
            -LiteralPath (Join-Path $Context.Win7Root "Windows\System32\config\$hiveName") `
            -Destination (Join-Path $registryBackup $hiveName)
    }

    $programFilesExisted = Test-Path -LiteralPath `
        $Context.ProgramFilesOpenSsh -PathType Container
    if ($programFilesExisted) {
        Invoke-Robocopy `
            -Source $Context.ProgramFilesOpenSsh `
            -Destination (Join-Path $stateRoot "program-files-openssh")
    }

    $programDataExisted = Test-Path -LiteralPath `
        $Context.ProgramDataSsh -PathType Container
    if ($programDataExisted) {
        Invoke-Robocopy `
            -Source $Context.ProgramDataSsh `
            -Destination (Join-Path $stateRoot "programdata-ssh")
    }

    $rootContentDetails = Join-Path $Context.Win7Root ".contentDetails"
    $rootContentDetailsExisted = Test-Path -LiteralPath $rootContentDetails
    if ($rootContentDetailsExisted) {
        Copy-Item -LiteralPath $rootContentDetails `
            -Destination (Join-Path $stateRoot "root.contentDetails")
    }

    Invoke-BcdEdit -Arguments @(
        "/export",
        (Join-Path $stateRoot "win10-live-bcd-backup")
    ) | Out-Null
    Save-TextEvidence `
        -Path (Join-Path $stateRoot "win10-live-bcd-all.txt") `
        -Value (Invoke-BcdEdit -Arguments @("/enum", "all", "/v"))
    Save-TextEvidence `
        -Path (Join-Path $stateRoot "firmware-before.txt") `
        -Value (Invoke-BcdEdit -Arguments @("/enum", "firmware", "/v"))
    Save-TextEvidence `
        -Path (Join-Path $stateRoot "win7-uefi-bcd-before.txt") `
        -Value (Invoke-BcdEdit -Arguments @(
            "/store",
            $Context.UefiBcd,
            "/enum",
            "all",
            "/v"
        ))
    Save-TextEvidence `
        -Path (Join-Path $stateRoot "win7-root-bcd-before.txt") `
        -Value (Invoke-BcdEdit -Arguments @(
            "/store",
            $Context.RootBcd,
            "/enum",
            "all",
            "/v"
        ))

    Get-Disk |
        Sort-Object Number |
        Format-List * |
        Out-File -LiteralPath (Join-Path $stateRoot "disks.txt") `
            -Encoding utf8 -Width 4096
    Get-Partition |
        Sort-Object DiskNumber, PartitionNumber |
        Format-List * |
        Out-File -LiteralPath (Join-Path $stateRoot "partitions.txt") `
            -Encoding utf8 -Width 4096
    Get-Volume |
        Sort-Object DriveLetter |
        Format-List * |
        Out-File -LiteralPath (Join-Path $stateRoot "volumes.txt") `
            -Encoding utf8 -Width 4096

    $state = [ordered]@{
        Schema = 1
        CreatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        Computer = $env:COMPUTERNAME
        DiskNumber = $Context.Disk.Number
        DiskModel = $Context.Disk.Model
        Win7Root = $Context.Win7Root
        Win7PartitionGuid = $Context.Win7Partition.Guid.ToString()
        Win7KernelVersion = $Context.KernelVersion.FileVersion
        OpenSshZipSha256 = $Asset.ZipHash
        OpenSshVersion = $Asset.SshdVersion
        ProgramFilesOpenSshExisted = [bool]$programFilesExisted
        ProgramDataSshExisted = [bool]$programDataExisted
        RootContentDetailsExisted = [bool]$rootContentDetailsExisted
        ApplyCompleted = $false
        VerificationCompleted = $false
    }
    $statePath = Join-Path $stateRoot "state.json"
    $state | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $statePath -Encoding utf8

    $manifestPath = Join-Path $stateRoot "SHA256SUMS-before.txt"
    Get-ChildItem -LiteralPath $stateRoot -File -Recurse -Force |
        Where-Object { $_.FullName -ne $manifestPath } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($stateRoot.Length + 1)
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            "$hash  $relative"
        } |
        Set-Content -LiteralPath $manifestPath -Encoding ascii

    return [pscustomobject]@{
        Root = $stateRoot
        StatePath = $statePath
        State = $state
    }
}

function Set-RestrictedAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Directory,
        [switch]$AllowUsersRead
    )

    $ownerArguments = @($Path, "/setowner", "*S-1-5-32-544", "/C", "/Q")
    if ($Directory) {
        $ownerArguments += "/T"
    }
    Invoke-Checked -FilePath "icacls.exe" -Arguments $ownerArguments | Out-Null

    $systemGrant = if ($Directory) {
        "*S-1-5-18:(OI)(CI)F"
    }
    else {
        "*S-1-5-18:F"
    }
    $adminGrant = if ($Directory) {
        "*S-1-5-32-544:(OI)(CI)F"
    }
    else {
        "*S-1-5-32-544:F"
    }
    $arguments = @(
        $Path,
        "/inheritance:r",
        "/grant:r",
        $systemGrant,
        $adminGrant
    )
    if ($AllowUsersRead) {
        $usersGrant = if ($Directory) {
            "*S-1-5-32-545:(OI)(CI)RX"
        }
        else {
            "*S-1-5-32-545:RX"
        }
        $arguments += $usersGrant
    }
    Invoke-Checked -FilePath "icacls.exe" -Arguments $arguments | Out-Null
    if ($Directory) {
        Invoke-Checked `
            -FilePath "icacls.exe" `
            -Arguments @(
                (Join-Path $Path "*"),
                "/reset",
                "/T",
                "/C",
                "/Q"
            ) | Out-Null
    }
}

function Install-OfflineOpenSsh {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Asset,
        [Parameter(Mandatory = $true)]$Backup
    )

    if (Test-Path -LiteralPath $Context.ProgramFilesOpenSsh) {
        Remove-Item -LiteralPath $Context.ProgramFilesOpenSsh -Recurse -Force
    }
    Invoke-Robocopy `
        -Source $Asset.Root `
        -Destination $Context.ProgramFilesOpenSsh `
        -Mirror
    Set-RestrictedAcl `
        -Path $Context.ProgramFilesOpenSsh `
        -Directory `
        -AllowUsersRead

    New-Item -ItemType Directory -Force -Path $Context.ProgramDataSsh | Out-Null
    New-Item -ItemType Directory -Force `
        -Path (Join-Path $Context.ProgramDataSsh "logs") | Out-Null
    Set-RestrictedAcl `
        -Path $Context.ProgramDataSsh `
        -Directory `
        -AllowUsersRead
    Set-RestrictedAcl `
        -Path (Join-Path $Context.ProgramDataSsh "logs") `
        -Directory
    foreach ($privateHostKey in @(
        (Join-Path $Context.ProgramDataSsh "ssh_host_ed25519_key"),
        (Join-Path $Context.ProgramDataSsh "ssh_host_rsa_key")
    )) {
        if (Test-Path -LiteralPath $privateHostKey -PathType Leaf) {
            Set-RestrictedAcl -Path $privateHostKey
        }
    }

    $sshKeygen = Join-Path $Context.ProgramFilesOpenSsh "ssh-keygen.exe"
    foreach ($keyName in @("ssh_host_ed25519_key", "ssh_host_rsa_key")) {
        $keyPath = Join-Path $Context.ProgramDataSsh $keyName
        Assert-True `
            -Condition (Test-Path -LiteralPath $keyPath -PathType Leaf) `
            -Message "The existing Win7 host key is missing: $keyPath"
        $derivedPublicKey = Invoke-Checked `
            -FilePath $sshKeygen `
            -Arguments @("-y", "-f", $keyPath)
        Write-AsciiFile `
            -Path "$keyPath.pub" `
            -Content (($derivedPublicKey -join "").Trim())
    }

    $authorizedKeysPath = Join-Path `
        $Context.ProgramDataSsh "administrators_authorized_keys"
    Write-AsciiFile `
        -Path $authorizedKeysPath `
        -Content $Asset.PublicKey

    $configLines = @(
        "Port 22",
        "AddressFamily any",
        "ListenAddress 0.0.0.0",
        "HostKey C:/ProgramData/ssh/ssh_host_ed25519_key",
        "HostKey C:/ProgramData/ssh/ssh_host_rsa_key",
        "PubkeyAuthentication yes",
        "PasswordAuthentication no",
        "PermitEmptyPasswords no",
        "ChallengeResponseAuthentication no",
        "AuthenticationMethods publickey",
        "AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys",
        "AllowUsers $($SshUser.ToLowerInvariant())",
        "PermitTTY yes",
        "AllowTcpForwarding no",
        "GatewayPorts no",
        "X11Forwarding no",
        "MaxAuthTries 3",
        "MaxSessions 4",
        "ClientAliveInterval 60",
        "ClientAliveCountMax 3",
        "SyslogFacility LOCAL0",
        "LogLevel VERBOSE",
        "Subsystem sftp sftp-server.exe"
    )
    $configText = $configLines -join "`r`n"
    $configPath = Join-Path $Context.ProgramDataSsh "sshd_config"
    Write-AsciiFile -Path $configPath -Content $configText

    Set-RestrictedAcl `
        -Path $Context.ProgramDataSsh `
        -Directory `
        -AllowUsersRead
    Set-RestrictedAcl `
        -Path (Join-Path $Context.ProgramDataSsh "logs") `
        -Directory
    foreach ($restrictedFile in @(
        $configPath,
        $authorizedKeysPath,
        (Join-Path $Context.ProgramDataSsh "ssh_host_ed25519_key"),
        (Join-Path $Context.ProgramDataSsh "ssh_host_rsa_key")
    )) {
        Set-RestrictedAcl -Path $restrictedFile
    }

    $drivePrefix = $Context.Win7Root.Replace("\", "/")
    $validationText = $configText.Replace("C:/", "$drivePrefix/")
    $validationPath = Join-Path $Backup.Root "sshd_config.offline-validation"
    Write-AsciiFile -Path $validationPath -Content $validationText
    Invoke-Checked `
        -FilePath (Join-Path $Context.ProgramFilesOpenSsh "sshd.exe") `
        -Arguments @("-t", "-f", $validationPath) | Out-Null

    New-Item -ItemType Directory -Force -Path $Context.RepairData | Out-Null
    $fallbackLines = @(
        "@echo off",
        "setlocal",
        "set LOG=C:\ProgramData\Win7OfflineRepair\first-boot-repair.log",
        "echo [%DATE% %TIME%] Repair start>>`"%LOG%`"",
        "sc.exe config sshd start= auto >>`"%LOG%`" 2>&1",
        "netsh advfirewall firewall delete rule name=`"OpenSSH Server (Win7 key-only)`" >>`"%LOG%`" 2>&1",
        "netsh advfirewall firewall add rule name=`"OpenSSH Server (Win7 key-only)`" dir=in action=allow protocol=TCP localport=22 remoteip=localsubnet profile=any >>`"%LOG%`" 2>&1",
        "net start sshd >>`"%LOG%`" 2>&1",
        "sc.exe query sshd >>`"%LOG%`" 2>&1",
        "endlocal"
    )
    Write-AsciiFile `
        -Path (Join-Path $Context.RepairData "repair-sshd-as-admin.cmd") `
        -Content ($fallbackLines -join "`r`n")
}

function Set-OfflineRegistry {
    param([Parameter(Mandatory = $true)]$Context)

    $systemHivePath = Join-Path `
        $Context.Win7Root "Windows\System32\config\SYSTEM"
    $softwareHivePath = Join-Path `
        $Context.Win7Root "Windows\System32\config\SOFTWARE"
    $systemRoot = "Registry::HKEY_LOCAL_MACHINE\$OfflineSystemHiveName"
    $softwareRoot = "Registry::HKEY_LOCAL_MACHINE\$OfflineSoftwareHiveName"

    if (Test-Path -LiteralPath $systemRoot) {
        Invoke-Checked -FilePath "reg.exe" `
            -Arguments @("unload", "HKLM\$OfflineSystemHiveName") | Out-Null
    }
    if (Test-Path -LiteralPath $softwareRoot) {
        Invoke-Checked -FilePath "reg.exe" `
            -Arguments @("unload", "HKLM\$OfflineSoftwareHiveName") | Out-Null
    }

    Invoke-Checked -FilePath "reg.exe" `
        -Arguments @("load", "HKLM\$OfflineSystemHiveName", $systemHivePath) |
        Out-Null
    Invoke-Checked -FilePath "reg.exe" `
        -Arguments @("load", "HKLM\$OfflineSoftwareHiveName", $softwareHivePath) |
        Out-Null

    try {
        $select = Get-ItemProperty -LiteralPath (Join-Path $systemRoot "Select")
        $controlSetNumbers = @(
            [int]$select.Current,
            [int]$select.Default,
            [int]$select.LastKnownGood
        ) | Select-Object -Unique

        foreach ($controlSetNumber in $controlSetNumbers) {
            $controlSet = "ControlSet{0:D3}" -f $controlSetNumber
            $servicePath = Join-Path `
                $systemRoot "$controlSet\Services\sshd"
            New-Item -ItemType Directory -Force -Path $servicePath | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "DisplayName" -PropertyType String `
                -Value "OpenSSH SSH Server" -Force | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "Description" -PropertyType String `
                -Value "Key-only OpenSSH server for managed recovery access." `
                -Force | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "ImagePath" -PropertyType ExpandString `
                -Value '"C:\Program Files\OpenSSH\sshd.exe"' `
                -Force | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "ObjectName" -PropertyType String `
                -Value "LocalSystem" -Force | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "Start" -PropertyType DWord -Value 2 -Force | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "Type" -PropertyType DWord -Value 16 -Force | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "ErrorControl" -PropertyType DWord -Value 1 -Force |
                Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "ServiceSidType" -PropertyType DWord -Value 1 -Force |
                Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "DependOnService" -PropertyType MultiString `
                -Value @("Tcpip") -Force | Out-Null
            New-ItemProperty -LiteralPath $servicePath `
                -Name "RequiredPrivileges" -PropertyType MultiString `
                -Value @(
                    "SeAssignPrimaryTokenPrivilege",
                    "SeTcbPrivilege",
                    "SeBackupPrivilege",
                    "SeRestorePrivilege",
                    "SeImpersonatePrivilege"
                ) -Force | Out-Null

            $firewallPath = Join-Path $systemRoot (
                "$controlSet\Services\SharedAccess\Parameters\" +
                "FirewallPolicy\FirewallRules"
            )
            New-Item -ItemType Directory -Force -Path $firewallPath | Out-Null
            $firewallRule = (
                "v2.10|Action=Allow|Active=TRUE|Dir=In|Protocol=6|" +
                "LPort=22|RA4=LocalSubnet|" +
                "Name=OpenSSH Server (Win7 key-only)|" +
                "Desc=Key-only SSH from the local subnet.|"
            )
            New-ItemProperty -LiteralPath $firewallPath `
                -Name $FirewallRuleName -PropertyType String `
                -Value $firewallRule -Force | Out-Null
        }

        $openSshSoftwarePath = Join-Path $softwareRoot "OpenSSH"
        New-Item -ItemType Directory -Force -Path $openSshSoftwarePath |
            Out-Null
        New-ItemProperty -LiteralPath $openSshSoftwarePath `
            -Name "DefaultShell" -PropertyType String `
            -Value "C:\Windows\System32\cmd.exe" -Force | Out-Null

        foreach ($controlSetNumber in $controlSetNumbers) {
            $controlSet = "ControlSet{0:D3}" -f $controlSetNumber
            $servicePath = Join-Path `
                $systemRoot "$controlSet\Services\sshd"
            $service = Get-ItemProperty -LiteralPath $servicePath
            Assert-True `
                -Condition (
                    $service.Start -eq 2 -and
                    $service.Type -eq 16 -and
                    $service.ImagePath -eq
                        '"C:\Program Files\OpenSSH\sshd.exe"'
                ) `
                -Message "Offline sshd service read-back failed for $controlSet."

            $firewallPath = Join-Path $systemRoot (
                "$controlSet\Services\SharedAccess\Parameters\" +
                "FirewallPolicy\FirewallRules"
            )
            $firewall = Get-ItemProperty -LiteralPath $firewallPath
            Assert-True `
                -Condition (
                    $firewall.$FirewallRuleName -match "LPort=22" -and
                    $firewall.$FirewallRuleName -match "RA4=LocalSubnet"
                ) `
                -Message "Offline firewall rule read-back failed for $controlSet."
        }
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Invoke-Checked -FilePath "reg.exe" `
            -Arguments @("unload", "HKLM\$OfflineSoftwareHiveName") |
            Out-Null
        Invoke-Checked -FilePath "reg.exe" `
            -Arguments @("unload", "HKLM\$OfflineSystemHiveName") |
            Out-Null
    }
}

function Repair-Win7UefiBcd {
    param([Parameter(Mandatory = $true)]$Context)

    $loaderId = Get-Win7LoaderId -Context $Context
    $partition = "partition=$($Context.Win7Root)"

    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", "{bootmgr}", "device", $partition
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", "{bootmgr}", "path",
        "\EFI\Microsoft\Boot\bootmgfw.efi"
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", "{bootmgr}", "description", "Windows 7"
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/default", $loaderId
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/displayorder", $loaderId
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/timeout", "8"
    ) | Out-Null

    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", $loaderId, "device", $partition
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", $loaderId, "osdevice", $partition
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", $loaderId, "path",
        "\Windows\system32\winload.efi"
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", $loaderId, "systemroot", "\Windows"
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", $loaderId, "description", "Windows 7"
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", $loaderId, "detecthal", "Yes"
    ) | Out-Null
    Invoke-BcdEdit -Arguments @(
        "/store", $Context.UefiBcd,
        "/set", $loaderId, "nx", "OptIn"
    ) | Out-Null

    foreach ($target in @("{bootmgr}", $loaderId)) {
        $deleteOutput = @(
            & bcdedit.exe /store $Context.UefiBcd `
                /deletevalue $target resumeobject 2>&1
        )
        if ($LASTEXITCODE -notin @(0, 1)) {
            throw "Could not clear stale resume state: $($deleteOutput -join "`n")"
        }
    }

    foreach ($labelPath in @(
        (Join-Path $Context.Win7Root ".contentDetails"),
        (Join-Path $Context.Win7Root "EFI\Boot\.contentDetails"),
        (Join-Path $Context.Win7Root "EFI\Microsoft\Boot\.contentDetails")
    )) {
        Write-AsciiFile `
            -Path $labelPath `
            -Content "Windows 7" `
            -NoFinalNewline
    }
}

function Assert-RepairedState {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$EvidenceRoot = ""
    )

    $loaderId = Get-Win7LoaderId -Context $Context
    $bcdOutput = Invoke-BcdEdit -Arguments @(
        "/store",
        $Context.UefiBcd,
        "/enum",
        "all",
        "/v"
    )
    $bcdText = $bcdOutput -join "`n"
    $activeBootOutput = @(
        Invoke-BcdEdit -Arguments @(
            "/store",
            $Context.UefiBcd,
            "/enum",
            "{bootmgr}",
            "/v"
        )
        Invoke-BcdEdit -Arguments @(
            "/store",
            $Context.UefiBcd,
            "/enum",
            $loaderId,
            "/v"
        )
    )
    $activeBootText = $activeBootOutput -join "`n"
    Assert-True `
        -Condition ($activeBootText -notmatch "(?im)^device\s+unknown\s*$") `
        -Message "The active Win7 boot manager or OS loader still has an unknown device."
    Assert-True `
        -Condition ($activeBootText -notmatch "(?im)^osdevice\s+unknown\s*$") `
        -Message "The active Win7 OS loader still has an unknown osdevice."
    Assert-True `
        -Condition ($activeBootText -match "(?im)^device\s+partition=") `
        -Message "The repaired Win7 UEFI BCD has no partition device."
    Assert-True `
        -Condition (
            $activeBootText -match
            "(?im)^path\s+\\Windows\\system32\\winload\.efi\s*$"
        ) `
        -Message "The repaired Win7 UEFI loader path is wrong."

    $configPath = Join-Path $Context.ProgramDataSsh "sshd_config"
    $config = Get-Content -LiteralPath $configPath -Raw
    Assert-True `
        -Condition ($config -match "(?im)^PasswordAuthentication no\s*$") `
        -Message "Win7 SSH password authentication is not disabled."
    Assert-True `
        -Condition ($config -match "(?im)^AuthenticationMethods publickey\s*$") `
        -Message "Win7 SSH is not constrained to public-key authentication."
    Assert-True `
        -Condition (
            $config -match
            "(?im)^AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys\s*$"
        ) `
        -Message "Win7 SSH authorized-key path is wrong."

    $authorizedKeysPath = Join-Path `
        $Context.ProgramDataSsh "administrators_authorized_keys"
    Assert-True `
        -Condition (
            (Get-Content -LiteralPath $authorizedKeysPath -Raw).Trim() -eq
            (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
        ) `
        -Message "The installed Win7 SSH public key does not match."

    foreach ($signedFileName in @(
        "sshd.exe",
        "ssh.exe",
        "ssh-keygen.exe",
        "sftp-server.exe"
    )) {
        $signedFile = Join-Path $Context.ProgramFilesOpenSsh $signedFileName
        $signature = Get-AuthenticodeSignature -FilePath $signedFile
        Assert-True `
            -Condition (
                $signature.Status -eq "Valid" -and
                $signature.SignerCertificate.Subject -match
                    "CN=Microsoft Corporation"
            ) `
            -Message "Installed OpenSSH signature failed: $signedFile"
    }

    $validationRoot = if ($EvidenceRoot) {
        $EvidenceRoot
    }
    else {
        (Join-Path $env:USERPROFILE "Win7Repair")
    }
    New-Item -ItemType Directory -Force -Path $validationRoot | Out-Null
    $drivePrefix = $Context.Win7Root.Replace("\", "/")
    $validationText = $config.Replace("C:/", "$drivePrefix/")
    $validationPath = Join-Path `
        $validationRoot "sshd_config.verify-$($Context.Win7Partition.Guid).txt"
    Write-AsciiFile -Path $validationPath -Content $validationText
    Invoke-Checked `
        -FilePath (Join-Path $Context.ProgramFilesOpenSsh "sshd.exe") `
        -Arguments @("-t", "-f", $validationPath) | Out-Null

    $systemHivePath = Join-Path `
        $Context.Win7Root "Windows\System32\config\SYSTEM"
    $systemRoot = "Registry::HKEY_LOCAL_MACHINE\$OfflineSystemHiveName"
    if (Test-Path -LiteralPath $systemRoot) {
        Invoke-Checked -FilePath "reg.exe" `
            -Arguments @("unload", "HKLM\$OfflineSystemHiveName") | Out-Null
    }
    Invoke-Checked -FilePath "reg.exe" `
        -Arguments @("load", "HKLM\$OfflineSystemHiveName", $systemHivePath) |
        Out-Null
    try {
        $select = Get-ItemProperty -LiteralPath (Join-Path $systemRoot "Select")
        $controlSet = "ControlSet{0:D3}" -f [int]$select.Current
        $servicePath = Join-Path $systemRoot "$controlSet\Services\sshd"
        $service = Get-ItemProperty -LiteralPath $servicePath
        Assert-True `
            -Condition (
                $service.Start -eq 2 -and
                $service.ImagePath -eq
                    '"C:\Program Files\OpenSSH\sshd.exe"'
            ) `
            -Message "The current offline control set will not auto-start sshd."

        $firewallPath = Join-Path $systemRoot (
            "$controlSet\Services\SharedAccess\Parameters\" +
            "FirewallPolicy\FirewallRules"
        )
        $firewall = Get-ItemProperty -LiteralPath $firewallPath
        Assert-True `
            -Condition (
                $firewall.$FirewallRuleName -match "LPort=22" -and
                $firewall.$FirewallRuleName -match "RA4=LocalSubnet"
            ) `
            -Message "The current offline control set lacks the SSH firewall rule."
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Invoke-Checked -FilePath "reg.exe" `
            -Arguments @("unload", "HKLM\$OfflineSystemHiveName") | Out-Null
    }

    if ($EvidenceRoot) {
        Save-TextEvidence `
            -Path (Join-Path $EvidenceRoot "win7-uefi-bcd-after.txt") `
            -Value $bcdOutput
        Invoke-Checked -FilePath "icacls.exe" `
            -Arguments @($Context.ProgramDataSsh, "/T", "/C") |
            Out-File -LiteralPath (Join-Path $EvidenceRoot "ssh-acls-after.txt") `
                -Encoding utf8 -Width 4096
    }

    return [pscustomobject]@{
        Win7Root = $Context.Win7Root
        LoaderId = $loaderId
        UefiBcd = "verified"
        OpenSsh = "8.9.1.0 Microsoft-signed"
        Authentication = "publickey-only"
        ServiceStart = "automatic in offline current/default/LKG control sets"
        Firewall = "TCP 22, LocalSubnet"
        OfflineSshdConfig = "validated"
    }
}

function Restore-RepairBackup {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    Assert-True `
        -Condition (Test-Path -LiteralPath $StatePath -PathType Container) `
        -Message "Rollback state directory is missing: $StatePath"
    $stateFile = Join-Path $StatePath "state.json"
    Assert-True `
        -Condition (Test-Path -LiteralPath $stateFile -PathType Leaf) `
        -Message "Rollback state metadata is missing."
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Assert-True `
        -Condition (
            $state.Computer -eq $env:COMPUTERNAME -and
            $state.Win7PartitionGuid.ToLowerInvariant() -eq
                $Context.Win7Partition.Guid.ToString().ToLowerInvariant()
        ) `
        -Message "Rollback state does not belong to this Win7 partition."

    if (Test-Path -LiteralPath (Join-Path $Context.Win7Root "EFI")) {
        Remove-Item -LiteralPath (Join-Path $Context.Win7Root "EFI") `
            -Recurse -Force
    }
    Invoke-Robocopy `
        -Source (Join-Path $StatePath "win7-efi") `
        -Destination (Join-Path $Context.Win7Root "EFI") `
        -Mirror

    if (Test-Path -LiteralPath $Context.ProgramFilesOpenSsh) {
        Remove-Item -LiteralPath $Context.ProgramFilesOpenSsh -Recurse -Force
    }
    if ([bool]$state.ProgramFilesOpenSshExisted) {
        Invoke-Robocopy `
            -Source (Join-Path $StatePath "program-files-openssh") `
            -Destination $Context.ProgramFilesOpenSsh `
            -Mirror
    }

    if (Test-Path -LiteralPath $Context.ProgramDataSsh) {
        Remove-Item -LiteralPath $Context.ProgramDataSsh -Recurse -Force
    }
    if ([bool]$state.ProgramDataSshExisted) {
        Invoke-Robocopy `
            -Source (Join-Path $StatePath "programdata-ssh") `
            -Destination $Context.ProgramDataSsh `
            -Mirror
    }

    foreach ($hiveName in @("SYSTEM", "SOFTWARE", "SAM", "SECURITY", "DEFAULT")) {
        Copy-Item `
            -LiteralPath (Join-Path $StatePath "registry\$hiveName") `
            -Destination (
                Join-Path $Context.Win7Root "Windows\System32\config\$hiveName"
            ) `
            -Force
    }

    $rootContentDetails = Join-Path $Context.Win7Root ".contentDetails"
    if ([bool]$state.RootContentDetailsExisted) {
        Copy-Item `
            -LiteralPath (Join-Path $StatePath "root.contentDetails") `
            -Destination $rootContentDetails `
            -Force
    }
    elseif (Test-Path -LiteralPath $rootContentDetails) {
        Remove-Item -LiteralPath $rootContentDetails -Force
    }

    Write-Host "Rollback restored the offline Win7 EFI, SSH files, and registry."
}

$context = Get-MachineContext
$loaderId = Get-Win7LoaderId -Context $context

[pscustomobject]@{
    Mode = $Mode
    RunningSystem = $context.OperatingSystem.Caption
    Computer = $context.Computer.Model
    Disk = "$($context.Disk.FriendlyName) ($($context.Disk.Number))"
    Win7 = $context.Win7Root
    Win7PartitionGuid = $context.Win7Partition.Guid
    Win7Kernel = $context.KernelVersion.FileVersion
    Win7UefiLoader = $loaderId
    Win7UefiBcd = $context.UefiBcd
    BackupVolume = $context.DataFire
} | Format-List

if ($Mode -eq "Audit") {
    $asset = Get-OpenSshAsset
    $bcdOutput = Invoke-BcdEdit -Arguments @(
        "/store",
        $context.UefiBcd,
        "/enum",
        "all",
        "/v"
    )
    $bcdOutput
    [pscustomobject]@{
        OpenSshZipSha256 = $asset.ZipHash
        OpenSshVersion = $asset.SshdVersion
        MicrosoftSignatures = "valid"
        ProgramFilesOpenSshExists = Test-Path -LiteralPath `
            $context.ProgramFilesOpenSsh
        ProgramDataSshExists = Test-Path -LiteralPath `
            $context.ProgramDataSsh
        UnknownBcdDevices = @(
            $bcdOutput | Where-Object { $_ -match "^\s*(os)?device\s+unknown" }
        ).Count
    } | Format-List
    Write-Host "Audit complete. No Win7 file, BCD, or registry value was changed."
    exit 0
}

if ($Mode -eq "Rollback") {
    Assert-True `
        -Condition ([bool]$RollbackStatePath) `
        -Message "Rollback requires -RollbackStatePath."
    Restore-RepairBackup `
        -Context $context `
        -StatePath $RollbackStatePath
    exit 0
}

if ($Mode -eq "Verify") {
    $verification = Assert-RepairedState -Context $context
    $verification | Format-List
    Write-Host "Offline verification passed. No boot was requested."
    exit 0
}

$asset = Get-OpenSshAsset
$backup = New-RepairBackup -Context $context -Asset $asset
try {
    Write-Host "Stage 1/4: repairing the isolated Win7 UEFI BCD."
    Repair-Win7UefiBcd -Context $context
    Write-Host "Stage 2/4: installing and validating offline OpenSSH."
    Install-OfflineOpenSsh `
        -Context $context `
        -Asset $asset `
        -Backup $backup
    Write-Host "Stage 3/4: writing the offline service and firewall registry state."
    Set-OfflineRegistry -Context $context
    Write-Host "Stage 4/4: independently verifying every repaired surface."
    $verification = Assert-RepairedState `
        -Context $context `
        -EvidenceRoot $backup.Root

    $state = Get-Content -LiteralPath $backup.StatePath -Raw | ConvertFrom-Json
    $state.ApplyCompleted = $true
    $state.VerificationCompleted = $true
    $state | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $backup.StatePath -Encoding utf8

    $postManifest = Join-Path $backup.Root "SHA256SUMS-after.txt"
    @(
        $context.UefiBcd,
        (Join-Path $context.Win7Root "EFI\Boot\bootx64.efi"),
        (Join-Path $context.Win7Root "EFI\Microsoft\Boot\bootmgfw.efi"),
        (Join-Path $context.ProgramFilesOpenSsh "sshd.exe"),
        (Join-Path $context.ProgramDataSsh "sshd_config"),
        (Join-Path $context.ProgramDataSsh "administrators_authorized_keys"),
        (Join-Path $context.Win7Root "Windows\System32\config\SYSTEM"),
        (Join-Path $context.Win7Root "Windows\System32\config\SOFTWARE")
    ) |
        ForEach-Object {
            $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash
            "$hash  $_"
        } |
        Set-Content -LiteralPath $postManifest -Encoding ascii

    $verification | Format-List
    Write-Host "Offline Win7 repair applied and verified."
    Write-Host "Rollback state: $($backup.Root)"
    Write-Host "No reboot or live Win10 BCD change was requested."
}
catch {
    Write-Host "Apply failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Warning "Apply stopped. Rollback state: $($backup.Root)"
    Write-Warning (
        "Run -Mode Rollback -RollbackStatePath `"$($backup.Root)`" " +
        "before booting Win7."
    )
    exit 1
}
