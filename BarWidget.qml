import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "themo.nfl"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root.iconOnly ? iconButton : textButton
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.forceRefresh) panelLoader.item.forceRefresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function handlePress(b) {
    if (b === Qt.MiddleButton) root.refresh()
    else root.togglePanel()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root, and the popout
  // coordinator identifies the panel by this widget, not the nested Panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // BarIconButton pins itself to a one-glyph slot and paints anything longer
  // straight over its neighbours, so only the icon form may use it; the text
  // formats need a WidgetButton, which sizes to its label.
  readonly property bool iconOnly: panelLoader.item ? panelLoader.item.barFormat === "icon" : true
  readonly property string label: panelLoader.item ? panelLoader.item.label : ""
  readonly property string tooltip: panelLoader.item ? panelLoader.item.tooltip : ""

  implicitWidth: iconOnly ? iconButton.implicitWidth : textButton.implicitWidth
  implicitHeight: iconOnly ? iconButton.implicitHeight : textButton.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onIconOnlyChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: root.iconOnly
    bar: root.bar
    text: root.iconOnly ? root.label : ""
    slotSize: Style.bar.statusSlot
    tooltipText: root.tooltip

    onPressed: function(b) { root.handlePress(b) }
  }

  WidgetButton {
    id: textButton
    anchors.fill: parent
    visible: !root.iconOnly
    bar: root.bar
    text: root.iconOnly ? "" : root.label
    fontSize: Style.font.bodySmall
    tooltipText: root.tooltip

    onPressed: function(b) { root.handlePress(b) }
  }
}
