import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AudioToolbox
import Carbon

// MARK: - NDJSON 契约模型

struct AppshotReadyFrame: Encodable {
    let type: String = "ready"
    let version: Int = 1
    let pid: pid_t
    let bundleId: String
}

struct AppshotSuccessResult: Encodable {
    let type: String = "appshot"
    let ok: Bool = true
    let platform: String = "darwin"
    let appName: String
    let windowTitle: String?
    let windowId: CGWindowID
    let width: Int
    let height: Int
    let mimeType: String = "image/png"
    let imagePath: String
    let timestamp: Int64
    /// 捕获类型：window（前台窗口，默认）或 region（⌘⇧A 框选区域）
    let captureKind: String
}

struct AppshotErrorResult: Encodable {
    let type: String = "error"
    let ok: Bool = false
    let platform: String = "darwin"
    let code: String
    let message: String
}

struct WindowInfo: Encodable {
    let windowId: CGWindowID
    let appName: String
    let pid: pid_t
    let title: String?
    let frame: [String: Double]
    let isOnScreen: Bool
    let layer: Int

    enum CodingKeys: String, CodingKey {
        case windowId, appName, pid, title, frame, isOnScreen, layer
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowId, forKey: .windowId)
        try container.encode(appName, forKey: .appName)
        try container.encode(pid, forKey: .pid)
        if let title = title {
            try container.encode(title, forKey: .title)
        } else {
            try container.encodeNil(forKey: .title)
        }
        try container.encode(frame, forKey: .frame)
        try container.encode(isOnScreen, forKey: .isOnScreen)
        try container.encode(layer, forKey: .layer)
    }
}

// MARK: - 动态配置模型 (Inbound JSON)

struct ConfigPayload: Decodable {
    let shortcutMode: String?
    let soundEnabled: Bool?
    let animationEnabled: Bool?
    /// 是否启用 ⌘⇧A 区域框选（默认启用；与 Chrome 等应用的「搜索标签页」冲突时可关闭）
    let regionShortcutEnabled: Bool?
}

struct InboundCommand: Decodable {
    let type: String
    let payload: ConfigPayload?
}

final class AppConfig {
    static let shared = AppConfig()

    var soundEnabled: Bool = true
    var animationEnabled: Bool = true
    var shortcutMode: String = "dual-cmd" // "dual-cmd", "double-cmd", "dual-option", "double-option", "dual-control", "double-control", "cmd-option"
    var regionShortcutEnabled: Bool = true

    private init() {}

    func update(with payload: ConfigPayload) {
        if let sound = payload.soundEnabled {
            self.soundEnabled = sound
        }
        if let anim = payload.animationEnabled {
            self.animationEnabled = anim
        }
        if let shortcut = payload.shortcutMode {
            self.shortcutMode = shortcut
        }
        if let region = payload.regionShortcutEnabled {
            self.regionShortcutEnabled = region
        }
    }
}

func outputJSON<T: Encodable>(_ object: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(object),
       let jsonString = String(data: data, encoding: .utf8) {
        print(jsonString)
        fflush(stdout)
    }
}

func outputError(code: String, message: String, exitCode: Int32 = 1) -> Never {
    outputJSON(AppshotErrorResult(code: code, message: message))
    exit(exitCode)
}

func checkScreenCapturePermission() -> Bool {
    if #available(macOS 10.15, *) {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }
    return true
}

func saveCGImageAsPNG(image: CGImage, destinationURL: URL) -> (Bool, String) {
    let parentDir = destinationURL.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    } catch {
        return (false, "createDirectory failed: \(error.localizedDescription)")
    }

    let typeIdentifier = UTType.png.identifier as CFString
    if let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, typeIdentifier, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            return (true, "")
        }
    }

    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    if let pngData = rep.representation(using: .png, properties: [:]) {
        do {
            try pngData.write(to: destinationURL, options: .atomic)
            return (true, "")
        } catch {
            return (false, "pngData write failed: \(error.localizedDescription)")
        }
    }

    return (false, "Both CGImageDestination and NSBitmapImageRep failed for image \(image.width)x\(image.height)")
}

