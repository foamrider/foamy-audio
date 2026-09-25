import QtQuick
import qs.Commons

Item {
  id: root
  required property var node
  property bool revealed: false
  property string label: ""
  property real maximum: 1
  property real step: 0.03
  property color secondary: Color.popups.text
  readonly property bool available: !!(node && node.audio)
  readonly property bool focused: slider.activeFocus
  readonly property bool dragging: slider.pressed
  signal muteRequested()
  implicitWidth: Style.space(114)
  implicitHeight: Style.space(26)
  opacity: !available || node.audio.muted ? 0.5 : 1
  AudioSlider {
    id: slider
    anchors.left: parent.left
    anchors.right: percent.left
    anchors.rightMargin: Style.space(7)
    anchors.verticalCenter: parent.verticalCenter
    mini: true
    revealed: root.revealed
    enabled: root.available
    label: root.label
    to: root.maximum
    stepSize: root.step
    value: root.available ? root.node.audio.volume : 0
    onMoved: if (root.available) root.node.audio.volume = value
    onMuteRequested: root.muteRequested()
  }
  Text {
    id: percent
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(34)
    text: root.available ? Math.round(slider.value*100)+"%" : "—"
    textFormat: Text.PlainText
    color: root.secondary
    font.family: "sans-serif"
    font.pixelSize: Style.space(11)
    horizontalAlignment: Text.AlignRight
  }
}
