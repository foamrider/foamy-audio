function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

function isAudioSource(node) {
  if (!node) return false
  if (node.audio) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Audio/Source") !== -1
    || mediaClass.indexOf("AudioSource") !== -1
    || mediaClass.indexOf("Source") !== -1
}

function listSnapshot(list) {
  return list && list.slice ? list.slice() : []
}

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
  if (p === 0) return "Silenced"
  if (p >= 100) return "Concert hall"
  if (p >= 85) return "Party mode"
  if (p >= 70) return "Cranked up"
  if (p >= 50) return "Steady groove"
  if (p >= 30) return "Easy listening"
  if (p >= 15) return "Murmur"
  return "Whisper"
}

function parseSinkAvailability(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
  }
  return next
}

function friendlyDeviceLabel(text) {
  var label = String(text || "").trim()
  label = label.replace(/^sof-soundwire\s+/i, "")
  label = label.replace(/^built-?in audio\s+/i, "")
  label = label.replace(/\s+Output$/i, "")
  label = label.replace(/\s+Input$/i, "")
  label = label.replace(/\bMicrophones\b/g, "Microphone")
  return label
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function normalizedBluetoothAddress(value) {
  return String(value || "").trim().toLowerCase().replace(/[^0-9a-f]/g, "")
}

function bluetoothSinkMatchesDevice(node, device) {
  if (!node || !device) return false

  var p = nodeProps(node)
  var address = normalizedBluetoothAddress(device.address)
  var propertyAddress = normalizedBluetoothAddress(p["api.bluez5.address"] || p["bluez5.address"] || "")
  var nodeName = normalizedBluetoothAddress(node.name || p["node.name"] || "")
  if (address && (propertyAddress === address || nodeName.indexOf(address) !== -1)) return true

  var label = String(device.deviceName || device.name || "").trim().toLowerCase()
  var nodeLabel = String([
    node.description, node.nickname, node.nick,
    p["node.description"] || "", p["node.nick"] || "",
    p["device.description"] || "", p["device.alias"] || ""
  ].join(" ")).toLowerCase()
  return label !== "" && nodeLabel.indexOf(label) !== -1
}

function bluetoothDeviceForSink(node, devices) {
  var list = devices || []
  for (var i = 0; i < list.length; i++) {
    if (bluetoothSinkMatchesDevice(node, list[i])) return list[i]
  }
  return null
}

function bluetoothDeviceIsHeadset(device) {
  var icon = String(device ? device.icon : "").toLowerCase()
  return icon.indexOf("headset") !== -1 || icon.indexOf("headphone") !== -1
}

function nodeLabel(node) {
  if (!node) return "Unknown"
  var p = nodeProps(node)
  var description = friendlyDeviceLabel(node.description || p["node.description"] || "")

  // Game and Chat are separate routing endpoints, not cosmetic profile names.
  if (/\s(?:game|chat)$/i.test(description)) return description

  var nickname = friendlyDeviceLabel(node.nickname || node.nick || p["node.nick"] || p["device.profile.description"] || "")
  if (nickname) return nickname
  return description || friendlyDeviceLabel(node.name || "Unknown")
}

function isAirplaySink(node) {
  if (!node) return false
  var p = nodeProps(node)
  var api = String(p["device.api"] || p["node.driver"] || "").toLowerCase()
  var name = String(node.name || p["node.name"] || "").toLowerCase()
  return api === "raop"
    || name.indexOf("foamy_airplay_group_") === 0
    || name.indexOf("raop_sink") !== -1
    || name.indexOf("raop-sink") !== -1
    || String(p["raop.ip"] || "") !== ""
    || String(p["raop.name"] || "") !== ""
}

function airplayPeerForSink(node, peers) {
  if (!node) return null
  var p = nodeProps(node)
  var name = String(node.name || p["node.name"] || "").toLowerCase()
  // Match complete endpoints first: an IP prefix can name a different room.
  for (var i = 0; i < peers.length; i++) {
    var peer = peers[i]
    var endpoint = String(peer.hostname || "") + "." + String(peer.address || "") + "." + String(peer.port || "")
    if (name === "raop_sink." + endpoint.toLowerCase()
        || (peer.address && String(p["raop.ip"] || "") === peer.address)) return peer
  }
  var room = airplayRoomLabel(node).toLowerCase()
  var matches = peers.filter(function(peer) { return String(peer.name || "").toLowerCase() === room })
  return matches.length === 1 ? matches[0] : null
}

function uniqueAirplaySinks(nodes, peers, selected) {
  var result = [], keys = []
  nodes.forEach(function(node) {
    if (String(node.name || "").indexOf("foamy_airplay_group_") === 0) return
    var peer = airplayPeerForSink(node, peers)
    var key = peer ? String(peer.hostname).toLowerCase() + ":" + peer.port : node.name
    var index = keys.indexOf(key)
    if (index < 0) { keys.push(key); result.push(node) }
    // Keep the active endpoint when multiple interfaces expose one receiver.
    else if (selected && node.name === selected.name) result[index] = node
  })
  return result
}

function cleanAirplayLabel(text) {
  var label = String(text || "").trim()
  if (!label) return ""
  label = label.replace(/\\032/g, " ")
  label = label.replace(/^raop[_. -]*sink[_. -]*/i, "")
  label = label.replace(/\.local(?:\..*)?$/i, "")
  label = label.replace(/^[0-9a-f]{12}@/i, "")
  label = label.replace(/^[0-9a-f]{2}(?:[:-]?[0-9a-f]{2}){5}@/i, "")
  label = label.replace(/^airplay\s+(?:to\s+)?/i, "")
  return friendlyDeviceLabel(label)
}

function airplayRoomLabel(node) {
  if (!node) return "AirPlay speaker"
  var p = nodeProps(node)
  var values = [
    p["raop.name"],
    node.nickname,
    p["node.nick"],
    node.description,
    p["node.description"],
    node.name,
    p["node.name"]
  ]
  for (var i = 0; i < values.length; i++) {
    var label = cleanAirplayLabel(values[i])
    if (label && label.toLowerCase() !== "airplay") return label
  }
  return "AirPlay speaker"
}

function airplayDeviceDetail(node) {
  if (!node) return ""
  var p = nodeProps(node)
  var hostname = String(p["raop.hostname"] || p["device.string"] || node.name || "")
  var vendor = friendlyDeviceLabel(p["device.vendor.name"] || "")
  if (!vendor && /sonos/i.test(hostname)) vendor = "Sonos"

  var model = friendlyDeviceLabel(
    p["device.model"] || p["raop.model"] || p["device.product.name"] || ""
  )
  var room = airplayRoomLabel(node).toLowerCase()
  if (model.toLowerCase() === room) model = ""

  var product = [vendor, model].filter(function(value, index, values) {
    return value && values.indexOf(value) === index
  }).join(" ")
  return product
}

function airplayPeerDetail(peer) {
  if (!peer) return ""
  var vendor = friendlyDeviceLabel(peer.vendor || "")
  var model = friendlyDeviceLabel(peer.model || "")
  if (/^AppleTV/i.test(String(peer.model || ""))) {
    vendor = "Apple"
    model = "TV"
  }
  var product = [vendor, model].filter(function(value, index, values) {
    return value && values.indexOf(value) === index
  }).join(" ")
  return product
}

function isHeadphones(node, bluetoothDevices) {
  if (!node) return false
  var p = nodeProps(node)
  var description = String(node.description || p["node.description"] || "")

  // Gaming headsets expose their routing role in the node description even
  // when Quickshell has not made the extended PipeWire properties available.
  if (/\s(?:game|gaming|chat)$/i.test(description)) return true

  var blob = String([
    node.name, node.description, node.nickname,
    p["device.icon-name"] || "",
    p["device.product.name"] || "",
    p["device.profile-set"] || "",
    p["device.profile.name"] || "",
    p["device.profile.description"] || "",
    p["node.description"] || "",
    p["node.nick"] || ""
  ].join(" ")).toLowerCase()
  if (blob.indexOf("headphone") !== -1
    || blob.indexOf("headset") !== -1
    || blob.indexOf("earbud") !== -1
    || blob.indexOf("earphone") !== -1
    || blob.indexOf("airpod") !== -1
    || /\b(?:game|gaming|chat)\b/.test(blob)) return true

  // PipeWire often labels a Bluetooth headset only by product name. Match its
  // BlueZ address and use the semantic icon instead of guessing from branding.
  return bluetoothDeviceIsHeadset(bluetoothDeviceForSink(node, bluetoothDevices))
}

function sinkGlyph(node, bluetoothDevices) {
  if (!node) return "󰓃"
  if (isHeadphones(node, bluetoothDevices)) return "󰋋"
  if (bluetoothDeviceForSink(node, bluetoothDevices)) return "󰂯"
  var p = nodeProps(node)
  var blob = String([
    node.name, node.description, node.nickname,
    p["device.icon-name"] || "",
    p["device.product.name"] || ""
  ].join(" ")).toLowerCase()
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("hdmi") !== -1 || blob.indexOf("display") !== -1) return "󰍹"
  return "󰓃"
}