func fetchShareableContent() throws -> SCShareableContent {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<SCShareableContent, Error>?

    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        if let error = error {
            result = .failure(error)
        } else if let content = content {
            result = .success(content)
        } else {
            result = .failure(NSError(domain: "Appshot", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error fetching shareable content"]))
        }
        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .distantFuture)
    return try result!.get()
}

func captureWindow(filter: SCContentFilter, config: SCStreamConfiguration) throws -> CGImage {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<CGImage, Error>?

    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
        if let error = error {
            result = .failure(error)
        } else if let image = image {
            result = .success(image)
        } else {
            result = .failure(NSError(domain: "Appshot", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error capturing screenshot"]))
        }
        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .distantFuture)
    return try result!.get()
}

// MARK: - 音效与动画辅助

private let embeddedShutterWavBase64 = "UklGRuRwAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YcBwAAAAAP///wAAAAAAAAAAAAAA//8AAP//AAAAAAAAAAAAAAAAAAAAAP//AAAAAAAAAAAAAP//AAAAAAAAAAAAAAAA//8BAAAA//8BAAAA//8AAP///v/8/wAA/v/+/wAAAAAAAAAAAAAA/v8AAAAAAgACAAIAAAAAAAAAAAAAAAAAAAADAAMAAgABAAEAAAABAAAA//8BAAEAAAD+/wAA//8BAAEAAgACAAQABAAEAAIAAgABAP//AAACAAQABAAFAAYABQAEAAMAAQABAP//AQABAP7/AAABAAIABAAEAAYABwAHAAYAAwAAAP//AQADAAUABgAHAAYABQACAAMABAADAAMAAgAAAP//AAACAAUABwAHAAcABgAFAAUABwAIAAcABQADAAMAAwADAAMAAwADAAMABAAFAAcACAAHAAYABQADAAIABAAFAAYABgAHAAYABQAEAAUABQAEAAIAAAACAAQABgAHAAYABQAEAAQABQAHAAgABwAFAAMABAAGAAgACQAHAAQAAwAEAAQABQAGAAcABwAGAAQAAgADAAQABQAGAAYABQADAAIABAAEAAUABQAEAAQABgAHAAYABQAFAAUAAwABAAIABAAEAAUABwAIAAgABwAFAAMABAAFAAUABQADAAMAAwACAAMABQAHAAYABAABAAIAAwAEAAQABQAHAAYABAAEAAIABAAEAAQABAAEAAQABAACAAIAAQABAAAAAAABAAIAAwADAAIAAAABAAIAAwAEAAMAAwADAAMAAwADAAIAAgABAAAAAAABAAIAAgACAAIAAwADAAMAAwADAAIAAAABAAEAAQAAAAEAAgADAAMAAgAAAAEAAQABAAAA/v8BAAIABAAFAAQAAgAAAP//AQADAAMAAgAAAAEAAgADAAMAAQABAP//AAACAAQAAwABAP//AQACAAIAAgABAP//AAAA/v8AAP7///8BAAEAAQAAAAAAAAAAAAEAAQABAP7/AAAA//8BAAEAAAABAAIAAwACAAAAAAD//wAA/v8AAAEA//8BAAMABAAEAAIAAAD//wABAAEAAAABAAIAAwADAAMAAQAAAAEAAgACAAIAAgABAAAAAQACAAMAAwADAAMAAgAAAAEAAQABAAEAAAABAAIAAQAAAAEAAQACAAIAAgABAAAAAAABAAIAAgABAAAAAAD//wAAAQABAAEAAAD//wEAAQABAP//AQABAP7/AAABAP7/AAD//wAAAQAAAP7/AAABAAIAAgAAAP7/AAAAAAABAAEA/v8AAP7/AQABAP//AAABAP//AQABAAAA/v/+/wEAAgABAAAAAQABAAEAAAAAAP//AAACAAIAAAABAAIAAgABAAAAAQABAAEA/v8AAAEAAQABAAAAAQABAAAAAQAAAAAAAQACAAEAAgACAAEAAAAAAAEAAQAAAP7/AAABAP7/AQABAAAA//8BAAEAAAAAAP7/AQABAAAA//8AAP7/AQABAAAA//8BAAAAAAAA/v8BAAAAAQABAAAA/v/+/wAAAAABAAAAAAD+/wEAAQAAAP7/AAABAP//AQABAAAAAAD+/wAA/v8AAAEAAQAAAAAAAAABAAEAAQABAP7/AAAA//8AAAEAAgABAAAA//8BAAEAAAD//wAA/v8AAAEAAQAAAP//AQABAAAAAQABAAAAAAD//wAA/v8AAAIAAQAAAP7///8AAAEAAQAAAP7/AAABAAEAAQABAAAA/v/9//8BAAEAAAD+/wAA//8BAAEAAQAAAP//AQABAAAA/v/+/wEAAgABAP7/AQABAAAAAAD//wAAAQAAAP//AAABAAEAAAD+/wAAAQAAAP7/AAABAAEA/v/9//8BAAEAAQAAAAAA//8AAAEAAQAAAP7/AAABAP7/AAABAAEAAQAAAAAA//8BAAEAAAAAAP//AQABAAEAAQAAAAAA//8BAAEAAAAAAAEAAAD+/wAA/v8AAP7/AQACAAEAAAD+/wAAAQAAAP7/AAABAAEAAAD//wAA/v8BAAEAAQAAAP//AQAAAAEAAAD//wAA//8BAAEAAQAAAAAAAAD//wAA/v8BAAEAAAD+/wAAAQAAAP//AQABAP7/AAABAAEAAAD//wAA/v8BAAEAAAD//wAA/v/+/wAA/v/9//8BAAEAAAD+/wAA/v/+/wAAAQABAAEAAAAAAP//AQAAAAAAAAD//wEAAQAAAP//AQABAAAAAQAAAP7/AAABAAEAAAABAAAA//8BAAEAAAAAAP7/AAABAAAA/v8AAP//AQAAAAAAAAD//wEAAQAAAAAA//8AAAAA/v8BAAEAAAD//wAA/v8AAAEAAAAAAP7/AQABAP7/AAABAP7/AAABAP7/AAABAAAAAAD//wAAAQAAAP7/AAABAP7/AAABAAAA//8BAAAA//8BAAAAAQABAP//AAABAAEAAQABAAAA//8BAAAAAAAA//8AAAEAAAD+/wAAAQAAAAAAAAD//wEAAQAAAP7/AQABAP7/AQABAP7/AQAAAAAAAAD//wAA/v8AAAIAAgABAP//AQACAAIAAAD+/wAAAQAAAP7/AAABAAAA/v8AAAEAAQAAAAAAAQAAAP7/AQACAAIAAAD+/wAA/v8BAAEAAAD//wAAAQAAAP7/AQABAP7/AQABAP//AAABAAAA/v8BAAEAAAD//wAAAQAAAP//AQAAAAAAAAD//wAA/v8AAAEAAQAAAAAAAAD//wAAAQAAAAAAAAD//wEAAQAAAP//AAABAP7/AAABAAAAAAD//wAAAQAAAP//AAAAAAABAP7/AQABAAAAAAD//wAAAQAAAP7/AAABAP//AQAAAAAAAAD//wEAAQAAAP//AAABAAEAAAD//wAA//8BAAEAAAD+/wAAAQAAAP7/AAABAAAAAAD//wAAAQAAAP7/AAABAP//AQAAAAAAAAD//wEAAQAAAP//AAABAAAAAAD//wAA/v8AAAIAAgABAP//AQACAAIAAAD+/wAAAQAAAP7/AAABAAAA/v8AAAEAAQAAAAAAAQAAAP7/AQACAAIAAAD+/wAA/v8BAAEAAAD//wAAAQAAAP7/AQABAP7/AQABAP//AAABAAAA/v8BAAEAAAD//wAAAQAAAP//AQAAAAAAAAD//wAA/v8AAAEAAQAAAAAAAAD//wAAAQAAAAAAAAD//wEAAQAAAP//AAABAP7/AAABAAAAAAD//wAAAQAAAP//AAAAAAABAP7/AQABAAAAAAD//wAAAQAAAP7/AAABAP//AQAAAAAAAAD//wEAAQAAAP//AAABAAEAAAD//wAA//8BAAEAAAD+/wAAAQAAAP7/AAABAAAAAAD//wAAAQAAAP7/AAABAP//AQAAAAAAAAD//wEAAQAAAP//AAABAAAAAAD//wAA/v8AAAIAAgABAP//AQACAAIAAAD+/wAAAQAAAP7/AAABAAAA/v8AAAEAAQAAAAAAAQAAAP7/AQACAAIAAAD+/wAA/v8BAAEAAAD//wAAAQAAAP7/AQABAP7/AQABAP//AAABAAAA/v8BAAEAAAD//wAAAQAAAP//AQAAAAAAAAD//wAA/v8AAAEAAQAAAAAAAAD//wAAAQAAAAAAAAD//wEAAQAAAP//AAABAP7/AAABAAAAAAD//wAAAQAAAP//AAAAAAABAP7/AQABAAAAAAD//wAAAQAAAP7/AAABAP//AQAAAAAAAAD//wEAAQAAAP//AAABAAEAAAD//wAA//8BAAEAAAD+/wAAAQAAAP7/AAABAAAAAAD//wAAAQAAAP7/AAABAP//AQAAAAAAAAD//wEAAQAAAP//"

private var _activeSoundRef: NSSound?

private var cachedShutterSoundData: Data? = {
    // 1. 优先从 Bundle / Resources 目录加载
    if let bundleUrl = Bundle.main.url(forResource: "shutter", withExtension: "wav"),
       let data = try? Data(contentsOf: bundleUrl) {
        return data
    }
    // 2. 检查可执行文件同级及 Contents/Resources 目录
    let execPath = Bundle.main.bundlePath
    let candidatePaths = [
        execPath + "/Contents/Resources/shutter.wav",
        (execPath as NSString).deletingLastPathComponent + "/Resources/shutter.wav",
        (execPath as NSString).deletingLastPathComponent + "/shutter.wav",
        "/tmp/dsh-appshot-resources/shutter.wav"
    ]
    for p in candidatePaths {
        if FileManager.default.fileExists(atPath: p), let data = try? Data(contentsOf: URL(fileURLWithPath: p)) {
            return data
        }
    }
    // 3. 兜底内置 Base64（保证单独 CLI 执行时 100% 播放相同的快门音）
    return Data(base64Encoded: embeddedShutterWavBase64, options: .ignoreUnknownCharacters)
}()

func playCaptureSound() {
    guard AppConfig.shared.soundEnabled else { return }
    DispatchQueue.main.async {
        if let data = cachedShutterSoundData, let sound = NSSound(data: data) {
            _activeSoundRef = sound
            sound.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                _activeSoundRef = nil
            }
            return
        }
        NSSound.beep()
    }
}

final class CaptureFlashWindow: NSWindow {
    init(targetRect: CGRect) {
        super.init(
            contentRect: targetRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isOpaque = false
        self.hasShadow = false
        self.backgroundColor = NSColor.white.withAlphaComponent(0.35)
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
}

final class CaptureFlyinWindow: NSWindow {
    init(startRect: CGRect, image: CGImage) {
        super.init(
            contentRect: startRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.isOpaque = false
        self.hasShadow = true
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let imageView = NSImageView(frame: CGRect(origin: .zero, size: startRect.size))
        let nsImage = NSImage(cgImage: image, size: startRect.size)
        imageView.image = nsImage
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10.0
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        imageView.layer?.borderWidth = 1.5
        imageView.autoresizingMask = [.width, .height]
        self.contentView = imageView
    }
}

/// 强引用正在执行动画的 overlay window，防止 ARC 在动画回调前释放导致 SIGSEGV
final class OverlayManager {
    static let shared = OverlayManager()
    private var activeWindows: [NSWindow] = []
    private init() {}

    func track(_ window: NSWindow) {
        activeWindows.append(window)
    }

    func release(_ window: NSWindow) {
        window.orderOut(nil)
        activeWindows.removeAll { $0 === window }
    }
}

/// 解析 macOS Dock 栏的终点坐标（优先对齐 Dock 位置；若 Dock 隐藏退化为屏幕底部中央）
private func resolveDockEndpoint(on screen: NSScreen) -> CGPoint {
    let sf = screen.frame
    let vf = screen.visibleFrame

    // 1. 底部 Dock (最常见)：visibleFrame.origin.y > screen.frame.origin.y
    if vf.origin.y > sf.origin.y {
        let dockHeight = vf.origin.y - sf.origin.y
        return CGPoint(x: sf.midX, y: sf.origin.y + dockHeight / 2.0)
    }
    // 2. 左侧 Dock：visibleFrame.origin.x > screen.frame.origin.x
    if vf.origin.x > sf.origin.x {
        let dockWidth = vf.origin.x - sf.origin.x
        return CGPoint(x: sf.origin.x + dockWidth / 2.0, y: sf.midY)
    }
    // 3. 右侧 Dock：visibleFrame 宽度小于 screen.frame 且左边对齐
    if (vf.origin.x + vf.width) < (sf.origin.x + sf.width) {
        let dockWidth = (sf.origin.x + sf.width) - (vf.origin.x + vf.width)
        return CGPoint(x: vf.origin.x + vf.width + dockWidth / 2.0, y: sf.midY)
    }
    // 4. 隐藏 Dock 或无法判别：退化为屏幕底部居中
    return CGPoint(x: sf.midX, y: sf.origin.y + 24.0)
}

func showCaptureAnimation(for scFrame: CGRect, image: CGImage? = nil, onComplete: (() -> Void)? = nil) {
    guard AppConfig.shared.animationEnabled else {
        onComplete?()
        return
    }
    DispatchQueue.main.async {
        guard let mainScreen = NSScreen.main ?? NSScreen.screens.first else {
            onComplete?()
            return
        }
        let primaryHeight = mainScreen.frame.height
        // ScreenCaptureKit (左上原点) -> Cocoa (左下原点)
        let cocoaY = primaryHeight - scFrame.origin.y - scFrame.size.height
        let targetRect = CGRect(x: scFrame.origin.x, y: cocoaY, width: scFrame.size.width, height: scFrame.size.height)

        // 1. 边框/闪光反馈（Flash）
        let flashOverlay = CaptureFlashWindow(targetRect: targetRect)
        OverlayManager.shared.track(flashOverlay)
        flashOverlay.alphaValue = 0.0
        flashOverlay.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.06
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flashOverlay.animator().alphaValue = 0.75
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                flashOverlay.animator().alphaValue = 0.0
            }, completionHandler: {
                OverlayManager.shared.release(flashOverlay)
            })
        })

        // 2. 缩略图飞入 Dock 动画（Fly-in）
        guard let image = image else {
            onComplete?()
            return
        }

        // 计算缩略图起始尺寸（最大宽 380px，保持原始宽高比）
        let startMaxWidth: CGFloat = 380.0
        let aspectRatio = scFrame.size.height / max(1.0, scFrame.size.width)
        let startW = max(80.0, min(startMaxWidth, targetRect.width * 0.35))
        let startH = max(40.0, startW * aspectRatio)
        let startCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let startRect = CGRect(
            x: startCenter.x - startW / 2.0,
            y: startCenter.y - startH / 2.0,
            width: startW,
            height: startH
        )

        // 解析终点（Dock 位置）
        let endCenter = resolveDockEndpoint(on: mainScreen)
        let endW: CGFloat = 36.0
        let endH: CGFloat = max(18.0, endW * aspectRatio)
        let endRect = CGRect(
            x: endCenter.x - endW / 2.0,
            y: endCenter.y - endH / 2.0,
            width: endW,
            height: endH
        )

        let flyinWindow = CaptureFlyinWindow(startRect: startRect, image: image)
        OverlayManager.shared.track(flyinWindow)
        flyinWindow.alphaValue = 1.0
        flyinWindow.orderFrontRegardless()

        // 420ms 飞入动画 (easeInOut 曲线，从窗口中心飞向 Dock 并缩小淡出)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            flyinWindow.animator().setFrame(endRect, display: true)
            flyinWindow.animator().alphaValue = 0.0
        }, completionHandler: {
            OverlayManager.shared.release(flyinWindow)
            onComplete?()
        })
    }
}

