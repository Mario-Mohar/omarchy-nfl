// Pure helpers for the NFL panel. Everything here is side-effect free so the
// QML side stays declarative: bin/nfl-data hands us one JSON document and
// these functions slice it into the shapes the panel and bar widget render.
//
// Every user-visible string lives in STRINGS rather than inline in the QML,
// so the wording is reviewable in one place.

.pragma library

var STRINGS = {
  nextGame: "NEXT GAME",
  live: "LIVE NOW",
  upcoming: "UPCOMING GAMES",
  results: "RESULTS",
  standings: "STANDINGS",
  record: "Record",
  team: "Team",
  byePrefix: "Bye: Week ",
  week: "Week",
  pre: "Pre",
  playoffs: "Playoffs",
  neutral: "neutral site",
  loading: "loading …",
  refreshHint: "Enter = refresh",
  noData: "no data — press Enter to retry",
  searchTeam: "Search team",
  changeTeam: "Click to change team",
  pickerHint: "↑↓ select · Enter confirm · Esc cancel",
  next: "Next",
  last: "Last",
  noTeamData: "NFL — no data",
  minutes: "in %1 min",
  hours: "in %1 hrs",
  day: "in %1 day",
  days: "in %1 days",
  weeks: "in %1 weeks",
  days_short: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}

function t(key) {
  var value = STRINGS[key]
  return value === undefined ? "" : value
}

function fill(template, value) {
  return String(template).replace("%1", String(value))
}

function parsePayload(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object" || !data.games) return null
    return data
  } catch (e) {
    return null
  }
}

function parseTeams(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var list = data && data.teams
    return (list && list.length) ? list : []
  } catch (e) {
    return []
  }
}

// The picker's choice is stored outside shell.json, so it has to win over the
// widget setting — otherwise picking a team would silently do nothing for
// anyone who had set `team` by hand.
function resolveTeam(storedTeam, settingTeam) {
  var stored = String(storedTeam || "").trim()
  if (stored !== "") return stored.toLowerCase()
  var configured = String(settingTeam || "").trim()
  return configured !== "" ? configured.toLowerCase() : "sf"
}

function parseStoredTeam(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var team = String((data && data.team) || "").trim()
    return /^[A-Za-z]{2,4}$/.test(team) ? team.toUpperCase() : ""
  } catch (e) {
    return ""
  }
}

// Rank matches so typing "ka" surfaces Kansas City before Arizona: exact
// abbreviation, then abbreviation prefix, then name prefix, then substring.
function filterTeams(teams, query) {
  var list = teams || []
  var needle = String(query || "").trim().toLowerCase()
  if (needle === "") return list

  var scored = []
  for (var i = 0; i < list.length; i++) {
    var team = list[i]
    var abbr = String(team.abbr || "").toLowerCase()
    var name = String(team.name || "").toLowerCase()
    var short = String(team.short || "").toLowerCase()

    var score = -1
    if (abbr === needle) score = 0
    else if (abbr.indexOf(needle) === 0) score = 1
    else if (name.indexOf(needle) === 0) score = 2
    else if (short.indexOf(needle) === 0) score = 3
    else if (name.indexOf(needle) >= 0 || short.indexOf(needle) >= 0) score = 4

    if (score >= 0) scored.push({ team: team, score: score, name: name })
  }

  scored.sort(function(a, b) {
    if (a.score !== b.score) return a.score - b.score
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
  })

  var out = []
  for (var j = 0; j < scored.length; j++) out.push(scored[j].team)
  return out
}

function teamDisplayName(teams, abbr, fallback) {
  var list = teams || []
  var needle = String(abbr || "").toUpperCase()
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].abbr).toUpperCase() === needle) return list[i].name
  }
  return String(fallback || needle)
}

