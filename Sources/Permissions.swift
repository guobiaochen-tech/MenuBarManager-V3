import AppKit
import ScreenCaptureKit

enum Permissions {
    /// 辅助功能：读图标归属、发模拟鼠标事件
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// 屏幕录制：截图标画面
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func requestScreenRecording() {
        // 调一次截屏接口，系统才会把本软件放进「屏幕录制」列表
        SCShareableContent.getWithCompletionHandler { _, _ in }
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    /// 重新启动本软件。屏幕录制权限只有重启后才生效。
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        do {
            try task.run()
        } catch {
            Log.error("Perm", "重启失败: \(error)")
            return
        }
        NSApp.terminate(nil)
    }
}

/// 权限没给全时弹出的引导窗：两行（辅助功能、屏幕录制），每秒刷新一次状态
@MainActor
final class PermissionGuideWindow: NSWindow {
    var onAllGranted: (() -> Void)?
    private var timer: Timer?
    private let axStatus = NSTextField(labelWithString: "")
    private let srStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: "去开启", target: nil, action: nil)
    private let srButton = NSButton(title: "去开启", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let relaunchButton = NSButton(title: "重新启动", target: nil, action: nil)
    /// 屏幕录制在系统设置里打勾后，本进程要重启才拿得到；记下用户点过开启
    private var askedScreenRecording = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "MenuBarManager 需要两项权限"
        isReleasedWhenClosed = false
        center()

        axButton.target = self
        axButton.action = #selector(openAX)
        srButton.target = self
        srButton.action = #selector(openSR)
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch)
        relaunchButton.isHidden = true
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [
            row("辅助功能", "用来识别图标属于哪个软件、模拟点击", axStatus, axButton),
            row("屏幕录制", "用来截取被挤掉的图标的样子", srStatus, srButton),
            hint,
            relaunchButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func row(_ name: String, _ desc: String, _ status: NSTextField, _ button: NSButton) -> NSView {
        let title = NSTextField(labelWithString: name)
        title.font = .boldSystemFont(ofSize: 13)
        let detail = NSTextField(labelWithString: desc)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let r = NSStackView(views: [texts, NSView(), status, button])
        r.spacing = 10
        r.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return r
    }

    private func refresh() {
        let ax = Permissions.accessibility
        let sr = Permissions.screenRecording
        axStatus.stringValue = ax ? "✅ 已开启" : "未开启"
        srStatus.stringValue = sr ? "✅ 已开启" : "未开启"
        axButton.isHidden = ax
        srButton.isHidden = sr
        if !sr && askedScreenRecording {
            hint.stringValue = "在系统设置里打开「屏幕录制」后，需要重新启动本软件才生效。"
            relaunchButton.isHidden = false
        } else {
            hint.stringValue = "在系统设置 → 隐私与安全性 里找到 MenuBarManager-V3 并打开开关。"
            relaunchButton.isHidden = true
        }
        if ax && sr {
            timer?.invalidate()
            timer = nil
            orderOut(nil)
            onAllGranted?()
            onAllGranted = nil
        }
    }

    /// 权限没给全就关掉引导窗 = 不用了，直接退出，免得留一个没有图标的后台进程
    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
        if onAllGranted != nil {
            Log.info("Perm", "权限未给全时关闭引导窗，退出")
            NSApp.terminate(nil)
        }
    }

    @objc private func openAX() { Permissions.requestAccessibility() }

    @objc private func openSR() {
        askedScreenRecording = true
        Permissions.requestScreenRecording()
    }

    @objc private func relaunch() { Permissions.relaunch() }
}
