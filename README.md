# Foamy Audio

Audio controls for Omarchy Quattro: output selection, microphones, per-app
volume and AirPlay in a compact, theme-aware panel.

## Local installation

Clone [foamrider/foamy-audio](https://github.com/foamrider/foamy-audio), then
place this directory at `~/.config/omarchy/plugins/foamy.audio`, or symlink it
there from a local checkout. Then run:

```sh
omarchy-shell shell rescanPlugins
omarchy plugin enable foamy.audio --section right
omarchy restart shell
```

Remove the previous audio widget from the bar when replacing it.

## Controls

- Left-click the bar widget to open the panel. Right-click to mute or unmute
  both output and microphone. Scroll to adjust output volume.
- Select an Output, Input, or Wireless row to switch devices. Mini sliders
  appear on hover or keyboard focus; scrolling a row adjusts that device.
- The header speaker and microphone buttons mute their respective channels.
  A vertical level meter appears only on the selected microphone row.
- Apps contains playback streams; select a row to mute it. App volume supports
  up to 150%, matching Omarchy's mixer.
- Tab moves between controls. Enter or Space activates them; arrows adjust
  sliders. On a device row, Left/Right or H/L adjusts volume and M toggles mute.
- O, I, A and W expand the corresponding sections. S opens settings; Escape
  returns from settings or closes the panel.

Wireless and Apps start collapsed. AirPlay discovery starts when the panel
opens and stops when an unused scan closes. Selecting a local output restores
local routing and unloads only the discovery module owned by this plugin.

## Settings

The cog and Omarchy's plugin settings use the same manifest schema. Values are
stored on the `foamy.audio` bar entry in `~/.config/omarchy/shell.json`, using
Omarchy's `setBarWidget` IPC API. No separate preference file is created.

| Setting | Default | Values |
| --- | --- | --- |
| `language` | `system` | `system`, `en`, `nb` |
| `showPercentage` | `true` | Boolean |
| `scrollVolumeStep` | `"3"` | `"3"` or `"5"` percent |

## Requirements

Omarchy Quattro with Quickshell and PipeWire. Device switching uses Omarchy's
audio helpers, including the physical-output resolver for DSP/tuned speakers.
Optional AirPlay discovery needs `pipewire-zeroconf`, `pactl`, and `avahi-browse`.
Missing AirPlay support is reported in Wireless; local audio remains usable.
Transient discovery ownership is kept under `$XDG_RUNTIME_DIR`; it is not
plugin preferences. Device volumes and routing remain PipeWire state.

## Validation

```sh
node --test tests/*.test.js
python3 -m unittest discover -s tests -p 'test_*.py'
omarchy plugin validate .
```

## License

[MIT](LICENSE). Adapted Omarchy components and Lucide icons retain their notices
in [LICENSE-OMARCHY](LICENSE-OMARCHY) and [LICENSE-LUCIDE](LICENSE-LUCIDE).