function sourceGlyph(node) {
  if (!node) return "󰍬"
  var p = nodeProps(node)
  var blob = String([
    node.name, node.description, node.nickname,
    p["device.icon-name"] || ""
  ].join(" ")).toLowerCase()
  if (blob.indexOf("headset") !== -1) return "󰋋"
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("webcam") !== -1 || blob.indexOf("camera") !== -1) return "󰄀"
  return "󰍬"
}

function friendlyStreamLabel(label) {
  label = String(label || "").trim()
  if (!label) return ""

  var known = {
    "spotify": "Spotify"
  }
  var normalized = label.toLowerCase()
  return known[normalized] || label
}

function streamLabelKey(label) {
  return String(label || "").trim().toLowerCase()
}

function streamLabelIsGeneric(label) {
  return streamLabelKey(label) === "audio-src"
}

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"]
    || node.description
    || p["media.name"]
    || p["node.name"]
    || node.name
}

function mprisPlayerLabel(player) {
  if (!player) return ""
  return friendlyStreamLabel(player.identity || player.desktopEntry || "")
}

function mprisPlayerIsProxy(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
  var streamKey = streamLabelKey(friendlyStreamLabel(streamLabel))
  var playerKey = streamLabelKey(playerLabel)
  if (!streamKey || !playerKey) return false
  return streamKey === playerKey
    || streamKey.indexOf(playerKey) !== -1
    || playerKey.indexOf(streamKey) !== -1
}

