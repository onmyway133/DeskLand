import AppKit
import WebKit

/// `DESKLAND_RECORD=<dir>` records a demo clip of each theme with upstream's built-in recorder
/// (share.js, `__recDemoStyle`): sample icons get dragged around and the scenery reshapes.
/// Pages render in offscreen windows, so nothing on the real desktop is captured.
final class RecordRunner {
    static let shared = RecordRunner()

    private var hosts: [HostWebView] = []
    private var windows: [NSWindow] = []

    func run(outputDir: URL, schemeHandler: LocalSchemeHandler) {
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let size = CGSize(width: Double(env["DESKLAND_RECORD_WIDTH"] ?? "") ?? 1600, height: Double(env["DESKLAND_RECORD_HEIGHT"] ?? "") ?? 1000)
        let themes = (env["DESKLAND_RECORD_THEMES"] ?? "beach:flat.html,meadow:meadow.html")
            .split(separator: ",")
            .map { $0.split(separator: ":").map(String.init) }
            .filter { $0.count == 2 }

        Task {
            for (index, theme) in themes.enumerated() {
                await record(name: theme[0], page: theme[1], index: index, size: size, outputDir: outputDir, schemeHandler: schemeHandler)
            }
            NSApp.terminate(nil)
        }
    }

    private func record(name: String, page: String, index: Int, size: CGSize, outputDir: URL, schemeHandler: LocalSchemeHandler) async {
        // Offscreen pages count as hidden: WebKit stops requestAnimationFrame and slows timers.
        // Drive frames from timers and lift the timer throttling, for this dev mode only.
        let setup = """
        window.requestAnimationFrame = f => setTimeout(() => f(performance.now()), 16);
        window.__recDemoStyle = 1;
        window.__recFullRange = 1;
        window.__recMaxPixels = \(Int(size.width * size.height * 4));
        window.__recBitrate = 16e6;
        """
        let host = HostWebView(schemeHandler: schemeHandler, extraScript: setup)
        let prefs = host.webView.configuration.preferences
        Self.setPrivate(prefs, "_setHiddenPageDOMTimerThrottlingEnabled:", false)
        Self.setPrivate(prefs, "_setPageVisibilityBasedProcessSuppressionEnabled:", false)

        let frame = CGRect(x: -40_000 - CGFloat(index) * 4_000, y: -40_000, width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.webView.frame = CGRect(origin: .zero, size: size)
        window.contentView = host.webView
        window.orderFrontRegardless()
        hosts.append(host)
        windows.append(window)

        host.load(page: page)
        try? await Task.sleep(for: .seconds(5))

        let fps = try? await host.webView.callAsyncJavaScript(
            "const f0 = frameN; await new Promise(r => setTimeout(r, 1000)); return frameN - f0;",
            contentWorld: .page
        )
        print("\(name): \(fps ?? "?") frames per second offscreen")

        let script = """
        const r = await window.desklandRecord(() => {});
        const data = await new Promise((ok, fail) => {
          const reader = new FileReader();
          reader.onload = () => ok(reader.result);
          reader.onerror = () => fail(reader.error);
          reader.readAsDataURL(r.blob);
        });
        return r.mime + '|' + data;
        """
        do {
            let result = try await host.webView.callAsyncJavaScript(script, contentWorld: .page) as? String ?? ""
            let parts = result.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let base64 = parts[1].split(separator: ",", maxSplits: 1).last, let data = Data(base64Encoded: String(base64)) else {
                print("\(name): recorder returned no video")
                return
            }
            let url = outputDir.appending(path: "\(name).\(parts[0] == "video/webm" ? "webm" : "mp4")")
            try data.write(to: url)
            print("\(name): saved \(url.path) (\(data.count / 1024) KB)")
        } catch {
            print("\(name): recording failed: \(error)")
        }
        window.orderOut(nil)
    }

    /// Calls a private WKPreferences setter if this WebKit has it.
    private static func setPrivate(_ prefs: WKPreferences, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: prefs), selector) else {
            print("WebKit has no \(name)")
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(prefs, selector, value)
    }
}
