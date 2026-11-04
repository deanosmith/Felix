# Orth Prototype

## Run

1. Open `dist/Orth.app`.
2. Grant the app access in System Settings > Privacy & Security > Accessibility.
3. If Settings reports keyboard access unavailable, use Settings > Input Monitoring
   Settings to grant access. macOS may require quitting and reopening it.
4. In a supported prose field, type a lowercase typo such as `mispell`, then a space.
5. Backspace deletes the trailing space normally without reverting the correction.
   Backspace at the end of the corrected word restores the original typo instead
   of deleting its last character; any trailing punctuation is deleted normally
   first. Command-Z reverts the correction immediately. Undo remains available
   for 10 seconds, provided no other text or focus changes occur.

The app runs behind a wrench icon in the menu bar, not the Dock. Its menu includes
Pause, Sensitivity, Typing Profile, Apps, Glow Colour..., Ignore Last Correction,
Settings, and Quit.
Pause changes to Resume while paused. Settings contains status, the correction
count, recent activity, Check Focused Field, Accessibility Settings, and Input
Monitoring Settings. Ignore Last Correction
applies to the last corrected word or phrase; undo remains available through the keyboard.
The wrench is filled while unpaused and outlined and dimmed while paused.
A green wrench app icon also identifies Orth in
Finder and macOS privacy settings. Ignoring a word saves it locally and attempts
to revert that correction if the text is still unchanged.

Corrections replace text automatically after a space, including non-breaking
spaces used by web editors. There is no suggestion popup. A final word without
a following space is not corrected yet.

After the editor confirms a replacement, a soft underline glows beneath only the
corrected word's characters, excluding trailing spaces and punctuation. It is
white by default; Glow Colour... opens the macOS colour picker to choose another
colour, saved locally across restarts and used for subsequent corrections.
It appears at full brightness when the correction is confirmed, then smoothly
fades out over 1.6 seconds. With Reduce Motion enabled, it stays steady for 1.6
seconds instead. It never selects text, takes keyboard focus, or intercepts
clicks. The menu-bar icon also
shows a green checkmark while correction feedback is active, including when word
bounds are unavailable. Each correction has its own glow and expiry time:
overlapping glows coexist, and new corrections do not restart or hide earlier
ones. No feedback is shown for an unconfirmed replacement.

Chromium editors can return empty rectangles for numeric text ranges even when
correction works. If numeric word bounds are unavailable, Orth derives an exact
word-only text-marker range from the confirmed post-replacement caret and checks
that its text matches the corrected word before requesting bounds. It never uses
the replacement selection's bounds, which include the trailing separator.
The glow does not create an extra selection or move the caret.
If neither API provides geometry, the activity line and Console report that
word bounds are unavailable; the menu-bar checkmark still confirms the edit.

## Applications

Use Apps in the menu bar to choose which apps Orth can correct:

- All Apps Except Excluded is the default and preserves the original behavior
  until you add exclusions.
- Only Included Apps restricts corrections to apps checked in Included Apps.
- Excluded Apps always takes priority, even if an app is also included.

Included Apps and Excluded Apps show running apps alongside saved entries.
Check an app to add it to that list; uncheck it to remove it. Add App... lets you
select an installed app even when it is not running. Choices use bundle
identifiers and are saved locally across restarts. Saved apps remain removable
even if they are no longer installed.

Changing the mode or either list cancels pending corrections and clears undo
context. The menu reports App excluded - suspended when the focused app is not
allowed. Inclusion never overrides protected-app, secure-input, sensitive-field,
or technical-text safeguards.

## Browser Access and Diagnostics

Chrome, Electron, and embedded WebKit text fields do not always advertise usable
selected-text writes. Orth enables the accessibility tree for supported browsers, Notas, and
VS Code, selects only the completed word and its trailing punctuation and spaces,
then reads the selection back before editing. In web editors, the selection is
anchored to the original caret's text markers rather than numeric offsets:
Chromium can map a numeric end-of-paragraph position into the next paragraph,
silently merging or deleting that line even though the selected text looks right.
Web editors without writable text markers are skipped instead of using that
unsafe numeric fallback. The same suffix is included unchanged in the replacement,
leaving the caret naturally after it without another selection write.

Chromium-based editors and fields inside embedded web views use normal Unicode
keyboard input rather than selected-text writes, which can report success without
actually applying an edit. This also covers the Python Grok overlay's WebKit
composer. Other editors use keyboard input when
selected-text writes are unavailable. Events enter after Orth's own monitoring
tap so its read-back wait cannot block them. Focus and selection are checked
immediately before insertion, and the clipboard is never used.

Editable combo boxes are supported alongside text fields and text areas, including
the Grok composer in the Python-based macOS overlay's embedded WebKit view.
They must expose readable text and a writable caret and pass the same sensitive-field
and technical-text safeguards as other inputs.

