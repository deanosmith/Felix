import AppKit
import ApplicationServices
import Carbon
import OSLog

let felixSyntheticEventTag: Int64 = 0x46_45_4C_49_58

struct TextSnapshot {
    let element: AXUIElement
    let processID: pid_t
    let selection: NSRange
    let selectionMarkers: AXTextMarkerRange?
    let contextStart: Int
    let text: String

    var caretOffset: Int { selection.location - contextStart }
}

enum TextReplacementResult {
    case unchanged
    case unconfirmed
    case applied(snapshot: TextSnapshot, bounds: CGRect?)
}

enum TextSelectionResult {
    case caret(Int)
    case changed
    case unavailable
}

@MainActor
final class AccessibilityTextClient {
    private struct PendingSelection {
        let snapshot: TextSnapshot
        let originalRange: NSRange
        let replacementRange: NSRange
        let replacementContext: String
        let caret: Int
        var writeWasSubmitted = false
    }

    private let systemWide = AXUIElementCreateSystemWide()
    private let applicationFilter: ApplicationFilter
    private let accessibilityLog = Logger(subsystem: "local.deanmsmith.Felix", category: "Accessibility")
    private var accessibilityRequests: [pid_t: TimeInterval] = [:]
    private var pendingSelections: [PendingSelection] = []
    private var replacementIsInFlight = false
    private(set) var failureReason: String?
    var hasAccessibilityAccess = false

    init(applicationFilter: ApplicationFilter) {
        self.applicationFilter = applicationFilter
        AXUIElementSetMessagingTimeout(systemWide, 0.04)
    }

    func allows(_ application: NSRunningApplication) -> Bool {
        guard let identifier = application.bundleIdentifier?.lowercased(),
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }

