import QtQuick
import QtQuick.Layouts
import qs.Commons as Commons
import qs.Ui
import "kit"

// One device, app or AirPlay speaker. Painted from the panel cursor
// (hasCursor) and selection (current); hover moves the cursor. The volume
// slider shows on the cursor row; a multi-select row (AirPlay) shows a
// checkbox and its volume only while selected.
FoamyCursorSurface {
  id: root
  property string label: ""
  property string iconName: "speaker"
  property url iconSource: ""
  property bool selected: false
  property bool multiSelect: false
  property bool dimmedIcon: false
  property bool volumeVisible: true
  property bool volumeAvailable: false
  property real volume: 0
  property bool muted: false
  property real maximum: 1
  property real step: 0.01
  property bool showLevelMeter: false
  property real level: 0
  property string levelDescription: ""
  readonly property bool levelVisible: showLevelMeter && selected
  signal activated()
  signal volumeMoved(real value)

  implicitHeight: FoamyStyle.rowHeight + FoamyStyle.gap
  current: selected && !multiSelect
  opacity: enabled ? 1 : FoamyStyle.disabledOpacity
  onClicked: if (enabled) activated()

  Accessible.role: multiSelect ? Accessible.CheckBox : Accessible.Button
  Accessible.name: label
  Accessible.checkable: multiSelect
  Accessible.checked: multiSelect && selected
  Accessible.onPressAction: if (enabled) activated()

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: FoamyStyle.rowPadding
    anchors.rightMargin: FoamyStyle.rowPadding
    spacing: FoamyStyle.rowPadding

    // Routing confirms selection asynchronously; the tick follows `selected` only.
    BorderSurface {
      visible: root.multiSelect
      Layout.preferredWidth: Commons.Style.space(16)
      Layout.preferredHeight: Commons.Style.space(16)
      radius: FoamyStyle.radiusSmall
      color: root.selected ? Commons.Style.selectedFillFor(Commons.Color.popups.text, Commons.Color.accent) : "transparent"
      borderSpec: Commons.Border.controlSpec(root.selected ? "selected" : "normal", Commons.Color.popups.text, Commons.Color.accent)
      FoamyIcon {
        anchors.centerIn: parent
        visible: root.selected
        width: parent.width - Commons.Style.space(4)
        height: width
        name: "check"
        strokeWidth: 2.4
        color: Commons.Style.selectedStateColor(Commons.Color.popups.text, Commons.Color.accent)
      }
    }
    Item {
      Layout.preferredWidth: FoamyStyle.iconSize
      Layout.preferredHeight: FoamyStyle.iconSize
      FoamyIcon {
        anchors.fill: parent
        visible: appIcon.status !== Image.Ready
        name: root.iconName
        color: FoamyPalette.text
      }
      Image {
        id: appIcon
        anchors.fill: parent
        source: root.iconSource
        sourceSize.width: Math.ceil(width * 2)
        sourceSize.height: Math.ceil(height * 2)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        visible: status === Image.Ready
        opacity: root.dimmedIcon ? FoamyStyle.disabledOpacity : 1
      }
    }
    // Name, then the selection tick right after it; the rest of the width stays free.
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Row {
        id: nameRow
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        spacing: FoamyStyle.gapSmall
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, nameRow.width - (tick.visible ? tick.width + nameRow.spacing : 0))
          text: root.label
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignLeft
          elide: Text.ElideRight
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
        }
        FoamyIcon {
          id: tick
          anchors.verticalCenter: parent.verticalCenter
          visible: root.selected && !root.multiSelect
          width: Commons.Style.space(12)
          height: width
          name: "check"
          color: Commons.Color.accent
        }
      }
    }
    DeviceVolume {
      visible: root.volumeVisible
      Layout.preferredWidth: implicitWidth
      available: root.volumeAvailable
      volume: root.volume
      muted: root.muted
      revealed: root.hasCursor
      label: root.label
      maximum: root.maximum
      step: root.step
      onMoved: function(value) { root.volumeMoved(value) }
    }
    // Every row with a volume keeps the meter's slot, so the percentages of
    // all sections line up; only the selected input shows the meter.
    Rectangle {
      visible: root.levelVisible || root.volumeVisible
      opacity: root.levelVisible ? 1 : 0
      Layout.preferredWidth: Commons.Style.space(3)
      Layout.preferredHeight: Commons.Style.space(20)
      radius: width / 2
      color: Qt.alpha(Commons.Color.popups.text, 0.18)
      Accessible.ignored: !root.levelVisible
      Accessible.role: Accessible.Indicator
      Accessible.name: root.label
      Accessible.description: root.levelDescription
      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: parent.height * Math.max(0, Math.min(1, root.level))
        radius: parent.radius
        color: Commons.Color.accent
        Behavior on height { NumberAnimation { duration: FoamyMotion.duration(70) } }
      }
    }
  }
}
