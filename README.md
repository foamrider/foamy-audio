# Foamy Audio

Audio outputs, microphones, app volume, and AirPlay.

![Foamy Audio screenshot](preview.png)

## Install

Requires Omarchy Quattro with PipeWire, Python 3, and `jq`. For AirPlay, also install
`pipewire-zeroconf`, `pactl`, and `avahi-browse`.

AirPlay also needs incoming UDP timing/control traffic from the selected
receiver. A firewall can allow discovery and selection while blocking sound;
PipeWire normally uses UDP ports 6001 and 6002, with additional ports for
simultaneous receivers. In Settings → Advanced, **Firewall rules → Verify** reads live
UFW status. **Apply** adds an unrestricted UDP 6001–6002 allow
rule for all source IPs and interfaces. Each action requests administrator
authorization once through Polkit; use **Verify** separately to check after applying. Opening ports does not enable an
inactive firewall or remove existing rules; earlier deny rules may still need
manual review. The check covers UFW rules, not other firewalls or router rules.

Microphone metering uses Quickshell for stereo sources. Other channel layouts,
including Pro Audio AUX microphones, use Python 3 and PipeWire's `pw-record`
with the source's channel map. Capture runs only while the panel is open;
only level numbers leave the helper, and no audio is saved or transmitted.
Closing the panel or switching microphones stops the previous capture.
During AirPlay, the meter uses passive capture for every channel layout: it
shows levels only while another application uses the microphone, so opening
the panel does not wake the microphone and disturb the playback clock.

```sh
omarchy plugin add https://github.com/foamrider/foamy-audio.git --enable
```

Remove the previous audio widget from the bar when replacing it.

## Use

- Left-click the widget to open the panel. Select a device row to switch to it.
- Hover over a row to reveal its volume slider. Expand Apps for per-app volume.
- Use the speaker and microphone icons to mute each channel. Right-click the
  bar widget to mute both. Scrolling never changes volume.
- Open the cog to change language and bar percentage. Settings
  are saved in Omarchy's `shell.json`.
- Expand Wireless and use the checkboxes to select one or more AirPlay speakers.
  Select a speaker again
  to remove it from the group; removing the last speaker returns to local audio.
  Only selected speakers show volume controls. Each speaker keeps its own level.
  Switching to a local output keeps discovered speakers listed while the panel
  is open. Discovery stops when the panel closes with no AirPlay output selected.
  Group playback uses PipeWire latency compensation; synchronization depends on
  the receivers. The vertical meter shows the selected microphone's input level.

## Remove

Select a local output and deselect AirPlay receivers before removal.

```sh
omarchy plugin remove foamy.audio
```

Restore the stock audio widget through the bar settings if needed. Device volumes and
selections remain as last configured. Optional UFW rules added through
**Firewall rules → Apply** also remain; review and remove those rules separately
if no other AirPlay application needs them. Removing the plugin does not
uninstall PipeWire, Avahi, or other packages.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

Licensed under [MIT](LICENSE). Omarchy and Lucide notices are in
[LICENSE-OMARCHY](LICENSE-OMARCHY) and [LICENSE-LUCIDE](LICENSE-LUCIDE).

Provided **as is**, without warranty or guaranteed support. Use at your own risk.