@discardableResult
private func bringAppToFront(_ app: NSRunningApplication) -> Bool {
    if #available(macOS 14.0, *) {
        return app.activate()
    } else {
        return app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }
}

func activateApplication(bundleIdentifier: String? = nil, pid: pid_t? = nil) -> Bool {
    // 1. 优先根据 PID 激活 (直接激活拉起 Agent 的宿主进程)
    if let targetPid = pid, targetPid > 0 {
        if let app = NSRunningApplication(processIdentifier: targetPid) {
            if bringAppToFront(app) {
                return true
            }
        }
    }

    // 2. 根据候选 Bundle ID 激活
    let candidateBundleIds = [
        bundleIdentifier,
        "com.deepseek-harness.desktop",
        "com.deepseek.harness",
        "com.electron.deepseek-harness"
    ].compactMap { $0 }

    for bundleId in candidateBundleIds {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if let targetApp = runningApps.first {
            if bringAppToFront(targetApp) {
                return true
            }
        }
    }

    // 3. 按进程名称匹配 DeepSeek 相关应用
    for app in NSWorkspace.shared.runningApplications {
        if let name = app.localizedName, (name.localizedCaseInsensitiveContains("deepseek") || name.localizedCaseInsensitiveContains("dsh")) {
            if bringAppToFront(app) {
                return true
            }
        }
    }

    // 4. AppleScript 强力唤起置顶兜底
    if let bid = bundleIdentifier ?? candidateBundleIds.first {
        let scriptSource = "tell application id \"\(bid)\" to activate"
        if let script = NSAppleScript(source: scriptSource) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            if errorDict == nil {
                return true
            }
        }
    }

    return false
}

