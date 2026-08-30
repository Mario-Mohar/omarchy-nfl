import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "themo.nfl"
  // The IPC handler lives on a `.control` sub-target rather than the bare
  // plugin id. On the bare id the registration only survives while the shell
  // hot-reloaded the plugin; after `omarchy restart shell` every call comes
  // back as "Target not found". manageIpc is off because the handler below
  // registers this target itself.
  ipcTarget: "themo.nfl.control"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget in its slot (BarWidget.qml), not this nested
  // panel, so popout coordination has to be done against that identity.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh(false)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh(false)
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.pickingTeam) root.cancelPickingTeam()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Settings ----------------------------------------------------------

  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 15), 10) || 15)
  readonly property string barFormat: String(setting("barFormat", "icon"))
  readonly property string icon: String(setting("icon", ""))
  readonly property int upcomingCount: Math.max(0, parseInt(setting("upcomingCount", 6), 10) || 0)
  readonly property int resultsCount: Math.max(0, parseInt(setting("resultsCount", 8), 10) || 0)
  readonly property color winColor: setting("winColor", "#6f9e5f")
  readonly property color lossColor: Color.urgent

  // Off by default, all three: a football score is not worth waking someone at
  // three in the morning who installed this for the quiet glyph.
  readonly property bool notifyKickoff: setting("notifyKickoff", false)
  readonly property bool notifyFinal: setting("notifyFinal", false)
  readonly property bool notifyLead: setting("notifyLead", false)

  // ---- Team --------------------------------------------------------------

  // Picked in the panel and stored outside shell.json (bin/nfl-team owns the
  // file); the `team` setting is the seed for anyone who never opens the
  // picker. Watching the file keeps every bar instance in step.
  property string storedTeam: ""
  readonly property string team: Model.resolveTeam(storedTeam, setting("team", "sf"))

  property FileView teamFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/nfl-team.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.storedTeam = Model.parseStoredTeam(text())
    onLoadFailed: root.storedTeam = ""
  }

  // Drop data belonging to the previous team right away, so the header never
  // shows one team's name above another team's schedule.
  onTeamChanged: {
    if (report && String(report.team.abbr).toLowerCase() !== String(team).toLowerCase())
      report = null
    Qt.callLater(function() { root.refresh(false) })
  }

  // ---- State -------------------------------------------------------------

  // Kept across failed refreshes so a dropped network leaves the last good
  // schedule on screen instead of an empty panel.
  property var report: null
  property var teams: []
  property bool loading: false
  property bool everLoaded: false
  property string standingsScope: String(setting("standingsScope", "division"))
  property double now: 0

  readonly property string label: Model.barLabel(report, barFormat, icon)
  readonly property string tooltip: Model.tooltipText(report)

  readonly property var live: report ? Model.liveGame(report) : null
  readonly property var nextGame: report ? Model.nextGame(report) : null
  readonly property var lastGame: report ? Model.lastGame(report) : null
  readonly property var upcomingGames: report ? Model.limited(Model.upcoming(report), upcomingCount) : []
  readonly property var resultGames: report ? Model.limited(Model.reversed(Model.played(report)), resultsCount) : []
  readonly property var standingsRows: report ? Model.standingsRows(report, standingsScope) : []
  readonly property var byes: report ? Model.byeWeeks(report) : []

  readonly property string recordLabel: report ? (Model.regularRecordLabel(report) || Model.recordLabel(report)) : ""
  readonly property string seasonLabel: report ? (String(report.season) + " " + String(report.seasonTypeName || "")) : ""
  readonly property string teamName: report ? String(report.team.name)
    : Model.teamDisplayName(teams, team, team.toUpperCase())

  // bin/ ships next to this file; resolving keeps the plugin relocatable.
  readonly property string scriptPath: Qt.resolvedUrl("bin/nfl-data").toString().replace(/^file:\/\//, "")
  readonly property string teamScriptPath: Qt.resolvedUrl("bin/nfl-team").toString().replace(/^file:\/\//, "")
  readonly property string notifyScriptPath: Qt.resolvedUrl("bin/nfl-notify").toString().replace(/^file:\/\//, "")

  // A refresh asked for while one is in flight is queued, never dropped: at
  // startup the stored team lands after the first fetch has already begun, so
  // dropping that second request would leave the panel on the wrong team
  // until the next timer tick.
  property bool refreshQueued: false
  property bool refreshQueuedForce: false

  function refresh(force) {
    if (dataProc.running) {
      refreshQueued = true
      if (force === true) refreshQueuedForce = true
      return
    }
    loading = true
    dataProc.command = [scriptPath, "--team", team,
      "--max-age", force === true ? "0" : String(refreshMinutes * 60)]
    dataProc.running = true
  }

  function drainQueuedRefresh() {
    if (!refreshQueued) return
    refreshQueued = false
    var force = refreshQueuedForce
    refreshQueuedForce = false
    Qt.callLater(function() { root.refresh(force) })
  }

  function forceRefresh() {
    dataProc.running = false
    refresh(true)
  }

  // Hung off the poll rather than off anything on screen. A bar widget gets
  // collapsed when the bar runs out of room and the popup is shut most of the
  // time, so neither can be what decides whether a kickoff is noticed; the
  // Loader in BarWidget.qml stays active either way, and so does this timer.
  //
  // Every poll reports the upcoming game and the last finished one, in whatever
  // state they are in. Deciding which of those states is *new* is nfl-notify's
  // job, because that answer has to outlive the shell process.
  function announce(data) {
    if (!notifyKickoff && !notifyFinal && !notifyLead) return
    var entries = Model.notifyEntries(data)
    if (!entries.length) return
    var want = []
    if (notifyKickoff) want.push("kickoff")
    if (notifyFinal) want.push("final")
    if (notifyLead) want.push("lead")
    Quickshell.execDetached([notifyScriptPath,
      JSON.stringify({ want: want, games: entries })])
  }

  function setScope(scope) {
    standingsScope = scope
  }

  // ---- Team picker -------------------------------------------------------

  property bool pickingTeam: false
  property int teamIndex: 0
  readonly property var filteredTeams: Model.filterTeams(teams, teamField.text)

  function loadTeams() {
    if (teams.length > 0 || teamsProc.running) return
    teamsProc.command = [scriptPath, "--teams"]
    teamsProc.running = true
  }

  function startPickingTeam() {
    loadTeams()
    pickingTeam = true
    teamIndex = 0
    Qt.callLater(function() {
      teamField.text = ""
      teamField.forceActiveFocus()
    })
  }

  function cancelPickingTeam() {
    pickingTeam = false
    teamIndex = 0
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitTeam() {
    var list = root.filteredTeams
    if (!list.length) return
    selectTeam(list[Math.max(0, Math.min(teamIndex, list.length - 1))].abbr)
  }

  function selectTeam(abbr) {
    var picked = String(abbr || "").toUpperCase()
    if (picked === "") return
    // Set locally first so the panel switches immediately; the file write is
    // what makes it stick across restarts and other bar instances.
    root.report = null
    root.storedTeam = picked
    teamSaveProc.command = [teamScriptPath, "--set", picked]
    teamSaveProc.running = true
    cancelPickingTeam()
  }

  function moveTeamIndex(delta) {
    var count = root.filteredTeams.length
    if (count === 0) return
    teamIndex = Math.max(0, Math.min(teamIndex + delta, count - 1))
  }

  function isTeamRow(row) {
    return report && row && String(row.abbr) === String(report.team.abbr)
  }

  function resultColor(game) {
    if (!game || !game.result) return root.bar ? root.bar.foreground : Color.foreground
    if (game.result === "W") return winColor
    if (game.result === "L") return lossColor
    return Color.muted
  }

  Process {
    id: dataProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var parsed = Model.parsePayload(text)
        if (parsed) {
          root.report = parsed
          root.everLoaded = true
          root.announce(parsed)
        }
      }
    }
    onRunningChanged: {
      if (running) return
      root.loading = false
      root.drainQueuedRefresh()
    }
  }

  Process {
    id: teamsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = Model.parseTeams(text)
        if (list.length) root.teams = list
      }
    }
  }

  Process {
    id: teamSaveProc
  }

  // A live game moves fast; everything else can wait out the full interval.
  Timer {
    id: refreshTimer
    interval: (root.live ? 1 : root.refreshMinutes) * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(root.live ? true : false)
  }

  // Drives the countdown without re-fetching anything.
  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.forceRefresh() }
    function pickTeam(): void { root.openFromHotkey(); root.startPickingTeam() }
    function setTeam(abbr: string): void { root.selectTeam(abbr) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(nflColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.pickingTeam
      onReturnRequested: root.forceRefresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: nflScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: nflColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: nflColumn
          width: nflScroll.width
          spacing: Style.space(10)

          // ---- Header: team, record, season -------------------------------
          Item {
            width: parent.width
            height: Math.max(headerRow.implicitHeight, headerRecord.implicitHeight)

            Row {
              id: headerRow
              anchors.left: parent.left
              anchors.right: headerRecord.left
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.icon
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.display
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                width: parent.width - Style.space(46)

                // Clicking the team name swaps it for the picker, the way the
                // weather panel turns its location label into a search field.
                // The search field is taller than the label it replaces, so
                // the row has to follow whichever one is showing — otherwise
                // the field overlaps the hint line beneath it.
                Item {
                  width: parent.width
                  height: root.pickingTeam ? teamField.implicitHeight : teamNameText.implicitHeight

                  Text {
                    textFormat: Text.PlainText
                    id: teamNameText
                    visible: !root.pickingTeam
                    width: parent.width
                    text: root.teamName
                    color: teamNameArea.containsMouse
                      ? Color.accent
                      : (root.bar ? root.bar.foreground : Color.foreground)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    id: teamNameArea
                    anchors.fill: parent
                    visible: !root.pickingTeam
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startPickingTeam()
                  }

                  TextField {
                    id: teamField
                    visible: root.pickingTeam
                    width: parent.width
                    placeholderText: Model.t("searchTeam")
                    foreground: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family

                    onTextChanged: root.teamIndex = 0

                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) {
                        root.cancelPickingTeam()
                        event.accepted = true
                      } else if (event.key === Qt.Key_Down) {
                        root.moveTeamIndex(1)
                        event.accepted = true
                      } else if (event.key === Qt.Key_Up) {
                        root.moveTeamIndex(-1)
                        event.accepted = true
                      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.commitTeam()
                        event.accepted = true
                      }
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.pickingTeam
                    ? Model.t("pickerHint")
                    : (root.seasonLabel + (root.byes.length
                        ? "  ·  " + Model.t("byePrefix") + root.byes.join(", ")
                        : ""))
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            Column {
              id: headerRecord
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: root.recordLabel || "—"
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: Model.t("record")
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

          // ---- Team picker list --------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(1)
            visible: root.pickingTeam

            Repeater {
              model: root.pickingTeam ? root.filteredTeams : []

              Rectangle {
                id: teamRow
                required property var modelData
                required property int index
                readonly property bool current: root.teamIndex === teamRow.index
                width: nflColumn.width
                height: Style.space(22)
                radius: Style.space(4)
                color: teamRow.current ? Style.selectedFill : "transparent"

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(46)
                  text: String(teamRow.modelData.abbr)
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(58)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(teamRow.modelData.name)
                  color: teamRow.current
                    ? (root.bar ? root.bar.foreground : Color.foreground)
                    : Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.teamIndex = teamRow.index
                  onClicked: root.selectTeam(teamRow.modelData.abbr)
                }
              }
            }
          }

          // ---- Hero: next game (or the live one) --------------------------
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: !root.pickingTeam && !!root.nextGame

            Text {
              textFormat: Text.PlainText
              text: root.live ? Model.t("live") : Model.t("nextGame")
              color: root.live ? root.lossColor : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.nextGame ? Model.opponentLongLabel(root.nextGame) : ""
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.nextGame) return ""
                if (root.live) {
                  return Model.scoreLine(root.nextGame) + "  ·  Q" + root.nextGame.period
                    + " " + root.nextGame.displayClock
                }
                var parts = [Model.weekLabel(root.nextGame),
                             Model.formatKickoff(root.nextGame.date)]
                var left = Model.countdown(root.nextGame.date, root.now)
                if (left !== "") parts.push(left)
                return parts.join("  ·  ")
              }
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.nextGame) return ""
                var venue = String(root.nextGame.venue || "")
                var city = String(root.nextGame.venueCity || "")
                var place = city !== "" ? (venue + ", " + city) : venue
                return root.nextGame.neutralSite
                  ? (place + "  ·  " + Model.t("neutral"))
                  : place
              }
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelSeparator {
            foreground: root.bar ? root.bar.foreground : Color.foreground
            visible: !root.pickingTeam && root.upcomingGames.length > 0
          }

          // ---- Upcoming ----------------------------------------------------
          PanelSectionHeader {
            text: Model.t("upcoming")
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            visible: !root.pickingTeam && root.upcomingGames.length > 0
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: !root.pickingTeam && root.upcomingGames.length > 0

            Repeater {
              model: root.pickingTeam ? [] : root.upcomingGames

              Item {
                id: upcomingRow
                required property var modelData
                width: nflColumn.width
                height: Style.space(20)

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(74)
                  text: Model.weekLabel(upcomingRow.modelData)
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(78)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(96)
                  text: Model.opponentLabel(upcomingRow.modelData)
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                // Late-season kickoffs are flexed, so ESPN reports them as TBD
                // until the slot is fixed; showing a fake time would lie.
                Text {
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(upcomingRow.modelData.shortDetail) === "TBD"
                    ? (Model.formatDay(upcomingRow.modelData.date) + "  TBD")
                    : (Model.formatDay(upcomingRow.modelData.date) + "  "
                       + Model.formatTime(upcomingRow.modelData.date))
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.bar ? root.bar.foreground : Color.foreground
            visible: !root.pickingTeam && root.resultGames.length > 0
          }

          // ---- Results -----------------------------------------------------
          PanelSectionHeader {
            text: Model.t("results")
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            visible: !root.pickingTeam && root.resultGames.length > 0
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: !root.pickingTeam && root.resultGames.length > 0

            Repeater {
              model: root.pickingTeam ? [] : root.resultGames

              Item {
                id: resultRow
                required property var modelData
                readonly property color badge: root.resultColor(resultRow.modelData)
                width: nflColumn.width
                height: Style.space(20)

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(74)
                  text: Model.weekLabel(resultRow.modelData)
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(78)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(96)
                  text: Model.opponentLabel(resultRow.modelData)
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(178)
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.formatDay(resultRow.modelData.date)
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.scoreLine(resultRow.modelData)
                    color: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(18)
                    height: Style.space(16)
                    radius: Style.space(3)
                    color: Qt.rgba(resultRow.badge.r, resultRow.badge.g, resultRow.badge.b, 0.18)

                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: String(resultRow.modelData.result || "-")
                      color: resultRow.badge
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.bar ? root.bar.foreground : Color.foreground
            visible: !root.pickingTeam && root.standingsRows.length > 0
          }

          // ---- Standings ----------------------------------------------------
          Item {
            width: parent.width
            height: standingsHeader.implicitHeight
            visible: !root.pickingTeam && root.standingsRows.length > 0

            PanelSectionHeader {
              id: standingsHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.report
                ? Model.standingsTitle(root.report, root.standingsScope).toUpperCase()
                : Model.t("standings")
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Repeater {
                model: [{ key: "division", label: "Division" }, { key: "conference", label: "Conference" }]

                Rectangle {
                  id: scopeTab
                  required property var modelData
                  readonly property bool active: root.standingsScope === scopeTab.modelData.key
                  width: scopeLabel.implicitWidth + Style.space(12)
                  height: Style.space(17)
                  radius: Style.space(4)
                  color: scopeTab.active ? Style.selectedFill : "transparent"
                  border.width: 1
                  border.color: scopeTab.active ? Style.selectedBorderColor : "transparent"

                  Text {
                    textFormat: Text.PlainText
                    id: scopeLabel
                    anchors.centerIn: parent
                    text: scopeTab.modelData.label
                    color: scopeTab.active
                      ? (root.bar ? root.bar.foreground : Color.foreground)
                      : Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setScope(scopeTab.modelData.key)
                  }
                }
              }
            }
          }

          // Column header for the standings table.
          Item {
            width: parent.width
            height: Style.space(16)
            visible: !root.pickingTeam && root.standingsRows.length > 0

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(26)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.t("team")
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                textFormat: Text.PlainText
                width: Style.space(58); horizontalAlignment: Text.AlignRight
                text: "W-L"; color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(50); horizontalAlignment: Text.AlignRight
                text: "PCT"; color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(46); horizontalAlignment: Text.AlignRight
                text: "DIFF"; color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                width: Style.space(40); horizontalAlignment: Text.AlignRight
                text: "STRK"; color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(1)
            visible: !root.pickingTeam && root.standingsRows.length > 0

            Repeater {
              model: root.pickingTeam ? [] : root.standingsRows

              Rectangle {
                id: standingRow
                required property var modelData
                readonly property bool mine: root.isTeamRow(standingRow.modelData)
                // Color.muted on the selected-row fill is all but unreadable;
                // the highlighted row carries its secondary columns at full
                // foreground instead.
                readonly property color primary: root.bar ? root.bar.foreground : Color.foreground
                readonly property color secondary: standingRow.mine ? standingRow.primary : Color.muted
                // Conference view carries its own 1..16 ranking; the division
                // view keeps the per-division rank.
                readonly property string position: String(
                  root.standingsScope === "conference" && standingRow.modelData.confRank !== undefined
                    ? standingRow.modelData.confRank : standingRow.modelData.rank)
                width: nflColumn.width
                height: Style.space(20)
                radius: Style.space(4)
                color: standingRow.mine ? Style.selectedFill : "transparent"

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(20)
                  text: standingRow.position
                  color: standingRow.secondary
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(26)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(standingRow.modelData.abbr)
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: standingRow.mine
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(64)
                  anchors.right: statsRow.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(standingRow.modelData.name)
                  color: standingRow.secondary
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Row {
                  id: statsRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    textFormat: Text.PlainText
                    width: Style.space(58); horizontalAlignment: Text.AlignRight
                    text: String(standingRow.modelData.record)
                    color: root.bar ? root.bar.foreground : Color.foreground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: standingRow.mine
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: Style.space(50); horizontalAlignment: Text.AlignRight
                    text: String(standingRow.modelData.pct)
                    color: standingRow.secondary
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: Style.space(46); horizontalAlignment: Text.AlignRight
                    text: String(standingRow.modelData.diff)
                    color: standingRow.secondary
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: Style.space(40); horizontalAlignment: Text.AlignRight
                    text: String(standingRow.modelData.streak)
                    color: standingRow.secondary
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          // ---- Footer -------------------------------------------------------
          Item {
            width: parent.width
            height: Style.space(18)

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.loading
                ? Model.t("loading")
                : (root.pickingTeam
                    ? Model.t("pickerHint")
                    : (root.everLoaded ? Model.t("refreshHint") : Model.t("noData")))
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.pickingTeam ? "" : Model.t("changeTeam")
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
