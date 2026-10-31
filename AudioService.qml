pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "kit"
import "Model.js" as Model

// Audio state shared by every Foamy Audio bar instance (4.5 draws one bar per
// monitor): the PipeWire device model, the volume sink behind any DSP sink,
// 4.5 platform node hiding and untyped inputs, and the AirPlay discovery
// session. Panels join FoamyMember scope "audio"; an open popup raises demand,
// which is what starts AirPlay discovery and the availability refresh.
Singleton {
  id: root

  readonly property bool demanded: FoamyShared.demandCount("audio") > 0
  readonly property int members: FoamyShared.memberCount("audio")
  // Demand held through a short release delay, so moving the popup between
  // monitors or panels does not stop and restart discovery.
  property bool wanted: false

  // 4.5 Commons singletons, resolved at runtime so 4.0 still loads the plugin.
  property var platform: null   // AudioNodes: platformHides(), isShellLevelMeter()
  property var untyped: null    // UntypedInput: wpctl volume/mute for a virtual default input

  readonly property string airplayBridge: localPath(Qt.resolvedUrl("airplay_bridge.py"))

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var bluetoothDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []

  readonly property var nodeNames: {
    var names = []
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && nodes[i].name) names.push(String(nodes[i].name))
    return names
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    return decodeURIComponent(value)
  }

  // Nodes of a platform's audio processing (4.5 /usr/share/omarchy-platform/audio.json)
  // are neither devices nor apps. Most machines, and every 4.0 host, have none.
  function platformHides(node) {
    return !!node && !!platform && platform.platformHides(node.name, nodeNames)
  }

  function isShellLevelMeter(node) {
    var name = node ? node.name : ""
    return platform ? platform.isShellLevelMeter(name) : Model.isShellLevelMeter(name)
  }

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && !platformHides(n)) list.push(n)
    }
    return list
  }

  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream) continue
      if (!Model.isAudioSource(n) && !Model.isUntypedSource(n, sourceAvailability)) continue
      if (isShellLevelMeter(n) || platformHides(n)) continue
      list.push(n)
    }
    return list
  }

  readonly property var candidateStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !Model.isPlaybackStream(n)) continue
      // Tuning and AirPlay group outputs route audio internally; they are not apps.
      var name = String(n.name || "")
      if (name.indexOf("omarchy_speaker_tuning") === 0
          || name.indexOf("output.foamy_airplay_group_") === 0 || platformHides(n)) continue
      list.push(n)
    }
    return list
  }

  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false
  property var sourceAvailability: ({})

  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailabilityLoaded) return true
    return sinkAvailability[String(node.name)] !== false
  }

  property var cachedAudioSinks: []
  property var cachedAudioSources: []

  readonly property var rawAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++) {
      var candidate = candidateSinks[i]
      if (sinkAvailable(candidate) && !Model.isAirplaySink(candidate)) list.push(candidate)
    }
    if (sink && !Model.isAirplaySink(sink) && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var rawWirelessAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++) {
      var candidate = candidateSinks[i]
      if (sinkAvailable(candidate) && Model.isAirplaySink(candidate)) list.push(candidate)
    }
    if (sink && Model.isAirplaySink(sink) && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var rawAudioSources: {
    var list = candidateSources.slice()
    if (source && list.indexOf(source) < 0) list.unshift(source)
    return list
  }

  readonly property var audioSinks: rawAudioSinks.length > 0 ? rawAudioSinks : cachedAudioSinks
  readonly property var audioSources: rawAudioSources.length > 0 ? rawAudioSources : cachedAudioSources
  readonly property var audioStreams: {
    var list = []
    for (var i = 0; i < candidateStreams.length; i++)
      if (candidateStreams[i].audio) list.push(candidateStreams[i])
    return list
  }

  onRawAudioSinksChanged: if (rawAudioSinks.length > 0) cachedAudioSinks = rawAudioSinks
  onRawAudioSourcesChanged: if (rawAudioSources.length > 0) cachedAudioSources = rawAudioSources

  // Bind what the bar needs (the output, the default input) always; the
  // rest only while a popup shows it.
  PwObjectTracker { objects: root.candidateSinks }
  PwObjectTracker { objects: root.demanded ? root.candidateSources : (root.source ? [root.source] : []) }
  PwObjectTracker { objects: root.demanded ? root.audioStreams : [] }

  // ---- Volume sink -------------------------------------------------------
  // A DSP sink (a speaker tuning, EasyEffects) can be the default output
  // without being where loudness lives. omarchy-audio-output-sink resolves the
  // default through it to the physical sink, the same definition the volume
  // keys use. Event-driven like the 4.5 first-party panel: the default
  // changing, nodes or links changing (500 ms debounce) and EasyEffects'
  // configured output changing; never polled.
  property string volumeSinkName: ""
  property bool volumeSinkStale: false
  // Bumped by every resolve, so an older script answer cannot overwrite a
  // newer one (the hardware fast path's included).
  property int volumeSinkGeneration: 0
  property int volumeSinkRequest: -1

  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio) return n
    }
    return sink
  }

  function resolveVolumeSink() {
    volumeSinkGeneration++
    // A hardware output is its own volume sink; only a DSP sink needs the script.
    if (sink && String(sink.name).indexOf("alsa_output.") === 0) {
      volumeSinkName = String(sink.name)
      return
    }
    if (volumeSinkProc.running) {
      volumeSinkStale = true
      return
    }
    volumeSinkRequest = volumeSinkGeneration
    volumeSinkProc.running = true
  }

  onSinkChanged: {
    resolveVolumeSink()
    if (airplayDiscoveryActive && sink && !Model.isAirplaySink(sink)
        && !airplayStartProc.running && !airplayStopProc.running && !airplaySelectProc.running) {
      if (wanted) selectLocalSink(sink)
      else stopAirplayDiscovery(sink)
    }
  }
  onNodesChanged: volumeSinkResolveTimer.restart()

  Connections {
    target: Pipewire.linkGroups
    ignoreUnknownSignals: true
    function onValuesChanged() { volumeSinkResolveTimer.restart() }
  }

  FileView {
    // An idle EasyEffects resolves through its configured output, which
    // changes without touching the PipeWire graph.
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/easyeffects/db/easyeffectsrc"
    watchChanges: true
    printErrors: false
    onFileChanged: volumeSinkResolveTimer.restart()
  }

  Timer {
    id: volumeSinkResolveTimer
    interval: 500
    onTriggered: root.resolveVolumeSink()
  }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.volumeSinkRequest === root.volumeSinkGeneration) root.volumeSinkName = String(text).trim()
    }
    onExited: {
      if (!root.volumeSinkStale) return
      root.volumeSinkStale = false
      // Deferred: the process still reports running while it signals exit.
      Qt.callLater(root.resolveVolumeSink)
    }
  }

  // ---- Levels --------------------------------------------------------------
  // A virtual default input has no PwNode.audio; on 4.5 its volume and mute
  // go through UntypedInput (wpctl), once for the whole shell.
  readonly property bool inputViaWpctl: !!untyped && untyped.active === true
  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  readonly property real inputVolume: inputViaWpctl ? untyped.volume : (source && source.audio ? source.audio.volume : 0)
  readonly property bool inputMuted: inputViaWpctl ? untyped.muted : (source && source.audio ? source.audio.muted : false)
  readonly property bool hasOutput: !!(volumeSink && volumeSink.audio)
  readonly property bool hasInput: !!(source && source.audio) || (inputViaWpctl && untyped.known === true)
  // Only existing channels vote, so a missing microphone cannot block unmuting.
  readonly property bool anyAudible: (hasOutput && !outputMuted) || (hasInput && !inputMuted)
  readonly property bool airplayActive: Model.isAirplaySink(sink)

  function untypedNode(node) { return inputViaWpctl && !!node && !!source && node.id === source.id }
  function nodeHasVolume(node) { return !!(node && node.audio) || (untypedNode(node) && untyped.known === true) }
  function nodeVolume(node) { return untypedNode(node) ? untyped.volume : node && node.audio ? node.audio.volume : 0 }
  function nodeMuted(node) { return untypedNode(node) ? untyped.muted : node && node.audio ? node.audio.muted : false }
  function setNodeVolume(node, value, maximum) {
    var volume = Math.max(0, Math.min(maximum || 1, value))
    if (untypedNode(node)) untyped.setVolume(volume)
    else if (node && node.audio) node.audio.volume = volume
  }
  function toggleNodeMute(node) {
    if (untypedNode(node)) untyped.setMuted(!untyped.muted)
    else if (node && node.audio) node.audio.muted = !node.audio.muted
  }

  function setOutputVolume(value) { if (hasOutput) setNodeVolume(volumeSink, value, 1) }
  function toggleOutputMute() { if (hasOutput) toggleNodeMute(volumeSink) }
  function toggleInputMute() { if (hasInput) toggleNodeMute(source) }
  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput && outputMuted !== mute) toggleNodeMute(volumeSink)
    if (hasInput && inputMuted !== mute) toggleNodeMute(source)
  }

  function setDefaultSink(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
  }

  function setDefaultSource(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-input-set-default", String(node.id), String(node.name)])
  }

  // ---- Availability (only while a popup is open) -------------------------
  Timer {
    interval: 5000
    running: root.demanded
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
      // `sources` exists on 4.5 only, together with UntypedInput.
      if (root.untyped && !sourceAvailabilityProc.running) sourceAvailabilityProc.running = true
    }
  }

  Process {
    id: sinkAvailabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.sinkAvailability = Model.parseSinkAvailability(text)
        root.sinkAvailabilityLoaded = true
      }
    }
  }

  Process {
    id: sourceAvailabilityProc
    command: ["omarchy-audio-sink-availability", "sources"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sourceAvailability = Model.parseSinkAvailability(text)
    }
  }

  // ---- AirPlay discovery -------------------------------------------------
  // Scoped to popup use: demand starts it, releasing demand stops an unused
  // scan, and only a module this plugin loaded is ever unloaded.
  property bool airplayDiscoveryActive: false
  property string airplayScanState: "idle"
  property string airplayError: ""
  property string airplayStopResultState: "idle"
  property var airplayPeers: []
  property var selectedAirplayNames: []
  property bool stopAirplayAfterStart: false
  property bool scanAirplayAfterStop: false
  readonly property bool airplayBusy: airplayStartProc.running || airplayStopProc.running || airplaySelectProc.running
  readonly property bool airplaySelecting: airplaySelectProc.running || airplayStopProc.running
  readonly property bool airplayScanning: airplayStartProc.running || airplayScanState === "scanning"
  readonly property bool airplayStopping: airplayStopProc.running || airplayScanState === "stopping"

  onDemandedChanged: {
    if (demanded) {
      releaseTimer.stop()
      if (!wanted) {
        wanted = true
        acquire()
      }
    } else {
      releaseTimer.restart()
    }
  }

  Timer {
    id: releaseTimer
    interval: 400
    onTriggered: {
      if (root.demanded) return
      root.wanted = false
      root.release()
    }
  }

  function acquire() {
    stopAirplayAfterStart = false
    if (airplayStopProc.running) scanAirplayAfterStop = true
    // Re-check a session we think is running: another shell generation may have ended it.
    else if (airplayDiscoveryActive) { if (!airplayStatusProc.running) airplayStatusProc.running = true }
    else if (!airplayStartProc.running) Qt.callLater(startAirplayScan)
  }

  function release() {
    scanAirplayAfterStop = false
    if (airplayStartProc.running) stopAirplayAfterStart = true
    else if (airplayDiscoveryActive && !airplayActive && !airplayStopProc.running && !airplaySelectProc.running)
      stopAirplayDiscovery(null, true)
  }

  // The last panel is going away (plugin disabled or removed, shell exit):
  // do not leave mDNS browsing loaded. A selected AirPlay output stays.
  function teardown() {
    stopAirplayAfterStart = airplayStartProc.running
    if (airplayDiscoveryActive && !airplayActive && !airplayStopProc.running) {
      Quickshell.execDetached(["python3", airplayBridge, "stop", "--skip-restore"])
      airplayDiscoveryActive = false
      airplayScanState = "idle"
    }
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
    if (sink && !Model.isAirplaySink(sink)) return sink
    for (var i = 0; i < audioSinks.length; i++)
      if (audioSinks[i] && !Model.isAirplaySink(audioSinks[i])) return audioSinks[i]
    return null
  }

  function startAirplayScan() {
    if (airplayStartProc.running || airplayStopProc.running || !wanted) return
    var restore = preferredLocalSink()
    stopAirplayAfterStart = false
    airplayError = ""
    airplayScanState = "scanning"
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
    if (stopAirplayAfterStart || !wanted) {
      stopAirplayAfterStart = false
      if (!airplayActive) stopAirplayDiscovery(null, true)
      return
    }
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
    if (restoreNode && restoreNode.id !== undefined && restoreNode.name)
      command.push("--restore-id", String(restoreNode.id), "--restore-name", String(restoreNode.name))
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
    var again = scanAirplayAfterStop && wanted
    scanAirplayAfterStop = false
    if (again) Qt.callLater(startAirplayScan)
  }

  function applyAirplayStatus(raw) {
    var payload = parseAirplayPayload(raw)
    if (payload.ok === true) {
      airplayDiscoveryActive = payload.active === true
      if (airplayDiscoveryActive) {
        airplayPeers = payload.peers && payload.peers.slice ? payload.peers.slice() : []
        selectedAirplayNames = payload.selectedNames || []
        airplayScanState = rawWirelessAudioSinks.length > 0 ? "results" : "scanning"
        if (airplayScanState === "scanning") airplayScanTimeout.restart()
      }
    }
    if (!airplayDiscoveryActive && wanted && !airplayStartProc.running) startAirplayScan()
  }

  function airplaySelected(node) {
    if (!node || !airplayActive) return false
    return sink.name === node.name || (String(sink.name).indexOf("foamy_airplay_group_") === 0
      && selectedAirplayNames.indexOf(String(node.name)) >= 0)
  }

  function selectAirplaySink(node) {
    if (!node || !airplayDiscoveryActive || airplaySelecting) return
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
    if (!node || airplaySelecting) return
    if (!airplayDiscoveryActive) {
      setDefaultSink(node)
      return
    }
    // Disconnect receivers without unloading discovery while the list is in use.
    airplayError = ""
    airplaySelectProc.command = ["python3", airplayBridge, "select", "--local-name", String(node.name)]
    airplaySelectProc.running = true
  }

  onRawWirelessAudioSinksChanged: {
    if (rawWirelessAudioSinks.length > 0 && airplayDiscoveryActive && airplayScanState === "scanning") {
      airplayScanState = "results"
      airplayScanTimeout.stop()
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
      if (!root.selectedAirplayNames.length && !root.wanted) root.stopAirplayDiscovery(null, true)
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
    id: airplayScanTimeout
    interval: 8000
    onTriggered: {
      if (root.airplayScanState === "scanning" && root.rawWirelessAudioSinks.length === 0)
        root.stopAirplayDiscovery(null, true, "empty")
    }
  }

  Component.onCompleted: {
    try {
      var probe = Qt.createQmlObject('import QtQuick; import qs.Commons; QtObject {'
        + ' function nodes() { return typeof AudioNodes === "undefined" ? null : AudioNodes }'
        + ' function untyped() { return typeof UntypedInput === "undefined" ? null : UntypedInput } }',
        root, "FoamyAudioPlatformProbe")
      var nodesApi = probe.nodes()
      var untypedApi = probe.untyped()
      probe.destroy()
      if (nodesApi && typeof nodesApi.platformHides === "function") platform = nodesApi
      if (untypedApi && typeof untypedApi.setVolume === "function") untyped = untypedApi
    } catch (error) {
      // 4.0: no platform hints, no untyped inputs; the built-in filters apply.
    }
    resolveVolumeSink()
    airplayStatusProc.running = true
  }
  Component.onDestruction: teardown()
}
