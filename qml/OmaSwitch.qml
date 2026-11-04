import QtQuick

// Minimalist sharp track + sliding knob modeled after Omarchy's ToggleSwitch.qml.
Item {
  id: root

  property bool checked: false
  property bool busy: false
  property bool hoverable: true
  property int trackWidth: 32
  property int trackHeight: 16
  readonly property int knobSize: 10
  readonly property int knobInset: 3

  signal toggled()

  implicitWidth: trackWidth
  implicitHeight: trackHeight
  opacity: busy ? 0.5 : 1.0

  Rectangle {
    id: track
    anchors.fill: parent
    radius: OmaTheme.cornerRadius > 0 ? height / 2 : 0
    color: root.checked
      ? (mouse.containsMouse && root.hoverable ? OmaTheme.rgba(OmaTheme.accent, 0.28) : OmaTheme.accentFill)
      : (mouse.containsMouse && root.hoverable ? OmaTheme.hoverFill : OmaTheme.normalFill)
    border.width: 1
    border.color: root.checked
      ? OmaTheme.rgba(OmaTheme.accent, 0.85)
      : (mouse.containsMouse && root.hoverable ? OmaTheme.hoverBorder : OmaTheme.normalBorder)

    Behavior on color { ColorAnimation { duration: 110 } }

    Rectangle {
      width: root.knobSize
      height: root.knobSize
      radius: OmaTheme.cornerRadius > 0 ? height / 2 : 0
      anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? (track.width - width - root.knobInset) : root.knobInset
      color: root.checked ? OmaTheme.accent : OmaTheme.muted

      Behavior on x { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 110 } }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: root.hoverable
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (!root.busy) root.toggled()
    }
  }
}
