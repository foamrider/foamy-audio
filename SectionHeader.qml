import QtQuick
import qs.Commons

Rectangle {
  id: root
  property string label: ""
  property bool expanded: true
  signal toggled()
  implicitHeight: Style.space(30)
  color: "transparent"
  radius: Style.space(5)
  activeFocusOnTab: true
  border.width: activeFocus ? 1 : 0
  border.color: Color.accent
  Accessible.role: Accessible.Button
  Accessible.name: label
  Accessible.onPressAction: toggled()
  Keys.onReturnPressed: toggled()
  Keys.onEnterPressed: toggled()
  Keys.onSpacePressed: toggled()
  Text {
    anchors.left:parent.left;anchors.leftMargin:Style.space(1);anchors.verticalCenter:parent.verticalCenter
    text:root.label.toUpperCase();textFormat:Text.PlainText;color:Qt.tint(Color.popups.background,Qt.alpha(Color.popups.text,0.76))
    font.family:"sans-serif";font.pixelSize:Style.space(11);font.letterSpacing:0.8
  }
  AudioIcon { anchors.right:parent.right;anchors.rightMargin:Style.space(2);anchors.verticalCenter:parent.verticalCenter;width:Style.space(14);height:width;name:root.expanded?"chevron-up":"chevron-down";color:Color.popups.text }
  MouseArea {anchors.fill:parent;cursorShape:Qt.PointingHandCursor;onClicked:{root.forceActiveFocus();root.toggled()}}
}
