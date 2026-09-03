[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Install', 'Off', 'On', 'Status')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$taskPrefix = 'LazyingArt-DisplayPrivacy'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'LazyingArt'
$statePath = Join-Path $stateDirectory 'display-privacy-state.json'

function Write-PrivacyState {
    param([Parameter(Mandatory)][string]$RequestedState)

    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    [ordered]@{
        requested_state = $RequestedState.ToLowerInvariant()
        requested_at = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
        user = "$env:USERDOMAIN\$env:USERNAME"
        process_session_id = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        note = 'Requested state; keyboard, mouse, or remote input may wake a software-powered-off monitor.'
    } | ConvertTo-Json | Set-Content -Encoding UTF8 -Path $statePath
}

function Initialize-NativeDisplayPower {
    if ('LazyingArt.NativeDisplayPower' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace LazyingArt
{
    public static class NativeDisplayPower
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SendMessage(
            IntPtr hWnd,
            UInt32 message,
            IntPtr wParam,
            IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern void mouse_event(
            UInt32 flags,
            UInt32 dx,
            UInt32 dy,
            UInt32 data,
            UIntPtr extraInfo);
    }
}
'@
}

function Set-DisplayPower {
    param([Parameter(Mandatory)][ValidateSet('Off', 'On')][string]$State)

    Initialize-NativeDisplayPower

    $hwndBroadcast = [IntPtr]0xffff
    $wmSysCommand = 0x0112
    $scMonitorPower = [IntPtr]0xf170
    $powerState = if ($State -eq 'Off') { [IntPtr]2 } else { [IntPtr](-1) }

    [void][LazyingArt.NativeDisplayPower]::SendMessage(
        $hwndBroadcast,
        $wmSysCommand,
        $scMonitorPower,
        $powerState)

    if ($State -eq 'On') {
        # A one-pixel move and exact return wakes drivers that ignore the
        # SC_MONITORPOWER "on" request without changing pointer position.
        [LazyingArt.NativeDisplayPower]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        [LazyingArt.NativeDisplayPower]::mouse_event(0x0001, [UInt32]::MaxValue, 0, 0, [UIntPtr]::Zero)
    }

    Write-PrivacyState -RequestedState $State
    Write-Output "Requested Windows physical monitor power $($State.ToLowerInvariant()); desktop remains running."
}

function Install-DisplayPrivacyTasks {
    $interactiveUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if ([string]::IsNullOrWhiteSpace($interactiveUser)) {
        throw 'No interactively logged-in Windows user was detected.'
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Install this script from a stable file path, not from pasted input.'
    }

    $principal = New-ScheduledTaskPrincipal `
        -UserId $interactiveUser `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

    foreach ($state in @('Off', 'On')) {
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
            '-WindowStyle Hidden -File "' + $PSCommandPath + '" -Action ' + $state
        $taskAction = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument $arguments
        Register-ScheduledTask `
            -TaskName "$taskPrefix$state" `
            -Action $taskAction `
            -Principal $principal `
            -Settings $settings `
            -Description "Request physical monitor power $($state.ToLowerInvariant()) without ending the desktop session." `
            -Force | Out-Null
    }

    Write-Output "Installed ${taskPrefix}Off and ${taskPrefix}On for $interactiveUser."
}

function Show-DisplayPrivacyStatus {
    Write-Output 'Windows cannot reliably query the physical power state of every external monitor.'
    if (Test-Path $statePath) {
        Write-Output 'Last requested state:'
        Get-Content -Raw -Path $statePath
    } else {
        Write-Output 'No display power request has been recorded yet.'
    }

    Get-ScheduledTask -TaskName "$taskPrefix*" -ErrorAction SilentlyContinue |
        Sort-Object TaskName |
        Select-Object TaskName, State
}

switch ($Action) {
    'Install' { Install-DisplayPrivacyTasks }
    'Off' { Set-DisplayPower -State Off }
    'On' { Set-DisplayPower -State On }
    'Status' { Show-DisplayPrivacyStatus }
}
