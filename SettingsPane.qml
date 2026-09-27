import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Preferences.js" as Preferences

Item {
  id: root
  required property var settings
  required property string language
  property bool saving: false
  property string error: ""
  property alias backTarget: backButton
  signal save(string key, var value)
  signal back()
  signal clearError()
  function tr(label) { return Preferences.text(label,language) }
  function focusBack() { backButton.forceActiveFocus() }
  property string firewallState: ""
  property string firewallMessage: ""
  onVisibleChanged: {
    if (visible && !firewallProcess.running) {
      firewallState = ""
      firewallMessage = ""
    }
  }
  function checkFirewall(action) {
    if (firewallProcess.running) return
    firewallState = ""
    firewallMessage = ""
    firewallProcess.command = ["python3", decodeURIComponent(Qt.resolvedUrl("ufw_check.py").toString().replace(/^file:\/\//, "")), action]
    firewallProcess.running = true
  }
  Process {
    id: firewallProcess
    stdout: StdioCollector { id: firewallOutput; waitForEnd: true }
    stderr: StdioCollector { id: firewallError; waitForEnd: true }
    onExited: function(code) {
      try {
        var result = JSON.parse(firewallOutput.text)
        if (!result.state || typeof result.message !== "string" || typeof result.details !== "string")
          throw new Error("Invalid UFW helper response")
        root.firewallState = code === 0 ? result.state : "error"
        var messages = {
          open: "Required ports are open.",
          restricted: "Rules are restricted. Apply to open the ports.",
          missing: "Rules are missing. Apply to open the ports.",
          conflict: "Rules conflict. Review UFW rules.",
          inactive: "UFW is inactive."
        }
        root.firewallMessage = result.details === "Administrator authorization was cancelled or denied."
          ? "Authorization cancelled or denied." : messages[root.firewallState] || result.message
        if (code !== 0) console.warn("Foamy Audio UFW:", result.details)
      } catch (error) {
        root.firewallState = "error"
        root.firewallMessage = "Could not complete the UFW check."
        console.warn("Foamy Audio UFW:", firewallError.text.trim() || String(error))
      }
    }
  }
  readonly property color secondary: Qt.tint(Color.popups.background,Qt.alpha(Color.popups.text,0.7))
  readonly property int padding: Style.space(20)
  implicitHeight: settingsHeader.height + settingsBody.implicitHeight
  function resetScroll() { settingsScroll.contentY = 0 }
  function keepFocusVisible(item) {
    var ancestor = item
    while (ancestor && ancestor !== settingsScroll.contentItem) ancestor = ancestor.parent
    if (!ancestor) return
    var point = item.mapToItem(settingsScroll.contentItem, 0, 0)
    if (point.y < settingsScroll.contentY) settingsScroll.contentY = Math.max(0, point.y-Style.space(8))
    else if (point.y+item.height > settingsScroll.contentY+settingsScroll.height)
      settingsScroll.contentY = Math.max(0, Math.min(settingsScroll.contentHeight-settingsScroll.height, point.y+item.height-settingsScroll.height+Style.space(8)))
  }
  Connections {
    target: root.Window.window
    function onActiveFocusItemChanged() { root.keepFocusVisible(target.activeFocusItem) }
  }
  Item {
    id: settingsHeader
    width: parent.width
    height: settingsHeaderRow.implicitHeight + root.padding*2
    RowLayout {
      id: settingsHeaderRow
      anchors.centerIn: parent
      width: root.width-root.padding*2
      AudioAction { id:backButton; iconName:"arrow-left"; foreground:root.secondary; tooltipText:root.tr("Back"); onClicked:root.back() }
      Text { text:root.tr("Settings"); color:root.secondary; font.family:"sans-serif"; font.pixelSize:Style.space(13); Layout.fillWidth:true }
      Text { visible:root.saving; text:root.tr("Saving…"); color:root.secondary; font.family:"sans-serif"; font.pixelSize:Style.space(11) }
    }
  }
  Flickable {
    id: settingsScroll
    anchors.top: settingsHeader.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: settingsBody.implicitHeight
    clip: true
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight-height))
    onHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight-height))
    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
    Column {
      id: settingsBody
      width: parent.width
      leftPadding: root.padding
      rightPadding: root.padding
      bottomPadding: root.padding
      spacing: Style.space(14)
      Text {
        width: root.width-root.padding*2
        visible: root.error!==""
        text: root.error
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Color.urgent
        font.family: "sans-serif"
        font.pixelSize: Style.space(12)
        Accessible.role: Accessible.AlertMessage
      }
      Repeater {
        model: Preferences.fields
        Column {
          id: fieldRow
          required property var modelData
          readonly property var current: Preferences.value(root.settings,modelData.key)
          width: root.width-root.padding*2
          enabled: !root.saving
          opacity: enabled ? 1 : 0.55
          AudioDropdown {
            width: parent.width
            visible: fieldRow.modelData.type==="enum"
            label: root.tr(fieldRow.modelData.label)
            fontFamily: "sans-serif"
            value: String(fieldRow.current)
            options: (fieldRow.modelData.options || []).map(function(v) { return {value:v,label:root.tr(Preferences.optionLabel(v))} })
            onChanged: function(value) { root.save(fieldRow.modelData.key,value) }
          }
          Toggle {
            width: parent.width
            visible: fieldRow.modelData.type==="boolean"
            implicitHeight: Style.space(36)
            color: "transparent"
            borderSpec: activeFocus ? Border.flat(Color.accent,1) : Border.none()
            radius: Style.space(7)
            fontFamily: "sans-serif"
            titleSize: Style.space(13)
            label: root.tr(fieldRow.modelData.label)
            checked: fieldRow.current===true
            onClicked: root.save(fieldRow.modelData.key,!checked)
          }
          RowLayout {
            width: parent.width
            visible: fieldRow.modelData.type==="integer"
            spacing: Style.space(12)
            Text {
              Layout.fillWidth:true
              text:root.tr(fieldRow.modelData.label)
              wrapMode:Text.WordWrap
              color:Color.popups.text
              font.family:"sans-serif"
              font.pixelSize:Style.space(13)
            }
            Controls.TextField {
              id: input
              Layout.preferredWidth: Style.space(68)
              implicitHeight: Style.space(34)
              text: String(fieldRow.current)
              selectByMouse:true
              color:Color.popups.text
              font.family:"sans-serif"
              font.pixelSize:Style.space(12)
              padding:Style.space(7)
              Accessible.name:root.tr(fieldRow.modelData.label)
              background: Rectangle { radius:Style.space(7); color:Qt.alpha(Color.popups.text,0.055); border.width:input.activeFocus?1:0; border.color:Color.accent }
              onTextEdited:root.clearError()
              onEditingFinished: {
                if (!visible) return
                var next=text.trim()===""?NaN:Number(text)
                if (next!==fieldRow.current) root.save(fieldRow.modelData.key,next)
              }
              Keys.onEscapePressed: { text=String(fieldRow.current); root.back() }
              HoverHandler { id:numberHover }
              PanelToolTip { visible:numberHover.hovered||input.activeFocus; text:fieldRow.modelData.min+"–"+fieldRow.modelData.max; fontFamily:"sans-serif" }
            }
          }
        }
      }
      Column {
        width: root.width-root.padding*2
        spacing: Style.space(10)
        Text {
          text: root.tr("Advanced")
          color: root.secondary
          font.family: "sans-serif"
          font.pixelSize: Style.space(13)
        }
        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          Text {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.tr("Firewall rules")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Color.popups.text
            font.family: "sans-serif"
            font.pixelSize: Style.space(12)
          }
          AudioAction {
            label: root.tr("Verify")
            iconName: ""
            foreground: root.secondary
            enabled: !firewallProcess.running
            tooltipText: root.tr("Read-only check. Requests administrator authorization.")
            onClicked: root.checkFirewall("verify")
          }
          AudioAction {
            label: root.tr("Apply")
            iconName: ""
            foreground: root.secondary
            enabled: !firewallProcess.running && root.firewallState !== "open"
            tooltipText: root.tr("Add an unrestricted UDP 6001–6002 rule. Requests administrator authorization.")
            onClicked: root.checkFirewall("open")
          }
        }
        Text {
          width: parent.width
          visible: firewallProcess.running || root.firewallMessage !== ""
          text: firewallProcess.running ? root.tr("Checking…") : root.tr(root.firewallMessage)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.firewallState === "error" || root.firewallState === "conflict" ? Color.urgent : root.secondary
          font.family: "sans-serif"
          font.pixelSize: Style.space(12)
          Accessible.role: Accessible.StaticText
        }
      }
    }
  }
}
