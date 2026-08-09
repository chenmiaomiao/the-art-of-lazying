# Diagnose Speaker Pulses During a UU Remote Session

## Do Not Diagnose by Timing Alone

Hearing a repeated pulse while connected through UU Remote does not prove that
UU generated it. A shared desktop can contain unrelated games, browsers,
speech services and remote-audio sinks. Identify the live PipeWire stream
before changing the bridge or global sound configuration.

The UU Ubuntu bridge's internal SDL FreeRDP relay is intentionally launched
with `/audio-mode:2`. In the 2026-08-09 incident, UU and FreeRDP owned no
playback node. An unrelated packaged Unreal game did:

```text
application.name = SDL Application
application.process.binary = SHI
media.class = Stream/Output/Audio
target.object = ...USB_Audio_2...sink
```

The game's log independently confirmed that SDL3 opened the physical USB
S/PDIF device as a six-channel 48 kHz output. UU merely made the session
visible while that process held the speaker path open.

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
- `media.class = Stream/Output/Audio`;
- the target sink;
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
- UU remained active;
- XRDP, GNOME Shell, and open windows were not restarted;
- future SHI remote previews start without an audio device unless sound is
  explicitly requested.

## Related Notes

- [UU Remote Ubuntu bridge](./uu-remote-ubuntu-bridge.md)
- [Keep UU on the existing XRDP desktop](./uu-remote-same-xrdp-desktop.md)
- [Bridge troubleshooting](../../code/uu-remote-ubuntu-bridge/docs/troubleshooting.md)
