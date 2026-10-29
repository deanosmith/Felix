import AppKit
import QuartzCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct CorrectionFeedback {
        let panel: NSPanel?
        let task: Task<Void, Never>
    }

    private var statusItem: NSStatusItem?
    private let engine = AutocorrectEngine()
    private let status = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private let counter = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let activity = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var pause: NSMenuItem!
    private var ignore: NSMenuItem!
    private var sensitivityItems: [NSMenuItem] = []
    private var applicationFilterModeItems: [NSMenuItem] = []
    private let includedAppsMenu = NSMenu(title: "Included Apps")
    private let excludedAppsMenu = NSMenu(title: "Excluded Apps")
    private var correctionFeedback: [UUID: CorrectionFeedback] = [:]
    private var glowColor: NSColor = {
        guard let components = UserDefaults.standard.array(forKey: "glowColor") as? [Double],
              components.count == 3, components.allSatisfy({ (0...1).contains($0) })
        else { return .white }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
    }()

    private var showingCorrection: Bool { !correctionFeedback.isEmpty }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        status.isEnabled = false
        counter.isEnabled = false
        activity.isEnabled = false
        pause = add("Pause", action: #selector(togglePaused), symbol: "pause", to: menu)
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
        let applicationsMenu = NSMenu(title: "Apps")
        applicationsMenu.autoenablesItems = false
        let applicationsItem = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        applicationsItem.image = NSImage(systemSymbolName: "app.badge.checkmark", accessibilityDescription: "Apps")
        applicationsItem.submenu = applicationsMenu
        menu.addItem(applicationsItem)
        for mode in ApplicationFilterMode.allCases {
            let option = NSMenuItem(title: mode.title, action: #selector(setApplicationFilterMode(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = mode.rawValue
            applicationsMenu.addItem(option)
            applicationFilterModeItems.append(option)
        }
        applicationsMenu.addItem(.separator())
        for listMenu in [includedAppsMenu, excludedAppsMenu] {
            listMenu.autoenablesItems = false
            listMenu.delegate = self
            let listItem = NSMenuItem(title: listMenu.title, action: nil, keyEquivalent: "")
            listItem.submenu = listMenu
            applicationsMenu.addItem(listItem)
        }
        add("Glow Colour...", action: #selector(chooseGlowColor), symbol: "paintpalette", to: menu)
        ignore = add("Ignore Last Word", action: #selector(ignoreLast), symbol: "text.badge.minus", to: menu)
        ignore.toolTip = "Ignore the last corrected word"
        let settingsMenu = NSMenu(title: "Settings")
        settingsMenu.autoenablesItems = false
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        settingsMenu.addItem(status)
        settingsMenu.addItem(counter)
        settingsMenu.addItem(activity)
        settingsMenu.addItem(.separator())
        add("Check Focused Field", action: #selector(checkFocusedField), symbol: "stethoscope", to: settingsMenu)
        add("Accessibility Settings...", action: #selector(openAccessibility), symbol: "accessibility", to: settingsMenu)
        add("Input Monitoring Settings...", action: #selector(openInputMonitoring), symbol: "keyboard", to: settingsMenu)
        menu.addItem(.separator())
        add("Quit", action: #selector(quit), symbol: "power", to: menu)
        item.menu = menu
        statusItem = item

        engine.onChange = { [weak self] in self?.updateMenu() }
        engine.onCorrection = { [weak self] rectangle in self?.showCorrection(at: rectangle) }
        engine.start()
        engine.requestAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for feedback in correctionFeedback.values {
            feedback.task.cancel()
            feedback.panel?.orderOut(nil)
        }
        correctionFeedback.removeAll()
        engine.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let list = applicationList(for: menu) {
            updateApplicationsMenu(menu, list: list)
        } else if menu === statusItem?.menu {
            updateMenu()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem?.menu { engine.setMenuOpen(true) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem?.menu { engine.setMenuOpen(false) }
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
        pause.title = engine.isPaused ? "Resume" : "Pause"
        pause.image = NSImage(systemSymbolName: engine.isPaused ? "play" : "pause", accessibilityDescription: pause.title)
        for option in sensitivityItems {
            option.state = (option.representedObject as? String) == engine.sensitivity.rawValue ? .on : .off
        }
        for option in applicationFilterModeItems {
            option.state = (option.representedObject as? String) == engine.applicationFilter.mode.rawValue ? .on : .off
        }
        ignore.isEnabled = engine.lastCorrection != nil
        statusItem?.button?.image = NSImage(
            systemSymbolName: showingCorrection ? "checkmark.circle.fill"
                : (engine.isPaused ? "wrench" : "wrench.fill"),
            accessibilityDescription: "Orth"
        )
        statusItem?.button?.contentTintColor = showingCorrection ? .systemGreen
            : (engine.isPaused ? .secondaryLabelColor : nil)
        statusItem?.button?.toolTip = "Orth: \(engine.status) (\(engine.sensitivity.title))"
    }

    private func showCorrection(at rectangle: CGRect?) {
        let identifier = UUID()
        let feedbackDuration = 1.6
        let deadline = ContinuousClock.now.advanced(by: .seconds(feedbackDuration))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var feedbackPanel: NSPanel?
        if let rectangle, let primaryScreen = NSScreen.screens.first,
           rectangle.width < 1_000, rectangle.height < 120 {
            let underlineFrame = NSRect(
                x: rectangle.minX,
                y: primaryScreen.frame.maxY - rectangle.maxY - 2,
                width: rectangle.width,
                height: 2
            )
            let glowInset: CGFloat = 10
            let frame = underlineFrame.insetBy(dx: -glowInset, dy: -glowInset)
            let panel = NSPanel(
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
            panel.setFrame(frame, display: false)
            let feedbackGlow = NSView(
                frame: NSRect(origin: .zero, size: frame.size).insetBy(dx: glowInset, dy: glowInset)
            )
            panel.contentView?.addSubview(feedbackGlow)
            feedbackGlow.wantsLayer = true
            feedbackGlow.layer?.backgroundColor = glowColor.withAlphaComponent(0.85).cgColor
            feedbackGlow.layer?.cornerRadius = 1
            feedbackGlow.layer?.shadowColor = glowColor.cgColor
            feedbackGlow.layer?.shadowOpacity = 0.9
            feedbackGlow.layer?.shadowRadius = 6
            feedbackGlow.layer?.shadowOffset = .zero
            feedbackGlow.layer?.masksToBounds = false
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            feedbackPanel = panel
            if !reduceMotion {
                let glow = CAKeyframeAnimation(keyPath: "opacity")
                glow.values = [0, 1, 0.65, 1, 0]
                glow.keyTimes = [0, 0.12, 0.35, 0.55, 1]
                glow.duration = feedbackDuration
                glow.calculationMode = .linear
                glow.timingFunctions = Array(
                    repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4
                )
                glow.fillMode = .both
                glow.isRemovedOnCompletion = false
                feedbackGlow.layer?.add(glow, forKey: "correctionGlow")
            }
        }

        let task = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch { return }
            guard let self else { return }
            correctionFeedback.removeValue(forKey: identifier)?.panel?.orderOut(nil)
            updateMenu()
        }
        correctionFeedback[identifier] = CorrectionFeedback(panel: feedbackPanel, task: task)
        updateMenu()
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

    @objc private func chooseGlowColor() {
        let panel = NSColorPanel.shared
        panel.title = "Glow Colour"
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = glowColor
        panel.setTarget(self)
        panel.setAction(#selector(setGlowColor(_:)))
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }

    @objc private func setGlowColor(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB) else {
            NSSound.beep()
            return
        }
        glowColor = color
        UserDefaults.standard.set(
            [color.redComponent, color.greenComponent, color.blueComponent], forKey: "glowColor"
        )
    }

    private func applicationList(for menu: NSMenu?) -> ApplicationFilterMode? {
        if menu === includedAppsMenu { return .include }
        if menu === excludedAppsMenu { return .exclude }
        return nil
    }

    private func updateApplicationsMenu(_ menu: NSMenu, list: ApplicationFilterMode) {
        menu.removeAllItems()
        add("Add App...", action: #selector(addApplication(_:)), symbol: "plus", to: menu)
        menu.addItem(.separator())

        let selected = engine.applicationFilter.applications(in: list)
        var applications: [String: String] = [:]
        for identifier in selected {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                applications[identifier] = FileManager.default.displayName(atPath: url.path)
            } else {
                applications[identifier] = identifier
            }
        }
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let identifier = application.bundleIdentifier?.lowercased()
            else { continue }
            applications[identifier] = application.localizedName ?? identifier
        }
        for (identifier, name) in applications.sorted(by: {
            let order = $0.value.localizedStandardCompare($1.value)
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }) {
            let item = NSMenuItem(title: name, action: #selector(toggleApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identifier
            item.toolTip = identifier
            item.state = selected.contains(identifier) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func setApplicationFilterMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = ApplicationFilterMode(rawValue: rawValue)
        else {
            NSSound.beep()
            return
        }
        engine.setApplicationFilterMode(mode)
    }

    @objc private func toggleApplication(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let list = applicationList(for: sender.menu)
        else {
            NSSound.beep()
            return
        }
        let selected = engine.applicationFilter.applications(in: list).contains(identifier)
        engine.setApplication(identifier, selected: !selected, in: list)
    }

    @objc private func addApplication(_ sender: NSMenuItem) {
        guard let list = applicationList(for: sender.menu) else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.title = list == .include ? "Include an App" : "Exclude an App"
        panel.prompt = "Add App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to Add App"
            alert.informativeText = "The selected app does not have a bundle identifier. Choose another app."
            alert.runModal()
            return
        }
        engine.setApplication(identifier, selected: true, in: list)
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