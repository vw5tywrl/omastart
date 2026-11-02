import QtQuick

Rectangle {
  id: root

  property string text: ""
  property bool active: false
  property bool accentStyle: false
  property bool dangerStyle: false
  property bool bordered: true
  property bool enabledControl: true
  property int hPad: 10
  property int vPad: 5
  property int fontSize: OmaTheme.fontSmall

  signal clicked()

  implicitWidth: label.implicitWidth + hPad * 2
  implicitHeight: label.implicitHeight + vPad * 2
  radius: OmaTheme.cornerRadius
  opacity: enabledControl ? 1.0 : 0.4

  readonly property color tone: dangerStyle ? OmaTheme.red : (accentStyle || active ? OmaTheme.accent : OmaTheme.foreground)
  readonly property bool hot: mouse.containsMouse && enabledControl

  color: {
    if (mouse.pressed && enabledControl) return OmaTheme.pressedFill
    if (accentStyle) return hot ? OmaTheme.rgba(OmaTheme.accent, 0.26) : OmaTheme.accentFill
    if (dangerStyle) return hot ? OmaTheme.rgba(OmaTheme.red, 0.24) : OmaTheme.rgba(OmaTheme.red, 0.12)
    if (active) return OmaTheme.selectedFill
    if (hot) return OmaTheme.hoverFill
    return bordered ? OmaTheme.normalFill : "transparent"
  }

  border.width: (bordered || hot || active || accentStyle || dangerStyle) ? 1 : 0
  border.color: {
    if (dangerStyle) return OmaTheme.rgba(OmaTheme.red, hot ? 0.8 : 0.5)
    if (accentStyle || active) return OmaTheme.rgba(OmaTheme.accent, hot ? 0.95 : 0.65)
    if (hot) return OmaTheme.hoverBorder
    return bordered ? OmaTheme.normalBorder : "transparent"
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    textFormat: Text.PlainText
    font.family: OmaTheme.fontFamily
    font.pixelSize: root.fontSize
    font.bold: root.active || root.accentStyle || root.dangerStyle
    color: root.tone
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.enabledControl
    hoverEnabled: true
    cursorShape: root.enabledControl ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.clicked()
  }
}
