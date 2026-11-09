import Foundation

/// Current theme, interface language and the parameters the user changed per theme.
/// Same shape as upstream's settings.json, stored in Application Support/DeskLand.
final class SettingsStore {
    private let fileURL = Paths.dataDir.appending(path: "settings.json")
    private var saveTask: Task<Void, Never>?

    var theme = "beach"
    var lang = "auto"
    var params: [String: [String: Any]] = [:]
    private(set) var existedAtLaunch = false

    func load() {
        guard
            let data = try? Data(contentsOf: fileURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        existedAtLaunch = true
        if let value = root["theme"] as? String { theme = value }
        if let value = root["lang"] as? String { lang = value }
        if let value = root["params"] as? [String: [String: Any]] { params = value }
    }

    func paramsFor(_ theme: String) -> [String: Any] {
        params[theme] ?? [:]
    }

    /// Sliders send many changes in a row, so write once they settle.
    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { save() }
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        let root: [String: Any] = ["version": 1, "theme": theme, "lang": lang, "params": params]
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Saving settings failed: \(error.localizedDescription)")
        }
    }
}

struct Theme {
    let id: String
    let page: String
}

/// Reads WebContent/themes.json. Only "ready" themes marked free have a page, matching upstream.
enum Themes {
    static func load() -> [String: Theme] {
        guard
            let data = try? Data(contentsOf: Paths.webDir.appending(path: "themes.json")),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["themes"] as? [[String: Any]]
        else {
            log.error("Couldn't read themes.json")
            return [:]
        }
        var result: [String: Theme] = [:]
        for item in list {
            guard
                let id = item["id"] as? String,
                let page = item["page"] as? String,
                item["status"] as? String == "ready",
                item["product"] as? String == "free"
            else {
                continue
            }
            result[id] = Theme(id: id, page: page)
        }
        return result
    }
}

enum Language {
    static let supported = ["zh-CN", "en"]

    static var system: String {
        let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return first.hasPrefix("zh") ? "zh-CN" : "en"
    }

    static func effective(_ setting: String) -> String {
        supported.contains(setting) ? setting : system
    }
}
