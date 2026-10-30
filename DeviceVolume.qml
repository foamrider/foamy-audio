import QtQuick
import qs.Commons as Commons
import "kit"

// A row's inline volume: slider plus percentage. Values come in and go out
// through the panel API so untyped (wpctl) inputs work like typed nodes.
Item {
  id: root
  property bool available: false
  property real volume: 0
  property bool muted: false
  property bool revealed: false
  property string label: ""
  property real maximum: 1
  property real step: 0.01
  readonly property bool dragging: slider.pressed
  signal moved(real value)
  implicitWidth: Commons.Style.space(114)
  implicitHeight: Commons.Style.space(26)
  opacity: !available || muted ? 0.5 : 1
  AudioSlider {
    id: slider
    anchors.left: parent.left
    anchors.right: percent.left
    anchors.rightMargin: FoamyStyle.gap
    anchors.verticalCenter: parent.verticalCenter
    mini: true
    revealed: root.revealed
    enabled: root.available
    label: root.label
    to: root.maximum
    stepSize: root.step
    value: root.available ? root.volume : 0
    onMoved: if (root.available) root.moved(value)
  }
  Text {
    id: percent
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Commons.Style.space(34)
    text: root.available ? FoamyI18n.t("%1%", Math.round(slider.value * 100)) : "—"
    textFormat: Text.PlainText
    color: FoamyPalette.secondaryText
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.bodySmall
    horizontalAlignment: Text.AlignRight
  }
}
