import AppKit

/// Saves what the theme page draws for sharing to ~/Pictures/DeskLand and puts it on the
/// clipboard, like upstream does with the Pictures folder. The page never captures the screen:
/// it draws sample icons and color blocks in place of real file names.
enum ShareSaver {
    static func saveImage(dataURL: String) throws -> URL {
        let bytes = try decode(dataURL)
        let url = try write(bytes, ext: "png")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(bytes, forType: .png)
        if let tiff = NSImage(data: bytes)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        return url
    }

    static func saveVideo(dataURL: String, mime: String) throws -> URL {
        let bytes = try decode(dataURL)
        let url = try write(bytes, ext: mime == "video/webm" ? "webm" : "mp4")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return url
    }

    private static func decode(_ dataURL: String) throws -> Data {
        let base64 = dataURL.split(separator: ",", maxSplits: 1).last.map(String.init) ?? dataURL
        guard let data = Data(base64Encoded: base64) else {
            throw ShareError.badData
        }
        return data
    }

    private static func write(_ data: Data, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let url = Paths.shareDir.appending(path: "DeskLand \(formatter.string(from: .now)).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
