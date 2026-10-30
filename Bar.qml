import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "BarModel.js" as BarModel

Item {
  id: root

  // The omarchy-shell host injects omarchyPath from OMARCHY_PATH.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  // Injected by the host shell so bar slots can resolve enabled widgets.
  property var barWidgetRegistry: fallbackBarWidgetRegistry
  // Read-only registry view for third-party full bars; the built-in bar does
  // not otherwise need it, but declaring it keeps clone construction atomic.
  property var pluginRegistry: null
  // Injected by the host shell every time shell.json is reloaded. Holds the
  // `bar:` subtree: position, centerAnchor, layout. The host owns file IO;
  // the bar just renders whatever it's handed. The bar font follows the
  // OS-level fontconfig monospace binding — it is not stored in shell.json.
  property var barConfig: ({})
  // Injected by the host shell. Used for shell-wide actions such as opening
  // settings and persisting inline widget state.
  property var shell: null
  // Manifest for the active bar option. Present for custom bars and useful for
  // diagnostics; the built-in bar does not otherwise need it.
  property var manifest: null
  QtObject {
    id: fallbackBarWidgetRegistry
    property var widgets: ({})
    property int revision: 0
    function metadataFor(id) { return null }
  }
  // Mirrors the on-disk `bar-off` flag so the user can hide the bar without
  // killing the entire shell. Hidden panels stay mapped but park off-screen
  // without an exclusion zone; updated by the FileView watcher further down.
  property bool barHidden: false
  property string home: Quickshell.env("HOME")
  property string stateHome: home + "/.local/state"
  property string omarchyConfigDir: home + "/.config/omarchy"
  property var fallbackBarConfig: ({
    position: "top",
    transparent: false,
    centerAnchor: "omarchy.clock",
    layout: { left: [], center: [], right: [] }
  })
  property var layoutConfig: fallbackBarConfig.layout
  property string centerAnchor: ""
  property bool requestedTransparent: false
  property bool useTransparentForeground: false
  property bool transparent: false
  property bool centerSectionHovered: false
  // One bar surface exists per monitor and each reports into this count, so a
  // pointer crossing from one monitor's bar to another's stays counted however
  // the enter and leave interleave. A single shared bool would be left false by
  // whichever event landed last.
  property int barHoverCount: 0
  // True while the pointer is over any bar, widgets included.
  readonly property bool barHovered: barHoverCount > 0
  property bool centerSectionRevealHeld: false
  property bool centerHoverRevealSuppressed: false
  property int barConfigSerial: 0
  property string position: "top"
  // Resolves through fontconfig at paint time (Style.font.family defaults
  // to "monospace"), so changing the system font (via `omarchy-font-set`)
  // updates the bar without a reload.
  // Island Bar: the dock's typeface, so the bar and the dock read as one system.
  property string fontFamily: "Adwaita Sans"
  // Bound to the central Color singleton so the bar tracks shell.toml's
  // [bar] section. Property names kept for the rest of this file's bindings.
  property color themeForeground: Commons.Color.bar.text
  property color themeContrastForeground: Commons.Color.background
  property color transparentForeground: Commons.Color.bar.text
  property color foreground: themeForeground
  property color barForeground: useTransparentForeground ? transparentForeground : themeForeground
  property bool foregroundAnimationEnabled: true
  // Translucent; the blur toggle (blurToggle) blurs what is behind it.
  property color background: Qt.rgba(Commons.Color.bar.background.r, Commons.Color.bar.background.g, Commons.Color.bar.background.b, 0.62)
  property color urgent: Commons.Color.bar.active

  Behavior on barForeground { enabled: root.foregroundAnimationEnabled; ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on background { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on urgent { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  property var tooltipTarget: null
  property var pendingTooltipTarget: null
  property string tooltipText: ""
  property string pendingTooltipText: ""
  property bool tooltipShown: false
  property int tooltipRequest: 0
  property var activePopout: null
  property var barDragSource: null
  property var barDragTarget: null
  property var barDragTargetGeometry: null
  property bool barDragAfter: false
  property var barDragWindow: null
  property var barDragScreen: null
  property url barDragImageUrl: ""
  property real barDragSceneX: 0
  property real barDragSceneY: 0
  property real barDragScreenX: 0
  property real barDragScreenY: 0
  property real barDragOffsetX: 0
  property real barDragOffsetY: 0
  property bool barMoveActive: false
  property string barMoveCandidate: ""
  property var barMoveWindow: null
  property var barMoveScreen: null
  property var clickTargets: []
  property var moduleSlots: []
  property var pluginBarApis: ({})
  // target -> { target, pluginId, clickTarget, popout }. Keyed by object so a
  // registration edits one entry in place instead of copying and rescanning an
  // array in QML; Qt's Map still finds a key by a native linear scan.
  readonly property var pluginObjectOwners: new Map()
  property bool pluginBarApiSyncQueued: false

  Component {
    id: pluginBarApiComponent
    PluginBarApi { }
  }

  function publicLayoutConfig() {
    return JSON.parse(JSON.stringify(root.layoutConfig || {}))
  }

  function bindPluginBarApi(api) {
    if (!api) return
    api.foreground = Qt.binding(function() { return root.foreground })
    api.barForeground = Qt.binding(function() { return root.barForeground })
    api.background = Qt.binding(function() { return root.background })
    api.urgent = Qt.binding(function() { return root.urgent })
    api.fontFamily = Qt.binding(function() { return root.fontFamily })
    api.position = Qt.binding(function() { return root.position })
    api.vertical = Qt.binding(function() { return root.vertical })
    api.barSize = Qt.binding(function() { return root.barSize })
    api.transparent = Qt.binding(function() { return root.transparent })
    api.foregroundAnimationEnabled = Qt.binding(function() { return root.foregroundAnimationEnabled })
    api.centerSectionRevealHeld = Qt.binding(function() { return root.centerSectionRevealHeld })
    api._centerHoverRevealSuppressed = Qt.binding(function() { return root.centerHoverRevealSuppressed })
    root.syncPluginBarApiObjects(api)
  }

  // Each api keeps its own detached copy of the layout. A flush serialises
  // the layout once and passes the string in so it is not re-serialised for
  // every plugin.
  function syncPluginBarApiObjects(api, layoutSnapshot) {
    if (!api) return
    api.activePopout = root.pluginOwnsBarObject(api.pluginId, root.activePopout)
      ? root.activePopout : (root.activePopout ? api.foreignPopoutMarker : null)
    api.clickTargets = root.pluginClickTargets(api.pluginId)
    api.layoutConfig = layoutSnapshot !== undefined
      ? JSON.parse(layoutSnapshot) : root.publicLayoutConfig()
  }

  function pluginObjectRecord(target) {
    return target ? (pluginObjectOwners.get(target) || null) : null
  }

  function markPluginObject(pluginId, target, role) {
    var key = String(pluginId || "")
    if (!key || !target) return false
    var record = root.pluginObjectRecord(target)
    if (record && record.pluginId !== key) return false
    if (!record) {
      record = { target: target, pluginId: key, clickTarget: false, popout: false }
      pluginObjectOwners.set(target, record)
    }
    record[role] = true
    return true
  }

  function unmarkPluginObject(pluginId, target, role) {
    var key = String(pluginId || "")
    var record = root.pluginObjectRecord(target)
    if (!record || record.pluginId !== key) return
    record[role] = false
    if (!record.clickTarget && !record.popout) pluginObjectOwners.delete(target)
  }

  function pluginOwnsBarObject(pluginId, target) {
    var record = target ? root.pluginObjectRecord(target) : null
    return !!record && record.pluginId === String(pluginId || "")
  }

  function pluginClickTargets(pluginId) {
    var out = []
    for (var i = 0; i < root.clickTargets.length; i++) {
      var target = root.clickTargets[i]
      if (root.pluginOwnsBarObject(pluginId, target)) out.push(target)
    }
    return out
  }

  // Every click target registration, popout change and layout change used to
  // resync every plugin api synchronously. Startup alone is hundreds of
  // registrations, each walking every api and every target, so coalesce them
  // into one resync per event-loop turn (as onModuleSlotsChanged already does
  // for prunePluginBarApis). bindPluginBarApi still syncs a brand-new api
  // directly so a widget never sees an empty api on its first read.
  function schedulePluginBarApiSync() {
    if (pluginBarApiSyncQueued) return
    pluginBarApiSyncQueued = true
    Qt.callLater(root.syncAllPluginBarApiObjects)
  }

  function syncAllPluginBarApiObjects() {
    pluginBarApiSyncQueued = false
    var layoutSnapshot = JSON.stringify(root.layoutConfig || {})
    for (var id in pluginBarApis) {
      var api = pluginBarApis[id]
      if (api) root.syncPluginBarApiObjects(api, layoutSnapshot)
    }
  }

  function registerPluginClickTarget(pluginId, target) {
    if (!root.markPluginObject(pluginId, target, "clickTarget")) return
    root.registerClickTarget(target)
  }

  function unregisterPluginClickTarget(pluginId, target) {
    if (!root.pluginOwnsBarObject(pluginId, target)) return
    root.unregisterClickTarget(target)
    root.unmarkPluginObject(pluginId, target, "clickTarget")
  }

  // A plugin may read api.activePopout right after asking for its popout, so
  // its own api is brought up to date inline; everyone else waits for the
  // coalesced resync.
  function requestPluginPopout(pluginId, owner) {
    if (!root.markPluginObject(pluginId, owner, "popout")) return
    root.requestPopout(owner)
    root.syncPluginBarApiObjects(pluginBarApis[String(pluginId || "")])
  }

  function releasePluginPopout(pluginId, owner) {
    if (!root.pluginOwnsBarObject(pluginId, owner)) return
    root.releasePopout(owner)
    root.unmarkPluginObject(pluginId, owner, "popout")
    root.syncPluginBarApiObjects(pluginBarApis[String(pluginId || "")])
  }

  function pluginBarApiFor(pluginId, moduleName, registered) {
    var key = String(pluginId || "")
    if (!key) return null

    var pluginShell = null
    if (registered && root.shell && typeof root.shell.pluginShellForId === "function") {
      // Only the trusted built-in bar receives ShellRoot and can request a
      // service-capable facade for the widget it is instantiating.
      pluginShell = root.shell.pluginShellForId(moduleName)
    } else if (root.shell && typeof root.shell.pluginShellForBarEntry === "function") {
      // Replacement bars receive a service-less entry facade. Giving an
      // untrusted bar a generic facade factory would let it retrieve another
      // third-party plugin's live service object.
      pluginShell = root.shell.pluginShellForBarEntry(key, moduleName)
    }

    if (pluginBarApis[key]) {
      pluginBarApis[key].shell = pluginShell
      return pluginBarApis[key]
    }

    var api = pluginBarApiComponent.createObject(null, {
      pluginId: key,
      moduleName: String(moduleName || ""),
      shell: pluginShell,
      _showTooltip: function(target, text) { root.showTooltip(target, text) },
      _hideTooltip: function(target) { root.hideTooltip(target) },
      _registerClickTarget: function(target) { root.registerPluginClickTarget(key, target) },
      _unregisterClickTarget: function(target) { root.unregisterPluginClickTarget(key, target) },
      _requestPopout: function(owner) { root.requestPluginPopout(key, owner) },
      _releasePopout: function(owner) { root.releasePluginPopout(key, owner) },
      _switchPanelFrom: function(owner, direction) { return root.switchPanelFrom(owner, direction) },
      _targetBelongsToWindow: function(target, window) { return root.targetBelongsToWindow(target, window) },
      _moduleWidgets: function(requestedId) {
        return String(requestedId || "") === String(moduleName || "")
          ? root.moduleWidgets(moduleName) : []
      },
      _run: function(command) { root.run(command) },
      _setCenterHoverRevealSuppressed: function(value) {
        root.centerHoverRevealSuppressed = !!value
      }
    })
    if (!api) return null
    root.bindPluginBarApi(api)

    var next = ({})
    for (var id in pluginBarApis) next[id] = pluginBarApis[id]
    next[key] = api
    pluginBarApis = next
    return api
  }

  function pluginBarApiUsed(pluginId) {
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (slot && slot.pluginApiId === pluginId) return true
    }
    return false
  }

  function releasePluginObjects(pluginId) {
    var owned = Array.from(pluginObjectOwners.values())
    for (var i = 0; i < owned.length; i++) {
      var record = owned[i]
      if (!record || record.pluginId !== pluginId) continue
      if (record.clickTarget) root.unregisterClickTarget(record.target)
      if (record.popout && root.activePopout === record.target) root.releasePopout(record.target)
      pluginObjectOwners.delete(record.target)
    }
  }

  function prunePluginBarApis() {
    var next = ({})
    for (var id in pluginBarApis) {
      var api = pluginBarApis[id]
      if (root.pluginBarApiUsed(id)) {
        next[id] = api
        continue
      }
      root.releasePluginObjects(id)
      if (api && typeof api.destroy === "function") api.destroy()
    }
    pluginBarApis = next
  }

  onActivePopoutChanged: {
    schedulePluginBarApiSync()
    // tools drawer: a panel just closed while the pointer is away -> fold it
    if (!activePopout && drawerOpen && !barHovered) drawerCloseTimer.restart()
  }
  onClickTargetsChanged: schedulePluginBarApiSync()
  onLayoutConfigChanged: schedulePluginBarApiSync()
  onModuleSlotsChanged: Qt.callLater(prunePluginBarApis)

  Component.onDestruction: {
    for (var id in pluginBarApis) {
      root.releasePluginObjects(id)
      if (pluginBarApis[id] && typeof pluginBarApis[id].destroy === "function")
        pluginBarApis[id].destroy()
    }
    pluginBarApis = ({})
  }

  function registerClickTarget(target) {
    if (!target || clickTargets.indexOf(target) !== -1) return
    var next = clickTargets.slice()
    next.push(target)
    clickTargets = next
  }

  function unregisterClickTarget(target) {
    var next = clickTargets.filter(function(item) { return item !== target })
    clickTargets = next
  }

  function registerModuleSlot(slot) {
    if (!slot || moduleSlots.indexOf(slot) !== -1) return
    var next = moduleSlots.slice()
    next.push(slot)
    moduleSlots = next
  }

  function unregisterModuleSlot(slot) {
    var next = moduleSlots.filter(function(item) { return item !== slot })
    moduleSlots = next
  }

  function debugBarGeometry() {
    var out = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      var point = { x: slot.x, y: slot.y }
      try {
        point = slot.mapToItem(null, 0, 0)
      } catch (e) {
      }
      out.push({
        id: slot.moduleName,
        section: slot.region,
        x: Math.round(point.x),
        y: Math.round(point.y),
        width: Math.round(slot.width),
        height: Math.round(slot.height),
        visible: slot.visible === true && slot.width > 0 && slot.height > 0,
        itemVisible: slot.activeItem.visible === true,
        itemWidth: Math.round(slot.activeItem.implicitWidth || 0),
        itemHeight: Math.round(slot.activeItem.implicitHeight || 0)
      })
    }
    return out
  }

  function targetWindow(target) {
    return target && target.QsWindow ? target.QsWindow.window : null
  }

  function targetBelongsToWindow(target, window) {
    return !!target && !!window && targetWindow(target) === window
  }

  function slotWindow(slot) {
    if (!slot) return null
    return targetWindow(slot.activeItem) || targetWindow(slot)
  }

  function sameWindow(left, right) {
    if (!left || !right) return false
    if (left === right) return true
    return !!left.screen && !!right.screen && !!left.screen.name && !!right.screen.name && left.screen.name === right.screen.name
  }

  function targetTooltipHovered(target) {
    return !!target && target.visible !== false && target.opacity !== 0 && target.tooltipHovered === true
  }

  function clearTooltip() {
    tooltipTimer.stop()
    pendingTooltipTarget = null
    pendingTooltipText = ""
    tooltipTarget = null
    tooltipText = ""
    tooltipShown = false
  }

  function clearBarDrag() {
    barDragSource = null
    barDragWindow = null
    barDragScreen = null
    barDragImageUrl = ""
    barDragTarget = null
    barDragTargetGeometry = null
    barDragAfter = false
    barDragSceneX = 0
    barDragSceneY = 0
    barDragScreenX = 0
    barDragScreenY = 0
    barDragOffsetX = 0
    barDragOffsetY = 0
  }

  function windowScreenPoint(scenePoint, window) {
    var x = scenePoint ? scenePoint.x : 0
    var y = scenePoint ? scenePoint.y : 0
    if (!window || !window.screen) return { x: x, y: y }

    if (root.position === "bottom")
      y += Math.max(0, window.screen.height - window.height)
    else if (root.position === "right")
      x += Math.max(0, window.screen.width - window.width)

    return { x: x, y: y }
  }

  function barDragScreenPoint(scenePoint) {
    return windowScreenPoint(scenePoint, barDragWindow)
  }

  function dropMarkerRect(slot, after) {
    if (!slot) return null

    try {
      var slotPoint = slot.mapToItem(null, 0, 0)
      var screenPoint = barDragScreenPoint(slotPoint)
      var thickness = Style.spacing.xs
      if (vertical) {
        return {
          x: screenPoint.x,
          y: screenPoint.y + (after ? slot.height : 0) - thickness / 2,
          width: slot.width,
          height: thickness
        }
      }

      return {
        x: screenPoint.x + (after ? slot.width : 0) - thickness / 2,
        y: screenPoint.y,
        width: thickness,
        height: slot.height
      }
    } catch (e) {
      return null
    }
  }

  // Split the screen along its diagonals (in normalized space, so widescreens
  // don't bias toward left/right): whichever triangle holds the cursor names
  // the candidate edge.
  function nearestScreenEdge(point, screen) {
    var nx = screen.width > 0 ? Util.clamp(point.x / screen.width, 0, 1) : 0.5
    var ny = screen.height > 0 ? Util.clamp(point.y / screen.height, 0, 1) : 0.5

    var edge = "top"
    var best = ny
    if (1 - ny < best) { edge = "bottom"; best = 1 - ny }
    if (nx < best) { edge = "left"; best = nx }
    if (1 - nx < best) { edge = "right"; best = 1 - nx }
    return edge
  }

  function beginBarMove(window) {
    barMoveWindow = window
    barMoveScreen = window ? window.screen : null
    barMoveCandidate = position
    barMoveActive = true
  }

  function updateBarMove(screenPoint) {
    if (!barMoveActive || !barMoveScreen) return
    barMoveCandidate = nearestScreenEdge(screenPoint, barMoveScreen)
  }

  function clearBarMove() {
    barMoveActive = false
    barMoveCandidate = ""
    barMoveWindow = null
    barMoveScreen = null
  }

  function finishBarMove() {
    var edge = barMoveCandidate
    if (!barMoveActive || !edge || edge === position) {
      clearBarMove()
      return
    }

    clearBarMove()
    setBarPosition(edge)
  }

  function setBarPosition(value) {
    var next = normalizePosition(value)
    if (root.shell && typeof root.shell.mutateShellConfig === "function") {
      root.shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.position = next
      })
    } else {
      root.position = next
    }
  }

  function captureBarDragGhost(slot) {
    var item = slot && slot.activeItem ? slot.activeItem : null
    barDragImageUrl = ""
    if (!item || typeof item.grabToImage !== "function") return

    var grabWidth = Math.max(1, Math.ceil(item.width || item.implicitWidth || slot.width || 1))
    var grabHeight = Math.max(1, Math.ceil(item.height || item.implicitHeight || slot.height || 1))
    item.grabToImage(function(result) {
      if (root.barDragSource !== slot || !result || !result.url) return
      root.barDragImageUrl = result.url
    }, Qt.size(grabWidth, grabHeight))
  }

  function requestPopout(owner) {
    if (activePopout === owner) return
    if (activePopout) {
      if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      else if ("close" in activePopout) activePopout.close()
    }
    activePopout = owner
  }

  function releasePopout(owner) {
    if (activePopout === owner) activePopout = null
  }

  readonly property bool vertical: position === "left" || position === "right"
  readonly property int barSize: vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal

  function normalizePosition(value) {
    return BarModel.normalizePosition(value)
  }

  // Apply tray-pinning on top of the shared layout normalization so the
  // bar host and scriptable config helpers can't drift on entry shape.
  function normalizeLayout(layout) {
    var normalized = Util.normalizeLayout(Util.isPlainObject(layout) ? layout : fallbackBarConfig.layout)
    return {
      left:   pinTrayToInner(normalized.left,   "left"),
      center: pinTrayToInner(normalized.center, "center"),
      right:  pinTrayToInner(normalized.right,  "right")
    }
  }

  // The tray drawer reveals inward (away from the bar edge). Place it at the
  // section's inner edge: start of the right section, end of the left/center
  // sections. The drawer's reserved space then sits next to the bar center,
  // not stranded mid-section.
  function pinTrayToInner(entries, section) {
    return BarModel.pinTrayToInner(entries, section)
  }

  function applyBarConfig() {
    var config = Util.isPlainObject(barConfig) ? barConfig : fallbackBarConfig

    position = normalizePosition(config.position)
    setRequestedTransparency(config.transparent === true)
    centerAnchor = Util.canonicalWidgetId(config.centerAnchor || "")

    // layoutEntries feeds plain JS arrays to the module Repeaters, and QML
    // cannot diff those: reassigning layoutConfig rebuilds every widget on
    // every monitor. When a shell.json write only changed inline widget
    // settings, patch the live layout and running widgets in place instead.
    var next = normalizeLayout(config.layout)
    var delta = BarModel.inlineSettingsDelta(layoutConfig, next)
    if (delta) {
      applySettingsDelta(delta)
      return
    }
    layoutConfig = next
    barConfigSerial++
  }

  // Bumped when applySettingsDelta patches the layout in place (pinning a
  // tool is such a patch), so what reads "drawer" updates without a rebuild.
  property int layoutPatchSerial: 0
  function applySettingsDelta(delta) {
    for (var i = 0; i < delta.length; i++) {
      var change = delta[i]
      layoutConfig[change.region][change.index] = change.entry
      var settings = entrySettings(change.entry)
      for (var s = 0; s < moduleSlots.length; s++) {
        var slot = moduleSlots[s]
        if (!slot || slot.region !== change.region || slot.moduleName !== entryId(change.entry)) continue
        var item = slot.activeItem
        if (item && "settings" in item) item.settings = settings
      }
    }
    layoutPatchSerial++
  }

  onBarConfigChanged: applyBarConfig()

  function layoutEntries(region) {
    var serial = barConfigSerial
    var entries = layoutConfig ? layoutConfig[region] : null
    return Array.isArray(entries) ? entries : []
  }

  // Tab order for the panels in one bar region. Scoped to a single bar surface
  // so tabbing walks the bar the open panel belongs to instead of hopping the
  // panel to another monitor's copy of the same widget.
  function panelNavigationSlots(region, window) {
    var entries = layoutEntries(region)
    var slots = []
    for (var i = 0; i < entries.length; i++) {
      var id = entryId(entries[i])
      for (var j = 0; j < moduleSlots.length; j++) {
        var slot = moduleSlots[j]
        if (!slot || slot.region !== region || slot.moduleName !== id) continue
        if (window && !sameWindow(slotWindow(slot), window)) continue
        var item = slot.activeItem
        if (!item || item.visible !== true || slot.visible !== true || slot.width <= 0 || slot.height <= 0) continue
        if (typeof item.open !== "function" || typeof item.close !== "function" || item.opened === undefined) continue
        slots.push(slot)
        break
      }
    }
    return slots
  }

  // The Nth panel in a bar region, counted the way the bar reads: layout order,
  // and only the panels actually on screen. A widget with no panel (the tray)
  // and one that is hiding itself are passed over, so the number lands on the
  // Nth panel icon the user can see rather than the Nth layout entry.
  // One-based, because it exists for hotkeys; anything else lands on no slot.
  //
  // Counting any bar surface is enough: every monitor lays its bar out from the
  // one layout, and summoning the id routes through pickPanelSlot, which opens
  // the focused monitor's copy whichever surface was counted.
  function panelWidgetIdAt(region, index) {
    var slots = panelNavigationSlots(String(region || ""), null)
    var slot = slots[Math.round(Number(index)) - 1]
    return slot ? String(slot.moduleName || "") : ""
  }

  // Is `obj` this slot's widget? Panels register with the real widget, which
  // sits in `inner` when the slot holds a thin entry (Entry.qml).
  function slotHolds(slot, obj) {
    return !!slot && !!obj && (slot.activeItem === obj || moduleState(slot.activeItem) === obj)
  }

  function switchPanelFrom(owner, direction) {
    if (!owner) return false

    var currentSlot = null
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (slot && slotHolds(slot, owner)) {
        currentSlot = slot
        break
      }
    }
    if (!currentSlot) return false

    var slots = panelNavigationSlots(currentSlot.region, slotWindow(currentSlot))
    if (slots.length < 2) return false

    var currentIndex = -1
    for (var j = 0; j < slots.length; j++) {
      if (slots[j] === currentSlot) {
        currentIndex = j
        break
      }
    }
    if (currentIndex < 0) return false

    var step = direction < 0 ? -1 : 1
    var nextSlot = slots[(currentIndex + step + slots.length) % slots.length]
    if (!nextSlot || !nextSlot.activeItem || slotHolds(nextSlot, owner)) return false

    nextSlot.activeItem.open()
    return true
  }

  // Every live instance of a widget id. A bar surface is built per monitor, so
  // a widget that appears once in the layout is still live once per screen.
  function moduleWidgets(pluginId) {
    var id = String(pluginId || "")
    var items = []
    if (!id) return items
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem || slot.moduleName !== id) continue
      items.push(slot.activeItem)
    }
    return items
  }

  function slotScreenName(slot) {
    var window = slotWindow(slot)
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  // The output Hyprland has focused, which is where a keyboard-summoned panel
  // belongs. Empty until Hyprland reports one, which leaves panel routing on
  // its per-monitor fallback rather than guessing at an output.
  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name || "") : ""
  }

  // Resolve the live bar-widget instance for a plugin id (e.g. "omarchy.bluetooth").
  // Only widgets that expose popup open/close methods count; plain indicators
  // (clock, workspaces, tray) return null. Used by shell.summon/toggle so
  // panel hotkeys route through the bar instead of a per-target IPC handler
  // that only reaches whichever per-monitor instance claimed the target.
  function findPanelWidget(pluginId) {
    var id = String(pluginId || "")
    if (!id) return null
    var candidates = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      if (slot.moduleName !== id) continue
      var item = slot.activeItem
      if (typeof item.open !== "function" || typeof item.close !== "function" || item.opened === undefined) continue
      candidates.push({ slot: slot, screenName: slotScreenName(slot), opened: item.opened === true })
    }
    // One copy per monitor, plus a zero-size placeholder for anchored center
    // modules. See BarModel.pickPanelSlot for which one a hotkey acts on.
    var chosen = BarModel.pickPanelSlot(candidates, focusedScreenName())
    return chosen ? chosen.activeItem : null
  }

  function summonBarWidget(pluginId) {
    var item = findPanelWidget(pluginId)
    if (!item || typeof item.open !== "function") return false
    item.open()
    return true
  }

  function hideBarWidget(pluginId) {
    var item = findPanelWidget(pluginId)
    if (!item || typeof item.close !== "function") return false
    item.close()
    return true
  }

  function isBarWidgetOpen(pluginId) {
    var item = findPanelWidget(pluginId)
    return !!item && item.opened === true
  }

  // Runs of consecutive entries with the same "group" key: [{ group, entries }].
  function islandsOf(entries) {
    var out = []
    for (var i = 0; i < (entries || []).length; i++) {
      var e = entries[i]
      var g = e && typeof e === "object" && e.group ? String(e.group) : ""
      var last = out.length ? out[out.length - 1] : null
      if (last && g !== "" && last.group === g) last.entries.push(e)
      else out.push({ group: g, entries: [e] })
    }
    return out
  }

  function entrySettings(entry) {
    return BarModel.entrySettings(entry)
  }

  function entryId(entry) {
    return BarModel.entryId(entry)
  }

  function moduleString(entry, key, fallback) {
    return BarModel.moduleString(entry, key, fallback)
  }

  function entryIndex(entries, name) {
    return BarModel.entryIndex(entries, name)
  }

  function entriesBefore(entries, name) {
    return BarModel.entriesBefore(entries, name)
  }

  function entriesAfter(entries, name) {
    return BarModel.entriesAfter(entries, name)
  }

  function canonicalWidgetId(name) {
    return Util.canonicalWidgetId(name)
  }

  function expandPath(path) {
    return BarModel.expandPath(path, home)
  }

  function customModuleSafeName(name) {
    return BarModel.customModuleSafeName(name)
  }

  function customModuleType(entry) {
    return BarModel.customModuleType(entry)
  }

  function customModuleSource(entry) {
    var source = BarModel.customModulePath(entry, home, omarchyConfigDir)
    return source ? Util.fileUrl(source) : ""
  }

  readonly property string blurToggle: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/toggles/hypr/hugorolimf-bar-blur.lua"
  readonly property string blurLua: [
    "-- io.github.hugorolimf.bar: blur behind the translucent bar (layer namespace omarchy-bar).",
    "-- Written by the bar; delete this file and run hyprctl reload to turn it off.",
    "hl.layer_rule({ name = \"hugorolimf-bar-blur\", match = { namespace = \"omarchy-bar\" }, blur = true, ignore_alpha = 0, no_anim = true, animation = \"none\" })"
  ].join("\n")
  Component.onCompleted: {
    applyBarConfig()
    // written once, and again only if it changed
    Quickshell.execDetached(["sh", "-c",
      'printf "%s\\n" "$2" | cmp -s - "$1" || { mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1" && hyprctl reload; }',
      "sh", blurToggle, blurLua])
  }

  // Revealing the indicators widens their section, which can slide a neighbour
  // under a stationary pointer. Collapsing on that un-hover would move it back
  // out and re-open the peek, so hold until the pointer leaves the bar.
  function setCenterSectionHovered(hovered) {
    centerSectionHovered = hovered
    if (hovered) {
      centerSectionRevealTimer.stop()
      centerSectionRevealHeld = true
    } else {
      centerSectionRevealTimer.restart()
    }
  }

  function setBarHovered(hovered) {
    barHoverCount = Math.max(0, barHoverCount + (hovered ? 1 : -1))
    if (barHoverCount === 0) centerSectionRevealTimer.restart()
  }

  function setCenterHoverRevealSuppressed(value) {
    centerHoverRevealSuppressed = !!value
  }

  Timer {
    id: centerSectionRevealTimer
    interval: 120
    // Collapse only. Opening the peek is the center section's own gesture, done
    // in setCenterSectionHovered, so a timer left pending by a pointer that dipped
    // off the bar and came back cannot reveal indicators it never pointed at.
    onTriggered: if (!root.centerSectionHovered && !root.barHovered) root.centerSectionRevealHeld = false
  }

  function run(command) {
    if (!command) return

    Util.execDetached(command)
  }

  function toggleTransparency() {
    var nextTransparent = !(root.requestedTransparent === true)
    if (root.shell && typeof root.shell.mutateShellConfig === "function") {
      root.shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.transparent = nextTransparent
      })
    } else {
      root.setRequestedTransparency(nextTransparent)
    }
  }

  function rawLayoutSection(config, region) {
    if (!Util.isPlainObject(config.bar)) config.bar = {}
    if (!Util.isPlainObject(config.bar.layout)) config.bar.layout = {}
    if (!Array.isArray(config.bar.layout[region])) config.bar.layout[region] = []

    return config.bar.layout[region]
  }

  function rawEntryIndex(entries, name) {
    for (var i = 0; i < entries.length; i++) {
      if (root.entryId(entries[i]) === name) return i
    }

    return -1
  }

  function moveModuleInConfig(config, fromRegion, fromName, toRegion, beforeName) {
    var fromEntries = rawLayoutSection(config, fromRegion)
    var toEntries = rawLayoutSection(config, toRegion)
    var fromIndex = rawEntryIndex(fromEntries, fromName)
    if (fromIndex < 0) return false

    var toIndex = beforeName ? rawEntryIndex(toEntries, beforeName) : toEntries.length
    if (toIndex < 0) toIndex = toEntries.length

    if (fromRegion === toRegion && fromIndex === toIndex) return false

    var movedEntry = fromEntries[fromIndex]
    fromEntries.splice(fromIndex, 1)

    if (fromRegion === toRegion && fromIndex < toIndex) toIndex -= 1
    if (toIndex < 0) toIndex = 0
    if (toIndex > toEntries.length) toIndex = toEntries.length
    if (fromRegion === toRegion && fromIndex === toIndex) {
      fromEntries.splice(fromIndex, 0, movedEntry)
      return false
    }

    toEntries.splice(toIndex, 0, movedEntry)
    return true
  }

  function dropBarModule(source, toRegion, beforeName) {
    if (!source || !source.region || !source.moduleName || !toRegion) return false
    if (source.region === toRegion && source.moduleName === beforeName) return false
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return false

    var changed = false
    root.shell.mutateShellConfig(function(config) {
      changed = moveModuleInConfig(config, source.region, source.moduleName, toRegion, beforeName)
    })
    return changed
  }

  function moduleDropAtScene(scenePoint, sourceSlot) {
    var sourceWindow = root.slotWindow(sourceSlot) || root.barDragWindow
    if (sourceWindow && sourceWindow.contentItem) {
      var barPoint = sourceWindow.contentItem.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (barPoint.x < 0 || barPoint.x > sourceWindow.contentItem.width ||
          barPoint.y < 0 || barPoint.y > sourceWindow.contentItem.height)
        return null
    }

    var candidates = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || slot === sourceSlot || !slot.visible || slot.width <= 0 || slot.height <= 0) continue
      if (sourceWindow && !root.sameWindow(root.slotWindow(slot), sourceWindow)) continue

      var slotPoint = { x: slot.x, y: slot.y }
      try {
        slotPoint = slot.mapToItem(null, 0, 0)
      } catch (e) {
      }

      candidates.push({
        slot: slot,
        x: slotPoint.x,
        y: slotPoint.y,
        width: slot.width,
        height: slot.height
      })
    }

    return BarModel.nearestDropTarget(candidates, scenePoint, root.vertical)
  }

  function visibleModuleSlot(region, name, sourceSlot) {
    var sourceWindow = root.slotWindow(sourceSlot) || root.barDragWindow
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || slot === sourceSlot || slot.region !== region || slot.moduleName !== name ||
          !slot.visible || slot.width <= 0 || slot.height <= 0) continue
      if (sourceWindow && !root.sameWindow(root.slotWindow(slot), sourceWindow)) continue
      return slot
    }

    return null
  }

  function nextVisibleModuleName(region, afterName, sourceSlot) {
    var entries = layoutEntries(region)
    var found = false
    for (var i = 0; i < entries.length; i++) {
      var name = entryId(entries[i])
      if (!found) {
        found = name === afterName
        continue
      }

      if (visibleModuleSlot(region, name, sourceSlot)) return name
    }

    return ""
  }

  function dropBarModuleAtTarget(sourceSlot, targetSlot, afterTarget) {
    if (!sourceSlot || !targetSlot) return false

    var beforeName = afterTarget ? nextVisibleModuleName(targetSlot.region, targetSlot.moduleName, sourceSlot) : targetSlot.moduleName
    return dropBarModule(sourceSlot, targetSlot.region, beforeName)
  }

  function moduleTargetClickable(target) {
    return target
      && target.visible !== false
      && target.opacity !== 0
      && target.interactive !== false
      && target.pressable !== false
      && target.concealed !== true
      && typeof target.triggerPress === "function"
  }

  function moduleClickTargetAt(slot, localX, localY) {
    for (var i = clickTargets.length - 1; i >= 0; i--) {
      var target = clickTargets[i]
      if (!moduleTargetClickable(target)) continue
      // Only this slot's own buttons: a tool folded into the drawer keeps its
      // button's size at the slot next to it, and used to steal its clicks.
      if (!itemInside(target, slot)) continue

      var targetPoint = { x: localX, y: localY }
      try {
        targetPoint = slot.mapToItem(target, localX, localY)
      } catch (e) {
        continue
      }

      if (targetPoint.x >= 0 && targetPoint.x <= target.width &&
          targetPoint.y >= 0 && targetPoint.y <= target.height) {
        return target
      }
    }

    if (moduleTargetClickable(slot.activeItem)) return slot.activeItem
    // The slot is wider than its button when the bar paints a value beside
    // the icon (AI usage "66%"): a click there still belongs to the module,
    // so it goes to the module's own button.
    for (var j = 0; j < clickTargets.length; j++) {
      if (moduleTargetClickable(clickTargets[j]) && itemInside(clickTargets[j], slot)) return clickTargets[j]
    }
    return null
  }

  function clickModule(id) {
    var screen = focusedScreenName(), pick = null
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem || slot.moduleName !== id) continue
      if (!pick || slotScreenName(slot) === screen) pick = slot
    }
    if (!pick) return false
    // the widget's own button, wherever it sits in the slot (a label beside
    // the icon, as on the AI usage, moves it off the centre)
    for (var k = 0; k < clickTargets.length; k++) {
      var target = clickTargets[k]
      if (moduleTargetClickable(target) && itemInside(target, pick)) {
        target.triggerPress(Qt.LeftButton)
        return true
      }
    }
    return pressModuleClickTarget(pick, Qt.LeftButton, pick.width / 2, pick.height / 2)
  }

  function itemInside(item, ancestor) {
    for (var p = item; p; p = p.parent) if (p === ancestor) return true
    return false
  }

  function pressModuleClickTarget(slot, button, localX, localY) {
    var target = moduleClickTargetAt(slot, localX, localY)
    if (!target) return false

    target.triggerPress(button)
    return true
  }

  function colorHex(colorValue) {
    var c = colorValue
    if (typeof c === "string") c = Qt.color(c)
    function hexChannel(value) {
      var s = Math.round(Util.clamp(value, 0, 1) * 255).toString(16)
      return s.length < 2 ? "0" + s : s
    }
    return "#" + hexChannel(c.r) + hexChannel(c.g) + hexChannel(c.b)
  }

  function setRequestedTransparency(value) {
    var nextTransparent = value === true
    requestedTransparent = nextTransparent
    if (!nextTransparent) {
      foregroundAnimationEnabled = false
      useTransparentForeground = false
      transparent = false
      transparentForeground = themeForeground
      restoreForegroundAnimation()
      return
    }
    scheduleTransparentForegroundRefresh()
  }

  function restoreForegroundAnimation() {
    Qt.callLater(function() {
      Qt.callLater(function() { root.foregroundAnimationEnabled = true })
    })
  }

  function scheduleTransparentForegroundRefresh() {
    if (!requestedTransparent) {
      transparentForeground = themeForeground
      return
    }
    transparentForegroundTimer.restart()
  }

  function refreshTransparentForeground() {
    if (!requestedTransparent || transparentForegroundProc.running) return

    transparentForegroundProc.command = [
      "omarchy-bar-text-color",
      root.position,
      String(root.barSize),
      colorHex(root.themeForeground),
      colorHex(root.themeContrastForeground)
    ]
    transparentForegroundProc.running = true
  }

  onRequestedTransparentChanged: scheduleTransparentForegroundRefresh()
  onPositionChanged: scheduleTransparentForegroundRefresh()
  onThemeForegroundChanged: scheduleTransparentForegroundRefresh()
  onThemeContrastForegroundChanged: scheduleTransparentForegroundRefresh()

  Timer {
    id: transparentForegroundTimer
    interval: 120
    repeat: false
    onTriggered: root.refreshTransparentForeground()
  }

  Process {
    id: transparentForegroundProc
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (!/^#[0-9A-Fa-f]{6}$/.test(value)) return

        root.foregroundAnimationEnabled = false
        root.transparentForeground = value
        if (root.requestedTransparent) {
          root.useTransparentForeground = true
          root.transparent = true
        }
        root.restoreForegroundAnimation()
      }
    }
  }

  FileView {
    path: root.stateHome + "/omarchy/current"
    watchChanges: true
    printErrors: false
    onFileChanged: root.scheduleTransparentForegroundRefresh()
  }

  function runProcess(process) {
    if (!process.running)
      process.running = true
  }

  // Island Bar: what each icon is and what clicking it does, in Portuguese.
  // Widgets that already describe themselves on hover (media, microphone,
  // keyboard layout, tray items, indicators) keep theirs, translated below.
  readonly property var ptTips: ({
    "omarchy.menu": "Menu do sistema — clique para abrir · botão direito abre o terminal",
    "yakumy.station": "Station — áreas de trabalho e telas sincronizadas",
    "omarchy.weather": "Clima — clique para ver a previsão",
    "techspawn.projects": "Projetos — seus repositórios git: branch, alterações, pull e push",
    "evindor.keystroke": "Keystroke — paleta de comandos para abrir apps e ações",
    "omarchy.agents": "Agentes de IA — limites e uso do Claude, Codex e outros",
    "io.github.hugorolimf.dock": "Dock — ajustes da dock",
    "io.github.fasi96.liquid-glass": "Liquid Glass — ajustar o vidro dos terminais",
    "omaplug": "Plugins — ativar, desativar e atualizar plugins do sistema",
    "omarchy.system-update": "Atualizações disponíveis — clique para atualizar o sistema",
    "omarchy.bluetooth": "Bluetooth — clique para ver e conectar dispositivos · botão direito liga/desliga",
    "omarchy.network": "Wi‑Fi e rede — clique para ver as redes",
    "omarchy.audio": "Som — clique para volume e saídas · role para ajustar · botão direito silencia",
    "omarchy.monitor": "Tela — brilho e monitores",
    "omarchy.power": "Bateria e energia — clique para detalhes e modos de energia",
    "io.github.hugorolimf.power": "Bateria e energia — clique para detalhes e modos de energia",
    "omarchy.tailscale": "Tailscale — rede privada",
    "io.github.hugorolimf.clock": "Calendário — clique para abrir",
    "io.github.hugorolimf.iphone": "iPhone — clique para ver as mensagens",
    "io.github.hugorolimf.bar": "Ferramentas — abrir e organizar os plugins da barra",
    "io.github.hugorolimf.inbox": "Notificações — histórico agrupado por app",
    "io.github.hugorolimf.monitores": "Organizar monitores — arrastar telas, resolução, escala e rotação"
  })
  readonly property var ptTexts: ({
    "Microphone muted": "Microfone silenciado — clique para ativar",
    "Microphone in use": "Microfone em uso — clique para silenciar",
    "Microphone live": "Microfone ligado — clique para silenciar",
    "Pending Omarchy Updates": "Atualizações do Omarchy pendentes"
  })
  // `omarchy-shell io.github.hugorolimf.bar peek`: every icon shows its value for a few
  // seconds, as if all were hovered at once.
  property bool peekValues: false
  Timer { id: peekTimer; interval: 4000; onTriggered: root.peekValues = false }
  IpcHandler {
    target: root.selfId
    function peek(): void { root.peekValues = true; peekTimer.restart() }
    function drawer(): void { root.toggleDrawer() }
    function organize(): void { root.toggleDrawerEdit() }
    // The tools panel (ToolsPanel.qml) lists, pins and opens tools here.
    function tools(): string { return JSON.stringify(root.toolsReport()) }
    function pin(id: string, pinned: string): void { root.setInDrawer(id, pinned !== "true") }
    function add(id: string): void { root.addToDrawer(id) }
    function remove(id: string): void { root.removeTool(id) }
    function openTool(id: string): void { root.openTool(id) }
    // Same as a left click on that widget's icon on the focused monitor.
    function click(id: string): string { return root.clickModule(id) ? "ok" : "none" }
  }

  // The network widget only learns the Wi-Fi name once its panel opens, so
  // ask nmcli when the network icon is hovered (or peeked), not on a timer.
  property string wifiName: ""
  function refreshWifiName() { if (!wifiProc.running) wifiProc.running = true }
  Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshWifiName() }
  onPeekValuesChanged: if (peekValues) refreshWifiName()
  Process {
    id: wifiProc
    command: ["sh", "-c", "nmcli -t -f active,ssid dev wifi 2>/dev/null | sed -n 's/^\\(sim\\|yes\\)://p' | head -1"]
    stdout: StdioCollector { onStreamFinished: root.wifiName = text.trim() }
  }

  // Icon set, "anatomy" style: thin monochrome strokes on a 24-unit
  // grid, colour only where it says something (green ok/charging, amber
  // attention, red alert, blue in use, dim = off). Drawn by the bar over
  // the widget, which stays underneath invisible and still takes the clicks.
  // iconFor returns { key, fam, tone, badge, ring, spin, slash, cross,
  // parts: [{ d, a (alpha), f (fill) }], blocks: [{ x, y, w, h, r, a, f }] }
  // or null to keep the widget's own look. Within one `fam` the parts keep
  // their places, so a state change only fades their alpha (Wi-Fi bars,
  // volume waves); `blocks` are rectangles on the same grid that glide to
  // their new size (battery level, brightness, switch knobs); `slash` draws a
  // stroke across from the top left and `cross` grows the mute cross.
  readonly property string slashPath: "M4 4l16 16"
  readonly property string crossPath: "M16 9.5l5 5M21 9.5l-5 5"
  readonly property var easeCurve: [0.32, 0.72, 0, 1, 1, 1]
  readonly property string monoFamily: "JetBrainsMono Nerd Font"
  function circ(cx, cy, r) {
    return "M" + (cx - r) + " " + cy + "a" + r + " " + r + " 0 1 0 " + (2 * r) + " 0a" + r + " " + r + " 0 1 0 " + (-2 * r) + " 0"
  }
  function rrect(x, y, w, h, r) {
    return "M" + (x + r) + " " + y + "h" + (w - 2 * r) + "a" + r + " " + r + " 0 0 1 " + r + " " + r + "v" + (h - 2 * r)
      + "a" + r + " " + r + " 0 0 1 " + (-r) + " " + r + "h" + (-(w - 2 * r)) + "a" + r + " " + r + " 0 0 1 " + (-r) + " " + (-r)
      + "v" + (-(h - 2 * r)) + "a" + r + " " + r + " 0 0 1 " + r + " " + (-r) + "z"
  }
  readonly property var shapes: ({
    bell: ["M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 2h-14z", "M10 20.5a2 2 0 0 0 4 0"],
    cmd: ["M9 9V6.5A2.5 2.5 0 1 0 6.5 9H17.5A2.5 2.5 0 1 0 15 6.5V17.5A2.5 2.5 0 1 0 17.5 15H6.5A2.5 2.5 0 1 0 9 17.5Z"],
    projects: [circ(6, 6, 2) + circ(6, 18, 2) + circ(18, 8, 2), "M6 8v8M18 10c0 4-6 3-11.2 6.6"],
    // Claude: its own starburst, filled, one colour like the rest
    agents: ["M6.25 15.09L9.97 13.00L10.04 12.82L9.97 12.72L9.79 12.72L9.17 12.68L7.04 12.62L5.20 12.55L3.41 12.45L2.96 12.36L2.54 11.80L2.58 11.52L2.96 11.27L3.50 11.32L4.70 11.40L6.49 11.52L7.80 11.60L9.73 11.80L10.04 11.80L10.08 11.68L9.97 11.60L9.89 11.52L8.03 10.26L6.02 8.93L4.97 8.16L4.40 7.78L4.11 7.41L3.98 6.62L4.50 6.05L5.20 6.09L5.37 6.14L6.08 6.68L7.58 7.85L9.55 9.29L9.83 9.53L9.95 9.45L9.96 9.39L9.83 9.18L8.77 7.25L7.63 5.28L7.12 4.47L6.98 3.98C6.94 3.78 6.90 3.61 6.90 3.41L7.49 2.61L7.82 2.50L8.60 2.61L8.93 2.89L9.42 4.01L10.21 5.77L11.44 8.16L11.80 8.87L11.99 9.52L12.06 9.73L12.19 9.73L12.19 9.61L12.29 8.26L12.47 6.61L12.66 4.48L12.72 3.88L13.02 3.17L13.61 2.78L14.07 3.00L14.44 3.54L14.39 3.89L14.17 5.35L13.72 7.64L13.44 9.17L13.61 9.17L13.80 8.98L14.57 7.95L15.88 6.32L16.45 5.68L17.12 4.96L17.55 4.62L18.37 4.62L18.97 5.51L18.70 6.43L17.86 7.50L17.17 8.40L16.17 9.74L15.55 10.81L15.60 10.90L15.75 10.88L18.00 10.41L19.22 10.19L20.67 9.94L21.33 10.24L21.40 10.55L21.14 11.19L19.59 11.57L17.77 11.94L15.06 12.58L15.02 12.61L15.06 12.65L16.28 12.77L16.81 12.80L18.09 12.80L20.47 12.97L21.09 13.39L21.46 13.89L21.40 14.27L20.44 14.76L19.15 14.45L16.13 13.74L15.10 13.48L14.95 13.48L14.95 13.56L15.81 14.41L17.40 15.83L19.37 17.67L19.47 18.13L19.22 18.49L18.95 18.45L17.21 17.14L16.54 16.55L15.02 15.27L14.92 15.27L14.92 15.41L15.27 15.92L17.12 18.70L17.22 19.55L17.08 19.83L16.60 20.00L16.08 19.90L14.99 18.38L13.88 16.67L12.98 15.14L12.87 15.20L12.34 20.93L12.09 21.22L11.51 21.44L11.03 21.08L10.78 20.49L11.03 19.32L11.34 17.80L11.59 16.60L11.81 15.10L11.95 14.60L11.94 14.56L11.83 14.58L10.70 16.13L8.98 18.46L7.62 19.91L7.29 20.04L6.72 19.75L6.78 19.23L7.09 18.76L8.98 16.37L10.11 14.88L10.85 14.02L10.84 13.90L10.80 13.90L5.80 17.15L4.90 17.26L4.52 16.90L4.57 16.31L4.75 16.12L6.25 15.09L6.25 15.09Z"],
    dock: [rrect(3, 4, 18, 16, 3), "M7 16h10"],
    glass: ["M12 3.5c3 3.6 5.5 6.6 5.5 10a5.5 5.5 0 0 1-11 0c0-3.4 2.5-6.4 5.5-10z", "M9.5 14.5a2.5 2.5 0 0 0 2.5 2.5"],
    plugins: ["M10 4h4v3a2 2 0 1 0 0 4h3v4h-3a2 2 0 1 0 0 4v1h-4v-3a2 2 0 1 0-4 0v3H4v-4h1a2 2 0 1 0 0-4H4V7h6z"],
    update: ["M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19.5h14"],
    cloud: ["M7.5 18h9a3.5 3.5 0 0 0 .4-7A5 5 0 0 0 7.3 9.6 4.2 4.2 0 0 0 7.5 18z"],
    sun: [circ(12, 12, 4), "M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"],
    partly: ["M8.5 3.5v1.6M3.7 5.6l1.1 1.1M2.5 10.5h1.6M13.3 5.6l-1.1 1.1M5.6 12.6A3.6 3.6 0 0 1 11.9 8.9",
             "M9.5 20h7.5a3.2 3.2 0 0 0 .3-6.4A4.6 4.6 0 0 0 8.6 12.3 3.9 3.9 0 0 0 9.5 20z"],
    moon: ["M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z"],
    rain: ["M7.5 14.5h9a3.5 3.5 0 0 0 .4-7A5 5 0 0 0 7.3 6.1 4.2 4.2 0 0 0 7.5 14.5z", "M9 17l-1 2.5M13 17l-1 2.5M17 17l-1 2.5"],
    snow: ["M7.5 14.5h9a3.5 3.5 0 0 0 .4-7A5 5 0 0 0 7.3 6.1 4.2 4.2 0 0 0 7.5 14.5z", circ(9, 18, .7) + circ(12, 20.5, .7) + circ(15, 18, .7)],
    storm: ["M7.5 14.5h9a3.5 3.5 0 0 0 .4-7A5 5 0 0 0 7.3 6.1 4.2 4.2 0 0 0 7.5 14.5z", "M12.5 15.5l-2 3h3l-2 3"],
    fog: ["M4 8h16M6 12h12M4 16h16"],
    mic: [rrect(9, 3.5, 6, 11, 3), "M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v2.5"],
    slash: ["M4 4l16 16"],
    bluetooth: ["M7 7l10 10-5 4V3l5 4L7 17"],
    btdots: [circ(3.8, 12, .7) + circ(20.2, 12, .7)],
    wifi3: ["M2.8 9.2a13 13 0 0 1 18.4 0"], wifi2: ["M5.8 12.4a8.6 8.6 0 0 1 12.4 0"], wifi1: ["M8.9 15.5a4.3 4.3 0 0 1 6.2 0"],
    wifidot: [circ(12, 18.6, .9)],
    lan: [rrect(9, 3, 6, 5, 1) + rrect(3, 15, 5, 5, 1) + rrect(16, 15, 5, 5, 1), "M12 8v3.5M5.5 15v-3.5h13V15"],
    speaker: ["M4 9.5h3.5L12 5.5v13l-4.5-4H4z"], wave1: ["M15.5 9.2a4 4 0 0 1 0 5.6"], wave2: ["M18 7a7 7 0 0 1 0 10"],
    mute: ["M16 9.5l5 5M21 9.5l-5 5"],
    sunCore: [circ(12, 12, 3.6)],
    screen: [rrect(3.5, 4.5, 17, 12, 2.2), "M9.5 20h5M12 16.5V20"],
    // two screens side by side, the arranger's
    monitors: [rrect(2.5, 6, 9, 7, 1.6), rrect(13, 4.5, 8.5, 10, 1.6), "M5.5 16.5h3M15.5 18h3.5"],
    battery: [rrect(3, 7.5, 16, 9, 2.5), "M21 10.5v3"],
    bolt: ["M11.8 9.2l-2 3h3l-2 3"],
    phone: [rrect(6.5, 2.5, 11, 19, 2.8), "M10.5 5h3"],
    // two switches, one on and one off (the control-centre glyph)
    tools: ["M8 4.5h8a3 3 0 0 1 0 6H8a3 3 0 0 1 0-6z", "M16 6.1a1.4 1.4 0 1 0 0 2.8a1.4 1.4 0 1 0 0-2.8z", "M8 13.5h8a3 3 0 0 1 0 6H8a3 3 0 0 1 0-6z", "M8 15.1a1.4 1.4 0 1 0 0 2.8a1.4 1.4 0 1 0 0-2.8z"],
    // the switches' tracks alone; the knobs are blocks that slide
    toolTracks: ["M8 4.5h8a3 3 0 0 1 0 6H8a3 3 0 0 1 0-6z", "M8 13.5h8a3 3 0 0 1 0 6H8a3 3 0 0 1 0-6z"],
    // Island Kit's catalog: a toolcase whose handle is the notch's pill; the
    // latch is a block that slides
    kit: [rrect(2.8, 8, 18.4, 12.2, 3), "M8 8V6.2a1.8 1.8 0 0 1 1.8-1.8h4.4A1.8 1.8 0 0 1 16 6.2V8", "M2.8 13h7.2M14 13h7.2"],
  })
  // A knob of the tools glyph (stroked circle, r 1.4 on the path's centre).
  function knobBlock(cx, cy) { return { x: cx - 2.3, y: cy - 2.3, w: 4.6, h: 4.6, r: 2.3, a: 1, f: false } }
  function partsOf(names, alpha, fill) {
    var out = []
    for (var i = 0; i < names.length; i++) {
      var list = shapes[names[i]] || []
      for (var j = 0; j < list.length; j++) out.push({ d: list[j], a: alpha === undefined ? 1 : alpha, f: !!fill })
    }
    return out
  }
  readonly property var fixedShapes: ({
    "evindor.keystroke": "cmd", "omarchy.agents": "agents", "io.github.hugorolimf.dock": "dock",
    "io.github.fasi96.liquid-glass": "glass", "omaplug": "plugins", "io.github.hugorolimf.monitores": "monitors"
  })
  // Nerd Font weather glyph of the weather widget -> our shape.
  readonly property var weatherShapes: ({
    "e30d": "sun", "e32b": "moon", "e302": "partly", "e32e": "partly", "e33d": "cloud", "e313": "fog", "e346": "fog",
    "e308": "rain", "e333": "rain", "e30a": "snow", "e327": "snow", "e3ad": "snow", "e31d": "storm", "e318": "rain", "e31a": "snow"
  })

  // First glyph a widget paints (the weather widget keeps its icon on an
  // inner button's text).
  function paintedGlyph(item, depth) {
    if (!item || depth > 4) return ""
    if (typeof item.text === "string" && item.text.length > 0 && item.text.charCodeAt(0) >= 0xe000) return item.text
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var g = paintedGlyph(kids[i], depth + 1)
      if (g) return g
    }
    return ""
  }

  readonly property var clonedKinds: ["power", "audio", "network", "bluetooth", "monitor", "weather", "agents", "microphone", "media", "system-update"]
  // Island plugins are known by their published ids (io.github.hugorolimf.*).
  // Local hugo.* copies of them read as the published ids; the tools drawer
  // is part of this plugin and the notification history is Island Inbox.
  readonly property string selfId: "io.github.hugorolimf.bar"
  readonly property var legacyIds: ({ "hugo.tools": selfId, "hugo.notifcenter": "io.github.hugorolimf.inbox" })
  function canon(id) {
    id = String(id || "")
    if (legacyIds[id]) return legacyIds[id]
    return id.indexOf("hugo.") === 0 ? "io.github.hugorolimf." + id.slice(5) : id
  }
  // Clones are drawn and named as their original (Island Panels' power is
  // omarchy.power).
  function kindOf(id) {
    var c = canon(id)
    var m = /^io\.github\.hugorolimf\.(.+)$/.exec(c)
    return m && clonedKinds.indexOf(m[1]) >= 0 ? "omarchy." + m[1] : c
  }

  // The object a module's state is read from. A plugin's bar entry can be a
  // thin loader (Entry.qml) that keeps the real widget in `inner`; every
  // state read (iconFor, liveLabel) goes through here so both shapes work.
  function moduleState(item) { return item && item.inner ? item.inner : item }

  function iconFor(id, item) {
    item = moduleState(item)
    // the entry's own "install Island Kit" button stays visible
    if (!item || item.needsKit === true) return null
    try {
      if (id === "io.github.hugorolimf.iphone") {
        // Phone outline; the battery fills it from the bottom and glides as
        // it changes. Out of reach: dim and empty.
        var bat = typeof item.battery === "number" ? item.battery : -1
        var on = item.connected === true
        var lv = on && bat >= 0 ? Math.min(1, bat / 100) : 0
        return { key: "iphone" + (on ? Math.round(bat / 10) : "off"), fam: "phone",
                 tone: !on ? "dim" : bat >= 0 && bat < 10 ? "red" : bat >= 0 && bat < 20 ? "amber" : "",
                 badge: on && item.unread > 0 ? item.unread : 0, parts: partsOf(["phone"]),
                 blocks: [{ x: 8.5, y: 17.5 - 11 * lv, w: 7, h: Math.max(0.6, 11 * lv), r: 1, a: on && bat >= 0 ? 0.85 : 0, f: true }] }
      }
      // Do Not Disturb: the bell red and slashed. `ring` swings it (a clear).
      if (id === "io.github.hugorolimf.inbox") {
        var dnd = item.dnd === true
        return { key: dnd ? "bell-dnd" : "bell", fam: "bell", tone: dnd ? "red" : item.opened === true ? "blue" : "",
                 badge: item.unseen > 0 ? item.unseen : 0, ring: item.clearSerial || 0, slash: dnd, parts: partsOf(["bell"]) }
      }
      // Two switches whose knobs swap sides while the drawer is open.
      if (id === "io.github.hugorolimf.bar") {
        var open = root.drawerOpen || root.drawerEdit
        return { key: open ? "tools-open" : "tools", fam: "tools", tone: open || item.opened === true ? "blue" : "", parts: partsOf(["toolTracks"]),
                 blocks: [knobBlock(open ? 8 : 16, 7.5), knobBlock(open ? 16 : 8, 16.5)] }
      }
      // The case's latch drops open while the catalog is open.
      if (id === "io.github.hugorolimf.kit") {
        var kitOpen = item.opened === true
        return { key: kitOpen ? "kit-open" : "kit", fam: "kit", tone: kitOpen ? "blue" : "", parts: partsOf(["kit"]),
                 blocks: [{ x: 10, y: kitOpen ? 13.4 : 11.6, w: 4, h: 2.8, r: 1.4, a: 1, f: false }] }
      }
      // AI usage: the starburst turns once each time the share moves.
      if (id === "omarchy.agents") {
        var hl = item.headline
        var pc = hl && hl.percent >= 0 ? hl.percent : -1
        return { key: "agents", fam: "agents", always: pc >= 0, spin: pc >= 0 ? Math.round(pc * 100) : -1,
                 tone: pc >= 0.9 ? "red" : pc >= 0.7 ? "amber" : "", parts: partsOf(["agents"], 1, true) }
      }
      if (fixedShapes[id]) return { key: fixedShapes[id], fam: fixedShapes[id], parts: partsOf([fixedShapes[id]]) }
      if (id === "omarchy.system-update") return { key: "update", fam: "update", tone: "amber", parts: partsOf(["update"]) }
      if (id === "techspawn.projects") return { key: "projects", fam: "projects", badge: item.attention > 0 ? item.attention : 0, parts: partsOf(["projects"]) }
      if (id === "omarchy.weather") {
        var g = paintedGlyph(item, 0)
        var w = g ? weatherShapes[g.charCodeAt(0).toString(16)] : ""
        // a new sky fades in (fam) instead of swapping
        return w ? { key: "w-" + w, fam: "w-" + w, parts: partsOf([w]) } : null
      }
      // Sound: the waves fade with the volume; muted, they go and a red
      // cross grows beside the speaker.
      if (id === "omarchy.audio" && "outputVolume" in item) {
        var v = item.outputVolume, muted = item.outputMuted === true
        return { key: muted ? "mute" : "vol" + (v <= 0.001 ? 0 : v < 0.5 ? 1 : 2), fam: "speaker", tone: muted ? "red" : "", cross: muted,
                 parts: partsOf(["speaker"]).concat(partsOf(["wave1"], !muted && v > 0.001 ? 1 : 0),
                                                    partsOf(["wave2"], muted || v <= 0.001 ? 0 : v >= 0.5 ? 1 : 0.3)) }
      }
      // Network: cable; Wi-Fi bars lit by the signal; Wi-Fi on but joined to
      // nothing: faint bars in amber; Wi-Fi switched off: red and slashed.
      if (id === "omarchy.network") {
        if (item.kind === "ethernet") return { key: "lan", fam: "lan", parts: partsOf(["lan"]) }
        if (item.kind !== "wifi") {
          var radioOff = item.wifiEnabled === false
          return { key: radioOff ? "wifi-off" : "nowifi", fam: "wifi", tone: radioOff ? "red" : "amber", slash: radioOff,
                   parts: partsOf(["wifi3", "wifi2", "wifi1"], radioOff ? 0.5 : 0.35).concat(partsOf(["wifidot"], radioOff ? 0.5 : 1, true)) }
        }
        var sig = item.signalStrength > 0 ? item.signalStrength : 100
        return { key: "wifi" + (sig < 34 ? 1 : sig < 67 ? 2 : 3), fam: "wifi",
                 parts: partsOf(["wifi3"], sig >= 67 ? 1 : 0.3).concat(partsOf(["wifi2"], sig >= 34 ? 1 : 0.3), partsOf(["wifi1"]), partsOf(["wifidot"], 1, true)) }
      }
      // Bluetooth: off = dim and slashed; a device connected = blue, with
      // the two dots of a link either side.
      if (id === "omarchy.bluetooth" && "connectedDevices" in item) {
        var btOff = !!item.adapter && item.adapter.enabled === false
        var linked = !btOff && (item.connectedDevices || []).length > 0
        return { key: btOff ? "bt-off" : linked ? "bt-on" : "bt", fam: "bt", tone: btOff ? "dim" : linked ? "blue" : "", slash: btOff,
                 parts: partsOf(["bluetooth"]).concat(partsOf(["btdots"], linked ? 1 : 0, true)) }
      }
      if (id === "omarchy.microphone" && "muted" in item) {
        if (item.muted) return { key: "mic-off", fam: "mic", tone: "dim", slash: true, parts: partsOf(["mic"]) }
        return { key: item.inUse ? "mic-live" : "mic", fam: "mic", tone: item.inUse ? "red" : "", parts: partsOf(["mic"]) }
      }
      if (id === "omarchy.monitor") {
        // a screen on its stand (the weather keeps the sun); the light in it
        // grows with the brightness, and night light warms it amber
        var b = item.brightnessAvailable ? item.brightnessPercent : 50
        var r = 1 + Math.round(b / 100 * 4) * 0.4
        return { key: "screen" + Math.round(r * 10) + (item.nightlightOn === true ? "n" : ""), fam: "screen", tone: item.nightlightOn === true ? "amber" : "",
                 parts: partsOf(["screen"]), blocks: [{ x: 12 - r, y: 10.5 - r, w: 2 * r, h: 2 * r, r: r, a: 1, f: true }] }
      }
      if ((id === "omarchy.power" || id === "io.github.hugorolimf.power")) {
        // The level glides; plugged in it pales under a bolt and turns green.
        var d = UPower.displayDevice
        if (!d || !d.isLaptopBattery) return null
        var pct = d.percentage <= 1.0001 ? d.percentage * 100 : d.percentage
        var charging = d.state === UPowerDeviceState.Charging || d.state === UPowerDeviceState.FullyCharged
        var tone = charging ? "green" : pct < 10 ? "red" : pct < 20 ? "amber" : ""
        return { key: "bat" + Math.round(pct / 10) + (charging ? "c" : ""), fam: "battery", tone: tone,
                 parts: partsOf(["battery"]).concat(partsOf(["bolt"], charging ? 1 : 0)),
                 blocks: [{ x: 5, y: 9.5, w: Math.max(1, 12 * Math.min(1, pct / 100)), h: 5, r: 1, a: charging ? 0.35 : 0.85, f: true }] }
      }
    } catch (e) {}
    return null
  }
  function toneColor(tone) {
    if (tone === "green") return "#6be0a0"
    if (tone === "amber") return "#f5c26b"
    if (tone === "red") return "#ff6b6b"
    if (tone === "blue") return "#6b9bff"
    if (tone === "dim") return Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.45)
    return barForeground
  }

  // ---- Tools drawer (the tools button) ----------------------------------
  // Tools marked `"drawer": true` in shell.json stay off the bar until the
  // drawer opens; it opens inside the bar (not in a separate window), so
  // their panels still anchor under their icons. Right click on the button
  // = organise mode: every tool gets a pin (pinned = always on the bar),
  // and installed bar widgets that are nowhere yet show up to be added.
  property bool drawerOpen: false
  // Ids kept in the drawer right now ("drawer": true in the layout).
  readonly property var drawerIds: {
    var patched = layoutPatchSerial
    var out = ({}), list = layoutEntries("right")
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (e && typeof e === "object" && e.drawer) out[root.entryId(e)] = true
    }
    return out
  }
  property bool drawerEdit: false
  function toggleDrawer() { drawerEdit = false; drawerOpen = !drawerOpen }
  function toggleDrawerEdit() { drawerEdit = !drawerEdit; drawerOpen = drawerEdit }
  Timer {
    id: drawerCloseTimer
    interval: 1500
    onTriggered: if (!root.barHovered && !root.activePopout && !root.drawerEdit) root.drawerOpen = false
  }
  onBarHoveredChanged: if (!barHovered && drawerOpen) drawerCloseTimer.restart()

  function setInDrawer(id, inDrawer) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    root.shell.mutateShellConfig(function(config) {
      var right = config.bar && config.bar.layout && config.bar.layout.right
      if (!Array.isArray(right)) return
      for (var i = 0; i < right.length; i++) {
        var e = right[i]
        if (e && typeof e === "object" && e.id === id) {
          if (inDrawer) e.drawer = true
          else delete e.drawer
        }
      }
    })
  }
  // A widget from the catalog joins the tools group, in the drawer.
  function addToDrawer(id) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    root.shell.mutateShellConfig(function(config) {
      var right = config.bar && config.bar.layout && config.bar.layout.right
      if (!Array.isArray(right)) return
      var at = -1
      for (var i = 0; i < right.length; i++) if (right[i] && right[i].group === "ferramentas") at = i
      right.splice(at < 0 ? right.length : at + 1, 0, { id: id, group: "ferramentas", drawer: true })
    })
  }
  // Installed bar widgets placed nowhere on the bar yet (organise mode).
  readonly property var hiddenCatalog: ["omarchy.spacer", "omarchy.clock", "omarchy.workspaces", "omarchy.menu",
    "omarchy.active-window", "io.github.hugorolimf.bar", "omarchy.media", "yakumy.station"]
  readonly property var drawerCatalog: drawerEdit ? catalogList() : []
  function catalogList() {
    var w = root.barWidgetRegistry.widgets, used = ({}), out = []
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layoutEntries(sections[s])
      for (var i = 0; i < list.length; i++) used[root.entryId(list[i])] = true
    }
    for (var id in w) {
      if (used[id] || hiddenCatalog.indexOf(root.canon(id)) >= 0) continue
      // a clone replaces its original (Island Panels' power stands for omarchy.power)
      var base = id.replace(/^omarchy\./, "")
      if (used["io.github.hugorolimf." + base] || used["hugo." + base]) continue
      var meta = w[id].metadata || {}
      out.push({ id: id, name: String(meta.displayName || meta.name || id), desc: String(meta.description || "") })
    }
    out.sort(function(a, b) { return a.name.localeCompare(b.name) })
    return out
  }

  // ---- Tools panel (ToolsPanel.qml) --------------------------------------
  // The panel is its own plugin; what it shows and changes lives here, so it
  // asks over IPC: every tool with its Portuguese name, what it does, its
  // live value and the same stroke icon the bar draws.
  // Names for widgets the hover tips do not cover.
  readonly property var toolExtraTips: ({
    "omarchy.microphone": "Microfone — ligar e silenciar o microfone",
    "omarchy.keyboard-layout": "Teclado — trocar o layout do teclado",
    "io.github.hugorolimf.island": "Ilha dinâmica — ditado, música, gravação e notificações no notch"
  })
  // Icons for widgets the bar draws as text (clock, keyboard, notch).
  readonly property var toolExtraPaths: ({
    "io.github.hugorolimf.clock": ["M12 4a8 8 0 1 0 0 16a8 8 0 1 0 0-16z", "M12 8v4l2.5 2"],
    "omarchy.keyboard-layout": ["M4 7h16a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1z", "M7 10h.01M10 10h.01M13 10h.01M16 10h.01M8 14h8"],
    "io.github.hugorolimf.island": ["M8 9h8a3 3 0 0 1 0 6H8a3 3 0 0 1 0-6z"]
  })
  function toolNameDesc(id) {
    var tip = String(tipFor(id) || extraTipFor(id) || "")
    var cut = tip.indexOf(" — ")
    var meta = null
    try { meta = root.barWidgetRegistry.metadataFor(root.canonicalWidgetId(id)) } catch (e) { meta = null }
    return {
      name: cut >= 0 ? tip.slice(0, cut) : String((meta && (meta.displayName || meta.name)) || id),
      desc: cut >= 0 ? tip.slice(cut + 3) : String((meta && meta.description) || "")
    }
  }
  // Everything on the bar, in bar order, tagged with the island it sits in.
  // Only island entries can be kept in the drawer (pin), and only tools can
  // leave the bar from the panel (the rest are the system's own).
  readonly property var toolsSkipped: ["omarchy.tray", "omarchy.indicators", "io.github.hugorolimf.bar", "omarchy.spacer"]
  function toolsReport() {
    var tools = [], regions = ["left", "center", "right"]
    for (var r = 0; r < regions.length; r++) {
      var list = layoutEntries(regions[r])
      for (var i = 0; i < list.length; i++) {
        var e = list[i]
        var obj = !!e && typeof e === "object"
        var id = root.entryId(e)
        if (!id || toolsSkipped.indexOf(root.canon(id)) >= 0) continue
        var group = obj && e.group ? String(e.group) : "outros"
        var item = root.moduleWidgets(id)[0] || null
        // clones (Island AI Usage) are drawn and named as their original
        var kind = root.kindOf(id)
        var icon = null, value = ""
        try { icon = iconFor(kind, item) } catch (err) { icon = null }
        try { value = String(liveLabel(kind, item, true) || "") } catch (err) { value = "" }
        var cid = root.canon(id)
        var nd = toolNameDesc(tipFor(cid) || extraTipFor(cid) ? cid : kind)
        // hover tips speak of clicks ("clique para ver a previsão · botão
        // direito …"); the panel wants what it does ("Ver a previsão")
        nd.desc = nd.desc.split(" · ")[0].replace(/^(clique para|click to) (abrir$|open$)?/i, "")
        if (cid === "io.github.hugorolimf.clock") nd.desc = tr("data, hora e o calendário do mês")
        if (!nd.desc) nd.desc = tr("abrir")
        nd.desc = nd.desc.charAt(0).toUpperCase() + nd.desc.slice(1)
        var paths = []
        if (icon && icon.parts) for (var j = 0; j < icon.parts.length; j++) if (!(icon.parts[j].a < 0.05)) paths.push(icon.parts[j].d)
        if (icon && icon.slash) paths.push(slashPath)
        if (icon && icon.cross) paths.push(crossPath)
        if (paths.length === 0 && toolExtraPaths[cid]) paths = toolExtraPaths[cid]
        if (paths.length === 0 && kind === "omarchy.weather") paths = shapes.cloud || []
        tools.push({ id: id, name: nd.name, desc: nd.desc, group: group, value: value,
                     pinned: !(obj && e.drawer), canPin: regions[r] === "right" && obj && !!e.group,
                     canRemove: group === "ferramentas",
                     badge: icon && icon.badge ? icon.badge : 0, paths: paths,
                     fill: !!(icon && icon.parts && icon.parts.length && icon.parts[0].f) })
      }
    }
    return { tools: tools, catalog: catalogList() }
  }
  // Off the bar entirely (still installed; the panel offers it again).
  function removeTool(id) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    root.shell.mutateShellConfig(function(config) {
      var right = config.bar && config.bar.layout && config.bar.layout.right
      if (!Array.isArray(right)) return
      for (var i = right.length - 1; i >= 0; i--)
        if (right[i] && typeof right[i] === "object" && right[i].id === id && right[i].group === "ferramentas") right.splice(i, 1)
    })
  }
  // Open a tool's own panel under its icon: unfold the drawer first (a tool
  // kept there has no width yet), then press it on the focused monitor. The
  // drawer stays open while that panel is.
  property string pendingTool: ""
  function openTool(id) {
    pendingTool = String(id || "")
    if (!pendingTool) return
    drawerOpen = true
    openToolTimer.restart()
  }
  Timer {
    id: openToolTimer
    interval: 480
    onTriggered: {
      var id = root.pendingTool, screen = root.focusedScreenName(), pick = null
      root.pendingTool = ""
      for (var i = 0; i < root.moduleSlots.length; i++) {
        var slot = root.moduleSlots[i]
        if (!slot || !slot.activeItem || slot.moduleName !== id) continue
        if (!pick || root.slotScreenName(slot) === screen) pick = slot
      }
      if (!pick) return
      var item = pick.activeItem
      if (typeof item.open === "function" && item.opened !== undefined) item.open()
      else root.pressModuleClickTarget(pick, Qt.LeftButton, pick.width / 2, pick.height / 2)
    }
  }

  // Value shown beside an icon while it is hovered ("" = nothing to add).
  // Read from the widget itself where it already knows (volume, network,
  // Bluetooth, brightness) and from UPower for the battery.
  function liveLabel(id, item, hovered) {
    item = moduleState(item)
    if (!item || item.needsKit === true) return ""
    try {
      if (id === "io.github.hugorolimf.inbox") {
        var u = item.unseen || 0
        var news = u > 0 ? u + (u === 1 ? root.tr(" nova") : root.tr(" novas")) : ""
        if (item.dnd === true) return hovered ? (news ? news + " · " : "") + root.tr("não perturbe") : news
        return news || (hovered ? root.tr("nenhuma nova") : "")
      }
      if (id === "io.github.hugorolimf.iphone") {
        if (item.connected !== true) return hovered ? root.tr("fora de alcance") : ""
        if (!hovered) return ""
        var parts = []
        if (item.battery >= 0) parts.push(item.battery + "%")
        if (item.unread > 0) parts.push(item.unread + (item.unread === 1 ? root.tr(" não lida") : root.tr(" não lidas")))
        return parts.join(" · ")
      }
      // AI usage (omarchy.agents): always the share of the tightest limit;
      // hovering adds the provider and when that limit resets.
      if (id === "omarchy.agents") {
        var hl = item.headline
        if (!hl || !(hl.percent >= 0)) return ""
        var pct = Math.round(hl.percent * 100) + "%"
        if (!hovered) return pct
        var name = item.provider && item.provider.providerName ? item.provider.providerName + " " : ""
        var ms = hl.resetAt ? new Date(hl.resetAt).getTime() - Date.now() : -1
        return name + pct + (ms > 0 ? root.tr(" · zera em ") + durationText(ms / 1000) : "")
      }
      if (id === "omarchy.audio" && "outputVolume" in item)
        return item.outputMuted ? root.tr("Mudo") : Math.round(item.outputVolume * 100) + "%"
      if (id === "omarchy.network") {
        var net = item.connectedWifiNetwork
        if (net && net.ssid) return net.ssid
        if (item.info && item.info.ssid) return item.info.ssid
        if (wifiName !== "") return wifiName
        if (item.kind === "ethernet") return root.tr("Cabo")
        if (item.kind !== "wifi" && item.wifiEnabled === false) return root.tr("Wi‑Fi desligado")
        return item.kind === "wifi" ? "Wi‑Fi" : root.tr("Sem conexão")
      }
      if (id === "omarchy.bluetooth" && "connectedDevices" in item) {
        var devs = item.connectedDevices || []
        if (devs.length > 0) return String(devs[0].name || devs[0].deviceName || root.tr("Conectado")) + (devs.length > 1 ? " +" + (devs.length - 1) : "")
        return item.adapter && item.adapter.enabled === false ? root.tr("Desligado") : root.tr("Nenhum aparelho")
      }
      if (id === "omarchy.monitor" && item.brightnessAvailable) return item.brightnessPercent + "%"
      if (id === "omarchy.microphone" && "muted" in item) return item.muted ? root.tr("Mudo") : root.tr("Ligado")
      // the power mode only when it is not the everyday one
      if ((id === "omarchy.power" || id === "io.github.hugorolimf.power")) {
        var mode = ({ "performance": root.tr("desempenho"), "max-power": root.tr("extremo"), "power-saver": root.tr("economia") })[item.activeProfile] || ""
        var bl = batteryLabel()
        return bl && mode ? bl + " · " + mode : (bl || mode)
      }
    } catch (e) {}
    return ""
  }

  function batteryLabel() {
    var d = UPower.displayDevice
    if (!d || !d.isLaptopBattery) return ""
    var pct = d.percentage <= 1.0001 ? d.percentage * 100 : d.percentage
    var text = Math.round(pct) + "%"
    if (d.state === UPowerDeviceState.Charging) {
      text += root.tr(" · carregando")
      if (d.timeToFull > 0) text += root.tr(", cheia em ") + durationText(d.timeToFull)
    } else if (d.state === UPowerDeviceState.FullyCharged) {
      text += root.tr(" · carregada")
    } else if (d.timeToEmpty > 0) {
      text += " · " + durationText(d.timeToEmpty) + root.tr(" restantes")
    }
    return text
  }

  function durationText(seconds) {
    var h = Math.floor(seconds / 3600), m = Math.round((seconds % 3600) / 60)
    if (h >= 24) return Math.floor(h / 24) + "d" + (h % 24 > 0 ? " " + (h % 24) + "h" : "")
    return h > 0 ? h + "h" + (m < 10 ? "0" : "") + m : m + " min"
  }

  // The bar's own strings are written in Portuguese; every other locale gets
  // English. Texts of the widgets themselves are only translated to Portuguese.
  readonly property bool portuguese: Qt.locale().name.indexOf("pt") === 0
  readonly property var enTips: ({"omarchy.menu": "System menu — click to open · right-click opens a terminal", "yakumy.station": "Station — synced workspaces and displays", "omarchy.weather": "Weather — click for the forecast", "techspawn.projects": "Projects — your git repos: branch, changes, pull and push", "evindor.keystroke": "Keystroke — command palette for apps and actions", "omarchy.agents": "AI agents — limits and usage for Claude, Codex and others", "io.github.hugorolimf.dock": "Dock — dock settings", "io.github.fasi96.liquid-glass": "Liquid Glass — tune the terminals' glass", "omaplug": "Plugins — enable, disable and update plugins", "omarchy.system-update": "Updates available — click to update the system", "omarchy.bluetooth": "Bluetooth — click to see and connect devices · right-click toggles it", "omarchy.network": "Wi‑Fi and network — click to see networks", "omarchy.audio": "Sound — click for volume and outputs · scroll to adjust · right-click mutes", "omarchy.monitor": "Display — brightness and monitors", "omarchy.power": "Battery and power — click for details and power modes", "io.github.hugorolimf.power": "Battery and power — click for details and power modes", "omarchy.tailscale": "Tailscale — private network", "io.github.hugorolimf.clock": "Calendar — click to open", "io.github.hugorolimf.iphone": "iPhone — click to see your messages", "io.github.hugorolimf.bar": "Tools — open and organise the bar's plugins", "io.github.hugorolimf.inbox": "Notifications — history grouped by app", "io.github.hugorolimf.monitores": "Arrange displays — drag screens, resolution, scale and rotation"})
  readonly property var enExtraTips: ({"omarchy.microphone": "Microphone — mute and unmute the microphone", "omarchy.keyboard-layout": "Keyboard — switch the keyboard layout", "io.github.hugorolimf.island": "Island Notch — dictation, music, recording and alerts in the notch"})
  readonly property var enText: ({" nova": " new", " novas": " new", "nenhuma nova": "nothing new", "não perturbe": "do not disturb", "fora de alcance": "out of range", " não lida": " unread", " não lidas": " unread", " · zera em ": " · resets in ", "Mudo": "Muted", "desempenho": "performance", "economia": "power saver", "extremo": "extreme", "Wi‑Fi desligado": "Wi‑Fi off", "Cabo": "Wired", "Sem conexão": "Offline", "Conectado": "Connected", "Desligado": "Off", "Nenhum aparelho": "No devices", "Ligado": "On", " · carregando": " · charging", ", cheia em ": ", full in ", " · carregada": " · charged", " restantes": " left", "data, hora e o calendário do mês": "date, time and the month's calendar", "abrir": "open", "Na gaveta  ·  clique para fixar na barra": "In the drawer  ·  click to pin it to the bar", "Fixo na barra  ·  clique para guardar na gaveta": "Pinned to the bar  ·  click to keep it in the drawer"})
  function tr(text) { return portuguese || enText[text] === undefined ? text : enText[text] }
  function tipFor(id) { return (portuguese ? ptTips[id] : enTips[id]) || "" }
  function extraTipFor(id) { return (portuguese ? toolExtraTips[id] : enExtraTips[id]) || "" }
  function ptText(text) {
    if (!portuguese) return text
    return ptTexts[text] !== undefined ? ptTexts[text] : text
  }

  function showTooltip(target, text) {
    clearTooltip()
    text = ptText(text)

    if (!targetTooltipHovered(target) || !text) {
      tooltipRequest += 1
      return
    }

    var request = tooltipRequest + 1
    tooltipRequest = request
    pendingTooltipTarget = target
    pendingTooltipText = text

    Qt.callLater(function() {
      if (request !== tooltipRequest) return
      if (!targetTooltipHovered(pendingTooltipTarget)) {
        clearTooltip()
        return
      }
      tooltipTarget = pendingTooltipTarget
      tooltipText = pendingTooltipText
      pendingTooltipTarget = null
      pendingTooltipText = ""
      tooltipTimer.restart()
    })
  }

  function hideTooltip(target) {
    if (tooltipTarget !== target && pendingTooltipTarget !== target) return

    tooltipRequest += 1
    clearTooltip()
  }

  Timer {
    id: tooltipTimer
    interval: 400
    onTriggered: {
      if (root.targetTooltipHovered(root.tooltipTarget)) root.tooltipShown = true
      else root.clearTooltip()
    }
  }

  Timer {
    interval: 100
    running: root.tooltipShown
    repeat: true
    onTriggered: if (!root.targetTooltipHovered(root.tooltipTarget)) root.hideTooltip(root.tooltipTarget)
  }

  // Presence of the `bar-off` flag = bar hidden. Watching the parent toggles
  // directory because FileView can't observe a file that doesn't exist yet,
  // and the flag is created/removed by `omarchy-toggle-bar`.
  Process {
    id: barHiddenProbe
    running: true
    command: ["bash", "-c", "[[ -f $HOME/.local/state/omarchy/toggles/bar-off ]] && echo yes || echo no"]
    stdout: SplitParser { onRead: function(line) { root.barHidden = String(line).trim() === "yes" } }
  }
  FileView {
    path: root.home + "/.local/state/omarchy/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: barHiddenProbe.running = true
  }

  // The directory watch can permanently stop delivering events after flag
  // changes land in quick succession, stranding the bar off screen until the
  // shell restarts. `omarchy-toggle-bar` nudges this after flipping the flag
  // so the probe re-reads it even when the watch has gone quiet.
  IpcHandler {
    target: "omarchy.bar"

    // Start rather than restart: a probe already in flight was launched by the
    // directory watch after the flag flipped, so its answer is current, and
    // killing it here can swallow the result entirely.
    function syncHidden(): void {
      barHiddenProbe.running = true
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarPanel {
        required property var modelData

        screen: modelData
      }
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      DragGhostPanel {
        required property var modelData

        screen: modelData
        ghostScreen: modelData
      }
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarMoveGhostPanel {
        required property var modelData

        screen: modelData
        ghostScreen: modelData
      }
    }
  }

  component BarPanel: PanelWindow {
    id: barWindow

    // Hiding parks the bar just past its screen edge instead of unmapping it.
    // Unmapping frees the layer surface and the whole scene graph, so every
    // reveal has to rebuild them — new surface, re-shaped glyphs, re-uploaded
    // textures — which measures ~150ms against ~20ms to tear down. Parking
    // keeps the surface alive, so showing is only a margin change.
    visible: !remapGuard.remapping
    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto

    ScreenMoveRemap {
      id: remapGuard
      window: barWindow
    }

    margins {
      top: root.barHidden && root.position === "top" ? -root.barSize : 0
      bottom: root.barHidden && root.position === "bottom" ? -root.barSize : 0
      left: root.barHidden && root.position === "left" ? -root.barSize : 0
      right: root.barHidden && root.position === "right" ? -root.barSize : 0
    }

    anchors {
      top: root.position === "top" || root.vertical
      bottom: root.position === "bottom" || root.vertical
      left: root.position === "left" || !root.vertical
      right: root.position === "right" || !root.vertical
    }

    implicitWidth: root.vertical ? root.barSize : 0
    implicitHeight: root.vertical ? 0 : root.barSize
    color: root.transparent ? "transparent" : root.background
    surfaceFormat.opaque: false
    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top

    Loader {
      anchors.fill: parent
      sourceComponent: root.vertical ? verticalBar : horizontalBar

      // A child of the loader, not a sibling of the sections: an ancestor stays
      // hovered while the pointer is over a widget, where a sibling would lose
      // hover to the section the pointer entered.
      HoverHandler {
        onHoveredChanged: root.setBarHovered(hovered)
        // Unplugging a monitor destroys its bar without a leave event, which
        // would strand this surface's tally and hold the peek open for good.
        Component.onDestruction: if (hovered) root.setBarHovered(false)
      }
    }

    PopupWindow {
      id: tooltipWindow

      visible: root.tooltipShown && root.tooltipTarget !== null && root.tooltipText !== "" && root.targetBelongsToWindow(root.tooltipTarget, barWindow)
      color: "transparent"
      implicitWidth: Math.ceil(tooltipBubble.implicitWidth)
      implicitHeight: Math.ceil(tooltipBubble.implicitHeight)

      anchor {
        id: tooltipAnchor
        window: barWindow
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
          var target = root.tooltipTarget
          if (!root.targetBelongsToWindow(target, barWindow)) return

          var popupWidth = tooltipWindow.implicitWidth
          var popupHeight = tooltipWindow.implicitHeight
          var localX = target.width / 2 - popupWidth / 2
          var localY = target.height + 6

          if (root.position === "bottom") {
            localY = -popupHeight - 6
          } else if (root.position === "left") {
            localX = target.width + 6
            localY = target.height / 2 - popupHeight / 2
          } else if (root.position === "right") {
            localX = -popupWidth - 6
            localY = target.height / 2 - popupHeight / 2
          }

          var point = barWindow.contentItem.mapFromItem(target, localX, localY)
          tooltipAnchor.rect.x = Math.round(point.x)
          tooltipAnchor.rect.y = Math.round(point.y)
        }
      }

      // Island Bar: anatomy tooltip — near-black card, hairline rim, the
      // value (before "·") bright, the explanation muted.
      Rectangle {
        id: tooltipBubble
        implicitWidth: tooltipLabel.implicitWidth + 20
        implicitHeight: tooltipLabel.implicitHeight + 12
        color: Qt.rgba(0.043, 0.043, 0.043, 0.96)
        border.width: 0.6
        border.color: Qt.rgba(1, 1, 1, 0.09)
        radius: 8
        opacity: tooltipWindow.visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }

        Text {
          id: tooltipLabel
          textFormat: Text.StyledText
          anchors.centerIn: parent
          text: {
            var t = String(root.tooltipText).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            var i = t.indexOf("  ·  ")
            return i > 0 ? "<font color='#8a8a8f'>" + t.slice(0, i) + "  ·  </font><font color='#e6e6e6'>" + t.slice(i + 5) + "</font>" : t
          }
          color: "#a3a3a3"
          font.family: root.fontFamily
          font.pixelSize: 12
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
    }

    Component {
      id: horizontalBar

      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent }

        LeftModules {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        RightModules {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    Component {
      id: verticalBar

      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent }

        LeftModules {
          anchors.top: parent.top
          anchors.topMargin: Style.space(8)
          anchors.horizontalCenter: parent.horizontalCenter
        }

        RightModules {
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(8)
          anchors.horizontalCenter: parent.horizontalCenter
        }
      }
    }
  }

  Component { id: emptyModuleComponent; Item { implicitWidth: 0; implicitHeight: 0; visible: false } }

  component DragGhostPanel: PanelWindow {
    id: ghostWindow

    required property var ghostScreen
    readonly property bool screenMatches: root.barDragScreen === ghostScreen ||
      (root.barDragScreen && ghostScreen && root.barDragScreen.name && ghostScreen.name && root.barDragScreen.name === ghostScreen.name)
    readonly property bool active: root.barDragSource && root.barDragScreen && screenMatches
    readonly property var sourceItem: root.barDragSource ? root.barDragSource.activeItem : null
    readonly property int ghostPadding: Style.space(1)
    readonly property int ghostWidth: sourceItem ? Math.max(1, Math.ceil(sourceItem.width)) : 1
    readonly property int ghostHeight: sourceItem ? Math.max(1, Math.ceil(sourceItem.height)) : 1

    visible: active && sourceItem !== null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-bar-drag-ghost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    // Visual-only drag feedback. Keep the input region empty so the ghost can
    // sit under the cursor without stealing the MouseArea's active pointer grab.
    mask: Region {}

    Item {
      visible: ghostWindow.visible
      x: Math.round(root.barDragScreenX - root.barDragOffsetX - ghostWindow.ghostPadding)
      y: Math.round(root.barDragScreenY - root.barDragOffsetY - ghostWindow.ghostPadding)
      width: ghostWindow.ghostWidth + ghostWindow.ghostPadding * 2
      height: ghostWindow.ghostHeight + ghostWindow.ghostPadding * 2

      BorderSurface {
        anchors.fill: parent
        color: root.transparent ? "transparent" : root.background
        borderSpec: Border.flat(root.barForeground, 1)
        radius: Math.min(Style.cornerRadius, height / 2)
        opacity: root.transparent ? 0.45 : 0.94
      }

      Image {
        anchors.fill: parent
        anchors.margins: ghostWindow.ghostPadding
        source: root.barDragImageUrl
        fillMode: Image.Stretch
        smooth: true
        opacity: 0.84
      }
    }

    Rectangle {
      readonly property var targetRect: root.barDragTargetGeometry

      visible: ghostWindow.active && targetRect !== null
      x: targetRect ? Math.round(targetRect.x) : 0
      y: targetRect ? Math.round(targetRect.y) : 0
      width: targetRect ? targetRect.width : 0
      height: targetRect ? targetRect.height : 0
      color: Commons.Color.accent
      radius: Math.min(width, height) / 2
    }
  }

  component BarMoveGhostPanel: PanelWindow {
    id: moveGhostWindow

    required property var ghostScreen
    readonly property bool screenMatches: root.barMoveScreen === ghostScreen ||
      (root.barMoveScreen && ghostScreen && root.barMoveScreen.name && ghostScreen.name && root.barMoveScreen.name === ghostScreen.name)
    visible: root.barMoveActive && screenMatches
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-bar-move-ghost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    // Visual-only preview of the candidate edge. Keep the input region empty
    // so the overlay never steals the gesture area's active pointer grab.
    mask: Region {}

    // One fixed-geometry slab per edge, crossfaded on candidate changes.
    // Resizing a single slab between edges repaints mid-transition and
    // flickers; fading between static ones does not.
    Repeater {
      model: ["top", "bottom", "left", "right"]

      BorderSurface {
        id: edgeSlab

        required property string modelData
        readonly property bool edgeVertical: modelData === "left" || modelData === "right"
        readonly property int edgeSize: edgeVertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal

        x: modelData === "right" ? parent.width - edgeSize : 0
        y: modelData === "bottom" ? parent.height - edgeSize : 0
        width: edgeVertical ? edgeSize : parent.width
        height: edgeVertical ? parent.height : edgeSize
        color: root.transparent ? "transparent" : root.background
        borderSpec: Border.flat(root.barForeground, 1)
        visible: opacity > 0
        opacity: root.barMoveCandidate === modelData ? (root.transparent ? 0.45 : 0.7) : 0

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
      }
    }
  }

  function findCenterAnchorEntry() {
    var entries = root.layoutEntries("center")
    var idx = root.entryIndex(entries, root.centerAnchor)
    return idx === -1 ? null : entries[idx]
  }

  component LeftModules: ModuleList {
    entries: root.layoutEntries("left")
    region: "left"
  }

  component RightModules: ModuleList {
    entries: root.layoutEntries("right")
    region: "right"
  }

  component CenterModules: Item {
    id: centerRoot

    property var entries: root.layoutEntries("center")
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1
    readonly property var anchorEntry: root.findCenterAnchorEntry()

    Loader {
      anchors.fill: parent
      sourceComponent: root.vertical ? verticalCenterModules : horizontalCenterModules
    }

    Component {
      id: horizontalCenterModules

      Item {
        anchors.fill: parent

        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesAfter(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.left: centerAnchorModule.right
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }
      }
    }

    Component {
      id: verticalCenterModules

      Item {
        anchors.fill: parent

        CenterGestureArea { anchors.fill: parent }

        HoverHandler {
          onHoveredChanged: root.setCenterSectionHovered(hovered)
        }

        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.bottom: centerAnchorModule.top
          anchors.horizontalCenter: centerAnchorModule.horizontalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesAfter(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.top: centerAnchorModule.bottom
          anchors.horizontalCenter: centerAnchorModule.horizontalCenter
        }
      }
    }
  }

  component CenterGestureArea: MouseArea {
    id: gestureArea

    property bool dragging: false
    property bool suppressClick: false
    property real pressedX: 0
    property real pressedY: 0
    readonly property real dragThreshold: Style.space(4)

    acceptedButtons: Qt.LeftButton
    cursorShape: dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
    pressAndHoldInterval: 200

    function startDrag(x, y) {
      if (dragging) return
      dragging = true
      root.beginBarMove(root.targetWindow(gestureArea))
      var scenePoint = gestureArea.mapToItem(null, x, y)
      root.updateBarMove(root.windowScreenPoint(scenePoint, root.barMoveWindow))
    }

    onPressed: function(mouse) {
      dragging = false
      suppressClick = false
      pressedX = mouse.x
      pressedY = mouse.y
    }

    onPressAndHold: function(mouse) {
      // A widget above us propagates its composed press-and-hold down here without
      // ever handing over the grab, so we'd get no release or cancel to end the move.
      if (!gestureArea.pressed) return
      startDrag(mouse.x, mouse.y)
    }

    onPositionChanged: function(mouse) {
      if (!(mouse.buttons & Qt.LeftButton)) return

      if (!dragging) {
        var distance = Math.abs(mouse.x - pressedX) + Math.abs(mouse.y - pressedY)
        if (distance < dragThreshold) return
        startDrag(mouse.x, mouse.y)
        return
      }

      var scenePoint = gestureArea.mapToItem(null, mouse.x, mouse.y)
      root.updateBarMove(root.windowScreenPoint(scenePoint, root.barMoveWindow))
    }

    onReleased: function(mouse) {
      if (!dragging) return
      dragging = false
      suppressClick = true
      root.finishBarMove()
      mouse.accepted = true
    }

    onCanceled: {
      dragging = false
      suppressClick = false
      root.clearBarMove()
    }

    onClicked: function(mouse) {
      if (suppressClick) {
        suppressClick = false
        mouse.accepted = true
      }
    }

    onDoubleClicked: function(mouse) {
      if (suppressClick) {
        suppressClick = false
        return
      }
      if (mouse.button === Qt.LeftButton) {
        root.toggleTransparency()
        mouse.accepted = true
      }
    }
  }

  component ModuleList: Loader {
    id: moduleListRoot

    property var entries: []
    property string region: ""

    visible: entries.length > 0
    // A hidden list must not build its modules. The center section declares
    // both an anchored and an unanchored arrangement and shows whichever
    // fits, so leaving the other one loaded mounts every center module
    // twice — two IPC handlers registered for the same target, two clocks
    // ticking, two of every timer and fetch behind them.
    active: visible && entries.length > 0
    sourceComponent: root.vertical ? verticalModuleList : horizontalModuleList
    width: item ? item.implicitWidth : 0
    height: item ? item.implicitHeight : 0

    // Island Bar: consecutive entries sharing a "group" (shell.json) sit
    // together on a rounded island; entries without one stand on their own.
    // An island whose icons are all hidden takes no room.
    Component {
      id: horizontalModuleList

      Row {
        spacing: Style.space(6)

        Repeater {
          model: root.islandsOf(moduleListRoot.entries)

          Item {
            id: island
            required property var modelData
            readonly property bool framed: modelData.group !== ""
            readonly property real pad: framed ? Style.space(4) : 0
            // Not `visible: false` when empty: hiding the island would hide its
            // icons too, and a hidden icon reports no width, so it would never
            // come back. An empty island just takes no room.
            readonly property bool empty: islandRow.implicitWidth <= 0
            implicitWidth: empty ? 0 : islandRow.implicitWidth + pad * 2
            implicitHeight: islandRow.implicitHeight
            width: implicitWidth
            height: implicitHeight

            Rectangle {
              visible: island.framed && !island.empty
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: Math.max(0, root.barSize - Style.space(6))
              radius: height / 2
              color: Qt.rgba(1, 1, 1, 0.03)
              border.width: 0.6
              border.color: Qt.rgba(1, 1, 1, 0.08)
            }

            Row {
              id: islandRow
              x: island.pad
              spacing: 0

              Repeater {
                model: island.modelData.entries

                ModuleSlot {
                  required property var modelData
                  entry: modelData
                  region: moduleListRoot.region
                }
              }

              // Organise mode: installed widgets not on the bar yet; a click
              // adds one to the drawer.
              Repeater {
                model: island.modelData.group === "ferramentas" ? root.drawerCatalog : []
                Rectangle {
                  id: chip
                  required property var modelData
                  y: (islandRow.height - height) / 2
                  height: Math.max(0, root.barSize - Style.space(12))
                  width: chipText.implicitWidth + 14
                  radius: height / 2
                  color: chipMouse.containsMouse ? Qt.rgba(0.42, 0.61, 1, 0.22) : Qt.rgba(1, 1, 1, 0.05)
                  border.width: 0.6
                  border.color: Qt.rgba(1, 1, 1, 0.12)
                  Text {
                    id: chipText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "+ " + chip.modelData.name
                    color: "#a3a3a3"
                    font.family: root.monoFamily
                    font.pixelSize: 10
                  }
                  MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.addToDrawer(chip.modelData.id)
                  }
                }
              }
            }
          }
        }
      }
    }

    Component {
      id: verticalModuleList

      Column {
        spacing: 0

        Repeater {
          model: moduleListRoot.entries

          ModuleSlot {
            required property var modelData
            entry: modelData
            region: moduleListRoot.region
          }
        }
      }
    }
  }

  component ModuleSlot: Item {
    id: slot

    required property var entry
    property string region: ""
    readonly property string moduleName: root.entryId(entry)
    readonly property var moduleSettings: root.entrySettings(entry)
    readonly property string customType: root.customModuleType(entry)
    readonly property var registryMetadata: root.barWidgetRegistry.metadataFor(root.canonicalWidgetId(moduleName))
    readonly property bool firstParty: registryMetadata && registryMetadata.firstParty === true
    readonly property string pluginApiId: registered ? root.canonicalWidgetId(moduleName) : "bar-entry:" + moduleName
    // Re-evaluate when the registry mutates (Component reference changes,
    // plugin enabled/disabled, etc.). Reading the `widgets` property creates
    // the binding dependency — the wrapped function call alone wouldn't.
    readonly property var registryComponent: {
      var w = root.barWidgetRegistry.widgets
      if (customType) return null
      var registryName = root.canonicalWidgetId(moduleName)
      return w[registryName] ? w[registryName].component : null
    }
    readonly property bool qmlCustom: customType === "qml"
    readonly property bool commandCustom: customType === "command"
    readonly property bool registered: registryComponent !== null
    readonly property var activeItem: {
      if (registered) return registryLoader.item
      if (qmlCustom) return qmlLoader.item
      return componentLoader.item
    }
    readonly property bool hovered: moduleHover.hovered
    readonly property bool dragSource: root.barDragSource === slot
    readonly property bool panelOpen: root.slotHolds(slot, root.activePopout)
    // Modules bigger than the mark they want (a text label in a padded slot,
    // a multi-line stack on a vertical bar) can say how long the open-panel
    // dot should be along the bar, so it tracks what the module paints
    // instead of a fraction of whatever slot it happens to fill.
    readonly property real panelIndicatorExtent: {
      var key = root.vertical ? "openPanelIndicatorHeight" : "openPanelIndicatorWidth"
      var hint = activeItem && key in activeItem ? activeItem[key] : undefined
      if (hint !== undefined && hint !== null && hint > 0) return Math.round(hint)
      return Math.max(Style.space(10), Math.round((root.vertical ? slot.height : slot.width) * 0.55))
    }
    // Island Bar: the widget keeps its own width (baseWidth); hovering a widget
    // with something to say (volume, network, battery...) widens the slot
    // smoothly and shows that value beside the icon (root.liveLabel).
    readonly property real baseWidth: activeItem && activeItem.visible ? (root.vertical ? root.barSize : activeItem.implicitWidth) : 0
    // eased copy of baseWidth, so icons coming and going slide the bar
    // instead of jumping
    property real shownBase: baseWidth
    Behavior on shownBase { NumberAnimation { duration: 400; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
    // Clones of Omarchy panels (Island Panels: power, audio...) keep the icon,
    // value and tip of the panel they copy.
    readonly property string kindId: root.kindOf(moduleName)
    // Inline value: only labels that are always shown (AI usage) or a peek.
    // Hovering never widens a slot: icons must stay put under the pointer
    // (widening pushed the neighbours away while aiming at them), so the
    // value goes into the tooltip instead.
    readonly property string liveLabel: root.vertical ? "" : root.liveLabel(kindId, activeItem, root.peekValues)
    readonly property var ownIcon: root.vertical ? null : root.iconFor(kindId, activeItem)
    readonly property bool expanded: (root.peekValues || !!(ownIcon && ownIcon.always)) && liveLabel !== "" && !root.barDragSource
    property real labelRoom: expanded ? liveText.implicitWidth + Style.space(8) : 0
    Behavior on labelRoom { NumberAnimation { duration: 450; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
    clip: labelRoom > 0 || shownBase !== baseWidth || drawerShow < 1
    // In the drawer: folded away until the drawer opens.
    // read live from the layout: the slot's own entry is a snapshot that a
    // pin/keep switch does not reach until the bar is rebuilt
    readonly property bool inDrawer: !!root.drawerIds[moduleName]
    readonly property bool isTool: !!(entry && typeof entry === "object" && entry.group === "ferramentas") && root.canon(moduleName) !== root.selfId
    property real drawerShow: inDrawer && !root.drawerOpen && !root.drawerEdit ? 0 : 1
    Behavior on drawerShow { NumberAnimation { duration: 420; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
    implicitWidth: (shownBase + labelRoom) * drawerShow
    implicitHeight: activeItem && activeItem.visible ? activeItem.implicitHeight : 0
    width: implicitWidth
    height: implicitHeight
    opacity: (baseWidth > 0 ? 1 : 0) * drawerShow * (root.drawerEdit && inDrawer ? 0.55 : 1)
    Behavior on opacity { NumberAnimation { duration: 200 } }

    // Soft highlight behind the hovered icon.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(1)
      width: parent.width - Style.space(2)
      height: Math.max(0, root.barSize - Style.space(10))
      radius: height / 2
      color: root.barForeground
      opacity: moduleHover.hovered && !root.barDragSource ? 0.07 : 0
      Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
    }
    z: modulePointer.dragging ? 100 : 0

    Component.onCompleted: root.registerModuleSlot(slot)
    Component.onDestruction: {
      if (root.barDragSource === slot) root.clearBarDrag()
      root.unregisterModuleSlot(slot)
    }

    HoverHandler {
      id: moduleHover
      // Island Bar: describe the icon in Portuguese (see root.ptTips).
      onHoveredChanged: {
        if (hovered && slot.kindId === "omarchy.network") root.refreshWifiName()
        // Short on hover ("Wi-Fi  ·  I.Rolim5G"); the click opens the full panel.
        var value = hovered ? root.liveLabel(slot.kindId, slot.activeItem, true) : ""
        var name = slot.ptTip.split(" — ")[0]
        var tip = value && name ? name + "  ·  " + value : (value || name)
        if (!tip) return
        // slot.tooltipHovered (read by showTooltip) follows this handler's
        // hovered only after this signal returns, so ask on the next turn.
        if (hovered && !root.barDragSource) Qt.callLater(function() { if (moduleHover.hovered) root.showTooltip(slot, tip) })
        else root.hideTooltip(slot)
      }
    }
    readonly property string ptTip: root.tipFor(kindId) || root.tipFor(root.canon(moduleName))
    readonly property bool tooltipHovered: moduleHover.hovered

    BorderSurface {
      visible: slot.dragSource
      anchors.fill: parent
      anchors.margins: Style.space(1)
      color: root.transparent ? "transparent" : root.background
      borderSpec: Border.flat(root.barForeground, 1)
      radius: Math.min(Style.cornerRadius, height / 2)
      opacity: root.transparent ? 0.22 : 0.32
    }

    Loader {
      id: componentLoader
      active: !slot.qmlCustom && !slot.registered
      sourceComponent: slot.commandCustom ? customCommandModuleComponent : emptyModuleComponent
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: slot.baseWidth
      opacity: slot.ownIcon ? 0 : (slot.dragSource ? 0.22 : 1.0)
      // folded into the drawer: hidden, and its button must not take clicks
      // meant for its neighbours (clip hides it, input still reached it)
      enabled: slot.drawerShow > 0.5
      onLoaded: {
        slot.injectProps()
        Qt.callLater(slot.injectProps)
      }
    }

    Loader {
      id: registryLoader
      active: slot.registered
      sourceComponent: slot.registered ? slot.registryComponent : null
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: slot.baseWidth
      opacity: slot.ownIcon ? 0 : (slot.dragSource ? 0.22 : 1.0)
      // folded into the drawer: hidden, and its button must not take clicks
      // meant for its neighbours (clip hides it, input still reached it)
      enabled: slot.drawerShow > 0.5
      onLoaded: {
        slot.injectProps()
        Qt.callLater(slot.injectProps)
      }
    }

    Loader {
      id: qmlLoader
      active: slot.qmlCustom
      source: slot.qmlCustom ? root.customModuleSource(slot.entry) : ""
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: slot.baseWidth
      opacity: slot.ownIcon ? 0 : (slot.dragSource ? 0.22 : 1.0)
      // folded into the drawer: hidden, and its button must not take clicks
      // meant for its neighbours (clip hides it, input still reached it)
      enabled: slot.drawerShow > 0.5
      onLoaded: {
        slot.injectProps()
        Qt.callLater(slot.injectProps)
      }
    }

    // The bar's own icon (root.iconFor), drawn in strokes; it lifts a little
    // on hover and pops when its state changes (volume step, Wi-Fi bars...).
    // Parts fade, blocks glide and the slash or cross draw themselves in, so
    // a change of state reads as a movement, not a swap.
    Item {
      id: ownGlyph
      visible: !!slot.ownIcon
      readonly property real size: 16
      readonly property var icon: slot.ownIcon
      readonly property var parts: icon ? icon.parts || [] : []
      readonly property var blocks: icon ? icon.blocks || [] : []
      // a new tone (red, blue…) eases in instead of switching
      property color ink: root.toneColor(icon ? icon.tone : "")
      Behavior on ink { ColorAnimation { duration: 320; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
      readonly property string key: icon ? icon.key : ""
      readonly property string fam: icon ? icon.fam || icon.key : ""
      // `ring` going up swings the icon from its top, damped (the bell when
      // notifications are cleared)
      readonly property int ring: icon && icon.ring ? icon.ring : 0
      property int ringSeen: 0
      onRingChanged: {
        if (ring > ringSeen) iconRing.restart()
        ringSeen = ring
      }
      // `spin` changing turns the glyph once round its centre (AI usage
      // moving); -1 = nothing to report yet
      readonly property int spin: icon && icon.spin !== undefined ? icon.spin : -1
      property int spinSeen: -1
      onSpinChanged: {
        if (spin >= 0 && spinSeen >= 0 && spin !== spinSeen) iconSpin.restart()
        spinSeen = spin
      }
      transform: [
        Rotation { id: glyphSwing; origin.x: ownGlyph.size / 2; origin.y: 1.5; angle: 0 },
        Rotation { id: glyphTurn; origin.x: ownGlyph.size / 2; origin.y: ownGlyph.size / 2; angle: 0 }
      ]
      SequentialAnimation {
        id: iconRing
        NumberAnimation { target: glyphSwing; property: "angle"; to: -18; duration: 90; easing.type: Easing.OutCubic }
        NumberAnimation { target: glyphSwing; property: "angle"; to: 14; duration: 150; easing.type: Easing.InOutSine }
        NumberAnimation { target: glyphSwing; property: "angle"; to: -9; duration: 140; easing.type: Easing.InOutSine }
        NumberAnimation { target: glyphSwing; property: "angle"; to: 5; duration: 130; easing.type: Easing.InOutSine }
        NumberAnimation { target: glyphSwing; property: "angle"; to: 0; duration: 180; easing.type: Easing.OutCubic }
      }
      NumberAnimation { id: iconSpin; target: glyphTurn; property: "angle"; from: 0; to: 360; duration: 900; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve }
      width: size
      height: size
      x: (slot.baseWidth - size) / 2
      y: (slot.height - size) / 2 - (moduleHover.hovered ? 0.5 : 0)
      opacity: slot.dragSource ? 0.22 : 1.0
      scale: 1
      Behavior on y { NumberAnimation { duration: 350; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
      // same drawing, new state: a small pop; another drawing (Wi-Fi to
      // cable, a new sky): it fades in as it pops
      property string famSeen: ""
      onKeyChanged: {
        if (key === "") return
        if (famSeen !== "" && fam !== famSeen) { glyphBody.opacity = 0; famFade.restart() }
        famSeen = fam
        iconPop.restart()
      }
      SequentialAnimation {
        id: iconPop
        NumberAnimation { target: ownGlyph; property: "scale"; to: 0.82; duration: 90; easing.type: Easing.InCubic }
        NumberAnimation { target: ownGlyph; property: "scale"; to: 1; duration: 420; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve }
      }
      NumberAnimation { id: famFade; target: glyphBody; property: "opacity"; to: 1; duration: 360; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve }

      Item {
        id: glyphBody
        width: 24
        height: 24
        scale: ownGlyph.size / 24
        transformOrigin: Item.TopLeft

        GlyphBlock { spec: ownGlyph.blocks[0]; ink: ownGlyph.ink; curve: root.easeCurve }
        GlyphBlock { spec: ownGlyph.blocks[1]; ink: ownGlyph.ink; curve: root.easeCurve }
        GlyphBlock { spec: ownGlyph.blocks[2]; ink: ownGlyph.ink; curve: root.easeCurve }

        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          GlyphPart { part: ownGlyph.parts[0]; ink: ownGlyph.ink; curve: root.easeCurve }
          GlyphPart { part: ownGlyph.parts[1]; ink: ownGlyph.ink; curve: root.easeCurve }
          GlyphPart { part: ownGlyph.parts[2]; ink: ownGlyph.ink; curve: root.easeCurve }
          GlyphPart { part: ownGlyph.parts[3]; ink: ownGlyph.ink; curve: root.easeCurve }
          GlyphPart { part: ownGlyph.parts[4]; ink: ownGlyph.ink; curve: root.easeCurve }
          GlyphPart { part: ownGlyph.parts[5]; ink: ownGlyph.ink; curve: root.easeCurve }
          GlyphPart { part: ownGlyph.parts[6]; ink: ownGlyph.ink; curve: root.easeCurve }
          GlyphPart { part: ownGlyph.parts[7]; ink: ownGlyph.ink; curve: root.easeCurve }
        }

        // the slash draws across from the top left (Do Not Disturb, radio off)
        GlyphMark {
          path: root.slashPath
          on: !!(ownGlyph.icon && ownGlyph.icon.slash)
          originX: 4
          originY: 4
          ink: ownGlyph.ink
          curve: root.easeCurve
        }
        // the mute cross grows from its own centre
        GlyphMark {
          path: root.crossPath
          on: !!(ownGlyph.icon && ownGlyph.icon.cross)
          originX: 18.5
          originY: 12
          ink: ownGlyph.ink
          curve: root.easeCurve
        }
      }
    }
    // The count pops in, bumps when it changes and shrinks away at zero
    // (keeping its last number while it goes).
    Rectangle {
      id: ownBadge
      readonly property int count: slot.ownIcon && slot.ownIcon.badge > 0 ? slot.ownIcon.badge : 0
      property int shownCount: count
      onCountChanged: {
        if (count <= 0) return
        if (shownCount > 0 && count !== shownCount && opacity > 0.99) badgeBump.restart()
        shownCount = count
      }
      visible: !!slot.ownIcon && opacity > 0.01
      opacity: count > 0 ? 1 : 0
      scale: count > 0 ? 1 : 0.3
      Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
      Behavior on scale { NumberAnimation { duration: 340; easing.type: Easing.OutBack; easing.overshoot: 1.5 } }
      transform: Scale { id: badgeScale; origin.x: ownBadge.width / 2; origin.y: ownBadge.height / 2 }
      SequentialAnimation {
        id: badgeBump
        ParallelAnimation {
          NumberAnimation { target: badgeScale; property: "xScale"; to: 1.3; duration: 110; easing.type: Easing.OutCubic }
          NumberAnimation { target: badgeScale; property: "yScale"; to: 1.3; duration: 110; easing.type: Easing.OutCubic }
        }
        ParallelAnimation {
          NumberAnimation { target: badgeScale; property: "xScale"; to: 1; duration: 260; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve }
          NumberAnimation { target: badgeScale; property: "yScale"; to: 1; duration: 260; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve }
        }
      }
      x: slot.baseWidth / 2 + 3
      y: Math.max(1, (slot.height - 18) / 2 - 3)
      width: Math.max(height, badgeText.implicitWidth + 4)
      height: 11
      radius: height / 2
      color: "#f5c26b"
      Text {
        id: badgeText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: ownBadge.shownCount > 0 ? String(ownBadge.shownCount) : ""
        color: "#0b0b0b"
        font.family: root.monoFamily
        font.pixelSize: 8
        font.bold: true
      }
    }

    Text {
      id: liveText
      textFormat: Text.PlainText
      x: slot.baseWidth
      anchors.verticalCenter: parent.verticalCenter
      text: slot.liveLabel
      color: slot.ownIcon && slot.ownIcon.always && slot.ownIcon.tone ? root.toneColor(slot.ownIcon.tone) : "#e6e6e6"
      font.family: root.monoFamily
      font.pixelSize: 11
      font.weight: Font.Medium
      opacity: slot.expanded ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: slot.expanded ? 300 : 120; easing.type: Easing.Bezier; easing.bezierCurve: root.easeCurve } }
    }

    Rectangle {
      id: openPanelIndicator

      readonly property int inset: Style.space(2)

      visible: opacity > 0
      opacity: slot.panelOpen && !slot.dragSource ? 0.9 : 0
      color: Commons.Color.accent
      radius: Math.min(width, height) / 2
      width: root.vertical ? Style.space(2) : slot.panelIndicatorExtent
      height: root.vertical ? slot.panelIndicatorExtent : Style.space(2)
      // The mark sits on the module's inner edge — the one facing the
      // desktop — so it underlines a top bar, overlines a bottom one, and
      // points inward from a left or right one. It reads as pointing at the
      // panel that opens on that side.
      // Snap toward the start of the slot, matching native glyph rendering.
      x: root.vertical
        ? (root.position === "left" ? parent.width - width - inset : inset)
        : Math.floor((parent.width - width) / 2)
      y: root.vertical
        ? Math.floor((parent.height - height) / 2)
        : (root.position === "top" ? parent.height - height - inset : inset)
      z: 50

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      id: modulePointer

      property bool dragging: false
      property bool suppressClick: false
      property real pressedX: 0
      property real pressedY: 0
      readonly property bool canReorder: root.shell && typeof root.shell.mutateShellConfig === "function"
      readonly property real dragThreshold: Style.space(4)

      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      enabled: slot.visible && slot.width > 0 && slot.height > 0
      propagateComposedEvents: true
      // Only the hovered slot needs the hit test; without the guard every
      // slot on every monitor re-ran it on each click target change.
      cursorShape: moduleHover.hovered && root.moduleClickTargetAt(slot, mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor
      // Do not assign drag.target here: ModuleSlot is owned by Row/Column
      // positioners, and mutating slot.x/slot.y can leave stale offsets that
      // make neighboring modules overlap after a small aborted drag.

      onPressed: function(mouse) {
        dragging = false
        suppressClick = false
        pressedX = mouse.x
        pressedY = mouse.y
        root.clearBarDrag()
      }

      onPositionChanged: function(mouse) {
        if (!canReorder || !(mouse.buttons & Qt.LeftButton)) return

        var distance = Math.abs(mouse.x - pressedX) + Math.abs(mouse.y - pressedY)
        if (distance >= dragThreshold) {
          if (!dragging) {
            root.barDragWindow = root.targetWindow(slot.activeItem) || root.targetWindow(slot)
            root.barDragScreen = root.barDragWindow ? root.barDragWindow.screen : null
            root.barDragOffsetX = pressedX
            root.barDragOffsetY = pressedY
            root.captureBarDragGhost(slot)
            root.barDragSource = slot
          }
          dragging = true
          root.hideTooltip(slot.activeItem)
        }

        if (dragging) {
          var scenePoint = slot.mapToItem(null, mouse.x, mouse.y)
          var screenPoint = root.barDragScreenPoint(scenePoint)
          root.barDragSceneX = scenePoint.x
          root.barDragSceneY = scenePoint.y
          root.barDragScreenX = screenPoint.x
          root.barDragScreenY = screenPoint.y

          var drop = root.moduleDropAtScene(scenePoint, slot)
          root.barDragTarget = drop ? drop.slot : null
          root.barDragAfter = drop ? drop.after : false
          root.barDragTargetGeometry = drop ? root.dropMarkerRect(drop.slot, drop.after) : null
        }
      }

      onReleased: function(mouse) {
        var wasDragging = dragging
        var targetSlot = root.barDragTarget
        var afterTarget = root.barDragAfter

        if (wasDragging) suppressClick = true

        dragging = false
        root.clearBarDrag()

        if (wasDragging && targetSlot) {
          root.dropBarModuleAtTarget(slot, targetSlot, afterTarget)
          mouse.accepted = true
        } else if (!wasDragging) {
          mouse.accepted = false
        }
      }

      onCanceled: {
        dragging = false
        suppressClick = false
        root.clearBarDrag()
      }

      onClicked: function(mouse) {
        if (suppressClick) {
          suppressClick = false
          mouse.accepted = true
          return
        }

        if (!root.pressModuleClickTarget(slot, mouse.button, mouse.x, mouse.y)) mouse.accepted = false
      }
    }

    // Organise mode: the whole icon becomes the switch (it does not open its
    // panel meanwhile). A dot under it says where it lives, like the dock's:
    // filled blue = pinned on the bar, hollow ring = kept in the drawer.
    Rectangle {
      visible: root.drawerEdit && slot.isTool && slot.baseWidth > 0
      z: 100
      width: 6
      height: 6
      radius: 3
      x: (slot.baseWidth - width) / 2
      y: slot.height - height - 1
      color: slot.inDrawer ? "transparent" : "#6b9bff"
      border.width: 1
      border.color: slot.inDrawer ? Qt.rgba(1, 1, 1, 0.55) : "#6b9bff"
    }
    MouseArea {
      visible: root.drawerEdit && slot.isTool && slot.baseWidth > 0
      z: 101
      x: 0
      width: slot.baseWidth
      height: slot.height
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.showTooltip(slot, root.tr(slot.inDrawer ? "Na gaveta  ·  clique para fixar na barra" : "Fixo na barra  ·  clique para guardar na gaveta"))
      onExited: root.hideTooltip(slot)
      onClicked: root.setInDrawer(slot.moduleName, !slot.inDrawer)
    }

    onActiveItemChanged: Qt.callLater(injectProps)
    onModuleSettingsChanged: injectProps()

    function injectProps() {
      var target = activeItem
      if (!target) return
      // The tools button is part of this bar (its panel and drawer), so it gets the
      // bar itself like first-party widgets, not the narrowed plugin API.
      var cid = root.canon(moduleName)
      if ("bar" in target) target.bar = firstParty || cid === root.selfId || cid === "io.github.hugorolimf.inbox"
        ? root : root.pluginBarApiFor(pluginApiId, moduleName, registered)
      if ("moduleName" in target) target.moduleName = moduleName
      if ("settings" in target) target.settings = moduleSettings
    }

    Component {
      id: customCommandModuleComponent
      CustomCommandModule { entry: slot.entry }
    }
  }

  // ---- Pieces of the bar's own icons (ModuleSlot's ownGlyph), on the
  // 24-unit grid. Inline components do not see the bar's scope, so the ink
  // and the easing curve come in as properties.

  // One stroke (or filled) part; its alpha eases, so parts fade in and out.
  component GlyphPart: ShapePath {
    id: gp
    property var part: null
    property color ink: "white"
    property var curve: [0.32, 0.72, 0, 1, 1, 1]
    property real alpha: part ? part.a : 0
    Behavior on alpha { NumberAnimation { duration: 300; easing.type: Easing.Bezier; easing.bezierCurve: gp.curve } }
    strokeWidth: 1.8
    capStyle: ShapePath.RoundCap
    joinStyle: ShapePath.RoundJoin
    strokeColor: part && !part.f ? Qt.rgba(ink.r, ink.g, ink.b, alpha) : "transparent"
    fillColor: part && part.f ? Qt.rgba(ink.r, ink.g, ink.b, alpha) : "transparent"
    PathSvg { path: gp.part ? gp.part.d : "" }
  }

  // A rectangle that glides to its new place and size (battery level,
  // brightness, a switch knob); `f` false draws it as a ring.
  component GlyphBlock: Rectangle {
    id: gb
    property var spec: null
    property color ink: "white"
    property var curve: [0.32, 0.72, 0, 1, 1, 1]
    x: spec ? spec.x : 12
    y: spec ? spec.y : 12
    width: spec ? spec.w : 0
    height: spec ? spec.h : 0
    radius: spec ? Math.min(spec.r, Math.min(width, height) / 2) : 0
    visible: !!spec
    opacity: spec ? spec.a : 0
    antialiasing: true
    color: spec && spec.f ? ink : "transparent"
    border.width: spec && !spec.f ? 1.8 : 0
    border.color: ink
    Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.Bezier; easing.bezierCurve: gb.curve } }
    Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.Bezier; easing.bezierCurve: gb.curve } }
    Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.Bezier; easing.bezierCurve: gb.curve } }
    Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.Bezier; easing.bezierCurve: gb.curve } }
    Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.Bezier; easing.bezierCurve: gb.curve } }
  }

  // A mark over the glyph (the slash, the mute cross): it grows out from
  // (originX, originY) as it fades in, and folds back the same way.
  component GlyphMark: Shape {
    id: gm
    property string path: ""
    property bool on: false
    property real originX: 12
    property real originY: 12
    property color ink: "white"
    property var curve: [0.32, 0.72, 0, 1, 1, 1]
    property real grow: on ? 1 : 0
    Behavior on grow { NumberAnimation { duration: 360; easing.type: Easing.Bezier; easing.bezierCurve: gm.curve } }
    width: 24
    height: 24
    visible: grow > 0.01
    opacity: Math.min(1, grow * 1.6)
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { origin.x: gm.originX; origin.y: gm.originY; xScale: 0.15 + 0.85 * gm.grow; yScale: 0.15 + 0.85 * gm.grow }
    ShapePath {
      strokeWidth: 1.8
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      strokeColor: gm.ink
      fillColor: "transparent"
      PathSvg { path: gm.path }
    }
  }

  component CustomCommandModule: WidgetButton {
    id: customRoot

    required property var entry
    readonly property string moduleName: root.entryId(entry)
    readonly property var settings: root.entrySettings(entry)
    property string outputText: ""
    property string outputTooltip: ""
    property bool outputActive: false

    function setting(name, fallback) {
      var value = settings ? settings[name] : undefined
      return value === undefined || value === null ? fallback : value
    }

    function update(raw) {
      var data = Util.parseModuleJson(raw)
      var klass = data.class || data.alt || ""

      outputText = data.text || String(raw || "").trim()
      outputTooltip = data.tooltip || String(setting("tooltip", ""))
      outputActive = klass === "active" || (Array.isArray(klass) && klass.indexOf("active") !== -1)
    }

    bar: root
    text: outputText || String(setting("text", ""))
    tooltipText: outputTooltip || String(setting("tooltip", ""))
    active: outputActive
    keepSpace: setting("keepSpace", false) === true
    horizontalMargin: Number(setting("horizontalMargin", 7.5))
    verticalPadding: Number(setting("verticalPadding", 6))
    fontSize: Number(setting("fontSize", 12))

    onPressed: function(button) {
      var command = ""
      if (button === Qt.RightButton)
        command = String(setting("onRightClick", ""))
      else if (button === Qt.MiddleButton)
        command = String(setting("onMiddleClick", ""))
      else
        command = String(setting("onClick", ""))

      if (command) root.run(command)
    }

    Process {
      id: customProc
      command: ["bash", "-lc", String(customRoot.setting("exec", ""))]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: customRoot.update(text)
      }
    }

    Timer {
      interval: Math.max(1, Number(customRoot.setting("interval", 5))) * 1000
      running: String(customRoot.setting("exec", "")) !== ""
      repeat: true
      triggeredOnStart: true
      onTriggered: root.runProcess(customProc)
    }
  }
}
