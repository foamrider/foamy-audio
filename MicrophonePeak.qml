import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire

Item {
  id: root
  property var source: null
  property bool passive: false
  enabled: false
  readonly property var channels: source && source.audio ? source.audio.channels : []
  readonly property bool stereo: channels.length === 2
    && channels[0] === PwAudioChannel.FrontLeft && channels[1] === PwAudioChannel.FrontRight
  readonly property string channelMap: {
    if (!source || !source.ready || !source.properties) return ""
    var raw = String(source.properties["audio.position"] || "").replace(/[\[\]"]/g, "").trim()
    return raw ? raw.split(/[\s,]+/).join(",") : stereo ? "FL,FR" : ""
  }
  readonly property bool useHelper: passive || !stereo
  readonly property string requestedKey: enabled && source && channels.length > 0 && useHelper && channelMap
    ? source.name + "|" + channelMap + "|" + passive : ""
  readonly property string error: failure || (enabled && channels.length > 0 && useHelper && !channelMap
    ? "Microphone level unavailable" : "")
  readonly property real peak: !enabled || !source || !source.audio || source.audio.muted ? 0
    : !useHelper ? nativeMeter.peak
    : Math.min(1, fallbackPeak / Math.max(0.0001, source.audio.volume))
  property real fallbackPeak: 0
  property string failure: ""
  property string launchedKey: ""
  property string failedKey: ""
  property bool stopping: false

  onRequestedKeyChanged: {
    fallbackPeak = 0
    failure = ""
    failedKey = ""
    reconcile.restart()
  }

  function syncCapture() {
    if (capture.running) {
      if (launchedKey !== requestedKey) {
        stopping = true
        capture.running = false
      }
      return
    }
    if (!requestedKey || requestedKey === failedKey) return
    launchedKey = requestedKey
    stopping = false
    var command = ["python3", decodeURIComponent(Qt.resolvedUrl("microphone_peak.py").toString().replace(/^file:\/\//, "")), source.name, channelMap]
    if (passive) command.push("--passive")
    capture.command = command
    capture.running = true
  }

  Timer { id: reconcile; interval: 0; onTriggered: root.syncCapture() }
  PwNodePeakMonitor {
    id: nativeMeter
    node: root.source
    enabled: root.enabled && !root.useHelper
  }
  Process {
    id: capture
    stdout: SplitParser {
      onRead: function(data) {
        var level = Number(data)
        if (root.launchedKey === root.requestedKey && data.trim() && isFinite(level) && level >= 0 && level <= 1)
          root.fallbackPeak = level
      }
    }
    stderr: StdioCollector { id: captureError }
    onExited: {
      root.fallbackPeak = 0
      if (!root.stopping && root.launchedKey === root.requestedKey && root.requestedKey) {
        // Retry on reopen or device change, never spin on a missing or failed helper.
        root.failedKey = root.launchedKey
        root.failure = "Microphone level unavailable"
        console.warn("Foamy Audio microphone meter: " + captureError.text.trim())
      }
      reconcile.restart()
    }
  }
}
