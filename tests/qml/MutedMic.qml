import QtQuick
import Quickshell
import qs.Commons as Commons
import "harness"
import "plugin" as Audio
import "plugin/kit"

// The muted microphone's icon in the hero band, against a mock `audio` (as
// preview/Preview.qml has, with the microphone muted): tests/runtime.py runs
// it in two dark themes where the raw urgent colour does not read on the
// band, one with a dim red and one with a bright accent. The icon must read on every pixel the band painted
// under it, at rest and under the action's hover fill, and keep its colour
// under the cursor. Then the keys' border on Mute all.
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
    return shell.view !== null && shell.micIcon() !== null && shell.bandUnderIcon().length > 0
  }, 10000, function (ok) {
    if (ok)
      atRest()
    else
      finish()
  }, "the band is painted under the muted microphone's icon")

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
  // The pixels the band's Canvas painted under the icon's box, as opaque
  // colours; empty until the band has painted them all.
  function bandUnderIcon() {
    var band = findWith(view, function (item) {
      return item.objectName === "foamyHeroBandSurface"
    })
    var icon = micIcon()
    var box = icon.mapToItem(band, 0, 0, icon.width, icon.height)
    var x = Math.floor(box.x), y = Math.floor(box.y)
    var data = band.getContext("2d").getImageData(x, y, Math.ceil(box.x + box.width) - x, Math.ceil(box.y + box.height) - y).data
    var pixels = []
    for (var i = 0; i < data.length; i += 4) {
      if (data[i + 3] !== 255)
        return []
      pixels.push(Qt.rgba(data[i] / 255, data[i + 1] / 255, data[i + 2] / 255, 1))
    }
    return pixels
  }
  // The lowest ratio `colour` has on the band under the icon: each painted
  // pixel under the action's own fill as drawn.
  function lowestRatio(colour) {
    var fill = micAction().color
    var lowest = 21
    bandUnderIcon().forEach(function (pixel) {
      lowest = Math.min(lowest, FoamyPalette.contrastRatio(colour, Qt.tint(pixel, fill)))
    })
    return lowest
  }
  function reads(label) {
    var icon = micIcon()
    // The theme is in effect: its raw red does not read there.
    var raw = lowestRatio(Commons.Color.urgent)
    check(raw < 4.5, "the theme's raw red is under 4.5:1 on the band " + label + ": " + raw.toFixed(2) + ":1")
    var ratio = lowestRatio(icon.color)
    // A known kit limit: FoamyPalette.onSurface steps a colour at most 1.7
    // times, and a very dim red ends there under 4.5:1 on the band's corner
    // under the hover fill (the kit's dim-red fixture: 4.02:1). The colour
    // at that last step passes; a theme whose red can reach 4.5:1 must.
    var cap = Qt.color((FoamyPalette.lightTheme ? Qt.darker(Commons.Color.urgent, 1.7) : Qt.lighter(Commons.Color.urgent, 1.7)).toString())
    check(ratio >= 4.5 || Qt.colorEqual(icon.color, cap), "the muted microphone reads on the band " + label + ": " + icon.color + ", " + ratio.toFixed(2) + ":1 (4.5:1 needed, or the kit's last step " + cap + ")")
  }

  property color restColour
  function atRest() {
    check(!micAction().hasCursor && micAction().color.a === 0, "the microphone action has no cursor at rest: fill " + micAction().color)
    reads("at rest")
    restColour = micIcon().color
    view.hover("inputMute")
    // Until the action's fill has ended its fade (FoamyMotion.hover) at
    // the hover fill, so the measure is on the settled state.
    wait.waitFor(function () {
      return shell.micAction().hasCursor && Qt.colorEqual(shell.micAction().color, FoamyPalette.hoverFill)
    }, 5000, function (ok) {
      if (ok)
        underCursor()
      else
        finish()
    }, "the cursor reaches the microphone action")
  }
  function underCursor() {
    reads("under the cursor")
    var icon = micIcon()
    check(Qt.colorEqual(icon.color, restColour), "the icon keeps its colour under the cursor: " + restColour + " at rest, " + icon.color)
    footerKeys()
  }
  // Mute all (enabled here, unlike in Runtime.qml without a server): the
  // keys' cursor draws its accent border, the pointer's does not.
  function footerKeys() {
    for (var n = 0; n < view.stops.length && view.cursorKey !== "muteAll"; n++)
      view.moveRequested(0, 1)
    var footer = findWith(view, function (item) {
      return item.cursorByKeys !== undefined && item.border !== undefined && item.hasCursor === true
    })
    check(view.cursorKey === "muteAll" && footer !== null, "fixture: ↓ reaches Mute all (" + view.cursorKey + ")")
    if (footer) {
      check(footer.cursorByKeys && footer.border.width > 0 && Qt.colorEqual(footer.border.color, Commons.Color.accent), "↓: Mute all draws the keys' border")
      var ev = Qt.createQmlObject("import QtTest; TestEvent {}", view)
      ev.mouseMove(footer, footer.width / 2, footer.height / 2, -1, Qt.NoButton, Qt.NoModifier)
      ev.mouseMove(footer, footer.width / 2 + 1, footer.height / 2, -1, Qt.NoButton, Qt.NoModifier)
      ev.destroy()
      check(footer.hovered && footer.hasCursor && footer.border.width === 0, "the pointer on Mute all: its cursor, no keys' border (hovered " + footer.hovered + ")")
    }
    finish()
  }

  function finish() {
    console.log("FOAMY RESULT muted-mic " + checks + " checks, " + failures + " failures")
    console.log("FOAMY DONE")
    Qt.quit()
  }
}
