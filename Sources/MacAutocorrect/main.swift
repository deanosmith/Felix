import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let engine = AutocorrectEngine()
    private let status = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private let counter = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let activity = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var pause: NSMenuItem!
    private var undo: NSMenuItem!
    private var ignore: NSMenuItem!
    private var sensitivityItems: [NSMenuItem] = []
    private var feedbackPanel: NSPanel?
    private var feedbackTask: Task<Void, Never>?
    private var showingCorrection = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        status.isEnabled = false
        counter.isEnabled = false
        activity.isEnabled = false
        menu.addItem(status)
        menu.addItem(counter)
        menu.addItem(activity)
        menu.addItem(.separator())
        pause = add("Pause Orth", action: #selector(togglePaused), symbol: "pause", to: menu)
        let sensitivityMenu = NSMenu(title: "Sensitivity")
        sensitivityMenu.autoenablesItems = false
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        sensitivityItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Sensitivity")
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)
        for level in CorrectionSensitivity.allCases {
            let option = NSMenuItem(title: level.title, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = level.rawValue
            sensitivityMenu.addItem(option)
            sensitivityItems.append(option)
        }
        undo = add("Undo Last Correction", action: #selector(undoLast), symbol: "arrow.uturn.backward", to: menu)
        ignore = add("Ignore Last Corrected Word", action: #selector(ignoreLast), symbol: "text.badge.minus", to: menu)
        menu.addItem(.separator())
        add("Check Focused Field", action: #selector(checkFocusedField), symbol: "stethoscope", to: menu)
        add("Accessibility Settings...", action: #selector(openAccessibility), symbol: "accessibility", to: menu)
        add("Input Monitoring Settings...", action: #selector(openInputMonitoring), symbol: "keyboard", to: menu)
        menu.addItem(.separator())
        add("Quit Orth", action: #selector(quit), symbol: "power", to: menu)
        item.menu = menu
        statusItem = item

        engine.onChange = { [weak self] in self?.updateMenu() }
        engine.onCorrection = { [weak self] rectangle in self?.showCorrection(at: rectangle) }
        engine.start()
        engine.requestAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        feedbackTask?.cancel()
        feedbackPanel?.orderOut(nil)
        engine.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        engine.setMenuOpen(true)
        updateMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        engine.setMenuOpen(false)
    }

    @discardableResult
    private func add(_ title: String, action: Selector, symbol: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        menu.addItem(item)
        return item
    }

    private func updateMenu() {
        status.title = engine.status
        counter.title = "Corrections this session: \(engine.correctionCount)"
        activity.title = engine.activity
        pause.title = engine.isPaused ? "Resume Orth" : "Pause Orth"
        pause.image = NSImage(systemSymbolName: engine.isPaused ? "play" : "pause", accessibilityDescription: pause.title)
        for option in sensitivityItems {
            option.state = (option.representedObject as? String) == engine.sensitivity.rawValue ? .on : .off
        }
        undo.isEnabled = engine.canUndo
        ignore.isEnabled = engine.lastCorrection != nil
        statusItem?.button?.image = NSImage(
            systemSymbolName: showingCorrection ? "checkmark.circle.fill"
                : (engine.isPaused ? "pause.circle" : "text.badge.checkmark"),
            accessibilityDescription: "Orth"
        )
        statusItem?.button?.contentTintColor = showingCorrection ? .systemGreen : nil
        statusItem?.button?.toolTip = "Orth: \(engine.status) (\(engine.sensitivity.title))"
    }

    private func showCorrection(at rectangle: CGRect?) {
        feedbackTask?.cancel()
        feedbackPanel?.orderOut(nil)
        showingCorrection = true
        updateMenu()

        if let rectangle, let primaryScreen = NSScreen.screens.first,
           rectangle.width < 1_000, rectangle.height < 120 {
            let frame = NSRect(
                x: rectangle.minX - 2,
                y: primaryScreen.frame.maxY - rectangle.maxY - 1,
                width: rectangle.width + 4,
                height: rectangle.height + 2
            )
            let panel = feedbackPanel ?? NSPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
            panel.contentView?.layer?.cornerRadius = 3
            panel.setFrame(frame, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            feedbackPanel = panel
        }

        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    for opacity in [0.8, 0.6, 0.4, 0.2, 0.0] {
                        self?.feedbackPanel?.alphaValue = opacity
                        try await Task.sleep(for: .milliseconds(25))
                    }
                }
            } catch { return }
            self?.feedbackPanel?.orderOut(nil)
            self?.showingCorrection = false
            self?.updateMenu()
        }
    }

    @objc private func togglePaused() {
        engine.togglePaused()
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let value = CorrectionSensitivity(rawValue: rawValue)
        else { return }
        engine.setSensitivity(value)
    }

    @objc private func undoLast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.engine.undoLastCorrection()
        }
    }

    @objc private func ignoreLast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.engine.ignoreLastWord()
        }
    }

    @objc private func checkFocusedField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.engine.inspectFocusedField()
        }
    }

    @objc private func openAccessibility() {
        engine.requestAccessibilityPermission()
        openSettings("Privacy_Accessibility")
    }

    @objc private func openInputMonitoring() {
        engine.requestKeyboardPermission()
        openSettings("Privacy_ListenEvent")
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()