// MARK: - DSH 自身窗口过滤判定

func isDshApp(_ app: NSRunningApplication?, activatePid: pid_t? = nil, activateAppId: String? = nil) -> Bool {
    guard let app = app else { return false }
    if let targetPid = activatePid, targetPid > 0, app.processIdentifier == targetPid {
        return true
    }
    if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
        return true
    }
    if let bid = app.bundleIdentifier {
        let candidateBundleIds = [
            activateAppId,
            "com.deepseek-harness.desktop",
            "com.deepseek.harness",
            "com.electron.deepseek-harness"
        ].compactMap { $0 }
        if candidateBundleIds.contains(bid) {
            return true
        }
        if bid.localizedCaseInsensitiveContains("deepseek-harness") || bid.localizedCaseInsensitiveContains("dsh") {
            return true
        }
    }
    if let name = app.localizedName {
        if name.localizedCaseInsensitiveContains("deepseek harness") ||
           name.localizedCaseInsensitiveContains("dsh desktop") ||
           name.caseInsensitiveCompare("dsh") == .orderedSame {
            return true
        }
    }
    return false
}

func isDshWindow(ownerPid: pid_t, ownerName: String?, activatePid: pid_t?, activateAppId: String?) -> Bool {
    if ownerPid == ProcessInfo.processInfo.processIdentifier {
        return true
    }
    if let targetPid = activatePid, targetPid > 0, ownerPid == targetPid {
        return true
    }
    if let app = NSRunningApplication(processIdentifier: ownerPid) {
        if isDshApp(app, activatePid: activatePid, activateAppId: activateAppId) {
            return true
        }
    }
    if let name = ownerName {
        if name.localizedCaseInsensitiveContains("deepseek harness") ||
           name.localizedCaseInsensitiveContains("dsh desktop") ||
           name.caseInsensitiveCompare("dsh") == .orderedSame {
            return true
        }
    }
    return false
}

// MARK: - 核心截图执行器

func performCapture(targetWindowId: UInt32? = nil, outputPath: String? = nil, activateAppId: String? = nil, activatePid: pid_t? = nil) -> AppshotSuccessResult? {
    guard checkScreenCapturePermission() else {
        outputJSON(AppshotErrorResult(code: "SCREEN_PERMISSION_DENIED", message: "Screen capture permission is required."))
        return nil
    }

    // 聚焦防护：若当前聚焦是 DSH 窗口本身，明确不触发截图
    if targetWindowId == nil {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           isDshApp(frontApp, activatePid: activatePid, activateAppId: activateAppId) {
            outputJSON(AppshotErrorResult(code: "DSH_FOREGROUND_IGNORED", message: "Focused window is DSH itself, capture ignored."))
            return nil
        }
    }

    let content: SCShareableContent
    do {
        content = try fetchShareableContent()
    } catch {
        outputJSON(AppshotErrorResult(code: "SCREEN_CONTENT_FETCH_FAILED", message: "Failed to fetch shareable content: \(error.localizedDescription)"))
        return nil
    }

    var targetWindow: SCWindow? = nil
    var targetAppName = "Unknown"

    if let requestedId = targetWindowId {
        targetWindow = content.windows.first { $0.windowID == requestedId }
        if let window = targetWindow {
            targetAppName = window.owningApplication?.applicationName ?? "Unknown"
        } else {
            outputJSON(AppshotErrorResult(code: "WINDOW_NOT_FOUND", message: "Window with ID \(requestedId) not found."))
            return nil
        }
    } else {
        var targetAppPID: pid_t? = nil
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            targetAppName = frontApp.localizedName ?? "Unknown"
            targetAppPID = frontApp.processIdentifier
        }

        var appWindows: [SCWindow] = []
        if let targetPID = targetAppPID {
            appWindows = content.windows.filter { win in
                guard let owner = win.owningApplication else { return false }
                return owner.processID == targetPID &&
                       win.isOnScreen &&
                       win.frame.width > 50 &&
                       win.frame.height > 50
            }
        }

        if appWindows.isEmpty {
            let topWindows = content.windows.filter { win in
                guard let owner = win.owningApplication else { return false }
                return !isDshWindow(ownerPid: owner.processID, ownerName: owner.applicationName, activatePid: activatePid, activateAppId: activateAppId) &&
                       win.isOnScreen &&
                       win.frame.width > 50 &&
                       win.frame.height > 50 &&
                       win.windowLayer == 0
            }
            if let firstTop = topWindows.first {
                targetWindow = firstTop
                targetAppName = firstTop.owningApplication?.applicationName ?? "Unknown"
            } else {
                outputJSON(AppshotErrorResult(code: "NO_FOREGROUND_WINDOW", message: "No capturable on-screen window found."))
                return nil
            }
        } else {
            let layerZeroWindows = appWindows.filter { $0.windowLayer == 0 }
            if let firstLayerZero = layerZeroWindows.first {
                targetWindow = firstLayerZero
            } else {
                targetWindow = appWindows.max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
            }
        }
    }

    guard let window = targetWindow else {
        outputJSON(AppshotErrorResult(code: "NO_FOREGROUND_WINDOW", message: "Could not resolve a valid target window."))
        return nil
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.showsCursor = false
    config.scalesToFit = false
    config.width = Int(window.frame.width * 2)
    config.height = Int(window.frame.height * 2)

    let capturedImage: CGImage
    do {
        capturedImage = try captureWindow(filter: filter, config: config)
    } catch {
        outputJSON(AppshotErrorResult(code: "CAPTURE_FAILED", message: "ScreenCaptureKit captureImage failed: \(error.localizedDescription)"))
        return nil
    }

    let resolvedPath = outputPath ?? "/tmp/dsh-appshot-\(UUID().uuidString.prefix(8)).png"
    let destinationURL = URL(fileURLWithPath: resolvedPath)
    let (saved, saveErr) = saveCGImageAsPNG(image: capturedImage, destinationURL: destinationURL)
    guard saved else {
        outputJSON(AppshotErrorResult(code: "FILE_SAVE_FAILED", message: "Failed to write PNG image to \(resolvedPath): \(saveErr)"))
        return nil
    }

    // 先截后唤与视觉/音效反馈（严格在落盘后触发，保障防自截）
    playCaptureSound()
    showCaptureAnimation(for: window.frame, image: capturedImage, onComplete: {
        _ = activateApplication(bundleIdentifier: activateAppId, pid: activatePid)
    })

    let result = AppshotSuccessResult(
        appName: targetAppName,
        windowTitle: window.title,
        windowId: window.windowID,
        width: capturedImage.width,
        height: capturedImage.height,
        imagePath: resolvedPath,
        timestamp: Int64(Date().timeIntervalSince1970 * 1000),
        captureKind: "window"
    )

    return result
}

