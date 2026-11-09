import AppKit
import ApplicationServices

/// Reads where Finder draws the desktop icons, through Finder's accessibility tree.
/// This replaces upstream's cross-process reads of the Windows desktop ListView.
///
/// Not verified on a Mac with desktop icons turned on: the tree shape below (a top-level
/// AXScrollArea holding AXImage items) is the expected layout, and the label allowance
/// is an estimate. Check both with Accessibility Inspector if icons come out wrong.
final class IconReader {
    struct Result: Equatable {
        /// False when Finder isn't showing desktop icons, so the theme fills the whole screen.
        var visible: Bool
        /// Icon frames in global coordinates, top-left origin, in points.
        var rects: [CGRect]
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccess() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func read() -> Result {
        guard Self.isTrusted else {
            return Result(visible: true, rects: [])
        }
        guard
            let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else {
            return Result(visible: false, rects: [])
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)

        // The desktop is a scroll area hanging directly off the app, unlike Finder windows.
        guard let desktop = children(app).first(where: { role($0) == kAXScrollAreaRole }) else {
            return Result(visible: false, rects: [])
        }
        var rects: [CGRect] = []
        collect(desktop, depth: 0, into: &rects)
        let label = labelHeight()
        return Result(visible: true, rects: rects.map { rect in
            // Upstream sends icon plus label bounds. If Finder only reports the square image,
            // grow it downward to cover the name underneath.
            guard rect.height < rect.width * 1.15 else { return rect }
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + label)
        })
    }

    private func collect(_ element: AXUIElement, depth: Int, into rects: inout [CGRect]) {
        guard depth < 4 else { return }
        for child in children(element) {
            if role(child) == kAXImageRole, let rect = frame(child) {
                rects.append(rect)
            } else {
                collect(child, depth: depth + 1, into: &rects)
            }
        }
    }

    /// Two lines of label text at Finder's desktop text size (12pt unless changed).
    private func labelHeight() -> CGFloat {
        let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        let icon = settings?["IconViewSettings"] as? [String: Any]
        let textSize = (icon?["textSize"] as? NSNumber)?.doubleValue ?? 12
        return CGFloat((textSize * 1.3 * 2 + 6).rounded())
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(element, kAXPositionAttribute),
            let sizeValue = attribute(element, kAXSizeAttribute)
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}
