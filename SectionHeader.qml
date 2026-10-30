import QtQuick
import QtQuick.Layouts
import "kit"

// A collapsible section title (Output, Input, Apps, Wireless): one stop of
// the panel cursor; Enter, a click or the section's letter key toggles it.
FoamyCursorSurface {
  id: root
  property string label: ""
  property bool expanded: true
  signal toggled()
  implicitHeight: FoamyStyle.controlHeight
  Accessible.role: Accessible.Button
  Accessible.name: label
  Accessible.onPressAction: toggled()
  onClicked: toggled()
  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: FoamyStyle.rowPadding
    anchors.rightMargin: FoamyStyle.rowPadding
    Text {
      Layout.fillWidth: true
      text: root.label
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      elide: Text.ElideRight
      color: FoamyPalette.secondaryText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
      font.weight: Font.DemiBold
    }
    FoamyIcon {
      Layout.preferredWidth: FoamyStyle.iconSize
      Layout.preferredHeight: FoamyStyle.iconSize
      name: root.expanded ? "chevron-up" : "chevron-down"
      color: FoamyPalette.secondaryText
    }
  }
}
