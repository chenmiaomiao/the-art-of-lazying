# Astrill Lazy Router Native Windows Setup

This note records the safe build, installation, and first-run flow for the
native Windows frontend in
[`lachlanchen/astrill-lazy-router`](https://github.com/lachlanchen/astrill-lazy-router).
It intentionally excludes passwords, private/public key bodies, and
machine-specific SSH fingerprints.

## Current Version And Paths

The source snapshot documented here reports application version `0.2.13` and
router companion version `0.2.11`.

| Artifact | Default path |
| --- | --- |
| Workstation checkout | `%USERPROFILE%\Projects\astrill-lazy-router` |
| Build virtual environment | `build\windows-venv` |
| PyInstaller work directory | `build\pyinstaller-windows` |
| Built application folder | `dist\windows\Astrill Lazy Router` |
| Per-user installation | `%LOCALAPPDATA%\Programs\Astrill Lazy Router` |
| Installed executable | `%LOCALAPPDATA%\Programs\Astrill Lazy Router\Astrill Lazy Router.exe` |
| Desktop shortcut | `%USERPROFILE%\Desktop\Astrill Lazy Router.lnk` |
| Login-startup shortcut | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Astrill Lazy Router.lnk` |
| Configuration | `%LOCALAPPDATA%\Astrill Lazy Router\config.json` |
| Saved endpoint latency | `%LOCALAPPDATA%\Astrill Lazy Router\endpoint-latency.json` |
| App-owned host-key store | `%LOCALAPPDATA%\Astrill Lazy Router\known_hosts` |
| Default dedicated identity | `~/.ssh/astrill_lazy_router_ed25519` |

The PyInstaller result is a folder bundle. Keep the adjacent `_internal`
directory with the executable.

## Native UI

The Windows frontend is a native PySide6/Qt application. It does not need WSL,
GTK, VNC, or noVNC, and it does not install a local VPN, proxy, packet filter,
or network driver. DD-WRT remains the routing enforcement point.

The roomy layout targets `1360 x 860`, has a `960 x 640` minimum, and uses a
fixed navigation sidebar with scrollable content. Its vivid, saturated theme
uses an indigo-to-teal sidebar, purple/cyan accents, white cards, spacious
controls, and distinct status colors. The nine views are Policies, Services,
Countries, Devices, Connection, Endpoints, Astrill, Router, and Settings.

Fresh configurations start native-only, read-only, and with no policy applied.

The desktop reads router status once at startup, but it does not run a
recurring 60-second SSH poll. Later reads happen only through **Refresh
router**, a first page-demand load such as Devices, Endpoints, or Astrill, or
the status returned by an explicit router action. Leaving the app open does
not create periodic desktop-to-router SSH traffic. This affects only the
Windows frontend: the optional companion's router-local watchdog remains on
DD-WRT and continues maintaining its installed routing runtime independently.

The **Astrill** view follows the Ubuntu frontend's human-readable layout. Its
controls are organized into seven spacious tabs: **Overview**, **Connection**,
**Routing**, **Privacy & DNS**, **Devices**, **Resilience**, and **Advanced**.
Friendly labels and appropriate switches, selectors, and text fields make
common settings easier to understand, while the exact NVRAM key remains
visible as secondary metadata for troubleshooting and comparison with DD-WRT.

This presentation layer still reads and writes only the same explicitly
allowlisted, validated NVRAM keys. Loading the page preserves the router's
current values, and read-only mode continues to prevent saves; reorganizing the
controls does not broaden the app's router access or invent replacement
defaults.

The dedicated **Connection** view mirrors Ubuntu's shared-tunnel workflow
without hiding the Windows safety rules. It combines the live tunnel state
with searchable server, favorite, protocol, common port, cipher, MTU,
acceleration, kill-switch, favorite cycling, and router-boot controls. A
router refresh that arrives while the form is dirty preserves the local draft
and shows a conflict banner rather than silently replacing edits.

Its actions have deliberately different meanings:

- **Save** verifies changed connection values while leaving a disconnected
  tunnel stopped; it is unavailable while the tunnel is connected.
- **Connect** starts the tunnel only with the already-saved clean draft.
- **Apply & Connect** or **Apply & Reconnect** saves the validated connection
  values, verifies the readback, and restores previous connection settings if
  the attempt fails.
- **Disconnect** stops the shared tunnel while preserving its endpoint,
  favorites, policies, and other saved settings.

The read-only guard and one-action-at-a-time lock apply to every write. The
Connection and Astrill editors also lock each other's overlapping controls
while either has an unsaved draft. A Connection-page favorite edit uses the
same fresh-read, compare-before-write merge as Endpoints instead of sending a
stale complete list through an ordinary NVRAM write. That favorite merge runs
before Save or Apply; if a later connection step fails, the UI states
explicitly that the already-verified favorite edit remains saved.

## Build And Install

Windows 10 or 11, Python 3.11 or newer, network access for the initial
dependency installation, and Windows OpenSSH Client are required to build.
Check OpenSSH first:

```powershell
Get-Command ssh.exe
ssh.exe -V
```

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\contrib\windows\build-native.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\contrib\windows\install-native.ps1
```

The build script creates the virtual environment, installs the Windows
dependencies, creates the windowed PyInstaller bundle, and verifies that the
catalog, router package, and schema are present. The installer stages updates
before replacing the current per-user copy and refuses to update while the
installed app is running.

The router package builder canonicalizes its `VERSION` file to LF, so a Windows
CRLF checkout cannot turn an exact companion version such as `0.2.11` into a
mismatched runtime value.

The native installer creates one Desktop shortcut and one current-user Startup
shortcut. The latter opens the app after Windows sign-in, including after a
reboot, without a service or administrator access. Installation remains
idempotent and does not launch the app immediately. It removes an older
same-named Start Menu shortcut, creates no new Start Menu entry, and does not
alter router state.

The GUI holds a crash-recoverable per-user lock for its full lifetime. A
second launch exits successfully before it can construct another window or
start another reboot-reconciliation task, so a double-click cannot race the
one-shot RAM-overlay restore.

Launch from the Desktop shortcut or directly:

```powershell
& "$env:LOCALAPPDATA\Programs\Astrill Lazy Router\Astrill Lazy Router.exe"
```

## First-Run SSH Onboarding

Keep the Windows PC and DD-WRT router on a trusted LAN for this one-time flow.
Telnet is unencrypted; never perform the bootstrap across an untrusted network.

In **Settings**:

1. Enter the router host, SSH user and port, and dedicated identity path.
2. Select **Set up key via Telnet**.
3. Independently compare the displayed SSH algorithm and SHA-256 fingerprint
   with the router's trusted record or local console. **Cancel** is the default.
4. Confirm the warning only when the fingerprint matches, then enter the
   one-time Telnet password.
5. Wait until the app reports that strict key-only SSH was verified.

The app scans the SSH endpoint before asking for a credential. After
confirmation it scans again, refuses a changed key, and atomically pins the
confirmed key in its own `known_hosts` file. It generates or reuses a dedicated
Ed25519 identity and uses the LAN Telnet session to append only the public key
material to DD-WRT's existing authorized keys.

The password exists only transiently in app memory. It is not stored in the
configuration, logs, files, command arguments, or environment variables.

The ordering is an important lockout guard:

1. preserve existing authorized keys and append the dedicated public key
   idempotently;
2. restart SSH and prove strict key-only access with Windows OpenSSH;
3. only after that successful proof, disable SSH password authentication,
   SSH forwarding, and WAN SSH;
4. restart SSH and prove key-only access a second time.

Background commands fail closed with batch mode, identity-only
authentication, strict host-key checking, and the app-owned `known_hosts`
file. The onboarding flow never uses `StrictHostKeyChecking=no` and never
silently accepts a new or changed host key.

On Windows, noninteractive OpenSSH helpers such as `ssh.exe`,
`ssh-keyscan.exe`, and `ssh-keygen.exe` run without creating a console window,
so normal status refreshes and onboarding checks do not flash a terminal. The
explicit **Open interactive SSH setup** action intentionally opens a visible
terminal because that action hands control of the SSH session to the user.

Telnet deliberately remains enabled as a recovery path. This is a security
tradeoff: keep it LAN-only and maintain physical or local-console access.

## Services, Policies, And The UU Remote Path

The **Services** view is the safest way to create catalog-backed policies. It
has independent **Category**, **Profile**, and **Provider country** filters in
addition to text search. Provider country describes the service company; it is
not the same thing as choosing an Astrill endpoint country.

Selection is durable while search and filters change. Use any combination of:

- the checkbox at the start of a row;
- normal Qt row selection, including `Ctrl` multi-select and `Shift` range
  selection;
- the tri-state **Select visible** control for the current filtered result; or
- **Clear selection** to clear visible and hidden selections together.

The selected count explicitly reports selections hidden by the current
filters. Choose **Suggested**, **Direct**, or **Astrill**, then select **Add to
Policies**. **Suggested** uses each catalog entry's recommended route; the
other two override the selected services as one batch.

Selection alone does not create a policy. **Add to Policies** writes the
selection to the Windows configuration. Companion `0.2.11` then offers two
separate confirmed router operations:

- **Replace persistent core** compiles the selected complete global core,
  writes it to compressed NVRAM, and activates it after every reboot.
- **Load selected into router RAM** compiles this controller's volatile
  overlay, scopes it to the Windows computer's LAN source and observed MAC,
  and performs no NVRAM commit.

The persistent core accepts at most 6,144 compiled bytes and must leave at
least 2 KiB of live NVRAM headroom. A service row can expand into many domain
and literal-network rows, so the app preflights exact rows and bytes before
SSH. RAM overlays instead use per-owner byte/row limits plus total effective
rows, generated-match, reclaimable-memory, and build-duration checks. Neither
path silently truncates its scope, and a failed preflight leaves the previous
effective policy active.

Policies reports five distinct states: **Local library**, **Persistent core**,
**This computer's RAM overlay**, **Other overlays**, and **Effective router**.
The local manifest binds the confirmed SSH host fingerprint, companion version,
and exact stored-package MD5. Exact origin IDs, runtime generations, policy
document MD5 hashes, source/MAC binding, and runtime epoch distinguish an
intentionally smaller deployment from drift.

This distinction explains a missing **UU Remote** policy seen during the July
2026 check. The Windows configuration contained no rules, and both the
companion rule table and native router list were empty. The policy therefore
had not been saved or applied; it was not merely hidden by a stale GUI row.

To prepare the three reboot-essential Direct policies used on this router:

1. Open **Policies** and select **Add service...**, or open **Services**.
2. Search for `UU Remote`, select it, choose **Direct**, and use **Add to
   Policies**.
3. Repeat for `Nutstore (Jianguoyun)` and `WeChat`.
4. On **Policies**, select those three rows and choose **Replace persistent
   core**.
5. Approve the whole-core replacement only if it reports three enabled
   origins, 41 compiled rows, and 4,135 / 6,144 bytes.
6. Refresh the router and verify all three exact IDs and the returned core
   generation/hash.
7. Select computer-specific policies outside that core, choose **Load selected
   into router RAM**, and keep the recommended source value `auto`.
8. Verify the returned `/32`, MAC, owner, overlay generation/hash, and
   effective rows before opting into one-shot reboot restoration.
9. Reconnect only the affected applications if they retain old sessions; do
   not flush all router connection tracking.

The maintained profiles include UU's observed
`a56.gdl.netease.com` updater and Nutstore's documented
`dav.jianguoyun.com` WebDAV service. Protocol and port remain unrestricted,
and the literal UU networks remain narrow. UU Remote also uses dynamic UDP
ICE, relay, and peer destinations that a destination-domain policy cannot
promise to catch. A source-device Direct rule is the reliable broader
fallback, but it bypasses every flow from that device. Use it only when that
scope is acceptable; otherwise a process-aware device-local backend is needed.
Do not add a hosting provider's broad networks merely to chase changing peers.

If the row is still absent, inspect the local `rules` array before changing the
router. Do not interpret selecting a catalog row, or merely opening the
Services page, as a saved policy.

### Persistent core and RAM overlay

The hybrid model is implemented by Windows `0.2.13` and companion `0.2.11`.
The measured local split is:

| State | July 2026 value |
| --- | ---: |
| Complete Windows library | 88 enabled origins |
| Expanded complete library | 316 rows / 28,686 bytes |
| Persistent UU + Nutstore + WeChat core | 3 origins / 41 rows / 4,135 bytes |
| Remaining Windows overlay | 85 origins / 275 rows / 24,551 bytes |
| Source-scoped effective document | 316 rows / 38,455 bytes |

The storage lifecycle is:

1. Keep the small global core in gzip/base64 NVRAM when compression is smaller.
2. Reconstruct, validate, and activate that core immediately after reboot,
   even when every PC is off.
3. Keep controller overlays only under `/tmp/astrill-lazy/overlays`.
4. Compose the core first, then enter each overlay only through its source
   address and optional MAC guard.
5. Give each router runtime a new epoch and every layer a compare-and-swap
   generation plus MD5 content hash.
6. Restore an opted-in controller overlay once after Windows sign-in or a
   relevant network-change event; never poll DD-WRT repeatedly.
7. Rebuild a RAM overlay only for an explicit load, that one-shot restore, or a
   manual restore/reload; do not put large overlays on the watchdog's periodic
   DNS cycle.

The base package stored in NVRAM intentionally excludes the larger
`alhybrid` helper. The Windows bundle uploads that helper atomically to RAM and
verifies its MD5 under the same controller lock used by package and policy
transactions. This preserves package headroom without weakening core-only
boot. Core writes also stage this helper because it owns the cross-layer
transaction journal and rollback path. The persistent footprint is only the
base package, compressed bootstrap payload, and small core; the helper,
workstation overlays, effective document, runtime epoch, and generations are
RAM-only.

Every core/overlay document mutation is bound to the exact running code:

```text
alctl apply VERSION PACKAGE_MD5 HELPER_MD5 FILE|-
alctl rollback VERSION PACKAGE_MD5 HELPER_MD5 [--json]
alctl core-apply VERSION PACKAGE_MD5 HELPER_MD5 GENERATION FILE|-
alctl core-rollback VERSION PACKAGE_MD5 HELPER_MD5 GENERATION
alctl overlay-put VERSION PACKAGE_MD5 HELPER_MD5 OWNER GENERATION \
  SOURCE EXPECTED_SOURCE EXPECTED_MAC FILE|-
alctl overlay-remove VERSION PACKAGE_MD5 HELPER_MD5 OWNER GENERATION
alctl toggle-origin VERSION PACKAGE_MD5 HELPER_MD5 ID
alctl route-origin VERSION PACKAGE_MD5 HELPER_MD5 ID direct|vpn
```

After acquiring the shared lock, `alctl` compares the supplied version and
package MD5 with both the verified tmpfs markers and installed NVRAM metadata,
then compares `HELPER_MD5` with the executable it will source. A same-version
package replacement or helper replacement therefore fails the precondition
instead of racing a policy write onto different code.

The E4200 admission design uses this live preflight snapshot:

```text
/proc/meminfo MemTotal: 58,708 KiB
MemFree during inspection: about 31-32 MiB
/tmp/astrill-lazy runtime files: about 124 KiB
Deterministic companion package: 19,960 bytes / 26,616 base64 bytes / 15 chunks
Package MD5: 3552747bcb9a06a8f6b64dcbb1ce0675
Package SHA-256: 2f0dbbda03af55a54ebf75fa6a06d2f47ffcd071310082544202edac4422a4be
NVRAM free before locked upgrade projection: 3,115 bytes
Normalized bootstrap source: 6,502 bytes
Stored deterministic gzip/base64 bootstrap: 2,560 bytes
Canonical payload-plus-LF hash input: 2,561 bytes
Bootstrap MD5 for this release: 3b6a21b7fbc73107dc1fc85539e9e008
Projected upgrade growth: +608 bytes
Projected NVRAM free after upgrade: 2,507 bytes
Projected reserve margin: 459 bytes above the required 2,048
Observed free after physical reboot: 2,494 bytes
Observed reserve margin: 446 bytes
```

Those values describe that router snapshot, not a permanent capacity
guarantee. Every install recomputes the projection from current NVRAM before
and again under the shared controller lock.

The selected persistent core is:

```text
UU Remote            -> Direct
Nutstore/Jianguoyun   -> Direct
WeChat                -> Direct
```

Changing the core is a global NVRAM operation. The GUI reads the current core
generation and hash, shows the whole replacement, and refuses drift rather
than overwriting it. A core persistence failure restores the prior NVRAM
values and A/B chain in the same transaction. A corrupt current core at boot
uses a verified previous core in a degraded state; it is never accepted as an
intentional empty policy.

For the overlay, keep **Automatic source binding** unless a deliberate LAN
CIDR is required. `auto` derives the SSH peer `/32` and requires its bridge ARP
MAC. A controller cannot shadow a core origin or replace another owner's
overlay. Device rows are rejected because the owner chain already supplies the
source condition.

On reboot restoration, the app sends the previously trusted resolved `/32` and
MAC as write preconditions. The router compares them with its fresh LAN/ARP
resolution before composing or activating a candidate. A DHCP reassignment is
therefore rejected before any policy can briefly apply to the wrong device.

Initial limits are 32 KiB/320 rows per overlay, eight owners, 128 KiB/512 rows
effective, 1,536 generated matches, at least 8 MiB reclaimable memory, a
240-second whole-policy transaction, and 16 resolved addresses per domain.

The loader deduplicates enabled domains, runs no more than eight resolver jobs
at once, and stops each lookup after five seconds. A refresh prefers a fresh
validated answer but reuses the prior validated cache when that lookup fails.
It then serializes one bounded restore document that declares only the
unreferenced inactive A/B chain. After topology, memory, and deadline checks,
the helper dry-runs the document with `iptables-restore --noflush --test`,
rechecks the guards, commits the same document once with `--noflush`, and reads
back the exact rule count and reference topology before publishing the A/B
jump. Any rejection leaves the previous effective policy active.

To enable reboot restoration safely:

1. Load and verify the overlay manually once.
2. Confirm the returned source/MAC, owner, generation, and hash.
3. Enable **Restore this computer's RAM overlay after router reboot**.
4. Reboot the router while the GUI is closed and verify core-only service.
5. Open the GUI and verify one restore for the new epoch.
6. Compare the complete NVRAM digest before and after; an overlay operation
   must not change it.

Core-only operation after reboot is an amber “overlay waiting for restore”
state, not a red failure. Red is reserved for core drift/corruption, failed
restore, binding mismatch, or degraded fail-closed health.

The canonical engineering reference is
[Hybrid policy storage](https://github.com/lachlanchen/astrill-lazy-router/blob/main/docs/HYBRID_POLICY_STORAGE.md).

## Optional Router Companion

SSH onboarding and companion installation are separate decisions. A successful
fingerprint/Telnet confirmation does not install the companion.

Review native Astrill and router status while the read-only guard is still on.
When the optional DD-WRT companion is wanted, open **Router**, select
**Install / upgrade**, read the write summary, and confirm it separately.
Cancel is the default. On a fresh profile that confirmation also turns off the
local read-only guard; a failed installation restores the guard.

The confirmed installation writes the validated base companion package,
startup hook, watchdog, routes, and MyPage entries. Version and package MD5
must both match. Before the first write, the installer projects package/key
growth—including key names and terminators—and compressed-rule migration
against the 2 KiB NVRAM reserve. Under the same controller lock used by policy
writes, it compare-and-swap checks the complete snapshot and repeats the live
headroom calculation immediately before mutation. After bootstrap it
independently decodes the committed core as a clean reboot would. If bootstrap
or verification fails, guarded recovery restores the old chunks, metadata,
rule records, startup/MyPage values, commits once, and reconstructs the prior
runtime from the locally validated captured package through the current
serialized recovery logic; it refuses to overwrite a newer state.

The installer normalizes the bootstrap source, deterministically gzips and
base64-encodes it, and stores only that encoded payload. Its MD5 covers the
encoded payload plus one canonical trailing newline. At boot, the launcher
captures the encoded payload and digest once, rejects blank or malformed
values, hashes that canonical captured payload, decodes the same payload
through `uudecode` and gzip, rejects an empty script, and executes it.
The bootstrap rechecks the stored payload identity before and after it
acquires the controller lock, verifies the reconstructed package archive,
extracts to a private staging directory, publishes each runtime file by atomic
rename, and writes the running package marker last. It never verifies one
NVRAM read and decodes or executes another.

Failed-upgrade rollback restores the exact NVRAM snapshot, then uses the
desktop-shipped current bootstrap in serialized recovery mode. It binds the
expected old version, package MD5, and canonical stored-bootstrap MD5, rechecks
them before and under the lock, verifies and stages the captured package, and
starts the restored controller. Legacy status without a package marker is
accepted only when every restored runtime file matches the validated archive.

Install, upgrade, policy mutation, RAM-helper publication, and **Restore
Astrill Only** share the same controller lock. Removal stops the runtime,
captures exact NVRAM bytes and every numbered package chunk, then reacquires
the lock and refuses any snapshot or residue change before mutation. It
commits and verifies the uninstalled state and audits the owned watchdog,
chains, policy rules, tables, startup hook, MyPage commands, NVRAM keys,
chunks, and runtime residue before the GUI records native-only mode. A failed
locked transaction attempts exact same-session NVRAM restoration.

Installation does not change Astrill account credentials or the selected
endpoint. Replacing the core or loading an overlay is another separately
confirmed action; merely editing local policies does not change traffic.

After reboot, the base companion reconstructs the verified package and
persistent core without a desktop. The Windows app inspects the result at
startup, on a relevant network-change event, or on manual **Refresh router**.
It treats the package as current only when version, package and
stored-bootstrap-payload digests, stored chunk/bootstrap integrity, persistent
hooks, and the running package marker all agree.
If opted in, it uploads the RAM-only hybrid helper and restores only its own
missing overlay once for the new runtime epoch. A saved failed-attempt epoch
prevents relaunch from becoming a retry loop.

The router watchdog never periodically rebuilds an active workstation overlay.
Overlay DNS and the batched inactive-chain load run only on an explicit load,
this one-shot startup/network restoration, or a manual restore/reload. A
core-only policy can retain its lightweight 30-cycle refresh while no overlay
is active.

If the router retained neither persistent markers nor runtime, the desktop
falls back to usable native-only mode and leaves **Install / upgrade**
available. An unreachable router does not trigger that fallback. Missing,
stale, fingerprint-mismatched, or inconsistent packages are never silently
installed or persistently rewritten.

### Companion 0.2.11 policy safety and recovery

Astrill creates its native policy rules dynamically, so a fixed companion
priority is not safe. Before a managed connect or switch, companion `0.2.11`
removes only its exact mark/mask/table signatures and enables a VPN-mark
filter guard. After `tun0` and Astrill's native rules stabilize, it allocates
one free adjacent Direct/VPN pair immediately ahead of the observed native
minimum, verifies the installed rules and dedicated tables, and only then
releases the guard.

Table `213` must contain exactly one WAN default. While connected, table `212`
contains the usable `tun0` default plus a worse-priority
`blackhole default metric 32767`; while disconnected, the blackhole is its only
route. The filter guard is enabled before every explicit stop. These layers
keep VPN-targeted traffic fail-closed during tunnel loss instead of falling
through to the main WAN route.

If Astrill is restarted outside companion control and its new native rules
undercut the recorded pair, the watchdog removes the owned pair, records
`rpdb-rebase-required`, and reports degraded health. It does not keep choosing
lower preferences on every 60-second cycle. Observing the tunnel down clears
that temporary marker; an explicit managed connect can stop/start Astrill once
and rebase safely. The watchdog also reclaims a dead or missing-PID lock,
refreshes a core-only policy every 30 cycles (about 30 minutes) only while no
overlay is active, and does not require desktop polling. Active overlays are
explicit/one-shot snapshots and are not rebuilt on that cadence.

Cleanup scans only exact companion signatures, attempts every mangle, filter,
RPDB, and dedicated-table object, and returns failure if anything remains. An
upgrade aborts before extracting the replacement package when the old runtime
cannot stop cleanly. The Windows app distinguishes a connected VPN from policy
health, displays the native and owned preferences, table readiness,
fail-closed state, rebase state, and last reconciliation error, and never calls
a present-but-degraded runtime ready.

### Historical companion 0.2.4 routing and connection fixes

The live router exposed two concrete reliability defects that were separate
from the still-unreproduced 2.4 GHz radio problem.

First, native Astrill had policy rules at priorities `28998` and `28999`, while
the older companion used `29000` and `29001`. Linux evaluates the lower
priority number first, so native Astrill could take precedence before the
companion's marked Direct/Astrill routes. Companion `0.2.4` moves its exact
rules to `28000` and `28001`, ahead of the observed native rules. Its ensure
path validates that precedence and removes only matching old companion entries
at `29000` and `29001`; it does not delete an unrelated rule that happens to
occupy one of those numbers.

Second, the old endpoint-switch path allowed only 30 seconds for Astrill to
become ready. A measured connection from fully down to server `998` using
RouterPro VPN TCP (protocol index `3`) succeeded in 28.4 seconds after the
`0.2.4` upgrade. That endpoint and protocol were valid, but the measured time
left too little margin for normal variation. Endpoint switching now allows 60
seconds and still requires both Astrill's connected state and a `tun0` route
before declaring success. A real timeout restores the previous selection,
stops any late or partial requested tunnel, and then preserves whether the
original endpoint had been connected or disconnected. The Windows SSH timeout
also covers this bounded recovery instead of abandoning it midway. If cleanup
or the prior reconnect cannot be verified, the companion returns a distinct
recovery-failed error rather than claiming restoration.

Router-local maintenance was also reduced. The previous watchdog ensured
runtime every 15 seconds and refreshed domains every five minutes. Version
`0.2.4` ensures every 60 seconds and refreshes every 30 minutes. This lowers
background work on the E4200 while retaining router-local recovery, and does
not introduce desktop SSH polling.

The **Endpoints** page already provides **Connect router to selected endpoint**.
It loads the router's Astrill server catalog, requires the read-only guard to
be off, requires exactly one selected endpoint, and asks for a Cancel-default
confirmation. This action does not install a VPN or change local routing on
the Windows PC.

The connection operation is transactional in both supported modes:

- With the companion enabled, the companion performs the switch, verifies the
  native DD-WRT readback, and restores changed connection settings if the
  switch fails.
- In native-only mode, the app remembers the previous selection and connection
  state, disconnects only when needed, writes the new selection, connects, and
  verifies the readback. A failed attempt restores the previous values and
  reconnects the old session when it had been connected.

### Endpoint filtering, selection, and ordering

The **Country** selector is an exact endpoint-country filter. For example,
selecting one country compares the catalog's complete country name; it does not
use substring matching or accidentally include a similarly named region.
Search can still match endpoint name, country, mapped region, or server ID.

Endpoint selection uses the same durable model as Services: row checkboxes,
`Ctrl`, `Shift`, tri-state **Select visible**, and **Clear**. A
selection hidden by search or country filters remains selected and is called
out in the selection summary. Connecting requires exactly one endpoint, while
latency and favorite actions can use a batch.

Windows release `0.2.11` keeps search and reload on the first row, places
Country, Protocol, Sort, **PC latency...**, and **Connect selected** on the
second, and combines selection, favorite synchronization, and connection
behavior in one compact card. The endpoint table receives all remaining
height, so substantially more servers stay visible without scrolling.
**Behavior...** opens the two native failover/boot preferences without
permanently using another row above the table.

The sort presets remain **Default order**, **Region (A–Z)**, and **PC latency
(fastest)**. Clicking a table header adds semantic ascending/descending sorts
for Select, Endpoint, Region, Favorite, Server ID, Router state, Nodes, PC
latency, Reach, and Tested. Numeric columns sort as numbers rather than text;
selection and favorite columns sort by actual membership; router state uses
the current/connected state; and latency, reach, and tested use the saved
probe state. Missing values stay at the end in either direction, with the
original Astrill catalog order as the stable tie breaker. Sorting and
filtering preserve selections and never run a test.

### Atomic bulk router favorites

The **Favorite** column is backed by DD-WRT's native `astrill_favlist`. The app
reads it after the endpoint catalog loads, on **Sync from router**, and from
completed-action readbacks. These reads are event-driven; there is no recurring
favorite or router-status poll.

To change favorites:

1. Turn off the read-only guard only when router writes are intended.
2. Load **Endpoints**, select **Sync from router**, then select one or more
   endpoint rows.
3. For additions, choose a protocol supported by every selected endpoint and
   select **Favorite selected**. For removals, select **Unfavorite selected**;
   removal matches only the server ID and does not depend on protocol.
4. Review the Cancel-default batch summary, approve it, and wait for the
   verified DD-WRT readback.

The entire addition is validated before any write, so one endpoint lacking the
chosen protocol blocks the batch. A confirmed batch then:

1. reads the complete favorite value once;
2. preserves existing and unrecognized records and their order;
3. appends only new selections in selected order, or removes only the selected
   server IDs;
4. compares the fresh value before writing;
5. commits at most once; and
6. reads back and verifies the exact result.

A no-op makes no commit. Malformed data, a concurrent favorite change, or any
validation error stops before overwrite and asks for a fresh sync.

An unrelated Astrill or Connection draft no longer makes **Favorite selected**
look active while silently blocking the click. The favorite action remains
available and merges only the verified `astrill_favlist` readback into the
Connection editor's baseline, preserving pending endpoint, protocol, port,
cipher, MTU, and resilience edits. If the Connection draft itself changes
favorite membership, the Endpoints favorite buttons are visibly disabled and
their tooltip names that exact conflict until the draft is saved or reloaded.
Changing favorites does not require the companion, reconnect or switch the
active tunnel, run a latency test, change Windows routing, or start background
monitoring.

### Persistent, manual PC latency

Select the single compact **PC latency...** button to open the reusable test
dialog. Its scope can be selected endpoints, currently visible endpoints, or
all loaded endpoints. **Run latency test** performs bounded TCP connection
checks from the Windows PC and reports connection setup latency. Closing and
reopening the dialog preserves its scope and status.
The test never starts automatically: opening the page, loading or filtering
the catalog, changing protocol, sorting, and refreshing status do not launch
it.

This PC-side check sends no SSH command to DD-WRT, does not read or write router
configuration, and does not connect or switch the router tunnel. It is not a
VPN throughput or download-speed test; it measures only TCP connection setup
over the PC's current network path, which can differ from the path used by the
router.

The results persist across app restarts in a separate validated local cache;
loading them never starts a network test. Each row keeps its tested time.
Results older than 24 hours, or results whose advertised Astrill address or
port changed, are marked for a manual retest. **Clear saved results** removes
the cache.

### Reboot and automatic connection behavior

There are two independent autostart settings:

- The Windows Startup shortcut opens the GUI after Windows sign-in. It does not
  connect a local VPN, poll the router repeatedly, or replace the router's own
  startup behavior.
- **Start automatically after router boot** writes native Astrill's
  `astrill_autostart` preference. If it is off, a valid and reachable saved
  endpoint can still remain disconnected after a router reboot; that expected
  state is not evidence that endpoint switching failed.

**Auto reconnect to next favorite server** controls native favorite failover.
The companion's router-local startup hook and watchdog can reconstruct its own
runtime after DD-WRT reboots without the desktop. Neither mechanism justifies
a desktop polling loop.

During the July 2026 inspection, the tunnel was down because native Astrill
autostart was disabled. Its saved endpoint and protocol were valid and
reachable, and no post-boot connection attempt had reached the companion. That
snapshot therefore did not demonstrate a failed endpoint connection. Use the
app's **Start automatically after router boot** control and verify its router
readback when automatic reconnection is wanted.

### Current 2026-07-30 companion 0.2.11 hybrid deployment

The persistent package installed from the current source is 19,960 bytes,
26,616 base64 bytes, and 15 NVRAM chunks. Its MD5 is
`3552747bcb9a06a8f6b64dcbb1ce0675`; its SHA-256 is
`2f0dbbda03af55a54ebf75fa6a06d2f47ffcd071310082544202edac4422a4be`.
The locked installer preflight started at 3,115 free NVRAM bytes, projected 608
bytes of growth and 2,507 free, and observed 2,494 free after reboot. The final
446-byte margin remained above the required 2,048-byte reserve.

The generation-1 persistent core contained three origins, 41 rows, 4,135
bytes, and hash `md5:b9651667705f05dbd97019aa529bc256`. The Windows
controller loaded 85 origins as a generation-1, 275-row/24,551-byte overlay
with hash `md5:6d6fe09c400bb103e0af5a168236f1d6`, source
`192.168.1.166/32`, and MAC `54:bf:64:80:aa:23`. The resulting 316-row,
38,455-byte effective document had hash
`md5:383499271b38e263b709040abbed1da8`.

The first large load exceeded the original 120-second helper deadline and
failed safely without replacing the active policy. With a 240-second router
deadline and 330-second Windows allowance, the manual load completed in 277.82
seconds including client work. That DNS snapshot produced 694 generated
matches and 1,394 chain rules. Both topology guards read one active reference
and no inactive reference. Single-process validation plus committed-effective
readback reduced normal status from more than 90 seconds to about seven
seconds.

Physical reboot created runtime epoch
`c838dc8397a57cd936a1f9e7e3649caa`. The router activated the core by itself and
cleared the RAM helper and overlay as designed. The opted-in Windows app then
staged the helper and restored its overlay exactly once in about 200 seconds;
the GUI remained responsive, both saved epoch fields matched, and no error was
recorded. Fresh DNS produced 693 generated matches and 1,392 chain rules, one
normal DNS-time rule pair fewer than before reboot without changing the
effective document hash. Final status showed one active reference, no inactive
reference, no transaction residue, 2,494 free NVRAM bytes, and Astrill
disconnected.

### Historical 2026-07-30 companion 0.2.5 deployment

The finalized router archive was 16,598 bytes in 13 NVRAM chunks. A full NVRAM
and runtime backup was captured while Astrill was down before upgrading. The
installed companion then reported `0.2.5`, healthy/ready, with one watchdog,
both dedicated tables ready, the fail guard active, no owned RPDB rules, and
8,935 NVRAM bytes free.

The selected UU plus Nutstore document installed exactly two enabled origins:
24 Direct rows, 2,688 bytes, 43 resolved addresses, and zero unresolved
domains. The active Windows flows were UU Remote at
`223.252.194.149:443` and Nutstore at `160.19.208.29:80`. Controlled TCP
probes incremented their Direct mark/return counters. Two managed connects
both produced the same verified ordering: Direct `32762`, VPN-policy `32763`,
and native Astrill `32764`. Table `213` pointed to `vlan2`; connected table
`212` contained the `tun0` route plus the metric-32767 blackhole fallback.

The final requested state was restored and checked again after watchdog and
GUI reconciliation: Astrill disconnected, no `tun0` or owned RPDB rules,
blackhole-only table `212`, filter fail-closed active, both applied origins
retained, and policy health ready. The rebuilt Windows `0.2.12` app was
installed and opened with no console child. Desktop and login-startup
shortcuts target the new executable, and the legacy Start Menu shortcut is
absent.

This section is retained as earlier acceptance evidence; the current
`0.2.13`/`0.2.11` physical-reboot and one-shot-overlay result is recorded
immediately above.

## E4200 2.4 GHz Deep Check

A read-only check was performed after reports that an E4200 v1 sometimes lost
2.4 GHz service and became hard to manage. It did not reproduce the failure.
The router had recently rebooted, and syslog, kernel logging, and remote
logging were all disabled, so the evidence needed to determine the previous
failure's root cause no longer existed.

At inspection time, the DD-WRT r62374 router showed:

- healthy CPU, memory, connection tracking, NVRAM space, file-descriptor use,
  and approximately 54/52 C radio temperatures;
- both radios up with strong associated clients and zero packet loss in the
  wired management ping sample;
- no current OOM, kernel, or radio error in the available runtime output;
- conservative 2.4 GHz AP settings: fixed channel 6, 20 MHz width, WMM on,
  no-ack off, frameburst and afterburner off, beacon 100, DTIM 1, automatic
  protection, and AES; and
- at the initial radio inspection, a healthy, low-load companion with no
  wireless-control (`wl`) commands; its then-zero policy count matched the
  empty Windows configuration.

The check therefore did not implicate the desktop app or companion, but one
healthy snapshot also cannot prove the intermittent radio path is sound. Both
bands were manually configured for 100 mW, the driver reported an unusual
power ceiling, and frame counters were high. The 5 GHz counters were worse,
however, so none of those observations establishes the 2.4 GHz root cause.
Power-supply sag from an aging 12 V / 2 A adapter remains plausible but
unproven.

Use staged diagnostics rather than a broad reset:

1. Test a known-good, regulated 12 V / 2 A supply with the correct connector
   and polarity, keep the router ventilated, and observe whether the symptom
   recurs.
2. Send syslog and kernel log to a separate LAN collector so the next failure
   survives a reboot. Avoid sustained logging to JFFS/flash.
3. Capture radio association, error counters, load, memory, temperatures, and
   wired reachability during the failure before restarting anything.
4. If power and logs do not identify the cause, A/B test one setting at a time:
   return transmit power to Auto/default or 71 mW first. Preserve the prior
   value and test long enough to compare.
5. Only as a later isolated test, disable 2.4 GHz APSD while keeping WMM on.

The evidence did not justify a firmware flash, NVRAM erase, scheduled reboot,
watchdog restart loop, simultaneous radio retune, or speculative permanent
mutation, and none was made during the check. Consider firmware or broader
radio changes only after logs capture a repeatable fault and a rollback/export
path is ready.

## Update Or Remove

Close the app before an update, rebuild, and run `install-native.ps1` again.
To uninstall the application:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\contrib\windows\uninstall-native.ps1
```

Uninstall removes the app folder and matching Desktop, Startup, and legacy
Start Menu shortcuts but preserves unrelated shortcuts, configuration, and SSH
keys. Review and remove retained configuration or keys manually only when they
are no longer needed.

The canonical, more detailed references remain
[the Windows application guide](https://github.com/lachlanchen/astrill-lazy-router/blob/main/docs/WINDOWS_APP.md),
[the rule model](https://github.com/lachlanchen/astrill-lazy-router/blob/main/docs/RULE_MODEL.md),
and
[the router installation guide](https://github.com/lachlanchen/astrill-lazy-router/blob/main/docs/ROUTER_INSTALL.md)
in the Astrill Lazy Router repository.
