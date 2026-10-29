import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../io.github.hugorolimf.kit/ui"

// Tools: every plugin of the desktop in one place. On the bar, by island: a
// click opens that plugin's own panel, the switch keeps it on the bar or in
// the drawer, tools can leave the bar. In the background: plugins without a
// bar icon, switched on and off (the essential ones — a clone standing in for
// the system's notifications or lock screen — only say so). Installed widgets
// not on the bar can be added. The bar's part goes through Island Bar's IPC,
// which owns the layout; the rest through `omarchy plugin`.
Panel {
  id: root
  moduleName: "io.github.hugorolimf.bar"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var tools: []
  property var catalog: []
  property var plugins: []
  property bool loaded: false

  // Island plugins by their published ids; local hugo.* copies read as those.
  readonly property string selfId: "io.github.hugorolimf.bar"
  function canon(id) {
    id = String(id || "")
    if (id === "hugo.tools" || id === "hugo.bar") return selfId
    if (id === "hugo.notifcenter") return "io.github.hugorolimf.inbox"
    return id.indexOf("hugo.") === 0 ? "io.github.hugorolimf." + id.slice(5) : id
  }

  // Interface texts: Portuguese, or English for every other locale.
  readonly property bool pt: Qt.locale().name.indexOf("pt") === 0
  readonly property var t: pt ? ({
    title: "Plugins", onBar: "NA BARRA", inBackground: "EM SEGUNDO PLANO", active: "ATIVO", addToBar: "ADICIONAR À BARRA",
    nothingFor: "Nada encontrado para", essential: "Essencial · ", removeAgain: "Clique de novo para remover do sistema",
    remove: "Remover do sistema", leaveBar: "Tirar da barra",
    footer: "Clique num plugin para abrir os ajustes ou a janela dele. Na barra, a chave desligada o guarda aqui; em segundo plano, a chave liga e desliga."
  }) : ({
    title: "Plugins", onBar: "ON THE BAR", inBackground: "IN THE BACKGROUND", active: "ON", addToBar: "ADD TO THE BAR",
    nothingFor: "Nothing found for", essential: "Essential · ", removeAgain: "Click again to remove it from the system",
    remove: "Remove from the system", leaveBar: "Take off the bar",
    footer: "Click a plugin to open its settings or its window. On the bar, the switch off keeps it in here; in the background, the switch turns it on and off."
  })
  readonly property var groupNames: pt
    ? ({ ferramentas: "FERRAMENTAS", status: "STATUS", sistema: "SISTEMA", outros: "OUTROS NA BARRA" })
    : ({ ferramentas: "TOOLS", status: "STATUS", sistema: "SYSTEM", outros: "OTHERS ON THE BAR" })
  readonly property var groupOrder: ["ferramentas", "status", "sistema", "outros"]

  // Background plugins: name, what they do and an icon, in both languages.
  readonly property var pluginInfo: ({
    "io.github.hugorolimf.alttab": { name: pt ? "Alt+Tab" : "Alt+Tab", desc: pt ? "Trocar de janela com miniaturas" : "Switch windows with thumbnails", path: "M4 7h11v9H4zM9 4h11v9h-2" },
    "io.github.hugorolimf.notifications": { name: pt ? "Notificações" : "Notifications", desc: pt ? "Cartões, histórico e Não perturbe" : "Cards, history and Do Not Disturb", path: Anatomy.icons.bell },
    "io.github.sirjul1337.lock-explorer": { name: pt ? "Tela de bloqueio" : "Lock screen", desc: pt ? "Escolher, pré-visualizar e criar designs" : "Pick, preview and design lock screens", path: Anatomy.icons.lock },
    "fkcodes.key-promoter": { name: pt ? "Dica de atalhos" : "Shortcut hints", desc: pt ? "Mostra o atalho do que você acabou de clicar" : "Shows the shortcut for what you just clicked", path: Anatomy.icons.keyboard },
    "io.github.hugorolimf.onboarding": { name: pt ? "Primeiros passos" : "First steps", desc: pt ? "Guia com os atalhos essenciais" : "Guide with the essential shortcuts", path: Anatomy.icons.sparkle },
    "community.monitor-layout": { name: pt ? "Organizar monitores" : "Arrange displays", desc: pt ? "Arrastar telas, resolução, escala e rotação" : "Drag screens, resolution, scale and rotation", path: "M4 6h7v6H4zM13 8h7v8h-7zM6.5 16h2M15.5 19h2" },
    "omaplug": { name: pt ? "Omaplug" : "Omaplug", desc: pt ? "Gerenciador de plugins antigo (este painel o substitui)" : "Older plugin manager (this panel replaces it)", path: "M9 4h6v4h4v6h-4v6H9v-6H5V8h4z" }
  })

  function open() {
    refresh()
    query = ""
    confirmRemove = ""
    root.controller.show()
  }
  function openFromHotkey() { open() }
  function close() { root.controller.hide() }
  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    if (!toolsProc.running) toolsProc.running = true
    if (!pluginsProc.running) pluginsProc.running = true
  }
  function barCall(args) {
    Quickshell.execDetached(["omarchy-shell", "-q", "io.github.hugorolimf.bar"].concat(args))
  }
  // Optimistic: the switch moves at once, the bar follows, then re-read.
  function setPinned(id, pinned) {
    var list = tools.slice()
    for (var i = 0; i < list.length; i++) if (list[i].id === id) list[i] = Object.assign({}, list[i], { pinned: pinned })
    tools = list
    barCall(["pin", id, pinned ? "true" : "false"])
    refreshSoon.restart()
  }
  function openTool(id) {
    close()
    barCall(["openTool", id])
  }
  function addTool(id) {
    barCall(["add", id])
    refreshSoon.restart()
  }
  function removeTool(id) {
    barCall(["remove", id])
    refreshSoon.restart()
  }
  // A background plugin's own window (lock screen picker, guide, …).
  function openPlugin(id) {
    close()
    Quickshell.execDetached(["omarchy-shell", "-q", "shell", "toggle", id, "{}"])
  }
  function setEnabled(id, on) {
    var list = plugins.slice()
    for (var i = 0; i < list.length; i++) if (list[i].id === id) list[i] = Object.assign({}, list[i], { enabled: on })
    plugins = list
    Quickshell.execDetached(["omarchy", "plugin", on ? "enable" : "disable", id])
    refreshSlow.restart()
  }

  // ---- search: typing with the panel open filters every list
  property string query: ""
  function fold(t) { return String(t || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "") }
  function matches() {
    var q = fold(query).trim()
    if (!q) return true
    for (var i = 0; i < arguments.length; i++) if (fold(arguments[i]).indexOf(q) >= 0) return true
    return false
  }
  readonly property bool searching: query.trim() !== ""

  function toolsIn(group) {
    var out = []
    for (var i = 0; i < tools.length; i++)
      if (tools[i].group === group && matches(tools[i].name, tools[i].desc, tools[i].id)) out.push(tools[i])
    return out
  }
  readonly property var shownBackground: backgroundPlugins.filter(function(p) { return root.matches(p.name, p.desc, p.id) })
  readonly property var shownCatalog: catalog.filter(function(c) { return root.matches(c.name, c.desc, c.id) })

  // ---- removing a plugin from the system (omarchy plugin remove), with a
  // second click to confirm. The pieces the desktop stands on are kept.
  readonly property var protectedPlugins: [selfId, "io.github.hugorolimf.kit", "io.github.hugorolimf.island", "io.github.hugorolimf.notifications", "io.github.hugorolimf.osd", "io.github.hugorolimf.inbox"]
  property string confirmRemove: ""
  function pluginInfoFor(id) {
    for (var i = 0; i < plugins.length; i++) if (plugins[i].id === id) return plugins[i]
    return null
  }
  function canDelete(id) {
    var p = pluginInfoFor(id)
    if (!p || p.firstParty || String(p.clonedFrom || "") !== "") return false
    return protectedPlugins.indexOf(canon(id)) < 0
  }
  function deletePlugin(id) {
    if (confirmRemove !== id) {
      confirmRemove = id
      confirmTimer.restart()
      return
    }
    confirmRemove = ""
    Quickshell.execDetached(["omarchy", "plugin", "remove", id, "--yes"])
    refreshSlow.restart()
  }
  Timer { id: confirmTimer; interval: 3000; onTriggered: root.confirmRemove = "" }

  // Not first-party, not the bar itself, not already listed on the bar or
  // offered to be added.
  readonly property var backgroundPlugins: {
    var onBar = ({}), out = []
    for (var i = 0; i < tools.length; i++) onBar[tools[i].id] = true
    for (var c = 0; c < catalog.length; c++) onBar[catalog[c].id] = true
    for (var j = 0; j < plugins.length; j++) {
      var p = plugins[j]
      if (p.firstParty || onBar[p.id] || canon(p.id) === selfId) continue
      if ((p.kinds || []).indexOf("bar") >= 0) continue
      var info = pluginInfo[canon(p.id)] || {}
      // overlays and menus have a window of their own to open (pickers,
      // editors); hugo.onboarding is a guide panel
      var kinds = p.kinds || []
      var openable = p.enabled === true && (kinds.indexOf("overlay") >= 0 || kinds.indexOf("menu") >= 0
        || canon(p.id) === "io.github.hugorolimf.onboarding" || p.id === "community.monitor-layout")
      out.push({ id: p.id, name: info.name || p.name || p.id, desc: info.desc || "", path: info.path || "",
                 enabled: p.enabled === true, essential: String(p.clonedFrom || "") !== "", openable: openable })
    }
    out.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return out
  }

  Process {
    id: toolsProc
    command: ["omarchy-shell", "io.github.hugorolimf.bar", "tools"]
    stdout: StdioCollector {
      onStreamFinished: {
        var report = null
        try { report = JSON.parse(String(text || "").trim()) } catch (e) { report = null }
        if (!report) return
        root.tools = Array.isArray(report.tools) ? report.tools : []
        root.catalog = Array.isArray(report.catalog) ? report.catalog : []
        root.loaded = true
      }
    }
  }
  Process {
    id: pluginsProc
    command: ["omarchy", "plugin", "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        var list = null
        try { list = JSON.parse(String(text || "").trim()) } catch (e) { list = null }
        if (Array.isArray(list)) root.plugins = list
      }
    }
  }
  Timer { id: refreshSoon; interval: 350; onTriggered: root.refresh() }
  Timer { id: refreshSlow; interval: 1200; onTriggered: root.refresh() }
  // Live values (AI usage, battery, …) while it stays open.
  Timer { interval: 5000; repeat: true; running: root.opened; onTriggered: if (!toolsProc.running) toolsProc.running = true }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: searchInput
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: parent.width
          spacing: 2

          Item {
            width: parent.width
            height: Style.space(30)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.t.title
              color: Anatomy.strong
              font.family: Anatomy.sans
              font.pixelSize: 15
              font.weight: Font.DemiBold
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              text: root.tools.length + " " + root.t.onBar + " · " + root.backgroundPlugins.length + " " + root.t.inBackground
              color: Anatomy.muted
              font.family: Anatomy.mono
              font.pixelSize: 9
              font.letterSpacing: Anatomy.labelSpacing
            }
          }

          // ---- search: shows up as soon as you type
          Rectangle {
            width: parent.width
            height: root.searching ? Style.space(32) : 0
            opacity: root.searching ? 1 : 0
            Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
            Behavior on opacity { NumberAnimation { duration: 140 } }
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.06)
            border.width: Anatomy.hairline
            border.color: Qt.rgba(1, 1, 1, 0.12)
            AnatomyIcon {
              id: searchIcon
              x: Style.space(11)
              anchors.verticalCenter: parent.verticalCenter
              size: 13
              color: Anatomy.muted
              path: "M10.5 4.5a6 6 0 1 0 0 12a6 6 0 1 0 0-12zM15 15l4.5 4.5"
            }
            TextInput {
              id: searchInput
              anchors.left: searchIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              color: Anatomy.strong
              selectionColor: Anatomy.selection
              font.family: Anatomy.sans
              font.pixelSize: 13
              clip: true
              text: root.query
              onTextEdited: root.query = text
              Keys.onEscapePressed: {
                if (text !== "") { root.query = ""; text = "" }
                else root.close()
              }
              Keys.onTabPressed: root.switchPanel(1)
              Keys.onBacktabPressed: root.switchPanel(-1)
            }
          }

          Text {
            visible: root.searching && root.toolsIn("ferramentas").length + root.toolsIn("status").length + root.toolsIn("sistema").length + root.toolsIn("outros").length + root.shownBackground.length + root.shownCatalog.length === 0
            width: parent.width
            topPadding: Style.space(14)
            bottomPadding: Style.space(14)
            horizontalAlignment: Text.AlignHCenter
            text: root.t.nothingFor + " “" + root.query.trim() + "”"
            color: Anatomy.muted
            font.family: Anatomy.sans
            font.pixelSize: 12
          }

          // ---- on the bar, island by island
          Repeater {
            model: root.groupOrder
            delegate: Column {
              required property string modelData
              readonly property var rows: root.toolsIn(modelData)
              width: column.width
              spacing: 0
              visible: rows.length > 0
              SectionLabel {
                text: root.groupNames[modelData] || modelData.toUpperCase()
                hint: modelData !== "outros" ? root.t.onBar : ""
              }
              Repeater {
                model: parent.rows
                delegate: PluginRow {
                  required property var modelData
                  name: modelData.name || ""
                  sub: modelData.value || modelData.desc || ""
                  live: (modelData.value || "") !== ""
                  paths: modelData.paths || []
                  filled: modelData.fill === true
                  badge: modelData.badge || 0
                  showSwitch: modelData.canPin === true
                  checked: modelData.pinned === true
                  removable: modelData.canRemove === true
                  deletable: root.canDelete(modelData.id)
                  confirming: root.confirmRemove === modelData.id
                  onOpenRequested: root.openTool(modelData.id)
                  onSwitchToggled: root.setPinned(modelData.id, !modelData.pinned)
                  onRemoveRequested: root.removeTool(modelData.id)
                  onDeleteRequested: root.deletePlugin(modelData.id)
                }
              }
            }
          }

          // ---- in the background (no bar icon)
          Column {
            width: column.width
            visible: root.shownBackground.length > 0
            SectionLabel { text: root.t.inBackground; hint: root.t.active }
            Repeater {
              model: root.shownBackground
              delegate: PluginRow {
                required property var modelData
                name: modelData.name
                sub: modelData.essential ? root.t.essential + modelData.desc : modelData.desc
                paths: modelData.path ? [modelData.path] : []
                dim: !modelData.enabled
                showSwitch: !modelData.essential
                checked: modelData.enabled
                clickable: modelData.openable === true
                deletable: root.canDelete(modelData.id)
                confirming: root.confirmRemove === modelData.id
                onOpenRequested: root.openPlugin(modelData.id)
                onSwitchToggled: root.setEnabled(modelData.id, !modelData.enabled)
                onDeleteRequested: root.deletePlugin(modelData.id)
              }
            }
          }

          // ---- installed bar widgets placed nowhere yet
          Column {
            width: column.width
            visible: root.shownCatalog.length > 0
            spacing: Style.space(4)
            SectionLabel { text: root.t.addToBar }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.shownCatalog
                delegate: Rectangle {
                  required property var modelData
                  height: Style.space(26)
                  width: chipRow.implicitWidth + Style.space(18)
                  radius: height / 2
                  color: chipArea.containsMouse ? Anatomy.hover : "transparent"
                  border.width: Anatomy.hairline
                  border.color: Anatomy.controlRim
                  Behavior on color { ColorAnimation { duration: Anatomy.fast } }
                  Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: Style.space(5)
                    AnatomyIcon { anchors.verticalCenter: parent.verticalCenter; size: 12; path: "M12 6v12M6 12h12" }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.name
                      color: Anatomy.text
                      font.family: Anatomy.sans
                      font.pixelSize: 12
                    }
                  }
                  MouseArea {
                    id: chipArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.addTool(modelData.id)
                  }
                  PanelToolTip { visible: chipArea.containsMouse && modelData.desc !== ""; text: modelData.desc }
                }
              }
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(10)
            bottomPadding: Style.space(2)
            wrapMode: Text.Wrap
            text: root.t.footer
            color: Anatomy.muted
            font.family: Anatomy.sans
            font.pixelSize: 11
          }
        }
      }
    }
  }

  // Small caps section title, with what the switches mean on the right.
  component SectionLabel: Item {
    property alias text: label.text
    property string hint: ""
    width: column.width
    height: Style.space(28)
    Rectangle { width: parent.width; height: 1; color: Anatomy.rule; anchors.top: parent.top; anchors.topMargin: Style.space(4) }
    Text {
      id: label
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(4)
      color: Anatomy.muted
      font.family: Anatomy.mono
      font.pixelSize: 10
      font.weight: Font.DemiBold
      font.letterSpacing: Anatomy.labelSpacing
    }
    Text {
      visible: parent.hint !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.baseline: label.baseline
      text: parent.hint
      color: Anatomy.muted
      font.family: Anatomy.mono
      font.pixelSize: 9
      font.letterSpacing: Anatomy.labelSpacing
    }
  }

  // One plugin: icon tile, name, what it does or shows now, × (tools only)
  // and a switch. A click elsewhere on the row opens its own panel.
  component PluginRow: Rectangle {
    id: row
    property string name: ""
    property string sub: ""
    property bool live: false
    property var paths: []
    property bool filled: false
    property int badge: 0
    property bool showSwitch: true
    property bool checked: false
    property bool removable: false
    property bool clickable: true
    property bool dim: false
    property bool deletable: false
    property bool confirming: false
    signal openRequested()
    signal deleteRequested()
    signal switchToggled()
    signal removeRequested()

    width: column.width
    height: Style.space(44)
    radius: Anatomy.rowRadius
    color: row.clickable && rowArea.containsMouse ? Anatomy.hover : "transparent"
    Behavior on color { ColorAnimation { duration: Anatomy.fast } }

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (row.clickable) row.openRequested()
    }

    Rectangle {
      id: tile
      x: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(30)
      height: width
      radius: Anatomy.cardRadius
      color: Anatomy.card
      border.width: Anatomy.hairline
      border.color: Anatomy.controlRim
      opacity: row.dim ? 0.5 : 1
      AnatomyIcon {
        anchors.centerIn: parent
        visible: row.paths.length > 0
        size: 17
        paths: row.paths
        filled: row.filled
        color: Anatomy.hi
      }
      Text {
        anchors.centerIn: parent
        visible: row.paths.length === 0
        text: row.name.charAt(0).toUpperCase()
        color: Anatomy.hi
        font.family: Anatomy.sans
        font.pixelSize: 13
        font.weight: Font.DemiBold
      }
      Rectangle {
        visible: row.badge > 0
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: -3
        anchors.topMargin: -3
        width: Math.max(14, badgeText.implicitWidth + 6)
        height: 14
        radius: 7
        color: Anatomy.amber
        Text {
          id: badgeText
          anchors.centerIn: parent
          text: String(row.badge)
          color: "#0b0b0b"
          font.family: Anatomy.mono
          font.pixelSize: 9
          font.weight: Font.Bold
        }
      }
    }

    Column {
      anchors.left: tile.right
      anchors.leftMargin: Style.space(10)
      anchors.right: trashButton.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      opacity: row.dim ? 0.6 : 1
      Text {
        width: parent.width
        text: row.name
        color: Anatomy.strong
        font.family: Anatomy.sans
        font.pixelSize: 13
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: text !== ""
        text: row.sub
        color: row.live ? Anatomy.text : Anatomy.muted
        font.family: row.live ? Anatomy.mono : Anatomy.sans
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }

    // remove from the system (installed plugins only); a second click within
    // 3 s confirms
    Item {
      id: trashButton
      anchors.right: removeButton.left
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      width: row.deletable ? Style.space(20) : 0
      height: Style.space(20)
      visible: row.deletable
      opacity: row.confirming || rowArea.containsMouse || trashArea.containsMouse ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Anatomy.fast } }
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: row.confirming ? Anatomy.urgentFill : trashArea.containsMouse ? Anatomy.hover : "transparent"
      }
      AnatomyIcon {
        anchors.centerIn: parent
        size: 12
        path: "M5 7h14M10 7V5h4v2M7 7l1 12h8l1-12M10.5 10.5v5M13.5 10.5v5"
        color: row.confirming || trashArea.containsMouse ? Anatomy.red : Anatomy.muted
      }
      MouseArea {
        id: trashArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.deleteRequested()
      }
      PanelToolTip {
        visible: trashArea.containsMouse || row.confirming
        text: row.confirming ? root.t.removeAgain : root.t.remove
      }
    }

    // leave the bar (still installed: it comes back under "Adicionar")
    Item {
      id: removeButton
      anchors.right: switchBox.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: row.removable ? Style.space(20) : 0
      height: Style.space(20)
      visible: row.removable
      opacity: rowArea.containsMouse || removeArea.containsMouse ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Anatomy.fast } }
      AnatomyIcon {
        anchors.centerIn: parent
        size: 12
        path: "M7 7l10 10M17 7L7 17"
        color: removeArea.containsMouse ? Anatomy.red : Anatomy.muted
      }
      MouseArea {
        id: removeArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.removeRequested()
      }
      PanelToolTip { visible: removeArea.containsMouse; text: root.t.leaveBar }
    }

    AnatomyIcon {
      visible: row.clickable && !row.showSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      size: 14
      path: "M10 7l5 5-5 5"
      color: rowArea.containsMouse ? Anatomy.hi : Anatomy.muted
    }

    Item {
      id: switchBox
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: row.showSwitch ? pinSwitch.implicitWidth : 0
      height: pinSwitch.implicitHeight
      ToggleSwitch {
        id: pinSwitch
        visible: row.showSwitch
        checked: row.checked
        onToggled: row.switchToggled()
      }
    }
  }
}
