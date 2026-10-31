import QtQuick
import "../kit"
import ".." as Audio

// Mock states for the foamy-kit preview harness (no PipeWire, no processes).
// The harness sets bar/anchorItem, then cycles previewState and captures `popup`.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["default", "wireless", "empty", "settings", "settings-firewall"]
  property string previewState: "default"
  readonly property Item popup: popup

  function node(id, name, label, volume, muted) {
    return { id: id, name: name, label: label, audio: { volume: volume, muted: !!muted } }
  }
  readonly property var sinks: [node(1, "alsa_output.speakers", "Speakers", 0.46), node(2, "bluez_output.headphones", "WH-1000XM5", 0.6),
    node(3, "alsa_output.hdmi", "LG UltraFine", 0.8)]
  readonly property var sources: [node(4, "alsa_input.mic", "Laptop microphone", 0.7), node(5, "alsa_input.usb", "Yeti Nano", 0.5)]
  readonly property var streams: [node(6, "spotify", "Spotify", 0.9), node(7, "firefox", "Firefox", 1.0, true)]
  readonly property var speakers: [node(8, "raop_sink.living", "Living room", 0.35), node(9, "raop_sink.kitchen", "Kitchen", 0.5)]
  readonly property var allNodes: sinks.concat(sources, streams, speakers)
  function rows(list) { return list.map(function(n) { return { id: n.id, name: n.name } }) }

  QtObject {
    id: mock
    readonly property string state: preview.previewState
    readonly property bool empty: state === "empty"
    readonly property bool wireless: state === "wireless"
    property bool opened: true
    readonly property bool editingSettings: state.indexOf("settings") === 0
    readonly property real volumeStep: 0.05
    readonly property var displayAudioSinks: empty ? [] : preview.rows(preview.sinks)
    readonly property var displayAudioSources: empty ? [] : preview.rows(preview.sources)
    readonly property var displayAudioStreams: empty ? [] : preview.rows(preview.streams)
    readonly property var displayWirelessAudioSinks: wireless ? preview.rows(preview.speakers) : []
    readonly property string outputLabel: empty ? "" : wireless ? "Living room" : "Speakers"
    readonly property bool hasOutput: !empty
    readonly property bool hasInput: !empty
    readonly property real outputVolume: wireless ? 0.35 : 0.46
    readonly property bool outputMuted: false
    readonly property bool inputMuted: false
    readonly property bool anyAudible: !empty
    readonly property bool airplayActive: wireless
    readonly property string airplayScanState: empty ? "error" : wireless ? "results" : "scanning"
    readonly property string airplayError: empty ? "AirPlay support is not installed (pipewire-zeroconf)" : ""
    readonly property bool airplayScanning: airplayScanState === "scanning"
    readonly property bool airplayStopping: false
    readonly property bool airplaySelecting: false
    readonly property int airplayPeerCount: state === "settings-firewall" ? 2 : 0
    readonly property real inputPeak: 0.55
    readonly property string inputMeterError: ""
    readonly property bool showPercentage: true
    readonly property bool saving: false
    readonly property string settingsError: ""
    readonly property bool settingsRetryable: false
    readonly property bool firewallBusy: false
    readonly property string firewallState: state === "settings-firewall" ? "wide" : ""
    readonly property string firewallMessage: state === "settings-firewall"
      ? "Ports are open to every network. Remove the rule, then apply to limit it to this network." : ""
    function nodeFor(row) { for (var i = 0; row && i < preview.allNodes.length; i++) if (preview.allNodes[i].id === row.id) return preview.allNodes[i]; return null }
    function rowLabel(kind, n) { return n ? n.label : "" }
    function rowIcon(kind, n) {
      return kind === "source" ? "mic" : kind === "stream" ? (n && n.audio.muted ? "volume-x" : "app-window")
        : kind === "wireless" ? "airplay" : n && n.id === 2 ? "headphones" : "speaker"
    }
    function streamIconSource(n) { return "" }
    function isSelected(kind, n) {
      if (!n) return false
      return kind === "sink" ? n.id === 1 && !wireless : kind === "source" ? n.id === 4 : kind === "wireless" ? n.id === 8 : false
    }
    function volumeTarget(kind, n) { return n }
    function nodeHasVolume(n) { return !!(n && n.audio) }
    function nodeVolume(n) { return n && n.audio ? n.audio.volume : 0 }
    function nodeMuted(n) { return !!(n && n.audio && n.audio.muted) }
    function setNodeVolume(n, v, m) {}
    function toggleNodeMute(n) {}
    function activate(kind, n) {}
    function setOutputVolume(v) {}
    function toggleOutputMute() {}
    function toggleInputMute() {}
    function toggleAllMuted() {}
    function openSettings() {}
    function closeSettings() {}
    function close() {}
    function switchPanel(d) {}
    function save(k, v) {}
    function retrySave() {}
    function firewallAction(a) {}
  }

  FoamyPopup {
    id: popup
    anchorItem: preview.anchorItem
    bar: preview.bar
    open: true
    body: Component {
      Audio.AudioView { audio: mock }
    }
  }
}