Focus is read from the active app first, with the system-wide focus as a fallback.
Some Chromium fields report more characters than their ranged-text API can read,
and their whole-field value can use different offsets. If the read extending past
the caret fails, Orth reads only through the caret. Bounded whole-field values are
used only when the ranged-text API is unsupported, not when a supported range read
fails. This keeps the completed word and its separator aligned with the editor's
selection ranges instead of incorrectly reporting a missing space.

VS Code is supported only inside its chat input containers, identified through
accessibility metadata. Its source editors, terminal, and other fields remain
excluded. A chat input is not excluded just because the active editor tab is a
source file or the composer uses Monaco internally. Sensitive fields and
code-looking text remain protected, including inside chat.

For VS Code's native EditContext chat input, set Editor: Accessibility Support
to On (`"editor.accessibilitySupport": "on"` in VS Code settings). With this
setting explicitly Off, VS Code can expose an empty accessibility buffer even
while text is being entered. Orth does not bypass unreadable-field safeguards
or change this preference automatically. Enabling it also turns on VS Code's
screen-reader optimizations.

Selection and insertion updates have short, bounded read-back waits. A rejected
replacement restores the original caret when the selected text is unchanged,
rather than leaving the typo selected. Secure fields and protected apps remain
excluded.

Focus the WhatsApp message composer, choose Settings > Check Focused Field from
Orth's menu, then reopen Settings to read the result. The activity line also reports why the
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

Dictionary corrections require the original word to fail spell checking. This is spelling
correction, not grammar rewriting or replacement of correctly spelled words.
Secure-input, sensitive-field, technical-text, detected-name, ignored-word, and
stale-text protections remain active at every level. Corrections still trigger
after a space; sensitivity changes candidate acceptance, not the typing delay.

## Typing Profile

Typing Profile in the menu bar provides independent switches for double initial
capitals (`THis` to `This`), prioritising accidental repeated-letter fixes, and
repairing configured space mistakes. All three are enabled initially. Turning
off repeated-letter prioritisation still allows Apple's normal spelling
suggestions; it does not prohibit dictionary corrections of repeated letters.

Edit Replacements... manages explicit personal rules, one `typo = correction`
per line. Each side accepts one or two lowercase English words of up to 32
letters each. Empty lines are allowed; duplicate typos and unchanged replacements
are rejected without saving. Delete a line to remove a rule, or clear the editor
to remove all rules. Initial capitalisation is preserved. Explicit rules take
priority over spelling and name detection, but still respect macOS Text
Replacements, ignored words, technical-text, secure-field, app, and stale-text
protections.

The initial rules are `thiis = this` and `thi s = this`. The split rule also
supports `Thi sdog ` to `This dog `: Orth moves the configured stranded `s` only
when the next token is misspelled and the remaining word is valid. Valid next
words are not altered, and ambiguous competing repairs are skipped. The space
between tokens must be one ordinary or non-breaking space, never a newline.
Configured split prefixes such as `Thi ` are left unchanged while waiting for
the next completed word. Disabling space repair disables multiword rules and
this deferral. No general phrase joining or grammar rewriting is performed.

Repeated-letter prioritisation only removes one adjacent duplicate from a
misspelled word when it produces exactly one valid spelling; valid doubles such
as `book` are untouched. Explicit personal rules remain active independently of
this option. Double-capital words are skipped when their option is disabled.

The profile is stored locally in the app's preferences, survives restarts, and
is editable and resettable via Reset Typing Profile.... Reset requires
confirmation and leaves ignored words and other settings unchanged. Profile
changes cancel pending corrections and clear undo context; profile corrections
otherwise use the existing guarded replacement, glow, and keyboard undo paths.
No automatic learning, typing history, or network service is added.

## macOS Text Replacements

System Settings > Keyboard > Text Replacements takes priority over Orth.
Before applying any correction, Orth checks the current system replacement
dictionary and skips edits overlapping a shortcut, a partially typed multiword
shortcut, or its expanded text. Matching respects word boundaries, ignores
capitalisation, and handles non-breaking spaces used by web editors.
Unrelated text remains eligible for correction. Orth does not expand the
shortcuts itself, change macOS settings, or enable substitutions in apps that
do not support them.

Run the focused regression checks with `zsh scripts/test-text-replacements.sh`.
They use isolated fixtures, do not modify system replacements, and require only
Command Line Tools, not Xcode or XCTest.

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
  terminals, remote desktop apps, and recognized source/config documents are
  skipped. VS Code's chat inputs are the exception to its app-wide editor block;
  its source editors and terminal remain excluded.
- Numbers and technical tokens such as URLs, emails, paths, and filenames with
  extensions are skipped. Code-looking lines and marked-text input methods are skipped.
- Mixed-case and all-capital words are skipped to protect names and acronyms,
  except double initial capitals when enabled in Typing Profile.
  Conservative and Balanced also skip initially capitalized words. Named-entity
  detection remains active, but names and extensionless filenames cannot always
  be distinguished from typos. Ignore handles exceptions.
- Conservative checks deliberately miss some typos. App-specific text controls,
  existing native autocorrect, and rich-text editors need manual compatibility checks.
