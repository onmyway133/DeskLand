import AppKit

/// `DESKLAND_SNAPSHOT=<dir>` renders the theme pages and the settings page in offscreen
/// windows with sample icons, saves PNGs and quits. It never touches the real desktop.
final class SnapshotRunner {
    static let shared = SnapshotRunner()

    private var hosts: [HostWebView] = []
    private var windows: [NSWindow] = []

    func run(outputDir: URL, schemeHandler: LocalSchemeHandler) {
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let size = CGSize(width: 1440, height: 900)
        let pages = [
            ("beach", "flat.html?wallpaper=1"),
            ("meadow", "meadow.html?wallpaper=1"),
            ("settings", "settings.html"),
        ]
        for (index, (name, page)) in pages.enumerated() {
            // Far off any screen, so nothing shows on the desktop.
            let frame = CGRect(x: -40_000 - CGFloat(index) * 2_000, y: -40_000, width: size.width, height: size.height)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Offscreen pages count as hidden, so WebKit never fires requestAnimationFrame.
            // Drive frames from timers instead; the real wallpaper window is on screen.
            let frameDriver = "window.requestAnimationFrame = f => setTimeout(() => f(performance.now()), 16);"
            let host = HostWebView(schemeHandler: schemeHandler, extraScript: frameDriver)
            host.webView.frame = CGRect(origin: .zero, size: size)
            window.contentView = host.webView
            host.onMessage = { [weak host] text in
                guard let host else { return }
                Self.answer(text, host: host, size: size, scale: window.backingScaleFactor)
            }
            host.load(page: page)
            window.orderFrontRegardless()
            hosts.append(host)
            windows.append(window)

            Task {
                try? await Task.sleep(for: .seconds(7))
                let probe = "JSON.stringify({frames: typeof frameN === 'undefined' ? null : frameN, canvases: document.querySelectorAll('canvas').length, dpr: devicePixelRatio, hidden: document.hidden, errors: window.__deskErrors || []})"
                if let state = try? await host.webView.evaluateJavaScript(probe) {
                    print("\(name): \(state)")
                }
                await Self.save(host.webView, to: outputDir.appending(path: "\(name).png"))
                if name == pages.last?.0 {
                    try? await Task.sleep(for: .seconds(1))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Plays the host's part: settings and a column of icons on the right, like a Mac desktop.
    private static func answer(_ text: String, host: HostWebView, size: CGSize, scale: CGFloat) {
        if text == "ready" {
            host.post(#"{"t":"settings","v":{}}"#)
            let rects = (0..<6).map { index -> [Int] in
                let x = size.width - 110
                let y = 40 + CGFloat(index) * 105
                return [x, y, x + 90, y + 98].map { Int(($0 * scale).rounded()) }
            }
            host.post(JSON.string(["t": "icons", "vis": true, "r": rects] as [String: Any]))
            host.post(#"{"t":"pause","v":false}"#)
        } else if let message = JSON.parse(text) as? [String: Any], message["t"] as? String == "hello" {
            host.post(JSON.string([
                "t": "init", "theme": "beach", "params": [String: Any](),
                "screen": ["w": Int(size.width * scale), "h": Int(size.height * scale)],
                "autostart": false, "autostartWarn": false, "autostartSw": "",
                "lang": "en", "langEff": "en", "langSys": "en",
            ] as [String: Any]))
        }
    }

    private static func save(_ webView: WKWebViewSnapshotting, to url: URL) async {
        let image = await webView.snapshotImage()
        guard
            let tiff = image?.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            print("snapshot failed: \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("snapshot saved: \(url.path)")
    }
}

import WebKit

protocol WKWebViewSnapshotting {
    func snapshotImage() async -> NSImage?
}

extension WKWebView: WKWebViewSnapshotting {
    func snapshotImage() async -> NSImage? {
        await withCheckedContinuation { continuation in
            takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
