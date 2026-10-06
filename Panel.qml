import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model
import "Preferences.js" as Preferences

Panel {
  id: root
  moduleName: "foamy.audio"
  manageIpc: false
  ipcTarget: "foamy.audio"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var bluetoothDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var mediaService: bar?.shell?.firstPartyServiceFor("omarchy.media")
  readonly property var activeMediaPlayer: mediaService ? mediaService.activePlayer : null
  readonly property string airplayBridge: localPathFromUrl(Qt.resolvedUrl("airplay_bridge.py"))

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream) list.push(n)
    }
    return list
  }

  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && !n.isSink && !n.isStream && isAudioSource(n)) {
        var name = n.name || ""
        if (name === "quickshell") continue
        list.push(n)
      }
    }
    return list
  }

  readonly property var candidateStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !isPlaybackStream(n)) continue
      // Tuning and AirPlay group outputs route audio internally; they are not apps.
      var name = String(n.name || "")
      if (name.indexOf("omarchy_speaker_tuning") === 0
          || name.indexOf("output.foamy_airplay_group_") === 0) continue
      list.push(n)
    }
    return list
  }

  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false

  // Identify true playback streams without reading node.properties here:
  // PwNode.properties is invalid until the node is bound, and reading it while
  // capture streams are appearing (for example, when Voxtype starts recording)
  // can destabilize Quickshell's Pipewire service. Quickshell versions differ
  // in how `type` is exposed (media.class, enum name, or numeric enum), but
  // playback streams consistently accept audio input from clients and publish
  // `isSink: true`; capture streams publish as stream sources.
  function isPlaybackStream(node) {
    return Model.isPlaybackStream(node)
  }

  function isAudioSource(node) {
    return Model.isAudioSource(node)
  }

  property var cachedAudioSinks: []
  property var cachedAudioSources: []

  readonly property var rawAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++) {
      var candidate = candidateSinks[i]
      if (sinkAvailable(candidate) && !isAirplaySink(candidate)) list.push(candidate)
    }
    if (sink && !isAirplaySink(sink) && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var rawWirelessAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++) {
      var candidate = candidateSinks[i]
      if (sinkAvailable(candidate) && isAirplaySink(candidate)) list.push(candidate)
    }
    if (sink && isAirplaySink(sink) && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var rawAudioSources: {
    var list = candidateSources.slice()
    if (source && list.indexOf(source) < 0) list.unshift(source)
    return list
  }

  readonly property var audioSinks: rawAudioSinks.length > 0 ? rawAudioSinks : cachedAudioSinks
  readonly property var wirelessAudioSinks: rawWirelessAudioSinks
  readonly property var audioSources: rawAudioSources.length > 0 ? rawAudioSources : cachedAudioSources

  readonly property var audioStreams: {
    var list = []
    for (var i = 0; i < candidateStreams.length; i++)
      if (candidateStreams[i].audio) list.push(candidateStreams[i])
    return list
  }

  // Feed Repeaters with panel-local snapshots instead of the live PipeWire
  // model. PipeWire can remove nodes while Quickshell is dispatching the
  // removal signal; rebuilding a Repeater from that signal path has crashed
  // in Quickshell's PipeWire service. The snapshot timer lets that mutation
  // settle first, and closed panels keep their repeaters detached entirely.
  property var displayAudioSinks: []
  property var displayWirelessAudioSinks: []
  property var displayAudioSources: []
  property var displayAudioStreams: []

  // A DSP sink -- a speaker tuning, or EasyEffects -- can be the selected output
  // without being where loudness lives: changing its volume alters the level going
  // *into* the processing, so the slider would move while the speakers did not,
  // and on a chain with a limiter it would change the tone as well.
  //
  // omarchy-audio-output-sink resolves the *current* default output through any
  // such sink to the physical one, which is the same definition the volume keys
  // and the output switcher use. Resolving the default (rather than "whatever a
  // tuning fronts") is what keeps this correct when headphones or HDMI are
  // selected while a tuning still exists.
  property string volumeSinkName: ""

  readonly property real volumeStep: 0.01

  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio)
        return n
    }
    return sink
  }

  // Re-resolve whenever the selected output changes; the timer below is only a
  // safety net for the tuning being applied or removed underneath us.
  onSinkChanged: {
    resolveVolumeSink()
    if (airplayDiscoveryActive && sink && !isAirplaySink(sink)
        && !airplayStartProc.running && !airplayStopProc.running && !airplaySelectProc.running) {
      if (opened) selectLocalSink(sink)
      else stopAirplayDiscovery(sink)
    }
  }

  function resolveVolumeSink() {
    if (!volumeSinkProc.running) volumeSinkProc.running = true
  }

  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  readonly property real inputVolume: source && source.audio ? source.audio.volume : 0
  readonly property bool inputMuted: source && source.audio ? source.audio.muted : false

  // AirPlay discovery is scoped to panel use: opening starts it, closing an
  // unused scan stops it, and only a module owned here is ever unloaded.
  property bool airplayDiscoveryActive: false
  property string airplayScanState: "idle"
  property string airplayError: ""
  property string airplayStopResultState: "idle"
  property int airplayScanAnimationStep: 0
  property var airplayPeers: []
  property var selectedAirplayNames: []
  property bool stopAirplayAfterStart: false
  property bool scanAirplayAfterStop: false
  readonly property bool airplayActive: isAirplaySink(sink)
  readonly property string airplayScanDots: ["", ".", "..", "..."][airplayScanAnimationStep]
  readonly property string wirelessRowTitle: {
    if (airplayStopProc.running || airplayScanState === "stopping") return "Returning to local audio"
    if (airplayStartProc.running || airplayScanState === "scanning")
      return "Looking for speakers" + airplayScanDots
    if (airplayScanState === "error") return airplayError || "AirPlay discovery failed"
    if (airplayScanState === "empty") return "No AirPlay speakers found"
    if (displayWirelessAudioSinks.length > 0) {
      if (airplayActive) return airplayRoomLabel(sink)
      return displayWirelessAudioSinks.length + " speaker"
        + (displayWirelessAudioSinks.length === 1 ? "" : "s") + " found"
    }
    return "AirPlay is off"
  }
  readonly property string wirelessRowDetail: {
    if (airplayStopProc.running || airplayScanState === "stopping")
      return "Closing AirPlay discovery"
    if (airplayStartProc.running || airplayScanState === "scanning")
      return "AirPlay · up to 8 seconds"
    if (airplayScanState === "error") return "Reopen this panel to try again"
    if (airplayScanState === "empty") return "Check the speaker, then reopen this panel"
    if (displayWirelessAudioSinks.length > 0)
      return airplayActive ? airplayDeviceDetail(sink) : "Choose an AirPlay output"
    return "Reopen this panel to scan again"
  }
  readonly property color wirelessRowTint: airplayScanState === "error"
    ? (bar ? bar.urgent : Color.urgent) : foreground
  onRawAudioSinksChanged: if (rawAudioSinks.length > 0) cachedAudioSinks = rawAudioSinks
  onRawWirelessAudioSinksChanged: {
    if (rawWirelessAudioSinks.length > 0) {
      if (airplayDiscoveryActive) {
        airplayScanState = "results"
        airplayScanTimeout.stop()
      }
    }
  }
  onRawAudioSourcesChanged: if (rawAudioSources.length > 0) cachedAudioSources = rawAudioSources

  property bool outputExpanded: true
  property bool inputExpanded: true
  property bool sourcesExpanded: false
  property bool wirelessExpanded: false
  readonly property bool hasOutput: !!(volumeSink && volumeSink.audio)
  readonly property bool hasInput: !!(source && source.audio)
  readonly property bool anyAudible: (hasOutput && !outputMuted) || (hasInput && !inputMuted)

  onOpenedChanged: {
    if (opened) {
      outputExpanded = true
      wirelessExpanded = airplayActive
      inputExpanded = true
      sourcesExpanded = false
      stopAirplayAfterStart = false
      refreshDisplayAudioModels()
      editingSettings = false
      Qt.callLater(resetScroll)
      if (airplayStopProc.running) scanAirplayAfterStop = true
      else if (!airplayDiscoveryActive && !airplayStartProc.running)
        Qt.callLater(startAirplayScan)
    } else {
      scanAirplayAfterStop = false
      clearDisplayAudioModels()
      if (airplayStartProc.running) stopAirplayAfterStart = true
      else if (airplayDiscoveryActive && !airplayActive && !airplayStopProc.running && !airplaySelectProc.running)
        stopAirplayDiscovery(null, true)
    }
  }

  // Defer model replacement until PipeWire finishes its node-removal signal.
  onAudioSinksChanged: scheduleDisplayAudioModelRefresh()
  onWirelessAudioSinksChanged: scheduleDisplayAudioModelRefresh()
  onAirplayPeersChanged: scheduleDisplayAudioModelRefresh()
  onAudioSourcesChanged: scheduleDisplayAudioModelRefresh()
  onAudioStreamsChanged: scheduleDisplayAudioModelRefresh()

  function listSnapshot(list) {
    return Model.listSnapshot(list)
  }

  function refreshDisplayAudioModels() {
    if (!opened) return
    displayAudioSinks = listSnapshot(audioSinks)
    displayWirelessAudioSinks = Model.uniqueAirplaySinks(listSnapshot(rawWirelessAudioSinks), airplayPeers, sink)
    displayAudioSources = listSnapshot(audioSources)
    displayAudioStreams = listSnapshot(audioStreams)
  }

  function scheduleDisplayAudioModelRefresh() {
    if (!opened) return
    audioModelRefreshTimer.restart()
  }

  function clearDisplayAudioModels() {
    audioModelRefreshTimer.stop()
    displayAudioSinks = []
    displayWirelessAudioSinks = []
    displayAudioSources = []
    displayAudioStreams = []
  }

  function resetScroll() { panelScroll.contentY = 0; settingsPane.resetScroll() }
  function keepFocusVisible(item) {
    if (!item || !opened) return
    // Fixed header/footer controls must never move the scrolling device list.
    var ancestor = item
    while (ancestor && ancestor !== panelScroll.contentItem) ancestor = ancestor.parent
    if (!ancestor) return
    var pt = item.mapToItem(panelScroll.contentItem, 0, 0)
    var maxY = Math.max(0, panelScroll.contentHeight - panelScroll.height)
    if (pt.y < panelScroll.contentY) panelScroll.contentY = Math.max(0, pt.y - Style.space(8))
    else if (pt.y + item.height > panelScroll.contentY + panelScroll.height)
      panelScroll.contentY = Math.min(maxY, pt.y + item.height - panelScroll.height + Style.space(8))
  }

  function outputIcon(volume) {
    if (airplayActive) return "󱝉" // nf-md-cast_audio_variant (U+F1749).
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    if (!sink || !sink.audio) return ""
    if (outputMuted) return ""
    if (isHeadphones(sink)) return "󰋋"
    var v = volume === undefined ? outputVolume : volume
    if (v >= 0.67) return ""
    if (v >= 0.34) return ""
    if (v > 0) return ""
    return ""
  }

  function localPathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    return decodeURIComponent(value)
  }

  function parseAirplayPayload(raw) {
    try {
      var payload = JSON.parse(String(raw || "").trim())
      return payload && typeof payload === "object" ? payload : ({})
    } catch (error) {
      return ({ ok: false, error: "AirPlay helper returned invalid data" })
    }
  }

  function preferredLocalSink() {
    if (sink && !isAirplaySink(sink)) return sink
    for (var i = 0; i < audioSinks.length; i++) {
      var candidate = audioSinks[i]
      if (candidate && !isAirplaySink(candidate)) return candidate
    }
    return null
  }

  function startAirplayScan() {
    if (airplayStartProc.running || airplayStopProc.running) return
    var restore = preferredLocalSink()
    stopAirplayAfterStart = false
    airplayError = ""
    airplayScanState = "scanning"
    airplayScanAnimationStep = 0
    airplayStartProc.command = [
      "python3", airplayBridge, "start",
      "--restore-id", restore && restore.id !== undefined ? String(restore.id) : "",
      "--restore-name", restore && restore.name ? String(restore.name) : ""
    ]
    airplayStartProc.running = true
  }

  function applyAirplayStart(raw) {
    var payload = parseAirplayPayload(raw)
    if (payload.ok !== true) {
      stopAirplayAfterStart = false
      airplayDiscoveryActive = false
      airplayScanState = "error"
      airplayError = String(payload.error || "Could not start AirPlay discovery")
      return
    }

    airplayDiscoveryActive = true
    airplayPeers = payload.peers && payload.peers.slice ? payload.peers.slice() : []
    selectedAirplayNames = payload.selectedNames || []
    if (stopAirplayAfterStart || !opened) {
      stopAirplayAfterStart = false
      stopAirplayDiscovery(null, true)
      return
    }
    stopAirplayAfterStart = false
    if (rawWirelessAudioSinks.length > 0) {
      airplayScanState = "results"
    } else {
      airplayScanState = "scanning"
      airplayScanTimeout.restart()
    }
  }

  function stopAirplayDiscovery(restoreNode, skipRestore, resultState) {
    if (airplayStopProc.running) return
    airplayScanTimeout.stop()
    airplayStopResultState = resultState || "idle"
    airplayScanState = "stopping"
    var command = ["python3", airplayBridge, "stop"]
    if (restoreNode && restoreNode.id !== undefined && restoreNode.name) {
      command.push("--restore-id", String(restoreNode.id))
      command.push("--restore-name", String(restoreNode.name))
    }
    if (skipRestore === true) command.push("--skip-restore")
    airplayStopProc.command = command
    airplayStopProc.running = true
  }

  function applyAirplayStop(raw) {
    var payload = parseAirplayPayload(raw)
    if (payload.ok !== true) {
      airplayScanState = "error"
      airplayError = String(payload.error || "Could not stop AirPlay")
      return
    }
    airplayDiscoveryActive = false
    airplayError = ""
    airplayScanState = airplayStopResultState
    airplayPeers = []
    selectedAirplayNames = []
    scheduleDisplayAudioModelRefresh()
    if (scanAirplayAfterStop && opened) {
      scanAirplayAfterStop = false
      Qt.callLater(startAirplayScan)
    } else {
      scanAirplayAfterStop = false
    }
  }

  function applyAirplayStatus(raw) {
    var payload = parseAirplayPayload(raw)
    if (payload.ok !== true) return
    airplayDiscoveryActive = payload.active === true
    if (!airplayDiscoveryActive) return
    airplayPeers = payload.peers && payload.peers.slice ? payload.peers.slice() : []
    selectedAirplayNames = payload.selectedNames || []
    airplayScanState = rawWirelessAudioSinks.length > 0 ? "results" : "scanning"
    if (airplayScanState === "scanning") airplayScanTimeout.restart()
  }

  function airplaySelected(node) {
    if (!node || !airplayActive) return false
    return sink.name === node.name || (String(sink.name).indexOf("foamy_airplay_group_") === 0
      && selectedAirplayNames.indexOf(String(node.name)) >= 0)
  }

  function selectAirplaySink(node) {
    if (!node || !airplayDiscoveryActive || airplaySelectProc.running || airplayStopProc.running) return
    // An external output switch can leave the saved group membership stale.
    var names = !airplayActive ? [] : String(sink.name).indexOf("foamy_airplay_group_") === 0
      ? selectedAirplayNames.slice() : [String(sink.name)]
    var index = names.indexOf(String(node.name))
    if (index < 0) names.push(String(node.name))
    else names.splice(index, 1)
    airplayError = ""
    airplaySelectProc.command = ["python3", airplayBridge, "select"].concat(names)
    airplaySelectProc.running = true
  }

  function selectLocalSink(node) {
    if (!node || airplaySelectProc.running || airplayStopProc.running) return
    if (!airplayDiscoveryActive) {
      setDefaultSink(node)
      return
    }
    // Disconnect receivers without unloading discovery while the list is in use.
    airplayError = ""
    airplaySelectProc.command = ["python3", airplayBridge, "select", "--local-name", String(node.name)]
    airplaySelectProc.running = true
  }

  function inputIcon() {
    if (!source || !source.audio) return "󰍭"
    return inputMuted ? "󰍭" : "󰍬"
  }

  // Playful mood-name for a given output volume. Mirrors the brightness
  // panel's brightnessName ladder; bands are wide enough that small
  // tweaks don't rename the room you're in.
  function outputVolumeName(volume, muted) {
    return Model.outputVolumeName(volume, muted)
  }

  function setOutputVolume(v) {
    if (!volumeSink || !volumeSink.audio) return outputVolume
    var volume = Math.max(0, Math.min(1, v))
    volumeSink.audio.volume = volume
    return volume
  }

  function showVolumeOsd(volume) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: outputIcon(volume),
      value: Math.round(volume * 100)
    }))
  }

  function setInputVolume(v) {
    if (!source || !source.audio) return
    source.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleOutputMute() {
    if (volumeSink && volumeSink.audio) volumeSink.audio.muted = !volumeSink.audio.muted
  }

  function toggleInputMute() {
    if (source && source.audio) source.audio.muted = !source.audio.muted
  }

  // Only existing channels participate, so a missing microphone cannot block unmuting.
  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput) volumeSink.audio.muted = mute
    if (hasInput) source.audio.muted = mute
  }

  function setDefaultSink(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name) {
      Quickshell.execDetached([
        "omarchy-audio-output-set-default",
        String(node.id),
        String(node.name)
      ])
    }
  }

  function setDefaultSource(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name) {
      Quickshell.execDetached([
        "omarchy-audio-input-set-default",
        String(node.id),
        String(node.name)
      ])
    }
  }

  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailabilityLoaded) return true
    var name = String(node.name)
    return sinkAvailability[name] !== false
  }

  function updateSinkAvailability(raw) {
    sinkAvailability = Model.parseSinkAvailability(raw)
    sinkAvailabilityLoaded = true
  }

  function friendlyDeviceLabel(text) {
    return Model.friendlyDeviceLabel(text)
  }

  function nodeLabel(node) {
    return Model.nodeLabel(node)
  }

  function isAirplaySink(node) {
    return Model.isAirplaySink(node)
  }

  function airplayPeerForSink(node) {
    return Model.airplayPeerForSink(node, airplayPeers)
  }

  function airplayRoomLabel(node) {
    if (node && String(node.name).indexOf("foamy_airplay_group_") === 0) return tr("AirPlay group")
    var peer = airplayPeerForSink(node)
    return peer && peer.name ? String(peer.name) : Model.airplayRoomLabel(node)
  }

  function airplayDeviceDetail(node) {
    var peer = airplayPeerForSink(node)
    return peer ? Model.airplayPeerDetail(peer) : Model.airplayDeviceDetail(node)
  }

  function nodeProps(node) {
    return Model.nodeProps(node)
  }

  function isHeadphones(node) {
    return Model.isHeadphones(node, bluetoothDevices)
  }

  function sinkGlyph(node) {
    return Model.sinkGlyph(node, bluetoothDevices)
  }

  function sourceGlyph(node) {
    return Model.sourceGlyph(node)
  }

  function friendlyStreamLabel(label) {
    return Model.friendlyStreamLabel(label)
  }

  function streamLabelKey(label) {
    return Model.streamLabelKey(label)
  }

  function streamLabelIsGeneric(label) {
    return Model.streamLabelIsGeneric(label)
  }

  function rawStreamLabel(node) {
    return Model.rawStreamLabel(node)
  }

  function mprisPlayerLabel(player) {
    return Model.mprisPlayerLabel(player)
  }

  function mprisPlayerIsProxy(player) {
    return Model.mprisPlayerIsProxy(player)
  }

  function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
    return Model.streamRepresentsMprisPlayer(streamLabel, playerLabel)
  }

  function mprisLabelsFor(predicate) {
    return Model.mprisLabelsFor(mprisPlayers, predicate)
  }

  function matchingMprisStreamLabel(label) {
    return Model.matchingMprisStreamLabel(label, mprisPlayers)
  }

  function unmatchedMprisStreamLabel(label) {
    // Spotify exposes its PipeWire stream as "audio-src". For generic stream
    // names, use the one MPRIS player not already represented by another audio
    // stream (e.g. Chromium, or ALSA apps like cliamp).
    return Model.unmatchedMprisStreamLabel(label, mprisPlayers, displayAudioStreams)
  }

  function streamLabel(node) {
    return Model.streamLabel(node, mprisPlayers, displayAudioStreams)
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
      var source = entry ? appIconSource(entry.icon) : ""
      if (source) return source
    }
    return ""
  }

  function streamRepresentsPlayer(node, player) {
    return Model.streamRepresentsPlayer(node, player, mprisPlayers, displayAudioStreams)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: airplayStatusProc.running = true

  PwObjectTracker { objects: root.candidateSinks }
  PwObjectTracker { objects: root.candidateSources }
  PwObjectTracker { objects: root.audioStreams }

  MicrophonePeak {
    id: inputPeakMonitor
    source: root.source
    // Waking an idle microphone can steal the clock driving network playback.
    passive: root.airplayActive
    enabled: root.opened && !!root.source
  }

  Process {
    id: sinkAvailabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateSinkAvailability(text)
    }
  }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeSinkName = String(text).trim()
    }
  }

  Process {
    id: airplayStartProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAirplayStart(text)
    }
  }

  Process {
    id: airplaySelectProc
    stdout: StdioCollector { id: airplaySelectOutput; waitForEnd: true }
    onExited: function(code) {
      var payload = root.parseAirplayPayload(airplaySelectOutput.text)
      if (code !== 0 || payload.ok !== true) {
        root.airplayError = String(payload.error || "Could not change output.")
        root.airplayScanState = "error"
        return
      }
      root.selectedAirplayNames = payload.selectedNames || []
      root.airplayScanState = "results"
      if (!root.selectedAirplayNames.length && !root.opened)
        root.stopAirplayDiscovery(null, true)
    }
  }

  Process {
    id: airplayStopProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAirplayStop(text)
    }
  }

  Process {
    id: airplayStatusProc
    command: ["python3", root.airplayBridge, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAirplayStatus(text)
    }
  }

  Timer {
    interval: 350
    running: airplayStartProc.running || root.airplayScanState === "scanning"
    repeat: true
    onTriggered: root.airplayScanAnimationStep = (root.airplayScanAnimationStep + 1) % 4
  }

  Timer {
    id: airplayScanTimeout
    interval: 8000
    repeat: false
    onTriggered: {
      if (root.airplayScanState === "scanning" && root.rawWirelessAudioSinks.length === 0)
        root.stopAirplayDiscovery(null, true, "empty")
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
  }

  // Runs whether or not the panel is open: the bar shows the output
  // volume too, so an unresolved sink there would read and change the virtual
  // tuning sink instead of the speakers.
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveVolumeSink()
  }

  Timer {
    id: audioModelRefreshTimer
    interval: 75
    repeat: false
    onTriggered: root.refreshDisplayAudioModels()
  }


  readonly property color secondary: Qt.tint(Color.popups.background, Qt.alpha(Color.popups.text, 0.76))
  readonly property bool vertical: bar && (bar.position === "left" || bar.position === "right")
  readonly property string language: Preferences.language(preference("language"), Qt.locale().name)
  property bool editingSettings: false
  property string settingsError: ""
  property var pendingPreferences: ({})
  function preference(key) { return Preferences.value(settings, key) }
  function tr(label) { return Preferences.text(label, language) }
  function savePreference(key, value) {
    if (!Preferences.valid(key, value)) { settingsError = tr("Invalid setting."); return }
    settingsError = ""
    // Serialize updates and coalesce repeated edits to the same preference.
    pendingPreferences[key] = value
    flushPreferences()
  }
  function flushPreferences() {
    if (preferencesSave.running) return
    var keys = Object.keys(pendingPreferences)
    if (!keys.length) return
    var key = keys[0], value = pendingPreferences[key]
    delete pendingPreferences[key]
    preferencesSave.command = Preferences.saveCommand(key, value)
    preferencesSave.running = true
  }
  function openSettings() { open(); editingSettings = true; resetScroll(); Qt.callLater(function() { settingsPane.focusBack() }) }
  function closeSettings() { editingSettings = false; resetScroll(); Qt.callLater(function() { settingsButton.forceActiveFocus() }) }
  function volumeNodeFor(node) { return node && sink && node.id === sink.id ? volumeSink : node }
  function rowIcon(node) { return isAirplaySink(node) ? "cast-audio-variant" : isHeadphones(node) ? "headphones" : "speaker" }
  function muteNode(node) { if (node && node.audio) node.audio.muted = !node.audio.muted }
  Process {
    id: preferencesSave
    stdout: StdioCollector { id: preferenceOutput; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0 || preferenceOutput.text.trim() !== "ok") root.settingsError = root.tr("Could not save settings.")
      Qt.callLater(root.flushPreferences)
    }
  }
  IpcHandler {
    target: "foamy.audio"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void { root.openSettings() }
    function status(): string {
      return JSON.stringify({open:root.opened,settings:root.editingSettings,language:root.language,
        output:root.sink ? root.nodeLabel(root.sink) : "",input:root.source ? root.nodeLabel(root.source) : "",
        volume:root.outputVolume,inputVolume:root.inputVolume,outputMuted:root.outputMuted,inputMuted:root.inputMuted,
        outputs:root.displayAudioSinks.length,inputs:root.displayAudioSources.length,apps:root.displayAudioStreams.length,
        wireless:root.airplayScanState,wirelessError:root.airplayError,wirelessOutputs:root.displayWirelessAudioSinks.map(function(n){return {name:n.name,label:root.airplayRoomLabel(n),selected:root.airplaySelected(n)}}),settingsError:root.settingsError,
        microphonePeak:inputPeakMonitor.peak,microphoneMeterError:inputPeakMonitor.error})
    }
  }

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
    tooltipText: root.tr("Audio") + (root.sink ? " · " + root.nodeLabel(root.sink) : "")
    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(1)
      OpticalGlyph { width:Style.bar.iconCanvas;height:Style.bar.iconCanvas;text:root.outputIcon();fontFamily:button.fontFamily;fontSize:button.fontSize;color:button.foreground }
      Text { visible:root.preference("showPercentage")&&!root.vertical;text:Math.round(root.outputVolume*100)+"%";textFormat:Text.PlainText;color:button.foreground;font.family:button.fontFamily;font.pixelSize:button.fontSize;anchors.verticalCenter:parent.verticalCenter }
    }
    onPressed: function(b) { if (b === Qt.RightButton) root.toggleAllMuted(); else root.toggle() }
  }

  AudioPopup {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    padding: 0
    // Keep the initial focus on the panel so header actions retain their ghost appearance.
    focusTarget: root.editingSettings ? settingsPane.backTarget : panelScroll
    borderSpec: Border.flat(Qt.alpha(Color.popups.text, 0.15), 1)
    contentWidth: fittedContentWidth(Style.space(420))
    contentHeight: fittedContentHeight(root.editingSettings ? settingsPane.implicitHeight : panelHeader.implicitHeight + panelColumn.implicitHeight + panelFooter.height, Style.space(740))
    Item {
      id: panelContent
      anchors.fill: parent
      Keys.onEscapePressed: root.editingSettings ? root.closeSettings() : root.close()
      Keys.onPressed: function(event) {
        if (root.editingSettings) return
        if (event.key === Qt.Key_S) { root.openSettings(); event.accepted = true }
        else if (event.key === Qt.Key_O) { root.outputExpanded = !root.outputExpanded; event.accepted = true }
        else if (event.key === Qt.Key_I) { root.inputExpanded = !root.inputExpanded; event.accepted = true }
        else if (event.key === Qt.Key_A) { root.sourcesExpanded = !root.sourcesExpanded; event.accepted = true }
        else if (event.key === Qt.Key_W) { root.wirelessExpanded = !root.wirelessExpanded; event.accepted = true }
        else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up || event.key === Qt.Key_J || event.key === Qt.Key_K) {
          var current = panelScroll.Window.window ? panelScroll.Window.window.activeFocusItem : null
          if (current) { current.nextItemInFocusChain(event.key === Qt.Key_Down || event.key === Qt.Key_J).forceActiveFocus(); event.accepted = true }
        }
      }
      Connections {
        target: panelScroll.Window.window
        function onActiveFocusItemChanged() { root.keepFocusVisible(target.activeFocusItem) }
      }
      SettingsPane {
        id: settingsPane
        visible: root.editingSettings
        anchors.fill: parent
        settings: root.settings
        language: root.language
        saving: preferencesSave.running
        error: root.settingsError
        onSave: function(key, value) { root.savePreference(key, value) }
        onBack: root.closeSettings()
        onClearError: root.settingsError = ""
      }
      Item {
        id: panelHeader
        visible: !root.editingSettings
        width: parent.width
        implicitHeight: heroContent.implicitHeight + Style.space(34)
        Canvas {
          id: headerWash
          readonly property real cornerRadius: Math.max(0, Math.min(width / 2, height, panel.cornerRadius - Border.top(panel.borderSpec)))
          onCornerRadiusChanged: requestPaint()
          anchors.fill: parent
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            // Clip the wash to the same rounded top corners as the popup.
            var radius=cornerRadius
            ctx.beginPath();ctx.moveTo(radius,0);ctx.lineTo(width-radius,0)
            ctx.arcTo(width,0,width,radius,radius);ctx.lineTo(width,height)
            ctx.lineTo(0,height);ctx.lineTo(0,radius);ctx.arcTo(0,0,radius,0,radius)
            ctx.closePath();ctx.clip()
            var wash = ctx.createLinearGradient(0,0,width*0.5,height)
            wash.addColorStop(0,Qt.tint(Color.popups.background,Qt.alpha(Color.accent,0.08)))
            wash.addColorStop(1,Color.popups.background)
            ctx.fillStyle=wash;ctx.fillRect(0,0,width,height)
            var glow=ctx.createRadialGradient(width*0.9,0,0,width*0.9,0,width*0.85)
            glow.addColorStop(0,Qt.alpha(Color.accent,0.17));glow.addColorStop(1,"transparent")
            ctx.fillStyle=glow;ctx.fillRect(0,0,width,height)
          }
          Connections { target:Color;function onAccentChanged(){headerWash.requestPaint()} function onShellValuesChanged(){headerWash.requestPaint()} function onBackgroundChanged(){headerWash.requestPaint()} }
        }
        Column {
          id: heroContent
          anchors.centerIn: parent
          width: parent.width-Style.space(40)
          spacing: Style.space(14)
          Row {
            width: parent.width
            spacing: Style.space(4)
            Label { text:root.tr("Audio");width:parent.width-Style.space(108);height:Style.space(32);verticalAlignment:Text.AlignVCenter;font.pixelSize:Style.space(14) }
            AudioAction { id:outputMuteButton;width:Style.space(32);height:width;iconSize:Style.space(16);iconName:root.outputMuted?"volume-x":"volume-2";foreground:root.secondary;enabled:root.hasOutput;tooltipText:root.tr(root.outputMuted?"Unmute output":"Mute output");onClicked:root.toggleOutputMute() }
            AudioAction { width:Style.space(32);height:width;iconSize:Style.space(16);iconName:root.inputMuted?"mic-off":"mic";foreground:root.inputMuted?Color.urgent:root.secondary;enabled:root.hasInput;tooltipText:root.tr(root.inputMuted?"Unmute microphone":"Mute microphone");onClicked:root.toggleInputMute() }
            AudioAction { id:settingsButton;width:Style.space(32);height:width;iconSize:Style.space(16);foreground:root.secondary;tooltipText:root.tr("Settings");onClicked:root.openSettings() }
          }
          Row {
            width: parent.width
            spacing: Style.space(16)
            Row {
              id: heroVolume
              spacing: Style.space(4)
              opacity: root.outputMuted ? 0.5 : 1
              Label { text:root.hasOutput?String(Math.round(outputSlider.value*100)):"—";font.pixelSize:Style.space(54);font.letterSpacing:-2 }
              Label { text:root.hasOutput?"%":"";font.pixelSize:Style.space(19);anchors.bottom:parent.bottom;anchors.bottomMargin:Style.space(7) }
            }
            Label { width:Math.max(0,parent.width-heroVolume.width-parent.spacing);text:root.sink?(root.airplayActive?root.airplayRoomLabel(root.sink):root.nodeLabel(root.sink)):root.tr("No output devices");font.pixelSize:Style.space(15);wrapMode:Text.WordWrap;anchors.verticalCenter:parent.verticalCenter }
          }
          AudioSlider {
            id: outputSlider
            width: parent.width
            label: root.tr("Volume")
            enabled: root.hasOutput
            value: root.outputVolume
            stepSize: root.volumeStep
            onMoved: root.setOutputVolume(value)
            onMuteRequested: root.toggleOutputMute()
          }
        }
      }
      Flickable {
        id: panelScroll
        visible: !root.editingSettings
        anchors.top: panelHeader.bottom
        anchors.bottom: panelFooter.top
        width: parent.width
        clip: true
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight-height))
        onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight-height))
        Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
        Column {
          id: panelColumn
          width: parent.width-Style.space(40)
          bottomPadding: Style.space(14)
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(14)
          Column {
            width: parent.width
            spacing: Style.space(2)
            SectionHeader { width:parent.width;label:root.tr("Output");expanded:root.outputExpanded;onToggled:root.outputExpanded=!root.outputExpanded }
            Label { visible:root.outputExpanded&&!root.displayAudioSinks.length;width:parent.width;text:root.tr("No output devices");color:root.secondary }
            Repeater {
              model: root.outputExpanded ? root.displayAudioSinks : []
              AudioRow {
                required property var modelData
                width: parent.width
                node: modelData
                volumeNode: root.volumeNodeFor(node)
                label: root.nodeLabel(node)
                iconName: root.rowIcon(node)
                selected: !!(root.sink&&node&&root.sink.id===node.id)
                step: root.volumeStep
                secondary: root.secondary
                onActivated: root.selectLocalSink(node)
                onMuteRequested: root.muteNode(volumeNode)
              }
            }
          }
          Column {
            width: parent.width
            spacing: Style.space(2)
            SectionHeader { width:parent.width;label:root.tr("Input");expanded:root.inputExpanded;onToggled:root.inputExpanded=!root.inputExpanded }
            Label { visible:root.inputExpanded&&!root.displayAudioSources.length;width:parent.width;text:root.tr("No input devices");color:root.secondary }
            Label { visible:root.inputExpanded&&inputPeakMonitor.error!=="";width:parent.width;text:root.tr(inputPeakMonitor.error);color:Color.urgent;wrapMode:Text.WordWrap }
            Repeater {
              model: root.inputExpanded ? root.displayAudioSources : []
              AudioRow {
                required property var modelData
                width: parent.width
                node: modelData
                label: root.nodeLabel(node)
                iconName: "mic"
                showLevelMeter: true
                levelDescription: root.tr("Microphone level")
                level: root.inputMuted ? 0 : inputPeakMonitor.peak
                selected: !!(root.source&&node&&root.source.id===node.id)
                step: root.volumeStep
                secondary: root.secondary
                onActivated: root.setDefaultSource(node)
                onMuteRequested: root.muteNode(node)
              }
            }

          }
          Column {
            width: parent.width
            spacing: Style.space(2)
            SectionHeader { width:parent.width;label:root.tr("Apps");expanded:root.sourcesExpanded;onToggled:root.sourcesExpanded=!root.sourcesExpanded }
            Label { visible:root.sourcesExpanded&&!root.displayAudioStreams.length;width:parent.width;text:root.tr("No apps playing audio");color:root.secondary }
            Repeater {
              model: root.sourcesExpanded ? root.displayAudioStreams : []
              AudioRow {
                required property var modelData
                width: parent.width
                node: modelData
                label: root.streamLabel(node)
                iconSource: root.streamIconSource(node)
                iconName: node&&node.audio&&node.audio.muted?"volume-x":"app-window"
                stream: true
                step: root.volumeStep
                secondary: root.secondary
                onActivated: root.muteNode(node)
                onMuteRequested: root.muteNode(node)
              }
            }
          }
          Column {
            width: parent.width
            spacing: Style.space(2)
            SectionHeader { width:parent.width;label:root.tr("Wireless");expanded:root.wirelessExpanded;onToggled:root.wirelessExpanded=!root.wirelessExpanded }
            Label {
              visible: root.wirelessExpanded&&(root.airplayScanState==="error"||!root.displayWirelessAudioSinks.length)
              width: parent.width
              text: root.airplayScanState==="error"?root.tr(root.airplayError||"AirPlay discovery failed"):root.airplayScanState==="scanning"?root.tr("Looking for speakers")+root.airplayScanDots:root.airplayScanState==="stopping"?root.tr("Returning to local audio"):root.tr("No AirPlay speakers found")
              color: root.airplayScanState==="error"?Color.urgent:root.secondary
              wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.wirelessExpanded ? root.displayWirelessAudioSinks : []
              AudioRow {
                required property var modelData
                width: parent.width
                node: modelData
                label: root.airplayRoomLabel(node)
                iconName: "cast-audio-variant"
                multiSelect: true
                selected: root.airplaySelected(node)
                volumeVisible: selected
                enabled: !airplaySelectProc.running && !airplayStopProc.running
                step: root.volumeStep
                secondary: root.secondary
                onActivated: root.selectAirplaySink(node)
                onMuteRequested: root.muteNode(node)
              }
            }
          }
        }
      }
      Item {
        id: panelFooter
        visible: !root.editingSettings
        anchors.bottom: parent.bottom
        width: parent.width
        height: Style.space(56)
        Rectangle {
          x: Style.space(20)
          width: parent.width-Style.space(40)
          height: 1
          color: Qt.alpha(Color.popups.text, 0.15)
        }
        AudioAction {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(20)
          anchors.verticalCenter: parent.verticalCenter
          iconName: root.anyAudible ? "volume-x" : "volume-2"
          label: root.tr(root.anyAudible ? "Mute all" : "Unmute all")
          foreground: root.secondary
          enabled: root.hasOutput || root.hasInput
          onClicked: root.toggleAllMuted()
        }
      }
    }
  }
  component Label: Text {
    textFormat: Text.PlainText
    color: Color.popups.text
    font.family: "sans-serif"
    font.pixelSize: Style.space(13)
  }
}
