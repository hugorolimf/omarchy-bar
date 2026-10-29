import QtQuick
import Quickshell
import qs.Ui

// Island Bar's tools button. Left click opens the tools panel
// (ToolsPanel.qml): every tool of the bar, opened, pinned or kept in the
// drawer from one place. Right click toggles organise mode right on the bar.
// The bar draws this icon and owns the layout, so what the bar does goes
// through its IPC (io.github.hugorolimf.bar).
BarWidget {
  id: root
  moduleName: "io.github.hugorolimf.bar"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for shell.summon/hide/toggle (Bar.findPanelWidget).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // The tools panel is drawn with Island Kit; without it, the button says
  // how to get it instead of doing nothing.
  readonly property bool kitMissing: panelLoader.status === Loader.Error
  readonly property string kitNotice: Qt.locale().name.indexOf("pt") === 0
    ? "O painel de ferramentas precisa do Island Kit: omarchy plugin add https://github.com/hugorolimf/omarchy-island-kit --enable"
    : "The tools panel needs Island Kit: omarchy plugin add https://github.com/hugorolimf/omarchy-island-kit --enable"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("ToolsPanel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF0570)
    tooltipText: root.kitMissing ? root.kitNotice : ""
    onPressed: function(b) {
      if (b === Qt.RightButton) Quickshell.execDetached(["omarchy-shell", "-q", "io.github.hugorolimf.bar", "organize"])
      else if (panelLoader.item) panelLoader.item.toggle()
      else if (root.kitMissing) Quickshell.execDetached(["notify-send", "-a", "Island Bar", "Island Bar", root.kitNotice])
    }
  }
}