// ESPN stamps dates as "2026-09-11T00:35Z" — valid ISO 8601, but the missing
// seconds field trips some engines. Normalize before handing it to Date.
function parseDate(iso) {
  var text = String(iso || "")
  if (text === "") return null
  var normalized = text.replace(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(Z|[+-]\d{2}:?\d{2})$/, "$1:00$2")
  var date = new Date(normalized)
  return isNaN(date.getTime()) ? null : date
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function dayName(date) {
  return t("days_short")[date.getDay()]
}

// The clock stays 24h to match the shell's own clock widget.
function dateDigits(date) {
  return pad2(date.getMonth() + 1) + "/" + pad2(date.getDate())
}

function formatKickoff(iso) {
  var d = parseDate(iso)
  if (!d) return ""
  return dayName(d) + " " + dateDigits(d) + " "
    + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function formatDay(iso) {
  var d = parseDate(iso)
  if (!d) return ""
  return dayName(d) + " " + dateDigits(d)
}

function formatTime(iso) {
  var d = parseDate(iso)
  if (!d) return ""
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// Relative distance to kickoff, coarse on purpose: the panel refreshes on a
// timer, so minute-accurate countdowns would just look stale.
function countdown(iso, nowMs) {
  var d = parseDate(iso)
  if (!d) return ""
  var deltaMinutes = Math.round((d.getTime() - nowMs) / 60000)
  if (deltaMinutes < 0) return ""
  if (deltaMinutes < 60) return fill(t("minutes"), deltaMinutes)
  var hours = Math.round(deltaMinutes / 60)
  if (hours < 24) return fill(t("hours"), hours)
  var days = Math.round(hours / 24)
  if (days < 14) return fill(t(days === 1 ? "day" : "days"), days)
  return fill(t("weeks"), Math.round(days / 7))
}

function isLive(game) {
  return !!game && game.state === "in"
}

function opponentLabel(game) {
  if (!game) return ""
  var prefix = game.neutralSite ? "vs " : (game.homeAway === "home" ? "vs " : "@ ")
  return prefix + String(game.opponent || "")
}

// Long form for the hero line: "vs Miami Dolphins" / "@ Los Angeles Rams".
function opponentLongLabel(game) {
  if (!game) return ""
  var prefix = game.neutralSite ? "vs " : (game.homeAway === "home" ? "vs " : "@ ")
  return prefix + String(game.opponentName || game.opponent || "")
}

function weekLabel(game) {
  if (!game) return ""
  if (game.seasonType === 3) return String(game.weekText || t("playoffs"))
  if (game.seasonType === 1) return t("pre") + " " + String(game.week || "")
  return t("week") + " " + String(game.week || "")
}

function scoreLine(game) {
  if (!game || game.teamScore === null || game.oppScore === null) return ""
  return String(game.teamScore) + ":" + String(game.oppScore)
}

function played(data) {
  var games = (data && data.games) || []
  var out = []
  for (var i = 0; i < games.length; i++) {
    if (games[i].completed) out.push(games[i])
  }
  return out
}

function upcoming(data) {
  var games = (data && data.games) || []
  var out = []
  for (var i = 0; i < games.length; i++) {
    if (!games[i].completed) out.push(games[i])
  }
  return out
}

function liveGame(data) {
  var games = (data && data.games) || []
  for (var i = 0; i < games.length; i++) {
    if (isLive(games[i])) return games[i]
  }
  return null
}

// A live game outranks the next scheduled one — that is what you want on the
// bar while the game is on.
function nextGame(data) {
  var live = liveGame(data)
  if (live) return live
  var pending = upcoming(data)
  return pending.length ? pending[0] : null
}

function lastGame(data) {
  var done = played(data)
  return done.length ? done[done.length - 1] : null
}

function recordLabel(data) {
  if (!data || !data.record) return ""
  var r = data.record
  var text = String(r.wins) + "-" + String(r.losses)
  if (r.ties) text += "-" + String(r.ties)
  return text
}

// Record over regular-season games only; the combined record mixes in
// preseason, which no standings table counts.
function regularRecordLabel(data) {
  var done = played(data)
  var w = 0, l = 0, t2 = 0
  for (var i = 0; i < done.length; i++) {
    if (done[i].seasonType !== 2) continue
    if (done[i].result === "W") w++
    else if (done[i].result === "L") l++
    else if (done[i].result === "T") t2++
  }
  if (w + l + t2 === 0) return ""
  return String(w) + "-" + String(l) + (t2 ? "-" + String(t2) : "")
}

// Regular-season weeks with no game on the calendar. 2026 runs 18 weeks for
// 17 games, so exactly one bye falls out of this.
function byeWeeks(data) {
  var games = (data && data.games) || []
  var seen = {}
  var maxWeek = 0
  for (var i = 0; i < games.length; i++) {
    if (games[i].seasonType !== 2) continue
    var w = parseInt(games[i].week, 10)
    if (!w) continue
    seen[w] = true
    if (w > maxWeek) maxWeek = w
  }
  var out = []
  for (var week = 1; week <= maxWeek; week++) {
    if (!seen[week]) out.push(week)
  }
  return out
}

function standingsRows(data, scope) {
  var s = (data && data.standings) || {}
  return scope === "conference" ? (s.conference || []) : (s.division || [])
}

function standingsTitle(data, scope) {
  var s = (data && data.standings) || {}
  if (scope === "conference") return String(s.conferenceName || "Conference")
  return String(s.divisionName || t("standings"))
}

// Newest results first — a results list reads better backwards.
function reversed(list) {
  var out = []
  for (var i = (list || []).length - 1; i >= 0; i--) out.push(list[i])
  return out
}

function limited(list, count) {
  var items = list || []
  var max = parseInt(count, 10)
  if (!max || max <= 0 || items.length <= max) return items
  return items.slice(0, max)
}

// ---- Bar label -----------------------------------------------------------

function barLabel(data, mode, icon) {
  var glyph = String(icon || "")
  // Icon mode is the default: the bar keeps a single glyph and the popup
  // carries the detail, the way the weather widget does it.
  if (mode === "icon") return glyph
  var prefix = glyph === "" ? "" : glyph + " "
  if (!data) return prefix + "—"

  var live = liveGame(data)
  if (live) {
    var score = scoreLine(live)
    var clock = live.displayClock ? ("Q" + live.period + " " + live.displayClock) : "LIVE"
    return prefix + String(data.team.abbr) + " " + (score || "0:0") + " " + clock
  }

  if (mode === "record") {
    var rec = regularRecordLabel(data) || recordLabel(data)
    return prefix + (rec || "—")
  }

  if (mode === "last") {
    var last = lastGame(data)
    if (!last) return prefix + "—"
    return prefix + last.result + " " + scoreLine(last) + " " + opponentLabel(last)
  }

  var next = nextGame(data)
  if (!next) {
    var fallback = lastGame(data)
    if (!fallback) return prefix + "—"
    return prefix + fallback.result + " " + scoreLine(fallback)
  }

  if (mode === "short") return prefix + opponentLabel(next)
  return prefix + opponentLabel(next) + " " + formatKickoff(next.date)
}

function tooltipText(data) {
  if (!data) return t("noTeamData")
  var lines = []
  lines.push(String(data.team.name) + "  " + (regularRecordLabel(data) || recordLabel(data) || ""))
  var next = nextGame(data)
  if (next) {
    lines.push(t("next") + ": " + opponentLongLabel(next) + " — "
      + formatKickoff(next.date) + " (" + weekLabel(next) + ")")
  }
  var last = lastGame(data)
  if (last) {
    lines.push(t("last") + ": " + last.result + " " + scoreLine(last) + " " + opponentLabel(last))
  }
  return lines.join("\n")
}