// MARK: - 可配置快捷键状态机 (ConfigurableShortcutMonitor)

final class ConfigurableShortcutMonitor {
    private var isCapturing = false
    private var lastTriggerTime: TimeInterval = 0
    private let cooldownDuration: TimeInterval = 1.0 // 1 秒触发冷却防抖
    private let onTrigger: () -> Void

    // 双击连击检测
    private var lastModifierPressTime: TimeInterval = 0
    private var lastModifierType: String = ""
    private var previousFlags: NSEvent.ModifierFlags = []

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    private func tryTrigger() {
        let now = Date().timeIntervalSince1970
        guard !isCapturing && (now - lastTriggerTime >= cooldownDuration) else {
            return
        }
        lastTriggerTime = now
        isCapturing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.isCapturing = false }
            self?.onTrigger()
        }
    }

    func handleFlagsChanged(event: NSEvent) {
        let flags = event.modifierFlags
        let raw = flags.rawValue
        let now = Date().timeIntervalSince1970
        let mode = AppConfig.shared.shortcutMode

        // 提取左右具体键位（利用 macOS raw 掩码）
        // NX_DEVICELCMDKEYMASK = 0x08, NX_DEVICERCMDKEYMASK = 0x10
        // NX_DEVICELALTKEYMASK = 0x20, NX_DEVICERALTKEYMASK = 0x40
        // NX_DEVICELCTLKEYMASK = 0x01, NX_DEVICERCTLKEYMASK = 0x2000
        let isLeftCmd = (raw & 0x08) != 0
        let isRightCmd = (raw & 0x10) != 0
        let isLeftOpt = (raw & 0x20) != 0
        let isRightOpt = (raw & 0x40) != 0
        let isLeftCtrl = (raw & 0x01) != 0
        let isRightCtrl = (raw & 0x2000) != 0

        let isCmd = flags.contains(.command)
        let isOpt = flags.contains(.option)
        let isCtrl = flags.contains(.control)

        let wasCmd = previousFlags.contains(.command)
        let wasOpt = previousFlags.contains(.option)
        let wasCtrl = previousFlags.contains(.control)

        switch mode {
        case "dual-cmd":
            // 左右 Cmd 同时按（排斥单键双击）
            if isLeftCmd && isRightCmd {
                tryTrigger()
                previousFlags = flags
                return
            }

        case "double-cmd":
            // 双击 Cmd（排斥左右同时按）
            if isLeftCmd && isRightCmd {
                previousFlags = flags
                return
            }
            if isCmd && !wasCmd {
                if lastModifierType == "cmd" && (now - lastModifierPressTime < 0.35) {
                    tryTrigger()
                    lastModifierPressTime = 0
                } else {
                    lastModifierPressTime = now
                    lastModifierType = "cmd"
                }
            }

        case "dual-option":
            // 左右 Option 同时按（排斥单键双击）
            if isLeftOpt && isRightOpt {
                tryTrigger()
                previousFlags = flags
                return
            }

        case "double-option":
            // 双击 Option（排斥左右同时按）
            if isLeftOpt && isRightOpt {
                previousFlags = flags
                return
            }
            if isOpt && !wasOpt {
                if lastModifierType == "opt" && (now - lastModifierPressTime < 0.35) {
                    tryTrigger()
                    lastModifierPressTime = 0
                } else {
                    lastModifierPressTime = now
                    lastModifierType = "opt"
                }
            }

        case "dual-control":
            // 左右 Control 同时按（排斥单键双击）
            if isLeftCtrl && isRightCtrl {
                tryTrigger()
                previousFlags = flags
                return
            }

        case "double-control":
            // 双击 Control（排斥左右同时按）
            if isLeftCtrl && isRightCtrl {
                previousFlags = flags
                return
            }
            if isCtrl && !wasCtrl {
                if lastModifierType == "ctrl" && (now - lastModifierPressTime < 0.35) {
                    tryTrigger()
                    lastModifierPressTime = 0
                } else {
                    lastModifierPressTime = now
                    lastModifierType = "ctrl"
                }
            }

        case "cmd-option":
            // ⌘ Command + ⌥ Option 组合键
            if isCmd && isOpt {
                tryTrigger()
                previousFlags = flags
                return
            }

        default:
            // 默认回退 dual-cmd（左右 Command 同时按）
            if isLeftCmd && isRightCmd {
                tryTrigger()
                previousFlags = flags
                return
            }
        }

        previousFlags = flags
    }
}

// MARK: - 区域框选截图 (Region Shot · ⌘⇧A)

/// CLI `--region` 模式下截图完成即退出（守护进程模式不退出）。
private var regionCLIExitWhenDone = false

/// NSScreen → CGDirectDisplayID（ScreenCaptureKit 的 display 匹配键）。
func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
    }
    return CGDirectDisplayID(number.uint32Value)
}

/// 鼠标所在屏幕；多显示器下按目标屏幕捕获，不跨屏拼图。
func screenContainingMouse() -> NSScreen? {
    let location = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
        ?? NSScreen.main
        ?? NSScreen.screens.first
}

