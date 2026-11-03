import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var permissionWindow: PermissionGuideWindow?
    private let dropdown = DropdownPanel()
    private let mover = ItemMover()
    private let scanner = MenuBarScanner()
    private let scanQueue = DispatchQueue(label: "mbm.v3.scan", qos: .userInitiated)

    private var items: [MenuBarItem] = []
    /// 本软件图标的窗口编号，扫描时认出来
    private var ownWindowID: CGWindowID?
    private var images: [CGWindowID: NSImage] = [:]
    private var scanTimer: Timer?
    private var isScanning = false
    /// 点击时正在扫描，等这次扫完再扫一次并在这里弹出列表
    private var queuedShowAnchor: NSRect?
    private var ownHiddenCount = 0
    private var warnedOwnHidden = false
    /// 切换桌面或进出全屏的次数，扫描期间变了说明结果可能混着新旧两套图标
    private var spaceGeneration = 0
    /// 切换后菜单栏要过一会儿才稳定，这之前不检查本软件图标是否被挤掉
    private var ownCheckPausedUntil: Date = .distantPast

    private static let autosaveName = "MBMV3.Main"

    private var hiddenItems: [MenuBarItem] { items.filter { !$0.isVisible } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.info("App", "启动 版本=\(version) 日志=\(Log.fileURL.path)")

        if Permissions.accessibility && Permissions.screenRecording {
            start()
        } else {
            Log.warn("App", "权限不全 辅助功能=\(Permissions.accessibility) 屏幕录制=\(Permissions.screenRecording)")
            NSApp.setActivationPolicy(.regular)
            let w = PermissionGuideWindow()
            w.onAllGranted = { [weak self] in
                Log.info("App", "权限已给全")
                NSApp.setActivationPolicy(.accessory)
                self?.permissionWindow = nil
                self?.start()
            }
            permissionWindow = w
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func start() {
        registerLoginItemOnce()
        setupStatusItem()
        dropdown.onQuit = { [weak self] in self?.quit() }
        dropdown.reminderStatus = { BreakReminder.shared.statusText }
        dropdown.onReminderClick = { [weak self] row in self?.showReminderMenu(below: row) }
        mover.ownWindowID = { [weak self] in self?.ownWindowID }
        dropdown.onMove = { [weak self] item in
            guard let self else { return }
            Task { @MainActor in
                let moved = await self.mover.moveToMenuBar(item)
                self.scan()
                if !moved {
                    let alert = NSAlert()
                    alert.messageText = "未能将图标移到可见位置"
                    alert.informativeText = "请将本软件图标放在菜单栏靠右的位置，再点击列表中的图标重试。"
                    alert.runModal()
                }
            }
        }
        BreakReminder.shared.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        scan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    // MARK: - 用眼提醒档位

    private static let workChoices = [30, 45, 60]
    private static let restChoices = [5, 10]

    private func showReminderMenu(below row: NSView) {
        let reminder = BreakReminder.shared
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "工作时长"))
        for minutes in Self.workChoices {
            menu.addItem(reminderItem(minutes, checked: reminder.enabled && reminder.workLimitMin == minutes,
                                      action: #selector(workLimitChosen(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "休息时长"))
        for minutes in Self.restChoices {
            menu.addItem(reminderItem(minutes, checked: reminder.enabled && reminder.restLimitMin == minutes,
                                      action: #selector(restLimitChosen(_:))))
        }
        menu.addItem(.separator())
        let off = NSMenuItem(title: "关闭提醒", action: #selector(reminderOffChosen), keyEquivalent: "")
        off.target = self
        off.state = reminder.enabled ? .off : .on
        menu.addItem(off)
        // 菜单左上角贴着这一行的左下角
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: row)
    }

    private func reminderItem(_ minutes: Int, checked: Bool, action: Selector) -> NSMenuItem {
        let title = minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = minutes
        item.state = checked ? .on : .off
        return item
    }

    @objc private func workLimitChosen(_ sender: NSMenuItem) { BreakReminder.shared.chooseWorkLimit(sender.tag) }
    @objc private func restLimitChosen(_ sender: NSMenuItem) { BreakReminder.shared.chooseRestLimit(sender.tag) }
    @objc private func reminderOffChosen() { BreakReminder.shared.disable() }

    // MARK: - 开机启动

    /// 只在第一次加入开机启动项。之后用户在「系统设置 → 通用 → 登录项」里关掉，就不再加回去。
    private func registerLoginItemOnce() {
        let key = "MBMV3.LoginItemRegistered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
            Log.info("App", "已加入开机启动项")
        } catch {
            Log.error("App", "加入开机启动项失败: \(error)")
        }
    }

    // MARK: - 本软件图标

    private func setupStatusItem() {
        // 每次启动都把位置设为 0（最右边，紧挨系统图标），这里最不容易被挤掉，
        // 被挤掉的图标也是移到它左边。用户 ⌘ 拖到别处的位置，下次启动会被改回来。
        UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = []  // 不允许被 ⌘ 拖出菜单栏删掉

        guard let button = statusItem.button else { return }
        if let path = Bundle.main.path(forResource: "statusbar-icon", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = "被挤掉的菜单栏图标"
        button.target = self
        button.action = #selector(statusButtonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 本软件图标按钮所在窗口的位置，换成左上角原点（窗口服务器用的坐标）
    private var ownFrameTopLeft: CGRect? {
        guard let f = statusItem?.button?.window?.frame, let screen = NSScreen.menuBarScreen else { return nil }
        return CGRect(x: f.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    @objc private func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            dropdown.close()
            showQuitMenu()
            return
        }
        if dropdown.isShown {
            dropdown.close()
            return
        }
        guard let anchor = statusItem.button?.window?.frame else { return }
        // 先扫一次再弹出，不用旧结果：旧结果可能是全屏切换动画中途扫到的，不准
        scan(showAt: anchor)
    }

    private func showQuitMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // 用完就拿掉，否则左键也会弹这个菜单
    }

    @objc private func quit() {
        Log.info("App", "退出")
        NSApp.terminate(nil)
    }

    // MARK: - 扫描

    @objc private func activeSpaceChanged() {
        spaceGeneration += 1
        ownHiddenCount = 0
        ownCheckPausedUntil = Date().addingTimeInterval(8)
        Log.debug("Scan", "切换桌面或进出全屏，暂停检查本软件图标")
    }

    /// showAt：点了本软件图标，扫完后在这个位置弹出列表，并重新截图，保证看到的是图标当前样子
    private func scan(showAt anchor: NSRect? = nil) {
        if isScanning {
            // 正在跑的那次是点击前开始的，可能不准，等它跑完再扫一次
            if let anchor { queuedShowAnchor = anchor }
            return
        }
        guard !mover.isBusy, let geometry = MenuBarGeometry.current() else {
            if let anchor { dropdown.show(items: hiddenItems, images: images, anchor: anchor) }
            return
        }
        isScanning = true
        let ownFrame = ownFrameTopLeft
        let generation = spaceGeneration
        scanQueue.async { [scanner] in
            let result = scanner.scan(ownFrame: ownFrame, geometry: geometry)
            Task { @MainActor in
                self.isScanning = false
                if generation != self.spaceGeneration {
                    // 扫描期间切换了桌面或进出全屏，结果不可信，丢掉重扫
                    Log.debug("Scan", "扫描期间切换了桌面，丢弃本次结果")
                    let showAt = anchor ?? self.queuedShowAnchor
                    self.queuedShowAnchor = nil
                    self.scan(showAt: showAt)
                    return
                }
                await self.handleScan(result, showAt: anchor)
                if let queued = self.queuedShowAnchor {
                    self.queuedShowAnchor = nil
                    self.scan(showAt: queued)
                }
            }
        }
    }

    private func handleScan(_ result: MenuBarScanner.Result, showAt anchor: NSRect?) async {
        // 菜单栏收起时看不出谁被挤掉，沿用上一次菜单栏显示时的结果，也不检查本软件图标
        if result.menuBarHidden {
            Log.debug("Scan", "菜单栏已收起，忽略本次扫描")
            if let anchor { dropdown.show(items: hiddenItems, images: images, anchor: anchor) }
            return
        }
        let oldHidden = Set(hiddenItems.map(\.windowID))
        if result.ownWindowID == nil {
            Log.warn("Scan", "没认出本软件图标 ownFrame=\(ownFrameTopLeft.map { "\($0)" } ?? "nil")")
        }
        // 不沿用上一次的编号：进出全屏后旧编号可能指向已经离开屏幕的旧窗口
        ownWindowID = result.ownWindowID
        items = result.items
        let hidden = hiddenItems
        let newHidden = Set(hidden.map(\.windowID))
        if newHidden != oldHidden {
            Log.info("Scan", "图标 \(items.count) 个，被挤掉 \(hidden.count) 个: \(hidden.map(\.displayName))")
        }
        checkOwnVisibility()

        // 先截新出现的
        let newOnes = hidden.filter { images[$0.windowID] == nil }
        if !newOnes.isEmpty {
            let captured = await ItemImages.capture(newOnes)
            images.merge(captured) { _, new in new }
        }
        images = images.filter { newHidden.contains($0.key) }
        if let anchor {
            dropdown.show(items: hiddenItems, images: images, anchor: anchor)
        } else {
            dropdown.update(items: hiddenItems, images: images)
        }

        // 列表打开时，其余图标弹出后再重截，不拖慢弹出
        let newIDs = Set(newOnes.map(\.windowID))
        let toRefresh = anchor == nil ? [] : hidden.filter { !newIDs.contains($0.windowID) }
        if !toRefresh.isEmpty {
            let captured = await ItemImages.capture(toRefresh)
            images.merge(captured) { _, new in new }
            dropdown.update(items: hiddenItems, images: images)
        }
    }

    /// 本软件图标自己被挤掉了就提醒一次（连续两次扫描都看不到才算，避免挪动图标时的瞬间误判）
    private func checkOwnVisibility() {
        guard let own = ownWindowID, Date() >= ownCheckPausedUntil else {
            ownHiddenCount = 0
            return
        }
        if MenuBarScanner.isWindowVisible(own) {
            ownHiddenCount = 0
            return
        }
        ownHiddenCount += 1
        guard ownHiddenCount >= 2, !warnedOwnHidden else { return }
        warnedOwnHidden = true
        Log.warn("App", "本软件图标被挤掉了")
        let alert = NSAlert()
        alert.messageText = "MenuBarManager 的图标被挤掉了"
        alert.informativeText = "菜单栏放不下时，本软件的图标也会被系统藏起来，这样就点不到了。\n请按住 ⌘ 键，把本软件图标拖到菜单栏最右边（靠近控制中心的位置）。"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
