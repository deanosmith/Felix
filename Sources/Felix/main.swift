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
    private var typingProfileItems: [NSMenuItem] = []
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
        let typingMenu = NSMenu(title: "Typing Profile")
        typingMenu.autoenablesItems = false
        let typingItem = NSMenuItem(title: "Typing Profile", action: nil, keyEquivalent: "")
        typingItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Typing Profile")
        typingItem.submenu = typingMenu
        menu.addItem(typingItem)
        for (title, key) in [
            ("Fix Double Capitals", "capitals"),
            ("Prioritise Repeated-Letter Fixes", "repeats"),
            ("Repair Configured Space Mistakes", "spaces")
        ] {
            let option = NSMenuItem(title: title, action: #selector(toggleTypingFeature(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = key
            typingMenu.addItem(option)
            typingProfileItems.append(option)
        }
        typingMenu.addItem(.separator())
        add("Edit Replacements...", action: #selector(editReplacements), symbol: "pencil", to: typingMenu)
        add("Reset Typing Profile...", action: #selector(resetTypingProfile), symbol: "arrow.counterclockwise", to: typingMenu)
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
        ignore = add("Ignore Last Correction", action: #selector(ignoreLast), symbol: "text.badge.minus", to: menu)
        ignore.toolTip = "Ignore the original word or phrase from the last correction"
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
        updateStatusIcon()

        engine.onChange = { [weak self] in self?.updateMenu() }
        engine.onCorrection = { [weak self] rectangle in self?.showCorrection(at: rectangle) }
        engine.onFeedbackReset = { [weak self] in self?.clearCorrectionFeedback() }
        engine.start()
        engine.requestAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clearCorrectionFeedback()
        engine.stop()
    }

    private func clearCorrectionFeedback() {
        for feedback in correctionFeedback.values {
            feedback.task.cancel()
            feedback.panel?.orderOut(nil)
        }
        correctionFeedback.removeAll()
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

    private func wrenchImage(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let wrench = NSBezierPath()
            wrench.move(to: NSPoint(x: 3.4, y: 1))
            wrench.curve(to: NSPoint(x: 1.2, y: 3.8),
                         controlPoint1: NSPoint(x: 1.5, y: 1), controlPoint2: NSPoint(x: 1.2, y: 2.5))
            wrench.curve(to: NSPoint(x: 2, y: 6),
                         controlPoint1: NSPoint(x: 1.2, y: 4.7), controlPoint2: NSPoint(x: 1.6, y: 5.5))
            wrench.line(to: NSPoint(x: 7.1, y: 10.1))
            wrench.curve(to: NSPoint(x: 8, y: 12.8),
                         controlPoint1: NSPoint(x: 7.9, y: 10.8), controlPoint2: NSPoint(x: 8, y: 11.3))
            wrench.curve(to: NSPoint(x: 11.9, y: 17),
                         controlPoint1: NSPoint(x: 8, y: 15.5), controlPoint2: NSPoint(x: 9.4, y: 17))
            wrench.curve(to: NSPoint(x: 15.6, y: 15.4),
                         controlPoint1: NSPoint(x: 13.6, y: 17), controlPoint2: NSPoint(x: 14.9, y: 16.9))
            wrench.line(to: NSPoint(x: 12.6, y: 14.4))
            wrench.curve(to: NSPoint(x: 12.1, y: 13.2),
                         controlPoint1: NSPoint(x: 12.1, y: 14.2), controlPoint2: NSPoint(x: 11.9, y: 13.8))
            wrench.line(to: NSPoint(x: 12.5, y: 11.8))
            wrench.curve(to: NSPoint(x: 13.3, y: 11.3),
                         controlPoint1: NSPoint(x: 12.6, y: 11.3), controlPoint2: NSPoint(x: 12.9, y: 11.2))
            wrench.line(to: NSPoint(x: 16.1, y: 12.1))
            wrench.curve(to: NSPoint(x: 12.1, y: 8.4),
                         controlPoint1: NSPoint(x: 16, y: 9.9), controlPoint2: NSPoint(x: 14.5, y: 8.6))
            wrench.line(to: NSPoint(x: 10.3, y: 8.2))
            wrench.curve(to: NSPoint(x: 8.7, y: 7.1),
                         controlPoint1: NSPoint(x: 9.7, y: 8.1), controlPoint2: NSPoint(x: 9.2, y: 7.7))
            wrench.line(to: NSPoint(x: 5.5, y: 2.4))
            wrench.curve(to: NSPoint(x: 3.4, y: 1),
                         controlPoint1: NSPoint(x: 5, y: 1.5), controlPoint2: NSPoint(x: 4.4, y: 1))
            wrench.close()
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if filled {
                wrench.fill()
            } else {
                wrench.lineWidth = 1.2
                wrench.lineJoinStyle = .round
                wrench.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Felix"
        return image
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = wrenchImage(filled: !engine.isPaused)
        statusItem?.button?.contentTintColor = engine.isPaused ? .secondaryLabelColor : nil
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
        for option in typingProfileItems {
            let enabled: Bool
            switch option.representedObject as? String {
            case "capitals": enabled = engine.typingProfile.fixesCapitals
            case "repeats": enabled = engine.typingProfile.fixesRepeatedLetters
            case "spaces": enabled = engine.typingProfile.fixesSpaces
            default: enabled = false
            }
            option.state = enabled ? .on : .off
        }
        for option in applicationFilterModeItems {
            option.state = (option.representedObject as? String) == engine.applicationFilter.mode.rawValue ? .on : .off
        }
        ignore.isEnabled = engine.lastCorrection != nil
        statusItem?.button?.toolTip = "Felix: \(engine.status) (\(engine.sensitivity.title))"
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
                let glow = CABasicAnimation(keyPath: "opacity")
                glow.fromValue = 1
                glow.toValue = 0
                glow.duration = feedbackDuration
                glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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
        }
        correctionFeedback[identifier] = CorrectionFeedback(panel: feedbackPanel, task: task)
    }

    @objc private func togglePaused() {
        engine.togglePaused()
        updateStatusIcon()
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let value = CorrectionSensitivity(rawValue: rawValue)
        else { return }
        engine.setSensitivity(value)
    }

    @objc private func toggleTypingFeature(_ sender: NSMenuItem) {
        var profile = engine.typingProfile
        switch sender.representedObject as? String {
        case "capitals": profile.fixesCapitals.toggle()
        case "repeats": profile.fixesRepeatedLetters.toggle()
        case "spaces": profile.fixesSpaces.toggle()
        default:
            NSSound.beep()
            return
        }
        saveTypingProfile(profile)
    }

    @objc private func editReplacements() {
        let alert = NSAlert()
        alert.messageText = "Personal Replacements"
        alert.informativeText = "Use lowercase English words: typo = correction, one per line. Each side can contain one or two words. Initial capitalisation is preserved. These explicit rules override spelling and name detection, but not protected fields, technical text, or ignored words."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.contentView.bounds)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = engine.typingProfile.replacementText
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = editor
        NSApplication.shared.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                var profile = engine.typingProfile
                profile.replacements = try TypingProfile.parseReplacements(editor.string)
                try engine.setTypingProfile(profile)
                return
            } catch {
                showTypingProfileError(error)
            }
        }
    }

    @objc private func resetTypingProfile() {
        let alert = NSAlert()
        alert.messageText = "Reset Typing Profile?"
        alert.informativeText = "This restores the default typing options and replacements, removing your custom replacements. Ignored words and other settings are unchanged."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveTypingProfile(TypingProfile())
    }

    private func saveTypingProfile(_ profile: TypingProfile) {
        do {
            try engine.setTypingProfile(profile)
        } catch {
            showTypingProfileError(error)
        }
    }

    private func showTypingProfileError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Update Typing Profile"
        alert.informativeText = error.localizedDescription
        alert.runModal()
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