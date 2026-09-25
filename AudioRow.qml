import QtQuick
import qs.Commons

Rectangle {
  id: root
  required property var node
  property var volumeNode: node
  property string label: ""
  property string iconName: "speaker"
  property bool selected: false
  property bool stream: false
  property bool showLevelMeter: false
  property real level: 0
  property string levelDescription: ""
  readonly property bool levelVisible: showLevelMeter && selected
  readonly property real levelInset: levelVisible ? Style.space(12) : 0
  readonly property real contentCenterY: narrow ? Style.space(21) : height / 2
  property real step: 0.03
  property color secondary: Color.popups.text
  readonly property bool narrow: width < Style.space(310)
  property real wheelAccumulator: 0
  signal activated()
  signal muteRequested()
  implicitHeight: Style.space(narrow ? 64 : 42)
  radius: Style.space(8)
  color: selected ? Qt.alpha(Color.accent,0.11) : hover.hovered || activeFocus ? Qt.alpha(Color.accent,0.06) : "transparent"
  border.width: activeFocus ? 1 : 0
  border.color: Color.accent
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: label
  Accessible.onPressAction: activated()
  function adjust(delta) {
    if (volumeNode && volumeNode.audio) volumeNode.audio.volume = Math.max(0,Math.min(stream ? 1.5 : 1,volumeNode.audio.volume+delta))
  }
  Keys.onPressed: function(event) {
    if (event.key===Qt.Key_Return || event.key===Qt.Key_Enter || event.key===Qt.Key_Space) { activated();event.accepted=true }
    else if (event.key===Qt.Key_Left || event.key===Qt.Key_H) { adjust(-step);event.accepted=true }
    else if (event.key===Qt.Key_Right || event.key===Qt.Key_L) { adjust(step);event.accepted=true }
    else if (event.key===Qt.Key_M) { muteRequested();event.accepted=true }
  }
  HoverHandler { id:hover }
  // Selection owns the row; the slider is a later sibling and consumes its own pointer input.
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.forceActiveFocus();root.activated() }
    onWheel: function(event) {
      var result=Util.wheelSteps(root.wheelAccumulator,event.angleDelta.y)
      root.wheelAccumulator=result.remainder
      if(result.steps)root.adjust(result.steps*root.step)
      event.accepted=true
    }
  }
  AudioIcon { id:icon; x:Style.space(10);y:root.contentCenterY-height/2;width:Style.space(16);height:width;name:root.iconName;color:Color.popups.text }
  Text {
    id: nameLabel
    x: Style.space(34)
    y: root.contentCenterY-height/2
    width: Math.max(0,root.width-x-(root.narrow ? Style.space(50) : deviceVolume.width+root.levelInset+Style.space(18))-(root.selected ? Style.space(18):0))
    text: root.label
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: Color.popups.text
    font.family: "sans-serif"
    font.pixelSize: Style.space(12)
  }
  AudioIcon { visible:root.selected;x:nameLabel.x+Math.min(nameLabel.implicitWidth,nameLabel.width)+Style.space(5);y:root.contentCenterY-height/2;width:Style.space(12);height:width;name:"check";color:Color.accent }
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
    x: root.narrow ? Style.space(34) : root.width-width-Style.space(10)-root.levelInset
    y: root.narrow ? Style.space(33) : (root.height-height)/2
    width: root.narrow ? root.width-x-Style.space(10)-root.levelInset : implicitWidth
    node: root.volumeNode
    label: root.label
    revealed: hover.hovered || root.activeFocus
    maximum: root.stream ? 1.5 : 1
    step: root.step
    secondary: root.secondary
    onMuteRequested: root.muteRequested()
  }
}
