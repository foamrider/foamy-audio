pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Model.js" as Model
import "Preferences.js" as Schema

// The bar widget (one per monitor on 4.5). Shared state lives in the
// AudioService singleton; this file owns the bar button, the popup with its
// row snapshots, settings saving and the firewall helper. AudioView draws the
// popup body from the API below (preview/Preview.qml feeds a mock of it).
Panel {
  id: root
  ipcTarget: "foamy.audio"
  manageIpc: false
  readonly property alias popup: popup

  FoamyMember { id: member; scope: "audio"; demanding: root.opened }

  readonly property bool vertical: bar && (bar.position === "left" || bar.position === "right")
  readonly property bool showPercentage: Prefs.value(Schema.fields, settings, "showPercentage")
  readonly property real volumeStep: 0.05

  // ---- Levels (from the service) -----------------------------------------
  readonly property var sink: AudioService.sink
  readonly property var source: AudioService.source
  readonly property bool hasOutput: AudioService.hasOutput
  readonly property bool hasInput: AudioService.hasInput
  readonly property real outputVolume: AudioService.outputVolume
  readonly property bool outputMuted: AudioService.outputMuted
  readonly property bool inputMuted: AudioService.inputMuted
  readonly property bool anyAudible: AudioService.anyAudible
  readonly property bool airplayActive: AudioService.airplayActive
  readonly property string outputLabel: !sink ? "" : airplayActive ? airplayRoomLabel(sink) : Model.nodeLabel(sink)
  readonly property string airplayScanState: AudioService.airplayScanState
  readonly property string airplayError: AudioService.airplayError
  readonly property bool airplayScanning: AudioService.airplayScanning
  readonly property bool airplayStopping: AudioService.airplayStopping
  readonly property bool airplaySelecting: AudioService.airplaySelecting
  readonly property int airplayPeerCount: AudioService.airplayPeers.length
  readonly property real inputPeak: inputPeakMonitor.peak
  readonly property string inputMeterError: inputPeakMonitor.error

  function setOutputVolume(value) { AudioService.setOutputVolume(value) }
  function toggleOutputMute() { AudioService.toggleOutputMute() }
  function toggleInputMute() { AudioService.toggleInputMute() }
  function toggleAllMuted() { AudioService.toggleAllMuted() }
  function nodeHasVolume(node) { return AudioService.nodeHasVolume(node) }
  function nodeVolume(node) { return AudioService.nodeVolume(node) }
  function nodeMuted(node) { return AudioService.nodeMuted(node) }
  function setNodeVolume(node, value, maximum) { AudioService.setNodeVolume(node, value, maximum) }
  function toggleNodeMute(node) { AudioService.toggleNodeMute(node) }

  // ---- Rows ----------------------------------------------------------------
  // Repeaters get snapshots of {id, name} (Model.rowSnapshot), refreshed after
  // PipeWire settles; closed panels keep them empty.
  property var displayAudioSinks: []
  property var displayWirelessAudioSinks: []
  property var displayAudioSources: []
  property var displayAudioStreams: []

  Connections {
    target: AudioService
    function onAudioSinksChanged() { root.scheduleRows() }
    function onRawWirelessAudioSinksChanged() { root.scheduleRows() }
    function onAirplayPeersChanged() { root.scheduleRows() }
    function onAudioSourcesChanged() { root.scheduleRows() }
    function onAudioStreamsChanged() { root.scheduleRows() }
  }

  function scheduleRows() { if (opened) rowsTimer.restart() }
  function refreshRows() {
    if (!opened) return
    displayAudioSinks = Model.rowSnapshot(AudioService.audioSinks)
    displayWirelessAudioSinks = Model.rowSnapshot(Model.uniqueAirplaySinks(
      AudioService.rawWirelessAudioSinks.slice(), AudioService.airplayPeers, sink))
    displayAudioSources = Model.rowSnapshot(AudioService.audioSources)
    displayAudioStreams = Model.rowSnapshot(AudioService.audioStreams)
  }
  function clearRows() {
    rowsTimer.stop()
    displayAudioSinks = []
    displayWirelessAudioSinks = []
    displayAudioSources = []
    displayAudioStreams = []
  }
  Timer { id: rowsTimer; interval: 75; onTriggered: root.refreshRows() }

  onOpenedChanged: {
    if (opened) {
      refreshRows()
    } else {
      clearRows()
      editingSettings = false
    }
  }

  function nodeFor(row) { return Model.nodeFor(row, AudioService.nodes) }
  function nodeLabel(node) {
    var label = node ? Model.nodeLabel(node) : ""
    return label === "Unknown" ? FoamyI18n.t(label) : label
  }
  function airplayRoomLabel(node) {
    if (node && String(node.name).indexOf("foamy_airplay_group_") === 0) return FoamyI18n.t("AirPlay group")
    var peer = Model.airplayPeerForSink(node, AudioService.airplayPeers)
    if (peer && peer.name) return String(peer.name)
    var label = Model.airplayRoomLabel(node)
    return label === "AirPlay speaker" ? FoamyI18n.t(label) : label
  }
  function streamLabel(node) { return Model.streamLabel(node, AudioService.mprisPlayers, AudioService.audioStreams) }
  function rowLabel(kind, node) {
    if (!node) return ""
    return kind === "stream" ? streamLabel(node) : kind === "wireless" ? airplayRoomLabel(node) : nodeLabel(node)
  }
  function rowIcon(kind, node) {
    if (kind === "source") return "mic"
    if (kind === "stream") return node && nodeMuted(node) ? "volume-x" : "app-window"
    if (kind === "wireless" || Model.isAirplaySink(node)) return "airplay"
    return Model.isHeadphones(node, AudioService.bluetoothDevices) ? "headphones" : "speaker"
  }
  function isSelected(kind, node) {
    if (!node) return false
    if (kind === "sink") return !!sink && sink.id === node.id
    if (kind === "source") return !!source && source.id === node.id
    if (kind === "wireless") return AudioService.airplaySelected(node)
    return false
  }
  // The default output row controls the physical sink behind any DSP sink.
  function volumeTarget(kind, node) { return kind === "sink" && node && sink && node.id === sink.id ? AudioService.volumeSink : node }
  function activate(kind, node) {
    if (!node) return
    if (kind === "sink") AudioService.selectLocalSink(node)
    else if (kind === "source") AudioService.setDefaultSource(node)
    else if (kind === "wireless") AudioService.selectAirplaySink(node)
    else toggleNodeMute(node)
  }

  function appIconSource(icon) {
    var value = String(icon || "")
    if (!value) return ""
    if (value.indexOf("file://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function streamIconSource(node) {
    var properties = Model.nodeProps(node)
    var supplied = appIconSource(properties["application.icon-name"])
    if (supplied) return supplied
    // Some streams omit an icon or desktop ID; resolve the installed app by identity.
    DesktopEntries.applications.values
    var candidates = [properties["application.id"], properties["application.process.binary"],
      properties["application.name"], streamLabel(node), node ? node.name : ""]
    for (var i = 0; i < candidates.length; i++) {
      if (!candidates[i]) continue
      var name = String(candidates[i]).replace(/\.desktop$/, "")
      var entry = DesktopEntries.byId(name) || DesktopEntries.heuristicLookup(name)
      var found = entry ? appIconSource(entry.icon) : ""
      if (found) return found
    }
    return ""
  }

  MicrophonePeak {
    id: inputPeakMonitor
    source: AudioService.inputViaWpctl ? null : root.source
    // Waking an idle microphone can steal the clock driving network playback.
    passive: root.airplayActive
    enabled: root.opened && !!root.source
  }

  // ---- Settings ------------------------------------------------------------
  property bool editingSettings: false
  property bool saving: false
  property string settingsError: ""
  property var lastSave: null

  function openSettings() { editingSettings = true; open() }
  function closeSettings() { editingSettings = false }

  function save(key, next) {
    settingsError = ""
    lastSave = { key: key, value: next }
    var result = Prefs.save(root.bar, root.moduleName, Schema.fields, root.settings, key, next)
    if (!result.ok) { settingsError = result.error; return }
    if (result.command.length === 0) return
    saving = true
    saveProcess.command = result.command
    saveProcess.running = true
  }
  function retrySave() { if (lastSave) save(lastSave.key, lastSave.value) }

  Process {
    id: saveProcess
    onExited: function(code) {
      root.saving = false
      root.settingsError = code === 0 ? "" : "Couldn't save the setting."
    }
  }

  // ---- Firewall (Settings → AirPlay firewall) ------------------------------
  property string firewallState: ""
  property string firewallMessage: ""
  property bool firewallLegacy: false
  readonly property bool firewallBusy: firewallProcess.running
  readonly property var firewallMessages: ({
    open: "The speakers can reach PipeWire.",
    wide: "Ports are open to every network. Remove the rule, then apply to limit it to this network.",
    missing: "No rule lets the speakers in. Apply to allow this network.",
    present: "A Foamy Audio rule exists. Find speakers to check it.",
    conflict: "A blocking rule may affect AirPlay. Review the UFW rules.",
    inactive: "UFW is inactive.",
    applied: "Rule added for this network. Verify to check.",
    removed: "Foamy Audio rules removed.",
    none: "No Foamy Audio rules to remove.",
    nopeers: "No AirPlay speakers found yet."
  })

  function firewallAction(action) {
    if (firewallProcess.running) return
    var command = ["python3", AudioService.localPath(Qt.resolvedUrl("ufw_check.py")), action]
    if (action !== "remove") {
      var peers = AudioService.airplayPeers
      for (var i = 0; i < peers.length; i++) if (peers[i] && peers[i].address) command.push("--peer", String(peers[i].address))
    } else if (firewallLegacy) {
      command.push("--legacy")
    }
    firewallState = ""
    firewallMessage = ""
    firewallProcess.command = command
    firewallProcess.running = true
  }

  Process {
    id: firewallProcess
    stdout: StdioCollector { id: firewallOutput; waitForEnd: true }
    stderr: StdioCollector { id: firewallErrors; waitForEnd: true }
    onExited: function(code) {
      try {
        var result = JSON.parse(firewallOutput.text)
        if (!result.state || typeof result.message !== "string" || typeof result.details !== "string")
          throw new Error("Invalid UFW helper response")
        root.firewallState = code === 0 ? result.state : "error"
        if (result.legacy !== undefined) root.firewallLegacy = result.legacy === true
        if (result.state === "removed") root.firewallLegacy = false
        root.firewallMessage = result.details === "Administrator authorization was cancelled or denied."
          ? "Authorization cancelled or denied." : root.firewallMessages[root.firewallState] || result.message
        if (code !== 0) console.warn("Foamy Audio UFW:", result.details)
      } catch (error) {
        root.firewallState = "error"
        root.firewallMessage = "Could not complete the UFW check."
        console.warn("Foamy Audio UFW:", firewallErrors.text.trim() || String(error))
      }
    }
  }

  // ---- IPC (one handler per shell) ---------------------------------------
  function statusObject() {
    return {
      open: root.opened, settings: root.editingSettings, language: FoamyI18n.language, leader: member.isLeader,
      output: root.outputLabel, input: root.source ? Model.nodeLabel(root.source) : "",
      volume: root.outputVolume, inputVolume: AudioService.inputVolume, outputMuted: root.outputMuted, inputMuted: root.inputMuted,
      volumeSink: AudioService.volumeSink ? String(AudioService.volumeSink.name) : "",
      outputs: root.displayAudioSinks.length, inputs: root.displayAudioSources.length, apps: root.displayAudioStreams.length,
      wireless: root.airplayScanState, wirelessError: root.airplayError,
      wirelessOutputs: root.displayWirelessAudioSinks.map(function(row) {
        var node = root.nodeFor(row)
        return { name: row.name, label: root.airplayRoomLabel(node), selected: AudioService.airplaySelected(node) }
      }),
      settingsError: root.settingsError, firewall: root.firewallState,
      microphonePeak: inputPeakMonitor.peak, microphoneMeterError: inputPeakMonitor.error,
      platformHints: !!AudioService.platform, untypedInput: AudioService.inputViaWpctl
    }
  }

  FoamyIpc {
    target: "foamy.audio"
    enabled: member.isLeader
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void { root.openSettings() }
    function status(): string { return JSON.stringify(root.statusObject()) }
  }

  // The last instance going away (plugin disabled or removed) ends discovery.
  Component.onDestruction: if (member.members <= 1) AudioService.teardown()

  // ---- Bar button --------------------------------------------------------
  // Nerd Font code points as escapes: private-use glyphs are easy to lose in an edit.
  function barGlyph() {
    if (airplayActive) return "\u{F1749}"                 // nf-md-cast_audio_variant
    // The Waybar pulseaudio glyph set; the Material speaker icons render smaller.
    if (!sink || !sink.audio || outputMuted) return "\ueee8" // muted / no output
    if (Model.isHeadphones(sink, AudioService.bluetoothDevices)) return "\u{F02CB}" // nf-md-headphones
    if (outputVolume >= 0.67) return "\uf028"              // nf-fa-volume_up
    if (outputVolume >= 0.34) return "\uf027"              // nf-fa-volume_down
    if (outputVolume > 0) return "\uf026"                  // nf-fa-volume_off
    return "\ueee8"
  }


  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Math.max(Style.bar.iconSlot,
      barContent.implicitWidth + Style.bar.iconSlot - Style.bar.iconCanvas)
    dimmed: root.outputMuted
    tooltipText: FoamyI18n.t("Audio") + (root.outputLabel ? " · " + root.outputLabel : "")
    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(1)
      OpticalGlyph {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        text: root.barGlyph()
        fontFamily: button.fontFamily
        fontSize: button.fontSize
        color: button.foreground
      }
      Text {
        visible: root.showPercentage && !root.vertical
        anchors.verticalCenter: parent.verticalCenter
        text: FoamyI18n.t("%1%", Math.round(root.outputVolume * 100))
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
    }
    onPressed: function(b) { if (b === Qt.RightButton) root.toggleAllMuted(); else root.toggle() }
  }

  FoamyPopup {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    body: Component {
      AudioView { audio: root }
    }
  }
}
