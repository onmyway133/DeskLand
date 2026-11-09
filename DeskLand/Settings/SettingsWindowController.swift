import AppKit

/// The upstream settings page (theme browser, sliders, live preview, sharing) in a normal window.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let host: HostWebView
    private let window: NSWindow

    var onClose: () -> Void = {}

    init(schemeHandler: LocalSchemeHandler, onMessage: @escaping (String) -> Void) {
        host = HostWebView(schemeHandler: schemeHandler)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "DeskLand"
        window.minSize = NSSize(width: 720, height: 560)
        window.isReleasedWhenClosed = false
        window.contentView = host.webView
        window.delegate = self
        window.setFrameAutosaveName("DeskLandSettings")
        if !window.setFrameUsingName("DeskLandSettings") {
            window.center()
        }
        host.onMessage = onMessage
        host.load(page: "settings.html")
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func post(_ message: String) {
        host.post(message)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
