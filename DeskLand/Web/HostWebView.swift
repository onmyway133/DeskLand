import AppKit
import UniformTypeIdentifiers
import WebKit

/// The upstream pages talk to their Windows host through WebView2's `window.chrome.webview`.
/// This shim recreates that object on top of WKWebView so the pages run unchanged.
private let webviewShim = """
(() => {
  window.__deskErrors = [];
  addEventListener('error', e => window.__deskErrors.push(String(e.message) + ' @' + e.lineno));
  const listeners = new Set();
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage: m => window.webkit.messageHandlers.host.postMessage(typeof m === 'string' ? m : JSON.stringify(m)),
    addEventListener: (type, f) => { if (type === 'message') listeners.add(f); },
    removeEventListener: (type, f) => { if (type === 'message') listeners.delete(f); },
  };
  window.__deskHost = data => {
    for (const f of listeners) {
      try { f({ data }); } catch (e) { console.error(e); }
    }
  };
})();
"""

/// A WKWebView that loads pages from `deskland://app/...` and exchanges string messages with Swift.
final class HostWebView: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let scheme = "deskland"

    let webView: WKWebView
    var onMessage: (String) -> Void = { _ in }
    var onCrash: () -> Void = {}

    init(schemeHandler: LocalSchemeHandler, extraScript: String? = nil) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(
            WKUserScript(source: webviewShim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        if let extraScript {
            config.userContentController.addUserScript(
                WKUserScript(source: extraScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "host")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func load(page: String) {
        guard let url = URL(string: "\(Self.scheme)://app/\(page)") else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    /// Delivers a message to the page's `chrome.webview` listeners, like PostWebMessageAsString.
    func post(_ message: String) {
        webView.evaluateJavaScript("window.__deskHost && window.__deskHost(\(JSON.string(message)))", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String {
            onMessage(text)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Web content process ended, reloading")
        onCrash()
    }
}

/// WKUserContentController keeps its handlers alive, so hold the real one weakly.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Serves `deskland://app/<file>` from the bundled WebContent folder and
/// `deskland://share/<file>` from the folder where shared images and clips are saved.
/// Upstream does the same with WebView2's virtual host mapping (app.local, share.local).
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    private let roots: [String: URL] = [
        "app": Paths.webDir,
        "share": Paths.shareDir,
    ]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard
            let url = task.request.url,
            let host = url.host(),
            let root = roots[host]?.standardizedFileURL,
            let file = Optional(root.appending(path: url.path(percentEncoded: false)).standardizedFileURL),
            file.path.hasPrefix(root.path + "/"),
            let data = try? Data(contentsOf: file)
        else {
            respond(task, status: 404, data: Data(), mime: "text/plain", total: 0)
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        // Video playback asks for byte ranges.
        if let range = task.request.value(forHTTPHeaderField: "Range"), let bounds = Self.parse(range, count: data.count) {
            respond(task, status: 206, data: data.subdata(in: bounds), mime: mime, total: data.count, range: bounds)
        } else {
            respond(task, status: 200, data: data, mime: mime, total: data.count)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, status: Int, data: Data, mime: String, total: Int, range: Range<Int>? = nil) {
        var headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
        ]
        if let range {
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
        }
        let response = HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func parse(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), count > 0 else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let start = Int(parts[0]) ?? 0
        let end = min(Int(parts[1]) ?? count - 1, count - 1)
        guard start <= end else { return nil }
        return start..<(end + 1)
    }
}
