[CmdletBinding()]
param(
    [ValidateSet("Start", "Status", "Stop")]
    [string]$Mode = "Status",

    [ValidatePattern("^[A-Za-z]$")]
    [string]$Win7DriveLetter = "D",

    [ValidateRange(1025, 65535)]
    [int]$Port = 2227,

    [string]$TestUser = $env:USERNAME,

    [string]$WorkRoot = (Join-Path $env:USERPROFILE "Win7Repair")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$taskName = "OptiPlex3040-Win7-OpenSSH-Smoke"
$firewallName = "OptiPlex3040-Win7-OpenSSH-Smoke"
$win7Root = "$($Win7DriveLetter.ToUpperInvariant()):"
$sshd = Join-Path $win7Root "Program Files\OpenSSH\sshd.exe"
$programData = "$win7Root/ProgramData/ssh"
$configPath = Join-Path $WorkRoot "sshd-smoke.conf"
$runnerPath = Join-Path $WorkRoot "run-sshd-smoke.ps1"
$logPath = Join-Path $WorkRoot "sshd-smoke.log"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )) {
        throw "Run from an elevated Windows 10 session."
    }
}

function Get-SmokeProcess {
    return @(
        Get-Process sshd -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $sshd }
    )
}

function Stop-Smoke {
    Get-SmokeProcess | Stop-Process -Force
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
    Remove-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    if (Get-NetTCPConnection -State Listen -LocalPort $Port `
            -ErrorAction SilentlyContinue) {
        throw "TCP $Port is still listening after cleanup."
    }
}

Assert-Administrator
$operatingSystem = Get-CimInstance Win32_OperatingSystem
if ($operatingSystem.Caption -notmatch "Windows 10") {
    throw "Run this smoke test from the working Windows 10 installation."
}
$computer = Get-CimInstance Win32_ComputerSystem
if (
    $computer.Manufacturer -notmatch "Dell" -or
    $computer.Model -notmatch "OptiPlex 3040"
) {
    throw "This helper is limited to the reviewed Dell OptiPlex 3040."
}

if ($Mode -eq "Stop") {
    Stop-Smoke
    Write-Host "The smoke task, staged sshd process, and firewall rule are removed."
    exit 0
}

if ($Mode -eq "Status") {
    $listeners = @(
        Get-NetTCPConnection -State Listen -LocalPort $Port `
            -ErrorAction SilentlyContinue
    )
    [pscustomobject]@{
        TaskPresent = [bool](
            Get-ScheduledTask -TaskName $taskName `
                -ErrorAction SilentlyContinue
        )
        ProcessIds = @(
            Get-SmokeProcess |
                Select-Object -ExpandProperty Id
        )
        Port = $Port
        Listening = [bool]$listeners
        FirewallPresent = [bool](
            Get-NetFirewallRule -Name $firewallName `
                -ErrorAction SilentlyContinue
        )
        Log = $logPath
    } | Format-List
    exit 0
}

if (-not (Test-Path -LiteralPath $sshd -PathType Leaf)) {
    throw "The staged offline sshd is missing: $sshd"
}
$signature = Get-AuthenticodeSignature -FilePath $sshd
if (
    $signature.Status -ne "Valid" -or
    $signature.SignerCertificate.Subject -notmatch "CN=Microsoft Corporation"
) {
    throw "The staged sshd Microsoft signature is not valid."
}

Stop-Smoke
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

$config = @"
Port $Port
AddressFamily any
ListenAddress 0.0.0.0
HostKey $programData/ssh_host_ed25519_key
HostKey $programData/ssh_host_rsa_key
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
AuthorizedKeysFile $programData/administrators_authorized_keys
AllowUsers $($TestUser.ToLowerInvariant())
AllowTcpForwarding no
GatewayPorts no
X11Forwarding no
SyslogFacility LOCAL0
LogLevel VERBOSE
"@
$runner = @"
`$ErrorActionPreference = "Continue"
& "$sshd" -D -e -f "$configPath" 2>>"$logPath"
"@
$encoding = New-Object System.Text.ASCIIEncoding
[IO.File]::WriteAllText($configPath, $config, $encoding)
[IO.File]::WriteAllText($runnerPath, $runner, $encoding)

& $sshd -t -f $configPath
if ($LASTEXITCODE -ne 0) {
    throw "The high-port smoke configuration did not validate."
}

New-NetFirewallRule `
    -Name $firewallName `
    -DisplayName $firewallName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $Port `
    -RemoteAddress LocalSubnet |
    Out-Null

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument (
        "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
        "-File `"$runnerPath`""
    )
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddHours(1))
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings |
    Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3

$listener = Get-NetTCPConnection -State Listen -LocalPort $Port `
    -ErrorAction SilentlyContinue
if (-not $listener) {
    if (Test-Path -LiteralPath $logPath) {
        Get-Content -LiteralPath $logPath
    }
    Stop-Smoke
    throw "The staged sshd did not listen on TCP $Port."
}

$process = Get-Process -Id $listener.OwningProcess
[pscustomobject]@{
    Task = $taskName
    ProcessId = $process.Id
    ProcessPath = $process.Path
    ListenAddress = $listener.LocalAddress
    ListenPort = $listener.LocalPort
    FirewallScope = "LocalSubnet"
    AutomaticStop = "15 minutes"
} | Format-List