function mprisLabelsFor(players, predicate) {
  var values = Array.isArray(players) ? players : []
  var playingCandidates = []
  var candidates = []
  var playingProxyCandidates = []
  var proxyCandidates = []

  for (var i = 0; i < values.length; i++) {
    var player = values[i]
    if (!player) continue
    if (!player.isPlaying && !player.canPlay) continue

    var playerLabel = mprisPlayerLabel(player)
    if (!playerLabel || !predicate(playerLabel)) continue

    if (mprisPlayerIsProxy(player)) {
      if (player.isPlaying) playingProxyCandidates.push(playerLabel)
      proxyCandidates.push(playerLabel)
    } else {
      if (player.isPlaying) playingCandidates.push(playerLabel)
      candidates.push(playerLabel)
    }
  }

  if (playingCandidates.length === 1) return playingCandidates[0]
  if (playingCandidates.length === 0 && playingProxyCandidates.length === 1) return playingProxyCandidates[0]
  if (candidates.length === 1) return candidates[0]
  if (candidates.length === 0 && proxyCandidates.length === 1) return proxyCandidates[0]
  return ""
}

function matchingMprisStreamLabel(label, players) {
  if (streamLabelIsGeneric(label)) return ""
  return mprisLabelsFor(players, function(playerLabel) {
    return streamRepresentsMprisPlayer(label, playerLabel)
  })
}

function unmatchedMprisStreamLabel(label, players, streams) {
  if (!streamLabelIsGeneric(label)) return ""

  return mprisLabelsFor(players, function(playerLabel) {
    var values = Array.isArray(streams) ? streams : []
    for (var i = 0; i < values.length; i++) {
      var stream = values[i]
      var streamLabel = rawStreamLabel(stream)
      if (!streamLabelIsGeneric(streamLabel) && streamRepresentsMprisPlayer(streamLabel, playerLabel))
        return false
    }
    return true
  })
}

function streamLabel(node, players, streams) {
  if (!node) return "Stream"
  var label = rawStreamLabel(node)
  return friendlyStreamLabel(matchingMprisStreamLabel(label, players)
    || unmatchedMprisStreamLabel(label, players, streams)
    || label) || "Stream"
}

function streamRepresentsPlayer(node, player, players, streams) {
  if (!node || !player) return false
  var playerLabel = mprisPlayerLabel(player)
  if (!playerLabel) return false

  var label = rawStreamLabel(node)
  if (!streamLabelIsGeneric(label)) return streamRepresentsMprisPlayer(label, playerLabel)
  return streamRepresentsMprisPlayer(streamLabel(node, players, streams), playerLabel)
}

if (typeof module !== "undefined") {
  module.exports = {
    isPlaybackStream: isPlaybackStream,
    isAudioSource: isAudioSource,
    listSnapshot: listSnapshot,
    outputVolumeName: outputVolumeName,
    parseSinkAvailability: parseSinkAvailability,
    friendlyDeviceLabel: friendlyDeviceLabel,
    nodeProps: nodeProps,
    normalizedBluetoothAddress: normalizedBluetoothAddress,
    bluetoothSinkMatchesDevice: bluetoothSinkMatchesDevice,
    bluetoothDeviceForSink: bluetoothDeviceForSink,
    bluetoothDeviceIsHeadset: bluetoothDeviceIsHeadset,
    nodeLabel: nodeLabel,
    isAirplaySink: isAirplaySink,
    airplayPeerForSink: airplayPeerForSink,
    uniqueAirplaySinks: uniqueAirplaySinks,
    cleanAirplayLabel: cleanAirplayLabel,
    airplayRoomLabel: airplayRoomLabel,
    airplayDeviceDetail: airplayDeviceDetail,
    airplayPeerDetail: airplayPeerDetail,
    isHeadphones: isHeadphones,
    sinkGlyph: sinkGlyph,
    sourceGlyph: sourceGlyph,
    friendlyStreamLabel: friendlyStreamLabel,
    streamLabelKey: streamLabelKey,
    streamLabelIsGeneric: streamLabelIsGeneric,
    rawStreamLabel: rawStreamLabel,
    mprisPlayerLabel: mprisPlayerLabel,
    mprisPlayerIsProxy: mprisPlayerIsProxy,
    streamRepresentsMprisPlayer: streamRepresentsMprisPlayer,
    mprisLabelsFor: mprisLabelsFor,
    matchingMprisStreamLabel: matchingMprisStreamLabel,
    unmatchedMprisStreamLabel: unmatchedMprisStreamLabel,
    streamLabel: streamLabel,
    streamRepresentsPlayer: streamRepresentsPlayer
  }
}
