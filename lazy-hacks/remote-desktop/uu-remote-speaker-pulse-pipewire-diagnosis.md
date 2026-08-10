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

Mute alone is not proof that the device is inactive. Two later regenerated
SHI review builds restored as muted but stayed linked to the S/PDIF sink, so
ALSA still reported the playback PCM as `RUNNING`. Rediscover and move every
exact live SHI link, and make generated launch commands carry `-NoSound`;
editing one older package launcher cannot govern future build directories.

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
hand. Live mute/link changes are useful for diagnosis, but do not persist
`PULSE_SINK=xrdp-sink` or `PULSE_SOURCE=xrdp-source` in the UU service.

That environment override was tested and rejected on 2026-08-10. The
multi-session workstation had many stale XRDP PipeWire modules exporting the
same node names. The UU server completed account login and the HTTP room
request, but Wine then hung at `Attempting to use the Windows Core Audio
APIs...`. It never created its two media factories, never connected signaling,
and therefore disappeared from every other UU client despite superficially
healthy room-request logs.

## Close the Hardware PCM, Not Just the Mixer Stream

For USB audio hardware that keeps its clock active while an idle stream is
linked, use the ALSA PCM state as the acceptance check:

```bash
cat /proc/asound/card*/pcm*p/sub*/status
fuser -v /dev/snd/*
```

On the affected workstation the relevant endpoint was the exact sink
`alsa_output.usb-Generic_USB_Audio-00.HiFi__hw_Audio_2__sink`. An
exact-device WirePlumber rule enabled `node.pause-on-idle` with a short suspend
timeout. Do not apply this to all sound devices. After removing all physical
links and loading that scoped rule,
`/proc/asound/card3/pcm2p/sub0/status` read `closed`.

## Disable UU's Own Audio Channel When It Is Unwanted

Even with the hardware PCM closed, UU's proprietary log showed that every
controller connection calls `startAudioCapture`. If audio is unnecessary for
this bridge, use the bridge's opt-in prefix boundary:

```ini
# ~/.config/systemd/user/uu-remote-bridge.service.d/20-audio-isolation.conf
[Service]
Environment="UURB_UU_AUDIO=off"
```

Reload systemd and restart only the UU bridge during a disconnected window:

```bash
systemctl --user daemon-reload
systemctl --user restart uu-remote-bridge.service
```

`UURB_UU_AUDIO=off` maps to `winepulse.drv=d` inside UU's dedicated Wine
prefix. It leaves browsers, native Ubuntu audio, XRDP, and unrelated Wine
prefixes unchanged. The compatibility default is `UURB_UU_AUDIO=system`.

On the validated host the existing XRDP session and all open applications
survived the scoped bridge restart. The new UU server had zero PipeWire audio
nodes, the physical PCM remained `closed`, and all live bridge checks passed.
Unlike the rejected forced-endpoint setup, this mode also completed both
WebRTC media factories, reported `signal connection success`, reached
`room_state_changed: created`, and advertised `LACHLANSERVER` as `CONNECTED`.

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
- no forced XRDP Pulse endpoint names remain in the service environment;
- UU remained active;
- XRDP, GNOME Shell, and open windows were not restarted;
- future SHI remote previews start without an audio device unless sound is
  explicitly requested.
- the final ALSA playback state is `closed`, not merely muted or idle;
- UU's dedicated Wine process uses `UURB_UU_AUDIO=off`, preventing its
  per-connection WebRTC audio capture path.

## Related Notes

- [UU Remote Ubuntu bridge](./uu-remote-ubuntu-bridge.md)
- [Keep UU on the existing XRDP desktop](./uu-remote-same-xrdp-desktop.md)
- [Bridge troubleshooting](../../code/uu-remote-ubuntu-bridge/docs/troubleshooting.md)

## Upstream References

- [WirePlumber ALSA device and node properties](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/alsa.html)
- [WirePlumber configuration fragments and array merging](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/modifying_configuration.html)
- [PipeWire property keys](https://pipewire.pages.freedesktop.org/pipewire/group__pw__keys.html)
