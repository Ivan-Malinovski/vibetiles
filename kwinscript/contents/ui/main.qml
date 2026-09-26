import QtQuick
import QtQuick.Effects
import org.kde.kwin
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore

import "components" as Components

// Declarative KWin script port of the VibeTiles daemon (see ../../../main.cpp /
// ../../../main.qml in the repo root for the standalone-app version this is replacing).
// Runs entirely inside kwin_wayland: Workspace.* is the same privileged API the daemon
// used to reach only by injecting throwaway scripts over D-Bus, now available directly
// and synchronously, so all the async report-back plumbing (AppService/Controller,
// queryWindowList, queryWindowInfo, ...) collapses into plain function calls.
//
// Root must be PlasmaCore.Dialog, not a plain QtQuick Window - a bare Window with
// interactive flags (Qt.Popup etc) gets wrapped by the declarative-script host's own
// dialog presentation and logs "QML Dialog: trying to show an empty dialog" without
// ever actually appearing (confirmed live; this is the same pattern kzones/main.qml and
// mousetiler/OverlayTiler.qml use for their own full-screen overlays).

PlasmaCore.Dialog {
    id: root

    location: PlasmaCore.Types.Desktop
    backgroundHints: PlasmaCore.Types.NoBackground
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    visible: false

    // ---- config, read from contents/config/main.xml via KWin.readConfig() ----
    property int gridCols: 6
    property int gridRows: 4
    property string overlayMode: "fullscreen" // "fullscreen" | "compact"
    property int compactWidth: 480
    property int compactHeight: 300
    property int windowGap: 8
    property bool resizeOverlapping: true
    // when a placement completely covers another window (which resizeOverlapping's
    // edge-slice shrink can't handle), move that window to the largest free grid region
    // instead of leaving it hidden underneath
    property bool relocateCovered: true
    property bool compactAtCursor: false
    // compact mode only: draw a 1:1 outline of the final window rectangle on the real
    // screen while selecting (see the `ghost` Rectangle). On by default - the compact grid
    // is a miniature, so without it a selection gives no sense of the resulting size - but
    // it is extra chrome over the desktop, so it can be turned off.
    property bool ghostPreview: true
    property string hotCorner: "none"
    // when true, any native window drag auto-shows a small top-center single-cell picker
    // after the window has moved past a threshold, no shortcut needed - modeled on
    // KZones/MouseTiler's automatic drag-triggered zone overlays. Opt-in since it changes
    // the feel of every plain window move, not just shortcut-driven placements.
    property bool dragAutoTrigger: false
    // When true, the auto-trigger picker spawns hanging down-right from the cursor, held
    // trailGap clear of it on whichever axis the drag is moving along (see dragDirection
    // and canvasX/canvasY - it used to trail by the picker's full size, which put the whole
    // body far from the pointer). Centering would force
    // any selection to include the cursor's spawn cell - making single-cell picks at
    // non-cursor cells impossible, and on a 1x1 picker leaving no room to drag from the
    // middle at all. With corner anchoring, the cursor's first inside-picker position is at
    // the near corner and dragging diagonally extends a selection away from it - AND the
    // cursor's exit from the picker clears the anchor (see
    // onNativeDragStepped) so a release past the edge doesn't commit a resize the user
    // never confirmed by hovering over a target cell.
    // Independent of compactAtCursor, which only affects non-autoMode compact activations.
    property bool autoAtCursor: false
    // when true, an interactive resize drags every window whose opposite edge is flush
    // against the edge being moved, so a shared border between two tiled windows behaves
    // like one splitter (Windows Snap). Opt-in: it changes the feel of every manual
    // resize, and windows that merely happen to sit flush get pulled along too.
    property bool linkedResize: false
    // when true, a plain native window drag (no shortcut held, Windows-Snap style) dropped
    // with the cursor against a screen edge fills the largest reachable gap containing the
    // window's current cells, or - on an otherwise-empty screen, where that would just
    // maximise - takes the half (quarter, at a corner) toward the edge(s). A live shadowed
    // preview of the outcome is shown while armed.
    // Deliberately scoped to the *native mouse* drag only: it does NOT fire on a grid-overlay
    // placement (finishDrag). A normal grid drop that happens to land against a screen edge
    // must commit exactly the selected size, not balloon to fill the free area - that was a
    // real "windows resize way too big" bug. Meta+Alt+E stays available for an explicit fill.
    // Off by default: the user typically also wants to disable KWin's built-in ElectricBorder
    // snap so the two don't both fire on the same edge. dragAutoTrigger takes precedence (its
    // picker owns the drag) - the two aren't armed on the same drag.
    property bool autoExpandOnEdgeDrag: false
    // when true, a plain native window drag dropped onto another window docks into it,
    // Trellis-style: the outer windowDropBand of a side splits the window underneath in half
    // with the dragged window taking the half on that side, the middle swaps the two. A
    // screen-edge drop still wins at the screen edge. See windowDropTarget().
    property bool dropOnWindow: false
    // fraction of the target window's width/height, from each side, that counts as that
    // side's split zone. Trellis uses the same 28%; anything inside all four bands swaps.
    readonly property real windowDropBand: 0.28
    // when true, a window placed via the grid/compact picker that lands close to but not
    // flush against a neighbour has that gap closed automatically. See computeGapClosedRect(),
    // called from finishDrag(). Deliberately scoped to VibeTiles' own placement commit only -
    // NOT to a plain native window resize (dragging a border with the mouse has nothing to do
    // with VibeTiles; a user doing that expects exactly the size they dragged to, same
    // reasoning as finishDrag's own "commits exactly the selected rect" rule). Off by default
    // since it changes the outcome of an ordinary placement the user may have wanted landed
    // exactly where they put it.
    property bool snapGaps: false
    // how far (px) a snapGaps edge is allowed to grow to close a gap - keeps it a gap-closer,
    // not a second expand-to-fill trigger. User-tunable: real off-grid gaps from a manual
    // resize are routinely well past a small hardcoded guess (confirmed live - an earlier
    // fixed 48-64px cap was "way too little to make any real difference" for typical gaps).
    property int snapGapMax: 200
    // when true, the size a window had just before VibeTiles placed it is remembered and
    // handed back the moment the user starts dragging that window by its titlebar again -
    // Windows' "drag a snapped window off and it goes back to its old size". Off by default:
    // it changes what an ordinary titlebar drag does to a placed window. See restoreGeoms.
    property bool restoreSizeOnDrag: false
    // distance (px) from the physical screen edge within which a native drop counts as an
    // edge-drop. Larger than the overlay path's 10px snap since it gates a whole gesture
    // rather than nudging an already-placed edge, and the cursor rarely lands pixel-exact.
    property int edgeDropThreshold: 16
    // corner zone for the same gesture: how far along each axis still counts as "at the
    // corner" once the drop already qualifies as an edge-drop on one axis. Deliberately much
    // wider than edgeDropThreshold - the intersection of two 16px bands is a 16x16 target,
    // which can't be hit deliberately. A quarter-screen drop is a distinct enough intent to
    // deserve the last ~120px of each edge.
    property int cornerDropThreshold: 120
    // per-output {gridCols, gridRows} overrides, keyed by output name (e.g. "DP-2"),
    // parsed from the monitorsJson config entry
    property var monitorOverrides: ({})
    // last raw monitorsJson string we parsed, so loadConfig() (run on every show/showAuto,
    // i.e. on every native drag when dragAutoTrigger is on) can skip re-parsing when the
    // stored value is unchanged. Sentinel init guarantees the first loadConfig parses.
    property string monitorsJsonRaw: "￿"
    // grid size actually in effect for the screen the overlay is showing on - the
    // per-monitor override if one matches targetScreenObj.name, else the defaults above.
    // effCols/effRows (the Alt-doubling multiplier) are derived from these, not
    // directly from gridCols/gridRows, so overrides apply everywhere sizing does.
    property int activeGridCols: gridCols
    property int activeGridRows: gridRows

    // combo-box-backed entries are Int in kcfg, not String - a plain QComboBox's
    // auto-bindable property is currentIndex, so a String entry would just store the
    // index as text instead of matching by name (confirmed live - this silently broke
    // mode-switching). Map index -> name here to match config.ui's item order.
    readonly property var modeNames: ["fullscreen", "compact"]
    readonly property var hotCornerNames: ["none", "topLeft", "topRight", "bottomLeft", "bottomRight"]

    function loadConfig() {
        gridCols = KWin.readConfig("gridCols", 6);
        gridRows = KWin.readConfig("gridRows", 4);
        overlayMode = modeNames[KWin.readConfig("mode", 0)] || "fullscreen";
        compactWidth = KWin.readConfig("compactWidth", 480);
        compactHeight = KWin.readConfig("compactHeight", 300);
        windowGap = KWin.readConfig("gap", 8);
        resizeOverlapping = KWin.readConfig("resizeOverlapping", true);
        relocateCovered = KWin.readConfig("relocateCovered", true);
        compactAtCursor = KWin.readConfig("compactAtCursor", false);
        ghostPreview = KWin.readConfig("ghostPreview", true);
        hotCorner = hotCornerNames[KWin.readConfig("hotCorner", 0)] || "none";
        dragAutoTrigger = KWin.readConfig("dragAutoTrigger", false);
        autoAtCursor = KWin.readConfig("autoAtCursor", false);
        linkedResize = KWin.readConfig("linkedResize", false);
        autoExpandOnEdgeDrag = KWin.readConfig("autoExpandOnEdgeDrag", false);
        dropOnWindow = KWin.readConfig("dropOnWindow", false);
        snapGaps = KWin.readConfig("snapGaps", false);
        snapGapMax = KWin.readConfig("snapGapMax", 200);
        restoreSizeOnDrag = KWin.readConfig("restoreSizeOnDrag", false);
        // reading the config string is cheap; re-parsing it (JSON.parse or line-splitting)
        // every activation is the part worth avoiding - only re-parse when it changed.
        const rawMonitors = KWin.readConfig("monitorsJson", "");
        if (rawMonitors !== root.monitorsJsonRaw) {
            root.monitorsJsonRaw = rawMonitors;
            root.monitorOverrides = root.parseMonitorOverrides(rawMonitors);
        }
    }

    // Per-monitor grid overrides, in either of two syntaxes.
    //
    // The plain form is one "OUTPUT = COLSxROWS" per line, which is what the settings
    // dialog now documents - the generic KWin-script config KCM can only do 1:1 scalar
    // binding, so a real per-row table editor isn't available without shipping a compiled
    // KCM, but hand-editing three tokens on a line is a great deal easier than getting
    // nested JSON braces right in a plain text box.
    //
    // The original JSON object form is still accepted, unchanged: it is what any existing
    // install already has stored, and silently dropping those overrides on upgrade would
    // be a data-loss bug. Detected by a leading brace, so the two can't be confused.
    function parseMonitorOverrides(text) {
        const s = String(text || "").trim();
        if (s === "" || s === "{}") return {};

        if (s.charAt(0) === "{") {
            try {
                const parsed = JSON.parse(s);
                // JSON.parse("null")/numbers/strings don't throw but leave a non-object
                // value, which crashes on the next monitorOverrides[name] lookup.
                // JSON.parse("[]") would silently mis-route too - guard for both.
                if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed;
            } catch (e) {
                console.warn("vibetiles: invalid monitorsJson, ignoring overrides:", e);
            }
            return {};
        }

        // name and size are split on the LAST separator, so output names containing '='
        // or ':' (rare, but nothing forbids them) still parse. Blank lines and #-comments
        // are skipped so the field can carry the example as a comment.
        //
        // The value is one or two comma-separated WxH pairs:
        //   HDMI-A-1 = 2x6              grid override only
        //   HDMI-A-1 = 2x6, 300x400     grid override + compact overlay size in px
        // The second pair overrides compactWidth/compactHeight for that output only.
        const out = {};
        const lines = s.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line === "" || line.charAt(0) === "#") continue;
            const cut = Math.max(line.lastIndexOf("="), line.lastIndexOf(":"));
            if (cut < 1) {
                console.warn("vibetiles: skipping unparseable monitor line:", String(line).substring(0, 80));
                continue;
            }
            const name = line.substring(0, cut).trim();
            const parts = line.substring(cut + 1).split(",");
            const size = parts[0].trim().split(/[xX*]/);
            const cols = parseInt(size[0], 10), rows = parseInt(size[1], 10);
            if (name === "" || size.length !== 2 || !(cols > 0) || !(rows > 0)) {
                console.warn("vibetiles: skipping unparseable monitor line:", String(line).substring(0, 80));
                continue;
            }
            const entry = { gridCols: cols, gridRows: rows };
            // an unparseable second pair is a warning, not a reason to drop the grid
            // override the line also carries - that half parsed fine.
            if (parts.length > 1) {
                const px = parts[1].trim().split(/[xX*]/);
                const cw = parseInt(px[0], 10), ch = parseInt(px[1], 10);
                if (px.length === 2 && cw > 0 && ch > 0) {
                    entry.compactWidth = cw;
                    entry.compactHeight = ch;
                } else {
                    console.warn("vibetiles: ignoring unparseable compact size on monitor line:", String(line).substring(0, 80));
                }
            }
            out[name] = entry;
        }
        return out;
    }

    Component.onCompleted: {
        root.loadConfig();
        const wins = Workspace.stackingOrder;
        for (let i = 0; i < wins.length; i++) root.hookWindow(wins[i]);
    }

    // ---- captured at show()-time, used throughout this activation ----
    property var targetWindow: null
    property string targetTitle: ""
    property string targetIconName: ""
    property var targetScreenObj: null
    // full output geometry - this Window itself spans it
    property rect screenGeo: Qt.rect(0, 0, 1920, 1080)
    // work area (screen geometry minus panels/docks) - KWin.PlacementArea is the
    // clientArea option that actually excludes panel struts (confirmed empirically for
    // the daemon version - see CLAUDE.md gotchas); everything below stays within this
    property rect availGeo: Qt.rect(0, 0, 1920, 1080)
    property point spawnCursorPos: Qt.point(0, 0)
    property var windowList: []

    x: screenGeo.x
    y: screenGeo.y
    width: screenGeo.width
    height: screenGeo.height

    property bool dragging: false
    property point dragStart: Qt.point(0, 0)
    property point dragCurrent: Qt.point(0, 0)
    // true while the currently-shown overlay was triggered by the shortcut firing mid a
    // native window drag (see "drag-triggered activation" below), as opposed to a plain
    // hotkey press - the selection then tracks nativeDragWindow's live position instead of
    // this overlay's own MouseArea, which never receives real pointer events during a
    // native interactive move (the compositor keeps that grab with the dragged window).
    property bool dragTriggered: false

    // true while the currently-shown overlay is the auto-trigger-on-drag picker (see
    // "auto-trigger on drag" below) - a small top-center single-cell hover picker, distinct
    // from both the shortcut-driven grid and dragTriggered's cursor-following box.
    property bool autoMode: false

    // holding Alt temporarily doubles the grid resolution for finer placement -
    // all cell math below uses effCols/effRows instead of the raw config values.
    // Alt rather than Shift: Shift is claimed by too many other things (KWin's own
    // drag behaviours, app-level range selection) and interfered in practice.
    property bool fineHeld: false
    property int effCols: fineHeld ? activeGridCols * 2 : activeGridCols
    property int effRows: fineHeld ? activeGridRows * 2 : activeGridRows

    property bool isCompact: overlayMode === "compact" || root.autoMode
    property real availLocalX: availGeo.x - screenGeo.x
    property real availLocalY: availGeo.y - screenGeo.y
    // a portrait monitor gets the configured compact size flipped (480x300 -> 300x480), so
    // the mini grid keeps the screen's orientation instead of always being landscape.
    // A per-output size from monitorsJson wins over both, unflipped (see rehomeForScreen).
    property bool portraitScreen: availGeo.height > availGeo.width
    property int activeCompactWidth: 0
    property int activeCompactHeight: 0
    property real compactW: activeCompactWidth > 0 ? activeCompactWidth : (portraitScreen ? compactHeight : compactWidth)
    property real compactH: activeCompactHeight > 0 ? activeCompactHeight : (portraitScreen ? compactWidth : compactHeight)
    property real canvasWidth: isCompact ? Math.min(compactW, availGeo.width) : availGeo.width
    property real canvasHeight: isCompact ? Math.min(compactH, availGeo.height) : availGeo.height
    // drag-triggered activations always spawn the compact box at the cursor, regardless of
    // the compactAtCursor setting - it's inherently about following the mouse mid-drag.
    // autoMode overrides this the other way: it always sits fixed top-center (see below),
    // never follows the cursor, so it doesn't jump around as the dragged window moves.
    property bool effectiveCompactAtCursor: (compactAtCursor || dragTriggered) && !root.autoMode
    // cursor-following compact placements (autoAtCursor, compactAtCursor, dragTriggered)
    // clamp to the available area's raw edge, so a cursor near the screen border spawns the
    // picker flush against it - too close to also reach a screen-edge zone (hot corner,
    // autoExpandOnEdgeDrag) without the two overlapping/fighting for the same drag. Keep a
    // fixed gap off every edge instead.
    readonly property int edgeMargin: 48
    // How far the autoAtCursor picker is held off the cursor on an axis the drag is moving
    // along. Small and fixed, so the picker always spawns *next to* the pointer.
    readonly property int trailGap: 48
    // autoAtCursor spawns the picker hanging down-right from the cursor, nudged trailGap
    // clear of it on whichever axis the drag is actually moving along (see dragDirection):
    // moving +X puts the picker's left edge trailGap to the right of the cursor, moving -X
    // (or not moving on that axis) leaves it flush at the cursor. Same for Y.
    //
    // It used to offset by the picker's FULL width/height on a positive-direction axis, so
    // the cursor sat on the far edge and the whole body trailed behind the motion. That read
    // as "way too high up" on a first drag (confirmed live): a titlebar pull is usually
    // downward, so the entire 300px-tall picker landed above the pointer. It also looked
    // inconsistent, because a cross-screen re-home reuses the first screen's dragDirection
    // and a monitor-crossing drag is near-horizontal - dy came out 0 or negative there, so
    // the re-homed picker did spawn at the cursor and the two paths disagreed.
    //
    // trailGap is what keeps the pointer OUTSIDE the picker, which still matters: autoAnchored
    // arms as soon as the cursor is within the canvas (pointInCanvas), so a picker spawned
    // under the pointer would pin an anchor and commit a placement the user never aimed at.
    // A gap only on the axis of motion is enough - that's the only direction continued
    // dragging can carry the cursor in, and it now has to cross trailGap first.
    property real canvasX: root.autoMode
        ? (autoAtCursor
            ? clamp(
                spawnCursorPos.x - screenGeo.x + (root.dragDirection.x > 0 ? trailGap : 0),
                availLocalX + edgeMargin,
                availLocalX + availGeo.width - canvasWidth - edgeMargin
              )
            : availLocalX + (availGeo.width - canvasWidth) / 2)
        : (isCompact && effectiveCompactAtCursor)
            ? clamp((spawnCursorPos.x - screenGeo.x) - canvasWidth / 2, availLocalX + edgeMargin, availLocalX + availGeo.width - canvasWidth - edgeMargin)
            : availLocalX + (availGeo.width - canvasWidth) / 2
    property real canvasY: root.autoMode
        ? (autoAtCursor
            ? clamp(
                spawnCursorPos.y - screenGeo.y + (root.dragDirection.y > 0 ? trailGap : 0),
                availLocalY + edgeMargin,
                availLocalY + availGeo.height - canvasHeight - edgeMargin
              )
            : availLocalY + edgeMargin)
        : (isCompact && effectiveCompactAtCursor)
            ? clamp((spawnCursorPos.y - screenGeo.y) - canvasHeight / 2, availLocalY + edgeMargin, availLocalY + availGeo.height - canvasHeight - edgeMargin)
            : availLocalY + (availGeo.height - canvasHeight) / 2
    // guard the divide: during a transient multi-monitor reconfigure canvasWidth can read
    // 0 for a frame, and availGeo.width/0 = Infinity propagates through finishDrag() into a
    // window geometry KWin accepts silently. Fall back to 1:1 until real dimensions arrive.
    property real scaleX: canvasWidth > 0 ? availGeo.width / canvasWidth : 1
    property real scaleY: canvasHeight > 0 ? availGeo.height / canvasHeight : 1

    property bool pickerOpen: false

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    // re-expresses a Kirigami theme color at a given alpha - used everywhere the overlay
    // needs a translucent tint of a theme color rather than the opaque color itself
    function themeAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // ---- show / hide ----

    // the output whose geometry contains the given point, falling back to activeScreen -
    // the overlay should follow the mouse to whichever monitor the user is pointing at,
    // not wherever the target window currently happens to sit (see daemon's
    // QGuiApplication::screenAt(gCursorPos) - same intent, ported here)
    function screenAt(point) {
        const screens = Workspace.screens;
        for (let i = 0; i < screens.length; i++) {
            const g = screens[i].geometry;
            if (point.x >= g.x && point.x < g.x + g.width && point.y >= g.y && point.y < g.y + g.height) {
                return screens[i];
            }
        }
        return Workspace.activeScreen;
    }

    // screenAt() scans every output, but a native drag fires per motion tick and the cursor
    // is almost always still on the screen the overlay is already homed to. Check that one's
    // bounds first and only fall back to the full scan when the cursor has actually crossed
    // out of it - behaviour-identical (non-overlapping outputs), just cheaper per step.
    function currentDragScreen() {
        const s = root.targetScreenObj;
        if (s) {
            const g = s.geometry;
            const p = Workspace.cursorPos;
            if (p.x >= g.x && p.x < g.x + g.width && p.y >= g.y && p.y < g.y + g.height) return s;
        }
        return root.screenAt(Workspace.cursorPos);
    }

    // applies screen-specific state for the given screen object: replaces targetScreenObj,
    // screenGeo, availGeo, and activeGridCols/Rows (the last two via the per-output
    // monitorOverrides map). Used by show(), showAuto(), and autoMode's monitor-cross
    // re-home - the same 5-line setup was duplicated in all three before extraction.
    function rehomeForScreen(screen) {
        root.targetScreenObj = screen;
        root.screenGeo = screen.geometry;
        root.availGeo = Workspace.clientArea(KWin.PlacementArea, screen, Workspace.currentDesktop);
        const override = root.monitorOverrides[screen.name];
        root.activeGridCols = (override && override.gridCols > 0) ? override.gridCols : root.gridCols;
        root.activeGridRows = (override && override.gridRows > 0) ? override.gridRows : root.gridRows;
        // 0 means "not overridden" - compactW/compactH then fall back to the global
        // compactWidth/compactHeight, with the portrait flip applied. An explicit
        // per-output size is taken literally instead (the user already wrote it in that
        // monitor's own orientation; flipping it would fight the setting).
        root.activeCompactWidth = (override && override.compactWidth > 0) ? override.compactWidth : 0;
        root.activeCompactHeight = (override && override.compactHeight > 0) ? override.compactHeight : 0;
        // PlasmaCore.Dialog resizes/repositions itself internally (to track mainItem size,
        // keep itself on-screen, etc); any such write from its C++ side permanently severs
        // a declarative x:/y:/width:/height: binding to screenGeo (confirmed live - once
        // that happens the window sticks to whatever geometry Plasma last set, ignoring
        // screenGeo entirely, e.g. spawning ~400px short and offset on a portrait monitor
        // after working fine on the very first activation). Reassert explicitly every
        // rehome so each activation self-heals regardless of what happened to the binding
        // in between.
        root.x = screen.geometry.x;
        root.y = screen.geometry.y;
        root.width = screen.geometry.width;
        root.height = screen.geometry.height;
    }

    // forcedTarget: when set (a window object), this activation is drag-triggered - target
    // that window instead of Workspace.activeWindow and seed the selection at the window's
    // current native-drag position instead of starting with no selection.
    function show(forcedTarget) {
        root.loadConfig();

        const isDragTriggered = !!forcedTarget;
        root.dragTriggered = isDragTriggered;
        // a shortcut-driven activation is never the auto-drag picker - clear autoMode
        // explicitly so a stale true (from a picker that didn't route through hide())
        // can't leave isCompact/canvas positioning stuck in auto-mode behaviour.
        root.autoMode = false;
        // a shortcut fired: drop any armed native edge-drop preview so it can't commit
        // behind the overlay the user just brought up.
        root.edgePreview = false;
        root.edgeDropWatch = false;
        // compact mode's small, cursor-centered box makes the anchor-point restriction
        // (the selection always has to include wherever the cursor was when the shortcut
        // fired) much more cramped than in fullscreen, where there's enough room to reach
        // most layouts anyway - so drag-triggered activations always use fullscreen,
        // regardless of the configured mode.
        if (isDragTriggered) root.overlayMode = "fullscreen";

        // capture the window to act on before our own popup steals activation - mirrors
        // the daemon's captureActiveWindow(), just synchronous now
        targetWindow = isDragTriggered
            ? forcedTarget
            : (Workspace.activeWindow && Workspace.activeWindow.normalWindow ? Workspace.activeWindow : null);
        targetTitle = targetWindow ? (targetWindow.caption || "") : "";
        targetIconName = targetWindow && targetWindow.resourceClass ? targetWindow.resourceClass.toString() : "";
        spawnCursorPos = Workspace.cursorPos;

        rehomeForScreen(screenAt(spawnCursorPos));

        if (isCompact) refreshWindowList();

        root.fineHeld = false;
        root.pickerOpen = false;
        root.visible = true;
        // PlasmaQuick::Dialog's prototype is QQuickWindow, so it has requestActivate().
        // These script-owned windows never reliably receive real keyboard focus
        // regardless (confirmed live: Escape/Keys.onEscapePressed never fires even
        // with forceActiveFocus() at the right time) - so skip the Item-level
        // focus attempt that was here before, since it both fails AND now refers
        // to a deleted item. Alt (fine grid) is read off mouse-event modifiers on the canvas
        // MouseArea; Escape has no such workaround, so cancel is right-click.
        root.requestActivate();

        if (isDragTriggered) {
            const p = root.externalCanvasPoint();
            root.dragStart = p;
            root.dragCurrent = p;
            root.dragging = true;
        } else {
            root.dragging = false;
        }
    }

    function hide() {
        root.visible = false;
        root.dragging = false;
        root.dragTriggered = false;
        root.autoMode = false;
        root.autoDragPending = false;
        root.autoAnchored = false;
        root.edgePreview = false;
        root.edgeDropWatch = false;
        root.edgePreviewRect = Qt.rect(0, 0, 0, 0);
        root.windowDropWatch = false;
        root.windowDrop = null;
        root.dragDirection = Qt.point(0, 0);
        // drop the compact-picker window list so a later show() can't briefly display a
        // stale set (a window could have closed while the overlay was hidden); the next
        // compact show() repopulates it via refreshWindowList().
        root.windowList = [];
    }

    function toggle() {
        if (root.visible) {
            hide();
        } else if (root.nativeDragActive && root.nativeDragWindow) {
            root.show(root.nativeDragWindow);
        } else {
            root.show(null);
        }
    }

    // ---- drag-triggered activation ----
    //
    // Holding the shortcut mid a native window drag (moving/resizing a window with the
    // mouse) retargets the overlay at that window instead of the current active window,
    // following the mouse for the rest of that native drag. Ported from the daemon's
    // persistent injected "drag watcher" KWin script + AppService::dragTick D-Bus relay -
    // in-script this is just interactiveMoveResizeStarted/Stepped/Finished hooked directly
    // on window objects, no D-Bus or second script needed.
    property var nativeDragWindow: null
    property bool nativeDragActive: false

    // ---- native edge-drop (autoExpandOnEdgeDrag, no shortcut) ----
    // armed at drag start for a plain native move when autoExpandOnEdgeDrag is on; while
    // set, each step re-evaluates whether the cursor is against a screen edge. edgePreview
    // is true only while the shadowed preview overlay is actually shown (cursor in an edge
    // zone); edgePreviewRect holds the target rect in screen coords (pre-gap-inset, exactly
    // what gets handed to commit()).
    property bool edgeDropWatch: false
    property bool edgePreview: false
    property rect edgePreviewRect: Qt.rect(0, 0, 0, 0)

    // ---- native drop-onto-window (dropOnWindow, no shortcut) ----
    // windowDropWatch is armed at drag start like edgeDropWatch. windowDrop is the current
    // {target, zone, slot, rest} while the cursor is over another window (null otherwise);
    // slot is also mirrored into edgePreviewRect so the same ghost draws the dragged
    // window's landing spot, and targetGhost draws `rest`. dragOriginGeo is the dragged
    // window's rect from before the drag (and before any size restore) - where a swap
    // sends the target.
    property bool windowDropWatch: false
    property var windowDrop: null
    property rect dragOriginGeo: Qt.rect(0, 0, 0, 0)

    // canvas-local point matching Workspace.cursorPos, the same frame dragStart/dragCurrent
    // live in - used to seed and update the selection during a drag-triggered activation,
    // since this overlay's own MouseArea gets no real pointer events during a native drag.
    function externalCanvasPoint() {
        return Qt.point(
            Workspace.cursorPos.x - screenGeo.x - root.canvasX,
            Workspace.cursorPos.y - screenGeo.y - root.canvasY
        );
    }

    // ---- auto-trigger on drag ----
    //
    // With dragAutoTrigger enabled, any native window drag (no shortcut needed) shows a
    // small top-center picker once the window has moved past a distance threshold - avoids
    // flashing the overlay on a plain click-to-focus or tiny nudge. There's only one tracked
    // point available (the native drag position - our own MouseArea gets no events during a
    // native move), so a real press-drag-release rectangle gesture isn't possible the way
    // the shortcut-driven grid does it. Instead: the picker starts with nothing selected,
    // and the moment the cursor first crosses into the picker's bounds, that point becomes
    // a pinned anchor - continuing to drag from there grows a normal rectangle selection
    // (reusing dragging/rawRect/computeSelBounds/finishDrag as-is) between that anchor and
    // the live cursor position, same visual as the shortcut-driven grid.
    property bool autoDragPending: false
    property point autoDragStartPos: Qt.point(0, 0)
    readonly property int autoDragThreshold: 24
    // true once the cursor has crossed into the picker at least once this drag and an
    // anchor corner has been pinned - before that, nothing is selected/highlighted yet
    property bool autoAnchored: false
    // sign-of-dx/sign-of-dy of the cursor's motion from autoDragStartPos to the moment
    // the threshold tripped. Captured in onNativeDragStepped right before showAuto, and
    // consumed by canvasX/canvasY to spawn the picker trailing the cursor's motion
    // direction (so continued dragging moves the cursor AWAY from the picker rather than
    // into it - reduces accidental trigger-while-continuing). Stale between activations;
    // reset in hide() for tidiness.
    property point dragDirection: Qt.point(0, 0)

    function pointInCanvas(p) {
        return p.x >= 0 && p.x <= canvasWidth && p.y >= 0 && p.y <= canvasHeight;
    }

    // forcedTarget is always set here (called only from onNativeDragStepped once the
    // threshold trips) - unlike show(), there's no "no target" case to handle.
    function showAuto(win) {
        root.loadConfig();
        root.dragTriggered = false;
        root.autoMode = true;
        root.autoAnchored = false;
        root.overlayMode = "compact";

        targetWindow = win;
        targetTitle = "";
        targetIconName = "";
        spawnCursorPos = Workspace.cursorPos;

        rehomeForScreen(screenAt(spawnCursorPos));

        root.fineHeld = false;
        root.pickerOpen = false;
        root.dragging = false;
        root.visible = true;
        root.requestActivate();
        root.dragCurrent = root.externalCanvasPoint();
    }

    // ---- linked resize (shared-border co-resize, gated on linkedResize) ----
    //
    // Windows-Snap-style: while one window is being interactively resized, every window
    // whose opposite edge was flush against the moving edge at drag start has that edge
    // follow along, keeping the border between them a single splitter. Nothing here
    // touches the overlay - it's a pure side-effect of the interactiveMoveResize* signals
    // already hooked on every window in hookWindow().
    //
    // Neighbours (and their pre-resize geometry) are captured once at drag start, and each
    // step recomputes each neighbour from that snapshot plus the dragged window's total
    // delta - never incrementally from its current geometry, which would accumulate
    // rounding drift over a long drag and desynchronise the shared edge.
    property var linkedNeighbors: []
    property rect linkedStartGeo: Qt.rect(0, 0, 0, 0)

    // gap-aware: VibeTiles-placed windows sit exactly windowGap apart, so "flush" has to
    // mean "within the gap", plus slack for hand-placed/decorated windows.
    readonly property int linkedTol: Math.max(16, root.windowGap + 12)

    function linkedCandidate(ow, win) {
        // reject a cross-output neighbour only when we positively know both outputs and
        // they differ; if the declarative API doesn't expose output on either window, we
        // can't tell, so fall through to the geometry checks rather than silently dropping
        // every candidate (!= null catches both null and undefined).
        return ow !== win && !ow.minimized && ow.normalWindow && !ow.fullScreen
            && !(win.output != null && ow.output != null && ow.output !== win.output);
    }

    // Which coordinate is `side`'s edge of rect r? Sides are keyed L/R/T/B throughout
    // this section, and double as the keys of the per-edge delta map in stepLinkedResize.
    function linkedEdgeCoord(r, side) {
        if (side === "L") return r.x;
        if (side === "R") return r.x + r.width;
        if (side === "T") return r.y;
        return r.y + r.height;
    }

    // Do a and b run alongside each other on the axis perpendicular to `axis`? Overlapping
    // counts, and so does a gap no wider than tol - two windows stacked with the usual
    // inter-window gap are still consecutive links of the same border.
    function linkedAbuts(a, b, axis, tol) {
        const share = (axis === "x")
            ? Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y)
            : Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
        return share >= -tol;
    }

    // Record that `w`'s `follow` edge (x1 = left, x2 = right, y1 = top, y2 = bottom) tracks
    // the dragged window's `side` edge. One entry per window, with up to four independently
    // tracked edges: a corner drag legitimately moves two of a neighbour's edges at once,
    // and a window collected by two different chains must merge rather than overwrite.
    function linkedAdd(acc, w, geo, follow, side) {
        let e = null;
        for (let i = 0; i < acc.length; i++) {
            if (acc[i].win === w) { e = acc[i]; break; }
        }
        if (!e) {
            e = { win: w, geo: geo, dxStart: "", dxEnd: "", dyStart: "", dyEnd: "" };
            acc.push(e);
        }
        const key = (follow === "x1") ? "dxStart" : (follow === "x2") ? "dxEnd"
                  : (follow === "y1") ? "dyStart" : "dyEnd";
        if (!e[key]) e[key] = side;  // first chain to claim an edge wins
    }

    // Is `side` of the dragged window sitting on the work area's own boundary?
    //
    // Such a border isn't a shared splitter, it's the screen edge, and every window
    // parked against it lines up there by construction rather than by being tiled
    // against this one. Two half-width windows side by side both have their top edge
    // at the top of the screen: dragging one's top edge down used to drag the other's
    // with it, which is not what "linked" is for - the user is resizing one window
    // away from the edge, not moving a divider they share.
    //
    // Uses the same tolerance as edge matching, and the work area (PlacementArea, so
    // panel struts are excluded) of the dragged window's own output.
    function linkedEdgeIsScreenBoundary(win, side) {
        if (win.output == null) return false;
        let area;
        try {
            area = Workspace.clientArea(KWin.PlacementArea, win.output, Workspace.currentDesktop);
        } catch (e) {
            return false;  // can't tell - fall through to the old linking behaviour
        }
        if (!area || area.width <= 0 || area.height <= 0) return false;
        const line = root.linkedEdgeCoord(win.frameGeometry, side);
        const bound = root.linkedEdgeCoord(area, side);
        return Math.abs(line - bound) <= root.linkedTol;
    }

    // Walk the border that the dragged window's `side` edge lies on, collecting every
    // window with an edge on that same line, reachable by a contiguous run of windows
    // alongside it. Contiguity is what makes this safe: matching the line coordinate alone
    // would rope in anything that happened to line up elsewhere on the screen.
    function collectBorderChain(win, side, acc) {
        const g = win.frameGeometry;
        const tol = root.linkedTol;
        const axis = (side === "L" || side === "R") ? "x" : "y";
        const line = root.linkedEdgeCoord(g, side);
        const wins = Workspace.stackingOrder;

        // every candidate with either of its `axis` edges on the line. Which edge it is
        // decides which way that window follows: a window whose LEFT edge is on the line
        // sits to the right of the border and moves its left edge; one whose RIGHT edge is
        // on the line sits to the left and moves its right edge. The gap between adjacent
        // windows is absorbed by tol, so both sides test against the same line value.
        const onLine = [];
        for (let i = 0; i < wins.length; i++) {
            const ow = wins[i];
            if (!root.linkedCandidate(ow, win)) continue;
            const c = ow.frameGeometry;
            const s = (axis === "x") ? c.x : c.y;
            const e = (axis === "x") ? c.x + c.width : c.y + c.height;
            let follow = "";
            if (Math.abs(s - line) <= tol) follow = axis + "1";
            else if (Math.abs(e - line) <= tol) follow = axis + "2";
            else continue;
            onLine.push({
                win: ow, geo: Qt.rect(c.x, c.y, c.width, c.height),
                follow: follow, used: false
            });
        }

        // grow outward from the dragged window until nothing new abuts the run. This is
        // what generalises the earlier "direct neighbour + one hop" rule: in a 2x2 grid,
        // dragging the bottom-right window's left edge reaches the bottom-left window
        // directly, the top-right window by stacking above it, and the top-left window
        // through that - so the whole vertical divider moves as one instead of only its
        // bottom half.
        const chain = [Qt.rect(g.x, g.y, g.width, g.height)];
        let grew = true;
        while (grew) {
            grew = false;
            for (let i = 0; i < onLine.length; i++) {
                const cand = onLine[i];
                if (cand.used) continue;
                for (let j = 0; j < chain.length; j++) {
                    if (!root.linkedAbuts(cand.geo, chain[j], axis, tol)) continue;
                    cand.used = true;
                    chain.push(cand.geo);
                    root.linkedAdd(acc, cand.win, cand.geo, cand.follow, side);
                    grew = true;
                    break;
                }
            }
        }
    }

    function beginLinkedResize(win) {
        const g = win.frameGeometry;
        root.linkedStartGeo = Qt.rect(g.x, g.y, g.width, g.height);
        const acc = [];
        // all four borders unconditionally - which of them actually moves isn't known until
        // the drag is under way (and a corner drag moves two). Sides whose delta stays 0
        // cost nothing per step beyond the no-op check.
        const sides = ["L", "R", "T", "B"];
        for (let i = 0; i < sides.length; i++) {
            // a border that IS the screen edge links nothing - see
            // linkedEdgeIsScreenBoundary()
            if (root.linkedEdgeIsScreenBoundary(win, sides[i])) continue;
            root.collectBorderChain(win, sides[i], acc);
        }
        // cache each neighbour's size limits once, up front - they don't change mid-drag,
        // so re-deriving them (min/max width/height, each its own try/catch) on every step
        // for every neighbour was pure overhead on the hot path, worse the bigger the
        // linked chain. unmaximized tracks whether setMaximize has been called yet, so a
        // neighbour that starts out already unmaximized isn't re-told every step either.
        for (let i = 0; i < acc.length; i++) {
            const n = acc[i];
            n.minW = root.linkedLimit(n.win, "min", "width", 100);
            n.minH = root.linkedLimit(n.win, "min", "height", 100);
            n.maxW = root.linkedLimit(n.win, "max", "width", 0);
            n.maxH = root.linkedLimit(n.win, "max", "height", 0);
            n.unmaximized = false;
            // last rect actually written to this neighbour (starts as its pre-drag geometry,
            // since that's what's on screen before the first step) - lets stepLinkedResize
            // skip a redundant frameGeometry write when the rounded target hasn't moved since
            // the previous step, which happens often (interactiveMoveResizeStepped can fire
            // more frequently than the rounded pixel target actually changes).
            n.lastX = n.geo.x;
            n.lastY = n.geo.y;
            n.lastW = n.geo.width;
            n.lastH = n.geo.height;
        }
        root.linkedNeighbors = acc;
    }

    // A window's declared size constraint on one dimension, or `fallback` if it declares
    // none. Read defensively: whether minSize/maxSize are exposed to declarative scripts
    // isn't something this codebase has confirmed live, and an undefined property read
    // must degrade to the old fixed floor rather than throw once per neighbour per step.
    //
    // Minimums are raised to the fallback, never lowered - the 100px floor stays as a
    // usability guard for apps that declare a uselessly small minimum. Maximums are taken
    // as-is, with KWin's "unconstrained" sentinel treated as unset.
    function linkedLimit(w, kind, dim, fallback) {
        let s;
        try {
            s = (kind === "min") ? w.minSize : w.maxSize;
        } catch (e) {
            return fallback;
        }
        const v = s ? s[dim] : undefined;
        if (typeof v !== "number" || v <= 0) return fallback;
        if (kind === "max" && v >= 100000) return fallback;
        return (kind === "min") ? Math.max(v, fallback) : v;
    }

    // `rect`, when given, is the geometry interactiveMoveResizeStepped already delivered -
    // reuse it instead of a redundant win.frameGeometry round trip. onNativeDragFinished has
    // no such value (interactiveMoveResizeFinished carries no rect), so it omits the arg and
    // this falls back to reading the property directly.
    function stepLinkedResize(win, rect) {
        if (root.linkedNeighbors.length === 0) return;
        let g;
        if (rect) {
            g = rect;
        } else {
            // unlike the neighbour loop below (which catches per-window), this read is called
            // straight from the interactiveMoveResize* signal handlers with no try/catch above
            // it - if the dragged window is being destroyed mid-drag, this would throw out of
            // the handler. Abandon the linked resize instead.
            try {
                g = win.frameGeometry;
            } catch (e) {
                root.endLinkedResize();
                return;
            }
        }
        const s = root.linkedStartGeo;
        // per-edge deltas rather than a single "which handle is the user dragging" guess -
        // this falls out correctly for corner drags, where two edges move at once.
        const d = {
            L: g.x - s.x,
            R: (g.x + g.width) - (s.x + s.width),
            T: g.y - s.y,
            B: (g.y + g.height) - (s.y + s.height)
        };
        for (let i = 0; i < root.linkedNeighbors.length; i++) {
            const n = root.linkedNeighbors[i], c = n.geo;
            const x1 = c.x + (n.dxStart ? d[n.dxStart] : 0);
            const x2 = c.x + c.width + (n.dxEnd ? d[n.dxEnd] : 0);
            const y1 = c.y + (n.dyStart ? d[n.dyStart] : 0);
            const y2 = c.y + c.height + (n.dyEnd ? d[n.dyEnd] : 0);
            if (x1 === c.x && y1 === c.y && x2 === c.x + c.width && y2 === c.y + c.height) continue;
            // clamp rather than clip: a neighbour that can't take the new size simply
            // stops following, leaving the dragged window free to keep shrinking it out
            // of the way instead of the whole drag jamming.
            //
            // Honouring the window's own declared limits (not just a fixed floor) is what
            // keeps it in sync with the border: an app that refuses a geometry smaller
            // than its minimum just keeps its old size, so the border would slide on
            // without it and the layout would silently come apart mid-drag. Limits are
            // cached on the neighbour by beginLinkedResize rather than re-derived here.
            if (x2 - x1 < n.minW || y2 - y1 < n.minH) continue;
            if ((n.maxW > 0 && x2 - x1 > n.maxW) || (n.maxH > 0 && y2 - y1 > n.maxH)) continue;
            const rx = Math.round(x1), ry = Math.round(y1);
            const rw = Math.round(x2 - x1), rh = Math.round(y2 - y1);
            // skip the write entirely if rounding collapsed this step back to what's already
            // on screen - avoids kicking off another client redraw/ack round-trip for nothing.
            if (rx === n.lastX && ry === n.lastY && rw === n.lastW && rh === n.lastH) continue;
            try {
                if (!n.unmaximized) {
                    n.win.setMaximize(false, false);
                    n.unmaximized = true;
                }
                n.win.frameGeometry = Qt.rect(rx, ry, rw, rh);
                n.lastX = rx; n.lastY = ry; n.lastW = rw; n.lastH = rh;
            } catch (e) {
                // neighbour destroyed mid-drag - drop it rather than throwing per step
                root.linkedNeighbors.splice(i, 1);
                i--;
            }
        }
    }

    function endLinkedResize() {
        root.linkedNeighbors = [];
    }

    // Pre-placement sizes, one entry per window: {win, w, h}. An array keyed by the window
    // object itself, same pattern as hookedWindows - window ids are QUuids and don't make
    // usable JS object keys. Only ever holds windows we've actually placed, so it stays tiny.
    property var restoreGeoms: []

    function restoreEntryIndex(win) {
        for (let i = 0; i < root.restoreGeoms.length; i++) {
            if (root.restoreGeoms[i].win === win) return i;
        }
        return -1;
    }

    // Remember `win`'s current size as what a later titlebar drag should give back. Called
    // from commit() *before* the placement write. Deliberately does not overwrite an existing
    // entry: re-tiling an already-placed window (grid, then grid again) must keep pointing at
    // the size the window had before VibeTiles first touched it, not at the intermediate tile.
    function rememberSize(win, fg) {
        if (!root.restoreSizeOnDrag || !win || !fg) return;
        if (root.restoreEntryIndex(win) >= 0) return;
        if (fg.width < 50 || fg.height < 50) return;
        root.restoreGeoms.push({ win: win, w: fg.width, h: fg.height });
    }

    function forgetSize(win) {
        const i = root.restoreEntryIndex(win);
        if (i >= 0) root.restoreGeoms.splice(i, 1);
    }

    // The "unsnap" itself: give the remembered size back at the start of a titlebar drag,
    // keeping the window under the cursor. The cursor's horizontal position within the frame
    // is preserved as a fraction (drag by the middle of a wide titlebar and you keep holding
    // the middle of the narrow one), while the top edge stays put - the same thing Windows
    // does, and the only choice that keeps the titlebar under the pointer at all.
    // One-shot: the entry is consumed here, so a second drag leaves the window alone.
    function restoreSizeFor(win) {
        const idx = root.restoreEntryIndex(win);
        if (idx < 0) return;
        const e = root.restoreGeoms[idx];
        root.restoreGeoms.splice(idx, 1);
        try {
            const fg = win.frameGeometry;
            if (Math.abs(fg.width - e.w) < 2 && Math.abs(fg.height - e.h) < 2) return;
            const c = Workspace.cursorPos;
            const frac = fg.width > 0
                ? Math.min(1, Math.max(0, (c.x - fg.x) / fg.width)) : 0.5;
            win.setMaximize(false, false);
            win.frameGeometry = Qt.rect(Math.round(c.x - frac * e.w), Math.round(fg.y),
                                        Math.round(e.w), Math.round(e.h));
        } catch (err) {
            // window torn down between the drag starting and this write - nothing to restore
            console.warn("vibetiles: size restore failed:", err);
        }
    }

    function onNativeDragStarted(win) {
        root.nativeDragWindow = win;
        root.nativeDragActive = true;
        root.dragOriginGeo = win.frameGeometry;
        // Windows-style unsnap, before anything else reads geometry this drag. A hand resize
        // is the user picking a size themselves, which supersedes whatever we remembered.
        if (root.restoreSizeOnDrag && win.normalWindow && !win.fullScreen) {
            if (win.resize) root.forgetSize(win);
            else if (win.move) root.restoreSizeFor(win);
        }
        // win.resize distinguishes an edge/corner drag from a plain move; both fire this
        // same signal. Fullscreen windows have no meaningful neighbours to link.
        if (root.linkedResize && win.normalWindow && win.resize && !win.fullScreen) {
            root.beginLinkedResize(win);
        } else {
            root.endLinkedResize();
        }
        // win.move is true only for genuine interactive moves; resizes fire the same
        // interactiveMoveResizeStarted signal but set win.resize instead, and the
        // picker should never pop up over a corner/edge drag. (The drag-triggered
        // activation path above is intentionally left unguarded - if the user holds
        // the shortcut mid-resize, that's their explicit choice to retarget.)
        if (root.dragAutoTrigger && !root.visible && win.normalWindow && win.move) {
            root.autoDragPending = true;
            root.autoDragStartPos = Workspace.cursorPos;
        }
        // Native edge-drop watch (Windows-Snap style). Only a plain move of a normal,
        // non-fullscreen window. Armed alongside the auto-trigger picker when both are on:
        // the picker handles mid-screen drags, but the edge preview takes precedence
        // whenever the cursor reaches a screen edge (see onNativeDragStepped).
        if (root.autoExpandOnEdgeDrag && !root.visible
                && win.normalWindow && win.move && !win.fullScreen) {
            root.edgeDropWatch = true;
        }
        // Drop-onto-window watch - same gating as the edge-drop watch above.
        root.windowDrop = null;
        root.windowDropWatch = root.dropOnWindow && !root.visible
            && win.normalWindow && win.move && !win.fullScreen;
    }

    function onNativeDragStepped(win, rect) {
        if (win !== root.nativeDragWindow) return;
        root.stepLinkedResize(win, rect);
        // fineHeld is otherwise updated off mouse-modifier flags on the canvas
        // MouseArea, but the overlay's MouseArea gets no events during a native
        // drag (the compositor keeps the grab). KWin's QML host doesn't expose
        // Qt.application.queryKeyboardModifiers(), so we have to live without
        // Alt-doubling during native drag activations - same as before this
        // script existed; restore parity rather than ship a broken call.
        if (root.visible && root.dragTriggered && root.targetWindow === win) {
            // follow the cursor across monitors, same as the autoMode branch below: the
            // overlay was homed to whichever screen the shortcut fired on, and a drag
            // routinely leaves it. Unlike autoMode there's no anchor to drop - the
            // selection's start point is re-seeded at the cursor on the new screen, since
            // the old one was in the previous screen's local coordinates and doesn't
            // translate. The effect is that crossing a monitor restarts the selection
            // there rather than stretching a meaningless rectangle between screens.
            const curScreen = root.currentDragScreen();
            if (curScreen !== root.targetScreenObj) {
                root.rehomeForScreen(curScreen);
                const np = root.externalCanvasPoint();
                root.dragStart = np;
                root.dragCurrent = np;
                root.dragging = true;
            } else {
                root.dragCurrent = root.externalCanvasPoint();
            }
            return;
        }
        // Native edge-drop takes precedence over the auto-trigger picker: whenever the
        // cursor is against a screen edge, show the shadowed edge preview and suppress the
        // picker; away from the edge the picker (if enabled) behaves as before. This runs
        // first so the edge always wins. edgeDropTargetRect returns null cheaply when not
        // near an edge (no occupancy scan), so this stays light mid-screen and only does
        // real work at the edge; it also homes root/the preview overlay to the cursor's
        // screen, so the preview follows the drag across monitors.
        if (root.edgeDropWatch) {
            const target = root.edgeDropTargetRect(win);
            if (target && target.width > 0 && target.height > 0) {
                // the edge owns the drag now - tear down the auto-trigger picker if it was up.
                if (root.autoMode) {
                    root.autoMode = false;
                    root.autoAnchored = false;
                    root.dragging = false;
                }
                root.autoDragPending = false;
                root.windowDrop = null;
                root.edgePreviewRect = target;
                if (!root.edgePreview) {
                    root.edgePreview = true;
                    root.targetTitle = "";
                    root.targetIconName = "";
                    root.visible = true;
                }
                return;
            }
            if (root.edgePreview) {
                // pulled back off the edge - drop the preview and fall through to the picker
                // logic. Re-arm the picker trigger (if enabled) from here so continued inward
                // motion can re-open it.
                root.edgePreview = false;
                root.visible = false;
                if (root.dragAutoTrigger) {
                    root.autoDragPending = true;
                    root.autoDragStartPos = Workspace.cursorPos;
                }
            }
        }
        // Drop-onto-window: next in line after the screen edge. While the cursor is over
        // another window this owns the drag and the picker stays down, except when the
        // picker is already up and the cursor is inside it - then the picker keeps it.
        if (root.windowDropWatch) {
            const pickerOwns = root.visible && root.autoMode
                && root.pointInCanvas(root.externalCanvasPoint());
            const drop = pickerOwns ? null : root.windowDropTarget(win);
            if (drop) {
                if (root.autoMode) {
                    root.autoMode = false;
                    root.autoAnchored = false;
                    root.dragging = false;
                }
                root.autoDragPending = false;
                root.edgePreviewRect = drop.slot;
                root.windowDrop = drop;
                if (!root.visible) {
                    root.targetTitle = "";
                    root.targetIconName = "";
                    root.visible = true;
                }
                return;
            }
            if (root.windowDrop) {
                // moved off the window - same pull-back as the edge branch above
                root.windowDrop = null;
                root.visible = false;
                if (root.dragAutoTrigger) {
                    root.autoDragPending = true;
                    root.autoDragStartPos = Workspace.cursorPos;
                }
            }
        }
        if (root.autoDragPending && !root.visible) {
            const p = Workspace.cursorPos;
            const dx = p.x - root.autoDragStartPos.x, dy = p.y - root.autoDragStartPos.y;
            // compare squared distances - avoids a sqrt per drag step (cheap in isolation,
            // but high-Hz pointers fire this on every motion tick).
            if (dx * dx + dy * dy >= root.autoDragThreshold * root.autoDragThreshold) {
                root.autoDragPending = false;
                // capture direction-of-motion before showAuto so the picker can spawn
                // trailing the cursor's drag direction (see canvasX/canvasY).
                root.dragDirection = Qt.point(Math.sign(dx), Math.sign(dy));
                root.showAuto(win);
            }
            return;
        }
        if (root.visible && root.autoMode && root.targetWindow === win) {
            // the picker is pinned to whichever screen the drag started on, but a drag
            // routinely crosses monitors - re-home it (geometry, work area, per-monitor
            // grid override) to follow the cursor's current screen. Any in-progress
            // anchor/selection is screen-local, so it gets dropped and has to be
            // re-picked on the new screen rather than translated.
            const curScreen = root.currentDragScreen();
            if (curScreen !== root.targetScreenObj) {
                // Re-spawn at the crossing point, not at the position the picker was
                // originally summoned from: canvasX/canvasY read spawnCursorPos, which
                // showAuto captured on the *first* screen, so without this the picker
                // reappeared at the old screen's cursor height (autoAtCursor) - visually
                // unrelated to where the cursor actually entered the new screen.
                // dragDirection is deliberately kept: the drag is still moving the same
                // way, so the picker should still trail it the same way.
                root.spawnCursorPos = Workspace.cursorPos;
                root.rehomeForScreen(curScreen);
                root.autoAnchored = false;
                root.dragging = false;
            }

            const p = root.externalCanvasPoint();
            root.dragCurrent = p;
            if (root.autoAnchored && !root.pointInCanvas(p)) {
                // cursor left the picker - drop the anchor and any in-progress
                // selection. onNativeDragFinished then sees autoAnchored=false and
                // calls hide() instead of finishDrag(), so a release past the
                // picker's edge doesn't commit a resize the user never confirmed by
                // hovering over a target cell. On re-entry, the next branch
                // re-anchors at the new cursor position.
                root.autoAnchored = false;
                root.dragging = false;
            } else if (!root.autoAnchored && root.pointInCanvas(p)) {
                root.dragStart = p;
                root.autoAnchored = true;
                root.dragging = true;
            }
            return;
        }
    }

    function onNativeDragFinished(win) {
        if (win !== root.nativeDragWindow) return;
        root.stepLinkedResize(win);
        root.endLinkedResize();
        root.nativeDragActive = false;
        root.nativeDragWindow = null;
        root.autoDragPending = false;
        // only a drop that was actually previewed commits; re-resolved from the release
        // position below, like the edge-drop, in case the target moved or closed.
        const windowDropArmed = root.windowDropWatch && root.windowDrop !== null;
        root.windowDropWatch = false;
        root.windowDrop = null;
        if (root.visible && root.dragTriggered && root.targetWindow === win) {
            root.dragCurrent = root.externalCanvasPoint();
            root.finishDrag();
            return;
        }
        if (root.visible && root.autoMode && root.targetWindow === win) {
            root.dragCurrent = root.externalCanvasPoint();
            if (root.autoAnchored) {
                root.finishDrag();
            } else {
                // cursor never crossed into the picker this drag - nothing to commit,
                // the native move already applied itself, so just get out of the way
                hide();
            }
            return;
        }
        // Native edge-drop release. Recompute the target from the release position rather
        // than trusting the last step's edgePreviewRect - if the cursor pulled back off the
        // edge just before release, the recompute returns null and nothing snaps (the native
        // move already applied itself), exactly like letting go in the middle of the screen.
        if (root.edgeDropWatch) {
            const target = root.edgeDropTargetRect(win);
            root.edgePreview = false;
            root.edgeDropWatch = false;
            root.edgePreviewRect = Qt.rect(0, 0, 0, 0);
            root.visible = false;
            if (target && target.width > 0 && target.height > 0) {
                root.targetWindow = win;
                root.commit(target.x, target.y, target.width, target.height);
                return;
            }
        }
        if (windowDropArmed) {
            const drop = root.windowDropTarget(win);
            root.edgePreviewRect = Qt.rect(0, 0, 0, 0);
            root.visible = false;
            if (drop) root.commitWindowDrop(win, drop);
        }
        // snapGaps deliberately does NOT trigger here - a plain native window resize (edge/
        // corner drag with the mouse) has nothing to do with VibeTiles; it only follows a
        // VibeTiles-initiated placement, from finishDrag(). See snapGaps' own comment.
    }

    function onNativeDragWindowClosed(win) {
        if (root.nativeDragWindow === win) {
            root.nativeDragActive = false;
            root.nativeDragWindow = null;
            root.endLinkedResize();
            // only the drag we're actually tracking cancels a pending auto-trigger; a
            // bystander window closing mid-drag must not clear it (that would swallow a
            // legitimate pending trigger for the window still being dragged).
            root.autoDragPending = false;
            // likewise tear down any armed edge-drop preview for the window that just died,
            // so its overlay can't linger and can't commit against a dead window.
            if (root.edgeDropWatch || root.edgePreview || root.windowDrop) {
                root.edgePreview = false;
                root.edgeDropWatch = false;
                root.edgePreviewRect = Qt.rect(0, 0, 0, 0);
                root.visible = false;
            }
            root.windowDropWatch = false;
            root.windowDrop = null;
        }
        // a dead window's remembered size is dead too - drop it whatever drag it was in
        root.forgetSize(win);
        // forget the window's handlers - its connections die with it, but the entry would
        // otherwise sit in hookedWindows for the rest of the session. Only the bookkeeping
        // is dropped here, not the connections: disconnecting win.closed from inside its
        // own emission is exactly the case worth not being clever about.
        for (let i = 0; i < root.hookedWindows.length; i++) {
            if (root.hookedWindows[i].win === win) {
                root.hookedWindows.splice(i, 1);
                break;
            }
        }
    }

    // Every window we've connected to, with the exact handler functions used - a closure
    // can only be disconnected through the same reference that was connected, so these
    // have to be retained rather than created inline at connect time.
    //
    // Without this, unloading the script (which bump.sh does on every deploy) tears down
    // the root object but leaves these connections live on each window, and they then
    // throw "Cannot read property 'onNativeDragStepped' of null" on every step of every
    // subsequent drag - once per dead generation, accumulating for the life of the
    // kwin_wayland process.
    property var hookedWindows: []

    function hookWindow(win) {
        // interactiveMove* signals only fire for normal windows anyway, but skip
        // panels/popups/transients upfront - 4 signal connections per dot on the
        // desktop adds up, and Workspace.windowAdded fires for everything.
        if (!win.normalWindow) return;
        const h = {
            win: win,
            started: () => root.onNativeDragStarted(win),
            stepped: (rect) => root.onNativeDragStepped(win, rect),
            finished: () => root.onNativeDragFinished(win),
            closed: () => root.onNativeDragWindowClosed(win)
        };
        root.hookedWindows.push(h);
        win.interactiveMoveResizeStarted.connect(h.started);
        win.interactiveMoveResizeStepped.connect(h.stepped);
        win.interactiveMoveResizeFinished.connect(h.finished);
        win.closed.connect(h.closed);
    }

    function unhookWindow(win) {
        for (let i = 0; i < root.hookedWindows.length; i++) {
            const h = root.hookedWindows[i];
            if (h.win !== win) continue;
            root.hookedWindows.splice(i, 1);
            try {
                win.interactiveMoveResizeStarted.disconnect(h.started);
                win.interactiveMoveResizeStepped.disconnect(h.stepped);
                win.interactiveMoveResizeFinished.disconnect(h.finished);
                win.closed.disconnect(h.closed);
            } catch (e) {
                // window already torn down - the connections went with it
            }
            return;
        }
    }

    // Drop every connection before the root object goes away. Without this the handlers
    // outlive the script and fire against a null root forever after (see hookedWindows).
    Component.onDestruction: {
        const hooks = root.hookedWindows.slice();
        for (let i = 0; i < hooks.length; i++) root.unhookWindow(hooks[i].win);
    }

    // {id-less, direct object refs} list of every normal window across all monitors,
    // current-screen entries first (drives the compact title bar's window-switch picker)
    function refreshWindowList() {
        const targetName = targetScreenObj ? targetScreenObj.name : "";
        const wins = Workspace.stackingOrder;
        const result = [];
        for (let i = 0; i < wins.length; i++) {
            const w = wins[i];
            if (!w.normalWindow || w.minimized) continue;
            result.push({
                win: w,
                title: w.caption || "",
                icon: w.resourceClass ? w.resourceClass.toString() : "",
                screen: w.output ? w.output.name : ""
            });
        }
        result.sort((a, b) => {
            const aCur = a.screen === targetName ? 0 : 1;
            const bCur = b.screen === targetName ? 0 : 1;
            if (aCur !== bCur) return aCur - bCur;
            if (a.screen !== b.screen) return a.screen < b.screen ? -1 : 1;
            return a.title < b.title ? -1 : (a.title > b.title ? 1 : 0);
        });
        root.windowList = result;
    }

    function selectWindow(entry) {
        // the picker list is debounced (refreshTimer), so entry.win can have closed in the
        // gap between the last refresh and this click. Selecting a dead window sets a dead
        // target and commit() then silently no-ops - drop the stale entry instead. The
        // normalWindow read is itself wrapped: touching a torn-down window throws.
        try {
            if (!entry || !entry.win || !entry.win.normalWindow) return;
        } catch (e) {
            return;
        }
        targetWindow = entry.win;
        targetTitle = entry.title;
        targetIconName = entry.icon;
        root.pickerOpen = false;
    }

    // ---- drag/snap math (ported as-is from the daemon's main.qml) ----

    function snapFloorX(px) {
        const cellW = canvasWidth / effCols;
        const idx = Math.floor(px / cellW);
        return Math.max(0, Math.min(effCols, idx)) * cellW;
    }
    function snapCeilX(px) {
        const cellW = canvasWidth / effCols;
        const idx = Math.ceil(px / cellW);
        return Math.max(0, Math.min(effCols, idx)) * cellW;
    }
    function snapFloorY(py) {
        const cellH = canvasHeight / effRows;
        const idx = Math.floor(py / cellH);
        return Math.max(0, Math.min(effRows, idx)) * cellH;
    }
    function snapCeilY(py) {
        const cellH = canvasHeight / effRows;
        const idx = Math.ceil(py / cellH);
        return Math.max(0, Math.min(effRows, idx)) * cellH;
    }
    function rawRect() {
        const x1 = Math.min(dragStart.x, dragCurrent.x);
        const y1 = Math.min(dragStart.y, dragCurrent.y);
        const x2 = Math.max(dragStart.x, dragCurrent.x);
        const y2 = Math.max(dragStart.y, dragCurrent.y);
        return Qt.rect(x1, y1, x2 - x1, y2 - y1);
    }
    function snappedRect() {
        const x1 = snapFloorX(Math.min(dragStart.x, dragCurrent.x));
        const y1 = snapFloorY(Math.min(dragStart.y, dragCurrent.y));
        const x2 = snapCeilX(Math.max(dragStart.x, dragCurrent.x));
        const y2 = snapCeilY(Math.max(dragStart.y, dragCurrent.y));
        return Qt.rect(x1, y1, x2 - x1, y2 - y1);
    }
    function computeSelBounds() {
        const cellW = canvasWidth / effCols;
        const cellH = canvasHeight / effRows;
        const r = root.rawRect();
        return {
            c1: Math.max(0, Math.min(effCols, Math.floor(r.x / cellW))),
            c2: Math.max(0, Math.min(effCols, Math.ceil((r.x + r.width) / cellW))),
            r1: Math.max(0, Math.min(effRows, Math.floor(r.y / cellH))),
            r2: Math.max(0, Math.min(effRows, Math.ceil((r.y + r.height) / cellH)))
        };
    }
    property var selBounds: root.dragging ? root.computeSelBounds() : null

    // ---- commit / overlap-resize (ported from main.cpp:477-547) ----

    function overlapRect(a, b) {
        const ix = Math.max(a.x, b.x), iy = Math.max(a.y, b.y);
        const ix2 = Math.min(a.x + a.width, b.x + b.width);
        const iy2 = Math.min(a.y + a.height, b.y + b.height);
        if (ix2 <= ix || iy2 <= iy) return null;
        return Qt.rect(ix, iy, ix2 - ix, iy2 - iy);
    }

    // How much of a neighbour's edge is allowed to stick out past the placement and still
    // count as a "fully covered" edge slice. Base is the daemon's 24px alignment epsilon -
    // enough for rounding and decoration slop between two grid-placed windows, nothing more.
    // With snapGaps on, that widens to snapGapMax: a neighbour that was resized off-grid by
    // hand overhangs the placement by real pixels (tens to low hundreds), so the strict test
    // saw "not an edge slice" and left it sitting half-hidden underneath - the exact case
    // snapGaps exists to absorb elsewhere. The proportional guard keeps the widened tolerance
    // from turning a genuinely partial overlap into a slice: the overhang has to be small
    // relative to the neighbour too, not just small in absolute pixels, so covering a third
    // of a 300px window is still a partial overlap and left alone.
    //
    // Returns true if `span` (the neighbour's extent on an axis) counts as covered by `ovSpan`.
    function coversSpan(ovSpan, span) {
        const tol = root.snapGaps ? Math.max(24, root.snapGapMax) : 24;
        const slack = span - ovSpan;
        return slack <= tol && slack <= span * 0.4;
    }

    // shrinks any other window whose edge is fully covered by target's new rectangle, so
    // it retreats into the remaining space instead of ending up hidden underneath -
    // only handles a clean full-width/full-height edge slice, same as the daemon version.
    // Returns the number of neighbours it actually moved, and appends each one's new
    // geometry to `changedOut` if given (see commit(), which grows the placed window into
    // the space a shrink just freed and can't trust a read-back for it).
    // `alreadyMoved`, when given, is the list relocateCoveredWindows just wrote ({win, rect}
    // entries) - those windows are skipped outright. They must be: this pass re-reads
    // ow.frameGeometry, which on the same tick still returns the window's PRE-move rect (the
    // same staleness commit()'s gap-close guards against with pendingGeoms). A relocated
    // window therefore still reads as overlapping the placement, and gets shrunk a second
    // time to a rect derived from where it used to be - undoing the size the relocate just
    // gave it. Harmless until coversSpan's epsilon widened to snapGapMax: before that, a
    // fully-covered window's shrink remainder failed the >50px guard below, so the second
    // write never landed. The two cases are meant to be disjoint anyway - a window that was
    // relocated has no edge slice left to shrink.
    // Is `win` one of the {win, rect} entries in `list`? Linear scan, same reason as
    // restoreEntryIndex/hookedWindows: window ids are QUuids and don't key a JS object.
    function wasMoved(list, win) {
        for (let i = 0; i < list.length; i++) {
            if (list[i].win === win) return true;
        }
        return false;
    }

    function resizeOverlappingWindows(target, changedOut, alreadyMoved) {
        const EPS = root.snapGaps ? Math.max(24, root.snapGapMax) : 24;
        let adjusted = 0;
        // `target` is already the placed window's final geometry, inset by windowGap/2 - so
        // retreating a neighbour to exactly the overlap edge leaves the two frames touching,
        // with no gap at all. Back it off by the full gap instead, which reproduces the
        // spacing two grid-placed windows get by construction (each inset windowGap/2 from
        // the shared cell boundary).
        const gap = root.windowGap;
        const others = Workspace.stackingOrder;
        for (let j = 0; j < others.length; j++) {
            const ow = others[j];
            // per-window guard: a sibling destroyed mid-loop shouldn't abort adjusting the
            // rest. The call site already has an outer try/catch, but that catches once for
            // the whole loop - this keeps a single dead window from cutting the pass short.
            try {
                if (ow === root.targetWindow || ow.minimized || !root.isRealWindow(ow)) continue;
                if (alreadyMoved && root.wasMoved(alreadyMoved, ow)) continue;
                const c = ow.frameGeometry;
                const ov = overlapRect(c, target);
                if (!ov) continue;
                let nr = null;
                // Which side of the neighbour the overlap sits against: with the widened
                // tolerance both ends can be within EPS at once (a small window covered
                // nearly whole), so pick the end the overlap is actually flush with rather
                // than letting the first branch win by source order.
                if (root.coversSpan(ov.width, c.width)) {
                    const dTop = ov.y - c.y, dBottom = (c.y + c.height) - (ov.y + ov.height);
                    if (dTop <= dBottom && dTop <= EPS) {
                        const top = ov.y + ov.height + gap;
                        nr = Qt.rect(c.x, top, c.width, (c.y + c.height) - top);
                    } else if (dBottom <= EPS) {
                        nr = Qt.rect(c.x, c.y, c.width, (ov.y - gap) - c.y);
                    }
                }
                if (!nr && root.coversSpan(ov.height, c.height)) {
                    const dLeft = ov.x - c.x, dRight = (c.x + c.width) - (ov.x + ov.width);
                    if (dLeft <= dRight && dLeft <= EPS) {
                        const left = ov.x + ov.width + gap;
                        nr = Qt.rect(left, c.y, (c.x + c.width) - left, c.height);
                    } else if (dRight <= EPS) {
                        nr = Qt.rect(c.x, c.y, (ov.x - gap) - c.x, c.height);
                    }
                }
                if (nr && nr.width > 50 && nr.height > 50) {
                    ow.setMaximize(false, false);
                    ow.frameGeometry = nr;
                    adjusted++;
                    if (changedOut) changedOut.push({ win: ow, rect: nr });
                }
            } catch (e) {
                continue;
            }
        }
        return adjusted;
    }

    // ---- relocate fully-covered windows (gated on relocateCovered) ----
    //
    // resizeOverlappingWindows only handles a clean edge slice - a window the placement
    // covers *entirely* falls through it (the shrink computes a zero-size remainder, which
    // fails its own > 50 guard), leaving the window intact but completely hidden
    // underneath. This moves it to the largest free region instead.
    //
    // "Free region" is defined over the grid rather than as a true maximal-empty-rectangle
    // search: candidates are all grid-aligned rectangles, tested at their final inset
    // geometry against every other window. That keeps the result predictable and aligned
    // with everything else the tiler does, and the candidate count is small enough
    // (~200 for a 6x4 grid) to brute-force once per commit.

    // Largest grid-aligned rectangle on the current screen that no other window occupies,
    // as a final (gap-inset) geometry, or null if nothing big enough is free.
    // every window that counts as occupying space on the current screen, `exceptWin` aside
    // Is this something the user thinks of as a window - i.e. something that both counts as
    // occupying space and is worth relocating? `normalWindow` alone is not enough: confirmed
    // live, plasmashell's desktop/wallpaper window passes it and reports the full screen
    // rect (0,681 3440x1440), which made every candidate region look 100% occupied and
    // silently disabled free-region search entirely. Helper windows kept out of the taskbar
    // (xwaylandvideobridge) are excluded for the same reason. Read defensively - an
    // undefined property must not end up skipping everything.
    function isRealWindow(w) {
        if (!w || w.minimized || !w.normalWindow) return false;
        if (w.skipTaskbar === true || w.skipSwitcher === true) return false;
        if (w.desktopWindow === true || w.dock === true) return false;
        // our own overlay is in the stacking order too, and in the drag-triggered path it is
        // forced fullscreen - so without this it reports the whole screen as occupied at
        // exactly the moment commit() asks where the free space is, pinning every candidate
        // region at 100% occupied and silently disabling free-region search altogether
        // (confirmed live: class and caption both empty, every type flag false, geometry
        // exactly the output rect). Script-owned windows carry no resourceClass; every real
        // application window does.
        if (!w.resourceClass || String(w.resourceClass) === "") return false;
        return true;
    }

    // Geometry a window is *about* to have, overriding what frameGeometry currently reads
    // back. Set only for the duration of commit()'s post-shrink gap-close (see there): a
    // neighbour written a moment earlier in the same commit still reads its OLD rect, which
    // made it look like an obstacle overlapping the placed window - and expandRectFor bails
    // outright on an overlapping obstacle, so the gap-close silently did nothing. (The
    // symptom: the placed window took the plain grid size on the drop, then filled the freed
    // space correctly if you dropped it on the same cells a second time, once the read had
    // caught up.) An array of {win, rect}, matching hookedWindows/restoreGeoms - window ids
    // are QUuids and don't work as JS object keys.
    property var pendingGeoms: null

    function pendingGeomFor(win) {
        const p = root.pendingGeoms;
        if (!p) return null;
        for (let i = 0; i < p.length; i++) if (p[i].win === win) return p[i].rect;
        return null;
    }

    function occupiedRects(exceptWin) {
        const occupied = [];
        const wins = Workspace.stackingOrder;
        for (let i = 0; i < wins.length; i++) {
            const ow = wins[i];
            // isRealWindow() and the frameGeometry read below both touch a live window
            // object that can vanish during the scan - a dead one simply doesn't count as
            // occupying space, so skip it rather than throw the whole occupancy build.
            try {
                if (ow === exceptWin || !root.isRealWindow(ow)) continue;
                const c = root.pendingGeomFor(ow) || ow.frameGeometry;
                if (!root.overlapRect(c, root.availGeo)) continue;
                occupied.push(c);
            } catch (e) {
                continue;
            }
        }
        return occupied;
    }

    // The grid-aligned rectangle nearest to an arbitrary one, as a final (gap-inset)
    // geometry. Rounds to the closest cell boundary rather than enclosing outward: this
    // tidies a floating window's geometry into the grid, and growing it to enclose would
    // just make it more likely to collide with whatever is next to it.
    function snapRectToGrid(r) {
        const cols = root.activeGridCols, rows = root.activeGridRows;
        const cellW = root.availGeo.width / cols, cellH = root.availGeo.height / rows;
        const inset = root.windowGap / 2;
        let c1 = Math.round((r.x - root.availGeo.x) / cellW);
        let c2 = Math.round((r.x + r.width - root.availGeo.x) / cellW);
        let r1 = Math.round((r.y - root.availGeo.y) / cellH);
        let r2 = Math.round((r.y + r.height - root.availGeo.y) / cellH);
        c1 = root.clamp(c1, 0, cols - 1);
        r1 = root.clamp(r1, 0, rows - 1);
        c2 = root.clamp(c2, c1 + 1, cols);
        r2 = root.clamp(r2, r1 + 1, rows);
        return Qt.rect(
            root.availGeo.x + c1 * cellW + inset,
            root.availGeo.y + r1 * cellH + inset,
            (c2 - c1) * cellW - root.windowGap,
            (r2 - r1) * cellH - root.windowGap
        );
    }

    // Is r free of every real window (other than exceptWin)? Plain pixel overlap, no
    // grid/threshold involved - used for final placement checks where "mostly free" isn't
    // good enough.
    function pixelRegionFree(r, exceptWin) {
        const occ = root.occupiedRects(exceptWin);
        for (let i = 0; i < occ.length; i++) {
            if (root.overlapRect(r, occ[i])) return false;
        }
        return true;
    }

    // Largest free rectangle anywhere on the screen that a covered window could move into, as
    // a final (gap-inset) geometry, or null if nothing big enough is free. `placed` (the
    // just-committed target rect) counts as an obstacle like any other window.
    //
    // Pixel-accurate via coordinate compression, not grid-quantised: the earlier grid version
    // (buildCellOccupancy at 35% cell-fill) rounded away any free space that didn't happen to
    // fill whole cells, e.g. a neighbour resized off-grid leaving a 2.4-cell gap reported as
    // only 2 free cells. Candidate edges are every obstacle's left/right/top/bottom (inflated
    // to slot space, same half-gap convention as expandRectFor) plus the work-area bounds -
    // the true maximal empty rectangle always has its edges on one of those lines. Obstacle
    // counts on a real desktop are small (a handful of windows), so the O(n^2) x O(n^2)
    // candidate sweep is cheap; this only runs once per commit, not per frame.
    function findFreeRegion(forWin, placed, exceptWin) {
        const availGeo = root.availGeo;
        const half = root.windowGap / 2;
        const aL = availGeo.x, aT = availGeo.y;
        const aR = availGeo.x + availGeo.width, aB = availGeo.y + availGeo.height;

        // a relocated window still has to be usable - don't shove it into a sliver
        const minW = Math.max(200, root.linkedLimit(forWin, "min", "width", 0));
        const minH = Math.max(150, root.linkedLimit(forWin, "min", "height", 0));

        const occ = root.occupiedRects(exceptWin !== undefined ? exceptWin : forWin);
        const obs = [];
        function addObstacle(o) {
            const oL = Math.max(aL, o.x - half), oT = Math.max(aT, o.y - half);
            const oR = Math.min(aR, o.x + o.width + half), oB = Math.min(aB, o.y + o.height + half);
            if (oR - oL > 0 && oB - oT > 0) obs.push({ l: oL, t: oT, r: oR, b: oB });
        }
        for (let i = 0; i < occ.length; i++) addObstacle(occ[i]);
        if (placed) addObstacle(placed);

        let xs = [aL, aR], ys = [aT, aB];
        for (let i = 0; i < obs.length; i++) {
            xs.push(obs[i].l, obs[i].r);
            ys.push(obs[i].t, obs[i].b);
        }
        xs = Array.from(new Set(xs)).sort((a, b) => a - b);
        ys = Array.from(new Set(ys)).sort((a, b) => a - b);

        function slotFree(L, T, R, B) {
            for (let i = 0; i < obs.length; i++) {
                const o = obs[i];
                if (o.r > L + 0.5 && o.l < R - 0.5 && o.b > T + 0.5 && o.t < B - 0.5) return false;
            }
            return true;
        }

        let best = null, bestScore = 0;
        for (let i = 0; i < xs.length; i++) {
            for (let j = i + 1; j < xs.length; j++) {
                const L = xs[i], R = xs[j];
                if (R - L < minW) continue;
                for (let k = 0; k < ys.length; k++) {
                    for (let m = k + 1; m < ys.length; m++) {
                        const T = ys[k], B = ys[m];
                        if (B - T < minH) continue;
                        if (!slotFree(L, T, R, B)) continue;
                        const cand = Qt.rect(L + half, T + half, (R - L) - root.windowGap, (B - T) - root.windowGap);
                        if (cand.width < minW || cand.height < minH) continue;
                        const score = cand.width * cand.height;  // biggest free region wins
                        if (score <= bestScore) continue;
                        best = cand;
                        bestScore = score;
                    }
                }
            }
        }
        return best;
    }

    function relocateCoveredWindows(target, vacated, changedOut) {
        const others = Workspace.stackingOrder;
        let moved = 0;
        const covered = [];
        for (let j = 0; j < others.length; j++) {
            const ow = others[j];
            if (ow === root.targetWindow || !root.isRealWindow(ow)) continue;
            const c = ow.frameGeometry;
            const ov = root.overlapRect(c, target);
            if (!ov) continue;
            // fully covered on both axes - a window covered on only one is an edge slice,
            // which resizeOverlappingWindows already shrinks properly. Same tolerance as
            // that pass (coversSpan): an off-grid neighbour overhanging the placement by a
            // snapGaps-sized sliver on both axes is swallowed for all practical purposes,
            // and the shrink pass can't help it either - the remainder it computes fails
            // its own >50px guard, so without this the window just stays hidden underneath.
            if (root.coversSpan(ov.width, c.width) && root.coversSpan(ov.height, c.height))
                covered.push(ow);
        }

        // The spot the placed window just left is the one region guaranteed to be free, and
        // it's also the one the gesture *means*: dropping A onto B is a swap, so B belongs
        // where A was, not in whatever unrelated corner happens to be the largest empty
        // rectangle. So it's tried FIRST, not as a fallback - the free-region search is what
        // handles the leftovers (a second covered window, or a target dragged in from another
        // screen, which vacates nothing here). Claimed by the first covered window that can
        // use it; anyone after that falls back to the region search.
        let swapAvailable = vacated && vacated.width >= 200 && vacated.height >= 150
            && !root.overlapRect(vacated, target);
        for (let j = 0; j < covered.length; j++) {
            let spot = null;
            if (swapAvailable) {
                // The vacated slot is whatever geometry the placed window happened to have,
                // which for a window that was never tiled is an arbitrary floating rectangle -
                // handing it to the covered window just moves the untidiness around, and makes
                // a swap onto an untiled window produce a floating B (reported live). So only
                // the grid-snapped version counts as a swap here; the raw rect is kept as a
                // last resort below, after the free-region search has had its turn. The grid
                // region around a floating window is not necessarily free, hence the test.
                const snapped = root.snapRectToGrid(vacated);
                if (!root.overlapRect(snapped, target)
                        && root.pixelRegionFree(snapped, covered[j])) {
                    spot = snapped;
                    swapAvailable = false;  // one window per vacated slot
                }
            }
            // recomputed per window, so two windows covered by one placement can't both be
            // sent to the same spot - the first one placed counts as occupied for the next.
            if (!spot) spot = root.findFreeRegion(covered[j], target, covered[j]);
            if (!spot && swapAvailable) {
                // Nothing grid-aligned anywhere and the vacated slot doesn't snap cleanly:
                // an inherited floating rect still beats leaving the window buried.
                spot = vacated;
                swapAvailable = false;
            }
            // nothing free and nothing vacated: leave the window where it is rather than
            // invent a position. It stays hidden underneath, which is the old behaviour,
            // but a guessed spot on a full screen would be worse than a predictable no-op.
            if (!spot) continue;
            try {
                const nr = Qt.rect(Math.round(spot.x), Math.round(spot.y),
                                   Math.round(spot.width), Math.round(spot.height));
                covered[j].setMaximize(false, false);
                covered[j].frameGeometry = nr;
                moved++;
                if (changedOut) changedOut.push({ win: covered[j], rect: nr });
            } catch (e) {
                console.warn("vibetiles: covered-window relocate failed:", e);
            }
        }
        return moved;
    }

    function commit(x, y, w, h) {
        if (!targetWindow) {
            hide();
            return;
        }
        const inset = windowGap / 2;
        const gx = x + inset;
        const gy = y + inset;
        const gw = Math.max(50, w - windowGap);
        const gh = Math.max(50, h - windowGap);
        const rect = Qt.rect(Math.round(gx), Math.round(gy), Math.round(gw), Math.round(gh));
        // snapshot before the write - this is the slot the placement frees up, and it's
        // what a covered window falls back to when no free region exists (see
        // relocateCoveredWindows). Only meaningful if the window was on this screen to
        // begin with; a target dragged in from another monitor vacates nothing here.
        const pg = targetWindow.frameGeometry;
        const vacated = root.overlapRect(pg, root.availGeo)
            ? Qt.rect(pg.x, pg.y, pg.width, pg.height) : null;
        // same snapshot, different lifetime: what a later titlebar drag gives back
        root.rememberSize(targetWindow, pg);
        targetWindow.setMaximize(false, false);
        try {
            targetWindow.frameGeometry = rect;
        } catch (e) {
            // can throw if the window is being destroyed between the read and the write
            console.warn("vibetiles: target window vanished during commit:", e);
            hide();
            return;
        }
        // relocate before shrink, so the covered-window test sees pre-shrink geometry. The
        // two cases are disjoint (a fully covered window has no edge slice to shrink), but
        // ordering it this way keeps that independence from being load-bearing.
        let neighboursChanged = 0;
        // Seeded with the placed window's own new rect, and kept live as pendingGeoms for
        // every scan below: the whole point of a swap (drop A onto B, B takes A's old spot)
        // is that the space A just vacated is free, and a frameGeometry read-back on this
        // tick still puts A there. Without the override findFreeRegion sees A at BOTH ends -
        // the stale rect over the vacated space plus `placed` over the new one - so the one
        // region B actually wants is excluded, and B lands in whatever sliver was left over,
        // half-size or worse (confirmed live, the reported symptom).
        const changedGeoms = [{ win: targetWindow, rect: rect }];
        root.pendingGeoms = changedGeoms;
        try {
            if (relocateCovered) {
                try {
                    neighboursChanged += relocateCoveredWindows(rect, vacated, changedGeoms);
                } catch (e) {
                    console.warn("vibetiles: covered-window relocate threw:", e);
                }
            }
            if (resizeOverlapping) {
                try {
                    // changedGeoms doubles as the skip list - anything relocateCoveredWindows
                    // already moved is off-limits here (see resizeOverlappingWindows). The
                    // seed entry is the target, which that pass skips on its own anyway.
                    neighboursChanged += resizeOverlappingWindows(rect, changedGeoms,
                                                                 changedGeoms.slice());
                } catch (e) {
                    // a sibling window we tried to make room for was destroyed mid-loop
                    console.warn("vibetiles: overlap-resize threw:", e);
                }
            }
        } finally {
            root.pendingGeoms = null;
        }
        // Second half of the off-grid-neighbour case: a neighbour that overhung the placement
        // has just retreated (or moved away entirely), which leaves a fresh sliver of free
        // space beside the window we placed - the mirror image of the gap snapGaps closes.
        // finishDrag's own pre-commit gap-close can't see it (it runs against pre-shrink
        // geometry, before any of this), so close it here, against the settled result.
        //
        // This is deliberately the one path that resizes the placed window twice: it only
        // runs when a neighbour actually moved, which is already a multi-window rearrangement.
        // Same cap and same screen-edge exclusion as every other snapGaps growth.
        //
        // The obstacle scan runs off pendingGeoms - the rects the two passes just WROTE - not
        // a read-back. A neighbour's frameGeometry still returns its old rect this same tick,
        // which reads as an obstacle overlapping the placed window, and expandRectFor bails
        // outright on that: the whole gap-close then silently no-opped on the drop, and only
        // worked if you re-dropped on the same cells afterwards (confirmed live).
        if (snapGaps && neighboursChanged > 0) {
            try {
                root.pendingGeoms = changedGeoms;
                const grownSlot = computeGapClosedRect(targetWindow, null, rect);
                if (grownSlot) {
                    const gi = windowGap / 2;
                    targetWindow.frameGeometry = Qt.rect(
                        Math.round(grownSlot.x + gi), Math.round(grownSlot.y + gi),
                        Math.round(Math.max(50, grownSlot.width - windowGap)),
                        Math.round(Math.max(50, grownSlot.height - windowGap)));
                }
            } catch (e) {
                console.warn("vibetiles: post-shrink gap-close threw:", e);
            } finally {
                // never leave a stale override behind - every later scan would trust it
                root.pendingGeoms = null;
            }
        }
        hide();
    }

    // The largest free rectangle that *contains* forWin and grows into the actual empty
    // PIXELS around it - not grid cells. The grid-quantised version rounded a whole cell of
    // usable space away whenever a neighbour was resized off the grid (a cell counts as
    // "taken" at 35% coverage, so a 40%-covered cell was lost entirely); this measures
    // against the real window edges instead. Returns screen coords, pre-gap-inset (what
    // commit() expects), or null if forWin can't be read or there's no room to grow.
    //
    // Works in "slot space": every window's slot is its frame inflated by windowGap/2, so
    // VibeTiles-placed windows tile edge-to-edge with no gap between slots. forWin's slot is
    // grown into the free slot-space between the obstacle slots; commit() then re-insets
    // windowGap/2, restoring exactly one windowGap between neighbours and windowGap/2 at the
    // screen edge - the same spacing the grid path produced. `screen` is unused now (the math
    // is pixel-based off frameGeometry and root.availGeo) but kept in the signature so callers
    // needn't change; root must be homed to it (occupiedRects/availGeo read root state).
    // presetFg, when given, is reused instead of a fresh forWin.frameGeometry read - see
    // computeGapClosedRect, whose caller (finishDrag) computes a placement's geometry itself
    // rather than reading it back from the window, since a fresh read could return a different,
    // mid-settle value while a placement's move/resize animation is still in flight (confirmed
    // live on rapid back-to-back placements).
    function expandRectFor(forWin, screen, presetFg) {
        let fg = presetFg;
        if (!fg) {
            try { fg = forWin.frameGeometry; } catch (e) { return null; }
        }
        if (!fg || fg.width <= 0 || fg.height <= 0) return null;
        const availGeo = root.availGeo;
        const half = root.windowGap / 2;
        const aL = availGeo.x, aT = availGeo.y;
        const aR = availGeo.x + availGeo.width, aB = availGeo.y + availGeo.height;
        // seed slot (recover forWin's pre-inset slot), clamped to the work area
        const sL = Math.max(aL, fg.x - half);
        const sT = Math.max(aT, fg.y - half);
        const sR = Math.min(aR, fg.x + fg.width + half);
        const sB = Math.min(aB, fg.y + fg.height + half);
        if (sR - sL <= 0 || sB - sT <= 0) return null;
        // obstacle slots: other real windows, inflated and clamped the same way. A window that
        // overlaps the seed can't be grown "around" - the free-rectangle premise this function
        // works on is already violated, so bail entirely rather than silently drop just that
        // obstacle. Dropping it only from the per-edge growth math (the old behaviour) meant an
        // obstacle that merely grazed the seed lost ALL its constraining power, including on
        // edges it didn't actually overlap - confirmed live as growth reaching past a real,
        // closer neighbour (also discarded this way) out to the next obstacle further out.
        const occ = root.occupiedRects(forWin);
        const obs = [];
        for (let i = 0; i < occ.length; i++) {
            const o = occ[i];
            const oL = Math.max(aL, o.x - half), oT = Math.max(aT, o.y - half);
            const oR = Math.min(aR, o.x + o.width + half), oB = Math.min(aB, o.y + o.height + half);
            if (oR - oL <= 0 || oB - oT <= 0) continue;
            // 0.5px tolerance - a window already flush against forWin (shared edge, zero gap)
            // can land a hair past exact contact under fractional display scaling, and without
            // slack that reads as "overlapping" and aborts growth entirely. Confirmed live:
            // the same already-snapped starting position non-deterministically bailed here
            // depending on which way the rounding noise fell.
            if (oR > sL + 0.5 && oL < sR - 0.5 && oB > sT + 0.5 && oT < sB - 0.5) return null;
            obs.push({ l: oL, t: oT, r: oR, b: oB });
        }
        // Grow one edge at a time to the nearest blocking obstacle slot (or work-area edge).
        // growV/growH each yield a valid non-overlapping band; a window only limits the axis
        // it lies on relative to the current extent. Because per-edge greedy growth is order-
        // dependent, run vertical-then-horizontal and horizontal-then-vertical and keep the
        // larger result - both are valid rectangles enclosing the seed.
        function growV(L, R) {
            let t = aT, b = aB;
            for (let i = 0; i < obs.length; i++) {
                const o = obs[i];
                if (o.r > L && o.l < R) {          // horizontally overlaps the band
                    if (o.b <= sT) t = Math.max(t, o.b);   // sits above the seed
                    if (o.t >= sB) b = Math.min(b, o.t);   // sits below the seed
                }
            }
            return { t: t, b: b };
        }
        function growH(T, B) {
            let l = aL, r = aR;
            for (let i = 0; i < obs.length; i++) {
                const o = obs[i];
                if (o.b > T && o.t < B) {          // vertically overlaps the band
                    if (o.r <= sL) l = Math.max(l, o.r);   // sits left of the seed
                    if (o.l >= sR) r = Math.min(r, o.l);   // sits right of the seed
                }
            }
            return { l: l, r: r };
        }
        const v1 = growV(sL, sR);        // vertical-then-horizontal
        const h1 = growH(v1.t, v1.b);
        const a1 = (h1.r - h1.l) * (v1.b - v1.t);
        const h2 = growH(sT, sB);        // horizontal-then-vertical
        const v2 = growV(h2.l, h2.r);
        const a2 = (h2.r - h2.l) * (v2.b - v2.t);
        let L, T, R, B;
        if (a1 >= a2) { L = h1.l; R = h1.r; T = v1.t; B = v1.b; }
        else { L = h2.l; R = h2.r; T = v2.t; B = v2.b; }
        // no meaningful growth past the seed slot -> nothing to do (keeps Meta+Alt+E a no-op
        // when a window is already maximal in its free region).
        if (!(L < sL - 0.5 || R > sR + 0.5 || T < sT - 0.5 || B > sB + 0.5)) return null;
        return Qt.rect(L, T, R - L, B - T);
    }

    function expandToGap(forWin) {
        // No-overlay expansion: the active window grows into the largest free rectangle
        // that contains its current cells, in any of the four directions (transitively
        // through free corridors). If no larger qualifying rectangle exists, no-op.
        if (!forWin || !root.isRealWindow(forWin)) return;
        if (root.visible) {
            // picker is open; don't race its state setup against our own rehomeForScreen.
            hide();
            return;
        }
        root.loadConfig();
        // frameGeometry is a QML Qt.rect - it has no .center property in QML (only
        // .x/.y/.width/.height), so build the point manually before passing to screenAt.
        const fgCenter = Qt.point(forWin.frameGeometry.x + forWin.frameGeometry.width / 2,
                                  forWin.frameGeometry.y + forWin.frameGeometry.height / 2);
        const screen = root.screenAt(fgCenter);
        // rehome before expandRectFor - occupiedRects and commit() both read root state.
        root.rehomeForScreen(screen);
        const rect = root.expandRectFor(forWin, screen);
        if (!rect) return;
        // commit() re-applies windowGap/2 and runs the relocate/shrink passes, so an
        // expansion that pushes into another window behaves like a drag-to-place.
        root.targetWindow = forWin;
        root.commit(rect.x, rect.y, rect.width, rect.height);
    }

    // Opt-in (snapGaps), called from finishDrag() only: after a grid/compact-picker placement
    // commits, close any small leftover gap to a neighbour instead of leaving it there. The
    // scenario this targets: a neighbour was itself resized off-grid (with the mouse, outside
    // VibeTiles), so the tiler's usual edge-to-edge spacing doesn't hold and a placement
    // toward it lands a few pixels short of flush rather than landing exactly against it.
    // Deliberately NOT hooked to plain native window resizes - see snapGaps' own comment.
    //
    // Reuses expandRectFor (same slot-space growth used by expandToGap/edge-drop) to find
    // how far each edge could grow before hitting an obstacle, but only *applies* that growth
    // up to snapGapMax per edge - expandRectFor's own growth is deliberately unbounded (it's
    // meant to fill all available free space), which would make an ordinary grid placement
    // blow up to fill the whole free region - exactly the "windows resize way too big" failure
    // finishDrag's own comment warns about, just reached from a different trigger. Capping it
    // keeps this a gap-closer, not a second expand-to-fill path; genuinely filling free space
    // still requires Meta+Alt+E or autoExpandOnEdgeDrag, which the user opts into explicitly.
    // Any edge whose obstacle is farther than snapGapMax away is left where it landed.
    // win/screen are used only to exclude win from the obstacle scan and to read root.availGeo
    // for the right monitor - fg is the authoritative seed geometry (frame coords, already
    // gap-inset), independent of win's own live frameGeometry. Called from finishDrag() BEFORE
    // that placement is ever written to the window, with fg set to what the raw placement is
    // about to become - not read back afterward - so this never touches a live win.frameGeometry
    // read that a placement's own move/resize animation could still be settling. That used to be
    // a second commit() after the first had already landed (two visible resizes back to back);
    // folding the result into the caller's own single commit() removed that, and as a side
    // effect also removed the animation-vs-read race entirely rather than just outrunning it.
    // Returns the grown rect in slot space (matching commit()'s x/y/w/h), or null if there's no
    // gap worth closing.
    function computeGapClosedRect(win, screen, fg) {
        const grown = root.expandRectFor(win, screen, fg);
        if (!grown) return null;

        // expandRectFor works (and returns) in slot space - fg inflated by windowGap/2 - not
        // fg's own (already gap-inset) frame coordinates. Recover the same seed slot here so
        // the "how far did this edge grow" comparison isn't off by half a gap.
        const half = root.windowGap / 2;
        const sL = fg.x - half, sT = fg.y - half;
        const sR = fg.x + fg.width + half, sB = fg.y + fg.height + half;
        const grownR = grown.x + grown.width, grownB = grown.y + grown.height;

        // grown is a valid free rectangle enclosing the seed slot with each edge moved outward
        // (or left in place) toward the nearest obstacle/work-area edge. Clamping each edge's
        // movement independently only ever shrinks that rectangle back toward the seed, so the
        // clamped result stays a subset of grown - still free - without needing to re-derive it.
        //
        // Only close a gap toward a REAL neighbouring window - an edge whose growth reached
        // all the way to the work-area boundary (no obstacle stopped it) is left alone, even
        // if that boundary happens to be within snapGapMax. Screen-edge filling is
        // autoExpandOnEdgeDrag/Meta+Alt+E's job, opted into explicitly; without this exclusion
        // a window sitting near a screen edge with no neighbour at all crept toward that edge
        // by up to snapGapMax on every single resize/placement, confirmed live as a
        // creeping-left bug on repeated no-op resizes near the left edge.
        const availGeo = root.availGeo;
        const aL = availGeo.x, aT = availGeo.y;
        const aR = availGeo.x + availGeo.width, aB = availGeo.y + availGeo.height;
        const snapGapMax = root.snapGapMax;
        let L = sL, T = sT, R = sR, B = sB;
        if (Math.abs(grown.x - aL) > 0.5 && sL - grown.x > 0 && sL - grown.x <= snapGapMax) L = grown.x;
        if (Math.abs(grown.y - aT) > 0.5 && sT - grown.y > 0 && sT - grown.y <= snapGapMax) T = grown.y;
        if (Math.abs(grownR - aR) > 0.5 && grownR - sR > 0 && grownR - sR <= snapGapMax) R = grownR;
        if (Math.abs(grownB - aB) > 0.5 && grownB - sB > 0 && grownB - sB <= snapGapMax) B = grownB;
        if (L === sL && T === sT && R === sR && B === sB) return null;
        return Qt.rect(L, T, R - L, B - T);
    }

    // Target rect for a native edge-drop of `win`, or null if the cursor is not against a
    // screen edge (so a drop in the middle of the screen leaves the window untouched). When
    // other windows share the screen it fills the largest reachable gap containing the
    // window's current cells (expandRectFor); on an otherwise-empty screen - where that would
    // just maximise - it takes the half toward the edge, or the quarter at a corner. Returned
    // rect is screen coords, pre-gap-inset (what commit() expects).
    //
    // Homes root state to the cursor's screen as a side effect: occupiedRects / expandRectFor
    // read it, the preview overlay's geometry follows screenGeo, and commit() needs it. Safe
    // because the caller acts only on the returned rect - nothing is placed unless non-null.
    // Overlapping part of two rects. Width/height come back 0 (never negative) when they
    // don't overlap, so callers can test either dimension.
    function rectIntersect(a, b) {
        const x1 = Math.max(a.x, b.x), y1 = Math.max(a.y, b.y);
        const x2 = Math.min(a.x + a.width, b.x + b.width);
        const y2 = Math.min(a.y + a.height, b.y + b.height);
        return Qt.rect(x1, y1, Math.max(0, x2 - x1), Math.max(0, y2 - y1));
    }

    function edgeDropTargetRect(win) {
        if (!win || !root.isRealWindow(win)) return null;
        const p = Workspace.cursorPos;
        const screen = root.screenAt(p);
        if (!screen) return null;
        const g = screen.geometry;
        const t = root.edgeDropThreshold;
        // measured against the physical output edge (the cursor is shoved to the real edge,
        // which may sit past availGeo when a panel occupies that strip).
        const nearLeft = (p.x - g.x) <= t;
        const nearRight = (g.x + g.width - p.x) <= t;
        const nearTop = (p.y - g.y) <= t;
        const nearBottom = (g.y + g.height - p.y) <= t;
        if (!nearLeft && !nearRight && !nearTop && !nearBottom) return null;
        root.rehomeForScreen(screen);
        const availGeo = root.availGeo;
        // Corners get a much more forgiving zone than edges: reaching the drop zone at all
        // only needs one axis within edgeDropThreshold (16px), so requiring both axes within
        // that same 16px would make the corner a 16x16 target nobody can hit on purpose.
        // Same idea as Windows' snap corners - a band along the last stretch of each edge.
        const ct = root.cornerDropThreshold;
        const cLeft = (p.x - g.x) <= ct, cRight = (g.x + g.width - p.x) <= ct;
        const cTop = (p.y - g.y) <= ct, cBottom = (g.y + g.height - p.y) <= ct;
        // one horizontal AND one vertical edge at once, each unambiguous
        const atCorner = (cLeft !== cRight) && (cTop !== cBottom);
        // The exact half toward the edge, quarter at a corner - pixel-based, not
        // grid-quantised, so it's a clean 50/50 regardless of the configured grid. At a
        // corner both axes are halved, using the corner flags (the edge flags may have only
        // one axis set, which is exactly why the wider zone exists).
        const fLeft = atCorner ? cLeft : nearLeft, fRight = atCorner ? cRight : nearRight;
        const fTop = atCorner ? cTop : nearTop, fBottom = atCorner ? cBottom : nearBottom;
        const halfW = availGeo.width / 2, halfH = availGeo.height / 2;
        let x = availGeo.x, y = availGeo.y, w = availGeo.width, h = availGeo.height;
        if (fLeft && !fRight) { w = halfW; }
        else if (fRight && !fLeft) { x = availGeo.x + halfW; w = halfW; }
        if (fTop && !fBottom) { h = halfH; }
        else if (fBottom && !fTop) { y = availGeo.y + halfH; h = halfH; }
        const fractionRect = Qt.rect(x, y, w, h);
        // Other windows present: fill the reachable free pixels around the drop (expandRectFor
        // grows the window's slot into real empty space). Null only if it's already boxed in
        // on every side - then there's nothing to snap to, so no-op.
        if (root.occupiedRects(win).length > 0) {
            const grown = root.expandRectFor(win, screen);
            if (!grown) return null;
            // A corner drop is the edge drop capped to that quadrant: same fill, same
            // stopping at whatever is in the way, half the size. Clipping the grown rect
            // (rather than returning the quarter outright) keeps obstacles authoritative -
            // a neighbour jutting into the quadrant still shortens the result.
            if (!atCorner) return grown;
            const clipped = root.rectIntersect(grown, fractionRect);
            // degenerate clip (the free region barely reaches into the quadrant) - the
            // gesture would commit something unusably small, so leave the window alone.
            return (clipped.width >= 50 && clipped.height >= 50) ? clipped : null;
        }
        return fractionRect;
    }

    // Drop-onto-window target for a native drag of `win`: the topmost other real window
    // under the cursor, and what the drop would do to it. Returns null when there's nothing
    // to drop onto, else {target, zone, slot, rest} - slot is where `win` lands, rest is
    // what the target keeps, both pre-gap-inset like everything commit() takes.
    //
    // The split works on the target's rect grown back out by windowGap/2 (clipped to the
    // work area), i.e. the tile it was placed into, so both halves come out with the same
    // gap spacing as a grid placement.
    function windowDropTarget(win) {
        if (!win || !root.isRealWindow(win)) return null;
        const p = Workspace.cursorPos;
        const wins = Workspace.stackingOrder;
        let target = null, tg = null;
        // stackingOrder is bottom-to-top, so walk it backwards for the topmost hit
        for (let i = wins.length - 1; i >= 0; i--) {
            const ow = wins[i];
            try {
                if (ow === win || !root.isRealWindow(ow) || ow.fullScreen) continue;
                if (!ow.onAllDesktops && ow.desktops.indexOf(Workspace.currentDesktop) < 0) continue;
                const g = ow.frameGeometry;
                if (p.x >= g.x && p.x < g.x + g.width && p.y >= g.y && p.y < g.y + g.height) {
                    target = ow;
                    tg = Qt.rect(g.x, g.y, g.width, g.height);
                    break;
                }
            } catch (e) {
                continue;
            }
        }
        if (!target) return null;
        const screen = root.screenAt(p);
        if (!screen) return null;
        root.rehomeForScreen(screen);
        const half = root.windowGap / 2;
        const outer = root.rectIntersect(
            Qt.rect(tg.x - half, tg.y - half, tg.width + root.windowGap, tg.height + root.windowGap),
            root.availGeo);
        if (outer.width < 100 || outer.height < 100) return null;
        const fx = (p.x - tg.x) / tg.width, fy = (p.y - tg.y) / tg.height;
        const dists = [["left", fx], ["right", 1 - fx], ["top", fy], ["bottom", 1 - fy]];
        let zone = "center", best = root.windowDropBand;
        for (let i = 0; i < dists.length; i++) {
            if (dists[i][1] < best) { best = dists[i][1]; zone = dists[i][0]; }
        }
        if (zone === "center") {
            const o = root.dragOriginGeo;
            if (o.width < 50 || o.height < 50) return null;
            return { target: target, zone: zone, slot: outer,
                     rest: Qt.rect(o.x - half, o.y - half, o.width + root.windowGap,
                                   o.height + root.windowGap) };
        }
        const hw = Math.round(outer.width / 2), hh = Math.round(outer.height / 2);
        let slot, rest;
        if (zone === "left") {
            slot = Qt.rect(outer.x, outer.y, hw, outer.height);
            rest = Qt.rect(outer.x + hw, outer.y, outer.width - hw, outer.height);
        } else if (zone === "right") {
            rest = Qt.rect(outer.x, outer.y, hw, outer.height);
            slot = Qt.rect(outer.x + hw, outer.y, outer.width - hw, outer.height);
        } else if (zone === "top") {
            slot = Qt.rect(outer.x, outer.y, outer.width, hh);
            rest = Qt.rect(outer.x, outer.y + hh, outer.width, outer.height - hh);
        } else {
            rest = Qt.rect(outer.x, outer.y, outer.width, hh);
            slot = Qt.rect(outer.x, outer.y + hh, outer.width, outer.height - hh);
        }
        return { target: target, zone: zone, slot: slot, rest: rest };
    }

    // gap-inset final geometry for a pre-inset rect, same math as commit()
    function gapInset(r) {
        const inset = root.windowGap / 2;
        return Qt.rect(Math.round(r.x + inset), Math.round(r.y + inset),
                       Math.round(Math.max(50, r.width - root.windowGap)),
                       Math.round(Math.max(50, r.height - root.windowGap)));
    }

    // Apply a windowDropTarget() result. Deliberately not routed through commit(): the drop
    // already decides both windows' geometry, so the overlap-resize/relocate passes there
    // would only second-guess it.
    function commitWindowDrop(win, drop) {
        try {
            root.rememberSize(win, win.frameGeometry);
            root.rememberSize(drop.target, drop.target.frameGeometry);
            drop.target.setMaximize(false, false);
            drop.target.frameGeometry = root.gapInset(drop.rest);
            win.setMaximize(false, false);
            win.frameGeometry = root.gapInset(drop.slot);
            Workspace.activeWindow = win;
        } catch (e) {
            // either window can die between the release and these writes
            console.warn("vibetiles: window drop failed:", e);
        }
    }

    function finishDrag() {
        root.dragging = false;
        const r = root.snappedRect();
        if (r.width < 10 || r.height < 10) {
            hide();
            return;
        }
        // A grid placement commits exactly the selected rect - no edge-snap, no expand.
        // autoExpandOnEdgeDrag's fill is deliberately confined to a native mouse edge-drop
        // (onNativeDrag*): letting a normal grid drop that happens to land against a screen
        // edge auto-expand made windows balloon to fill the whole free area instead of the
        // size the user actually selected. Meta+Alt+E is still available for an explicit fill.
        const placed = root.targetWindow;
        let x = availGeo.x + r.x * root.scaleX;
        let y = availGeo.y + r.y * root.scaleY;
        let w = r.width * root.scaleX;
        let h = r.height * root.scaleY;

        // Opt-in only, and capped (see computeGapClosedRect) - this closes small leftover gaps
        // to an off-grid neighbour, it does not reintroduce the "commits exactly the selected
        // rect" guarantee above for the general case. Folded into this same commit() (rather
        // than a separate one after) so a placement that closes a gap is one resize, not two -
        // confirmed live the two-commit version was reliable but visibly did the resize twice.
        if (root.snapGaps && placed) {
            const inset = root.windowGap / 2;
            const candidateFg = Qt.rect(
                Math.round(x + inset), Math.round(y + inset),
                Math.round(Math.max(50, w - root.windowGap)), Math.round(Math.max(50, h - root.windowGap))
            );
            const center = Qt.point(candidateFg.x + candidateFg.width / 2, candidateFg.y + candidateFg.height / 2);
            const screen = root.screenAt(center);
            root.rehomeForScreen(screen);
            const grownSlot = root.computeGapClosedRect(placed, screen, candidateFg);
            if (grownSlot) {
                x = grownSlot.x; y = grownSlot.y; w = grownSlot.width; h = grownSlot.height;
            }
        }
        commit(x, y, w, h);
    }

    Components.Shortcuts {
        onShowOverlay: root.toggle()
        onExpandToGap: root.expandToGap(Workspace.activeWindow)
    }

    Item {
        id: mainItem
        width: root.width
        height: root.height

        // Complementary is the color set Plasma itself uses for OSD-style overlays that
        // sit on top of arbitrary desktop content (e.g. the volume/brightness OSD) -
        // dark and high-contrast by design, and it tracks the active Plasma color scheme
        // (Breeze Dark/Light, custom schemes, etc) automatically. inherit: false so it
        // doesn't pick up whatever color set the KWin script host's implicit parent uses.
        Kirigami.Theme.colorSet: Kirigami.Theme.Complementary
        Kirigami.Theme.inherit: false

        // the grid-line and cell-highlight Repeater delegates all resolve to the same two
        // translucent theme tints; compute each once here (in mainItem's Complementary
        // scope) rather than reconstructing an identical Qt.rgba per delegate every time
        // Alt-doubling or a grid-size change rebuilds the delegate set. Constant during a
        // drag, so these don't recompute per frame - this just removes the per-delegate dup.
        property color gridLineColor: root.themeAlpha(Kirigami.Theme.textColor, 0.2)
        property color cellHighlightColor: root.themeAlpha(Kirigami.Theme.highlightColor, 0.27)

    // mouse-only activation via KWin screen edges - same "push cursor into corner"
    // mechanism as the daemon's injected registerScreenEdge() watcher script, just
    // registered directly here instead of over D-Bus. Only one of these four is ever
    // enabled at once, driven by the hotCorner config value (see loadConfig()).
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.TopLeftEdge
        enabled: root.hotCorner === "topLeft"
        onActivated: root.toggle()
    }
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.TopRightEdge
        enabled: root.hotCorner === "topRight"
        onActivated: root.toggle()
    }
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.BottomLeftEdge
        enabled: root.hotCorner === "bottomLeft"
        onActivated: root.toggle()
    }
    ScreenEdgeHandler {
        edge: ScreenEdgeHandler.BottomRightEdge
        enabled: root.hotCorner === "bottomRight"
        onActivated: root.toggle()
    }

    Connections {
        target: Workspace
        function onWindowAdded(win) {
            root.hookWindow(win);
            refreshTimer.restart();
        }
        function onWindowRemoved(window) {
            refreshTimer.restart();
        }
    }

    // debounced refresh of the compact-mode window picker so newly opened/closed
    // windows show up while the overlay is up. 200ms collapses a burst of adds/removes
    // (workspace switch, app launch) into a single refreshWindowList() call.
    Timer {
        id: refreshTimer
        interval: 200
        repeat: false
        onTriggered: if (root.visible && root.isCompact) root.refreshWindowList()
    }

    // background: click here (outside the canvas, only relevant in compact mode) cancels
    MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
    }

    // Compact mode only: a 1:1 ghost of the final window rectangle, drawn on the real
    // screen behind the little grid box. The compact grid is a miniature of the whole
    // output, so a selection there gives no sense of the actual size the window will end
    // up - this is the "you are here" for that. Deliberately drawn from snappedRect()
    // 1:1 outline of the final window position. Applies the same edge-snap math
    // finishDrag uses, so when you drag near a screen edge the outline jumps to the
    // post-snap position before release - visual confirmation that snap is armed.
    // Default-on in both compact and fullscreen modes.
    //
    // Coord-system notes: snappedRect() returns a rect in "canvas-local within work
    // area" units (where 0 is the work area's left edge). Multiplying by scaleX and
    // adding availGeo.x gives SCREEN coords, which is what commit() uses. The ghost
    // Rectangle itself lives inside mainItem, whose local origin sits at the dialog's
    // top-left (i.e., screen origin minus screenGeo.{x,y}). So we snap in screen coords
    // and convert to mainItem-local by subtracting screenGeo.x (= availGeo.x - availLocalX).
    // With windowGap/2 baked in so commit()'s inset geometry matches the outline exactly.
    // Drop-onto-window: where the window under the cursor ends up (windowDrop.rest), drawn
    // next to the main ghost, which shows the dragged window's slot. Fainter than the ghost
    // so it's clear which one is the window being dropped. Same screen-to-mainItem
    // conversion and gap inset as the ghost's edge-drop branch.
    Rectangle {
        id: targetGhost
        readonly property var drop: root.windowDrop
        // hold the last rect and only animate once shown, same as the ghost's held/settled -
        // otherwise it slides in from (0,0) when it first appears
        property rect held: Qt.rect(0, 0, 0, 0)
        property bool settled: false
        onDropChanged: {
            if (drop) held = drop.rest;
            if (!drop) settled = false;
            else if (!settled) Qt.callLater(() => targetGhost.settled = targetGhost.drop !== null);
        }
        visible: drop !== null
        x: held.x - root.availGeo.x + root.availLocalX + root.windowGap / 2
        y: held.y - root.availGeo.y + root.availLocalY + root.windowGap / 2
        width: Math.max(0, held.width - root.windowGap)
        height: Math.max(0, held.height - root.windowGap)
        color: root.themeAlpha(Kirigami.Theme.backgroundColor, 0.35)
        border.color: root.themeAlpha(Kirigami.Theme.textColor, 0.5)
        border.width: 2
        radius: 4
        Behavior on x { enabled: targetGhost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: targetGhost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on width { enabled: targetGhost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on height { enabled: targetGhost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    }

    Rectangle {
        id: ghost
        property rect g: {
            // Native edge-drop preview: edgePreviewRect is already the final screen-coords
            // target (post-snap/expand or the empty-screen half). Convert to mainItem-local
            // (subtract screenGeo origin, == availGeo.x - availLocalX) and inset windowGap/2
            // so the outline lands exactly where commit() will put the window.
            if (root.edgePreview || root.windowDrop) {
                const er = root.edgePreviewRect;
                if (er.width < 10 || er.height < 10) return Qt.rect(0, 0, 0, 0);
                return Qt.rect(
                    er.x - root.availGeo.x + root.availLocalX + root.windowGap / 2,
                    er.y - root.availGeo.y + root.availLocalY + root.windowGap / 2,
                    Math.max(0, er.width - root.windowGap),
                    Math.max(0, er.height - root.windowGap));
            }
            if (!root.dragging) return Qt.rect(0, 0, 0, 0);
            const r = root.snappedRect();
            if (r.width < 10 || r.height < 10) return Qt.rect(0, 0, 0, 0);
            const screenX = root.availGeo.x + r.x * root.scaleX;
            const screenY = root.availGeo.y + r.y * root.scaleY;
            const screenW = r.width * root.scaleX;
            const screenH = r.height * root.scaleY;
            return Qt.rect(
                screenX - root.availGeo.x + root.availLocalX + root.windowGap / 2,
                screenY - root.availGeo.y + root.availLocalY + root.windowGap / 2,
                Math.max(0, screenW - root.windowGap),
                Math.max(0, screenH - root.windowGap));
        }
        readonly property bool shown: (root.ghostPreview || root.windowDrop !== null)
            && (root.dragging || root.edgePreview || root.windowDrop !== null)
            && g.width > 0 && g.height > 0
        // Last valid target geometry. x/y/width/height bind to this, not to g directly: when
        // the preview is dismissed g collapses to (0,0,0,0), and binding the geometry straight
        // to g animated the outline toward the top-left corner. Holding the last valid rect
        // keeps it put. Only ever capture a real target (g.width/height > 10).
        property rect held: Qt.rect(0, 0, 0, 0)
        onGChanged: if (g.width > 10 && g.height > 10) held = g;
        // settled gates the positional Behaviors so the FIRST placement is instant - without
        // it the outline slid in from wherever held last sat, reading as a directional spawn.
        // It becomes true one tick after the ghost appears, so target-to-target changes while
        // already shown (moving between edges) still animate.
        property bool settled: false
        onShownChanged: {
            if (shown) { held = g; Qt.callLater(() => ghost.settled = true); }
            else settled = false;
        }
        visible: shown
        x: held.x
        y: held.y
        width: held.width
        height: held.height
        // Purely a fade - no scale, no positional slide on appear/disappear. Any scale/slide
        // read as the outline flying in or out from a direction, which is exactly what was
        // unwanted; a plain opacity fade has no directional character at all.
        opacity: shown ? 1 : 0
        color: root.themeAlpha(Kirigami.Theme.highlightColor, 0.18)
        border.color: root.themeAlpha(Kirigami.Theme.highlightColor, 0.9)
        border.width: 2
        radius: 4
        // Drop shadow so the preview reads as a floating pane over the desktop, same
        // treatment the compact chrome gets. Especially wanted on the native edge-drop
        // path, where the ghost is the only chrome on screen.
        layer.enabled: visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.6
            shadowVerticalOffset: 3
        }
        Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        // Smoothly follow the target when it moves while already shown (snap firing, moving
        // from one edge to another) - gated on `settled` so the first placement doesn't slide.
        Behavior on x { enabled: ghost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: ghost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on width { enabled: ghost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        Behavior on height { enabled: ghost.settled; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
    }

    Rectangle {
        id: canvas
        // hidden in native edge-drop preview: that mode shows only the ghost outline, no
        // grid box (there's no cell selection to make - the target is derived from the
        // cursor's edge, and the overlay never receives pointer events during a native drag).
        visible: !root.edgePreview && !root.windowDrop
        x: root.canvasX
        y: root.canvasY
        width: root.canvasWidth
        height: root.canvasHeight
        color: root.themeAlpha(Kirigami.Theme.backgroundColor, root.isCompact ? 0.8 : 0.13)
        border.color: root.isCompact ? root.themeAlpha(Kirigami.Theme.textColor, 0.33) : "transparent"
        border.width: root.isCompact ? 1 : 0
        radius: root.isCompact ? 6 : 0

        // fullscreen mode fills the entire dialog/screen, so a shadow would have no
        // visible edge to fall against - only worth the layer cost in compact mode,
        // where canvas is a small floating box.
        layer.enabled: root.isCompact
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.6
            shadowVerticalOffset: 3
        }

        Repeater {
            model: root.effCols - 1
            Rectangle {
                x: (index + 1) * (canvas.width / root.effCols)
                y: 0
                width: 1
                height: canvas.height
                color: mainItem.gridLineColor
            }
        }
        Repeater {
            model: root.effRows - 1
            Rectangle {
                x: 0
                y: (index + 1) * (canvas.height / root.effRows)
                width: canvas.width
                height: 1
                color: mainItem.gridLineColor
            }
        }

        // highlights each individual grid cell the current selection covers, distinct
        // from the freeform preview rectangle below
        Repeater {
            model: root.selBounds ? root.effCols * root.effRows : 0
            Rectangle {
                property int col: index % root.effCols
                property int row: Math.floor(index / root.effCols)
                property bool inSel: !!root.selBounds
                    && col >= root.selBounds.c1 && col < root.selBounds.c2
                    && row >= root.selBounds.r1 && row < root.selBounds.r2
                x: col * (canvas.width / root.effCols)
                y: row * (canvas.height / root.effRows)
                width: canvas.width / root.effCols
                height: canvas.height / root.effRows
                color: mainItem.cellHighlightColor
                opacity: inSel ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 70; easing.type: Easing.OutCubic } }
            }
        }

        Rectangle {
            visible: root.dragging
            color: root.themeAlpha(Kirigami.Theme.highlightColor, 0.33)
            border.color: Kirigami.Theme.highlightedTextColor
            border.width: 2
            property real gapX: root.windowGap / root.scaleX
            property real gapY: root.windowGap / root.scaleY
            property rect r: root.rawRect()
            x: r.x + gapX / 2
            y: r.y + gapY / 2
            width: Math.max(0, r.width - gapX)
            height: Math.max(0, r.height - gapY)
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // modifier state is read straight off the mouse event's flags instead of a
            // Keys.onPressed handler - these script-owned windows don't reliably receive
            // real keyboard focus (confirmed live: forceActiveFocus() didn't fix it), but
            // pointer events always carry accurate modifier flags regardless of focus
            onPositionChanged: (mouse) => {
                root.fineHeld = (mouse.modifiers & Qt.AltModifier) !== 0;
                if (root.dragging) root.dragCurrent = Qt.point(mouse.x, mouse.y);
            }
            onPressed: (mouse) => {
                // Escape doesn't reach these script-owned windows (no reliable keyboard
                // focus - see requestActivate note in show()), so right-click cancels
                // instead, same intent as the daemon's Keys.onEscapePressed.
                if (mouse.button === Qt.RightButton) {
                    root.dragging = false;
                    root.hide();
                    return;
                }
                root.fineHeld = (mouse.modifiers & Qt.AltModifier) !== 0;
                root.pickerOpen = false;
                root.dragStart = Qt.point(mouse.x, mouse.y);
                root.dragCurrent = root.dragStart;
                root.dragging = true;
            }
            onReleased: (mouse) => {
                if (!root.dragging) return;
                root.dragCurrent = Qt.point(mouse.x, mouse.y);
                root.finishDrag();
            }
        }
    }

    // compact mode only: floating bar above the grid showing which window is about to be
    // resized. Click to expand a picker and retarget it.
    Rectangle {
        id: titleBar
        visible: root.isCompact && root.targetTitle.length > 0
        width: Math.min(canvas.width, titleRow.implicitWidth + 24)
        height: 32
        x: canvas.x + (canvas.width - width) / 2
        y: (canvas.y - height - 8 >= root.availLocalY)
            ? canvas.y - height - 8
            : canvas.y + canvas.height + 8
        z: 30
        color: root.themeAlpha(Kirigami.Theme.backgroundColor, 0.87)
        radius: 6
        border.color: root.themeAlpha(Kirigami.Theme.textColor, 0.33)
        border.width: 1

        // Same materialize-in treatment as canvas, offset slightly later so the bar reads
        // as following the grid in rather than popping simultaneously.
        layer.enabled: visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.5
            shadowVerticalOffset: 2
        }

        Row {
            id: titleRow
            anchors.centerIn: parent
            spacing: 8
            Kirigami.Icon {
                source: root.targetIconName || "preferences-system-windows"
                width: 18
                height: 18
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.targetTitle
                color: Kirigami.Theme.textColor
                font.pixelSize: 13
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 240)
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.pickerOpen ? "▴" : "▾"
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.pickerOpen = !root.pickerOpen
        }
    }

    // expands below the title bar - lets the user pick a different window, on any
    // monitor, than the one that was active when the overlay was triggered
    Rectangle {
        id: pickerPanel
        visible: root.isCompact && root.pickerOpen && root.windowList.length > 0
        x: titleBar.x
        y: titleBar.y + titleBar.height + 4
        width: titleBar.width
        height: Math.min(pickerColumn.implicitHeight + 12, 220)
        z: 31
        color: root.themeAlpha(Kirigami.Theme.backgroundColor, 0.87)
        radius: 6
        border.color: root.themeAlpha(Kirigami.Theme.textColor, 0.33)
        border.width: 1
        clip: true

        layer.enabled: visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.6)
            shadowBlur: 0.5
            shadowVerticalOffset: 2
        }

        Flickable {
            anchors.fill: parent
            anchors.margins: 6
            contentWidth: width
            contentHeight: pickerColumn.implicitHeight
            clip: true

            Column {
                id: pickerColumn
                width: parent.width
                spacing: 2

                Repeater {
                    model: root.windowList
                    delegate: Column {
                        width: pickerColumn.width
                        spacing: 2
                        property bool isNewGroup: index === 0 || root.windowList[index - 1].screen !== modelData.screen

                        Rectangle {
                            visible: parent.isNewGroup && index !== 0
                            width: parent.width
                            height: 1
                            color: root.themeAlpha(Kirigami.Theme.textColor, 0.2)
                        }
                        Text {
                            visible: parent.isNewGroup
                            text: modelData.screen === (root.targetScreenObj ? root.targetScreenObj.name : "") ? "This Display" : modelData.screen
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: 10
                            font.bold: true
                            topPadding: index === 0 ? 0 : 4
                            bottomPadding: 2
                        }

                        Rectangle {
                            width: parent.width
                            height: 28
                            radius: 4
                            color: entryMouse.containsMouse ? root.themeAlpha(Kirigami.Theme.highlightColor, 0.2) : "transparent"
                            Behavior on color { ColorAnimation { duration: 90 } }

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                spacing: 8
                                Kirigami.Icon {
                                    source: modelData.icon || "preferences-system-windows"
                                    width: 16
                                    height: 16
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: modelData.title
                                    color: Kirigami.Theme.textColor
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                    width: pickerColumn.width - 40
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: entryMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.selectWindow(modelData)
                            }
                        }
                    }
                }
            }
        }
    }

    // No Item-level Keys handlers here: confirmed live, script-owned windows don't
    // reliably receive real keyboard focus even with forceActiveFocus(), so Keys.*
    // doesn't fire. Cancel is right-click on the canvas MouseArea; Alt (fine grid) is read off
    // mouse-event modifiers (and off Qt.application.queryKeyboardModifiers() in the
    // native-drag paths where the canvas MouseArea gets no events at all - see
    // onNativeDragStepped).
    } // mainItem
}
