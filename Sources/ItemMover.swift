import AppKit

/// 把被挤掉的真实图标移到本软件图标左侧，并留在新位置。
/// 移动通过模拟 ⌘ 拖动完成；后续由用户直接操作菜单栏上的图标。
@MainActor
final class ItemMover {
    var ownWindowID: () -> CGWindowID? = { nil }
    private(set) var isBusy = false
    private let moveEventField = CGEventField(rawValue: 0x33)!

    /// 只移动，不点击对方图标，也不记录或恢复原位置。
    func moveToMenuBar(_ item: MenuBarItem) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        Log.info("Move", "移到菜单栏 \(item.displayName) wid=\(item.windowID)")

        guard await waitForUserInputIdle() else { return false }
        guard let own = ownWindowID(), own != item.windowID,
              MenuBarScanner.isWindowVisible(own) else {
            Log.error("Move", "本软件图标不可见或窗口编号未知，无法移动")
            return false
        }
        permitLocalEvents()
        guard await move(item.windowID, pid: item.ownerPID, leftOf: own) else {
            Log.error("Move", "移动 \(item.displayName) 失败")
            return false
        }
        // 系统可能需要短暂时间完成菜单栏布局。
        for _ in 0..<10 {
            if MenuBarScanner.isWindowVisible(item.windowID) {
                Log.info("Move", "已移到菜单栏并保留位置 \(item.displayName)")
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Log.warn("Move", "\(item.displayName) 已移动，但目标位置仍不可见")
        return false
    }

    // MARK: - 挪动（模拟 ⌘ 拖动）

    private func move(_ wid: CGWindowID, pid: pid_t, leftOf targetID: CGWindowID) async -> Bool {
        let cursor = currentCursorLocation()
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            CGDisplayShowCursor(CGMainDisplayID())
        }

        for attempt in 1...6 {
            guard let itemFrame = WindowServer.frame(of: wid),
                  let targetFrame = WindowServer.frame(of: targetID) else {
                Log.warn("Move", "挪动时拿不到窗口位置 wid=\(wid)")
                return false
            }
            if isInPlace(itemFrame, targetFrame) {
                Log.debug("Move", "wid=\(wid) 已在目标位置（第 \(attempt) 次检查）")
                return true
            }

            let (start, end) = dragPoints(item: itemFrame, target: targetFrame)
            guard let down = makeMoveEvent(.leftMouseDown, at: start, windowID: wid, flags: .maskCommand),
                  let up = makeMoveEvent(.leftMouseUp, at: end, windowID: targetID, flags: []) else {
                Log.error("Move", "创建鼠标事件失败")
                return false
            }

            // 按下：发给窗口服务器，也直接发给图标所属进程（macOS 26 图标窗口归控制中心，只发一边不生效）
            postForMove(down, pid: pid)
            _ = await waitForOriginChange(wid, from: itemFrame.origin, timeout: .milliseconds(150))
            let movedOrigin = WindowServer.frame(of: wid)?.origin ?? itemFrame.origin
            // 松开发两次：只发一次偶尔会让图标卡在"拖动中"状态
            postForMove(up, pid: pid)
            postForMove(up, pid: pid)
            _ = await waitForOriginChange(wid, from: movedOrigin, timeout: .milliseconds(150))

            if let f = WindowServer.frame(of: wid), let t = WindowServer.frame(of: targetID), isInPlace(f, t) {
                Log.debug("Move", "wid=\(wid) 挪动成功（第 \(attempt) 次）")
                return true
            }
            Log.debug("Move", "wid=\(wid) 第 \(attempt) 次挪动未到位 目标左邻=\(targetID) 起点=\(start) 终点=\(end) 挪前=\(itemFrame) 挪后=\(WindowServer.frame(of: wid).map { "\($0)" } ?? "nil") 目标窗口=\(WindowServer.frame(of: targetID).map { "\($0)" } ?? "nil")")
            try? await Task.sleep(for: .milliseconds(60))
        }
        return false
    }

    private func isInPlace(_ item: CGRect, _ target: CGRect) -> Bool {
        abs(item.maxX - target.minX) <= 1
    }

    /// 保留原有的 ⌘ 拖动方式，只支持放到本软件图标左侧。
    private func dragPoints(item: CGRect, target: CGRect) -> (CGPoint, CGPoint) {
        let edge = CGPoint(x: target.minX, y: target.minY)
        if item.maxX <= target.minX {
            return (edge, CGPoint(x: edge.x - item.width, y: edge.y))
        }
        return (CGPoint(x: edge.x - 1, y: edge.y), edge)
    }

    private func waitForOriginChange(_ wid: CGWindowID, from origin: CGPoint, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let f = WindowServer.frame(of: wid), f.origin != origin { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: - 事件工具

    private func makeMoveEvent(
        _ type: CGEventType, at point: CGPoint,
        windowID: CGWindowID, flags: CGEventFlags
    ) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                              mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1...Int64.max))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        e.setIntegerValueField(moveEventField, value: Int64(windowID))
        return e
    }

    private func postForMove(_ e: CGEvent, pid: pid_t) {
        e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        e.post(tap: .cgSessionEventTap)
        e.postToPid(pid)
    }

    /// 系统默认在程序发出模拟事件后短暂屏蔽真实键鼠，这里关掉屏蔽，免得用户的鼠标卡一下
    private func permitLocalEvents() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let all: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        src.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateRemoteMouseDrag)
        src.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateSuppressionInterval)
        src.localEventsSuppressionInterval = 0
    }

    /// 等用户松开鼠标和修饰键（最多 2 秒），不然模拟的 ⌘ 拖动会和用户的真实操作打架
    private func waitForUserInputIdle() async -> Bool {
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        for _ in 0..<40 {
            if NSEvent.pressedMouseButtons == 0 && NSEvent.modifierFlags.isDisjoint(with: modifiers) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Log.warn("Move", "等用户松开按键超时，取消移动")
        return false
    }

    private func currentCursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

}
