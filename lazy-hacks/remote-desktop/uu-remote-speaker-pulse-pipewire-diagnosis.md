# Diagnose Speaker Pulses During a UU Remote Session

## Do Not Diagnose by Timing Alone

Hearing a repeated pulse while connected through UU Remote does not prove that
UU generated it. A shared desktop can contain unrelated games, browsers,
speech services and remote-audio sinks. Identify the live PipeWire stream
before changing the bridge or global sound configuration.

The UU Ubuntu bridge's internal SDL FreeRDP relay is intentionally launched
with `/audio-mode:2`. During the first 2026-08-09 inspection, UU and FreeRDP
owned no playback node. An unrelated packaged Unreal game did:

```text
application.name = SDL Application
application.process.binary = SHI
media.class = Stream/Output/Audio
target.object = ...USB_Audio_2...sink
```

The game's log independently confirmed that SDL3 opened the physical USB
S/PDIF device as a six-channel 48 kHz output. UU merely made the session
visible while that process held the speaker path open. This finding was real,
but a later bridge restart exposed a second, separate source described below.

## Inspect the Owner

```bash
wpctl status
wpctl inspect NODE_OR_CLIENT_ID
pw-link -l
timeout 3s pw-top -b -n 5

pgrep -a -u "$UID" -f 'sdl-freerdp|GameViewer|SHI'
```

PipeWire IDs change whenever streams reconnect. Before mutation, verify at
least:

- `application.process.binary`;
- `media.class = Stream/Output/Audio` or `Stream/Input/Audio`;
- the target sink or source;
- the corresponding Unix process command.

This workstation did not need `pactl`; `wpctl`, `pw-link`, and `pw-top` were
already available from PipeWire.

## Stop the Current Pulse Without Closing the App

Mute only the identified stream:

```bash
wpctl set-mute STREAM_NODE_ID 1
wpctl get-volume STREAM_NODE_ID
```

Expected confirmation:

```text
Volume: 1.00 [MUTED]
```

If the physical device remains active despite mute, inspect exact links and
move only that application's channel ports to an existing virtual sink. The
validated host used:

```bash
pw-link -d 'SDL Application:output_FL' \
  'PHYSICAL_SINK:playback_FL'
pw-link -d 'SDL Application:output_FR' \
  'PHYSICAL_SINK:playback_FR'

pw-link 'SDL Application:output_FL' 'xrdp-sink:send_FL'
pw-link 'SDL Application:output_FR' 'xrdp-sink:send_FR'
```

Replace `PHYSICAL_SINK` with the exact name shown by `pw-link -l`. Do not use
wildcards and do not run this when more than one stream has the same
application name. After the move, `pw-top` should show the physical sink idle.

This preserves the game window and process. It also avoids restarting
PipeWire, WirePlumber, XRDP, GNOME Shell, or UU.

## When UU Itself Opens Physical Audio

After the bridge restarted at 22:58, a second inspection showed two new
streams owned by Wine's `GameViewerServer.exe`:

```text
Output/Audio  网易UU远程服务 -> physical USB S/PDIF
Input/Audio   网易UU远程服务 <- C922 webcam microphone
```

The capture stream was active and `pipewire-pulse` emitted repeated messages:

```text
[网易UU远程服务] overrun recover
```

This explained why removing only the SHI path did not fully solve the sound.
Mute both dynamically discovered UU nodes. Then use IDs from `pw-link -I -l`
to move only their links from the physical devices to `xrdp-sink` and
`xrdp-source`. Do not copy IDs from another run; they are regenerated whenever
PipeWire reconnects a stream.

`wpctl set-mute` stores the per-application input and output mute through
WirePlumber's stream-restore mechanism. Do not edit that state database by
hand. Add a second service-scoped boundary for future bridge processes:

```ini
# ~/.config/systemd/user/uu-remote-bridge.service.d/20-audio-isolation.conf
[Service]
Environment="PULSE_SINK=xrdp-sink"
Environment="PULSE_SOURCE=xrdp-source"
```

Apply the unit metadata without disconnecting the live bridge:

```bash
systemctl --user daemon-reload
systemctl --user show uu-remote-bridge.service \
  -p ActiveState -p ExecMainStartTimestamp -p Environment
```

The running process retains its old environment until its next normal restart;
the live mute and link changes take effect immediately. On the validated host,
both UU audio streams then closed, the final overrun was logged at 23:17:18,
the C922 source suspended, and the physical USB output remained idle. The UU
service retained the same process and start timestamp.

## Prevent It on the Next Unreal Preview

Use Unreal's supported runtime option:

```bash
/path/to/PackagedGame.sh -nosound
```

Keep sound as an explicit local-review choice:

```bash
/path/to/PackagedGame.sh -enablesound
```

On the validated workstation, `shi-remote-preview` supplies `-nosound` by
default and accepts `--with-sound` as the explicit override. The generated
package launcher also defaults to `-nosound`, with a timestamped rollback copy.

An application launch flag is preferable to a global WirePlumber rule or a
polling daemon: it is deterministic, process-scoped, easy to reverse, and
cannot mute unrelated SDL applications.

## Acceptance Evidence

- the SHI window and process remained alive;
- only its stream was muted;
- its two output links moved to `xrdp-sink`;
- physical USB S/PDIF changed from running to idle;
- both later UU input/output streams were muted and left the physical graph;
- the webcam microphone returned to suspended state;
- the continuous PipeWire overrun messages stopped;
- a service drop-in redirects future UU Wine audio to XRDP virtual endpoints;
- UU remained active;
- XRDP, GNOME Shell, and open windows were not restarted;
- future SHI remote previews start without an audio device unless sound is
  explicitly requested.

## Related Notes

- [UU Remote Ubuntu bridge](./uu-remote-ubuntu-bridge.md)
- [Keep UU on the existing XRDP desktop](./uu-remote-same-xrdp-desktop.md)
- [Bridge troubleshooting](../../code/uu-remote-ubuntu-bridge/docs/troubleshooting.md)
