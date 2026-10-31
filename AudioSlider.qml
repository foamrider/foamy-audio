import QtQuick
import QtQuick.Controls.Basic
import qs.Commons as Commons
import "kit"

// The volume slider: pointer only (the panel cursor drives keyboard volume
// with h/l), mirrored in RTL through Slider's own mirroring.
Slider {
  id: root
  property string label: ""
  property bool mini: false
  property bool revealed: true
  from: 0
  to: 1
  stepSize: 0.01
  wheelEnabled: false
  focusPolicy: Qt.NoFocus
  implicitHeight: Commons.Style.space(24)
  padding: 0
  opacity: revealed || pressed ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: FoamyMotion.hover } }
  Accessible.name: label
  background: Rectangle {
    x: root.leftPadding
    y: (root.height - height) / 2
    width: root.availableWidth
    height: Commons.Style.space(root.mini ? 3 : 4)
    radius: height / 2
    color: Qt.alpha(Commons.Color.popups.text, 0.18)
    Rectangle {
      // Fill represents volume; visualPosition includes the mirrored handle position.
      x: root.mirrored ? parent.width - width : 0
      width: root.position * parent.width
      height: parent.height
      radius: parent.radius
      color: Commons.Color.accent
    }
  }
  handle: Rectangle {
    x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
    y: (root.height - height) / 2
    width: Commons.Style.space(root.mini ? 8 : 11)
    height: width
    radius: width / 2
    color: Commons.Color.popups.text
  }
}
