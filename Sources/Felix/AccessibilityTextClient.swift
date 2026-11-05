import AppKit
import ApplicationServices
import Carbon

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

@MainActor
enum TextReplacementTransaction {
    static func apply(
        insert: () -> Bool,
        verifyInsertion: () -> Bool,
        removeOriginal: () -> Bool,
        verifyReplacement: () -> Bool
    ) -> Bool {
        guard insert(), verifyInsertion() else { return false }
        guard removeOriginal() else { return false }
        return verifyReplacement()
    }
}

@MainActor
final class AccessibilityTextClient {
    private let systemWide = AXUIElementCreateSystemWide()
    private let applicationFilter: ApplicationFilter
    private(set) var failureReason: String?
    var hasAccessibilityAccess = false
    var hasKeyboardInsertionAccess = false

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
        failureReason = "Focused app is unavailable or protected"
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == expectedPID, allows(application)
        else { return nil }
        prepare(application)

        failureReason = "Focused text field is unavailable"
        guard let element = focusedElement(expectedPID: expectedPID) else { return nil }
        failureReason = "Focused field is protected or unsupported"
        guard isSafe(element, in: application) else { return nil }
        let isWebEditor = isChromium(application) || isWebContent(element)
        let selectionMarkers = isWebEditor ? selectedTextMarkers(of: element) : nil
        failureReason = isWebEditor
            ? "Focused web field does not expose a writable text-marker caret"
            : "Focused field does not expose an editable caret"
        guard
              isWebEditor
                ? selectionMarkers != nil && isSettable("AXSelectedTextMarkerRange", on: element)
                : isSettable(kAXSelectedTextRangeAttribute, on: element),
              let selection = selectedRange(of: element),
              selection.location >= 0, selection.length == 0
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

    func replace(
        range: NSRange,
        original: String,
        replacement: String,
        in expected: TextSnapshot
    ) -> (snapshot: TextSnapshot, bounds: CGRect?)? {
        guard let current = snapshot(expectedPID: expected.processID) else { return nil }
        failureReason = "Text or focus changed before correction"
        guard
              CFEqual(current.element, expected.element),
              current.selection == expected.selection,
              current.contextStart == expected.contextStart, current.text == expected.text,
              string(in: range, of: current.element) == original,
              range.location >= 0, range.length <= current.selection.location - range.location
        else { return nil }

        let suffixRange = NSRange(
            location: NSMaxRange(range), length: current.selection.location - NSMaxRange(range)
        )
        guard suffixRange.length <= 4,
              let suffix = string(in: suffixRange, of: current.element),
              suffix.unicodeScalars.allSatisfy({
                  CharacterSet.whitespaces.contains($0)
                      || CharacterSet(charactersIn: ".!?,;:").contains($0)
              })
        else { return nil }

        let editRange = NSRange(location: range.location, length: range.length + suffixRange.length)
        let originalText = original + suffix
        let replacementText = replacement + suffix
        let context = current.text as NSString
        let localRange = NSRange(
            location: editRange.location - current.contextStart, length: editRange.length
        )
        guard localRange.location >= 0, NSMaxRange(localRange) <= context.length else { return nil }
        let insertedContext = context.replacingCharacters(
            in: NSRange(location: localRange.location, length: 0), with: replacementText
        )
        let replacementContext = context.replacingCharacters(in: localRange, with: replacementText)
        let caretLocation = range.location + (replacementText as NSString).length
        failureReason = "Focused app is unavailable"
        guard let application = NSRunningApplication(processIdentifier: expected.processID)
        else { return nil }
        failureReason = "Keyboard insertion permission needed"
        guard hasKeyboardInsertionAccess else { return nil }

        guard let focused = focusedElement(expectedPID: expected.processID),
              CFEqual(focused, current.element), isSafe(focused, in: application),
              selectedRange(of: focused) == current.selection,
              string(in: editRange, of: focused) == originalText
        else { return nil }

        failureReason = "Editor did not confirm the correction caret"
        guard setCaret(at: range.location, in: current), waitUntil({
            self.matches(current, text: current.text, caret: range.location)
        }) else {
            restoreCaret(afterFailureIn: current, at: range.location)
            return nil
        }

        failureReason = "Editor did not confirm inserted text; original text was kept"
        guard TextReplacementTransaction.apply(
            insert: {
                self.insertUsingKeyboard(replacementText, processID: expected.processID)
            },
            verifyInsertion: {
                self.waitUntil {
                    self.matches(current, text: insertedContext, caret: caretLocation)
                }
            },
            removeOriginal: {
                guard self.matches(current, text: insertedContext, caret: caretLocation)
                else { return false }
                self.failureReason = "Editor did not confirm removal; replacement text was kept"
                return self.removeUsingKeyboard(originalText.count, processID: expected.processID)
            },
            verifyReplacement: {
                self.waitUntil {
                    self.matches(current, text: replacementContext, caret: caretLocation)
                }
            }
        ) else {
            restoreCaret(afterFailureIn: current, at: range.location)
            return nil
        }

        let replacementLength = (replacement as NSString).length
        let replacementRange = NSRange(location: range.location, length: replacementLength)
        guard let updated = snapshot(expectedPID: expected.processID) else { return nil }

        return (
            snapshot: updated,
            bounds: bounds(of: replacementRange, in: updated)
        )
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

    private func setCaret(at location: Int, in snapshot: TextSnapshot) -> Bool {
        guard location >= 0, location <= snapshot.selection.location,
              let focused = focusedElement(expectedPID: snapshot.processID),
              CFEqual(focused, snapshot.element)
        else { return false }
        if let markers = snapshot.selectionMarkers {
            guard let caret = marker(
                before: AXTextMarkerRangeCopyEndMarker(markers),
                count: snapshot.selection.location - location, of: focused
            ) else { return false }
            let selection = AXTextMarkerRangeCreate(nil, caret, caret)
            return AXUIElementSetAttributeValue(
                focused, "AXSelectedTextMarkerRange" as CFString, selection
            ) == .success
        }
        var range = CFRange(location: location, length: 0)
        guard let selection = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, selection
        ) == .success
    }

