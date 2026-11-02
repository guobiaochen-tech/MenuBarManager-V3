import AppKit
import ScreenCaptureKit

/// 用 ScreenCaptureKit 截取图标窗口的画面。被挤掉的图标窗口不在屏幕上也能截到，不用移动它。
enum ItemImages {
    /// 返回 窗口编号 -> 图片，截不到的不在结果里
    @MainActor
    static func capture(_ items: [MenuBarItem]) async -> [CGWindowID: NSImage] {
        guard !items.isEmpty else { return [:] }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            Log.error("Image", "拿不到窗口列表（多半是屏幕录制权限没生效）: \(error)")
            return [:]
        }
        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let scale = NSScreen.menuBarScreen?.backingScaleFactor ?? 2

        var result: [CGWindowID: NSImage] = [:]
        for item in items {
            guard let window = windows[item.windowID] else {
                Log.debug("Image", "截图找不到窗口 \(item.displayName) wid=\(item.windowID)")
                continue
            }
            let config = SCStreamConfiguration()
            config.width = Int(item.frame.width * scale)
            config.height = Int(item.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            do {
                let cg = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: config
                )
                let trimmed = trimTransparentSides(cg)
                result[item.windowID] = NSImage(cgImage: trimmed,
                                                size: NSSize(width: CGFloat(trimmed.width) / scale, height: item.frame.height))
            } catch {
                Log.warn("Image", "截图失败 \(item.displayName) wid=\(item.windowID): \(error)")
            }
        }
        return result
    }

    /// 去掉左右两边的透明列（菜单栏图标自带的留白）。高度不裁，所有图标在列表里缩放比例保持一致。
    /// 整张都透明或背景不透明时原样返回。
    private static func trimTransparentSides(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }

        // 留一点余量，几乎看不见的抗锯齿杂点不算内容
        func hasContent(_ x: Int) -> Bool {
            (0..<height).contains { alpha[$0 * width + x] > 8 }
        }
        guard let left = (0..<width).first(where: hasContent),
              let right = (0..<width).last(where: hasContent) else { return image }
        return image.cropping(to: CGRect(x: left, y: 0, width: right - left + 1, height: height)) ?? image
    }
}
