import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = Self.appIcon
        mainController = MainWindowController()
        buildMenu()
        mainController.showWindow(nil)
        mainController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // `SpaceMongerMac <path>` scans that folder right away.
        if CommandLine.arguments.count > 1 {
            mainController.scan(URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The original's icon (res/SpaceMonger.ico), shipped as a pre-upscaled PNG.
    static let appIcon: NSImage? = Bundle.module.url(forResource: "AppIcon", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()
        let wc = mainController!

        /// Window commands target the controller directly; it validates them
        /// (enabled state and checkmarks) via NSMenuItemValidation.
        func item(_ title: String, _ action: Selector?, _ key: String,
                  target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target ?? wc
            return i
        }

        // --- Application menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("About SpaceMonger", #selector(about(_:)), "", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(MainWindowController.openSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide SpaceMonger", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit SpaceMonger", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // --- File menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Open Drive…", #selector(MainWindowController.openFolder(_:)), "o"))
        fileMenu.addItem(item("Reload", #selector(MainWindowController.reload(_:)), "r"))
        let reloadFolder = item("Reload Folder", #selector(MainWindowController.reloadFolder(_:)), "r")
        reloadFolder.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(reloadFolder)
        let fullRescan = item("Full Rescan", #selector(MainWindowController.fullRescan(_:)), "R")  // ⇧⌘R
        fileMenu.addItem(fullRescan)
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Open", #selector(MainWindowController.openSelected(_:)), "\u{F701}"))  // ⌘↓, as in Finder
        fileMenu.addItem(item("Reveal in Finder", #selector(MainWindowController.reveal(_:)), ""))
        fileMenu.addItem(item("Move to Trash", #selector(MainWindowController.trash(_:)), "\u{8}"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Properties…", #selector(MainWindowController.showProperties(_:)), "i"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // --- View menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Zoom In", #selector(MainWindowController.doZoomIn(_:)), "\u{5D}"))
        viewMenu.addItem(item("Zoom Out", #selector(MainWindowController.doZoomOut(_:)), "\u{5B}"))
        viewMenu.addItem(item("Zoom Full", #selector(MainWindowController.doFull(_:)), "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Show Free Space", #selector(MainWindowController.toggleFreeSpace(_:)), ""))
        let units = item("Decimal Size Units (like Finder)",
                         #selector(MainWindowController.toggleDecimalUnits(_:)), "")
        units.toolTip = MainWindowController.unitsHelp
        viewMenu.addItem(units)

        // Zoom animation (original: animated_zoom on/off), plus Smooth.
        let animItem = NSMenuItem(title: "Zoom Animation", action: nil, keyEquivalent: "")
        let animMenu = NSMenu(title: "Zoom Animation")
        for (title, style) in [("Smooth", Settings.ZoomAnimation.smooth),
                               ("Classic (outline)", .classic),
                               ("Off", .off)] {
            let i = item(title, #selector(MainWindowController.setZoomAnimation(_:)), "")
            i.representedObject = style.rawValue
            animMenu.addItem(i)
        }
        animItem.submenu = animMenu
        viewMenu.addItem(animItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func about(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "SpaceMonger (macOS)"
        alert.informativeText = "A Swift/AppKit recreation of the classic SpaceMonger disk-space visualizer.\n\nPick a folder, then click tiles to select and double-click folders to zoom in."
        if let icon = Self.appIcon { alert.icon = icon }
        alert.runModal()
    }
}
