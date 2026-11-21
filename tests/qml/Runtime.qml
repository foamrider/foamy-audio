import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Audio
import "plugin/kit"

// Foamy Audio under a real host shell, offscreen: three bar instances (as on
// three monitors), one leader, the host's platform helpers, the bar button
// and its one setting, the lazy popup body in its empty state (no audio
// server), the single keyboard cursor, unfolding a section below the fold,
// settings saving through the bar, translations and RTL mirroring.
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
    // The host object the service drives a virtual default input through.
    var untyped = Audio.AudioService.untyped
    check(typeof untyped.setVolume === "function" && typeof untyped.setMuted === "function", "the host's UntypedInput offers setVolume and setMuted")
    check(untyped.active !== undefined && untyped.known !== undefined && untyped.volume !== undefined && untyped.muted !== undefined, "the host's UntypedInput offers active, known, volume and muted")
    check(Audio.AudioService.isShellLevelMeter({
      name: "quickshell-peak-monitor"
    }), "shell level meter filtered")
    eq(Audio.AudioService.platformHides({
      name: "alsa_output.speakers"
    }), false, "no platform hints here")
    // A second resolve while the startup run of omarchy-audio-output-sink is
    // still going (the fake takes 2 s): its answer is stale and must lose to
    // a rerun (checked at the end). If the startup run already ended, the
    // end check would pass without the rerun: fail here instead.
    Audio.AudioService.resolveVolumeSink()
    check(Audio.AudioService.volumeSinkStale, "fixture: the second resolve lands while the startup run is still going")
    var first = panels.itemAt(0)
    // No PipeWire offscreen: the bar shows the no-output glyph, never an empty button.
    eq(first.barGlyph(), "\ueee8", "bar glyph without an output")
    eq(first.popup.bodyItem, null, "popup body is lazy")
    // An app's icon name is text from the app: never a remote image.
    eq(first.appIconSource("https://example.invalid/icon.png"), "", "a stream's icon name never becomes a remote image")
    eq(String(first.appIconSource("/usr/share/icons/x.png")), "file:///usr/share/icons/x.png", "an absolute path becomes a file URL")
    // The bar tooltip carries the output's own name: bounded like FoamyText.tooltip.
    var button = findType(first, function (item) {
      return item.tooltipText !== undefined && item.labelVisible !== undefined
    })
    check(button !== null, "bar button found")
    if (button)
      eq(button.tooltipText, FoamyI18n.t("Audio"), "bar tooltip without an output")
    var long = first.barTooltip("Speaker ".repeat(40) + "\n1\n2\n3\n4\n5\n6\n7")
    var lines = long.split("\n")
    eq(lines.length, 6, "a long output name keeps at most six tooltip lines")
    check(lines.every(function (line) {
      return line.length <= 100
    }), "tooltip lines stay within 100 characters: " + JSON.stringify(long))
    check(long.indexOf("…") > 0, "a cut tooltip shows the ellipsis")
    // The one setting: the percentage next to the glyph, never on a vertical bar.
    percent = findType(button, function (item) {
      return item.text === FoamyI18n.t("%1%", 0) && item.textFormat !== undefined
    })
    check(percent !== null, "bar percentage found")
    if (percent) {
      eq(percent.visible, true, "the bar shows the percentage")
      mockBar.position = "left"
      eq(percent.visible, false, "a vertical bar hides the percentage")
      mockBar.position = "top"
    }
    eq(Audio.AudioService.demanded, false, "no demand while closed")
    if (!button) {
      shell.finish()
      return
    }
    barButton = button
    button.pressed(Qt.LeftButton)
    wait.waitFor(function () {
      return first.popup.bodyItem !== null
    }, 10000, stepTwo, "body built on open")
  }
  property var barButton: null
  property var percent: null

  function top(flick, item) {
    return item.mapToItem(flick.contentItem, 0, 0).y
  }
  function sectionText(view, name, text) {
    return findType(view.sectionItem(name), function (item) {
      return item.text === text && item.visible && item.textFormat !== undefined
    })
  }
  // Rows of nodes that do not exist: the delegates take the "node is gone" path.
  function fakeRows(base, count) {
    var rows = []
    for (var i = 0; i < count; i++)
      rows.push({
        id: base + i,
        name: "fake.node." + (base + i)
      })
    return rows
  }

  function stepTwo() {
    var first = panels.itemAt(0)
    var view = first.popup.bodyItem
    check(view !== null, "body built on open")
    eq(Audio.AudioService.demanded, true, "open popup raises demand")
    if (!view) {
      shell.finish()
      return
    }
    // What the popup shows without an audio server: the empty state.
    var band = findType(view, function (item) {
      return item.title !== undefined && item.meta !== undefined && item.settingsHasCursor !== undefined
    })
    check(band !== null, "hero band found")
    var shown = {
      en: ["Audio", "No output devices"],
      no: ["Lyd", "Ingen utgangsenheter"],
      ar: ["Audio", "No output devices"]
    }[shell.lang]
    if (band) {
      eq(band.title, shown[0], "the band's title in this language")
      eq(band.meta, shown[1], "the band names the missing output in this language")
    }
    check(findType(view, function (item) {
      return item.text === "—" && item.textFormat !== undefined && item.visible
    }) !== null, "the volume numeral is a dash without an output")
    check(sectionText(view, "output", FoamyI18n.t("No output devices")) !== null, "Output says there are no output devices")
    check(sectionText(view, "input", FoamyI18n.t("No input devices")) !== null, "Input says there are no input devices")
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
      eq(slider.enabled, false, "the header slider is disabled without an output")
      eq(slider.mirrored, shell.lang === "ar", "the volume slider mirrors in RTL only")
      // Up to the band (its own surface is not a row behind the slider).
      for (var item = slider.parent; item && item !== band; item = item.parent)
        if (item.color !== undefined)
          check(!item.visible || item.color.a === 0, "nothing filled behind the header slider while the cursor is on volume: " + item)
    }
    view.moveRequested(0, -1)
    eq(view.cursorKey, "settings", "up from the slider reaches the header")
    view.moveRequested(-1, 0)
    eq(view.cursorKey, FoamyI18n.rightToLeft ? "settings" : "inputMute", "h moves along the header in reading order")
    shell.key(view, "o")
    eq(view.outputExpanded, false, "o folds Output")
    // Enough inputs that Wireless starts below the fold.
    first.displayAudioSources = fakeRows(9000, 40)
    var flick = view.wheel.target
    wait.waitFor(function () {
      return flick.contentHeight > flick.height + 100
    }, 5000, stepTwoScroll, "fixture: the list overflows")
  }

  function stepTwoScroll() {
    var first = panels.itemAt(0)
    var view = first.popup.bodyItem
    var flick = view.wheel.target
    var wireless = view.sectionItem("wireless")
    eq(flick.contentY, 0, "fixture: list at the top")
    check(top(flick, wireless) + wireless.height > flick.contentY + flick.height, "fixture: Wireless starts below the fold")
    // Folded, the section is its header row.
    var header = wireless.height
    shell.key(view, "w")
    eq(view.wirelessExpanded, true, "w unfolds Wireless")
    // The header row at least: the section's last pixels can stay below the
    // fold, because FoamyWheelScroll refollows the growing section before
    // the Flickable's contentHeight has grown.
    wait.waitFor(function () {
      var y = shell.top(flick, wireless)
      return first.displayAudioSources.length === 40 && flick.contentY > 0 && y >= flick.contentY - 1 && y + header <= flick.contentY + flick.height + 1
    }, 5000, stepTwoSettings, "unfolding scrolls Wireless into view")
  }

  function stepTwoSettings() {
    var first = panels.itemAt(0)
    var view = first.popup.bodyItem
    eq(view.LayoutMirroring.enabled, shell.lang === "ar", "popup body mirrors in RTL only")
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
    if (percent)
      eq(percent.visible, false, "the saved setting hides the bar percentage at once")
    first.closeSettings()
    eq(view.blocked, false, "back from Settings")
    // Rows in every list right before the close: a closed popup holds none.
    first.displayAudioSources = fakeRows(9000, 40)
    first.displayAudioSinks = fakeRows(9100, 1)
    first.displayAudioStreams = fakeRows(9200, 1)
    first.displayWirelessAudioSinks = fakeRows(9300, 1)
    eq([first.displayAudioSources.length, first.displayAudioSinks.length, first.displayAudioStreams.length, first.displayWirelessAudioSinks.length].join(","), "40,1,1,1", "fixture: rows present while open")
    barButton.pressed(Qt.LeftButton)
    eq(first.opened, false, "the bar button closes the popup")
    eq(Audio.AudioService.demanded, false, "closing releases demand")
    wait.waitFor(function () {
      return !Audio.AudioService.wanted
    }, 10000, stepThree, "discovery released after the delay")
  }

  function stepThree() {
    var first = panels.itemAt(0)
    eq([first.displayAudioSources.length, first.displayAudioSinks.length, first.displayAudioStreams.length, first.displayWirelessAudioSinks.length].join(","), "0,0,0,0", "rows dropped while closed")
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
      shell.volumeSink()
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
    shell.volumeSink()
  }

  // tests/runtime.py compares the name with the number of runs the fake
  // omarchy-audio-output-sink counted: the last run's answer must win.
  function volumeSink() {
    wait.waitFor(function () {
      return Audio.AudioService.volumeSinkName !== ""
    }, 10000, function () {
      console.log("FOAMY VOLUME SINK " + Audio.AudioService.volumeSinkName)
      shell.finish()
    }, "a volume sink resolved")
  }

  // tests/runtime.py calls the IPC handler after FOAMY READY, then stops qs.
  function finish() {
    console.log("FOAMY RESULT " + host + "/" + lang + " " + checks + " checks, " + failures + " failures (a wait that timed out is reported on its own line)")
    console.log("FOAMY DONE")
    console.log("FOAMY READY")
  }
}
