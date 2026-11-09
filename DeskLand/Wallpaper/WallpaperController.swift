import AppKit

/// The wallpaper: a borderless window just above the system wallpaper and below Finder's
/// desktop icons, showing the current theme page. Covers the primary display, like upstream.
final class WallpaperController {
    private let window: NSWindow
    private let host: HostWebView
    private let iconReader = IconReader()
    private var timers: [Timer] = []
    private var page: String
    private var lastIcons = ""
    private var lastPause: Bool?
    private var screensAsleep = false

    var manualPause = false {
        didSet { pollPause() }
    }

    /// The settings message the page needs before anything else.
    var settingsMessage: () -> String = { "{}" }
    var onIconsChanged: (String) -> Void = { _ in }
    var onRecordProgress: (String) -> Void = { _ in }

    private var snapshotDone: ((Result<(thumb: String, png: String), ShareError>) -> Void)?
    private var recordDone: ((Result<(mime: String, poster: String, video: String), ShareError>) -> Void)?

    /// The latest icons message, so the settings preview can show the real layout.
    var currentIcons: String { lastIcons }

    init(page: String, schemeHandler: LocalSchemeHandler) {
        self.page = page
        let screen = NSScreen.screens.first ?? NSScreen.main!
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 26 / 255, green: 163 / 255, blue: 196 / 255, alpha: 1)

        host = HostWebView(schemeHandler: schemeHandler)
        host.webView.frame = window.contentLayoutRect
        host.webView.autoresizingMask = [.width, .height]
        window.contentView = host.webView

        host.onMessage = { [weak self] in self?.handle($0) }
        host.onCrash = { [weak self] in self?.host.reload() }
    }

    func start() {
        host.load(page: pageURL)
        window.orderFront(nil)
        timers = [
            repeating(0.4) { [weak self] in self?.pollIcons() },
            repeating(0.5) { [weak self] in self?.pollPause() },
        ]
        observe(NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.fitScreen() }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.window.orderFront(nil)
        }
        observe(NSWorkspace.screensDidSleepNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.screensAsleep = true
            self?.pollPause()
        }
        observe(NSWorkspace.screensDidWakeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.screensAsleep = false
            self?.pollPause()
        }
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        window.orderOut(nil)
    }

    func load(page newPage: String) {
        page = newPage
        host.load(page: pageURL)
    }

    func reload() {
        host.reload()
    }

    func post(_ message: String) {
        host.post(message)
    }

    private var pageURL: String {
        "\(page)?wallpaper=1"
    }

    private var screen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main!
    }

    private func fitScreen() {
        window.setFrame(screen.frame, display: true)
        lastIcons = ""
        pollIcons()
    }

    // MARK: - Messages from the theme page

    private func handle(_ message: String) {
        if message.hasPrefix("snapshot|") {
            let parts = message.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count < 3 {
                finishSnapshot(.failure(.badData))
            } else if parts[1] == "error" {
                finishSnapshot(.failure(.page(parts[2])))
            } else {
                finishSnapshot(.success((parts[1], parts[2])))
            }
        } else if message.hasPrefix("recprogress|") {
            onRecordProgress(String(message.dropFirst("recprogress|".count)))
        } else if message.hasPrefix("record|") {
            let parts = message.split(separator: "|", maxSplits: 3).map(String.init)
            if parts.count >= 3, parts[1] == "error" {
                finishRecord(.failure(.page(String(message.dropFirst("record|error|".count)))))
            } else if parts.count < 4 {
                finishRecord(.failure(.badData))
            } else {
                finishRecord(.success((parts[1], parts[2], parts[3])))
            }
        } else {
            // "ready": the page loaded. Send settings first, then icons and pause state.
            host.post(settingsMessage())
            lastIcons = ""
            lastPause = nil
            pollIcons()
            pollPause()
        }
    }

    // MARK: - Icons

    private func pollIcons() {
        let result = iconReader.read()
        let frame = screen.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        // AX coordinates have a top-left origin on the primary display; NSScreen has bottom-left.
        let top = primaryHeight - frame.maxY
        let scale = screen.backingScaleFactor
        let rects: [[Int]] = result.rects.compactMap { rect in
            let local = CGRect(x: rect.minX - frame.minX, y: rect.minY - top, width: rect.width, height: rect.height)
            guard local.intersects(CGRect(origin: .zero, size: frame.size)) else { return nil }
            return [local.minX, local.minY, local.maxX, local.maxY].map { Int(($0 * scale).rounded()) }
        }
        let message = JSON.string(["t": "icons", "vis": result.visible, "r": rects] as [String: Any])
        guard message != lastIcons else { return }
        lastIcons = message
        onIconsChanged(message)
        host.post(message)
    }

    // MARK: - Pause

    private func pollPause() {
        let pause = manualPause || screensAsleep || CoverDetector.isCovered(screen)
        guard pause != lastPause else { return }
        lastPause = pause
        host.post(JSON.string(["t": "pause", "v": pause] as [String: Any]))
    }

    // MARK: - Sharing

    func requestSnapshot(_ done: @escaping (Result<(thumb: String, png: String), ShareError>) -> Void) {
        guard snapshotDone == nil else {
            done(.failure(.busy))
            return
        }
        snapshotDone = done
        host.post(#"{"t":"snapshot"}"#)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.finishSnapshot(.failure(.timeout))
        }
    }

    func requestRecording(_ done: @escaping (Result<(mime: String, poster: String, video: String), ShareError>) -> Void) {
        guard recordDone == nil else {
            done(.failure(.busy))
            return
        }
        recordDone = done
        host.post(#"{"t":"record"}"#)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.finishRecord(.failure(.timeout))
        }
    }

    private func finishSnapshot(_ result: Result<(thumb: String, png: String), ShareError>) {
        let done = snapshotDone
        snapshotDone = nil
        done?(result)
    }

    private func finishRecord(_ result: Result<(mime: String, poster: String, video: String), ShareError>) {
        let done = recordDone
        recordDone = nil
        done?(result)
    }
}

enum ShareError: Error {
    case busy, timeout, badData
    case page(String)

    var message: String {
        switch self {
        case .busy: "The previous share is still being made"
        case .timeout: "Making the share took too long"
        case .badData: "The page returned incomplete data"
        case .page(let text): text
        }
    }
}
