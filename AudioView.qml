pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons as Commons
import qs.Ui
import "kit"

// The popup body: header, output volume, the Output/Input/Apps/Wireless
// sections, "Mute all", and the settings page. Everything comes from `audio`
// (the Panel, or the preview's mock), so this file never touches PipeWire.
//
// Keyboard (one cursor, hover moves it too): arrows/hjkl move, h/l change the
// volume of the cursor row (or move along the header buttons), Enter/Space
// activate, m mutes the cursor target, o/i/a/w fold sections, s opens
// Settings, Tab/Shift-Tab switch bar panels, Esc closes (or leaves Settings).
PanelKeyCatcher {
  id: view

  required property var audio

  readonly property bool editing: audio.editingSettings === true
  readonly property bool rtl: FoamyI18n.rightToLeft
  readonly property real step: audio.volumeStep || 0.05

  property bool outputExpanded: true
  property bool inputExpanded: true
  property bool appsExpanded: false
  property bool wirelessExpanded: false

  implicitWidth: FoamyStyle.popupWidth
  implicitHeight: editing ? settingsPage.implicitHeight
    : band.implicitHeight + FoamyStyle.gap + listColumn.implicitHeight + footer.height
  blocked: editing

  function resetView() {
    outputExpanded = true
    inputExpanded = true
    appsExpanded = false
    wirelessExpanded = audio.airplayActive === true
    cursor.reset()
    scroll.contentY = 0
  }
  Component.onCompleted: resetView()
  Connections {
    target: view.audio
    ignoreUnknownSignals: true
    function onOpenedChanged() { if (view.audio.opened) view.resetView() }
    function onAirplayActiveChanged() { if (view.audio.airplayActive) view.wirelessExpanded = true }
    function onEditingSettingsChanged() {
      if (view.editing) Qt.callLater(function() { settingsPage.resetScroll(); settingsPage.focusBack() })
      else view.forceActiveFocus()
    }
  }

  // ---- Cursor stops ------------------------------------------------------
  readonly property var headerStops: ["outputMute", "inputMute", "settings"]
  readonly property var stops: {
    var list = headerStops.concat(["volume", "section:output"])
    function add(kind, rows, expanded) { if (expanded) for (var i = 0; i < rows.length; i++) list.push(kind + ":" + i) }
    add("sink", audio.displayAudioSinks, outputExpanded)
    list.push("section:input")
    add("source", audio.displayAudioSources, inputExpanded)
    list.push("section:apps")
    add("stream", audio.displayAudioStreams, appsExpanded)
    list.push("section:wireless")
    add("wireless", audio.displayWirelessAudioSinks, wirelessExpanded)
    list.push("muteAll")
    return list
  }
  readonly property string cursorKey: cursor.index >= 0 && cursor.index < stops.length ? stops[cursor.index] : ""

  FoamyCursor { id: cursor; count: view.stops.length }

  function hasCursor(key) { return cursorKey === key }
  function hover(key) { var index = stops.indexOf(key); if (index >= 0) cursor.hover(index) }
  function rowsFor(kind) {
    return kind === "sink" ? audio.displayAudioSinks : kind === "source" ? audio.displayAudioSources
      : kind === "stream" ? audio.displayAudioStreams : audio.displayWirelessAudioSinks
  }
  function cursorRow() {
    var parts = cursorKey.split(":")
    if (parts.length !== 2 || parts[0] === "section") return null
    var node = audio.nodeFor(rowsFor(parts[0])[Number(parts[1])])
    return node ? { kind: parts[0], node: node, target: audio.volumeTarget(parts[0], node) } : null
  }
  function toggleSection(name) {
    if (name === "output") outputExpanded = !outputExpanded
    else if (name === "input") inputExpanded = !inputExpanded
    else if (name === "apps") appsExpanded = !appsExpanded
    else if (name === "wireless") wirelessExpanded = !wirelessExpanded
  }
  function activateStop() {
    var key = cursorKey
    if (key === "outputMute" || key === "volume") audio.toggleOutputMute()
    else if (key === "inputMute") audio.toggleInputMute()
    else if (key === "settings") audio.openSettings()
    else if (key === "muteAll") audio.toggleAllMuted()
    else if (key.indexOf("section:") === 0) toggleSection(key.slice(8))
    else { var row = cursorRow(); if (row) audio.activate(row.kind, row.node) }
  }
  function adjust(direction) {
    var key = cursorKey
    if (headerStops.indexOf(key) >= 0) {
      cursor.index = Math.max(0, Math.min(headerStops.length - 1, cursor.index + direction))
    } else if (key === "volume") {
      audio.setOutputVolume(audio.outputVolume + direction * step)
    } else {
      var row = cursorRow()
      if (!row || !audio.nodeHasVolume(row.target)) return
      if (row.kind === "wireless" && !audio.isSelected(row.kind, row.node)) return
      audio.setNodeVolume(row.target, audio.nodeVolume(row.target) + direction * step, row.kind === "stream" ? 1.5 : 1)
    }
  }
  function muteStop() {
    var key = cursorKey
    if (key === "inputMute") audio.toggleInputMute()
    else if (key === "muteAll") audio.toggleAllMuted()
    else { var row = cursorRow(); if (row) audio.toggleNodeMute(row.target); else audio.toggleOutputMute() }
  }
  function keepVisible(item) {
    if (!item || !scroll.contentItem) return
    var point = item.mapToItem(scroll.contentItem, 0, 0)
    var margin = FoamyStyle.gap
    if (point.y < scroll.contentY) scroll.contentY = Math.max(0, point.y - margin)
    else if (point.y + item.height > scroll.contentY + scroll.height)
      scroll.contentY = Math.min(Math.max(0, scroll.contentHeight - scroll.height), point.y + item.height - scroll.height + margin)
  }

  onMoveRequested: function(dx, dy) {
    if (dy !== 0) {
      if (!cursor.active) cursor.index = stops.indexOf("volume")
      else cursor.move(dy)
    } else if (dx !== 0) {
      if (!cursor.active) { cursor.index = stops.indexOf("volume"); return }
      // The header row and every slider mirror in RTL, so visual direction wins.
      adjust(rtl ? -dx : dx)
    }
  }
  onActivateRequested: activateStop()
  onCloseRequested: audio.close()
  onTabRequested: function(direction) { audio.switchPanel(direction) }
  onTextKey: function(text) {
    var key = String(text).toLowerCase()
    if (key === "s") audio.openSettings()
    else if (key === "m") muteStop()
    else if (key === "o") toggleSection("output")
    else if (key === "i") toggleSection("input")
    else if (key === "a") toggleSection("apps")
    else if (key === "w") toggleSection("wireless")
  }

  // AirPlay scanning dots; static under reduced motion, nothing while hidden.
  property int scanStep: 3
  readonly property string scanDots: ["", ".", "..", "..."][scanStep]
  Timer {
    interval: 350
    repeat: true
    running: view.audio.airplayScanning === true && view.visible && !view.editing && !FoamyMotion.reduceMotion
    onRunningChanged: view.scanStep = running ? 0 : 3
    onTriggered: view.scanStep = (view.scanStep + 1) % 4
  }

  // ---- Main view ---------------------------------------------------------
  FoamyHeroBand {
    id: band
    visible: !view.editing
    width: parent.width
    iconName: view.audio.outputMuted ? "volume-x" : "volume-2"
    title: FoamyI18n.t("Audio")
    meta: view.audio.outputLabel || FoamyI18n.t("No output devices")
    settingsHasCursor: view.hasCursor("settings")
    onSettingsClicked: view.audio.openSettings()
    onSettingsHovered: function(hovered) { if (hovered) view.hover("settings") }
    trailing: [
      FoamyAction {
        iconName: view.audio.outputMuted ? "volume-x" : "volume-2"
        foreground: FoamyPalette.secondaryText
        enabled: view.audio.hasOutput
        hasCursor: view.hasCursor("outputMute")
        tooltipText: FoamyI18n.t(view.audio.outputMuted ? "Unmute output" : "Mute output")
        onHoveredChanged: if (hovered) view.hover("outputMute")
        onClicked: view.audio.toggleOutputMute()
      },
      FoamyAction {
        iconName: view.audio.inputMuted ? "mic-off" : "mic"
        foreground: view.audio.inputMuted ? Commons.Color.urgent : FoamyPalette.secondaryText
        enabled: view.audio.hasInput
        hasCursor: view.hasCursor("inputMute")
        tooltipText: FoamyI18n.t(view.audio.inputMuted ? "Unmute microphone" : "Mute microphone")
        onHoveredChanged: if (hovered) view.hover("inputMute")
        onClicked: view.audio.toggleInputMute()
      }
    ]
      // Hero slot: the output volume (numeral) and its slider, one cursor
      // stop. The cursor rings the slider's thumb; no filled row behind it.
      Item {
        id: hero
        Layout.fillWidth: true
        implicitHeight: heroRow.implicitHeight + FoamyStyle.gap * 2
        HoverHandler { onHoveredChanged: if (hovered) view.hover("volume") }
        RowLayout {
          id: heroRow
          anchors.fill: parent
          anchors.leftMargin: FoamyStyle.gap
          anchors.rightMargin: FoamyStyle.gap
          spacing: FoamyStyle.gapLarge
          Item {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: heroNumber.implicitWidth + (heroUnit.visible ? FoamyStyle.gapTiny + heroUnit.implicitWidth : 0)
            implicitHeight: heroNumber.implicitHeight
            opacity: view.audio.outputMuted ? 0.5 : 1
            Text {
              id: heroNumber
              anchors.left: parent.left
              text: view.audio.hasOutput ? FoamyI18n.number(Math.round(outputSlider.value * 100)) : "—"
              textFormat: Text.PlainText
              color: FoamyPalette.text
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.numeral
              font.weight: Font.DemiBold
              font.letterSpacing: -2
            }
            Text {
              id: heroUnit
              visible: view.audio.hasOutput
              anchors.left: heroNumber.right
              anchors.leftMargin: FoamyStyle.gapTiny
              anchors.baseline: heroNumber.baseline
              text: "%"
              textFormat: Text.PlainText
              color: FoamyPalette.secondaryText
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.display
            }
          }
          AudioSlider {
            id: outputSlider
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            label: FoamyI18n.t("Volume")
            hasCursor: view.hasCursor("volume")
            enabled: view.audio.hasOutput
            value: view.audio.hasOutput ? view.audio.outputVolume : 0
            onMoved: view.audio.setOutputVolume(value)
          }
        }
      }
  }

  Flickable {
    id: scroll
    visible: !view.editing
    anchors.top: band.bottom
    anchors.topMargin: FoamyStyle.gap
    anchors.bottom: footer.top
    width: parent.width
    clip: true
    contentWidth: width
    contentHeight: listColumn.implicitHeight
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

    Column {
      id: listColumn
      x: FoamyStyle.gapLarge
      width: scroll.width - FoamyStyle.gapLarge * 2
      bottomPadding: FoamyStyle.gap
      spacing: FoamyStyle.gapTiny

      Section {
        name: "output"
        label: FoamyI18n.t("Output")
        expanded: view.outputExpanded
        empty: view.audio.displayAudioSinks.length === 0
        emptyText: FoamyI18n.t("No output devices")
        Repeater {
          model: view.outputExpanded ? view.audio.displayAudioSinks : []
          Device { kind: "sink" }
        }
      }
      Section {
        name: "input"
        label: FoamyI18n.t("Input")
        expanded: view.inputExpanded
        empty: view.audio.displayAudioSources.length === 0
        emptyText: FoamyI18n.t("No input devices")
        errorText: view.audio.inputMeterError ? FoamyI18n.t(view.audio.inputMeterError) : ""
        Repeater {
          model: view.inputExpanded ? view.audio.displayAudioSources : []
          Device { kind: "source"; showLevelMeter: true; level: view.audio.inputMuted ? 0 : view.audio.inputPeak; levelDescription: FoamyI18n.t("Microphone level") }
        }
      }
      Section {
        name: "apps"
        label: FoamyI18n.t("Apps")
        expanded: view.appsExpanded
        empty: view.audio.displayAudioStreams.length === 0
        emptyText: FoamyI18n.t("No apps playing audio")
        Repeater {
          model: view.appsExpanded ? view.audio.displayAudioStreams : []
          Device { kind: "stream"; maximum: 1.5 }
        }
      }
      Section {
        name: "wireless"
        label: FoamyI18n.t("Wireless")
        expanded: view.wirelessExpanded
        empty: view.audio.airplayScanState === "error" || view.audio.displayWirelessAudioSinks.length === 0
        errorText: view.audio.airplayScanState === "error" ? FoamyI18n.t(view.audio.airplayError || "AirPlay discovery failed") : ""
        emptyText: view.audio.airplayScanState === "error" ? ""
          : view.audio.airplayScanning ? FoamyI18n.t("Looking for speakers") + view.scanDots
          : view.audio.airplayStopping ? FoamyI18n.t("Returning to local audio")
          : FoamyI18n.t("No AirPlay speakers found")
        Repeater {
          model: view.wirelessExpanded ? view.audio.displayWirelessAudioSinks : []
          Device { kind: "wireless"; multiSelect: true; enabled: !view.audio.airplaySelecting }
        }
      }
    }
  }

  Item {
    id: footer
    visible: !view.editing
    anchors.bottom: parent.bottom
    width: parent.width
    height: FoamyStyle.controlHeight + FoamyStyle.gapLarge * 2
    Rectangle {
      x: FoamyStyle.padding
      width: parent.width - FoamyStyle.padding * 2
      height: 1
      color: FoamyPalette.divider
    }
    FoamyAction {
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.padding
      anchors.verticalCenter: parent.verticalCenter
      iconName: view.audio.anyAudible ? "volume-x" : "volume-2"
      label: FoamyI18n.t(view.audio.anyAudible ? "Mute all" : "Unmute all")
      foreground: FoamyPalette.secondaryText
      enabled: view.audio.hasOutput || view.audio.hasInput
      hasCursor: view.hasCursor("muteAll")
      onHoveredChanged: if (hovered) view.hover("muteAll")
      onClicked: view.audio.toggleAllMuted()
    }
  }

  // ---- Settings ----------------------------------------------------------
  FoamySettingsPage {
    id: settingsPage
    visible: view.editing
    width: parent.width
    height: parent.height
    saving: view.audio.saving === true
    error: view.audio.settingsError ? FoamyI18n.t(view.audio.settingsError) : ""
    retryable: view.audio.settingsRetryable === true
    onBack: view.audio.closeSettings()
    onRetry: view.audio.retrySave()

    FoamySettingsSection {
      width: parent.width
      title: FoamyI18n.t("Bar")
      FoamyToggle {
        width: parent.width
        label: FoamyI18n.t("Show percentage in the bar")
        checked: view.audio.showPercentage === true
        enabled: !view.audio.saving
        onClicked: view.audio.save("showPercentage", !checked)
      }
    }

    FoamySettingsSection {
      width: parent.width
      title: FoamyI18n.t("AirPlay firewall")
      description: FoamyI18n.t("Speakers send timing data back on UDP 6001–6002. Apply allows only the network your speakers are on. Each action asks for administrator authorization.")
      RowLayout {
        width: parent.width
        spacing: FoamyStyle.gap
        FoamyAction {
          focusable: true
          iconName: ""
          label: FoamyI18n.t("Verify")
          foreground: FoamyPalette.secondaryText
          enabled: !view.audio.firewallBusy
          tooltipText: FoamyI18n.t("Read the UFW rules")
          onClicked: view.audio.firewallAction("verify")
        }
        FoamyAction {
          focusable: true
          iconName: ""
          label: FoamyI18n.t("Apply")
          foreground: FoamyPalette.secondaryText
          enabled: !view.audio.firewallBusy && view.audio.airplayPeerCount > 0 && view.audio.firewallState !== "open"
          tooltipText: view.audio.airplayPeerCount > 0
            ? FoamyI18n.tn("Allow the network of %1 speakers", view.audio.airplayPeerCount)
            : FoamyI18n.t("No AirPlay speakers found yet.")
          onClicked: view.audio.firewallAction("open")
        }
        FoamyAction {
          focusable: true
          iconName: ""
          label: FoamyI18n.t("Remove")
          foreground: FoamyPalette.secondaryText
          destructive: true
          enabled: !view.audio.firewallBusy
          tooltipText: FoamyI18n.t("Remove the rules Foamy Audio added")
          onClicked: view.audio.firewallAction("remove")
        }
        Item { Layout.fillWidth: true }
      }
      Text {
        width: parent.width
        visible: view.audio.firewallBusy || view.audio.firewallMessage !== ""
        text: view.audio.firewallBusy ? FoamyI18n.t("Checking…") : FoamyI18n.t(view.audio.firewallMessage)
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignLeft
        wrapMode: Text.WordWrap
        color: ["error", "conflict", "wide"].indexOf(view.audio.firewallState) >= 0 ? Commons.Color.urgent : FoamyPalette.secondaryText
        font.family: FoamyStyle.fontFamily
        font.pixelSize: FoamyStyle.font.bodySmall
        Accessible.role: view.audio.firewallState === "error" ? Accessible.AlertMessage : Accessible.StaticText
      }
    }
  }

  // ---- Building blocks ---------------------------------------------------
  component Section: Column {
    id: section
    property string name: ""
    property string label: ""
    property bool expanded: true
    property bool empty: false
    property string emptyText: ""
    property string errorText: ""
    default property alias rows: rowsColumn.data
    width: parent ? parent.width : 0
    spacing: FoamyStyle.gapTiny
    SectionHeader {
      id: sectionHeader
      width: parent.width
      label: section.label
      expanded: section.expanded
      hasCursor: view.hasCursor("section:" + section.name)
      onHovered: view.hover("section:" + section.name)
      onToggled: view.toggleSection(section.name)
      onHasCursorChanged: if (hasCursor) view.keepVisible(sectionHeader)
    }
    Text {
      visible: section.expanded && section.errorText !== ""
      x: FoamyStyle.rowPadding
      width: parent.width - FoamyStyle.rowPadding * 2
      text: section.errorText
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: Commons.Color.urgent
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      Accessible.role: Accessible.AlertMessage
    }
    Text {
      visible: section.expanded && section.empty && section.emptyText !== ""
      x: FoamyStyle.rowPadding
      width: parent.width - FoamyStyle.rowPadding * 2
      bottomPadding: FoamyStyle.gapSmall
      text: section.emptyText
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      wrapMode: Text.WordWrap
      color: FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
    }
    Column {
      id: rowsColumn
      width: parent.width
      spacing: FoamyStyle.gapTiny
    }
  }

  component Device: AudioRow {
    id: device
    required property var modelData
    required property int index
    property string kind: "sink"
    readonly property var node: view.audio.nodeFor(modelData)
    readonly property var target: view.audio.volumeTarget(kind, node)
    readonly property string key: kind + ":" + index
    width: parent ? parent.width : 0
    label: view.audio.rowLabel(kind, node)
    iconName: view.audio.rowIcon(kind, node)
    iconSource: kind === "stream" ? view.audio.streamIconSource(node) : ""
    dimmedIcon: kind === "stream" && view.audio.nodeMuted(node)
    selected: view.audio.isSelected(kind, node)
    volumeVisible: multiSelect ? selected : true
    volumeAvailable: view.audio.nodeHasVolume(target)
    volume: view.audio.nodeVolume(target)
    muted: view.audio.nodeMuted(target)
    step: 0.01
    hasCursor: view.hasCursor(key)
    onHovered: view.hover(key)
    onHasCursorChanged: if (hasCursor) view.keepVisible(device)
    onActivated: view.audio.activate(kind, node)
    onVolumeMoved: function(value) { view.audio.setNodeVolume(target, value, maximum) }
  }
}
