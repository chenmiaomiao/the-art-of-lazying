# Baidu Netdisk 8.5.8 floating-window freeze: archived incident notes

This is an archived, version-specific record of a Windows incident investigated
on 2026-07-17. It is not a generic Baidu Netdisk launcher, an updater, or a
recommendation to remain on an old release.

The verified failure affected the exact signed artifacts below:

```text
BaiduNetdisk.exe       8.5.8.107
BaiduNetdiskUnite.exe  8.5.8.443
kernel_btsdk.dll       1.0.10.31
```

The included scripts intentionally refuse any other build. For a newer Baidu
release, use its supported UI and current vendor guidance; do not weaken or
edit the version and hash checks just to make these archived tools run.

## Incident summary

A physical right-click on Baidu's floating window consistently froze the
visible UI. The backend and network processes stayed alive, while the client
created a new BrowserEngine renderer and never produced a usable menu window.

The supported mitigation was to disable the floating window in Baidu itself:

```text
Settings -> Startup Settings -> Show floating window
设置 -> 启动设置 -> 显示悬浮窗
```

Use left-clicks to reach the setting and clear its checkbox. The floating
window should disappear immediately and remain disabled after a normal
restart.

For the tested 8.5.8 profile, these two additional vendor settings reduced
other native input, window, and GPU paths:

```text
Startup Settings -> Enable hardware acceleration       OFF (restart required)
Quick Upload      -> Start plug-in while Baidu runs    OFF
```

These settings describe the archived reproduction environment, not a permanent
policy. Re-evaluate them when moving to a newer signed release. Do not disable
updates merely to keep the archived scripts usable.

## Exact artifact record

The SHA-256 values recorded from the tested installation were:

```text
BaiduNetdisk.exe       F2E50ECD012C7B8D4269045C3937BAFDEBE2E2B3ED938F1AE03CAE28075F16C6
BaiduNetdiskUnite.exe  380DF87F28850FD284DAEB9C10354AC503D23F7CDD193B8BE4D6E883970A6C68
kernel_btsdk.dll       EF50D1EFE473851442C10448BF120529C5491AA8B5FB4D373B8D9469024F8DCB
```

The two executables and SDK also had valid Authenticode signatures whose
certificate subject identified Beijing Duyou Science and Technology. Hashes
identify the archived artifacts; a signature remains essential provenance.

Do not download files matching these hashes from an unofficial mirror. This
repository does not distribute Baidu binaries.

## Optional checked launch

The checked launcher is deliberately narrow:

```powershell
.\scripts\Launch-BaiduNetdisk858Incident.ps1
```

It accepts no force-restart or recovery switch. It:

- requires the normal `%APPDATA%\baidu\BaiduNetdisk` installation root;
- checks all three exact versions or hashes above and their signatures;
- refuses to proceed if a named Baidu process has an inaccessible path or is
  outside that checked root;
- refuses a visible, non-responsive BrowserEngine UI; and
- starts the checked executable normally, allowing Baidu's own
  single-instance handling to focus an already healthy instance.

The launcher does not stop a process, install or replace a file, change system
configuration, or run in the background. If Baidu is already frozen, the
launcher exits without trying to recover it. Resolve active transfers and use
ordinary vendor or Windows close/restart controls before running it again.

Because the launcher is pinned to an archived build, a normal Baidu update is
expected to make it refuse to run. That refusal is intentional; use Baidu's
normal shortcut for a current release.

## Non-destructive health check

After the exact 8.5.8 UI is ready, run:

```powershell
.\scripts\Test-BaiduNetdisk858Health.ps1 `
  -Samples 6 `
  -IntervalSeconds 5
```

The checker only reads process, window, file-signature, file-hash, and Windows
Application event data. It does not close or launch Baidu and does not write
configuration. It reports failure if:

- the exact signed artifacts are absent or changed;
- a matching Baidu process is outside the expected installation root;
- the BrowserEngine UI is missing or non-responsive;
- the floating window is visible;
- main-process private memory exceeds the selected threshold; or
- Windows records a new Baidu application-hang event during the sample.

The defaults are the archived versions and hashes above and are not
configurable. `-Samples`, `-IntervalSeconds`, and `-MaxMainPrivateMB` only
control observation.

## Verified outcome on 2026-07-17

After clearing `显示悬浮窗` in the supported settings UI:

- a clean restart produced one visible 1200-by-800 Baidu window and no floating
  window;
- the setting remained disabled across the restart;
- a real right-click in the main file window stayed responsive for 40
  consecutive 250 ms samples;
- 50 main-window right-click/Escape cycles completed with no hang or extra
  renderer;
- 30 minimize/restore cycles completed with stable memory;
- a ten-minute soak produced 60 responsive samples, no new hang event, and
  less than 1 MB of main-process private-memory growth; and
- disabling hardware acceleration through Baidu's settings was visible after
  restart in the main and renderer process flags.

No executable, DLL, shell registration, download directory, or cloud file was
changed by the setting-based mitigation.

This evidence is intentionally narrower than claiming every future operation
or release is fixed. It documents one reproduced 8.5.8 deadlock and the
supported UI feature that removed its trigger.

## Technical diagnosis

Synthetic posted mouse messages initially appeared to pass, but a real Windows
right-click consistently reproduced the failure. At that moment Baidu created
a new `--type=renderer` process for the floating menu:

```text
floating-window rightbuttondown
  -> OPEN_SESTON_MENU
  -> create /sestonMenu
  -> new Electron BrowserWindow (188 px wide)
```

Ordinary file-list context menus used a DOM menu in the existing renderer and
did not create this extra `BrowserWindow`.

A full user dump placed the main `CrBrowserMain` thread inside themed window
positioning and an indefinite `WaitForSingleObject`. A live, non-invasive
WinDbg query showed an unsignaled auto-reset event. Another Baidu thread was in
`UIAutomationCore` and synchronously messaging the UI thread. Together, the
evidence supports a native Electron window/UI Automation deadlock during
floating-menu creation. It does not identify a safe executable or DLL patch.

Do not publish full process dumps from this investigation because they may
contain account or session data.

## Approaches that did not establish a fix

- Replacing signed `kernel_btsdk.dll` 1.0.10.31 with 1.0.10.30 did not change
  the physical-click hang. The normal signed 1.0.10.31 file was restored.
- Blocking Baidu's legacy and modern Explorer context-menu COM classes did not
  help. Those per-user block values should not be retained for this incident.
- Reposting `WM_RBUTTON*` messages was not a valid physical-input test.
- Cache cleanup had already been exhausted.
- Chromium's `Local State` claimed hardware acceleration was disabled, but the
  Baidu settings UI and a live Intel GPU process showed it was enabled.
- Pagefile pressure, total RAM use, and GPU load did not match the freeze.

Keep diagnosis reversible. Do not replace a signed Baidu component based only
on a synthetic click.

## Setting persistence and rollback

Baidu's settings page recorded the floating-window choice through its native
settings API:

```text
scope:   personal user
section: local_info
key:     sestonSwitch
value:   false
```

The backing `PersonalSetting.xml` is runtime-managed and has a backup. Do not
hand-edit it; use Baidu's settings page so the application applies the value
consistently.

To test a newer signed build, re-enable the floating window through the same
checkbox. On BrowserEngine 8.5.8.443 that restores the reproduced trigger, so
do not re-enable it on that archived build for ordinary use.

Keep the Windows pagefile enabled. On the tested 16 GB machine, the fixed 16 GB
pagefile provided commit headroom with little observed physical I/O. Deleting
`pagefile.sys` was not part of this incident mitigation or a safe disk-cleanup
step.
