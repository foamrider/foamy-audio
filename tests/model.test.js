const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("device labels: Game and Chat stay apart, the nickname wins, built-in names are cleaned", () => {
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

  // Built-in prefixes and Output/Input suffixes go; no node at all is "Unknown".
  assert.equal(Model.nodeLabel({ description: "Built-in Audio Analog Stereo" }), "Analog Stereo")
  assert.equal(Model.nodeLabel({ description: "sof-soundwire Speaker Output" }), "Speaker")
  assert.equal(Model.nodeLabel({ name: "alsa_input.pci-0000 Input" }), "alsa_input.pci-0000")
  assert.equal(Model.nodeLabel(null), "Unknown")
})

test("headphones: description suffix, properties, BlueZ device; a Bluetooth speaker stays a speaker", () => {
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
})

test("AirPlay sinks: raop nodes are detected and named by room", () => {
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
})

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

test("untyped sources", () => {
  const availability = { "easyeffects_source": true }
  assert.equal(Model.isUntypedSource({ name: "easyeffects_source", audio: null, isSink: false, isStream: false }, availability), true)
  assert.equal(Model.isUntypedSource({ name: "easyeffects_source", audio: {}, isSink: false, isStream: false }, availability), false)
  assert.equal(Model.isUntypedSource({ name: "easyeffects_source", isSink: true }, availability), false)
  assert.equal(Model.isUntypedSource({ name: "other", isSink: false, isStream: false }, availability), false)
})

test("app labels follow the matching media player (Arrays and Quickshell list wrappers)", () => {
  const sp = { identity: "Spotify", desktopEntry: "spotify", isPlaying: true, canPlay: true }
  const ff = { identity: "Mozilla Firefox", desktopEntry: "firefox", isPlaying: true, canPlay: true }
  const gen = { ready: true, properties: { "application.name": "audio-src" } }
  const fx = { ready: true, properties: { "application.name": "Firefox" } }
  // Mpris.players.values and Pipewire.nodes.values are sequence wrappers:
  // Array.isArray is false for them.
  const wrap = list => Object.assign({ length: list.length }, list)
  assert.equal(Model.streamLabel(gen, [sp], [gen]), "Spotify")
  assert.equal(Model.streamLabel(gen, wrap([sp, ff]), wrap([gen, fx])), "Spotify", "a generic stream takes the player no other stream claims")
  assert.equal(Model.streamLabel(fx, wrap([sp, ff]), wrap([gen, fx])), "Mozilla Firefox", "a named stream takes its own player")
  assert.equal(Model.streamLabel(gen, [sp, ff], [gen]), "audio-src", "two candidates: keep the raw label")
  assert.equal(Model.streamLabel(fx, [], [fx]), "Firefox")
  assert.equal(Model.streamLabel(null, [], []), "Stream")
  assert.equal(Model.streamLabel({}, [], []), "Stream")
})

test("the meter reaches pw-record with any node name, a leading dash too", () => {
  // The real helper (FoamyNative's bash launch) with a fake pw-record on a
  // PATH that holds nothing else, so no microphone is opened.
  const fs = require("node:fs")
  const os = require("node:os")
  const path = require("node:path")
  const { spawnSync } = require("node:child_process")
  const FoamyNative = require("../kit/node-loader.cjs").load("FoamyNative")
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "foamy-audio-meter-argv-"))
  try {
    const log = path.join(dir, "argv.json")
    fs.writeFileSync(path.join(dir, "pw-record"),
      "#!/bin/bash\nprintf '%s\\0' \"$@\" > " + JSON.stringify(log) + "\nexit 1\n", { mode: 0o755 })
    for (const [name, passive] of [["--help", false], ["-mic", true], ["alsa_input.usb mic", false]]) {
      fs.rmSync(log, { force: true })
      const argv = FoamyNative.command(path.join(__dirname, ".."), "foamy-audio-helper",
        Model.microphonePeakArgs(name, "MONO", passive))
      const result = spawnSync("/bin/bash", argv.slice(1), { env: { PATH: dir }, encoding: "utf8", timeout: 10000 })
      assert.equal(result.status, 1, name + ": " + result.stderr)
      const seen = fs.readFileSync(log, "utf8").split("\0").slice(0, -1)
      assert.equal(seen[seen.indexOf("--target") + 1], name)
      assert.equal(seen.some(arg => arg.includes("node.passive=true")), passive, name)
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("a hung input switch ends at its deadline", () => {
  // A fake omarchy-audio-input-set-default that ignores SIGTERM and never
  // returns, like the host script stuck on a wedged pipewire-pulse. The
  // production deadline is bounded here and the same argv runs with a short
  // one, so the test proves the SIGTERM, then SIGKILL chain in about 1.5 s.
  const fs = require("node:fs")
  const os = require("node:os")
  const path = require("node:path")
  const { spawnSync } = require("node:child_process")
  const argv = Model.inputDefaultCommand(57, "-usb mic")
  const deadline = argv.findIndex(arg => /^\d+(\.\d+)?s$/.test(arg))
  assert.ok(deadline > 0, "the switch runs under a deadline: " + JSON.stringify(argv))
  assert.ok(parseFloat(argv[deadline]) <= 15, "deadline at most 15 s: " + argv[deadline])
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "foamy-audio-input-switch-"))
  try {
    const log = path.join(dir, "argv")
    fs.writeFileSync(path.join(dir, "omarchy-audio-input-set-default"),
      "#!/bin/bash\nprintf '%s\\0' \"$@\" > " + JSON.stringify(log) + "\ntrap '' TERM\nexec sleep 60\n", { mode: 0o755 })
    const short = argv.slice()
    short[deadline] = "0.3s"
    const started = Date.now()
    const result = spawnSync(short[0], short.slice(1), { env: { PATH: dir + ":/usr/bin:/bin" }, encoding: "utf8", timeout: 10000, killSignal: "SIGKILL" })
    const elapsed = Date.now() - started
    assert.equal(result.error, undefined, "the switch ended on its own deadline")
    // timeout's SIGKILL goes to its whole process group, itself included.
    assert.equal(result.signal, "SIGKILL", "SIGKILL after the ignored SIGTERM")
    assert.ok(elapsed >= 1000 && elapsed < 8000, "ended after " + elapsed + " ms (the 1 s kill-after ran)")
    assert.deepEqual(fs.readFileSync(log, "utf8").split("\0").slice(0, -1), ["57", "-usb mic"])
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
