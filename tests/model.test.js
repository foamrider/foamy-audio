const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

assert.equal(Model.nodeLabel({
  description: "Astro A50 Game",
  nickname: "USB Audio #1"
}), "Astro A50 Game")

assert.equal(Model.nodeLabel({
  description: "Astro A50 Chat",
  nickname: "Astro A50"
}), "Astro A50 Chat")

assert.equal(Model.nodeLabel({
  description: "Creative Stage SE Analog Stereo",
  nickname: "Creative Stage SE"
}), "Creative Stage SE")

const gamingHeadset = {
  ready: true,
  properties: {
    "device.product.name": "Astro A50",
    "device.profile-set": "usb-gaming-headset.conf"
  }
}

assert.equal(Model.isHeadphones(gamingHeadset), true)

const liveGamingSink = {
  description: "Astro A50 Gaming",
  nickname: "USB Audio #1"
}

assert.equal(Model.isHeadphones(liveGamingSink), true)

const trackedGamingSink = {
  ready: true,
  description: "USB Audio #1",
  properties: {
    "node.description": "Astro A50 Game"
  }
}

assert.equal(Model.isHeadphones(trackedGamingSink), true)

const jabraSink = {
  name: "bluez_output.02_00_00_00_00_01.1",
  description: "Jabra Evolve3 85",
  nickname: "Jabra Evolve3 85"
}
const jabraDevice = {
  address: "02:00:00:00:00:01",
  deviceName: "Jabra Evolve3 85",
  icon: "audio-headset"
}

assert.equal(Model.bluetoothSinkMatchesDevice(jabraSink, jabraDevice), true)
assert.equal(Model.isHeadphones(jabraSink, [jabraDevice]), true)

const bluetoothSpeaker = {
  address: "11:22:33:44:55:66",
  deviceName: "Living Room Speaker",
  icon: "audio-speakers"
}
const bluetoothSpeakerSink = {
  name: "bluez_output.11_22_33_44_55_66.1",
  description: "Living Room Speaker"
}

assert.equal(Model.isHeadphones(bluetoothSpeakerSink, [bluetoothSpeaker]), false)
assert.equal(Model.bluetoothDeviceForSink(bluetoothSpeakerSink, [bluetoothSpeaker]), bluetoothSpeaker)

const sonosBeam = {
  ready: true,
  name: "raop_sink.020000000002@Stue",
  description: "Stue",
  properties: {
    "device.api": "raop",
    "raop.name": "020000000002@Stue",
    "raop.hostname": "Sonos-020000000002.local",
    "device.model": "Beam"
  }
}

assert.equal(Model.isAirplaySink(sonosBeam), true)
assert.equal(Model.airplayRoomLabel(sonosBeam), "Stue")

assert.equal(Model.isAirplaySink({
  ready: true,
  name: "alsa_output.usb-Creative",
  properties: { "device.api": "alsa" }
}), false)

assert.equal(Model.cleanAirplayLabel("020000000003@Stua.local"), "Stua")

console.log("audio model tests passed")

test('AirPlay matching does not confuse an IP prefix with another receiver', () => {
  const peers = [
    {name:'Living room',hostname:'Living.local',address:'192.0.2.24',port:7000},
    {name:'Kitchen',hostname:'Kitchen.local',address:'192.0.2.249',port:7000}
  ]
  const kitchen = {name:'raop_sink.Kitchen.local.192.0.2.249.7000'}
  assert.equal(Model.airplayPeerForSink(kitchen, peers), peers[1])
  assert.equal(Model.airplayPeerForSink({name:'raop_sink.Unknown.local.192.0.2.240.7000'}, peers), null)
  assert.deepEqual(Model.uniqueAirplaySinks([kitchen, {...kitchen}, {name:'foamy_airplay_group_123'}],peers,kitchen), [kitchen])
})

test("repeater rows hold primitives and resolve to the live node", () => {
  const live = [{ id: 4, name: "alsa_output.a" }, { id: 7, name: "raop_sink.b" }]
  const rows = Model.rowSnapshot([live[1], null, { name: "no id" }])
  assert.deepEqual(rows, [{ id: 7, name: "raop_sink.b" }])
  assert.equal(Model.nodeFor(rows[0], live), live[1])
  // A recycled id under another name is not the same node.
  assert.equal(Model.nodeFor(rows[0], [{ id: 7, name: "other" }]), null)
  assert.equal(Model.nodeFor(null, live), null)
})

test("shell level meters and untyped sources", () => {
  assert.equal(Model.isShellLevelMeter("quickshell"), true)
  assert.equal(Model.isShellLevelMeter("quickshell-peak-monitor"), true)
  assert.equal(Model.isShellLevelMeter("alsa_input.mic"), false)
  const availability = { "easyeffects_source": true }
  assert.equal(Model.isUntypedSource({ name: "easyeffects_source", audio: null, isSink: false, isStream: false }, availability), true)
  assert.equal(Model.isUntypedSource({ name: "easyeffects_source", audio: {}, isSink: false, isStream: false }, availability), false)
  assert.equal(Model.isUntypedSource({ name: "easyeffects_source", isSink: true }, availability), false)
  assert.equal(Model.isUntypedSource({ name: "other", isSink: false, isStream: false }, availability), false)
})
