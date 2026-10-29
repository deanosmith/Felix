import AppKit
import ApplicationServices
import Carbon

let orthSyntheticEventTag: Int64 = 0x4F_52_54_48

struct TextSnapshot {
    let element: AXUIElement
    let processID: pid_t
    let selection: NSRange
    let contextStart: Int
    let text: String

    var caretOffset: Int { selection.location - contextStart }
}

@MainActor
final class AccessibilityTextClient {
    private let systemWide = AXUIElementCreateSystemWide()
    private var preparedProcessID: pid_t?
    private(set) var failureReason: String?

    init() {
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
            "com.microsoft.vscode", "com.jetbrains.", "com.agilebits.",
            "com.1password.", "com.cursor.", "com.parallels.", "com.citrix."
        ]
        return !excluded.contains(identifier) && !prefixes.contains(where: identifier.hasPrefix)
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
          guard isSafe(element) else { return nil }
          failureReason = "Focused field does not expose an editable caret"
          guard
              isSettable(kAXSelectedTextRangeAttribute, on: element),
              let selection = selectedRange(of: element),
              selection.location >= 0, selection.length == 0
        else { return nil }

        let characterCount = (attribute(kAXNumberOfCharactersAttribute, of: element) as? NSNumber)?
            .intValue ?? selection.location
        guard characterCount >= selection.location else { return nil }

        let start = max(0, selection.location - 1_024)
        let length = selection.location - start + min(128, characterCount - selection.location)
          failureReason = "Focused field does not expose readable text"
        guard let text = string(in: NSRange(location: start, length: length), of: element),
              (text as NSString).length == length
        else { return nil }

          failureReason = nil
        return TextSnapshot(
            element: element,
            processID: expectedPID,
            selection: selection,
            contextStart: start,
            text: text
        )
    }

    func replace(
        range: NSRange,
        original: String,
        replacement: String,
        in expected: TextSnapshot
    ) -> TextSnapshot? {
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
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet(charactersIn: ".!?,;:").contains($0)
              })
        else { return nil }

        let application = NSRunningApplication(processIdentifier: expected.processID)
        let usesAccessibilityWrite = !isChromium(application)
            && isSettable(kAXSelectedTextAttribute, on: current.element)
        failureReason = "Keyboard insertion permission needed"
        guard usesAccessibilityWrite || CGPreflightPostEventAccess() else { return nil }

        let editRange = NSRange(location: range.location, length: range.length + suffixRange.length)
        let selectedText = original + suffix
        let insertedText = replacement + suffix
        failureReason = "Editor did not accept the correction selection"
        guard setSelection(editRange, on: current.element), waitUntil({
            guard let focused = self.focusedElement(expectedPID: expected.processID) else { return false }
            return CFEqual(focused, current.element)
                && self.selectedRange(of: focused) == editRange
                && self.string(in: editRange, of: focused) == selectedText
        })
        else {
            restoreSelection(afterFailureIn: current, selected: editRange, original: selectedText)
            return nil
        }

        guard let focused = focusedElement(expectedPID: expected.processID),
              CFEqual(focused, current.element), isSafe(focused),
              selectedRange(of: focused) == editRange,
              string(in: editRange, of: focused) == selectedText
        else {
            restoreSelection(afterFailureIn: current, selected: editRange, original: selectedText)
            return nil
        }

        failureReason = "Editor did not accept the replacement"
        let didInsert: Bool
        if usesAccessibilityWrite {
            didInsert = AXUIElementSetAttributeValue(
                current.element, kAXSelectedTextAttribute as CFString, insertedText as CFString
            ) == .success
        } else {
            didInsert = insertUsingKeyboard(insertedText, processID: expected.processID)
        }
        guard didInsert else {
            restoreSelection(afterFailureIn: current, selected: editRange, original: selectedText)
            return nil
        }

        let replacementLength = (replacement as NSString).length
        let caret = current.selection.location + replacementLength - range.length
        let insertedRange = NSRange(location: range.location, length: (insertedText as NSString).length)
        guard waitUntil({
            guard let focused = self.focusedElement(expectedPID: expected.processID) else { return false }
            return CFEqual(focused, current.element)
                && self.string(in: insertedRange, of: focused) == insertedText
                && self.selectedRange(of: focused) == NSRange(location: caret, length: 0)
        }), let updated = snapshot(expectedPID: expected.processID)
        else {
            restoreSelection(afterFailureIn: current, selected: editRange, original: selectedText)
            return nil
        }

        return updated
    }

    func bounds(of range: NSRange, in snapshot: TextSnapshot) -> CGRect? {
        guard let focused = focusedElement(expectedPID: snapshot.processID),
              CFEqual(focused, snapshot.element)
        else { return nil }
        var requested = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rectangle = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rectangle),
              !rectangle.isNull, !rectangle.isInfinite, !rectangle.isEmpty
        else { return nil }
        return rectangle
    }

    func prepare(_ application: NSRunningApplication) {
        guard AXIsProcessTrusted(), preparedProcessID != application.processIdentifier else { return }
        preparedProcessID = application.processIdentifier
        guard isChromium(application) else { return }

        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.04)
        _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func isChromium(_ application: NSRunningApplication?) -> Bool {
        let identifier = application?.bundleIdentifier?.lowercased() ?? ""
        return [
            "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser",
            "company.thebrowser.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi"
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
        guard !IsSecureEventInputEnabled(), CGPreflightPostEventAccess(),
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
                event.setIntegerValueField(.eventSourceUserData, value: orthSyntheticEventTag)
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: pointer)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
            return true
        }
    }

    private func focusedElement(expectedPID: pid_t) -> AXUIElement? {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID,
              let value = attribute(kAXFocusedUIElementAttribute, of: systemWide),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }

        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.04)
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success, processID == expectedPID
        else { return nil }
        return element
    }

    private func isSafe(_ element: AXUIElement) -> Bool {
        guard let role = attribute(kAXRoleAttribute, of: element) as? String,
              [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              (attribute(kAXEnabledAttribute, of: element) as? Bool) != false,
              (attribute("AXProtectedContent", of: element) as? Bool) != true,
              !hasTechnicalDocument(element)
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
        return ![
            "password", "passwd", "passphrase", "one-time", "verification code",
            "credit card", "card number", "security code", "api key", "secret key",
            "address bar", "url", "omnibox", "file name", "filename", "save as",
            "file path", "code editor", "source editor", "monaco", "codemirror", "ace_editor"
        ].contains(where: hints.contains)
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

    private func setSelection(_ range: NSRange, on element: AXUIElement) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let selection = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, selection
        ) == .success
    }

    private func string(in range: NSRange, of element: AXUIElement) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var requested = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        ) == .success, let text = value as? String { return text }

        guard let count = attribute(kAXNumberOfCharactersAttribute, of: element) as? NSNumber,
              (0...16_384).contains(count.intValue),
              let text = attribute(kAXValueAttribute, of: element) as? String
        else { return nil }
        let source = text as NSString
        guard source.length <= 16_384, range.location <= source.length,
              range.length <= source.length - range.location
        else { return nil }
        return source.substring(with: range)
    }

    private func restoreSelection(
        afterFailureIn snapshot: TextSnapshot, selected: NSRange, original: String
    ) {
        guard let focused = focusedElement(expectedPID: snapshot.processID),
              CFEqual(focused, snapshot.element), selectedRange(of: focused) == selected,
              string(in: selected, of: focused) == original
        else { return }
        _ = setSelection(snapshot.selection, on: focused)
    }
}