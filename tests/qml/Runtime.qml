import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Audio
import "plugin/kit"

// Foamy Audio under a real host shell, offscreen: three bar instances (as on
// three monitors), one leader, the 4.5 platform helpers resolved at runtime
// (null on 4.0), the lazy popup body, the single keyboard cursor, settings
// saving through the bar, translations and RTL mirroring.
ShellRoot {
  id: shell
  readonly property string host: Quickshell.env("FOAMY_HOST")
  readonly property string lang: Quickshell.env("FOAMY_LANG") || "en"
  readonly property bool v45: host === "4.5"
  property int checks: 0
  property int failures: 0

  function check(ok, label) {
    checks++
    if (!ok) { failures++; console.log("FOAMY FAIL " + host + "/" + lang + " " + label) }
  }
  function eq(actual, expected, label) {
    check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
  }

  FloatingWindow {
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    ScreenSim { id: sim }
    Row {
      y: 4
      x: 1200
      spacing: 40
      Repeater {
        id: panels
        model: 3
        Audio.Panel {
          bar: mockBar
          moduleName: "foamy.audio"
          settings: ({ id: "foamy.audio", showPercentage: true, extra: "kept" })
        }
      }
    }
  }

  MockBar { id: mockBar; moduleName: "foamy.audio" }

  Component.onCompleted: Qt.callLater(stepOne)

  // The host's textKey arity (4.0 text, 4.5 text + modifiers) via the kit.
  FoamyCursor { id: keys }
  function key(view, text) { keys.emitTextKey(view, text) }
  function findNamed(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = findNamed(kids[i], name); if (hit) return hit }
    return null
  }
  function findType(item, test) {
    if (!item) return null
    if (test(item)) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = findType(kids[i], test); if (hit) return hit }
    return null
  }

  function leaders() {
    var count = 0
    for (var i = 0; i < 3; i++) if (panels.itemAt(i).statusObject().leader) count++
    return count
  }

  function stepOne() {
    eq(leaders(), 1, "one leader across three bar instances")
    eq(Audio.AudioService.members, 3, "three members")
    eq(!!Audio.AudioService.platform, v45, "AudioNodes resolved only on 4.5")
    eq(!!Audio.AudioService.untyped, v45, "UntypedInput resolved only on 4.5")
    check(Audio.AudioService.isShellLevelMeter({ name: "quickshell-peak-monitor" }), "shell level meter filtered")
    eq(Audio.AudioService.platformHides({ name: "alsa_output.speakers" }), false, "no platform hints here")
    var first = panels.itemAt(0)
    // No PipeWire offscreen: the bar shows the no-output glyph, never an empty button.
    eq(first.barGlyph(), "\ueee8", "bar glyph without an output")
    eq(first.popup.bodyItem, null, "popup body is lazy")
    eq(Audio.AudioService.demanded, false, "no demand while closed")
    first.open()
    stepTwo.start()
  }

  Timer {
    id: stepTwo
    interval: 600
    onTriggered: {
      var first = panels.itemAt(0)
      var view = first.popup.bodyItem
      check(view !== null, "body built on open")
      eq(Audio.AudioService.demanded, true, "open popup raises demand")
      if (!view) { shell.finish(); return }
      eq(view.cursorKey, "", "no cursor highlight on open")
      view.moveRequested(0, 1)
      eq(view.cursorKey, "volume", "first move lands on the volume slider")
      // Sliders (DESIGN.md "Sliders"): the cursor rings the header slider's
      // thumb; no filled row behind it.
      var slider = findType(view, function(item) { return item.hasCursor !== undefined && item.mini !== undefined })
      check(slider !== null, "header slider found")
      if (slider) {
        eq(slider.hasCursor, true, "the cursor on the volume rings the slider thumb")
        var hero = slider.parent ? slider.parent.parent : null
        eq(hero && hero.color !== undefined, false, "no filled row behind the header slider")
      }
      view.moveRequested(0, -1)
      eq(view.cursorKey, "settings", "up from the slider reaches the header")
      view.moveRequested(-1, 0)
      eq(view.cursorKey, FoamyI18n.rightToLeft ? "settings" : "inputMute", "h moves along the header in reading order")
      shell.key(view, "o")
      eq(view.outputExpanded, false, "o folds Output")
      shell.key(view, "w")
      eq(view.wirelessExpanded, true, "w unfolds Wireless")
      eq(view.LayoutMirroring.enabled, shell.lang === "ar", "popup body mirrors in RTL only")
      var titles = { en: "Audio", no: "Lyd", ar: "Audio" }
      if (shell.lang !== "ar") eq(first.popup.bodyItem.children.length > 0 ? FoamyI18n.t("Audio") : "", titles[shell.lang], "title translated")
      eq(FoamyI18n.tn("Allow the network of %1 speakers", 1), shell.lang === "no" ? "Tillat nettverket til 1 høyttaler" : "Allow the network of 1 speaker", "plural")
      shell.key(view, "s")
      eq(first.editingSettings, true, "s opens Settings")
      eq(view.blocked, true, "settings page owns the keys")
      first.save("showPercentage", false)
      eq(mockBar.saved.length, 1, "setting saved inline")
      if (mockBar.saved.length === 1) {
        eq(mockBar.saved[0].id, "foamy.audio", "saved to the widget's own entry")
        eq(mockBar.saved[0].settings.showPercentage, false, "saved value")
        eq(mockBar.saved[0].settings.extra, "kept", "unknown keys kept")
      }
      first.closeSettings()
      eq(view.blocked, false, "back from Settings")
      first.close()
      stepThree.start()
    }
  }

  Timer {
    id: stepThree
    interval: 900
    onTriggered: {
      eq(Audio.AudioService.demanded, false, "closing releases demand")
      eq(Audio.AudioService.wanted, false, "discovery released after the delay")
      eq(panels.itemAt(0).displayAudioSinks.length, 0, "rows dropped while closed")
      shell.finish()
    }
  }

  property int holdMs: Number(Quickshell.env("FOAMY_HOLD_MS") || 0)
  function finish() {
    console.log("FOAMY RESULT " + host + "/" + lang + " " + checks + " checks, " + failures + " failures")
    console.log("FOAMY READY")
    finishTimer.start()
  }
  Timer {
    id: finishTimer
    interval: shell.holdMs
    onTriggered: { console.log("FOAMY DONE"); Qt.quit() }
  }
}
