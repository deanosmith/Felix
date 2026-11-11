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
    var characters = ""
    if isKeyEvent {
        var buffer = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer
        )
        if length > 0 {
            characters = String(utf16CodeUnits: buffer, count: min(length, buffer.count))
        }
    }
    let suppressed = MainActor.assumeIsolated {
        engine.handle(
            type: type, keyCode: keyCode, flags: CGEventFlags(rawValue: flagBits),
            isRepeat: isRepeat, characters: characters
        )
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return nil }
    return suppressed ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class AutocorrectEngine: NSObject {
    private struct SnapshotUndoRecord {
        let snapshot: TextSnapshot
        let range: NSRange
        let original: String
        let replacement: String
        var wasReverted = false
        var lastForwardedCaret: Int?
    }

    private struct OpaqueUndoRecord {
        let target: OpaqueTextTarget
        var range: NSRange
        let original: String
        let replacement: String
        var wasReverted = false
    }

    private enum UndoState {
        case snapshot(SnapshotUndoRecord)
        case opaque(OpaqueUndoRecord)

        var wasReverted: Bool {
            switch self {
            case let .snapshot(record): record.wasReverted
            case let .opaque(record): record.wasReverted
            }
        }
    }

    var onChange: (() -> Void)?
    var onCorrection: ((CGRect?) -> Void)?
    var onFeedbackReset: (() -> Void)?
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
    private var undoRecord: UndoState?
    private var needsUndoFocusCheck = false
    private var typedBuffer = ""
    private var typedTarget: AXUIElement?
    private var pendingCorrection: Task<Void, Never>?
    private let maximumCorrectionAge: TimeInterval = 2
    private var spellingIsReady = false

    var status: String {
        if !hasAccessibilityAccess { return "Accessibility permission needed" }
        if isPaused { return "Paused" }
        if IsSecureEventInputEnabled() { return "Secure input active - suspended" }
        if tapIsSuspended { return "Keyboard monitoring stopped" }
        if tap == nil { return "Keyboard access unavailable" }
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if !applicationFilter.allows(application.bundleIdentifier) {
                return "App excluded - suspended"
            }
        }
        if !spellingIsReady { return "Preparing spelling engine" }
        return "Active"
    }

    var canUndo: Bool {
        undoRecord?.wasReverted == false
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
        if !client.recoverPendingSelection() {
            correctionLog.error("Unable to restore the pending editor selection before stopping")
        }
        isStopped = true
        revision &+= 1
        pendingCorrection?.cancel()
        pendingCorrection = nil
        undoRecord = nil
        resetTypedContext()
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionRefresh?.cancel()
        permissionRefresh = nil
        hasAccessibilityAccess = false
        client.hasAccessibilityAccess = false
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
        if !isPaused, !client.recoverPendingSelection() {
            setActivity(client.failureReason ?? "Move the caret before pausing Felix")
            NSSound.beep()
            return
        }
        isPaused.toggle()
        UserDefaults.standard.set(isPaused, forKey: "isPaused")
        revision &+= 1
        undoRecord = nil
        resetTypedContext()
        onFeedbackReset?()
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
        resetTypedContext()
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
        resetTypedContext()
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
        resetTypedContext()
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
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !client.allows(application) {
            setActivity("Focused app is excluded or unavailable")
            return
        }
        switch client.fieldState() {
        case .readable:
            setActivity("Focused field is readable and editable")
        case .opaque:
            setActivity("Focused field is editable via keyboard tracking")
        case .unavailable:
            setActivity(client.failureReason ?? "Focused field is unsupported")
        }
    }

    @discardableResult
    func undoLastCorrection(atWordEnd: Bool = false) -> Bool {
        guard canUndo, let state = undoRecord else { return false }
        pendingCorrection?.cancel()
        switch state {
        case let .opaque(record):
            return revertOpaqueCorrection(record, atWordEnd: atWordEnd)
        case let .snapshot(record):
            let currentRevision = revision
            pendingCorrection = Task { [weak self] in
                await self?.revertCorrection(record, atWordEnd: atWordEnd, revision: currentRevision)
            }
            return true
        }
    }

    private func revertOpaqueCorrection(_ record: OpaqueUndoRecord, atWordEnd: Bool) -> Bool {
        guard client.matchesOpaqueTarget(record.target) else {
            undoRecord = nil
            resetTypedContext()
            setActivity(client.failureReason ?? "Correction undo skipped: text or focus changed")
            return false
        }
        let source = typedBuffer as NSString
        guard NSMaxRange(record.range) <= source.length,
              source.substring(with: record.range) == record.replacement
        else {
            undoRecord = nil
            setActivity("Correction undo skipped: text or focus changed")
            return false
        }
        if atWordEnd, source.length > NSMaxRange(record.range) {
            undoRecord = nil
            setActivity("Correction undo cancelled: editor caret changed; Backspace withheld")
            return true
        }
        let trailing = source.substring(from: NSMaxRange(record.range))
        guard trailing.count <= 64, !trailing.contains("\n") else {
            undoRecord = nil
            setActivity("Correction undo skipped: text or focus changed")
            return false
        }
        let currentSegment = record.replacement + trailing
        let restoredSegment = record.original + trailing
        guard client.replaceOpaque(
            deleteCount: currentSegment.count, replacement: restoredSegment, in: record.target
        ) else {
            undoRecord = nil
            onFeedbackReset?()
            setActivity(client.failureReason ?? "Correction undo was not confirmed")
            return atWordEnd
        }
        let replaceRange = NSRange(
            location: record.range.location, length: source.length - record.range.location
        )
        typedBuffer = source.replacingCharacters(in: replaceRange, with: restoredSegment)
        undoRecord = .opaque(OpaqueUndoRecord(
            target: record.target,
            range: NSRange(
                location: record.range.location, length: (record.original as NSString).length
            ),
            original: record.original,
            replacement: record.replacement,
            wasReverted: true
        ))
        revision &+= 1
        onFeedbackReset?()
        activity = "Correction reverted"
        onChange?()
        return true
    }

    private func revertCorrection(_ record: SnapshotUndoRecord, atWordEnd: Bool, revision: UInt64) async {
        guard !Task.isCancelled, self.revision == revision else { return }
        let expected = record.snapshot
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        var latest: TextSnapshot?
        repeat {
            latest = client.snapshot(expectedPID: expected.processID)
            if let current = latest,
               !atWordEnd || !CFEqual(current.element, expected.element)
                || current.selection.location <= NSMaxRange(record.range) {
                break
            }
            if IsSecureEventInputEnabled() { break }
            do {
                try await Task.sleep(for: .milliseconds(4))
            } catch { return }
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard !Task.isCancelled, self.revision == revision else { return }
        guard let current = latest else {
            undoRecord = nil
            setActivity(client.failureReason ?? "Correction undo skipped: focused field is unsupported")
            return
        }
        guard CFEqual(current.element, expected.element) else {
            undoRecord = nil
            setActivity("Correction undo skipped: text or focus changed")
            return
        }
        if atWordEnd, current.selection.location > NSMaxRange(record.range) {
            undoRecord = nil
            setActivity("Correction undo cancelled: editor caret changed; Backspace withheld")
            return
        }

        let contextStart = max(expected.contextStart, current.contextStart)
        let currentText = current.text as NSString
        let expectedText = expected.text as NSString
        guard current.selection.location >= NSMaxRange(record.range),
              current.selection.location <= expected.selection.location,
              contextStart <= record.range.location
        else {
            undoRecord = nil
            setActivity("Correction undo skipped: text or focus changed")
            return
        }
        let preservedLength = current.selection.location - contextStart
        let currentRange = NSRange(
            location: contextStart - current.contextStart, length: preservedLength
        )
        let expectedRange = NSRange(
            location: contextStart - expected.contextStart, length: preservedLength
        )
        guard NSMaxRange(currentRange) <= currentText.length,
              NSMaxRange(expectedRange) <= expectedText.length,
              currentText.substring(with: currentRange) == expectedText.substring(with: expectedRange)
        else {
            undoRecord = nil
            setActivity("Correction undo skipped: text or focus changed")
            return
        }
        let result = await client.replace(
            range: record.range, original: record.replacement,
            replacement: record.original, in: current
        )
        switch result {
        case .unchanged:
            undoRecord = nil
            setActivity(client.failureReason ?? "Correction undo skipped: text or focus changed")
            return
        case .unconfirmed:
            undoRecord = nil
            onFeedbackReset?()
            setActivity(client.failureReason ?? "Correction undo was not confirmed; Backspace was withheld")
            return
        case let .applied(snapshot, _):
            undoRecord = .snapshot(SnapshotUndoRecord(
                snapshot: snapshot,
                range: NSRange(location: record.range.location, length: (record.original as NSString).length),
                original: record.original, replacement: record.replacement, wasReverted: true
            ))
        }
        self.revision &+= 1
        onFeedbackReset?()
        activity = "Correction reverted"
        onChange?()
    }

    private func handleBackspace() -> Bool {
        guard let state = undoRecord else { return false }
        switch state {
        case let .opaque(record):
            guard client.matchesOpaqueTarget(record.target) else {
                undoRecord = nil
                resetTypedContext()
                setActivity(client.failureReason ?? "Correction undo cleared: focused field changed")
                return false
            }
            let length = (typedBuffer as NSString).length
            if length > NSMaxRange(record.range) {
                return false
            }
            if record.wasReverted || length < NSMaxRange(record.range) {
                undoRecord = nil
                return false
            }
            let source = typedBuffer as NSString
            guard NSMaxRange(record.range) <= source.length,
                  source.substring(with: record.range) == record.replacement
            else {
                undoRecord = nil
                return false
            }
            return undoLastCorrection(atWordEnd: true)
        case let .snapshot(record):
            let deadline = ProcessInfo.processInfo.systemUptime + 0.08
            repeat {
                switch client.selection(in: record.snapshot) {
                case let .caret(location):
                    if location != record.lastForwardedCaret {
                        if location > NSMaxRange(record.range) {
                            if case var .snapshot(updated) = undoRecord {
                                updated.lastForwardedCaret = location
                                undoRecord = .snapshot(updated)
                            }
                            return false
                        }
                        if record.wasReverted || location < NSMaxRange(record.range) {
                            undoRecord = nil
                            return false
                        }
                        // Only read full text when the verified caret reaches the corrected word.
                        return undoLastCorrection(atWordEnd: true)
                    }
                case .changed:
                    undoRecord = nil
                    setActivity(client.failureReason ?? "Correction undo cleared: selection changed")
                    return false
                case .unavailable:
                    break
                }
                Thread.sleep(forTimeInterval: 0.004)
            } while ProcessInfo.processInfo.systemUptime < deadline && !IsSecureEventInputEnabled()

            undoRecord = nil
            setActivity("Correction undo unavailable: editor caret did not update; Backspace withheld")
            return true
        }
    }

    func ignoreLastWord() {
        guard let correction = lastCorrection else { return }
        Task { await policy.ignore(correction.original) }
        _ = undoLastCorrection()
        lastCorrection = nil
        onChange?()
    }

    private func resetTypedContext() {
        typedBuffer = ""
        typedTarget = nil
    }

    private func trimTypedBufferIfNeeded() {
        let source = typedBuffer as NSString
        guard source.length > 1_024 else { return }
        let boundary = source.rangeOfComposedCharacterSequence(at: source.length - 512).location
        guard boundary > 0 else { return }
        typedBuffer = source.substring(from: boundary)
        if case var .opaque(record) = undoRecord {
            let shifted = record.range.location - boundary
            if shifted >= 0 {
                record.range.location = shifted
                undoRecord = .opaque(record)
            } else {
                undoRecord = nil
            }
        }
    }

    fileprivate func handle(
        type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool,
        characters: String
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
            resetTypedContext()
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
        else {
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                needsUndoFocusCheck = true
                resetTypedContext()
                onFeedbackReset?()
            } else if type == .scrollWheel {
                onFeedbackReset?()
            } else if IsSecureEventInputEnabled() {
                undoRecord = nil
                resetTypedContext()
            }
            return false
        }

        if needsUndoFocusCheck {
            needsUndoFocusCheck = false
            switch undoRecord {
            case let .snapshot(record):
                // A click can enter a protected field without activating another app.
                switch client.selection(in: record.snapshot) {
                case .caret:
                    break
                case .changed:
                    undoRecord = nil
                    setActivity(client.failureReason ?? "Correction undo cleared: focused field changed")
                case .unavailable:
                    setActivity(client.failureReason ?? "Focused field is temporarily unavailable")
                }
            case .opaque:
                undoRecord = nil
            case nil:
                break
            }
        }

        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        let isFunctionKey = characters.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) }
        let isCaretNavigation = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Tab, kVK_Escape
        ].contains(Int(keyCode)) || isFunctionKey
        if !isCaretNavigation, !client.recoverPendingSelection() {
            setActivity(client.failureReason ?? "Move the caret to clear Felix's pending selection")
            NSSound.beep()
            return true
        }
        let undoKey = keyCode == kVK_Delete && modifiers.isEmpty
        let undoCommand = keyCode == kVK_ANSI_Z && modifiers == .maskCommand
            && !flags.contains(.maskShift)
        if undoKey {
            if handleBackspace() { return true }
            if !typedBuffer.isEmpty {
                typedBuffer.removeLast()
                if case let .opaque(record) = undoRecord,
                   (typedBuffer as NSString).length < NSMaxRange(record.range) {
                    undoRecord = nil
                }
            }
            return false
        }
        if undoCommand, undoLastCorrection() { return true }
        if !modifiers.isEmpty
            || isCaretNavigation || keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter
            || keyCode == kVK_ForwardDelete || keyCode == kVK_Delete {
            undoRecord = nil
            if modifiers == .maskAlternate, !isCaretNavigation,
               keyCode != kVK_Return, keyCode != kVK_ANSI_KeypadEnter,
               keyCode != kVK_ForwardDelete, keyCode != kVK_Delete {
                typedBuffer.append("\u{FFFD}")
                trimTypedBufferIfNeeded()
            } else {
                resetTypedContext()
            }
            onFeedbackReset?()
        } else {
            if case var .snapshot(record) = undoRecord {
                record.lastForwardedCaret = nil
                undoRecord = .snapshot(record)
            }
            if keyCode == kVK_Space {
                typedBuffer.append(" ")
            } else if !characters.isEmpty,
                      characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                typedBuffer.append(characters)
            }
            trimTypedBufferIfNeeded()
        }

        guard keyCode == kVK_Space, modifiers.isEmpty, !isRepeat
        else { return false }
        guard isKeyboardLayout() else {
            setActivity("Input method is currently excluded")
            return false
        }
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return false
        }

        queueCorrection(revision: revision, started: Date(), attempt: 0)
        setActivity("Checking a completed word")
        return false
    }

    private func queueCorrection(revision: UInt64, started: Date, attempt: Int) {
        pendingCorrection?.cancel()
        pendingCorrection = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 25 : 20))
            } catch { return }
            guard !Task.isCancelled else { return }
            await self?.correct(revision: revision, started: started, attempt: attempt)
        }
    }

    private func correct(revision: UInt64, started: Date, attempt: Int) async {
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
        let snapshot: TextSnapshot
        switch client.fieldState() {
        case .unavailable:
            if let application = NSWorkspace.shared.frontmostApplication, !client.allows(application) {
                setActivity("Focused app is excluded or unavailable")
            } else {
                setActivity(client.failureReason ?? "Focused field is unsupported")
            }
            return
        case let .opaque(target):
            await correctOpaque(in: target, revision: revision, started: started, stage: &stage)
            return
        case let .readable(resolved):
            if resolved.selection.location == 0, resolved.text.isEmpty,
               (typedBuffer as NSString).length >= 2 {
                if attempt < 1 {
                    queueCorrection(revision: revision, started: started, attempt: attempt + 1)
                } else {
                    await correctOpaque(
                        in: OpaqueTextTarget(element: resolved.element, processID: resolved.processID),
                        revision: revision, started: started, stage: &stage
                    )
                }
                return
            }
            typedTarget = resolved.element
            snapshot = resolved
        }

        let prefix = (snapshot.text as NSString).substring(to: snapshot.caretOffset)
        guard prefix.last?.isWhitespace == true else {
            if attempt < 2 {
                queueCorrection(revision: revision, started: started, attempt: attempt + 1)
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
        if case let .snapshot(record) = undoRecord, record.wasReverted,
           CFEqual(snapshot.element, record.snapshot.element),
           NSIntersectionRange(range, record.range).length > 0 {
            let text = snapshot.text as NSString
            let localRange = NSRange(
                location: record.range.location - snapshot.contextStart, length: record.range.length
            )
            if localRange.location >= 0, NSMaxRange(localRange) <= text.length,
               text.substring(with: localRange) == record.original {
                let next = text.substring(from: NSMaxRange(localRange)).first
                let extended = next.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
                if extended {
                    undoRecord = nil
                } else {
                    setActivity("Rejected correction kept")
                    return
                }
            }
        }
        stage = "Replacing text"
        let result = await client.replace(
            range: range, original: candidate.original,
            replacement: candidate.replacement, in: snapshot
        )
        guard case let .applied(updated, bounds) = result else {
            if case .unconfirmed = result {
                undoRecord = nil
                onFeedbackReset?()
            }
            setActivity(client.failureReason ?? "Correction skipped: text or focus changed")
            return
        }

        correctionCount += 1
        lastCorrection = candidate
        activity = bounds == nil ? "Correction applied; word bounds unavailable" : "Correction applied"
        correctionLog.notice("Correction applied")
        if bounds == nil {
            correctionLog.notice("Word glow unavailable: editor did not expose text bounds")
        }
        undoRecord = .snapshot(SnapshotUndoRecord(
            snapshot: updated,
            range: NSRange(location: range.location, length: (candidate.replacement as NSString).length),
            original: candidate.original, replacement: candidate.replacement
        ))
        onCorrection?(bounds)
        onChange?()
    }

    private func correctOpaque(
        in target: OpaqueTextTarget, revision: UInt64, started: Date, stage: inout String
    ) async {
        if let previous = typedTarget, !CFEqual(previous, target.element) {
            typedBuffer = ""
            typedTarget = target.element
            setActivity("Focused field changed")
            return
        }
        typedTarget = target.element

        let buffer = typedBuffer
        let source = buffer as NSString
        let caretOffset = source.length
        guard caretOffset > 1, buffer.last?.isWhitespace == true else {
            setActivity("No change: waiting for a completed word")
            return
        }

        stage = "Checking spelling"
        guard let candidate = await policy.correction(
            in: buffer, caretOffset: caretOffset, sensitivity: sensitivity,
            profile: typingProfile
        ) else {
            guard !Task.isCancelled, self.revision == revision else { return }
            setActivity("No change: protected word or no spelling suggestion")
            return
        }
        guard !Task.isCancelled, self.revision == revision, !isPaused, !menuIsOpen,
              Date().timeIntervalSince(started) < maximumCorrectionAge,
              typedBuffer == buffer
        else {
            if self.revision == revision {
                setActivity("Correction cancelled: spelling lookup expired")
            }
            return
        }

        if case let .opaque(record) = undoRecord, record.wasReverted,
           CFEqual(target.element, record.target.element),
           NSIntersectionRange(candidate.range, record.range).length > 0 {
            if record.range.location >= 0, NSMaxRange(record.range) <= source.length,
               source.substring(with: record.range) == record.original {
                let next = source.substring(from: NSMaxRange(record.range)).first
                let extended = next.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
                if extended {
                    undoRecord = nil
                } else {
                    setActivity("Rejected correction kept")
                    return
                }
            }
        }

        let suffixRange = NSRange(
            location: NSMaxRange(candidate.range),
            length: caretOffset - NSMaxRange(candidate.range)
        )
        guard suffixRange.length <= 4 else {
            setActivity("Correction skipped: unexpected trailing text")
            return
        }
        let suffix = source.substring(with: suffixRange)
        guard suffix.unicodeScalars.allSatisfy({
            CharacterSet.whitespaces.contains($0)
                || CharacterSet(charactersIn: ".!?,;:\u{2026}").contains($0)
        }) else {
            setActivity("Correction skipped: unexpected trailing text")
            return
        }

        let originalSegment = candidate.original + suffix
        let replacementSegment = candidate.replacement + suffix
        let editRange = NSRange(
            location: candidate.range.location,
            length: candidate.range.length + suffixRange.length
        )
        guard NSMaxRange(editRange) == source.length,
              source.substring(with: editRange) == originalSegment
        else {
            setActivity("Correction skipped: text changed")
            return
        }

        stage = "Replacing text"
        guard client.replaceOpaque(
            deleteCount: originalSegment.count, replacement: replacementSegment, in: target
        ) else {
            undoRecord = nil
            onFeedbackReset?()
            setActivity(client.failureReason ?? "Correction skipped: text or focus changed")
            return
        }

        typedBuffer = source.replacingCharacters(in: editRange, with: replacementSegment)
        correctionCount += 1
        lastCorrection = candidate
        activity = "Correction applied; word bounds unavailable"
        correctionLog.notice("Correction applied")
        correctionLog.notice("Word glow unavailable: editor did not expose text bounds")
        undoRecord = .opaque(OpaqueUndoRecord(
            target: target,
            range: NSRange(
                location: candidate.range.location,
                length: (candidate.replacement as NSString).length
            ),
            original: candidate.original,
            replacement: candidate.replacement
        ))
        onCorrection?(nil)
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
                return AXIsProcessTrusted()
            }.value
            guard let self, !Task.isCancelled, !isStopped else { return }
            permissionRefresh = nil
            applyAccess(trusted: access)
        }
    }

    private func applyAccess(trusted: Bool) {
        if trusted && !hasAccessibilityAccess { tapIsSuspended = false }
        hasAccessibilityAccess = trusted
        client.hasAccessibilityAccess = trusted
        if isPaused || !trusted || tapIsSuspended {
            revision &+= 1
            pendingCorrection?.cancel()
            pendingCorrection = nil
            undoRecord = nil
            resetTypedContext()
            stopTap()
        } else if tap == nil {
            let types: [CGEventType] = [
                .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
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
        resetTypedContext()
        onFeedbackReset?()
        if let application = NSWorkspace.shared.frontmostApplication, client.allows(application) {
            client.prepare(application, force: true)
        }
        refreshAccess()
        onChange?()
    }
}