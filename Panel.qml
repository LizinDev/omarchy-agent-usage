import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.lizindev.agent-usage"
  ipcTarget: "agent-usage"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Commons.Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Commons.Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The rail: one disc per agent down the left edge.
  readonly property bool showRail: providers.length > 1
  readonly property real railButtonSize: Style.space(40)
  readonly property real ringWidth: Math.max(2, Style.space(3))
  readonly property real markerWidth: Math.max(2, Style.space(3))

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    var reset = new Date(String(resetAt || "")).getTime()
    var expired = isFinite(reset) && reset <= root.nowMs
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: expired ? 0 : Number(percent),
      resetAt: expired ? "" : String(resetAt || ""),
      spanMs: windowSpanMs(label)
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  // How far through its window the clock is, 0 to 1; -1 when the window's
  // length or reset is unknown.
  function windowElapsed(w) {
    if (!w || !(w.spanMs > 0)) return -1
    var left = resetMsFor(w)
    if (!(left > 0)) return -1
    return clamp(1 - left / w.spanMs, 0, 1)
  }

  // Where the current pace lands at the reset. Too early in a window the
  // projection says nothing useful, so it waits for 5% of the clock.
  function limitForecast(w) {
    var elapsed = windowElapsed(w)
    if (elapsed < 0.05 || !w || !(w.percent >= 0)) return null
    if (w.percent >= 1) return { text: "Limit reached", short: true, ahead: true }
    var projected = w.percent / elapsed
    if (projected >= 1) {
      var rate = w.percent / (elapsed * w.spanMs)
      return { text: "Runs out in " + formatDuration((1 - w.percent) / rate), short: true, ahead: true }
    }
    return { text: "~" + Math.round((1 - projected) * 100) + "% left at reset", short: false, ahead: w.percent > elapsed }
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Commons.Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    // A dashboard: the whole point is reading limits and history without
    // scrolling, so it may run taller than the control panels.
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight, rail.implicitHeight), Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      // ---------- Rail: every agent's mark, ringed by its fullest limit ----------
      Column {
        id: rail
        visible: root.showRail
        anchors.left: parent.left
        anchors.leftMargin: root.markerWidth + Style.space(6)
        anchors.top: parent.top
        width: root.railButtonSize
        spacing: Style.space(10)

        Repeater {
          model: root.providers

          RailButton {
            required property var modelData
            required property int index
            provider: modelData
            selected: index === root.providerIndex
            hasCursor: root.cursorActive && index === root.providerIndex
            onClicked: {
              root.cursorActive = true
              root.selectProvider(index)
            }
          }
        }
      }

      // The accent marker slides to the agent on show.
      Rectangle {
        visible: rail.visible
        x: 0
        width: root.markerWidth
        height: Math.round(root.railButtonSize * 0.56)
        y: rail.y + root.providerIndex * (root.railButtonSize + rail.spacing) + (root.railButtonSize - height) / 2
        radius: Math.min(width / 2, Style.cornerRadius)
        color: Commons.Color.accent

        Behavior on y {
          NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }
      }

      Rectangle {
        id: railDivider
        visible: rail.visible
        anchors.left: rail.right
        anchors.leftMargin: Style.space(12)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: root.alpha(root.foreground, 0.08)
      }

      Flickable {
        id: panelFlick
        anchors.left: rail.visible ? railDivider.right : parent.left
        anchors.leftMargin: rail.visible ? Style.space(16) : 0
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(16)

          // A new agent's page settles in rather than snapping.
          opacity: 1
          SequentialAnimation on opacity {
            id: switchFade
            running: false
            NumberAnimation { to: 0.35; duration: 0 }
            NumberAnimation { to: 1; duration: 220; easing.type: Easing.OutCubic }
          }
          Connections {
            target: root
            function onProviderIndexChanged() { switchFade.restart() }
          }

          // ---------- Hero: tinted mark · name · plan · refresh ----------
          Item {
            id: hero
            visible: !!root.provider
            width: parent.width
            implicitHeight: Math.max(heroMark.height, heroText.implicitHeight)

            Rectangle {
              id: heroMark
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(44)
              height: width
              radius: Style.cornerRadius
              color: root.alpha(Commons.Color.accent, 0.12)

              ProviderIcon {
                anchors.centerIn: parent
                provider: root.provider
                size: Style.font.display
              }
            }

            Column {
              id: heroText
              anchors.left: heroMark.right
              anchors.leftMargin: Style.space(14)
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.provider ? root.provider.providerName : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.heroMeta(root.provider).toUpperCase()
                color: root.provider && String(root.provider.usageStatusText || "") !== "" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
                elide: Text.ElideRight
              }
            }

            HeroButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              glyph: "󰑓"
              tooltip: "Refresh (r)"
              spinning: usage.refreshing
              onClicked: root.refreshNow()
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding agents found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Today ----------
          Item {
            id: todayBlock
            visible: !!root.provider
            width: parent.width
            implicitHeight: todayValue.implicitHeight + todayCaption.implicitHeight

            Text {
              id: todayValue
              anchors.left: parent.left
              anchors.top: parent.top
              textFormat: Text.PlainText
              text: root.provider ? usage.formatTokenCount(Number(root.provider.todayTotalTokens || 0)) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Text {
              id: todayCaption
              anchors.left: parent.left
              anchors.top: todayValue.bottom
              textFormat: Text.PlainText
              text: "TOKENS TODAY"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
            }

            Column {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(2)
              visible: !!root.provider && root.provider.hasPromptStats !== false

              Repeater {
                model: root.provider ? [
                  { value: Number(root.provider.todayPrompts || 0), label: Number(root.provider.todayPrompts || 0) === 1 ? "prompt" : "prompts" },
                  { value: Number(root.provider.todaySessions || 0), label: Number(root.provider.todaySessions || 0) === 1 ? "session" : "sessions" }
                ] : []

                Row {
                  required property var modelData
                  anchors.right: parent.right
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: String(modelData.value)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          // ---------- Balance / limits ----------
          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(14)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- This week ----------
          Column {
            id: weekSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.space(8)

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            Item {
              width: parent.width
              implicitHeight: weekHeader.implicitHeight

              PanelSectionHeader {
                id: weekHeader
                text: "THIS WEEK"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "peak " + usage.formatTokenCount(root.weekPeak(root.provider))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: weekChart
              width: parent.width
              height: Style.space(72)
              spacing: Style.space(6)

              readonly property real columnWidth: (width - spacing * Math.max(0, weekSection.days.length - 1)) / Math.max(1, weekSection.days.length)

              Repeater {
                model: weekSection.days

                DayColumn {
                  required property var modelData
                  width: weekChart.columnWidth
                  height: weekChart.height
                  day: modelData
                  ratio: Number(modelData.messageCount || 0) / weekSection.peak
                  today: String(modelData.date || "") === root.todayDate()
                }
              }
            }

            Row {
              width: parent.width
              spacing: weekChart.spacing

              Repeater {
                model: weekSection.days

                Text {
                  required property var modelData
                  readonly property bool today: String(modelData.date || "") === root.todayDate()
                  width: weekChart.columnWidth
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: today ? "Today" : root.dayName(modelData.date)
                  color: today ? Commons.Color.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: today
                }
              }
            }
          }

          // ---------- Models ----------
          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              width: parent.width
              text: "BY MODEL · ALL TIME"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                required property int index
                width: modelSection.width
                row: modelData
                lead: index === 0
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // An agent on the rail: its mark in a disc, ringed by its fullest limit.
  // The ring is the agent's state at a glance, so it stays even unselected.
  component RailButton: Item {
    id: railButton
    property var provider: null
    property bool selected: false
    property bool hasCursor: false
    signal clicked()

    readonly property var window: root.bindingWindow(provider)
    readonly property real percent: window ? root.clamp(window.percent, 0, 1) : -1
    readonly property bool alarming: percent >= 0.9
    // Zero while the panel is closed, so every ring sweeps in as it opens.
    property real shown: root.opened ? Math.max(0, percent) : 0
    Behavior on shown { NumberAnimation { duration: 520; easing.type: Easing.OutCubic } }

    width: root.railButtonSize
    height: width

    Rectangle {
      anchors.centerIn: parent
      width: parent.width - root.ringWidth * 2 - Style.space(4)
      height: width
      radius: width / 2
      color: railButton.selected ? root.alpha(Commons.Color.accent, 0.16)
        : (railHover.containsMouse ? root.alpha(root.foreground, 0.07) : "transparent")
      border.width: railButton.hasCursor ? Math.max(1, Style.hoverBorderWidth) : 0
      border.color: Commons.Color.accent

      Behavior on color { ColorAnimation { duration: 140 } }
    }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: root.alpha(root.foreground, 0.12)
        strokeWidth: root.ringWidth
        fillColor: "transparent"
        PathAngleArc {
          centerX: railButton.width / 2
          centerY: railButton.height / 2
          radiusX: railButton.width / 2 - root.ringWidth / 2
          radiusY: radiusX
          startAngle: -90
          sweepAngle: 360
        }
      }

      ShapePath {
        strokeColor: railButton.percent < 0 ? "transparent"
          : railButton.alarming ? root.urgent
          : railButton.selected ? Commons.Color.accent : root.foreground
        strokeWidth: root.ringWidth
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: railButton.width / 2
          centerY: railButton.height / 2
          radiusX: railButton.width / 2 - root.ringWidth / 2
          radiusY: radiusX
          startAngle: -90
          sweepAngle: 360 * railButton.shown
        }
      }
    }

    ProviderIcon {
      anchors.centerIn: parent
      provider: railButton.provider
      size: Math.round(root.railButtonSize * 0.42)
      opacity: railButton.selected || railHover.containsMouse ? 1 : 0.72
      Behavior on opacity { NumberAnimation { duration: 140 } }
    }

    MouseArea {
      id: railHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: railButton.clicked()
    }

    PanelToolTip {
      visible: railHover.containsMouse
      text: {
        if (!railButton.provider) return ""
        var line = railButton.provider.providerName
        if (railButton.window)
          line += " · " + railButton.window.title + " " + Math.round(railButton.window.percent * 100) + "%"
        return line + " · " + usage.formatTokenCount(Number(railButton.provider.todayTotalTokens || 0)) + " today"
      }
      fontFamily: root.fontFamily
    }
  }

  // A provider's mark, falling back to the bar glyph when it ships none.
  component ProviderIcon: Item {
    id: mark
    property var provider: null
    property var candidates: root.iconCandidatesForProvider(provider, root.surface)
    // Provider objects are rebuilt on every refresh, which churns the
    // array's identity without changing its content. Restart the fallback
    // walk only when the URLs change.
    property string candidatesKey: candidates.join("\n")
    property int candidateIndex: 0
    onCandidatesKeyChanged: candidateIndex = 0
    property real size: Style.font.heading

    width: size
    height: size

    Image {
      id: markImage
      anchors.fill: parent
      source: mark.candidateIndex < mark.candidates.length ? mark.candidates[mark.candidateIndex] : ""
      sourceSize.width: mark.size * 2
      sourceSize.height: mark.size * 2
      fillMode: Image.PreserveAspectFit
      // Advancing source from inside its own status change trips the
      // binding-loop detector; defer the step one tick.
      onStatusChanged: if (status === Image.Error && mark.candidateIndex < mark.candidates.length)
        Qt.callLater(function() { mark.candidateIndex++ })
    }

    Text {
      anchors.centerIn: parent
      visible: markImage.status !== Image.Ready
      textFormat: Text.PlainText
      text: button.text
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: mark.size
    }
  }

  // The tinted square in the hero's corner, as in Omarchy's newer panels.
  component HeroButton: Rectangle {
    id: heroButton
    signal clicked()
    property string glyph: ""
    property string tooltip: ""
    property bool spinning: false

    implicitWidth: Style.space(34)
    implicitHeight: implicitWidth
    radius: Style.cornerRadius
    color: root.alpha(Commons.Color.accent, heroMouse.containsMouse ? 0.3 : 0.12)

    Behavior on color { ColorAnimation { duration: 140 } }

    Text {
      id: heroGlyph
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: heroButton.glyph
      color: Commons.Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading

      RotationAnimation on rotation {
        running: heroButton.spinning
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        onRunningChanged: if (!running) heroGlyph.rotation = 0
      }
    }

    MouseArea {
      id: heroMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: heroButton.clicked()
    }

    PanelToolTip {
      visible: heroMouse.containsMouse
      text: heroButton.tooltip
      fontFamily: root.fontFamily
    }
  }

  // A limit window: title and share used, a meter with the pace marker, and
  // what the current pace leaves at the reset.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9
    readonly property real elapsed: root.windowElapsed(window)
    readonly property var forecast: root.limitForecast(window)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
      pace: limitRow.elapsed
    }

    Item {
      width: parent.width
      implicitHeight: resetText.implicitHeight

      Text {
        id: resetText
        textFormat: Text.PlainText
        anchors.left: parent.left
        text: {
          var remainingMs = root.resetMsFor(limitRow.window)
          return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: limitRow.forecast ? limitRow.forecast.text : ""
        color: !limitRow.forecast ? root.dim
          : limitRow.forecast.short ? root.urgent
          : limitRow.forecast.ahead ? Commons.Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Rounded track showing the share of the allowance used, with an accent
  // tick where the window's clock stands: fill past the tick means ahead of
  // pace.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real pace: -1
    property real thickness: Math.max(Style.space(5), Math.round(Style.spacing.controlHeight * 0.18))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      // Fills from empty each time the panel opens, alongside the rail rings.
      width: root.opened ? meterTrack.width * root.clamp(meter.value, 0, 1) : 0
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      visible: meter.pace >= 0
      width: Math.max(2, Math.round(meter.thickness * 0.45))
      height: meter.thickness * 2.6
      radius: width / 2
      anchors.verticalCenter: meterTrack.verticalCenter
      x: root.clamp(meterTrack.width * root.clamp(meter.pace, 0, 1) - width / 2, 0, meterTrack.width - width)
      color: Commons.Color.accent
    }
  }

  // One column per day, scaled to the week's busiest; today in the accent.
  component DayColumn: Item {
    id: dayColumn
    property var day: null
    property real ratio: 0
    property bool today: false

    // A hairline floor keeps empty days on the chart; the column only lights
    // up under the pointer.
    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.06)
      opacity: columnHover.containsMouse ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: root.alpha(root.foreground, 0.16)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: dayColumn.ratio > 0 ? Math.max(Style.space(2), parent.height * root.clamp(dayColumn.ratio, 0, 1)) : 0
      radius: Style.cornerRadius
      color: dayColumn.today ? Commons.Color.accent : root.alpha(root.foreground, columnHover.containsMouse ? 0.7 : 0.45)

      Behavior on height {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
      }
    }

    MouseArea {
      id: columnHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: columnHover.containsMouse
      text: root.dayTooltip(dayColumn.day, dayColumn.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it. The heaviest model carries the accent.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0
    property bool lead: false

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.04)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: modelRow.lead ? root.alpha(Commons.Color.accent, 0.18) : root.alpha(root.foreground, 0.10)

      Behavior on width {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: modelRow.lead ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
