import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Audio
import "plugin/kit"

// The plugin's side of the helper protocol, in Norwegian, against the
// scripted fake helper of tests/runtime.py (HELPER): AirPlay start, stop and
// select, the firewall actions, replies that are errors or not JSON, actions
// ignored while one runs, and the stop when the popup closes.
// tests/runtime.py checks the helper's argv log. FOAMY_MODE=nohelper runs a
// plugin copy without bin/: the "no helper for this CPU" state.
ShellRoot {
  id: shell
  readonly property string mode: Quickshell.env("FOAMY_MODE") || "helper"
  readonly property var service: Audio.AudioService
  // The scene's only panel, in a Loader so that the last step can remove it.
  readonly property var panel: panelLoader.item
  readonly property var view: panel ? panel.popup.bodyItem : null
  property int checks: 0
  property int failures: 0
  property bool finished: false
  // The gates this scene released so far (see release()).
  property string released: ""

  function check(ok, label) {
    checks++
    if (!ok) {
      failures++
      console.log("FOAMY FAIL helper " + mode + " " + label)
    }
  }
  function eq(actual, expected, label) {
    check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
  }
  // What the popup shows from this flow must have a Norwegian text.
  function translated(text, label) {
    check(text !== "" && FoamyI18n.t(text) !== text, label + " has a Norwegian text: " + JSON.stringify(text))
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

  // Every Text under `item` whose text is `text`.
  function textsSaying(item, text, found) {
    if (!item)
      return found
    if (item.text === text && item.color !== undefined)
      found.push(item)
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++)
      textsSaying(kids[i], text, found)
    return found
  }

  // The `count` texts saying `text` read on the popup card as drawn.
  // tests/runtime.py runs this scene in a theme whose red reads 2.70:1 on
  // the popup; the first check proves that theme is in effect.
  function readsOnPopup(text, count, label) {
    var card = panel.popup.cardItem.color
    var raw = FoamyPalette.contrastRatio(FoamyPalette.error, card)
    check(raw < 4.5, "the theme's raw red is under 4.5:1 on the popup: " + raw.toFixed(2) + ":1")
    var said = textsSaying(view, text, [])
    eq(said.length, count, label + " is shown")
    said.forEach(function (item) {
      var ratio = FoamyPalette.contrastRatio(item.color, card)
      check(ratio >= 4.5, label + " reads on the popup: " + item.color + ", " + ratio.toFixed(2) + ":1")
    })
  }

  FloatingWindow {
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    ScreenSim {
      id: sim
    }
    Loader {
      id: panelLoader
      x: 1200
      y: 4
      sourceComponent: Audio.Panel {
        bar: mockBar
        moduleName: "foamy.audio"
        settings: ({
            id: "foamy.audio",
            showPercentage: true
          })
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
  // The fake helper holds the first start, the kitchen choice and verify
  // until the scene writes the gate's name here (hold in tests/runtime.py).
  FileView {
    id: gates
    path: Quickshell.env("FOAMY_OUT") + "/release"
    preload: false
    onSaveFailed: function (error) {
      shell.check(false, "writing the release file failed: " + FileViewError.toString(error))
    }
  }
  // Lets a held helper call answer: only after the scene has acted on the
  // state that call shows, so the order never depends on the machine's speed.
  function release(gate) {
    released += gate + "\n"
    gates.setText(released)
  }
  // A wait that timed out has logged its failure: the scene ends there, so
  // no later step acts on a state it never saw.
  function until(condition, timeoutMs, then, label) {
    wait.waitFor(condition, timeoutMs, function (ok) {
      if (ok)
        then()
      else
        finish()
    }, label)
  }

  Component.onCompleted: Qt.callLater(mode === "nohelper" ? noHelper : closeDuringStart)

  // a. A popup closed while its start still runs (the fake holds the first
  // start) must not leave discovery loaded. The service lets go of a closed
  // popup after a short delay: the start ends only once it has.
  function closeDuringStart() {
    panel.open()
    until(function () {
      return shell.service.airplayScanState === "scanning"
    }, 10000, function () {
      panel.close()
      until(function () {
        return !shell.service.wanted && shell.service.airplayBusy
      }, 10000, function () {
        release("start")
        until(function () {
          return !shell.service.wanted && !shell.service.airplayBusy && shell.service.airplayScanState === "idle"
        }, 15000, selectSpeaker, "a start still running at the close ends in a stop")
      }, "the service lets go of the closed popup while its start runs")
    }, "opening starts discovery")
  }

  // b. One speaker choice at a time.
  function selectSpeaker() {
    eq(service.airplayDiscoveryActive, false, "discovery not left active after a close during its start")
    panel.open()
    until(function () {
      return panel.airplayPeerCount === 2 && shell.service.airplayDiscoveryActive && view !== null
    }, 10000, function () {
      panel.activate("wireless", {
        name: "raop_sink.kitchen"
      })
      // The fake holds this choice: a second one meanwhile is ignored.
      until(function () {
        return shell.service.airplaySelecting
      }, 5000, function () {
        panel.activate("wireless", {
          name: "raop_sink.hall"
        })
        release("select")
        until(function () {
          return !shell.service.airplaySelecting && shell.service.airplayScanState === "results"
        }, 10000, verifyFirewall, "the speaker choice ends")
      }, "the speaker choice runs")
    }, "discovery finds two speakers")
  }

  // c. The firewall replies: a wide rule, removed, a reply that is not
  // JSON, a cancelled authorization.
  function firewall(action, then) {
    view.firewall(action)
    until(function () {
      return !panel.firewallBusy && panel.firewallState !== ""
    }, 10000, then, "the firewall " + action + " ends")
  }
  function verifyFirewall() {
    eq(service.airplayError, "", "no error after the speaker choice")
    eq(JSON.stringify(service.selectedAirplayNames), "[\"raop_sink.kitchen\"]", "the helper's selection is kept")
    var apply = findNamed(view, "audioFirewallApply")
    eq(apply ? apply.enabled : null, true, "Apply is enabled once speakers are found")
    firewall("verify", wideRule)
    // The fake holds verify: Apply meanwhile is ignored.
    until(function () {
      return panel.firewallBusy
    }, 5000, function () {
      view.firewall("open")
      release("verify")
    }, "verify runs")
  }
  function wideRule() {
    eq(panel.firewallState, "wide", "verify reports the wide rule")
    eq(panel.firewallLegacy, true, "the wide rule is the legacy one")
    eq(panel.firewallMessage, "Ports are open to every network. Remove the rule, then apply to limit it to this network.", "the wide-rule text")
    translated(panel.firewallMessage, "the wide-rule text")
    readsOnPopup(FoamyI18n.t(panel.firewallMessage), 1, "the wide-rule text")
    firewall("remove", removed)
  }
  function removed() {
    eq(panel.firewallState, "removed", "remove reports removed")
    eq(panel.firewallLegacy, false, "nothing legacy left after the remove")
    eq(panel.firewallMessage, "Foamy Audio rules removed.", "the removed text")
    translated(panel.firewallMessage, "the removed text")
    firewall("remove", notJson)
  }
  function notJson() {
    eq(panel.firewallState, "error", "a reply that is not JSON is an error")
    eq(panel.firewallMessage, "Could not complete the UFW check.", "the invalid-reply text")
    translated(panel.firewallMessage, "the invalid-reply text")
    firewall("open", cancelled)
  }
  function cancelled() {
    eq(panel.firewallState, "error", "a cancelled authorization is an error")
    eq(panel.firewallMessage, "Authorization cancelled or denied.", "the cancelled text")
    translated(panel.firewallMessage, "the cancelled text")
    choose("wireless", {
      name: "raop_sink.gone"
    }, "error", speakerGone)
  }

  // d. Replies to a choice: a refusal, a local output, invalid data, a
  // failure after the output changed.
  function choose(kind, node, state, then) {
    panel.activate(kind, node)
    until(function () {
      return !shell.service.airplaySelecting && shell.service.airplayScanState === state
    }, 10000, then, "the " + kind + " choice " + node.name + " ends in " + state)
  }
  function speakerGone() {
    eq(service.airplayError, "An AirPlay speaker is no longer available. Reopen the panel.", "the helper's refusal is shown")
    translated(service.airplayError, "the refusal")
    choose("sink", {
      id: 5,
      name: "alsa_output.usb"
    }, "results", localOutput)
  }
  function localOutput() {
    eq(service.airplayError, "", "a local output clears the error")
    choose("wireless", {
      name: "raop_sink.garbage"
    }, "error", garbage)
  }
  function garbage() {
    eq(service.airplayError, "AirPlay helper returned invalid data", "a reply that is not JSON")
    translated(service.airplayError, "the invalid-data text")
    panel.activate("wireless", {
      name: "raop_sink.half"
    })
    // The choice before ended in an error too: wait for this one's text.
    until(function () {
      return !shell.service.airplaySelecting && shell.service.airplayError === shell.changedText
    }, 10000, outputChanged, "the wireless choice raop_sink.half ends in its error")
  }
  // tests/runtime.py checks that the reply's details reach the log.
  readonly property string changedText: "Output changed, but an earlier AirPlay group could not be removed."
  function outputChanged() {
    eq(service.airplayScanState, "error", "a choice that failed after the output changed is an error")
    translated(service.airplayError, "the text after the output changed")
    eq(JSON.stringify(service.selectedAirplayNames), "[\"raop_sink.half\"]", "the speakers of a choice that failed after the output changed are taken")
    panel.close()
    until(function () {
      return !shell.service.wanted && !shell.service.airplayBusy && !shell.service.airplayDiscoveryActive && shell.service.airplayScanState === "idle"
    }, 10000, removePanel, "closing stops discovery")
  }

  // e. The last panel goes away (plugin disabled or removed) while its popup
  // is open and discovery runs: the service stops discovery itself.
  // tests/runtime.py waits for that stop in the helper log.
  function removePanel() {
    panel.open()
    until(function () {
      return shell.service.airplayDiscoveryActive && panel.airplayPeerCount === 2 && view !== null
    }, 10000, function () {
      panelLoader.active = false
      until(function () {
        return !shell.service.airplayDiscoveryActive && shell.service.airplayScanState === "idle"
      }, 10000, finish, "removing the last panel ends discovery")
    }, "reopening starts discovery again")
  }

  // No bin/ for this CPU: AirPlay and the firewall say so, in Norwegian.
  readonly property string unavailableText: "This plugin's helper isn't available for this CPU."
  function noHelper() {
    until(function () {
      return shell.service.airplayHelperUnavailable
    }, 10000, function () {
      panel.open()
      until(function () {
        return shell.service.airplayScanState === "error" && view !== null
      }, 10000, noHelperOpen, "AirPlay reports the missing helper")
    }, "the startup status finds no helper")
  }
  function noHelperOpen() {
    eq(service.airplayError, unavailableText, "AirPlay names the missing helper")
    translated(service.airplayError, "the missing-helper text")
    firewall("verify", function () {
      eq(panel.firewallState, "error", "the firewall check reports the missing helper")
      eq(panel.firewallMessage, shell.unavailableText, "the firewall names the missing helper")
      // The AirPlay section's error and the firewall's error both say it.
      readsOnPopup(FoamyI18n.t(shell.unavailableText), 2, "the missing-helper text")
      panel.close()
      shell.finish()
    })
  }

  function finish() {
    if (finished)
      return
    finished = true
    console.log("FOAMY RESULT helper " + mode + " " + checks + " checks, " + failures + " failures (a wait that timed out is reported on its own line)")
    console.log("FOAMY DONE")
    Qt.quit()
  }
}
