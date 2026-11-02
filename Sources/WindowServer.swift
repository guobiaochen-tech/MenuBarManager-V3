import AppKit
import CoreGraphics

// MARK: - 窗口服务器私有接口
// 苹果没有公开"列出菜单栏图标窗口"的接口，下面几个是 SkyLight 框架里的私有函数，
// 同类软件（Ice、Bartender 等）都靠它们。签名来自社区长期逆向，macOS 14~26 可用。

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(_ cid: CGSConnectionID, _ targetCID: CGSConnectionID, _ outCount: inout Int32) -> CGError

@_silgen_name("CGSGetOnScreenWindowCount")
private func CGSGetOnScreenWindowCount(_ cid: CGSConnectionID, _ targetCID: CGSConnectionID, _ outCount: inout Int32) -> CGError

@_silgen_name("CGSGetOnScreenWindowList")
private func CGSGetOnScreenWindowList(
    _ cid: CGSConnectionID, _ targetCID: CGSConnectionID,
    _ count: Int32, _ list: UnsafeMutablePointer<CGWindowID>, _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID, _ targetCID: CGSConnectionID,
    _ count: Int32, _ list: UnsafeMutablePointer<CGWindowID>, _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
private func CGSGetScreenRectForWindow(_ cid: CGSConnectionID, _ wid: CGWindowID, _ outRect: inout CGRect) -> CGError

@_silgen_name("CGSGetWindowLevel")
private func CGSGetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ outLevel: inout CGWindowLevel) -> CGError

enum WindowServer {
    private static let cid = CGSMainConnectionID()

    /// 所有菜单栏图标窗口（不含左侧的 app 菜单本身），包括被挤掉的
    static func menuBarItemWindowIDs() -> [CGWindowID] {
        var total: Int32 = 0
        guard CGSGetWindowCount(cid, 0, &total) == .success, total > 0 else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(total))
        var count: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(cid, 0, total, &list, &count) == .success else {
            Log.error("WS", "CGSGetProcessMenuBarWindowList 失败")
            return []
        }
        let mainMenuLevel = CGWindowLevelForKey(.mainMenuWindow)
        return list[..<Int(count)].filter { level(of: $0) != mainMenuLevel }
    }

    /// 当前在屏幕上显示的窗口编号集合
    static func onScreenWindowIDs() -> Set<CGWindowID> {
        var total: Int32 = 0
        guard CGSGetOnScreenWindowCount(cid, 0, &total) == .success, total > 0 else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(total))
        var count: Int32 = 0
        guard CGSGetOnScreenWindowList(cid, 0, total, &list, &count) == .success else { return [] }
        return Set(list[..<Int(count)])
    }

    /// 窗口在屏幕上的位置（左上角为原点的全局坐标）
    static func frame(of wid: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        guard CGSGetScreenRectForWindow(cid, wid, &rect) == .success else { return nil }
        return rect
    }

    static func level(of wid: CGWindowID) -> CGWindowLevel? {
        var level: CGWindowLevel = 0
        guard CGSGetWindowLevel(cid, wid, &level) == .success else { return nil }
        return level
    }
}

// MARK: - 屏幕几何

extension NSScreen {
    /// 菜单栏所在的主屏（坐标原点所在的那块屏）
    static var menuBarScreen: NSScreen? {
        screens.first { $0.frame.origin == .zero } ?? screens.first
    }
}

/// 判断图标看不看得见需要的屏幕信息。界面接口只能在主线程取，取好后可以交给后台线程用。
struct MenuBarGeometry {
    /// 主屏范围，左上角原点
    let bounds: CGRect
    /// 刘海区域，左上角原点；没有刘海为 nil
    let notch: CGRect?

    @MainActor
    static func current() -> MenuBarGeometry? {
        guard let screen = NSScreen.menuBarScreen else { return nil }
        var notch: CGRect?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGRect(x: left.maxX, y: 0, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        }
        return MenuBarGeometry(bounds: CGRect(origin: .zero, size: screen.frame.size), notch: notch)
    }

    /// 在屏幕上、不被刘海挡、不被前台 app 的菜单盖住，才算看得见
    func isVisible(_ frame: CGRect, onScreen: Bool, appMenuMaxX: CGFloat?) -> Bool {
        // 最右边的时钟窗口会比屏幕宽出 1~2pt，留点余量
        guard onScreen, bounds.insetBy(dx: -4, dy: -4).contains(frame) else { return false }
        if let notch, notch.intersects(frame) { return false }
        if let appMenuMaxX, frame.minX < appMenuMaxX { return false }
        return true
    }
}
