import QtQuick
import Quickshell
import qs.Commons as Commons
import "harness"
import "plugin" as Audio
import "plugin/kit"

// The muted microphone's icon in the hero band, against a mock `audio` (as
// preview/Preview.qml has, with the microphone muted): tests/runtime.py runs
// it in a dark theme with a dim red, where the raw urgent colour does not
// read on the band. The icon must read on the strongest fill at its place
// (the wash's end colour, the glow at its peak and the action's hover fill),
// and keep its colour under the cursor.
ShellRoot {
  id: shell
  property int checks: 0
  property int failures: 0

  function check(ok, label) {
    checks++
    if (!ok) {
      failures++
      console.log("FOAMY FAIL muted-mic " + label)
    }
  }
  function findWith(item, test) {
    if (!item)
      return null
    if (test(item))
      return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var hit = findWith(kids[i], test)
      if (hit)
        return hit
    }
    return null
  }

  FloatingWindow {
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    ScreenSim {
      id: sim
    }
    Item {
      id: anchor
      x: 1200
      y: 4
      width: 40
      height: 30
    }
    FoamyPopup {
      id: popup
      anchorItem: anchor
      bar: mockBar
      open: true
      body: Component {
        Audio.AudioView {
          audio: mock
        }
      }
    }
  }

  MockBar {
    id: mockBar
    moduleName: "foamy.audio"
  }
  FoamyWait {
    id: wait
  }

  QtObject {
    id: mock
    property bool opened: true
    readonly property bool editingSettings: false
    readonly property real volumeStep: 0.05
    readonly property var displayAudioSinks: []
    readonly property var displayAudioSources: []
    readonly property var displayAudioStreams: []
    readonly property var displayWirelessAudioSinks: []
    readonly property string outputLabel: "Speakers"
    readonly property bool hasOutput: true
    readonly property bool hasInput: true
    readonly property real outputVolume: 0.46
    readonly property bool outputMuted: false
    readonly property bool inputMuted: true
    readonly property bool anyAudible: true
    readonly property bool airplayActive: false
    readonly property string airplayScanState: "idle"
    readonly property string airplayError: ""
    readonly property bool airplayScanning: false
    readonly property bool airplayStopping: false
    readonly property bool airplaySelecting: false
    readonly property int airplayPeerCount: 0
    readonly property real inputPeak: 0
    readonly property string inputMeterError: ""
    readonly property bool showPercentage: true
    readonly property bool saving: false
    readonly property string settingsError: ""
    readonly property bool settingsRetryable: false
    readonly property bool firewallBusy: false
    readonly property string firewallState: ""
    readonly property string firewallMessage: ""
    function nodeFor(row) {
      return null
    }
    function rowLabel(kind, n) {
      return ""
    }
    function rowIcon(kind, n) {
      return "speaker"
    }
    function streamIconSource(n) {
      return ""
    }
    function isSelected(kind, n) {
      return false
    }
    function volumeTarget(kind, n) {
      return n
    }
    function nodeHasVolume(n) {
      return false
    }
    function nodeVolume(n) {
      return 0
    }
    function nodeMuted(n) {
      return false
    }
    function setNodeVolume(n, v, m) {
    }
    function toggleNodeMute(n) {
    }
    function activate(kind, n) {
    }
    function setOutputVolume(v) {
    }
    function toggleOutputMute() {
    }
    function toggleInputMute() {
    }
    function toggleAllMuted() {
    }
    function openSettings() {
    }
    function closeSettings() {
    }
    function close() {
    }
    function switchPanel(d) {
    }
    function save(k, v) {
    }
    function retrySave() {
    }
    function firewallAction(a) {
    }
  }

  readonly property var view: popup.bodyItem

  Component.onCompleted: wait.waitFor(function () {
    return shell.view !== null && shell.micIcon() !== null
  }, 10000, function (ok) {
    if (ok)
      atRest()
    else
      finish()
  }, "the popup shows the muted microphone's icon")

  function micIcon() {
    return findWith(view, function (item) {
      return item.name === "mic-off" && item.color !== undefined
    })
  }
  function micAction() {
    return findWith(view, function (item) {
      return item.iconName === "mic-off" && item.hasCursor !== undefined
    })
  }
  // The band's fill under the icon as the band paints it (FoamyHeroBand's
  // Canvas): the diagonal wash from `fill` to `fillEnd` at the icon's
  // centre, the radial glow from the trailing top corner at the icon's
  // point nearest that corner (its strongest there), then the action's own
  // fill as drawn.
  function fillUnderIcon() {
    var band = findWith(view, function (item) {
      return item.objectName === "foamyHeroBandSurface"
    })
    var icon = micIcon()
    var box = icon.mapToItem(band, 0, 0, icon.width, icon.height)
    var w = band.width, h = band.height
    var cx = box.x + box.width / 2, cy = box.y + box.height / 2
    var t = Math.max(0, Math.min(1, (cx * 0.6 * w + cy * h) / (0.36 * w * w + h * h)))
    var wash = Qt.rgba(band.fill.r + (band.fillEnd.r - band.fill.r) * t, band.fill.g + (band.fillEnd.g - band.fill.g) * t, band.fill.b + (band.fillEnd.b - band.fill.b) * t, 1)
    var gx = w * 0.9
    var nx = Math.max(box.x, Math.min(gx, box.x + box.width))
    var d = Math.sqrt((nx - gx) * (nx - gx) + box.y * box.y)
    var glow = Qt.alpha(band.glow, band.glow.a * Math.max(0, 1 - d / (Math.max(w, h) * 0.75)))
    console.log("muted-mic: wash at " + t.toFixed(2) + ", glow " + glow.a.toFixed(3) + " of " + band.glow.a.toFixed(3))
    return Qt.tint(Qt.tint(wash, glow), micAction().color)
  }

  property color restColour
  function atRest() {
    restColour = micIcon().color
    view.hover("inputMute")
    wait.waitFor(function () {
      return shell.micAction().hasCursor && shell.micAction().color.a > 0
    }, 5000, function (ok) {
      if (ok)
        underCursor()
      else
        finish()
    }, "the cursor reaches the microphone action")
  }
  function underCursor() {
    var icon = micIcon()
    var fill = fillUnderIcon()
    // The theme is in effect: its raw red does not read there.
    var raw = FoamyPalette.contrastRatio(Commons.Color.urgent, fill)
    check(raw < 4.5, "the theme's raw red is under 4.5:1 on the band: " + raw.toFixed(2) + ":1")
    var ratio = FoamyPalette.contrastRatio(icon.color, fill)
    check(ratio >= 4.5, "the muted microphone reads on the band under the cursor: " + icon.color + ", " + ratio.toFixed(2) + ":1")
    check(Qt.colorEqual(icon.color, restColour), "the icon keeps its colour under the cursor: " + restColour + " at rest, " + icon.color)
    finish()
  }

  function finish() {
    console.log("FOAMY RESULT muted-mic " + checks + " checks, " + failures + " failures")
    console.log("FOAMY DONE")
    Qt.quit()
  }
}
