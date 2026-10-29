# Orth Prototype

## Run

1. Open `dist/Orth.app`.
2. Grant the app access in System Settings > Privacy & Security > Accessibility.
3. If its menu reports keyboard access unavailable, use Input Monitoring Settings
   in the app menu to grant access. macOS may require quitting and reopening it.
4. In a supported prose field, type a lowercase typo such as `mispell`, then a space.
5. Press Backspace immediately to revert a correction. Immediate Command-Z and
   Undo Last Correction in the menu also revert it when the text is unchanged.

The app runs in the menu bar, not the Dock. Its menu includes a correction count,
pause/resume, and Ignore Last Corrected Word. Ignoring a word saves it locally
and attempts to revert that correction if the text is still unchanged.

Corrections replace text automatically after a space, including non-breaking
spaces used by web editors. There is no suggestion popup. A final word without
a following space is not corrected yet.

After the editor confirms a replacement, a gentle green flash marks the corrected
word and fades within about 300 ms. It never selects text, takes keyboard focus,
or intercepts clicks. When word bounds are unavailable, the menu-bar icon briefly
flashes instead. No feedback is shown for an unconfirmed replacement.

## Browser Access and Diagnostics

Chrome's web fields do not always advertise writable selected text. Orth enables
Chromium's accessibility tree, selects only the completed word and its trailing
separator, then reads the selection back before editing. Chromium editors use
normal Unicode keyboard input rather than selected-text writes, which can be
advertised without actually applying a web edit. Other editors use keyboard
input when selected-text writes are unavailable. Events enter after Orth's own
monitoring tap so its read-back wait cannot block them. Focus and selection are
checked immediately before insertion, and the clipboard is never used.

Selection and insertion updates have short, bounded read-back waits. A rejected
replacement restores the original caret when the selected text is unchanged,
rather than leaving the typo selected. Secure fields and protected apps remain
excluded.

Focus the WhatsApp message composer, choose Check Focused Field from Orth's menu,
then reopen the menu to read the result. The activity line also reports why the
last attempted correction was skipped. This distinguishes permission problems
from unsupported fields and an absence of spelling suggestions. Permission-state
changes are logged to macOS Console without typed text or message contents.

Spelling and name analysis run on a separate serialized worker, not inside the
keyboard callback. Orth prepares the spelling service at startup and reports
Preparing spelling engine until it is ready. A disabled keyboard tap is detected
and re-enabled automatically. Correction-stage timing, cancellations, and skip
reasons are logged without word or message contents.

If the menu reports Accessibility permission needed after rebuilding or renaming,
remove the old app entry from System Settings > Privacy & Security > Accessibility,
then add `dist/Orth.app` and enable it. Check Input Monitoring if requested.

The original internal bundle identifier and preference domain are retained so
sensitivity and ignored words survive the rename. The app bundle, executable,
menus, and build/run task names are Orth.

## Sensitivity

Choose a level from Sensitivity in the menu bar. Aggressive is the initial level
for experimentation; subsequent choices are saved across restarts.

- Conservative: only Apple's automatic corrections for lowercase words of at
  least three letters, matching the original prototype's policy.
- Balanced: also considers nearby ranked spelling guesses when there is no
  usable automatic correction, while keeping the lowercase/three-letter rule.
- Aggressive: accepts the first usable ranked guess without Balanced's edit-size
  limit, and also considers two-letter and initially capitalized words. Initial
  capitalization is preserved. Expect more incorrect replacements at this level.

Every level requires the original word to fail spell checking. This is spelling
correction, not grammar rewriting or replacement of correctly spelled words.
Secure-input, sensitive-field, technical-text, detected-name, ignored-word, and
stale-text protections remain active at every level. Corrections still trigger
after a space; sensitivity changes candidate acceptance, not the typing delay.

## Build

Command Line Tools with Swift 6 or later are sufficient; full Xcode is not needed.
The deployment target is macOS 13 or later. Builds target the current Mac's CPU.
Quit the running app before rebuilding, then run:

```sh
zsh scripts/build-app.sh
open "dist/Orth.app"
```

Equivalent Build and Run tasks are included for VS Code. Run uses the existing
app bundle; run Build first after source changes.

Local builds are ad-hoc signed. Rebuilding can require removing and re-adding
the app in Accessibility/Input Monitoring. A development signing identity can
be supplied with `ORTH_SIGNING_IDENTITY` for more stable attribution. The original
`MAC_AUTOCORRECT_SIGNING_IDENTITY` variable remains a fallback for existing setups.

## Version One Boundaries

- English spelling, using Apple's spelling service and named-entity detection.
- Corrections start about 25 ms after a space, plus dictionary/accessibility time.
  New input, focus changes, stale text, and selections cancel work. Spelling
  results older than two seconds are discarded; focus and nearby text are checked
  again before applying a result. Slow service startup does not block the keyboard.
- Only a supported focused text field with a readable, editable selection is used.
  There is no whole-document replacement or clipboard fallback. Editors without
  writable selected text and Chromium editors use guarded Unicode keyboard input.
- Nearby context is limited to 1,024 UTF-16 units before and 128 after the caret.
  If ranged reads are unavailable, a bounded value read supports fields of up to
  16,384 UTF-16 units. Typed text is not logged or sent to a cloud API. Undo context
  expires in 10 seconds.
- Secure input, secure/search fields, password managers, known code editors,
  terminals, remote desktop apps, and recognized source/config documents are skipped.
- Numbers and technical tokens such as URLs, emails, paths, and filenames with
  extensions are skipped. Code-looking lines and marked-text input methods are skipped.
- Mixed-case and all-capital words are skipped to protect names and acronyms.
  Conservative and Balanced also skip initially capitalized words. Named-entity
  detection remains active, but names and extensionless filenames cannot always
  be distinguished from typos. Ignore Last Corrected Word handles exceptions.
- Conservative checks deliberately miss some typos. App-specific text controls,
  existing native autocorrect, and rich-text editors need manual compatibility checks.

## Version Two

Add saved per-app enable/disable controls. Secure-field and sensitive-input
protection must remain mandatory regardless of an app's enabled state.