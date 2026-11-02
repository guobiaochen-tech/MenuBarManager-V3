import AppKit
import CoreGraphics

final class BreakReminder: NSObject {

    enum State {
        case working        // 工作计时
        case alerting       // 工作达阈值,初次提醒弹窗
        case resting        // 休息计时中
        case restingAlert   // 休息中检测到键鼠活动,再次弹窗
    }

    static let shared = BreakReminder()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "breakReminder.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "breakReminder.enabled") }
    }

    var workLimitMin: Int {
        get {
            let v = UserDefaults.standard.object(forKey: "breakReminder.workLimitMin") as? Int ?? 45
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: "breakReminder.workLimitMin") }
    }

    var restLimitMin: Int {
        get { UserDefaults.standard.object(forKey: "breakReminder.restLimitMin") as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: "breakReminder.restLimitMin") }
    }

    private(set) var state: State = .working {
        didSet {
            Log.info("Break", "状态转移 \(oldValue) -> \(state) work=\(Int(workSeconds))s alertActive=\(restingAlertActive)")
        }
    }
    private var workSeconds: TimeInterval = 0
    private var tickTimer: Timer?
    private var alertWindow: BreakAlertWindow?

    private var restingAlertActive: Bool = false
    private let restMotionlessGrace: TimeInterval = 10
    private let alertDismissGrace: TimeInterval = 2.0
    private var lastAlertDismissAt: Date?

    private let workAwayGrace: TimeInterval = 60
    /// 系统屏保启动时间；用户关了屏保（设为「永不」）时为 nil，此时没法判断"在看视频"
    private var screensaverIdleTime: TimeInterval?
    private var screensaverActive: Bool = false

    /// 供菜单显示当前计时，直接读取提醒器的状态。
    var statusText: String {
        guard enabled else { return "已关闭" }
        switch state {
        case .working:
            let seconds = max(0, Int(workSeconds))
            return String(format: "工作 %d:%02d / %d:00", seconds / 60, seconds % 60, workLimitMin)
        case .alerting:
            return "工作时间已到，请休息"
        case .resting:
            let remaining = max(0, restLimitMin * 60 - Int(currentIdleSec()))
            return String(format: "休息剩余 %d:%02d", remaining / 60, remaining % 60)
        case .restingAlert:
            return "请离开屏幕，继续休息"
        }
    }

    /// 菜单里选工作时长：打开提醒，计时清零；正在提醒或休息就直接结束，从头算
    func chooseWorkLimit(_ minutes: Int) {
        guard !enabled || workLimitMin != minutes else { return }
        Log.info("Break", "选工作时长 \(minutes)min（之前 \(enabled ? "\(workLimitMin)min" : "已关闭")）")
        workLimitMin = minutes
        enabled = true
        resetCycle()
    }

    /// 菜单里选休息时长：打开提醒。工作计时不清零，正在休息就直接按新时长算；
    /// 从关闭状态打开时从头算。
    func chooseRestLimit(_ minutes: Int) {
        guard !enabled || restLimitMin != minutes else { return }
        Log.info("Break", "选休息时长 \(minutes)min（之前 \(enabled ? "\(restLimitMin)min" : "已关闭")）")
        let wasEnabled = enabled
        restLimitMin = minutes
        enabled = true
        if !wasEnabled { resetCycle() }
    }

    func disable() {
        guard enabled else { return }
        Log.info("Break", "关闭提醒")
        enabled = false
        resetCycle()
    }

    /// 回到工作计时 0 秒，收起提醒窗
    private func resetCycle() {
        workSeconds = 0
        state = .working
        restingAlertActive = false
        lastAlertDismissAt = nil
        alertWindow?.hide()
    }

    func start() {
        guard tickTimer == nil else { return }
        screensaverIdleTime = readScreensaverIdleTime()
        registerScreensaverObservers()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        Log.info("Break", "启动 workLimit=\(workLimitMin)min restLimit=\(restLimitMin)min screensaverIdle=\(screensaverIdleTime.map { "\(Int($0))s" } ?? "关闭") enabled=\(enabled)")
    }

    /// 读系统屏保等待时间（等同 `defaults -currentHost read com.apple.screensaver idleTime`）。
    /// 没设置过时系统默认 20 分钟；设为 0 表示屏保关闭。
    private func readScreensaverIdleTime() -> TimeInterval? {
        let value = CFPreferencesCopyValue("idleTime" as CFString, "com.apple.screensaver" as CFString,
                                           kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard let seconds = (value as? NSNumber)?.intValue else { return 1200 }
        return seconds > 0 ? TimeInterval(seconds) : nil
    }

    /// 键鼠不动超过屏保时间、屏保却没起来 → 被视频播放器压住了，算在看视频
    private func isWatchingVideo(idleSec: TimeInterval) -> Bool {
        guard let screensaverIdleTime, !screensaverActive else { return false }
        return idleSec >= screensaverIdleTime
    }

    private func registerScreensaverObservers() {
        let nc = DistributedNotificationCenter.default()
        nc.addObserver(self, selector: #selector(inactiveDidStart),
                       name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)
        nc.addObserver(self, selector: #selector(inactiveDidStop),
                       name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil)
        nc.addObserver(self, selector: #selector(inactiveDidStart),
                       name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        nc.addObserver(self, selector: #selector(inactiveDidStop),
                       name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    private func currentIdleSec() -> TimeInterval {
        let eventTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
            .leftMouseDragged, .rightMouseDragged,
            .keyDown, .scrollWheel
        ]
        var idleSec = TimeInterval.infinity
        for t in eventTypes {
            let s = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: t)
            if s >= 0 && s.isFinite { idleSec = min(idleSec, s) }
        }
        if !idleSec.isFinite { idleSec = 0 }
        return idleSec
    }

    @objc private func inactiveDidStart() {
        screensaverActive = true
        switch state {
        case .alerting:
            Log.info("Break", "报警中屏保启动,判定用户离开,收窗进休息计时")
            alertWindow?.hide()
            restingAlertActive = false
            state = .resting
        case .working, .resting, .restingAlert:
            break
        }
    }

    @objc private func inactiveDidStop() {
        screensaverActive = false
    }

    private func tick() {
        guard enabled else { return }
        switch state {
        case .working:
            tickWorking()
        case .resting, .restingAlert:
            tickResting()
        case .alerting:
            tickAlerting()
        }
    }

    private func tickWorking() {
        let idleSec = currentIdleSec()
        let restThreshold = workAwayGrace + TimeInterval(restLimitMin * 60)

        if idleSec < workAwayGrace {
            workSeconds += 1
        } else if isWatchingVideo(idleSec: idleSec) {
            workSeconds += 1
        } else if idleSec >= restThreshold {
            if workSeconds > 0 {
                Log.info("Break", "连续不动\(Int(idleSec))s>=\(Int(restThreshold))s,休息过了,清零workSeconds")
                workSeconds = 0
            }
        }

        if workSeconds >= TimeInterval(workLimitMin * 60) {
            Log.warn("Break", "工作达阈值 \(workLimitMin)min,触发初次提醒")
            state = .alerting
            showAlert(mode: .initial)
        }
    }

    private func tickAlerting() {
        if let last = lastAlertDismissAt, Date().timeIntervalSince(last) < alertDismissGrace {
            return
        }
        let idleSec = currentIdleSec()
        if screensaverActive {
            Log.info("Break", "报警中屏保启动,判定用户离开,收窗进休息计时")
            alertWindow?.hide()
            restingAlertActive = false
            state = .resting
        } else if idleSec >= restMotionlessGrace {
            Log.info("Break", "报警中静止>=\(Int(restMotionlessGrace))s,判定用户离开,收窗进休息计时")
            alertWindow?.hide()
            restingAlertActive = false
            state = .resting
        }
    }

    private func tickResting() {
        let idleSec = currentIdleSec()
        Log.debug("Break", "tickResting state=\(state) idleSec=\(String(format: "%.2f", idleSec)) alertActive=\(restingAlertActive)")

        if let last = lastAlertDismissAt, Date().timeIntervalSince(last) < alertDismissGrace {
            return
        }

        if idleSec < 1 {
            if state == .resting && !restingAlertActive {
                Log.warn("Break", "休息中检测到键鼠活动(idleSec=\(String(format: "%.2f", idleSec))),触发二次报警")
                state = .restingAlert
                restingAlertActive = true
                showAlert(mode: .restingViolation)
            }
            return
        }

        if restingAlertActive && idleSec >= restMotionlessGrace {
            Log.info("Break", "报警态下静止>=\(Int(restMotionlessGrace))s,收起弹窗进入正式计时")
            alertWindow?.hide()
            restingAlertActive = false
            state = .resting
        }

        if idleSec >= TimeInterval(restLimitMin * 60) {
            Log.info("Break", "休息完成 \(restLimitMin)min,回到工作")
            workSeconds = 0
            state = .working
        }
    }

    private func showAlert(mode: BreakAlertWindow.Mode = .initial) {
        Log.info("Break", "showAlert mode=\(mode == .initial ? "初次" : "休息违规")")
        if alertWindow == nil {
            let w = BreakAlertWindow()
            w.onClose = { [weak self] in
                self?.handleAlertClose()
            }
            alertWindow = w
        }
        alertWindow?.show(workLimitMin: workLimitMin, restLimitMin: restLimitMin, mode: mode)
    }

    private func handleAlertClose() {
        Log.info("Break", "用户点[我知道了] 当前state=\(state)")
        lastAlertDismissAt = Date()
        switch state {
        case .alerting:
            state = .resting
            restingAlertActive = false
        case .restingAlert:
            state = .resting
            restingAlertActive = false
        default:
            Log.warn("Break", "handleAlertClose 在非预期状态 \(state)")
        }
    }
}
