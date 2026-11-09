import AppKit

/// Tells whether another app's window fills the screen (zoomed or full screen),
/// which is when upstream pauses the animation to save power.
enum CoverDetector {
    static func isCovered(_ screen: NSScreen) -> Bool {
        guard
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return false
        }
        let bounds = CGDisplayBounds(displayID)
        // The usable area: the screen minus the menu bar and Dock.
        let needed = screen.visibleFrame.width * screen.visibleFrame.height * 0.97
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in list {
            guard
                info[kCGWindowLayer as String] as? Int == 0,
                info[kCGWindowOwnerPID as String] as? pid_t != ownPID,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let windowBounds = CGRect(dictionaryRepresentation: boundsInfo)
            else {
                continue
            }
            let overlap = windowBounds.intersection(bounds)
            if !overlap.isNull, overlap.width * overlap.height >= needed {
                return true
            }
        }
        return false
    }
}
