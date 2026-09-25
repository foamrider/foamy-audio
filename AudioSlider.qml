import QtQuick
import QtQuick.Controls.Basic
import qs.Commons

Slider {
  id: root
  property string label: ""
  property bool mini: false
  property bool revealed: true
  readonly property bool dragging: pressed
  signal muteRequested()
  from: 0
  to: 1
  stepSize: 0.01
  wheelEnabled: false
  focusPolicy: Qt.StrongFocus
  implicitHeight: Style.space(24)
  padding: 0
  opacity: revealed || pressed || activeFocus ? 1 : 0
  Accessible.name: label
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_M) { muteRequested(); event.accepted = true }
  }
  background: Rectangle {
    x: root.leftPadding
    y: (root.height-height)/2
    width: root.availableWidth
    height: Style.space(root.mini ? 3 : 4)
    radius: height/2
    color: Qt.alpha(Color.popups.text,0.18)
    Rectangle { width:root.visualPosition*parent.width; height:parent.height; radius:parent.radius; color:Color.accent }
  }
  handle: Rectangle {
    x: root.leftPadding+root.visualPosition*(root.availableWidth-width)
    y: (root.height-height)/2
    width: Style.space(root.mini ? 8 : 11)
    height: width
    radius: width/2
    color: Color.popups.text
  }
}
