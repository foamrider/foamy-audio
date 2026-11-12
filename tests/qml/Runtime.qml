import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Audio
import "plugin/kit"

// Foamy Audio under a real host shell, offscreen: three bar instances (as on
// three monitors), one leader, the host's platform helpers, the lazy popup
// body, the single keyboard cursor, settings
// saving through the bar, translations and RTL mirroring.
ShellRoot {
  id: shell
  readonly property string host: Quickshell.env("FOAMY_HOST")
  readonly property string lang: Quickshell.env("FOAMY_LANG") || "en"
  property int checks: 0
  property int failures: 0

  function check(ok, label) {
    checks++
    if (!ok) {
      failures++
      console.log("FOAMY FAIL " + host + "/" + lang + " " + label)
    }
  }
  function eq(actual, expected, label) {
    check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
  }

  FloatingWindow {
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    ScreenSim {
      id: sim
    }
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
          settings: ({
              id: "foamy.audio",
              showPercentage: true,
              extra: "kept"
            })
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

  Component.onCompleted: Qt.callLater(stepOne)

  // The host's textKey call via the kit.
  FoamyCursor {
    id: keys
  }
  function key(view, text) {
    keys.emitTextKey(view, text)
  }
  function findNamed(item, name) {
    if (!item)
      return null
    if (item.objectName === name)
      return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var hit = findNamed(kids[i], name)
      if (hit)
        return hit
    }
    return null
  }
  function findType(item, test) {
    if (!item)
      return null
    if (test(item))
      return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var hit = findType(kids[i], test)
      if (hit)
        return hit
    }
    return null
  }

  function leaders() {
    var count = 0
    for (var i = 0; i < 3; i++)
      if (panels.itemAt(i).statusObject().leader)
        count++
    return count
  }

  function stepOne() {
    eq(leaders(), 1, "one leader across three bar instances")
    eq(Audio.AudioService.members, 3, "three members")
    eq(Audio.AudioService.platform, AudioNodes, "the host's AudioNodes")
    eq(Audio.AudioService.untyped, UntypedInput, "the host's UntypedInput")
    check(Audio.AudioService.isShellLevelMeter({
      name: "quickshell-peak-monitor"
    }), "shell level meter filtered")
    eq(Audio.AudioService.platformHides({
      name: "alsa_output.speakers"
    }), false, "no platform hints here")
    var first = panels.itemAt(0)
    // No PipeWire offscreen: the bar shows the no-output glyph, never an empty button.
    eq(first.barGlyph(), "\ueee8", "bar glyph without an output")
    eq(first.popup.bodyItem, null, "popup body is lazy")
    // The bar tooltip carries the output's own name: bounded like FoamyText.tooltip.
    var button = findType(first, function (item) {
      return item.tooltipText !== undefined && item.labelVisible !== undefined
    })
    check(button !== null, "bar button found")
    if (button)
      eq(button.tooltipText, first.barTooltip(""), "bar tooltip without an output")
    var long = first.barTooltip("Speaker ".repeat(40) + "\n1\n2\n3\n4\n5\n6\n7")
    var lines = long.split("\n")
    eq(lines.length, 6, "a long output name keeps at most six tooltip lines")
    check(lines.every(function (line) {
      return line.length <= 100
    }), "tooltip lines stay within 100 characters: " + JSON.stringify(long))
    check(long.indexOf("…") > 0, "a cut tooltip shows the ellipsis")
    eq(Audio.AudioService.demanded, false, "no demand while closed")
    first.open()
    wait.waitFor(function () {
      return first.popup.bodyItem !== null
    }, 10000, stepTwo, "body built on open")
  }

  function stepTwo() {
    var first = panels.itemAt(0)
    var view = first.popup.bodyItem
    check(view !== null, "body built on open")
    eq(Audio.AudioService.demanded, true, "open popup raises demand")
    // Discovery ran the native helper (FoamyNative) and got a JSON reply
    // (no PipeWire is reachable here, so usually an error from pactl).
    eq(Audio.AudioService.airplayHelperUnavailable, false, "AirPlay helper available")
    check(Audio.AudioService.airplayError !== "AirPlay helper returned invalid data", "AirPlay helper replied in JSON: " + Audio.AudioService.airplayScanState + " " + Audio.AudioService.airplayError)
    console.log("FOAMY AIRPLAY " + Audio.AudioService.airplayScanState + " " + Audio.AudioService.airplayError)
    if (!view) {
      shell.finish()
      return
    }
    eq(view.cursorKey, "", "no cursor highlight on open")
    view.moveRequested(0, 1)
    eq(view.cursorKey, "volume", "first move lands on the volume slider")
    // Sliders (DESIGN.md "Sliders"): the cursor rings the header slider's
    // thumb; no filled row behind it.
    var slider = findType(view, function (item) {
      return item.hasCursor !== undefined && item.mini !== undefined
    })
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
    check(view.wheel._following === view.sectionItem("wireless"), "unfolding scrolls Wireless into view")
    eq(view.LayoutMirroring.enabled, shell.lang === "ar", "popup body mirrors in RTL only")
    var titles = {
      en: "Audio",
      no: "Lyd",
      ar: "Audio"
    }
    if (shell.lang !== "ar")
      eq(first.popup.bodyItem.children.length > 0 ? FoamyI18n.t("Audio") : "", titles[shell.lang], "title translated")
    eq(FoamyI18n.tn("Allow the network of %1 speakers", 1), shell.lang === "no" ? "Tillat nettverket til 1 høyttaler" : "Allow the network of 1 speaker", "plural")
    shell.key(view, "s")
    eq(first.editingSettings, true, "s opens Settings")
    eq(view.blocked, true, "settings page owns the keys")
    // Firewall actions are form buttons: Verify, Apply (primary), Remove (destructive).
    var verify = findNamed(view, "audioFirewallVerify")
    var apply = findNamed(view, "audioFirewallApply")
    var remove = findNamed(view, "audioFirewallRemove")
    check(verify !== null && apply !== null && remove !== null, "firewall buttons exist")
    if (verify && apply && remove) {
      eq(verify.kind + "/" + apply.kind + "/" + remove.kind, "secondary/primary/destructive", "firewall button kinds")
      eq(verify.focusable && apply.focusable && remove.focusable, true, "firewall buttons join the Tab chain")
      eq(apply.enabled, false, "Apply waits for speakers")
    }
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
    eq(Audio.AudioService.demanded, false, "closing releases demand")
    wait.waitFor(function () {
      return !Audio.AudioService.wanted
    }, 10000, stepThree, "discovery released after the delay")
  }

  function stepThree() {
    eq(panels.itemAt(0).displayAudioSinks.length, 0, "rows dropped while closed")
    wait.waitFor(function () {
      return !Audio.AudioService.airplayScanning
    }, 30000, airplaySettled, "discovery settles")
  }

  // tests/runtime.py puts fakes in front of pactl and the other audio tools:
  // the discovery the popup started must have failed on the fake (the last
  // line of its stderr), never on a real pactl reaching a server.
  function airplaySettled() {
    eq(Audio.AudioService.airplayScanState, "error", "discovery failed without an audio server")
    eq(Audio.AudioService.airplayError, Quickshell.env("FOAMY_FAKE_ERROR"), "discovery ran the fake pactl")
    shell.floodMeter()
  }

  // The microphone meter's helper runs as long as the popup is open: a helper
  // (or pw-record) that floods stderr must not grow the shell. Its Process
  // gets a 32 MiB stderr writer; only the first stderrLimit characters stay.
  property var meter: null
  property var meterProc: null
  function floodMeter() {
    meter = findType(panels.itemAt(0), function (item) {
      return item.stderrLimit !== undefined && item.fallbackPeak !== undefined
    })
    check(meter !== null, "microphone meter found")
    var kids = meter ? meter.resources : []
    for (var i = 0; i < kids.length; i++)
      if (kids[i] && kids[i].command !== undefined && kids[i].running !== undefined)
        meterProc = kids[i]
    check(meterProc !== null, "meter process found")
    if (!meter || !meterProc) {
      shell.finish()
      return
    }
    eq(meterProc.running, false, "meter idle while closed")
    meterProc.command = ["bash", "-c", "head -c 33554432 /dev/zero | tr '\\0' x >&2; exit 3"]
    meterProc.running = true
    wait.waitFor(function () {
      return !shell.meterProc.running
    }, 30000, flooded, "flooding helper drained and exited")
  }
  function flooded() {
    eq(shell.meter.stderrHead.length, shell.meter.stderrLimit, "meter keeps only the head of a stderr flood")
    eq(shell.meter.stderrHead.replace(/x/g, ""), "", "kept head is the helper's output")
    eq(shell.meter.failure, "", "a closed meter reports no failure")
    shell.finish()
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
    onTriggered: {
      console.log("FOAMY DONE")
      Qt.quit()
    }
  }
}
