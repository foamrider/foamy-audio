import QtQuick
import Quickshell
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

  Component.onCompleted: Qt.callLater(mode === "nohelper" ? noHelper : closeDuringStart)

  // a. A popup closed while its start still runs (the fake's first start
  // takes 1.5 s) must not leave discovery loaded.
  function closeDuringStart() {
    panel.open()
    wait.waitFor(function () {
      return shell.service.airplayScanState === "scanning"
    }, 10000, function () {
      panel.close()
      wait.waitFor(function () {
        return !shell.service.wanted && !shell.service.airplayBusy && shell.service.airplayScanState === "idle"
      }, 15000, selectSpeaker, "a start still running at the close ends in a stop")
    }, "opening starts discovery")
  }

  // b. One speaker choice at a time.
  function selectSpeaker() {
    eq(service.airplayDiscoveryActive, false, "discovery not left active after a close during its start")
    panel.open()
    wait.waitFor(function () {
      return panel.airplayPeerCount === 2 && shell.service.airplayDiscoveryActive && view !== null
    }, 10000, function () {
      panel.activate("wireless", {
        name: "raop_sink.kitchen"
      })
      // The fake takes 1 s for this choice: a second one meanwhile is ignored.
      wait.waitFor(function () {
        return shell.service.airplaySelecting
      }, 5000, function () {
        panel.activate("wireless", {
          name: "raop_sink.hall"
        })
        wait.waitFor(function () {
          return !shell.service.airplaySelecting && shell.service.airplayScanState === "results"
        }, 10000, verifyFirewall, "the speaker choice ends")
      }, "the speaker choice runs")
    }, "discovery finds two speakers")
  }

  // c. The firewall replies: a wide rule, removed, a reply that is not
  // JSON, a cancelled authorization.
  function firewall(action, then) {
    view.firewall(action)
    wait.waitFor(function () {
      return !panel.firewallBusy && panel.firewallState !== ""
    }, 10000, then, "the firewall " + action + " ends")
  }
  function verifyFirewall() {
    eq(service.airplayError, "", "no error after the speaker choice")
    eq(JSON.stringify(service.selectedAirplayNames), "[\"raop_sink.kitchen\"]", "the helper's selection is kept")
    var apply = findNamed(view, "audioFirewallApply")
    eq(apply ? apply.enabled : null, true, "Apply is enabled once speakers are found")
    firewall("verify", wideRule)
    // The fake takes 1 s to verify: Apply meanwhile is ignored.
    wait.waitFor(function () {
      return panel.firewallBusy
    }, 5000, function () {
      view.firewall("open")
    }, "verify runs")
  }
  function wideRule() {
    eq(panel.firewallState, "wide", "verify reports the wide rule")
    eq(panel.firewallLegacy, true, "the wide rule is the legacy one")
    eq(panel.firewallMessage, "Ports are open to every network. Remove the rule, then apply to limit it to this network.", "the wide-rule text")
    translated(panel.firewallMessage, "the wide-rule text")
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

  // d. Replies to a choice: a refusal, a local output, invalid data.
  function choose(kind, node, state, then) {
    panel.activate(kind, node)
    wait.waitFor(function () {
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
    panel.close()
    wait.waitFor(function () {
      return !shell.service.wanted && !shell.service.airplayBusy && !shell.service.airplayDiscoveryActive && shell.service.airplayScanState === "idle"
    }, 10000, removePanel, "closing stops discovery")
  }

  // e. The last panel goes away (plugin disabled or removed) while its popup
  // is open and discovery runs: the service stops discovery itself.
  // tests/runtime.py waits for that stop in the helper log.
  function removePanel() {
    panel.open()
    wait.waitFor(function () {
      return shell.service.airplayDiscoveryActive && panel.airplayPeerCount === 2 && view !== null
    }, 10000, function () {
      panelLoader.active = false
      wait.waitFor(function () {
        return !shell.service.airplayDiscoveryActive && shell.service.airplayScanState === "idle"
      }, 10000, finish, "removing the last panel ends discovery")
    }, "reopening starts discovery again")
  }

  // No bin/ for this CPU: AirPlay and the firewall say so, in Norwegian.
  readonly property string unavailableText: "This plugin's helper isn't available for this CPU."
  function noHelper() {
    wait.waitFor(function () {
      return shell.service.airplayHelperUnavailable
    }, 10000, function () {
      panel.open()
      wait.waitFor(function () {
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
      panel.close()
      shell.finish()
    })
  }

  function finish() {
    console.log("FOAMY RESULT helper " + mode + " " + checks + " checks, " + failures + " failures")
    console.log("FOAMY DONE")
    Qt.quit()
  }
}