/// Cocoa 全局选区（原点主屏左下）→ 目标屏 `SCStreamConfiguration.sourceRect`（原点该屏左上，点）。
func regionSourceRect(selection: CGRect, on screen: NSScreen) -> CGRect {
    let localX = selection.minX - screen.frame.minX
    let localTop = screen.frame.height - (selection.maxY - screen.frame.minY)
    return CGRect(x: localX, y: localTop, width: selection.width, height: selection.height)
}

/// Cocoa 全局矩形 → ScreenCaptureKit 全局坐标（主屏左上原点），供闪光/飞入动画复用。
func screenCaptureGlobalRect(from selection: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
        ?? NSScreen.main?.frame.height
        ?? selection.maxY
    return CGRect(x: selection.minX, y: primaryHeight - selection.maxY, width: selection.width, height: selection.height)
}

/// 截取目标屏上的矩形；`excluding` 为本进程窗口（选区 UI / 动画），确保它们不出现在成图里。
func captureRegion(screen: NSScreen, sourceRect: CGRect, excluding ownWindows: [SCWindow] = []) throws -> CGImage {
    let content = try fetchShareableContent()
    let targetDisplay = displayID(of: screen)
    guard let display = content.displays.first(where: { $0.displayID == targetDisplay }) else {
        throw NSError(domain: "Appshot", code: -3, userInfo: [NSLocalizedDescriptionKey: "Target display is not shareable"])
    }

    // 优先使用调用方在遮罩仍在场时抓取的排除列表（按窗口身份排除，不依赖 orderOut 时序）
    let excluded = ownWindows.isEmpty
        ? content.windows.filter { $0.owningApplication?.processID == getpid() }
        : ownWindows
    let filter = SCContentFilter(display: display, excludingWindows: excluded)

    let config = SCStreamConfiguration()
    config.sourceRect = sourceRect
    let scale = screen.backingScaleFactor
    config.width = max(1, Int((sourceRect.width * scale).rounded()))
    config.height = max(1, Int((sourceRect.height * scale).rounded()))
    config.showsCursor = false
    config.scalesToFit = false

    return try captureWindow(filter: filter, config: config)
}

/// 抓取“本进程当前在场的窗口”快照，用于把选区 UI / 动画从成图里排除。
func snapshotOwnWindows() -> [SCWindow] {
    guard let content = try? fetchShareableContent() else { return [] }
    return content.windows.filter { $0.owningApplication?.processID == getpid() }
}

/// 区域截图主流程：权限 → 截取 → 落盘 → 反馈 → 先截后唤。
func performRegionCapture(
    selection: CGRect,
    on screen: NSScreen,
    outputPath: String?,
    activateAppId: String?,
    activatePid: pid_t?,
    excluding ownWindows: [SCWindow] = [],
    appName: String = "区域截图"
) -> AppshotSuccessResult? {
    guard checkScreenCapturePermission() else {
        outputJSON(AppshotErrorResult(code: "SCREEN_PERMISSION_DENIED", message: "Screen capture permission is required."))
        return nil
    }
    guard selection.width >= 1, selection.height >= 1 else {
        outputJSON(AppshotErrorResult(code: "REGION_TOO_SMALL", message: "Selected region is too small."))
        return nil
    }

    let image: CGImage
    do {
        image = try captureRegion(
            screen: screen,
            sourceRect: regionSourceRect(selection: selection, on: screen),
            excluding: ownWindows
        )
    } catch {
        outputJSON(AppshotErrorResult(code: "REGION_CAPTURE_FAILED", message: "Region capture failed: \(error.localizedDescription)"))
        return nil
    }

    let resolvedPath = outputPath ?? "/tmp/dsh-appshot-\(UUID().uuidString.prefix(8)).png"
    let (saved, saveErr) = saveCGImageAsPNG(image: image, destinationURL: URL(fileURLWithPath: resolvedPath))
    guard saved else {
        outputJSON(AppshotErrorResult(code: "FILE_SAVE_FAILED", message: "Failed to write PNG image to \(resolvedPath): \(saveErr)"))
        return nil
    }

    playCaptureSound()
    showCaptureAnimation(for: screenCaptureGlobalRect(from: selection), image: image, onComplete: {
        _ = activateApplication(bundleIdentifier: activateAppId, pid: activatePid)
    })

    return AppshotSuccessResult(
        appName: appName,
        windowTitle: nil,
        windowId: 0,
        width: image.width,
        height: image.height,
        imagePath: resolvedPath,
        timestamp: Int64(Date().timeIntervalSince1970 * 1000),
        captureKind: "region"
    )
}

