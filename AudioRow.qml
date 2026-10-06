import QtQuick
import QtQuick.Controls.Basic as Controls
import qs.Commons
import qs.Ui

Rectangle {
  id: root
  required property var node
  property var volumeNode: node
  property string label: ""
  property string iconName: "speaker"
  property url iconSource: ""
  property bool selected: false
  property bool multiSelect: false
  property bool stream: false
  property bool volumeVisible: true
  property bool showLevelMeter: false
  property real level: 0
  property string levelDescription: ""
  readonly property bool levelVisible: showLevelMeter && selected
  readonly property real levelInset: levelVisible ? Style.space(12) : 0
  readonly property real contentCenterY: narrow ? Style.space(21) : height / 2
  property real step: 0.03
  property color secondary: Color.popups.text
  readonly property bool narrow: width < Style.space(310)
  readonly property real selectionInset: multiSelect ? Style.space(26) : 0
  readonly property bool rowFocused: activeFocus || selectionBox.activeFocus
  signal activated()
  signal muteRequested()
  implicitHeight: Style.space(narrow && volumeVisible ? 64 : 42)
  radius: Style.cornerRadius * 2
  color: selected ? Qt.alpha(Color.accent,0.11) : hover.hovered || rowFocused ? Qt.alpha(Color.accent,0.06) : "transparent"
  border.width: rowFocused ? 1 : 0
  border.color: Color.accent
  activeFocusOnTab: !multiSelect
  Accessible.role: multiSelect ? Accessible.NoRole : Accessible.Button
  Accessible.name: multiSelect ? "" : label
  Accessible.onPressAction: activated()
  function adjust(delta) {
    if (volumeVisible && volumeNode && volumeNode.audio) volumeNode.audio.volume = Math.max(0,Math.min(stream ? 1.5 : 1,volumeNode.audio.volume+delta))
  }
  Keys.onPressed: function(event) {
    if (event.key===Qt.Key_Return || event.key===Qt.Key_Enter || event.key===Qt.Key_Space) { activated();event.accepted=true }
    else if (event.key===Qt.Key_Left || event.key===Qt.Key_H) { adjust(-step);event.accepted=true }
    else if (event.key===Qt.Key_Right || event.key===Qt.Key_L) { adjust(step);event.accepted=true }
    else if (event.key===Qt.Key_M && volumeVisible) { muteRequested();event.accepted=true }
  }
  HoverHandler { id:hover }
  // Selection owns the row; the slider is a later sibling and consumes its own pointer input.
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: { if (root.multiSelect) selectionBox.forceActiveFocus(); else root.forceActiveFocus(); root.activated() }
    onWheel: function(event) { event.accepted=false }
  }
  Controls.CheckBox {
    id: selectionBox
    visible: root.multiSelect
    x: Style.space(6)
    y: root.contentCenterY-height/2
    width: Style.space(24)
    height: Style.space(30)
    padding: 0
    checked: root.selected
    focusPolicy: Qt.StrongFocus
    Accessible.name: root.label
    // Routing confirms selection asynchronously; never show an unconfirmed tick.
    nextCheckState: function() { return root.selected ? Qt.Checked : Qt.Unchecked }
    onClicked: root.activated()
    Keys.onReturnPressed: root.activated()
    Keys.onEnterPressed: root.activated()
    Keys.forwardTo: [root]
    contentItem: Item {}
    background: Item {}
    // Keep the selection checkbox aligned with the popup controls.
    indicator: BorderSurface {
      x: (selectionBox.width-width)/2
      y: (selectionBox.height-height)/2
      width: Style.space(16)
      height: width
      radius: Style.cornerRadius * 2
      color: root.selected ? Style.selectedFillFor(Color.popups.text, Color.accent) : "transparent"
      borderSpec: Border.controlSpec(root.selected ? "selected" : "normal", Color.popups.text, Color.accent)
      Text {
        anchors.centerIn: parent
        visible: root.selected
        text: "✓"
        color: Style.selectedStateColor(Color.popups.text, Color.accent)
        font.family: Style.font.family
        font.pixelSize: Math.round(parent.height*0.85)
        font.bold: true
      }
    }
  }
  AudioIcon { id:icon; visible:appIcon.status!==Image.Ready;x:Style.space(10)+root.selectionInset;y:root.contentCenterY-height/2;width:Style.space(16);height:width;name:root.iconName;color:Color.popups.text }
  Image {
    id: appIcon
    x: icon.x
    y: icon.y
    width: icon.width
    height: icon.height
    source: root.iconSource
    sourceSize.width: Math.ceil(width*2)
    sourceSize.height: Math.ceil(height*2)
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    visible: status === Image.Ready
    opacity: root.stream && root.node && root.node.audio && root.node.audio.muted ? 0.45 : 1
  }
  Text {
    id: nameLabel
    x: Style.space(34)+root.selectionInset
    y: root.contentCenterY-height/2
    width: Math.max(0,root.width-x-(root.narrow || !root.volumeVisible ? Style.space(18) : deviceVolume.width+root.levelInset+Style.space(18))-(root.selected && !root.multiSelect ? Style.space(18):0))
    text: root.label
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: Color.popups.text
    font.family: "sans-serif"
    font.pixelSize: Style.space(12)
  }
  AudioIcon { visible:root.selected&&!root.multiSelect;x:nameLabel.x+Math.min(nameLabel.implicitWidth,nameLabel.width)+Style.space(5);y:root.contentCenterY-height/2;width:Style.space(12);height:width;name:"check";color:Color.accent }
  Rectangle {
    id: levelMeter
    visible: root.levelVisible
    x: root.width-width-Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(3)
    height: Style.space(20)
    radius: width/2
    color: Qt.alpha(Color.popups.text,0.18)
    Accessible.name: root.label
    Accessible.description: root.levelDescription
    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: parent.height*Math.max(0,Math.min(1,root.level))
      radius: parent.radius
      color: Color.accent
      Behavior on height { NumberAnimation { duration:70 } }
    }
  }
  DeviceVolume {
    id: deviceVolume
    visible: root.volumeVisible
    enabled: visible
    x: root.narrow ? nameLabel.x : root.width-width-Style.space(10)-root.levelInset
    y: root.narrow ? Style.space(33) : (root.height-height)/2
    width: root.narrow ? root.width-x-Style.space(10)-root.levelInset : implicitWidth
    node: root.volumeNode
    label: root.label
    revealed: hover.hovered || root.rowFocused
    maximum: root.stream ? 1.5 : 1
    step: root.step
    secondary: root.secondary
    onMuteRequested: root.muteRequested()
  }
}
