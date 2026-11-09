import AppKit
import ServiceManagement

/// Menu bar agent that owns the wallpaper and the settings window.
/// Mirrors upstream's HostContext: tray menu, settings messages, theme switching and sharing.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore()
    private let schemeHandler = LocalSchemeHandler()
    private var themes: [String: Theme] = [:]
    private var wallpaper: WallpaperController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var lastShare: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["DESKLAND_SNAPSHOT"] {
            SnapshotRunner.shared.run(outputDir: URL(filePath: dir), schemeHandler: schemeHandler)
            return
        }
        if let dir = ProcessInfo.processInfo.environment["DESKLAND_RECORD"] {
            RecordRunner.shared.run(outputDir: URL(filePath: dir), schemeHandler: schemeHandler)
            return
        }

        settings.load()
        themes = Themes.load()
        setUpStatusItem()
        startWallpaper()

        if !IconReader.isTrusted {
            IconReader.requestAccess()
        }
        if !settings.existedAtLaunch {
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        settings.save()
        wallpaper?.stop()
    }

    // MARK: - Wallpaper

    private func startWallpaper() {
        if themes[settings.theme] == nil {
            settings.theme = themes["beach"] != nil ? "beach" : (themes.keys.sorted().first ?? "beach")
        }
        guard let theme = themes[settings.theme] else {
            log.error("No theme with a page to load")
            return
        }
        let controller = WallpaperController(page: theme.page, schemeHandler: schemeHandler)
        controller.settingsMessage = { [weak self] in
            guard let self else { return "{}" }
            return JSON.string(["t": "settings", "v": settings.paramsFor(settings.theme)] as [String: Any])
        }
        controller.onIconsChanged = { [weak self] message in
            self?.settingsWindow?.post(message)
        }
        controller.onRecordProgress = { [weak self] progress in
            self?.settingsWindow?.post(#"{"t":"recProgress","p":\#(Double(progress) ?? 0)}"#)
        }
        controller.start()
        wallpaper = controller
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "beach.umbrella", accessibilityDescription: "DeskLand")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt each time it opens so checkmarks and the access item are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        let pause = menu.addItem(withTitle: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
        pause.state = wallpaper?.manualPause == true ? .on : .off
        menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = isLaunchAtLogin ? .on : .off
        if !IconReader.isTrusted {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Allow Reading Desktop Icons…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DeskLand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func togglePause() {
        wallpaper?.manualPause.toggle()
    }

    @objc private func reload() {
        wallpaper?.reload()
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLogin)
    }

    @objc private func openAccessibilitySettings() {
        IconReader.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var isLaunchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login change failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings window

    private func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(schemeHandler: schemeHandler) { [weak self] message in
                self?.handleSettingsMessage(message)
            }
            controller.onClose = { [weak self] in
                self?.settingsWindow = nil
            }
            settingsWindow = controller
        }
        settingsWindow?.show()
    }

    private func handleSettingsMessage(_ text: String) {
        guard
            let message = JSON.parse(text) as? [String: Any],
            let type = message["t"] as? String,
            let window = settingsWindow
        else {
            return
        }
        switch type {
        case "hello":
            let screen = NSScreen.screens.first?.pixelSize ?? .zero
            window.post(JSON.string([
                "t": "init",
                "theme": settings.theme,
                "params": settings.params,
                "screen": ["w": Int(screen.width), "h": Int(screen.height)],
                "autostart": isLaunchAtLogin,
                "autostartWarn": false,
                "autostartSw": "",
                "lang": settings.lang,
                "langEff": Language.effective(settings.lang),
                "langSys": Language.system,
            ] as [String: Any]))
            if let icons = wallpaper?.currentIcons, !icons.isEmpty {
                window.post(icons)
            }

        case "set":
            guard let theme = message["theme"] as? String, let key = message["key"] as? String else { return }
            let value = message["value"] ?? NSNull()
            settings.params[theme, default: [:]][key] = value
            if theme == settings.theme {
                wallpaper?.post(JSON.string(["t": "settings", "v": [key: value]] as [String: Any]))
            }
            settings.saveSoon()

        case "reset":
            guard let theme = message["theme"] as? String else { return }
            settings.params[theme] = nil
            if theme == settings.theme {
                wallpaper?.post(#"{"t":"reset"}"#)
            }
            settings.saveSoon()

        case "theme":
            guard let id = message["id"] as? String, let theme = themes[id] else {
                window.post(JSON.string(["t": "themeChanged", "id": settings.theme] as [String: Any]))
                return
            }
            guard id != settings.theme else { return }
            settings.theme = id
            settings.saveSoon()
            wallpaper?.load(page: theme.page)

        case "lang":
            guard let value = message["v"] as? String else { return }
            settings.lang = value
            settings.saveSoon()
            window.post(JSON.string([
                "t": "lang", "v": value, "eff": Language.effective(value), "sys": Language.system,
            ] as [String: Any]))

        case "autostart":
            setLaunchAtLogin(message["v"] as? Bool == true)
            window.post(JSON.string(["t": "autostart", "v": isLaunchAtLogin] as [String: Any]))

        case "share":
            shareImage()

        case "shareVideo":
            shareVideo()

        case "openShare":
            if let lastShare { NSWorkspace.shared.open(lastShare) }

        case "revealShare":
            if let lastShare { NSWorkspace.shared.activateFileViewerSelecting([lastShare]) }

        case "openWebsite":
            if let url = URL(string: "https://deskland.app/") { NSWorkspace.shared.open(url) }

        default:
            // autostartWarnSeen, updateCheck, updateProgram: Windows-only or not part of this port.
            break
        }
    }

    // MARK: - Sharing

    private func shareImage() {
        guard let wallpaper else {
            postShareFailure("The wallpaper isn't ready yet")
            return
        }
        wallpaper.requestSnapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let shot):
                do {
                    let url = try ShareSaver.saveImage(dataURL: shot.png)
                    lastShare = url
                    settingsWindow?.post(JSON.string([
                        "t": "shareResult", "ok": true, "thumb": shot.thumb, "path": url.path,
                    ] as [String: Any]))
                } catch {
                    postShareFailure(error.localizedDescription)
                }
            case .failure(let error):
                postShareFailure(error.message)
            }
        }
    }

    private func shareVideo() {
        guard let wallpaper else {
            postShareFailure("The wallpaper isn't ready yet")
            return
        }
        wallpaper.requestRecording { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let clip):
                do {
                    let url = try ShareSaver.saveVideo(dataURL: clip.video, mime: clip.mime)
                    lastShare = url
                    let name = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                    settingsWindow?.post(JSON.string([
                        "t": "shareResult", "ok": true, "kind": "video", "thumb": clip.poster,
                        "path": url.path, "url": "\(HostWebView.scheme)://share/\(name)",
                    ] as [String: Any]))
                } catch {
                    postShareFailure(error.localizedDescription)
                }
            case .failure(let error):
                postShareFailure(error.message)
            }
        }
    }

    private func postShareFailure(_ text: String) {
        settingsWindow?.post(JSON.string([
            "t": "shareResult", "ok": false, "path": NSNull(), "msg": text,
        ] as [String: Any]))
    }
}
