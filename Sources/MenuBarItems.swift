import AppKit
import ApplicationServices

/// 菜单栏上的一个图标
struct MenuBarItem {
    let windowID: CGWindowID
    /// 左上角原点的全局坐标
    let frame: CGRect
    /// 用户能不能在菜单栏上看到它
    let isVisible: Bool
    /// 创建这个图标的 app（macOS 26 起图标窗口都归控制中心，真实归属要靠辅助功能接口反查）
    let ownerPID: pid_t
    let appName: String
    /// 辅助功能接口给的描述，系统图标靠它区分（如「Wi‑Fi」「电池」）
    let detail: String

    var displayName: String {
        if detail.isEmpty || detail == appName { return appName }
        return "\(appName) · \(detail)"
    }
}

/// 扫描菜单栏图标。辅助功能接口调用会阻塞，所以只在后台线程调用 scan()。
final class MenuBarScanner: @unchecked Sendable {  // 内部状态都在 lock 保护下
    private struct Owner {
        let pid: pid_t
        let appName: String
        let detail: String
    }

    /// 窗口编号 -> 归属。图标窗口在其生命周期内编号不变，缓存后不必每次都全量反查
    private var ownerCache: [CGWindowID: Owner] = [:]
    private let lock = NSLock()

    struct Result {
        /// 除本软件以外的所有图标，从左到右
        let items: [MenuBarItem]
        /// 本软件自己图标的窗口编号
        let ownWindowID: CGWindowID?
        /// 整条菜单栏被收起了（应用全屏、或设置了自动隐藏菜单栏），这时图标都不在屏幕上，不代表被挤掉
        let menuBarHidden: Bool
    }

    /// 扫描所有图标。ownFrame：本软件图标按钮所在窗口的位置（左上角原点），用来认出自己。
    /// 不能直接用 NSWindow.windowNumber：macOS 26 上它不是窗口服务器的编号。
    func scan(ownFrame: CGRect?, geometry: MenuBarGeometry) -> Result {
        lock.lock()
        defer { lock.unlock() }

        let ids = WindowServer.menuBarItemWindowIDs()
        let onScreen = WindowServer.onScreenWindowIDs()
        let appMenuMaxX = Self.frontAppMenuMaxX()
        Log.debug("Scan", "屏幕=\(geometry.bounds) 刘海=\(geometry.notch.map { "\($0)" } ?? "无") 前台菜单右边界=\(appMenuMaxX.map { "\($0)" } ?? "无")")

        var frames: [CGWindowID: CGRect] = [:]
        for id in ids {
            if let f = WindowServer.frame(of: id), f.width > 0, f.width < 500 {
                frames[id] = f
            }
        }

        // 缓存里没有的窗口才去全量反查归属
        let unknown = frames.keys.filter { ownerCache[$0] == nil }
        if !unknown.isEmpty {
            resolveOwners(for: unknown, frames: frames)
        }
        // 清掉已经不存在的窗口
        ownerCache = ownerCache.filter { frames[$0.key] != nil }

        var items: [MenuBarItem] = []
        var ownWindowID: CGWindowID?
        for (id, f) in frames {
            if let ownFrame, abs(f.midX - ownFrame.midX) <= 2, abs(f.midY - ownFrame.midY) <= 2 {
                ownWindowID = id
                continue
            }
            guard let owner = ownerCache[id] else {
                Log.debug("Scan", "丢弃无归属窗口 wid=\(id) frame=\(f)")
                continue
            }
            if owner.pid == getpid() { continue }

            let visible = geometry.isVisible(f, onScreen: onScreen.contains(id), appMenuMaxX: appMenuMaxX)
            Log.debug("Scan", "  wid=\(id) \(owner.appName)·\(owner.detail) frame=\(f) onScreen=\(onScreen.contains(id)) visible=\(visible)")
            items.append(MenuBarItem(
                windowID: id, frame: f, isVisible: visible,
                ownerPID: owner.pid, appName: owner.appName, detail: owner.detail
            ))
        }
        items.sort { $0.frame.minX < $1.frame.minX }
        // 时钟这类最右边的系统图标不会被挤掉，所有图标同时不在屏幕上只可能是菜单栏整体收起了
        let menuBarHidden = !frames.isEmpty && !frames.keys.contains(where: onScreen.contains)
        return Result(items: items, ownWindowID: ownWindowID, menuBarHidden: menuBarHidden)
    }

    /// 判断某个窗口（如本软件自己的图标）此刻用户能否看到
    @MainActor
    static func isWindowVisible(_ wid: CGWindowID) -> Bool {
        guard let geometry = MenuBarGeometry.current(), let f = WindowServer.frame(of: wid) else { return false }
        return geometry.isVisible(f, onScreen: WindowServer.onScreenWindowIDs().contains(wid), appMenuMaxX: frontAppMenuMaxX())
    }

    // MARK: - 归属反查
    // 每个 app 的菜单栏图标都挂在它自己的 AXExtrasMenuBar 下，位置和图标窗口完全重合。
    // 按中心点精确匹配（误差 ≤ 2pt，只是为了容忍取整），不再像 V2 那样只比横坐标、容差 30pt。

    private func resolveOwners(for windowIDs: [CGWindowID], frames: [CGWindowID: CGRect]) {
        let started = Date()
        var pending = Set(windowIDs)
        for app in NSWorkspace.shared.runningApplications where !pending.isEmpty {
            guard app.activationPolicy != .prohibited, !app.isTerminated else { continue }
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            guard let bar: AXUIElement = AX.attribute(axApp, "AXExtrasMenuBar") else { continue }
            let children: [AXUIElement] = AX.attribute(bar, kAXChildrenAttribute) ?? []
            for child in children {
                guard let cf = AX.frame(of: child) else { continue }
                let match = pending.first { id in
                    guard let wf = frames[id] else { return false }
                    return abs(wf.midX - cf.midX) <= 2 && abs(wf.midY - cf.midY) <= 2
                }
                guard let id = match else { continue }
                let desc: String = AX.attribute(child, kAXDescriptionAttribute) ?? ""
                let title: String = AX.attribute(child, kAXTitleAttribute) ?? ""
                ownerCache[id] = Owner(
                    pid: pid,
                    appName: app.localizedName ?? app.bundleIdentifier ?? "未知",
                    detail: desc.isEmpty ? title : desc
                )
                pending.remove(id)
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.debug("Scan", "反查归属 \(windowIDs.count) 个，未匹配 \(pending.count) 个，耗时 \(ms)ms")
    }

    /// 最前面那个 app 的菜单（「文件」「编辑」…）右边界。被它盖住的图标也算看不到。
    private static func frontAppMenuMaxX() -> CGFloat? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let bar: AXUIElement = AX.attribute(axApp, kAXMenuBarAttribute) else { return nil }
        let children: [AXUIElement] = AX.attribute(bar, kAXChildrenAttribute) ?? []
        let maxX = children.compactMap { AX.frame(of: $0)?.maxX }.max()
        return maxX
    }
}

// MARK: - 辅助功能接口小工具

enum AX {
    static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        }
        return value as? T
    }

    /// 元素位置，左上角原点的全局坐标（和窗口服务器坐标一致）
    static func frame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}
