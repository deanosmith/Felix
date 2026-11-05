import AppKit
import ApplicationServices
import Carbon
import OSLog

private let eventCallback: CGEventTapCallBack = { _, type, event, context in
    if type == .keyDown, event.getIntegerValueField(.eventSourceUserData) == felixSyntheticEventTag {
        return Unmanaged.passUnretained(event)
    }
    guard let context else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<AutocorrectEngine>.fromOpaque(context).takeUnretainedValue()
    let isKeyEvent = type == .keyDown
    let keyCode = isKeyEvent ? event.getIntegerValueField(.keyboardEventKeycode) : 0
    let flagBits = isKeyEvent ? event.flags.rawValue : 0
    let isRepeat = isKeyEvent && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let suppressed = MainActor.assumeIsolated {
        engine.handle(
            type: type, keyCode: keyCode, flags: CGEventFlags(rawValue: flagBits), isRepeat: isRepeat
        )
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return nil }
    return suppressed ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class AutocorrectEngine: NSObject {
    private struct UndoRecord {
        let snapshot: TextSnapshot
        let range: NSRange
        let original: String
        let replacement: String
        let created: Date
        var deletedTrailingCharacters = 0
    }

    var onChange: (() -> Void)?
    var onCorrection: ((CGRect?) -> Void)?
    private(set) var isPaused = UserDefaults.standard.bool(forKey: "isPaused")
    private(set) var sensitivity = CorrectionSensitivity(
        rawValue: UserDefaults.standard.string(forKey: "correctionSensitivity") ?? ""
    ) ?? .aggressive
    private(set) var correctionCount = 0
    private(set) var lastCorrection: CorrectionCandidate?
    private(set) var activity = "Waiting for a completed word"
    private(set) var typingProfile = TypingProfile.load()

    let applicationFilter = ApplicationFilter()
    private lazy var client = AccessibilityTextClient(applicationFilter: applicationFilter)
    private let policy = CorrectionPolicy()
    private let permissionLog = Logger(subsystem: "local.deanmsmith.Felix", category: "Permissions")
    private let correctionLog = Logger(subsystem: "local.deanmsmith.Felix", category: "Correction")
    private var receivedKeyboardEvent = false
    private var reportedStatus: String?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var permissionRefresh: Task<Void, Never>?
    private var hasAccessibilityAccess = false
    private var tapIsSuspended = false
    private var isStopped = true
    private var revision: UInt64 = 0
    private var menuIsOpen = false
    private var undoRecord: UndoRecord?
    private var pendingCorrection: Task<Void, Never>?
    private let maximumCorrectionAge: TimeInterval = 2
    private var spellingIsReady = false

    var status: String {
        if !hasAccessibilityAccess { return "Accessibility permission needed" }
        if isPaused { return "Paused" }
        if IsSecureEventInputEnabled() { return "Secure input active - suspended" }
        if tapIsSuspended { return "Keyboard monitoring stopped" }
        if tap == nil { return "Keyboard access unavailable" }
        if let application = NSWorkspace.shared.frontmostApplication {
            if !applicationFilter.allows(application.bundleIdentifier) {
                return "App excluded - suspended"
            }
            if !client.allows(application) { return "Protected app - suspended" }
        }
        if !spellingIsReady { return "Preparing spelling engine" }
        return "Active"
    }

    var canUndo: Bool {
        guard let record = undoRecord else { return false }
        return Date().timeIntervalSince(record.created) < 10
    }

    func start() {
        isStopped = false
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
        refreshAccess()
        Task { [weak self] in
            guard let self else { return }
            await policy.prepare()
            spellingIsReady = true
            correctionLog.notice("Spelling engine prepared")
            refreshAccess()
        }
    }

    func stop() {
        isStopped = true
        revision &+= 1
        pendingCorrection?.cancel()
        pendingCorrection = nil
        undoRecord = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionRefresh?.cancel()
        permissionRefresh = nil
        hasAccessibilityAccess = false
        client.hasAccessibilityAccess = false
        client.hasKeyboardInsertionAccess = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopTap()
    }

    func requestAccessibilityPermission() {
        refreshAccess(promptAccessibility: true)
    }

    func requestKeyboardPermission() {
        refreshAccess(promptKeyboard: true)
    }

    func togglePaused() {
        isPaused.toggle()
        UserDefaults.standard.set(isPaused, forKey: "isPaused")
        revision &+= 1
        undoRecord = nil
        if !isPaused { tapIsSuspended = false }
        refreshAccess()
        onChange?()
    }

    func setSensitivity(_ value: CorrectionSensitivity) {
        guard sensitivity != value else { return }
        sensitivity = value
        UserDefaults.standard.set(value.rawValue, forKey: "correctionSensitivity")
        revision &+= 1
        undoRecord = nil
        onChange?()
    }

    func setApplicationFilterMode(_ mode: ApplicationFilterMode) {
        guard applicationFilter.mode != mode else { return }
        applicationFilter.setMode(mode)
        applicationFilterChanged()
    }

    func setTypingProfile(_ profile: TypingProfile) throws {
        try profile.save()
        typingProfile = profile
        revision &+= 1
        pendingCorrection?.cancel()
        pendingCorrection = nil
        undoRecord = nil
        setActivity("Typing profile updated")
        onChange?()
    }

    func setApplication(_ identifier: String, selected: Bool, in list: ApplicationFilterMode) {
        guard applicationFilter.applications(in: list).contains(identifier.lowercased()) != selected
        else { return }
        applicationFilter.setApplication(identifier, selected: selected, in: list)
        applicationFilterChanged()
    }

    private func applicationFilterChanged() {
        revision &+= 1
        pendingCorrection?.cancel()
        pendingCorrection = nil
        undoRecord = nil
        activity = "Application settings updated"
        correctionLog.notice("Application settings updated")
        refreshAccess()
    }

    func setMenuOpen(_ open: Bool) {
        menuIsOpen = open
        revision &+= 1
    }

    func inspectFocusedField() {
        guard hasAccessibilityAccess, !IsSecureEventInputEnabled() else {
            setActivity(status)
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication, client.allows(application) else {
            setActivity("Focused app is protected, excluded, or unavailable")
            return
        }
        if client.snapshot(expectedPID: application.processIdentifier) != nil {
            setActivity("Focused field is readable and editable")
        } else {
            setActivity(client.failureReason ?? "Focused field is unsupported")
        }
    }

    @discardableResult
    func undoLastCorrection() -> Bool {
        guard canUndo, let record = undoRecord else { return false }
        var expected = record.snapshot
        if record.deletedTrailingCharacters > 0 {
            guard let current = client.snapshot(expectedPID: expected.processID) else {
                setActivity(client.failureReason ?? "Correction undo skipped: focused field is unsupported")
                return false
            }
            let contextOffset = expected.contextStart - current.contextStart
            let currentText = current.text as NSString
            let deletedRange = NSRange(
                location: expected.caretOffset - record.deletedTrailingCharacters,
                length: record.deletedTrailingCharacters
            )
            guard CFEqual(current.element, expected.element),
                  current.selection.location
                    == expected.selection.location - record.deletedTrailingCharacters,
                  contextOffset >= 0, contextOffset <= currentText.length,
                  currentText.substring(from: contextOffset)
                    == (expected.text as NSString).replacingCharacters(in: deletedRange, with: "")
            else {
                setActivity("Correction undo skipped: text or focus changed")
                return false
            }
            expected = current
        }
        guard client.replace(
                range: record.range, original: record.replacement,
                replacement: record.original, in: expected
              ) != nil
        else {
            setActivity(client.failureReason ?? "Correction undo skipped: text or focus changed")
            return false
        }
        undoRecord = nil
        revision &+= 1
        activity = "Correction reverted"
        onChange?()
        return true
    }

    func ignoreLastWord() {
        guard let correction = lastCorrection else { return }
        Task { await policy.ignore(correction.original) }
        _ = undoLastCorrection()
        lastCorrection = nil
        onChange?()
    }

    fileprivate func handle(
        type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool
    ) -> Bool {
        revision &+= 1
        pendingCorrection?.cancel()
        pendingCorrection = nil
        if type == .keyDown, !receivedKeyboardEvent {
            receivedKeyboardEvent = true
            correctionLog.notice("Keyboard events received")
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            undoRecord = nil
            tapIsSuspended = true
            correctionLog.warning("Keyboard monitoring stopped after the input tap was disabled")
            DispatchQueue.main.async { [weak self] in
                guard let self, tapIsSuspended else { return }
                stopTap()
                refreshAccess()
            }
            return false
        }

        guard type == .keyDown, !isPaused, !menuIsOpen, !tapIsSuspended,
              !IsSecureEventInputEnabled(), hasAccessibilityAccess
        else { return false }

        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        let undoKey = keyCode == kVK_Delete && modifiers.isEmpty
        let undoCommand = keyCode == kVK_ANSI_Z && modifiers == .maskCommand
            && !flags.contains(.maskShift)
        if undoKey, canUndo, let record = undoRecord,
           record.snapshot.selection.location - record.deletedTrailingCharacters > NSMaxRange(record.range) {
            undoRecord?.deletedTrailingCharacters += 1
            return false
        }
        if (undoKey || undoCommand), undoLastCorrection() { return true }
        undoRecord = nil

        guard keyCode == kVK_Space, modifiers.isEmpty, !isRepeat
        else { return false }
        guard isKeyboardLayout() else {
            setActivity("Input method is currently excluded")
            return false
        }
        guard let application = NSWorkspace.shared.frontmostApplication, client.allows(application) else {
            setActivity("Focused app is protected, excluded, or unavailable")
            return false
        }

        queueCorrection(
            processID: application.processIdentifier, revision: revision,
            started: Date(), attempt: 0
        )
        setActivity("Checking a completed word")
        return false
    }

    private func queueCorrection(processID: pid_t, revision: UInt64, started: Date, attempt: Int) {
        pendingCorrection?.cancel()
        pendingCorrection = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 25 : 20))
            } catch { return }
            guard !Task.isCancelled else { return }
            await self?.correct(processID: processID, revision: revision, started: started, attempt: attempt)
        }
    }

    private func correct(processID: pid_t, revision: UInt64, started: Date, attempt: Int) async {
        let began = ProcessInfo.processInfo.systemUptime
        var stage = "Checking pending input"
        defer {
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1_000)
            if milliseconds >= 100 {
                correctionLog.notice("Slow correction stage: \(stage, privacy: .public), \(milliseconds) ms")
            }
        }
          guard !Task.isCancelled, self.revision == revision, !isPaused, !menuIsOpen,
              Date().timeIntervalSince(started) < maximumCorrectionAge
        else {
            setActivity("Correction cancelled: input changed or work expired")
            return
        }
        stage = "Reading focused text"
        guard let snapshot = client.snapshot(expectedPID: processID) else {
            setActivity(client.failureReason ?? "Focused field is unsupported")
            return
        }

        let prefix = (snapshot.text as NSString).substring(to: snapshot.caretOffset)
        guard prefix.last?.isWhitespace == true else {
            if attempt < 2 {
                queueCorrection(
                    processID: processID, revision: revision, started: started, attempt: attempt + 1
                )
            } else {
                setActivity("Editor has not reported the space yet")
            }
            return
        }

        stage = "Checking spelling"
        guard let candidate = await policy.correction(
                in: snapshot.text, caretOffset: snapshot.caretOffset, sensitivity: sensitivity,
                profile: typingProfile
              ) else {
            guard !Task.isCancelled, self.revision == revision else { return }
            setActivity("No change: protected word or no spelling suggestion")
            return
        }
        guard !Task.isCancelled, self.revision == revision, !isPaused, !menuIsOpen,
              Date().timeIntervalSince(started) < maximumCorrectionAge
        else {
            if self.revision == revision {
                setActivity("Correction cancelled: spelling lookup expired")
            }
            return
        }

        let range = NSRange(
            location: snapshot.contextStart + candidate.range.location, length: candidate.range.length
        )
        stage = "Replacing text"
        guard let edit = client.replace(
            range: range, original: candidate.original,
            replacement: candidate.replacement, in: snapshot
        ) else {
            setActivity(client.failureReason ?? "Correction skipped: text or focus changed")
            return
        }

        correctionCount += 1
        lastCorrection = candidate
        activity = edit.bounds == nil ? "Correction applied; word bounds unavailable" : "Correction applied"
        correctionLog.notice("Correction applied")
        if edit.bounds == nil {
            correctionLog.notice("Word glow unavailable: editor did not expose text bounds")
        }
        undoRecord = UndoRecord(
            snapshot: edit.snapshot,
            range: NSRange(location: range.location, length: (candidate.replacement as NSString).length),
            original: candidate.original, replacement: candidate.replacement, created: Date()
        )
        onCorrection?(edit.bounds)
        onChange?()
    }

    private func setActivity(_ message: String) {
        guard activity != message else { return }
        activity = message
        correctionLog.notice("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private func refreshAccess(promptAccessibility: Bool = false, promptKeyboard: Bool = false) {
        guard !isStopped else { return }
        if isPaused || tapIsSuspended || promptAccessibility || promptKeyboard {
            revision &+= 1
            pendingCorrection?.cancel()
            pendingCorrection = nil
            undoRecord = nil
            stopTap()
        }
        if promptAccessibility || promptKeyboard {
            tapIsSuspended = false
            permissionRefresh?.cancel()
            permissionRefresh = nil
        }
        guard permissionRefresh == nil else { return }
        permissionRefresh = Task { [weak self] in
            let access = await Task.detached {
                if promptAccessibility {
                    _ = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    )
                }
                if promptKeyboard { _ = CGRequestListenEventAccess() }
                let trusted = AXIsProcessTrusted()
                return (trusted: trusted, canInsert: trusted && CGPreflightPostEventAccess())
            }.value
            guard let self, !Task.isCancelled, !isStopped else { return }
            permissionRefresh = nil
            applyAccess(trusted: access.trusted, canInsert: access.canInsert)
        }
    }

    private func applyAccess(trusted: Bool, canInsert: Bool) {
        if trusted && !hasAccessibilityAccess { tapIsSuspended = false }
        hasAccessibilityAccess = trusted
        client.hasAccessibilityAccess = trusted
        client.hasKeyboardInsertionAccess = canInsert
        if !canUndo { undoRecord = nil }
        if isPaused || !trusted || tapIsSuspended {
            revision &+= 1
            pendingCorrection?.cancel()
            pendingCorrection = nil
            undoRecord = nil
            stopTap()
        } else if tap == nil {
            let types: [CGEventType] = [
                .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown
            ]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            if let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: eventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ), let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) {
                tap = newTap
                source = newSource
                CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
                CGEvent.tapEnable(tap: newTap, enable: true)
            } else {
                tapIsSuspended = true
                correctionLog.error("Keyboard monitoring stopped because the input tap could not be created")
            }
        }
        if let application = NSWorkspace.shared.frontmostApplication, client.allows(application) {
            client.prepare(application)
        }
        let currentStatus = status
        if reportedStatus != currentStatus {
            reportedStatus = currentStatus
            permissionLog.notice("\(currentStatus, privacy: .public)")
        }
        onChange?()
    }

    private func stopTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
    }

    private func isKeyboardLayout() -> Bool {
        guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(input, kTISPropertyInputSourceType)
        else { return false }
        return Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() == kTISTypeKeyboardLayout
    }

    @objc private func applicationChanged(_ notification: Notification) {
        revision &+= 1
        undoRecord = nil
        if let application = NSWorkspace.shared.frontmostApplication, client.allows(application) {
            client.prepare(application)
        }
        onChange?()
    }
}