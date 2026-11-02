import AppKit

final class BreakAlertWindow: NSObject, NSWindowDelegate {

    enum Mode {
        case initial          // 工作时长到，初次提醒
        case restingViolation // 休息中检测到键鼠活动
    }

    private var panel: NSPanel?
    private var alarmSound: NSSound?
    var onClose: (() -> Void)?

    func show(workLimitMin: Int, restLimitMin: Int, mode: Mode = .initial) {
        ensurePanel()
        guard let panel = panel, let screen = NSScreen.main else { return }
        let size = CGSize(width: 340, height: 180)
        let frame = NSRect(
            x: screen.frame.maxX - size.width - 16,
            y: screen.frame.maxY - size.height - 28,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        panel.contentView = makeContent(frame: frame, workLimitMin: workLimitMin, restLimitMin: restLimitMin, mode: mode)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startAlarm()
        NSApp.requestUserAttention(.criticalRequest)
    }

    func hide() {
        stopAlarm()
        // 只 orderOut 会留下一个常驻的浮动窗（level=.statusBar + canJoinAllSpaces），之后新建同层浮动窗时可能把残影带出来。
        // 这里彻底销毁：移出屏幕 → 断 delegate → 清 contentView → 释放，下次 show() 由 ensurePanel() 重建。
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel?.contentView = nil
        panel = nil
    }

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        panel = p
    }

    private func makeContent(frame: NSRect, workLimitMin: Int, restLimitMin: Int, mode: Mode) -> NSView {
        let container = NSVisualEffectView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.blendingMode = .behindWindow
        container.material = .popover

        let title: NSTextField
        let subtitle: NSTextField

        switch mode {
        case .initial:
            title = NSTextField(labelWithString: "该休息了!")
            title.font = .systemFont(ofSize: 24, weight: .bold)
            title.textColor = .systemRed

            subtitle = NSTextField(labelWithString: "你已经连续使用 \(workLimitMin) 分钟，请离开屏幕至少 \(restLimitMin) 分钟")
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = .secondaryLabelColor
        case .restingViolation:
            title = NSTextField(labelWithString: "请离开屏幕!")
            title.font = .systemFont(ofSize: 24, weight: .bold)
            title.textColor = .systemOrange

            subtitle = NSTextField(labelWithString: "休息期间检测到键鼠活动，请保持静止至少 10 秒后开始计时")
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = .secondaryLabelColor
        }

        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        let btn = NSButton(title: "我知道了", target: self, action: #selector(closeClicked))
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        btn.keyEquivalent = "\r"
        container.addSubview(btn)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            btn.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            btn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        return container
    }

    @objc private func closeClicked() {
        hide()
        onClose?()
    }

    private func startAlarm() {
        if alarmSound == nil {
            for name in ["Sosumi", "Basso", "Funk", "Glass", "Ping"] {
                if let s = NSSound(named: NSSound.Name(name)) {
                    alarmSound = s
                    break
                }
            }
        }
        alarmSound?.loops = true
        alarmSound?.play()
    }

    private func stopAlarm() {
        alarmSound?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        stopAlarm()
    }
}
