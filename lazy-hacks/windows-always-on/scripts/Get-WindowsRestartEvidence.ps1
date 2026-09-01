[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$Days = 30,

    [ValidateRange(10, 1000)]
    [int]$MaxEvents = 200,

    [string]$OutputPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-EventDataMap {
    param([Parameter(Mandatory = $true)]$Event)

    $map = [ordered]@{}
    try {
        [xml]$xml = $Event.ToXml()
        foreach ($item in @($xml.Event.EventData.Data)) {
            if ($item.Name) {
                $map[[string]$item.Name] = [string]$item.'#text'
            }
        }
    }
    catch {
        $map["ParseError"] = $_.Exception.Message
    }
    return $map
}

function Test-RelevantEvent {
    param([Parameter(Mandatory = $true)]$Event)

    switch ([int]$Event.Id) {
        1 { return $Event.ProviderName -eq "Microsoft-Windows-Power-Troubleshooter" }
        12 { return $Event.ProviderName -eq "Microsoft-Windows-Kernel-General" }
        13 { return $Event.ProviderName -eq "Microsoft-Windows-Kernel-General" }
        41 { return $Event.ProviderName -eq "Microsoft-Windows-Kernel-Power" }
        42 { return $Event.ProviderName -eq "Microsoft-Windows-Kernel-Power" }
        109 { return $Event.ProviderName -eq "Microsoft-Windows-Kernel-Power" }
        1074 { return $Event.ProviderName -eq "User32" }
        6005 { return $Event.ProviderName -eq "EventLog" }
        6006 { return $Event.ProviderName -eq "EventLog" }
        6008 { return $Event.ProviderName -eq "EventLog" }
        default { return $false }
    }
}

function Get-Classification {
    param(
        [Parameter(Mandatory = $true)]$Event,
        [Parameter(Mandatory = $true)]$EventData
    )

    switch ([int]$Event.Id) {
        1 { return "ResumeFromSleep" }
        12 { return "OperatingSystemStarted" }
        13 { return "OperatingSystemShutdown" }
        41 { return "UnexpectedRestartMarker" }
        42 { return "EnteredSleep" }
        109 { return "KernelPowerShutdown" }
        1074 {
            $initiator = [string]$EventData["param1"]
            if ($initiator -match "MoNotificationUx|TrustedInstaller|TiWorker|UsoClient|MusNotification") {
                return "PlannedWindowsUpdateRestartOrShutdown"
            }
            return "PlannedRestartOrShutdown"
        }
        6005 { return "EventLogStarted" }
        6006 { return "CleanEventLogStop" }
        6008 { return "UnexpectedShutdownReported" }
        default { return "Other" }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
}

$startTime = (Get-Date).AddDays(-$Days)
$rawEvents = Get-WinEvent -FilterHashtable @{
    LogName = "System"
    StartTime = $startTime
    Id = 1, 12, 13, 41, 42, 109, 1074, 6005, 6006, 6008
} -ErrorAction SilentlyContinue

$events = @(
    $rawEvents |
        Where-Object { Test-RelevantEvent -Event $_ } |
        Sort-Object TimeCreated -Descending |
        Select-Object -First $MaxEvents |
        ForEach-Object {
            $data = Get-EventDataMap -Event $_
            $bugcheck = $null
            if ($_.Id -eq 41) {
                $bugcheck = [ordered]@{
                    BugcheckCode = $data["BugcheckCode"]
                    SleepInProgress = $data["SleepInProgress"]
                    PowerButtonTimestamp = $data["PowerButtonTimestamp"]
                    LongPowerButtonPressDetected = $data["LongPowerButtonPressDetected"]
                    WHEABootErrorCount = $data["WHEABootErrorCount"]
                }
            }

            [ordered]@{
                TimeCreated = ([DateTimeOffset]$_.TimeCreated).ToString("o")
                Id = $_.Id
                RecordId = $_.RecordId
                Provider = $_.ProviderName
                Classification = Get-Classification -Event $_ -EventData $data
                PlannedAction = if ($_.Id -eq 1074) {
                    [ordered]@{
                        Initiator = $data["param1"]
                        Reason = $data["param3"]
                        ReasonCode = $data["param4"]
                        Action = $data["param5"]
                        User = $data["param7"]
                    }
                } else { $null }
                Bugcheck = $bugcheck
                Message = $_.Message
            }
        }
)

$os = Get-CimInstance Win32_OperatingSystem
$classifications = @($events | ForEach-Object { $_["Classification"] } | Group-Object | ForEach-Object {
    [ordered]@{ Name = $_.Name; Count = $_.Count }
})
$pendingReboot = [ordered]@{
    ComponentBasedServicing = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    WindowsUpdate = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    PendingFileRename = [bool](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
}

$result = [ordered]@{
    SchemaVersion = 1
    GeneratedAt = [DateTimeOffset]::Now.ToString("o")
    Computer = $env:COMPUTERNAME
    WindowStart = ([DateTimeOffset]$startTime).ToString("o")
    LastBoot = ([DateTimeOffset]$os.LastBootUpTime).ToString("o")
    UptimeSeconds = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalSeconds)
    PendingReboot = $pendingReboot
    ClassificationCounts = $classifications
    Interpretation = @(
        "User32 1074 records a planned restart or shutdown and usually names the initiating process.",
        "Kernel-Power 41 plus EventLog 6008 means the prior shutdown was unclean; it does not by itself distinguish power loss, reset, or a hard hang.",
        "Kernel-Power 42 and Power-Troubleshooter 1 identify sleep and resume transitions.",
        "BugcheckCode 0 with no dump is not evidence of a blue-screen crash."
    )
    Events = $events
}

if ($OutputPath) {
    Write-JsonFile -Value $result -Path $OutputPath
}
$result | ConvertTo-Json -Depth 10