        let excluded = [
            "com.apple.dt.xcode", "com.apple.terminal", "com.apple.keychainaccess",
            "com.apple.passwords", "com.googlecode.iterm2", "dev.warp.warp-stable",
            "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.mitchellh.ghostty",
            "org.vim.macvim", "com.sublimetext.3", "com.sublimetext.4", "dev.zed.zed",
            "com.barebones.bbedit", "com.google.android.studio", "com.exafunction.windsurf",
            "com.todesktop.230313mzl4w4u92", "com.microsoft.rdc.macos",
            "com.microsoft.rdc.mac", "com.microsoft.windowsapp", "com.realvnc.vncviewer"
        ]
        let prefixes = [
            "com.jetbrains.", "com.agilebits.",
            "com.1password.", "com.cursor.", "com.parallels.", "com.citrix."
        ]
        return applicationFilter.allows(identifier)
            && !excluded.contains(identifier) && !prefixes.contains(where: identifier.hasPrefix)
    }

    func snapshot(expectedPID: pid_t) -> TextSnapshot? {
        guard recoverPendingSelection() else { return nil }
        failureReason = "Focused app is unavailable or protected"
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == expectedPID, allows(application)
        else { return nil }
        prepare(application)

        failureReason = "Focused text field is unavailable"
        guard let element = focusedElement(expectedPID: expectedPID) else { return nil }
        failureReason = "Focused field is protected or unsupported"
        guard isSafe(element, in: application) else { return nil }
        if application.bundleIdentifier?.lowercased().hasPrefix("com.microsoft.vscode") == true,
           (attribute("AXDOMClassList", of: element) as? [String] ?? []).contains("native-edit-context"),
           (attribute(kAXDescriptionAttribute, of: element) as? String ?? "")
            .lowercased().contains("editor is not accessible") {
            failureReason = "VS Code chat needs Editor: Accessibility Support set to On"
            return nil
        }
        failureReason = "Focused field does not expose a collapsed caret"
        guard let selection = selectedRange(of: element),
              selection.location >= 0, selection.length == 0
        else { return nil }
        let isWebEditor = isChromium(application) || isWebContent(element)
        let selectionMarkers = isWebEditor ? selectedTextMarkers(of: element) : nil
        failureReason = "Focused field does not expose a writable caret"
        guard isWebEditor
            ? selectionMarkers != nil && isSettable("AXSelectedTextMarkerRange", on: element)
            : isSettable(kAXSelectedTextRangeAttribute, on: element)
        else { return nil }

        let characterCount = (attribute(kAXNumberOfCharactersAttribute, of: element) as? NSNumber)?
            .intValue ?? selection.location
        guard characterCount >= selection.location else { return nil }

        let start = max(0, selection.location - 1_024)
        let length = selection.location - start + min(128, characterCount - selection.location)
        let contextRange = NSRange(location: start, length: length)
        let prefixRange = NSRange(location: start, length: selection.location - start)
        failureReason = "Focused field does not expose readable text"
        // Chromium can report a character count larger than its addressable text.
        guard let text = string(in: contextRange, of: element)
            ?? string(in: prefixRange, of: element)
        else { return nil }
        guard selectedRange(of: element) == selection else {
            failureReason = "Editor changed its caret while reading text"
            return nil
        }

        failureReason = nil
        return TextSnapshot(
            element: element,
            processID: expectedPID,
            selection: selection,
            selectionMarkers: selectionMarkers,
            contextStart: start,
            text: text
        )
    }

    func recoverPendingSelection() -> Bool {
        guard !pendingSelections.isEmpty else { return true }
        pendingSelections.removeAll {
            NSRunningApplication(processIdentifier: $0.snapshot.processID)?.isTerminated != false
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              pendingSelections.contains(where: { $0.snapshot.processID == application.processIdentifier })
        else { return true }
        failureReason = "Felix could not restore its selection; move the caret before typing"
        guard let focused = focusedElement(expectedPID: application.processIdentifier)
        else { return false }
        guard let index = pendingSelections.firstIndex(where: { CFEqual($0.snapshot.element, focused) })
        else { return true }
        let pending = pendingSelections[index]
        guard let current = selectedRange(of: focused) else { return false }
        if !pending.writeWasSubmitted {
            guard current == pending.originalRange || current == pending.snapshot.selection else {
                pendingSelections.remove(at: index)
                failureReason = nil
                return true
            }
            guard string(
                in: NSRange(
                    location: pending.snapshot.contextStart,
                    length: (pending.snapshot.text as NSString).length
                ), of: focused
            ) == pending.snapshot.text,
                  setSelection(
                    pending.snapshot.selection, markers: pending.snapshot.selectionMarkers, on: focused
                  ),
                  selectedRange(of: focused) == pending.snapshot.selection
            else { return false }
            pendingSelections.remove(at: index)
            failureReason = nil
            return true
        }
        let replacementIsVisible = pending.writeWasSubmitted && string(
            in: NSRange(
                location: pending.snapshot.contextStart,
                length: (pending.replacementContext as NSString).length
            ), of: focused
        ) == pending.replacementContext
        if !replacementIsVisible, current == pending.snapshot.selection,
           string(
            in: NSRange(
                location: pending.snapshot.contextStart, length: (pending.snapshot.text as NSString).length
            ), of: focused
           ) == pending.snapshot.text {
            return false
        }
        let needsCaretUpdate = current.length == 0 && replacementIsVisible
            && current.location != pending.caret
            && (current.location == pending.snapshot.selection.location
                || current.location == pending.originalRange.location)
        guard needsCaretUpdate || (current.length > 0
              && (current == pending.originalRange || current == pending.replacementRange))
        else {
            pendingSelections.remove(at: index)
            failureReason = nil
            return true
        }

        let location: Int
        if pending.writeWasSubmitted {
            guard replacementIsVisible else { return false }
            location = pending.caret
        } else {
            location = NSMaxRange(current)
        }
        let markers: AXTextMarkerRange?
        if pending.snapshot.selectionMarkers != nil {
            guard let selected = selectedTextMarkers(of: focused),
                  let caret = marker(
                    from: AXTextMarkerRangeCopyEndMarker(selected),
                    offset: location - NSMaxRange(current), of: focused
                  )
            else { return false }
            markers = AXTextMarkerRangeCreate(nil, caret, caret)
        } else {
            markers = nil
        }
        let collapsed = NSRange(location: location, length: 0)
        guard setSelection(collapsed, markers: markers, on: focused),
              selectedRange(of: focused) == collapsed
        else { return false }
        pendingSelections.remove(at: index)
        failureReason = nil
        return true
    }

    func selection(in expected: TextSnapshot) -> TextSelectionResult {
        failureReason = "Correction focus changed"
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == expected.processID, allows(application)
        else { return .changed }
        failureReason = "Editor caret is temporarily unavailable"
        guard let focused = focusedElement(expectedPID: expected.processID) else { return .unavailable }
        guard CFEqual(focused, expected.element) else {
            failureReason = "Correction focus changed"
            return .changed
        }
        guard let range = selectedRange(of: focused) else { return .unavailable }
        guard range.location >= 0, range.length == 0 else {
            failureReason = "Correction selection changed"
            return .changed
        }
        failureReason = nil
        return .caret(range.location)
    }

    func replace(
        range: NSRange,
        original: String,
        replacement: String,
        in expected: TextSnapshot
    ) async -> TextReplacementResult {
        guard !replacementIsInFlight else {
            failureReason = "Previous replacement is still being confirmed"
            return .unchanged
        }
        replacementIsInFlight = true
        defer { replacementIsInFlight = false }
        guard recoverPendingSelection() else { return .unchanged }
        failureReason = "Correction range is outside the verified text"
        let context = expected.text as NSString
        let localRange = NSRange(
            location: range.location - expected.contextStart, length: range.length
        )
        guard localRange.location >= 0, range.length >= 0,
              NSMaxRange(localRange) <= context.length,
              NSMaxRange(range) <= expected.selection.location,
              expected.caretOffset <= context.length,
              context.substring(with: localRange) == original
        else { return .unchanged }

        let suffixRange = NSRange(
            location: NSMaxRange(localRange), length: expected.selection.location - NSMaxRange(range)
        )
        guard suffixRange.length <= 4 else { return .unchanged }
        let suffix = context.substring(with: suffixRange)
        guard suffix.unicodeScalars.allSatisfy({
                  CharacterSet.whitespaces.contains($0)
                      || CharacterSet(charactersIn: ".!?,;:").contains($0)
              })
        else { return .unchanged }

        let editRange = NSRange(location: range.location, length: range.length + suffixRange.length)
        let originalText = original + suffix
        let replacementText = replacement + suffix
        let replacementContext = context.replacingCharacters(
            in: NSRange(location: localRange.location, length: editRange.length), with: replacementText
        )
        let caretLocation = range.location + (replacementText as NSString).length
        failureReason = "Focused app is unavailable"
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == expected.processID, allows(application)
        else { return .unchanged }

        failureReason = "Text or focus changed before correction"
        guard !IsSecureEventInputEnabled(),
              let focused = focusedElement(expectedPID: expected.processID),
              CFEqual(focused, expected.element), isSafe(focused, in: application)
        else { return .unchanged }

        let markers: AXTextMarkerRange?
        if expected.selectionMarkers != nil {
            failureReason = "Editor did not expose an exact replacement range"
            guard let caretMarkers = selectedTextMarkers(of: focused),
                  let start = marker(
                    before: AXTextMarkerRangeCopyEndMarker(caretMarkers),
                    count: editRange.length, of: focused
                  )
            else { return .unchanged }
            let range = AXTextMarkerRangeCreate(nil, start, AXTextMarkerRangeCopyEndMarker(caretMarkers))
            guard (parameterizedAttribute(
                "AXStringForTextMarkerRange", value: range, of: focused
            ) as? String) == originalText
            else { return .unchanged }
            markers = range
        } else {
            markers = nil
        }
        let usesAtomicOperation = markers != nil
            && supportsAtomicReplacement(on: focused, in: application)
        let usesSelectedText = markers == nil && isSettable(kAXSelectedTextAttribute, on: focused)
        let insertion = usesAtomicOperation || usesSelectedText ? nil : keyboardInsertion(replacementText)
        guard usesAtomicOperation || usesSelectedText || insertion != nil else { return .unchanged }

        failureReason = "Text or focus changed before correction"
        guard !IsSecureEventInputEnabled(),
              let verified = focusedElement(expectedPID: expected.processID),
              CFEqual(verified, focused), selectedRange(of: verified) == expected.selection,
              string(
                in: NSRange(location: expected.contextStart, length: context.length), of: verified
              ) == expected.text
        else { return .unchanged }

        failureReason = "Editor did not confirm replacement; no additional edit was attempted"
        if usesAtomicOperation, let markers {
            let operation: [String: Any] = [
                "AXTextOperationType": "TextOperationReplacePreserveCase",
                "AXTextOperationMarkerRanges": [markers],
                "AXTextOperationReplacementString": replacementText,
                "AXTextOperationSmartReplace": false
            ]
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                focused, "AXTextOperation" as CFString, operation as CFDictionary, &result
            ) == .success else { return .unconfirmed }
        } else {
            pendingSelections.append(PendingSelection(
                snapshot: expected, originalRange: editRange,
                replacementRange: NSRange(
                    location: editRange.location, length: (replacementText as NSString).length
                ), replacementContext: replacementContext, caret: caretLocation
            ))
            guard setSelection(editRange, markers: markers, on: focused),
                  await waitUntil({ self.selectedRange(of: focused) == editRange })
            else {
                let reported = selectedRange(of: focused)
                    .map { "\($0.location):\($0.length)" } ?? "unavailable"
                let selectedLength = (attribute(kAXSelectedTextAttribute, of: focused) as? String)
                    .map { ($0 as NSString).length.description } ?? "unavailable"
                _ = recoverPendingSelection()
                failureReason = "Editor selection not confirmed: requested \(editRange.location):\(editRange.length), reported \(reported), selected length \(selectedLength)"
                return .unconfirmed
            }
            guard !Task.isCancelled, !IsSecureEventInputEnabled(),
                  let target = focusedElement(expectedPID: expected.processID),
                  CFEqual(target, focused), selectedRange(of: target) == editRange,
                  string(in: editRange, of: target) == originalText
            else {
                _ = recoverPendingSelection()
                return .unconfirmed
            }
            if let index = pendingSelections.firstIndex(where: { CFEqual($0.snapshot.element, focused) }) {
                pendingSelections[index].writeWasSubmitted = true
            }
            if usesSelectedText {
                let result = AXUIElementSetAttributeValue(
                    focused, kAXSelectedTextAttribute as CFString, replacementText as CFString
                )
                guard result == .success else {
                    if [.attributeUnsupported, .notImplemented].contains(result),
                       let index = pendingSelections.firstIndex(where: { CFEqual($0.snapshot.element, focused) }) {
                        pendingSelections[index].writeWasSubmitted = false
                    }
                    _ = recoverPendingSelection()
                    return .unconfirmed
                }
            } else if let insertion {
                insertion.0.postToPid(expected.processID)
                insertion.1.postToPid(expected.processID)
            }
        }
        guard await waitUntil({
            self.recoverPendingSelection()
                && self.matches(expected, text: replacementContext, caret: caretLocation)
        }) else {
            failureReason = "Editor did not confirm replacement text and caret"
            return .unconfirmed
        }

        let replacementLength = (replacement as NSString).length
        let replacementRange = NSRange(location: range.location, length: replacementLength)
        let updatedMarkers = expected.selectionMarkers == nil ? nil : selectedTextMarkers(of: focused)
        guard (expected.selectionMarkers == nil || updatedMarkers != nil),
              matches(expected, text: replacementContext, caret: caretLocation)
        else { return .unconfirmed }
        let updated = TextSnapshot(
            element: focused, processID: expected.processID,
            selection: NSRange(location: caretLocation, length: 0), selectionMarkers: updatedMarkers,
            contextStart: expected.contextStart, text: replacementContext
        )

        failureReason = nil
        return .applied(
            snapshot: updated,
            bounds: bounds(of: replacementRange, in: updated)
        )
    }

    private func setSelection(
        _ range: NSRange, markers: AXTextMarkerRange?, on element: AXUIElement
    ) -> Bool {
        if let markers {
            return AXUIElementSetAttributeValue(
                element, "AXSelectedTextMarkerRange" as CFString, markers
            ) == .success
        }
        var requested = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &requested) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value
        ) == .success
    }

    private func keyboardInsertion(_ text: String) -> (CGEvent, CGEvent)? {
        failureReason = "Keyboard insertion permission is unavailable"
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return nil }
        let characters = Array(text.utf16)
        return characters.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else {
                failureReason = "Replacement text is empty"
                return nil
            }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: felixSyntheticEventTag)
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: pointer)
            }
            return (down, up)
        }
    }

    private func matches(_ snapshot: TextSnapshot, text: String, caret: Int) -> Bool {
        guard let focused = focusedElement(expectedPID: snapshot.processID),
              CFEqual(focused, snapshot.element),
              selectedRange(of: focused) == NSRange(location: caret, length: 0)
        else { return false }
        return string(
            in: NSRange(location: snapshot.contextStart, length: (text as NSString).length),
            of: focused
        ) == text
    }

    private func supportsAtomicReplacement(
        on element: AXUIElement, in application: NSRunningApplication
    ) -> Bool {
        // Older WebKit can interpret an unknown replacement operation as selection.
        if !isChromium(application) {
            guard #available(macOS 15.2, *) else { return false }
        }
        var attributes: CFArray?
        return AXUIElementCopyParameterizedAttributeNames(element, &attributes) == .success
            && (attributes as? [String] ?? []).contains("AXTextOperation")
    }

    private func bounds(of range: NSRange, in snapshot: TextSnapshot) -> CGRect? {
        guard let focused = focusedElement(expectedPID: snapshot.processID),
              CFEqual(focused, snapshot.element)
        else { return nil }
        var requested = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return nil }
        if let rectangle = bounds(
            for: kAXBoundsForRangeParameterizedAttribute, value: rangeValue, of: focused
        ) {
            return rectangle
        }

        // Chromium can expose text-marker geometry even when numeric bounds are empty.
        // Numeric paragraph-end offsets can include the next paragraph in Chromium.
        let suffixLength = snapshot.selection.location - NSMaxRange(range)
        guard range.length > 0, (0...4).contains(suffixLength),
              selectedRange(of: focused) == snapshot.selection,
              let selectedMarkers = selectedTextMarkers(of: focused),
              let expectedText = string(in: range, of: focused)
        else { return nil }
        let caretMarker = AXTextMarkerRangeCopyEndMarker(selectedMarkers)
        guard let end = marker(before: caretMarker, count: suffixLength, of: focused),
              let start = marker(before: end, count: range.length, of: focused)
        else { return nil }
        let markers = AXTextMarkerRangeCreate(nil, start, end)
        guard (parameterizedAttribute(
            "AXStringForTextMarkerRange", value: markers, of: focused
        ) as? String) == expectedText
        else { return nil }
        return bounds(for: "AXBoundsForTextMarkerRange", value: markers, of: focused)
    }

    private func marker(before marker: AXTextMarker, count: Int, of element: AXUIElement) -> AXTextMarker? {
        self.marker(from: marker, offset: -count, of: element)
    }

    private func marker(from marker: AXTextMarker, offset: Int, of element: AXUIElement) -> AXTextMarker? {
        var current = marker
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        let attribute = offset < 0 ? "AXPreviousTextMarkerForTextMarker" : "AXNextTextMarkerForTextMarker"
        for _ in 0..<abs(offset) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                failureReason = "Editor did not provide the text-marker range promptly"
                return nil
            }
            guard let previous = parameterizedAttribute(
                attribute, value: current, of: element
            ), CFGetTypeID(previous) == AXTextMarkerGetTypeID()
            else { return nil }
            current = previous as! AXTextMarker
        }
        return current
    }

    private func bounds(
        for parameter: String, value: CFTypeRef, of element: AXUIElement
    ) -> CGRect? {
        guard let result = parameterizedAttribute(parameter, value: value, of: element),
              CFGetTypeID(result) == AXValueGetTypeID()
        else { return nil }
        var rectangle = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rectangle),
              !rectangle.isNull, !rectangle.isInfinite, !rectangle.isEmpty
        else { return nil }
        return rectangle
    }

    func prepare(_ application: NSRunningApplication) {
        guard hasAccessibilityAccess, isChromium(application) else { return }

        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.04)
        guard (attribute("AXManualAccessibility", of: element) as? Bool) != true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Electron restarts its two-second activation delay on every accessibility request.
        if let requestedAt = accessibilityRequests[application.processIdentifier],
           now - requestedAt < 3 {
            return
        }
        accessibilityRequests[application.processIdentifier] = now
        let result = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        if result != .success {
            accessibilityLog.error("Unable to enable browser accessibility: \(result.rawValue)")
        }
    }

    private func isChromium(_ application: NSRunningApplication?) -> Bool {
        let identifier = application?.bundleIdentifier?.lowercased() ?? ""
        return [
            "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser",
            "company.thebrowser.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi",
            "com.microsoft.vscode", "com.deanmsmith.notas.electron", "com.tinyspeck.slackmacgap"
        ].contains(where: identifier.hasPrefix)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        repeat {
            guard !Task.isCancelled, !IsSecureEventInputEnabled() else { return false }
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(4))
            } catch { return false }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func focusedElement(expectedPID: pid_t) -> AXUIElement? {
        guard !IsSecureEventInputEnabled(), hasAccessibilityAccess,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID
        else { return nil }

        let application = AXUIElementCreateApplication(expectedPID)
        AXUIElementSetMessagingTimeout(application, 0.04)
        guard let value = attribute(kAXFocusedUIElementAttribute, of: application)
            ?? attribute(kAXFocusedUIElementAttribute, of: systemWide),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }

        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.04)
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success, processID == expectedPID
        else { return nil }
        return element
    }

    private func isSafe(_ element: AXUIElement, in application: NSRunningApplication) -> Bool {
        let isVSCode = application.bundleIdentifier?.lowercased().hasPrefix("com.microsoft.vscode") == true
        let isChat = isVSCode && isChatInput(element)
        guard let role = attribute(kAXRoleAttribute, of: element) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              (attribute(kAXEnabledAttribute, of: element) as? Bool) != false,
              (attribute("AXProtectedContent", of: element) as? Bool) != true,
              (!isVSCode || isChat), (isChat || !hasTechnicalDocument(element))
        else { return false }

        let subrole = (attribute(kAXSubroleAttribute, of: element) as? String ?? "").lowercased()
        guard !subrole.contains("secure"), !subrole.contains("search") else { return false }

        let names = [
            kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
            kAXRoleDescriptionAttribute, "AXPlaceholderValue", "AXDOMIdentifier"
        ]
        let descriptions = names.compactMap { attribute($0, of: element) as? String }
        let classes = attribute("AXDOMClassList", of: element) as? [String] ?? []
        let hints = (descriptions + classes).map { String($0.prefix(512)) }
            .joined(separator: " ").lowercased()
        guard ![
            "password", "passwd", "passphrase", "one-time", "verification code",
            "credit card", "card number", "security code", "api key", "secret key",
            "address bar", "url", "omnibox", "file name", "filename", "save as",
            "file path"
        ].contains(where: hints.contains)
        else { return false }
        return isChat || ![
            "code editor", "source editor", "monaco", "codemirror", "ace_editor"
        ].contains(where: hints.contains)
    }

    static func hasChatInputMetadata(classes: [String]) -> Bool {
        return classes.contains("chat-input-container") || classes.contains("chat-editor-container")
    }

    private func isChatInput(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<16 {
            let classes = attribute("AXDOMClassList", of: current) as? [String] ?? []
            if Self.hasChatInputMetadata(classes: classes) { return true }
            guard let parent = attribute(kAXParentAttribute, of: current),
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            current = parent as! AXUIElement
        }
        return false
    }

    private func isWebContent(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<16 {
            if attribute(kAXRoleAttribute, of: current) as? String == "AXWebArea" { return true }
            guard let parent = attribute(kAXParentAttribute, of: current),
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            current = parent as! AXUIElement
        }
        return false
    }

    private func hasTechnicalDocument(_ element: AXUIElement) -> Bool {
        guard let value = attribute(kAXWindowAttribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID(),
              let document = attribute(kAXDocumentAttribute, of: value as! AXUIElement) as? String,
              let url = URL(string: document)
        else { return false }

        let extensions = [
            "swift", "py", "pyi", "js", "jsx", "ts", "tsx", "json", "yaml", "yml",
            "toml", "ini", "conf", "cfg", "xml", "html", "css", "scss", "sh", "bash",
            "zsh", "fish", "c", "h", "cpp", "hpp", "cs", "java", "kt", "rs", "go",
            "rb", "php", "sql", "r", "lua", "ipynb", "svelte", "vue"
        ]
        return extensions.contains(url.pathExtension.lowercased())
            || url.lastPathComponent.hasPrefix(".")
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private func parameterizedAttribute(_ name: String, value: CFTypeRef, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name as CFString, value, &result
        ) == .success
        else { return nil }
        return result
    }

    private func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    private func selectedTextMarkers(of element: AXUIElement) -> AXTextMarkerRange? {
        guard let value = attribute("AXSelectedTextMarkerRange", of: element),
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        return (value as! AXTextMarkerRange)
    }

    private func string(in range: NSRange, of element: AXUIElement) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var requested = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        )
        if [.parameterizedAttributeUnsupported, .attributeUnsupported, .notImplemented].contains(result) {
            return valueString(in: range, of: element)
        }
        guard result == .success,
              let text = value as? String, (text as NSString).length == range.length
        else { return nil }
        return text
    }

    private func valueString(in range: NSRange, of element: AXUIElement) -> String? {
        guard range.location >= 0, range.length >= 0,
              let count = attribute(kAXNumberOfCharactersAttribute, of: element) as? NSNumber,
              (0...16_384).contains(count.intValue),
              let text = attribute(kAXValueAttribute, of: element) as? String
        else { return nil }
        let source = text as NSString
        guard source.length <= 16_384, range.location <= source.length,
              range.length <= source.length - range.location
        else { return nil }
        return source.substring(with: range)
    }
}