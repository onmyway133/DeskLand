import AppKit
import os

let log = Logger(subsystem: "com.onmyway133.DeskLand", category: "app")

enum Paths {
    static let dataDir: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "DeskLand", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The theme pages from upstream Deskland, bundled unchanged except for a few strings.
    static var webDir: URL {
        Bundle.main.resourceURL!.appending(path: "WebContent", directoryHint: .isDirectory)
    }

    static let shareDir = URL.picturesDirectory.appending(path: "DeskLand", directoryHint: .isDirectory)
}

enum JSON {
    static func string(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
}

/// Timer and notification closures are @Sendable, but they always fire on the main run loop here.
@discardableResult
func repeating(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
        MainActor.assumeIsolated { body() }
    }
}

func observe(_ name: Notification.Name, center: NotificationCenter = .default, _ body: @escaping @MainActor () -> Void) {
    center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { body() }
    }
}

/// Upstream messages measure the screen in physical pixels and the pages divide by devicePixelRatio.
extension NSScreen {
    var pixelSize: CGSize {
        CGSize(width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor)
    }
}