/// 框选叠加层：不铺蒙层，只画选框/刻度/尺寸徽标（Esc / 右键 / 过小选区取消）。
final class RegionSelectionView: NSView {
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    var onFinish: ((CGRect?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    private func selectionRect() -> CGRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func update(point: NSPoint) {
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        update(point: point)
    }

    override func mouseDragged(with event: NSEvent) {
        update(point: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        update(point: convert(event.locationInWindow, from: nil))
        let rect = selectionRect()
        if let rect = rect, rect.width >= 4, rect.height >= 4 {
            onFinish?(rect)
        } else {
            onFinish?(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onFinish?(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 无整屏蒙层：屏幕保持原样，只叠加选框与提示；成图里也绝不会出现任何装饰
        // （窗口在截取前 orderOut，并按窗口身份从 SCContentFilter 排除）。
        if let rect = selectionRect() {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.stroke()

            // 四角外扩刻度：对齐用，不压住选区内容
            let tick: CGFloat = 10
            let tickPath = NSBezierPath()
            tickPath.lineWidth = 2.5
            let corners: [(CGPoint, [CGPoint])] = [
                (CGPoint(x: rect.minX, y: rect.minY), [CGPoint(x: rect.minX - tick, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY - tick)]),
                (CGPoint(x: rect.maxX, y: rect.minY), [CGPoint(x: rect.maxX + tick, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY - tick)]),
                (CGPoint(x: rect.minX, y: rect.maxY), [CGPoint(x: rect.minX - tick, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY + tick)]),
                (CGPoint(x: rect.maxX, y: rect.maxY), [CGPoint(x: rect.maxX + tick, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY + tick)]),
            ]
            for (corner, arms) in corners {
                tickPath.move(to: corner)
                for arm in arms {
                    tickPath.move(to: corner)
                    tickPath.line(to: arm)
                }
            }
            tickPath.stroke()

            let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let labelSize = (label as NSString).size(withAttributes: attributes)
            let badgeOrigin = CGPoint(
                x: min(max(rect.minX, bounds.minX + 4), bounds.maxX - labelSize.width - 16),
                y: rect.maxY + 8 + labelSize.height <= bounds.maxY ? rect.maxY + 8 : max(rect.minY - labelSize.height - 12, 4)
            )
            let badge = CGRect(x: badgeOrigin.x, y: badgeOrigin.y, width: labelSize.width + 12, height: labelSize.height + 4)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            (label as NSString).draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 2), withAttributes: attributes)
        }

        drawHintPill()
    }

    /// 顶部提示胶囊：单独的小浮层，不铺满屏幕。
    private func drawHintPill() {
        let hint = "拖动选择截图区域 · Esc 取消"
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let hintSize = (hint as NSString).size(withAttributes: hintAttributes)
        let hintOrigin = CGPoint(x: bounds.midX - hintSize.width / 2, y: bounds.maxY - hintSize.height - 60)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(
            roundedRect: CGRect(
                x: hintOrigin.x - 14,
                y: hintOrigin.y - 6,
                width: hintSize.width + 28,
                height: hintSize.height + 12
            ),
            xRadius: 8,
            yRadius: 8
        ).fill()
        (hint as NSString).draw(at: hintOrigin, withAttributes: hintAttributes)
    }

    /// 测试钩子：直接把选区画出来（配合 APPSHOT_REGION_PRESET 验证真实截取路径）。
    func applyPresetSelection(_ rect: CGRect) {
        startPoint = CGPoint(x: rect.minX, y: rect.minY)
        currentPoint = CGPoint(x: rect.maxX, y: rect.maxY)
        needsDisplay = true
    }
}

/// 区域截图控制器（单实例，⌘⇧A 触发）。
final class RegionCaptureController {
    static let shared = RegionCaptureController()

    private var overlayWindow: NSWindow?
    private var activeScreen: NSScreen?
    private var activateAppId: String?
    private var activatePid: pid_t?
    private var isActive = false

    /// CLI `--region --output <path>` 指定的落盘路径。
    var outputPathOverride: String?

    private init() {}

    func begin(activateAppId: String?, activatePid: pid_t?) {
        guard !isActive else { return }
        guard checkScreenCapturePermission() else {
            outputJSON(AppshotErrorResult(code: "SCREEN_PERMISSION_DENIED", message: "Screen capture permission is required."))
            return
        }
        guard let screen = screenContainingMouse() else {
            outputJSON(AppshotErrorResult(code: "NO_TARGET_SCREEN", message: "No usable screen for region capture."))
            return
        }

        isActive = true
        self.activateAppId = activateAppId
        self.activatePid = activatePid
        activeScreen = screen

        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        view.onFinish = { [weak self] rect in
            self?.finish(viewRect: rect)
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        overlayWindow = window

        // 测试钩子（不影响生产路径）：APPSHOT_REGION_PRESET=x,y,w,h 时直接画出该选区并自动完成，
        // 用于自动化验证「选区 UI 在场 → 截取」这条真实链路不会把 UI 带进成图。
        if let preset = ProcessInfo.processInfo.environment["APPSHOT_REGION_PRESET"],
           let rect = parseRegionPreset(preset) {
            view.applyPresetSelection(rect)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.finish(viewRect: rect)
            }
        }
    }

    private func finish(viewRect: CGRect?) {
        guard isActive, let screen = activeScreen else { return }
        isActive = false
        activeScreen = nil

        // 先在选区 UI 仍在场时抓一份“本进程窗口”清单：按窗口身份排除，不依赖 orderOut 的提交时序
        let excludedWindows = snapshotOwnWindows()

        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        guard let viewRect = viewRect else {
            if regionCLIExitWhenDone { exit(0) }
            return
        }

        let selection = CGRect(
            x: viewRect.minX + screen.frame.minX,
            y: viewRect.minY + screen.frame.minY,
            width: viewRect.width,
            height: viewRect.height
        )
        let appId = activateAppId
        let appPid = activatePid
        let outputPath = outputPathOverride

        // 等窗口服务器提交“UI 已离场”后再截取；排除列表是兜底，两条都保证成图干净
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if let result = performRegionCapture(
                selection: selection,
                on: screen,
                outputPath: outputPath,
                activateAppId: appId,
                activatePid: appPid,
                excluding: excludedWindows
            ) {
                outputJSON(result)
            }
            if regionCLIExitWhenDone { exit(0) }
        }
    }
}

/// 解析 APPSHOT_REGION_PRESET=「x,y,width,height」（view 坐标，左下原点）。
func parseRegionPreset(_ raw: String) -> CGRect? {
    let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, parts[2] >= 1, parts[3] >= 1 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

// MARK: - 全局热键 ⌘⇧A（Carbon RegisterEventHotKey，无需辅助功能授权）

private var regionHotKeyRef: EventHotKeyRef?
private var regionHotKeyHandlerRef: EventHandlerRef?
private var regionHotKeyAppId: String? = "com.deepseek-harness.desktop"
private var regionHotKeyPid: pid_t?

private func regionHotKeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        // 关闭开关时仍拦截按键但不截图：Carbon 热键一旦注册就独占该组合，
        // 用户可在设置面板关闭，避免与 Chrome「搜索标签页」等冲突。
        guard AppConfig.shared.regionShortcutEnabled else { return }
        RegionCaptureController.shared.begin(activateAppId: regionHotKeyAppId, activatePid: regionHotKeyPid)
    }
    return noErr
}

func registerRegionHotKey(activateAppId: String?, activatePid: pid_t?) {
    regionHotKeyAppId = activateAppId
    regionHotKeyPid = activatePid

    var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )
    let handlerStatus = InstallEventHandler(
        GetApplicationEventTarget(),
        regionHotKeyCallback,
        1,
        &eventType,
        nil,
        &regionHotKeyHandlerRef
    )
    guard handlerStatus == noErr else {
        outputJSON(AppshotErrorResult(code: "REGION_HOTKEY_HANDLER_FAILED", message: "InstallEventHandler failed: \(handlerStatus)"))
        return
    }

    let hotKeyID = EventHotKeyID(signature: OSType(0x41504854), id: 1) // 'APHT'
    let status = RegisterEventHotKey(
        UInt32(kVK_ANSI_A),
        UInt32(cmdKey | shiftKey),
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &regionHotKeyRef
    )
    if status != noErr {
        outputJSON(AppshotErrorResult(code: "REGION_HOTKEY_FAILED", message: "RegisterEventHotKey(⌘⇧A) failed: \(status)"))
    }
}

// MARK: - Stdin 监听器

func startStdinListener() {
    DispatchQueue.global(qos: .utility).async {
        let input = FileHandle.standardInput
        while true {
            let data = input.availableData
            guard !data.isEmpty else { break }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let lineData = trimmed.data(using: .utf8),
                   let cmd = try? JSONDecoder().decode(InboundCommand.self, from: lineData) {
                    if cmd.type == "config/update", let payload = cmd.payload {
                        // 派发到主线程更新配置，避免与 NSEvent monitor 回调的并发竞态
                        DispatchQueue.main.async {
                            AppConfig.shared.update(with: payload)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Main 入口

@main
struct AppshotCLI {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            Usage: appshot-macos [options]
            Options:
              --cli-capture          Capture the current frontmost window (default)
              --daemon               Run as persistent background agent with configurable shortcut monitor
              --window-id <id>       Capture specific window by ID
              --region               Interactive region selection (drag to select, Esc cancels)
              --region-rect <x,y,w,h> Capture that region headlessly (points, origin = top-left of the target screen)
              --screen <index>       Target screen index for --region-rect (default 0 = main display)
              --list-windows         List all on-screen capturable windows
              --output <path>        Custom output PNG file path
              --activate-app <id>    Activate target application bundle ID after capture
              --help                 Show this help message
            """)
            exit(0)
        }

        // 诊断模式：列出窗口
        if args.contains("--list-windows") {
            guard checkScreenCapturePermission() else {
                outputError(code: "SCREEN_PERMISSION_DENIED", message: "Screen capture permission is required.")
            }
            do {
                let content = try fetchShareableContent()
                let windowsInfo = content.windows.map { win in
                    WindowInfo(
                        windowId: win.windowID,
                        appName: win.owningApplication?.applicationName ?? "Unknown",
                        pid: win.owningApplication?.processID ?? 0,
                        title: win.title,
                        frame: ["x": win.frame.origin.x, "y": win.frame.origin.y, "width": win.frame.size.width, "height": win.frame.size.height],
                        isOnScreen: win.isOnScreen,
                        layer: win.windowLayer
                    )
                }
                outputJSON(windowsInfo)
                exit(0)
            } catch {
                outputError(code: "SCREEN_CONTENT_FETCH_FAILED", message: "Failed to fetch shareable content: \(error.localizedDescription)")
            }
        }

        // DAEMON 模式（Phase 3 / 生产常驻模式）
        if args.contains("--daemon") {
            let pid = ProcessInfo.processInfo.processIdentifier
            let bundleId = Bundle.main.bundleIdentifier ?? "com.deepseek-harness.appshot-agent"
            outputJSON(AppshotReadyFrame(pid: pid, bundleId: bundleId))

            var targetActivateApp: String? = "com.deepseek-harness.desktop"
            if let actIndex = args.firstIndex(of: "--activate-app"), actIndex + 1 < args.count {
                targetActivateApp = args[actIndex + 1]
            }

            var targetActivatePid: pid_t? = nil
            if let pidIndex = args.firstIndex(of: "--activate-pid"), pidIndex + 1 < args.count {
                targetActivatePid = pid_t(args[pidIndex + 1])
            }

            let monitor = ConfigurableShortcutMonitor {
                if let result = performCapture(activateAppId: targetActivateApp, activatePid: targetActivatePid) {
                    outputJSON(result)
                }
            }

            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                monitor.handleFlagsChanged(event: event)
            }

            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                monitor.handleFlagsChanged(event: event)
                return event
            }

            // 区域框选截图：⌘⇧A（Carbon 全局热键，不占用辅助功能权限）
            registerRegionHotKey(activateAppId: targetActivateApp, activatePid: targetActivatePid)

            // 启动 stdin NDJSON 指令监听
            startStdinListener()

            NSApp.run()
            exit(0)
        }

        // CLI 单次模式（Phase 1~2 / 诊断测试）
        var targetWindowId: UInt32? = nil
        if let idIndex = args.firstIndex(of: "--window-id"), idIndex + 1 < args.count {
            targetWindowId = UInt32(args[idIndex + 1])
        }

        var outputPath: String? = nil
        if let outIndex = args.firstIndex(of: "--output"), outIndex + 1 < args.count {
            outputPath = args[outIndex + 1]
        }

        var activateAppId: String? = nil
        if let actIndex = args.firstIndex(of: "--activate-app"), actIndex + 1 < args.count {
            activateAppId = args[actIndex + 1]
        }

        var activatePid: pid_t? = nil
        if let pidIndex = args.firstIndex(of: "--activate-pid"), pidIndex + 1 < args.count {
            activatePid = pid_t(args[pidIndex + 1])
        }

        // 区域截图（交互框选）：从命令行触发与守护进程相同的遮罩流程
        if args.contains("--region") {
            regionCLIExitWhenDone = true
            RegionCaptureController.shared.outputPathOverride = outputPath
            RegionCaptureController.shared.begin(activateAppId: activateAppId, activatePid: activatePid)
            NSApp.run()
            exit(0)
        }

        // 区域截图（无界面，供自动化验收）：坐标为目标屏左上原点的点
        if let rectIndex = args.firstIndex(of: "--region-rect"), rectIndex + 1 < args.count {
            let parts = args[rectIndex + 1]
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else {
                outputError(code: "INVALID_REGION_RECT", message: "Usage: --region-rect x,y,width,height")
            }

            var screenIndex = 0
            if let sIndex = args.firstIndex(of: "--screen"), sIndex + 1 < args.count, let parsed = Int(args[sIndex + 1]) {
                screenIndex = parsed
            }
            let screens = NSScreen.screens
            guard screens.indices.contains(screenIndex) else {
                outputError(code: "SCREEN_NOT_FOUND", message: "Screen index \(screenIndex) out of range (available: \(screens.count))")
            }
            let screen = screens[screenIndex]

            guard checkScreenCapturePermission() else {
                outputError(code: "SCREEN_PERMISSION_DENIED", message: "Screen capture permission is required.")
            }

            let sourceRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            guard sourceRect.width >= 1, sourceRect.height >= 1 else {
                outputError(code: "REGION_TOO_SMALL", message: "Selected region is too small.")
            }

            do {
                let image = try captureRegion(screen: screen, sourceRect: sourceRect)
                let path = outputPath ?? "/tmp/dsh-appshot-\(UUID().uuidString.prefix(8)).png"
                let (saved, saveErr) = saveCGImageAsPNG(image: image, destinationURL: URL(fileURLWithPath: path))
                guard saved else {
                    outputError(code: "FILE_SAVE_FAILED", message: "Failed to write PNG image to \(path): \(saveErr)")
                }
                outputJSON(AppshotSuccessResult(
                    appName: "区域截图",
                    windowTitle: nil,
                    windowId: 0,
                    width: image.width,
                    height: image.height,
                    imagePath: path,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    captureKind: "region"
                ))
                exit(0)
            } catch {
                outputError(code: "REGION_CAPTURE_FAILED", message: "Region capture failed: \(error.localizedDescription)")
            }
        }

        if let result = performCapture(targetWindowId: targetWindowId, outputPath: outputPath, activateAppId: activateAppId, activatePid: activatePid) {
            outputJSON(result)
            exit(0)
        } else {
            exit(1)
        }
    }
}
