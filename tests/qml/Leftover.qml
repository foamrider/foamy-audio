import QtQuick
import Quickshell
import "harness"
import "plugin" as Audio

// An AirPlay discovery session left behind by a shell that crashed with the
// popup open: the fake helper's `status` reports it active (tests/runtime.py).
// The service stops it only under a known, bound output that is not AirPlay;
// offscreen there is no PipeWire, so the startup status leaves it running.
ShellRoot {
  id: shell
  readonly property var service: Audio.AudioService
  property int checks: 0
  property int failures: 0

  function check(ok, label) {
    checks++
    if (!ok) {
      failures++
      console.log("FOAMY FAIL leftover " + label)
    }
  }
  function eq(actual, expected, label) {
    check(actual === expected, label + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected))
  }

  FoamyWait {
    id: wait
  }

  Component.onCompleted: wait.waitFor(function () {
    return shell.service.airplayDiscoveryActive
  }, 10000, statusSeen, "status reports the leftover session")

  function statusSeen() {
    eq(service.wanted, false, "no popup wants discovery")
    eq(service.sink, null, "no default output offscreen")
    eq(service.airplayStopping, false, "no stop while the default output is unknown")
    var local = {
      name: "alsa_output.speakers",
      ready: true,
      properties: {
        "device.api": "alsa"
      }
    }
    eq(service.stopUnwantedDiscovery({
      name: "alsa_output.speakers",
      ready: false
    }), false, "not before the output is bound")
    eq(service.stopUnwantedDiscovery({
      name: "raop_sink.Kitchen.local",
      ready: true,
      properties: {
        "device.api": "raop"
      }
    }), false, "never under an AirPlay output")
    eq(service.stopUnwantedDiscovery({
      name: "foamy_airplay_group_1",
      ready: true,
      properties: {}
    }), false, "never under an AirPlay group")
    eq(service.airplayStopping, false, "nothing stopped so far")
    eq(service.stopUnwantedDiscovery(local), true, "stops under a local output")
    eq(service.stopUnwantedDiscovery(local), false, "one stop at a time")
    wait.waitFor(function () {
      return !shell.service.airplayDiscoveryActive && !shell.service.airplayBusy
    }, 10000, stopped, "the leftover session stopped")
  }

  function stopped() {
    eq(service.airplayScanState, "idle", "discovery idle after the stop")
    eq(service.stopUnwantedDiscovery({
      name: "alsa_output.speakers",
      ready: true,
      properties: {}
    }), false, "nothing left to stop")
    console.log("FOAMY RESULT leftover " + checks + " checks, " + failures + " failures")
    console.log("FOAMY DONE")
    Qt.quit()
  }
}