    private func restoreCaret(afterFailureIn snapshot: TextSnapshot, at location: Int) {
        guard matches(snapshot, text: snapshot.text, caret: location) else { return }
        _ = setCaret(at: snapshot.selection.location, in: snapshot)
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
        var current = marker
        for _ in 0..<count {
            guard let previous = parameterizedAttribute(
                "AXPreviousTextMarkerForTextMarker", value: current, of: element
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
        _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func isChromium(_ application: NSRunningApplication?) -> Bool {
        let identifier = application?.bundleIdentifier?.lowercased() ?? ""
        return [
            "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser",
            "company.thebrowser.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi",
            "com.microsoft.vscode", "com.deanmsmith.notas.electron", "com.tinyspeck.slackmacgap"
        ].contains(where: identifier.hasPrefix)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        repeat {
            guard !IsSecureEventInputEnabled() else { return false }
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.004)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func insertUsingKeyboard(_ text: String, processID: pid_t) -> Bool {
        guard !IsSecureEventInputEnabled(), hasKeyboardInsertionAccess,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }

        let characters = Array(text.utf16)
        return characters.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return false }
            for event in [keyDown, keyUp] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: felixSyntheticEventTag)
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: pointer)
                event.postToPid(processID)
            }
            return true
        }
    }

    private func removeUsingKeyboard(_ count: Int, processID: pid_t) -> Bool {
        guard count > 0, !IsSecureEventInputEnabled(), hasKeyboardInsertionAccess,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(
                  keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ForwardDelete), keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ForwardDelete), keyDown: false
              )
        else { return false }
        for event in [keyDown, keyUp] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: felixSyntheticEventTag)
        }
        for _ in 0..<count {
            keyDown.postToPid(processID)
            keyUp.postToPid(processID)
        }
        return true
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

    private func isChatInput(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<8 {
            let classes = attribute("AXDOMClassList", of: current) as? [String] ?? []
            if classes.contains("chat-input-container") { return true }
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

    private func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    private func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
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