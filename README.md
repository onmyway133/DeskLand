# DeskLand

A macOS port of [Deskland Preview](https://github.com/BLEZZ0102/Deskland), the adaptive wallpaper that reshapes its scenery around your desktop icons.

The theme pages in `WebContent/` come from upstream commit `9818b57` and are unchanged except for the "launch at login" strings in `i18n/`. The macOS host in `DeskLand/` replaces upstream's Windows host (`host/DesktopHost.cs`).

## How it works

- **Wallpaper window:** a borderless window at `desktopWindow + 1`, which is above the system wallpaper and below Finder's desktop icons. It joins all Spaces and ignores the mouse. It covers the primary display only, like upstream.
- **Theme pages:** a WKWebView serves the bundled pages from `deskland://app/...` (upstream uses WebView2's `app.local`). An injected script recreates WebView2's `window.chrome.webview`, so the pages run unchanged.
- **Desktop icons:** read every 400 ms from Finder's accessibility tree and sent to the page in physical pixels, matching upstream's message format. This needs Accessibility access.
- **Pause:** the animation pauses when another window fills the screen, when the displays sleep, or from the menu.
- **Settings:** upstream's settings page in a normal window. Sharing saves to `~/Pictures/DeskLand` and copies the result to the clipboard.

## Build

Open `DeskLand.xcodeproj` in Xcode 27.2 and run, or:

```sh
xcodebuild -project DeskLand.xcodeproj -scheme DeskLand -derivedDataPath DerivedData build
```

`DESKLAND_SNAPSHOT=<dir>` renders both themes and the settings page in offscreen windows with sample icons, saves PNGs and quits. It doesn't touch the desktop.

## License

GPL-3.0, same as upstream (see `LICENSE`). Theme code and assets © the Deskland authors. Upstream's `TRADEMARKS.md` asks modified distributions to use their own name and icon and not imply endorsement. This port is independent and not affiliated with the Deskland project.
