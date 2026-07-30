[CmdletBinding()]
param(
    [ValidateRange(1, 120)]
    [int]$Samples = 6,

    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 5,

    [ValidateRange(100, 8192)]
    [int]$MaxMainPrivateMB = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Archived, non-destructive health check for one exact signed 8.5.8 incident.
# It reads process, window, artifact, and Windows event data only.
$processNames = @(
    'BaiduNetdisk',
    'BaiduNetdiskUnite',
    'baidunetdiskhost',
    'YunDetectService'
)

function Get-ActiveBaiduProcesses {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        if ($_.ProcessName -notin $processNames) {
            $false
        } else {
            try {
                -not $_.HasExited
            } catch {
                $false
            }
        }
    })
}

if (-not ('BaiduWindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class BaiduWindowProbe
{
    public delegate bool EnumWindowsProc(IntPtr window, IntPtr state);

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(
        IntPtr window,
        StringBuilder className,
        int maximumCount
    );
}
'@
}

function Get-BaiduVisibleWindowMetrics {
    param([int]$TargetProcessId)

    $windows = New-Object 'System.Collections.Generic.List[object]'
    [BaiduWindowProbe]::EnumWindows({
        param($window, $state)

        [uint32]$ownerProcessId = 0
        [BaiduWindowProbe]::GetWindowThreadProcessId(
            $window,
            [ref]$ownerProcessId
        ) | Out-Null
        if ($ownerProcessId -eq $TargetProcessId -and
            [BaiduWindowProbe]::IsWindowVisible($window)) {
            $rect = New-Object 'BaiduWindowProbe+Rect'
            [BaiduWindowProbe]::GetWindowRect($window, [ref]$rect) | Out-Null
            $className = New-Object 'System.Text.StringBuilder' 256
            [BaiduWindowProbe]::GetClassName(
                $window,
                $className,
                $className.Capacity
            ) | Out-Null
            $windows.Add([pscustomobject]@{
                Handle = $window
                ClassName = $className.ToString()
                Minimized = [BaiduWindowProbe]::IsIconic($window)
                Left = $rect.Left
                Top = $rect.Top
                Width = $rect.Right - $rect.Left
                Height = $rect.Bottom - $rect.Top
            })
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null

    @($windows | ForEach-Object { $_ })
}
$expectedSigner = 'Beijing Duyou Science and Technology'
$expectedRootPath = [IO.Path]::GetFullPath(
    (Join-Path $env:APPDATA 'baidu\BaiduNetdisk')
).TrimEnd('\')
$expectedRootPrefix = $expectedRootPath + '\'
$expectedArtifacts = @(
    @{
        Path = (Join-Path $expectedRootPath 'BaiduNetdisk.exe')
        Version = '8.5.8.107'
        Sha256 = 'F2E50ECD012C7B8D4269045C3937BAFDEBE2E2B3ED938F1AE03CAE28075F16C6'
        RequireReadOnly = $false
    },
    @{
        Path = (Join-Path $expectedRootPath 'module\BrowserEngine\BaiduNetdiskUnite.exe')
        Version = '8.5.8.443'
        Sha256 = '380DF87F28850FD284DAEB9C10354AC503D23F7CDD193B8BE4D6E883970A6C68'
        RequireReadOnly = $false
    },
    @{
        Path = (Join-Path $expectedRootPath 'kernel_btsdk.dll')
        Version = $null
        Sha256 = 'EF50D1EFE473851442C10448BF120529C5491AA8B5FB4D373B8D9469024F8DCB'
        RequireReadOnly = $false
    }
)

function Assert-BaiduArtifacts {
    param(
        [object[]]$Artifacts,
        [string]$SignerPattern
    )

    foreach ($artifact in $Artifacts) {
        $item = Get-Item -LiteralPath $artifact.Path
        $signature = Get-AuthenticodeSignature -LiteralPath $artifact.Path
        $signerSubject = if ($signature.SignerCertificate) {
            $signature.SignerCertificate.Subject
        } else {
            '<none>'
        }
        if ($artifact.Version -and $item.VersionInfo.FileVersion -ne $artifact.Version) {
            throw "Unexpected version at $($artifact.Path): $($item.VersionInfo.FileVersion)"
        }
        if ($artifact.Sha256) {
            $actualHash = (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash
            if ($actualHash -ne $artifact.Sha256) {
                throw "Unexpected SHA-256 at $($artifact.Path): $actualHash"
            }
        }
        if ($artifact.RequireReadOnly -and -not $item.IsReadOnly) {
            throw "Pinned component is not read-only: $($artifact.Path)"
        }
        if ($signature.Status -ne 'Valid' -or $signerSubject -notlike "*$SignerPattern*") {
            throw "Untrusted component at $($artifact.Path): $($signature.Status), $signerSubject"
        }
    }
}

Assert-BaiduArtifacts -Artifacts $expectedArtifacts -SignerPattern $expectedSigner
$testStart = Get-Date
$failed = $false
$failureReasons = New-Object 'System.Collections.Generic.HashSet[string]'

for ($sample = 1; $sample -le $Samples; $sample++) {
    Start-Sleep -Seconds $IntervalSeconds

    $processes = @(Get-ActiveBaiduProcesses)
    $outsideRootProcesses = @($processes | Where-Object {
        -not $_.Path -or
        -not $_.Path.StartsWith($expectedRootPrefix, [StringComparison]::OrdinalIgnoreCase)
    })
    $rootBrowserIds = @(Get-CimInstance Win32_Process -Filter "Name='BaiduNetdiskUnite.exe'" |
        Where-Object { $_.CommandLine -notmatch '--type=' } |
        Select-Object -ExpandProperty ProcessId)
    $main = $processes |
        Where-Object {
            $_.ProcessName -eq 'BaiduNetdiskUnite' -and
            $rootBrowserIds -contains $_.Id -and
            $_.MainWindowHandle -ne 0
        } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    if (-not $main) {
        $main = $processes |
            Where-Object {
                $_.ProcessName -eq 'BaiduNetdiskUnite' -and
                $rootBrowserIds -contains $_.Id
            } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
    }
    if (-not $main) {
        $main = $processes |
            Where-Object { $_.ProcessName -eq 'BaiduNetdisk' } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
    }

    $visibleWindows = @(
        if ($main -and $main.ProcessName -eq 'BaiduNetdiskUnite') {
            Get-BaiduVisibleWindowMetrics -TargetProcessId $main.Id
        }
    )
    $floatingWindows = @($visibleWindows | Where-Object {
        $aspectRatio = if ($_.Height -gt 0) {
            $_.Width / [double]$_.Height
        } else {
            0
        }
        -not $_.Minimized -and
        $_.ClassName -eq 'Chrome_WidgetWin_1' -and
        $_.Width -ge 100 -and $_.Width -le 400 -and
        $_.Height -ge 35 -and $_.Height -le 180 -and
        $aspectRatio -ge 2.1 -and $aspectRatio -le 3.2
    })

    $totalWorkingSet = if ($processes.Count -gt 0) {
        ($processes | Measure-Object WorkingSet64 -Sum).Sum
    } else {
        0
    }
    $totalPrivate = if ($processes.Count -gt 0) {
        ($processes | Measure-Object PrivateMemorySize64 -Sum).Sum
    } else {
        0
    }
    $mainPrivateMB = if ($main) {
        [math]::Round($main.PrivateMemorySize64 / 1MB, 1)
    } else {
        $null
    }
    $mainVersion = if ($main -and $main.Path) {
        (Get-Item -LiteralPath $main.Path).VersionInfo.FileVersion
    } else {
        $null
    }
    $mainPathValid = $main -and $main.Path -and
        $main.Path.StartsWith($expectedRootPrefix, [StringComparison]::OrdinalIgnoreCase)

    [pscustomobject]@{
        Sample            = $sample
        Time              = (Get-Date).ToString('HH:mm:ss')
        Processes         = $processes.Count
        TotalWorkingSetMB = [math]::Round($totalWorkingSet / 1MB, 1)
        TotalPrivateMB    = [math]::Round($totalPrivate / 1MB, 1)
        MainPID           = if ($main) { $main.Id } else { $null }
        MainResponding    = if ($main) { $main.Responding } else { $false }
        MainPrivateMB     = $mainPrivateMB
        MainVersion       = $mainVersion
        MainPath          = if ($main) { $main.Path } else { $null }
        VisibleWindows    = $visibleWindows.Count
        FloatingWindows   = $floatingWindows.Count
        OutsideRootCount  = $outsideRootProcesses.Count
    }

    if (-not $main) {
        [void]$failureReasons.Add('BrowserEngine UI process is missing')
        $failed = $true
    } elseif (-not $main.Responding) {
        [void]$failureReasons.Add('BrowserEngine UI process is not responding')
        $failed = $true
    }
    if ($main -and -not $mainPathValid) {
        [void]$failureReasons.Add('BrowserEngine UI process is outside the expected root')
        $failed = $true
    }
    if ($main -and $mainVersion -ne '8.5.8.443') {
        [void]$failureReasons.Add("BrowserEngine UI version is $mainVersion")
        $failed = $true
    }
    if ($outsideRootProcesses.Count -gt 0) {
        [void]$failureReasons.Add("$($outsideRootProcesses.Count) Baidu processes are outside the expected root")
        $failed = $true
    }
    if ($floatingWindows.Count -gt 0) {
        [void]$failureReasons.Add(
            'Baidu floating window is enabled; disable Settings > Startup Settings > Show floating window'
        )
        $failed = $true
    }
    if ($null -ne $mainPrivateMB -and $mainPrivateMB -gt $MaxMainPrivateMB) {
        [void]$failureReasons.Add("BrowserEngine UI private memory exceeded $MaxMainPrivateMB MB")
        $failed = $true
    }
}

try {
    Assert-BaiduArtifacts -Artifacts $expectedArtifacts -SignerPattern $expectedSigner
} catch {
    [void]$failureReasons.Add($_.Exception.Message)
    $failed = $true
}

$newHangs = @(Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    StartTime = $testStart
    Id        = 1001, 1002
} -ErrorAction SilentlyContinue | Where-Object {
    $_.Message -match 'BaiduNetdiskUnite|BaiduNetdisk|BrowserEngine'
})
if ($newHangs.Count -gt 0) {
    [void]$failureReasons.Add("Windows recorded $($newHangs.Count) new Baidu hang events")
    $failed = $true
}

[pscustomobject]@{
    TestStart     = $testStart
    TestEnd       = Get-Date
    NewHangEvents = $newHangs.Count
    Passed        = -not $failed
    FailureReasons = ($failureReasons -join '; ')
}

if ($failed) {
    Write-Error "Baidu Netdisk health check failed: $($failureReasons -join '; ')"
    exit 1
}
