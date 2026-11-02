import AppKit

/// 点本软件图标后弹出的列表：点击一行，将对应的真实图标移到菜单栏。
@MainActor
final class DropdownPanel: NSObject {
    var onMove: ((MenuBarItem) -> Void)?
    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?
    /// 点了用眼提醒那一行，参数是这一行，用来在它下面弹出档位菜单
    var onReminderClick: ((NSView) -> Void)?
    var reminderStatus: () -> String = { "" }

    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var items: [MenuBarItem] = []
    private var images: [CGWindowID: NSImage] = [:]
    private var anchor: NSRect = .zero
    private var reminderLabel: NSTextField?
    private var reminderTimer: Timer?

    var isShown: Bool { panel != nil }

    /// anchor：本软件图标在屏幕上的位置（左下角原点）
    func show(items: [MenuBarItem], images: [CGWindowID: NSImage], anchor: NSRect) {
        self.anchor = anchor
        self.items = items
        self.images = images
        if panel == nil {
            panel = makePanel()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshReminder() }
            }
            reminderTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
        rebuild()
        panel?.orderFrontRegardless()
    }

    /// 扫描或截图有了新结果时刷新内容（列表开着才有效）
    func update(items: [MenuBarItem], images: [CGWindowID: NSImage]) {
        guard isShown else { return }
        self.items = items
        self.images = images
        rebuild()
    }

    func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        reminderTimer?.invalidate()
        reminderTimer = nil
        reminderLabel = nil
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        onClose?()
    }

    // MARK: - 布局

    private let rowHeight: CGFloat = 30
    private let padding: CGFloat = 6
    private let width: CGFloat = 260

    private func quitClicked() {
        close()
        onQuit?()
    }

    private func refreshReminder() {
        reminderLabel?.stringValue = reminderStatus()
    }

    private func makeSeparator(y: CGFloat) -> NSBox {
        let separator = NSBox(frame: NSRect(x: padding, y: y, width: width - padding * 2, height: 1))
        separator.boxType = .separator
        return separator
    }

    /// 系统符号图标，大小和菜单文字相配
    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }

    private func rebuild() {
        guard let panel else { return }
        let rows: [NSView]
        if items.isEmpty {
            let label = NSTextField(labelWithString: "没有被挤掉的图标")
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            rows = [label]
        } else {
            rows = items.map { item in
                let image = images[item.windowID]
                    ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)
                let row = MenuRowView(title: item.displayName, image: image)
                row.toolTip = "移到本软件图标左侧，并留在菜单栏"
                row.setAccessibilityHelp(row.toolTip)
                row.onClick = { [weak self] in
                    self?.close()
                    self?.onMove?(item)
                }
                return row
            }
        }

        // 底部从下往上：退出、分隔线、用眼提醒、分隔线，分隔线上下各留 padding
        let footerHeight = rowHeight * 2 + padding * 4 + 2
        let height = CGFloat(rows.count) * rowHeight + padding * 2 + footerHeight
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        for (i, row) in rows.enumerated() {
            // 从上往下排
            row.frame = NSRect(x: padding, y: height - padding - CGFloat(i + 1) * rowHeight,
                               width: width - padding * 2, height: rowHeight)
            background.addSubview(row)
        }

        let quitButton = MenuRowView(title: "退出", image: Self.symbol("power"))
        quitButton.frame = NSRect(x: padding, y: padding, width: width - padding * 2, height: rowHeight)
        quitButton.onClick = { [weak self] in self?.quitClicked() }
        background.addSubview(quitButton)

        let lowerSeparatorY = quitButton.frame.maxY + padding
        background.addSubview(makeSeparator(y: lowerSeparatorY))

        let reminderRow = MenuRowView(title: "用眼提醒", image: Self.symbol("eye"), detail: reminderStatus())
        reminderRow.frame = NSRect(x: padding, y: lowerSeparatorY + 1 + padding,
                                   width: width - padding * 2, height: rowHeight)
        reminderRow.onClick = { [weak self, weak reminderRow] in
            guard let self, let reminderRow else { return }
            // 弹出的菜单会一直等到选完或取消才返回，返回后马上刷新计时
            self.onReminderClick?(reminderRow)
            self.refreshReminder()
        }
        background.addSubview(reminderRow)
        reminderLabel = reminderRow.detailLabel

        background.addSubview(makeSeparator(y: reminderRow.frame.maxY + padding))
        panel.contentView = background

        // 右边对齐本软件图标，放在菜单栏正下方，不超出屏幕
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.menuBarScreen
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.maxX - width
        x = min(max(x, visible.minX + 4), visible.maxX - width - 4)
        let y = anchor.minY - height - 4
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

/// 图标项、用眼提醒和退出共用的一行：左边图标位宽度一致，文字从同一列开始。
/// 透明背景，设了 onClick 才有悬停高亮，避免系统按钮自带的底色。
private final class MenuRowView: NSView {
    var onClick: (() -> Void)?
    /// 行右侧的灰色说明文字（用眼提醒的计时），没有则为 nil
    private(set) var detailLabel: NSTextField?
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String, image: NSImage? = nil, detail: String? = nil) {
        super.init(frame: .zero)

        let iconView = NSImageView()
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: image == nil ? 0 : 32),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: image == nil ? 0 : 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .right
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(detailLabel)
            NSLayoutConstraint.activate([
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -8),
            ])
            self.detailLabel = detailLabel
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6).isActive = true
        }

        setAccessibilityLabel(detail.map { "\(title) \($0)" } ?? title)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("不支持从界面文件加载") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
    override func rightMouseUp(with event: NSEvent) {}
    // 按下时什么都不做，等松开再触发，和系统菜单手感一致；也避免触发时鼠标键还按着
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, onClick != nil else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}
