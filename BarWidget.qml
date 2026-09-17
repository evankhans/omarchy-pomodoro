import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "omarchy-pomodoro"

  // Settings from shell.json
  readonly property int workMinutes: Model.parseDuration(setting("workMinutes", 25), 25, 1, 120)
  readonly property int shortBreakMinutes: Model.parseDuration(setting("shortBreakMinutes", 5), 5, 1, 60)
  readonly property int longBreakMinutes: Model.parseDuration(setting("longBreakMinutes", 15), 15, 1, 90)
  readonly property int longBreakInterval: Model.parseDuration(setting("longBreakInterval", 4), 4, 1, 12)
  readonly property bool autoStartBreaks: setting("autoStartBreaks", false)
  readonly property bool autoStartWork: setting("autoStartWork", false)
  readonly property bool soundEnabled: setting("soundEnabled", true)
  readonly property bool notifyEnabled: setting("notifyEnabled", true)
  readonly property bool showTimerInBar: setting("showTimerInBar", true)
  readonly property bool showIconInBar: setting("showIconInBar", true)
  readonly property bool showOnlyWhenRunning: setting("showOnlyWhenRunning", false)

  // Strict-break mode: when enabled, finishing a focus session locks the
  // screen via `omarchy system lock` (enforced through the plugin's own
  // hook script, see bin/omarchy-pomodoro-break-hook) so the break is
  // actually taken. Also gates the pause/skip guards below.
  readonly property bool lockOnBreak: setting("lockOnBreak", false)
  readonly property bool enforceFullFocus: setting("enforceFullFocus", false)

  // Pomodoro State
  property string phase: Model.PHASE_WORK
  property string state: Model.STATE_IDLE
  property int completedSessions: 0
  property int totalSeconds: durationForPhase(Model.PHASE_WORK)
  property int timeLeft: totalSeconds

  readonly property bool isRunning: state === Model.STATE_RUNNING
  readonly property bool isPaused: state === Model.STATE_PAUSED
  readonly property bool isIdle: state === Model.STATE_IDLE
  readonly property real progress: Model.calcProgress(timeLeft, totalSeconds)
  readonly property string timeString: Model.formatTime(timeLeft)
  readonly property string iconString: Model.phaseIcon(phase)
  readonly property string phaseName: Model.phaseTitle(phase)

  // Visibility: can hide on bar when idle if configured
  visible: !showOnlyWhenRunning || isRunning || isPaused || opened

  // Label for horizontal bar
  readonly property string barLabel: {
    var parts = []
    if (showIconInBar) parts.push(iconString)
    if (showTimerInBar || !showIconInBar) parts.push(timeString)
    return parts.join(" ")
  }

  // Label for vertical bar
  readonly property string verticalBarLabel: {
    var mins = Math.ceil(timeLeft / 60)
    return iconString + "\n" + mins + "m"
  }

  function durationForPhase(p) {
    if (p === Model.PHASE_SHORT_BREAK) return shortBreakMinutes * 60
    if (p === Model.PHASE_LONG_BREAK) return longBreakMinutes * 60
    return workMinutes * 60
  }

  function start() {
    if (timeLeft <= 0) {
      timeLeft = durationForPhase(phase)
      totalSeconds = timeLeft
    }
    state = Model.STATE_RUNNING
  }

  function pause() {
    // Strict-focus mode: pause disabled during focus phase so the focus
    // session always runs to completion and the break lock always fires.
    if (enforceFullFocus && phase === Model.PHASE_WORK) return
    state = Model.STATE_PAUSED
  }

  function togglePlayPause() {
    if (enforceFullFocus && phase === Model.PHASE_WORK && isRunning) return // no pause during focus when strict
    if (isRunning) pause()
    else start()
  }

  function reset() {
    state = Model.STATE_IDLE
    totalSeconds = durationForPhase(phase)
    timeLeft = totalSeconds
  }

  function setPhase(newPhase, autoStart) {
    phase = newPhase
    totalSeconds = durationForPhase(newPhase)
    timeLeft = totalSeconds
    if (autoStart) {
      state = Model.STATE_RUNNING
    } else {
      state = Model.STATE_IDLE
    }
    if (newPhase === Model.PHASE_WORK) {
      // Clear the lock-screen countdown so the patched lock view hides it.
      Quickshell.execDetached(["sh", "-c", "rm -f '" + countdownPath + "'"])
    }
  }

  function skipPhase() {
    // Strict-break mode: skipping is disabled — phases must always run to
    // completion so the break lock always fires at the right moment.
    if (lockOnBreak || enforceFullFocus) return
    var nextInfo = Model.nextPhaseInfo(phase, completedSessions, longBreakInterval)
    completedSessions = nextInfo.completedSessions
    setPhase(nextInfo.nextPhase, false)
  }

  function adjustTime(secondsDelta) {
    var next = Model.clamp(timeLeft + secondsDelta, 5, 7200)
    timeLeft = next
    if (next > totalSeconds) totalSeconds = next
  }

  function finishSession() {
    var oldPhase = phase
    var nextInfo = Model.nextPhaseInfo(phase, completedSessions, longBreakInterval)
    var nextPhase = nextInfo.nextPhase
    completedSessions = nextInfo.completedSessions

    // Desktop Notification
    if (notifyEnabled) {
      var headline = Model.phaseNotificationHeadline(oldPhase)
      var desc = Model.phaseNotificationDescription(nextPhase)
      var glyph = Model.phaseIcon(oldPhase)
      Quickshell.execDetached([
        "omarchy-notification-send",
        "-g", glyph,
        "-u", "normal",
        headline,
        desc
      ])
    }

    // Audio Chime
    if (soundEnabled) {
      Quickshell.execDetached([
        "paplay",
        "/usr/share/sounds/freedesktop/stereo/complete.oga"
      ])
    }

    var autoStart = (nextPhase === Model.PHASE_WORK) ? autoStartWork : autoStartBreaks

    // Strict-break mode: focus session ended -> lock screen for a real break
    if (lockOnBreak && oldPhase === Model.PHASE_WORK) {
      var hookScript = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "") + "bin/omarchy-pomodoro-break-hook"
      Quickshell.execDetached(["sh", "-c",
        "\"" + hookScript + "\" work >/dev/null 2>&1 &"])
    }

    setPhase(nextPhase, autoStart)
  }

  function tick() {
    if (timeLeft > 1) {
      timeLeft -= 1
    } else {
      timeLeft = 0
      finishSession()
    }
    publishCountdown()
  }

  // Publish break countdown for the lock-screen countdown patch: a small
  // state file the patched lock screen reads every second. Only written
  // during an active break phase (short or long).
  readonly property string stateRoot: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string countdownPath: stateRoot + "/omarchy/pomodoro-break-state"

  function publishCountdown() {
    if (phase === Model.PHASE_WORK) return
    if (isIdle) return
    Quickshell.execDetached(["sh", "-c",
      "mkdir -p '" + stateRoot + "/omarchy' && printf '%s   %s\\n' '" +
      phaseName + "' '" + timeString + "' > '" + countdownPath + "'"])
  }

  function resetSessionsCount() {
    completedSessions = 0
  }

  // 1-second interval timer
  Timer {
    id: countdownTimer
    interval: 1000
    repeat: true
    running: root.isRunning
    onTriggered: root.tick()
  }

  // Contract for shell.summon / hide / toggle and Bar panel routing
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    // If idle, refresh current total seconds based on possibly updated settings
    if (isIdle) {
      totalSeconds = durationForPhase(phase)
      timeLeft = totalSeconds
    }
  }

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

  IpcHandler {
    target: "omarchy-pomodoro"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function start(): void { root.start() }
    function pause(): void { root.pause() }
    function toggleRunning(): void { root.togglePlayPause() }
    function reset(): void { root.reset() }
    function skip(): void { root.skipPhase() }
    function setWork(): void { root.setPhase(Model.PHASE_WORK, false) }
    function setShortBreak(): void { root.setPhase(Model.PHASE_SHORT_BREAK, false) }
    function setLongBreak(): void { root.setPhase(Model.PHASE_LONG_BREAK, false) }
    function addMinute(): void { root.adjustTime(60) }
    function subMinute(): void { root.adjustTime(-60) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.verticalBarLabel : root.barLabel
    hasVisualContent: true
    active: root.isRunning
    activeColor: Color.accent
    dimmed: root.isPaused
    horizontalMargin: 8.5
    verticalPadding: 6
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.togglePlayPause()
      } else if (b === Qt.MiddleButton) {
        root.skipPhase()
      } else {
        root.togglePanel()
      }
    }

    onWheelMoved: function(delta) {
      if (delta > 0) root.adjustTime(60)
      else if (delta < 0) root.adjustTime(-60)
    }
  }
}
