# Correction overlay handoff

The overlay reuses the existing nonactivating panel and glass styling. One controller retains one capsule across presentations, plus one mouse-transparent companion surface for the blue range highlight. It does not create separate interaction windows for correction, suggestion, undo or confirmation.

The state machine has hidden, automaticCorrection, suggestion, undoLearning and learnedConfirmation states. An informational state preserves existing manual-review status messages. The confidence thresholds stay the same. Rejection counts only trigger a confirmation prompt; they never reduce confidence or suppress corrections.

## UI states

| State | Appearance | Lifetime |
| --- | --- | --- |
| Hidden | No capsule or range highlight | Until the next presentation |
| Automatic correction | Subtle 12% blue borderless range highlight (2.5-point corners, 2.5 × 1.5-point padding); `whta → what   Undo` in a 24-point glass capsule | 2.5 seconds |
| Suggestion | Source-range highlight; `source → suggestion   ⇥` | 5 seconds; Tab accepts, Escape dismisses |
| Undo learning | After the second rejection, the same capsule asks `Stop autocorrecting “whta”?   Yes`; no blue highlight | 5 seconds |
| Learned confirmation | Same capsule morphs to `✓ “whta” learned`; no action or highlight | 0.9 seconds |

macOS 26+ uses NSGlassEffectView with clear glass and a native window shadow, without a drawn outline. Older systems use NSVisualEffectView popover material. Capsule sizing adapts to content and caps at 320 points, with middle truncation for long text. Presentations use a subtle scale spring, eased frame resizing and fades. Reduce Motion disables these animations.

## Positioning and input safety

The old overlay used attributes(forCharacterIndex: 0, lineHeightRectangle:), which is the selection/caret anchor when no inline composition exists. That query remains the fallback. It is not a document-range rectangle.

The session now exposes the validated UTF-16 correction range, visible text and expected caret position. IMK firstRect(forCharacterRange:actualRange:) supplies the range rectangle. Complete horizontal range geometry is highlighted, including narrow single-line endpoint rectangles when the host omits actualRange; partial, wrapped, RTL/negative-width or unusable geometry falls back to the caret capsule. If neither anchor is usable/on screen, presentation is skipped and invisible suggestions cannot intercept Tab. No glyph widths are guessed.

While visible, a 0.12-second timer revalidates the caret and source text and updates geometry so the overlay follows window movement and scrolling where the client supports it. Keyboard movement uses the existing session invalidation. Ordinary typing keeps the automatic capsule visible for the remainder of its original 2.5 seconds, updating the expected caret without restarting its timer. Its Undo button and Control–Option–Z validate the exact correction plus trailing input and restore the original word while preserving everything typed afterward. Immediate Backspace and Command–Z retain their existing behavior. The dedicated shortcut uses the active IMK event route and is not registered globally; app or system shortcuts can still conflict. Mouse movement of the caret, changed text or lost geometry dismisses the presentation. Undo and suggestion acceptance retain the existing generation, text and double-selection checks. Always additionally validates the restored source before saving. Only confirming Yes saves protection: single tokens enter protected vocabulary; phrases retain context-specific pair suppression.

Neither overlay panel can become key or main; the action button refuses first responder and has no focus ring. Plain Tab is consumed when it accepts a suggestion or applies a word-boundary correction, preventing the same key from navigating host focus; a subsequent Tab with no new correction navigates normally. Shift-Tab retains backward navigation. The highlight ignores mouse events. The overlay never calls setSelectedRange or setMarkedText and does not install a global keyboard hook or request Accessibility permission.

## Validation completed before the testing handoff

- 130 Swift tests passed, including six new overlay tests for transitions/stale expiry, geometry bounds, correction/undo/confirmation, suggestion Tab/Escape/typing/movement, missing geometry, and stale learning actions.
- Release build and input-source registration succeeded.
- The updated app was installed at /Library/Input Methods/Cappy.app.
- Automated TextEdit input did not demonstrate correction callbacks, including after reopening TextEdit. That is an unresolved live IMK verification limitation, not a passing UI test.
- Further live testing was stopped at the user's request. The final spring/lifecycle polish was built, but the suite was not rerun after that polish.

## Manual test checklist

1. Select Cappy in the macOS input-source menu. If a previously open app receives no corrections after the update, save your work, fully quit and reopen that app to recreate its IMK connection.
2. In a new TextEdit document, physically type `I typed whta `, including the final space. Expect `I typed what `, a subtle blue highlight over only `what`, and the small Undo capsule immediately below it. Verify the caret remains after the space and there is no selected text.
3. Click Undo before the capsule expires. Expect exactly `I typed whta `, with no learning prompt after the first rejection. Repeat the correction and Undo; expect `Stop autocorrecting “whta”? Yes`. Dismissing it keeps future autocorrection enabled.
4. In a fresh document, type `ware you `. Expect a suggestion such as `Ware you → Are you ⇥`, with the source untouched. Press Tab within five seconds: expect acceptance and an Undo capsule. Capitalization may also cause an earlier automatic capsule.
5. Repeat the suggestion, press Escape, and then press Tab. The suggestion should disappear; Tab should behave normally in the host. Repeat with continued typing and with five-second expiry.
6. Test learning using an unwanted correction of an intentional token: Undo twice, then confirm Yes. Expect the learned confirmation for less than a second, then disappearance. Type the token again and verify it is preserved. Reopen Cappy Settings to confirm the token is protected; remove a temporary test token there afterward.
7. `SMT` was already present in this Mac's protected vocabulary at handoff. Type it and verify it remains unchanged. Do not force the real engine to produce an incorrect acronym edit just for the test. If SMT or another acronym is ever incorrectly corrected in an unprotected environment, use the Undo twice → Yes flow from step 6.
8. While an automatic capsule is visible, keep typing. Verify uninterrupted input and that the automatic capsule remains until its original 2.5-second expiry. Undo with the button or ⌃⌥Z before expiry and verify that subsequent text is preserved. While a suggestion is visible, keep typing; verify it is dismissed or recomputed without accepting the old suggestion.
9. Move the caret with arrows and with a mouse click while a capsule is visible. Verify dismissal and that clicking an old action cannot modify a different range. Move the app window or scroll without changing the caret: the capsule should follow where geometry stays reliable.
10. Try another host with weak geometry support. A valid caret alone should show the capsule without a guessed highlight; unusable range and caret geometry should show nothing. Verify typing and Tab remain normal. Client support varies, so this needs checking in your actual apps.
11. Also check Return/submission, Command shortcuts, Option/dead-key input, native undo and the existing manual correction shortcut in the apps you use.

## Screenshot follow-up

The installed executable matched the current build; the screenshot did not establish an outdated executable. The capsule now has a smaller 24-point height, muted source and arrow, emphasized replacement, blue action separated by a fine divider, and a softer rim. Width is measured from intrinsic text/button content rather than the previously constrained stack. An additional geometry regression test covers narrow endpoints, repeated caret rectangles, wrapping and wide rectangles. Build verification was performed; further live testing and test execution were left to the user as requested.

## October 12 feedback update

Automatic word highlights now include a faint blue outline. Continued ordinary typing preserves the capsule and its original expiry, with validated undo through the button or Control–Option–Z. Navigation, external text changes, app deactivation, or another presentation still end or replace the current feedback. Range highlighting continues to require reliable host geometry.

## Word-bounds compatibility repair

The highlight allows up to 0.4 seconds for asynchronous insertion to become readable, without drawing while the text differs. After matching once, any text mismatch removes the highlight immediately. Hosts that omit `actualRange` can supply a full word rectangle if it is distinct from their narrow caret rectangle. Partial ranges and repeated-caret geometry remain rejected.

If IMK bounds are unavailable, the read-only Accessibility fallback queries the focused editor in the matching foreground app, translates document offsets using both caret positions, verifies the exact local text, and obtains BoundsForRange. It handles the Accessibility top-left coordinate system and rechecks selection before using the result. No selection changes or document formatting are used. This fallback requires Cappy Accessibility access, enabled by the user through **Enable Cross-App Word Highlights…** in the Cappy input menu (also available in Cappy Settings). It never prompts during typing. Previous “no Accessibility permission needed” statements describe the native IMK route only. Temporary geometry diagnostics have been removed.

The vertical offset repair calibrates the range-query coordinates against IMK’s independent line-height caret query at the same insertion point. Their measured vertical delta is applied to both full ranges and endpoint ranges, preserving wrapped-line positions. Matching caret x positions, narrow caret widths and a bounded vertical difference are required; already aligned clients receive no shift. This avoids a hard-coded one-line adjustment across different fonts and apps.

## Discord and Codex compatibility (October 13)

The original right-click implementation only subscribed to IMK mouse callbacks. Discord's native context menu demonstrated that this was not sufficient for Electron editors. Cappy also lacked Accessibility permission on the development Mac, preventing the existing blue-highlight fallback.

Cross-app support now enables Electron's documented `AXManualAccessibility` attribute when permission is available. Exact AX word bounds are preferred to IMK geometry. Range translation supports words on either side of the caret and matching noncollapsed selections; the source text, selection and focused editor are revalidated. Secure fields are excluded.

A permission-gated mouse event tap watches secondary down/up and Control-click while a Cappy controller is active. It does not watch keyboard events. A click is consumed only after bounded AX hit testing and matching the word against the active IMK client; the menu opens on the paired release. Other clicks pass through. Menu actions validate focus and text again, replace through IMK and reuse Cappy's existing Undo ledger. AX is not used to change document values or selections. The lookup reads at most a 16,384-unit focused editor, scans at most 64 candidate offsets and stops its geometry search after a 120 ms budget; each AX request has a 30 ms messaging timeout. System timeouts re-enable the mouse tap.

Permission status is visible in Cappy Settings. `--diagnose-accessibility` reports permission, focused-editor capability and text length only, never contents. After enabling Cappy in System Settings → Privacy & Security → Accessibility, switch back to the editor and type once to refresh cross-app support. Verify right-click, two-finger secondary click, replacement, Undo and blue automatic-correction highlights in Discord and Codex. All 157 unit tests pass, but end-to-end verification still requires Accessibility permission; unit tests alone do not establish app compatibility.

## Electron highlights and borderless style (October 14)

Discord and Claude returned empty `AXBoundsForRange` for words, so no blue highlight appeared. When that query fails, Cappy now builds a text-marker range with `AXTextMarkerForIndex`, requires `AXStringForTextMarkerRange` to equal the expected word, and uses `AXBoundsForTextMarkerRange`. This is still read-only and still requires Accessibility permission. The highlight no longer has an outline, uses 2.5-point corners instead of 4, and has slightly more padding. Unit tests pass; the marker fallback needs live verification in Discord and Claude.

Revoking Accessibility while Cappy's mouse tap was active froze all input until restart, because Cappy re-enabled the tap whenever macOS disabled it. Cappy now removes the tap when access disappears. It checks on the Accessibility-change notification and every 0.5 seconds. A tap disabled by the user or the system stays off; only a timeout re-enables it, and only while access is still granted. This has not been tested by revoking access live; until it has been, quit Cappy before toggling the permission.

## Every-app presentation; right-click and written-text review removed (October 15)

Logs showed the overlay never appeared in Chrome, Claude, Discord, Notion, Obsidian and Codex: Accessibility reported no focused editor, empty `AXBoundsForRange`, or IMK/AX selections a character apart, IMK geometry was empty too, and `show` hid everything when no anchor existed. A probe of a focused Chrome contenteditable showed `AXBoundsForRange` returning a zero rect and `AXBoundsForTextMarkerRange` returning the whole field's frame for any range. `AXEnhancedUserInterface` is not implemented by Chrome's application element.

Changes:

- Geometry chain: word (IMK, AX index range, AX markers by index, then AX markers walked back from the editor's own caret with ±2 offset tolerance and exact read-back) → caret (IMK, then AX selection markers or the previous character) → focused editor frame → frontmost window frame from `CGWindowListCopyWindowInfo`. Field-sized areas place the capsule beside the field; larger areas inside their lower-left corner.
- Marker bounds equal to the element frame are rejected, so Chrome never highlights a whole field.
- Screen selection accepts partial overlap with a display; previously carets under the Dock or menu bar failed `visibleFrame.contains` and hid the capsule.
- Focus lookup falls back to the system-wide focused element (same pid) and an `AXEditableAncestor`; AX timeouts are 80–100 ms.
- Removed: right-click/Control-click word menu, the mouse event tap and its Accessibility-revocation handling, the ⌘⌥⇧C Carbon hotkey, the Correct Written Text menu item, `ManualTextCorrection`, `WordCorrectionReview` and their tests. ⌃⌥Z and the capsule's Undo are unchanged.

The Chrome probe confirmed the rejected geometry and the available editor frame. End-to-end typing in Chromium apps was not automated; check that the capsule appears under the field in Chrome, Claude and Discord.

### Lagging hosts (October 15, follow-up)

In Claude the capsule still appeared only sometimes. Electron applies `insertText` asynchronously: right after a correction it can report the replaced range as the selection, or a caret one or two characters behind. Two strict checks then dismissed the feedback almost immediately: the per-keystroke continuation check (exact caret and text) and the 0.12-second tracking check, which had only a 0.4-second grace period after presentation. Now:

- Continued typing keeps the feedback when the reported selection ends between the replacement and the expected caret. A caret before the corrected word, or past the expected caret, still ends it.
- Tracking ends a presentation only after a caret/text mismatch lasts 0.8 s, and keeps the last position when a geometry lookup fails transiently. Keyboard navigation and clicks still end it immediately through the session.
- Caret reconciliation during typing no longer hides visible feedback.
- Undo and Tab still validate the exact text and caret before writing.
- The `overlay` log category records `Shown at word|caret|editor/window`, `Not shown`, and `Ended: caret moved|text changed`, without document text.

### Blue word box in every app; install relaunch (October 15, follow-up 2)

- Install now runs `open` on the installed bundle. After one update macOS did not relaunch the selected input method, so nothing was corrected until Cappy was started by hand.
- The highlight survives brief stale reads: it is dropped only after a 1 s insertion grace without a match, or a mismatch lasting 0.8 s. It is never drawn while the text differs.
- New last-resort word box: when no source gives word geometry but a caret is known (IMK, or Accessibility markers), Cappy measures the word and the text typed after it. It uses the host's reported font, or the system font sized from the caret's line height (height / 1.3, 10–32 pt), and ends the box just before the trailing text on the caret's line. A line break in between means no estimate. This is approximate by design.
- The `highlight` log category records which source answered: `accessibility`, `input method range`, `input method endpoints`, `input method unreported range`, `estimated from caret` or `none`.
- The box no longer drifts right while typing. It was re-estimated every 0.12 s as caret minus trailing width, so any font-size error grew with each key. `WordPlacements` now keeps the first placement for a word while the caret stays on the same line (within 2 pt, 5 s). Exact geometry replaces an estimate once and is then held too, so alternating sources no longer make it jump.
- Estimated boxes could still start a character or so off (seen on a capitalisation fix in Claude) and were then held in the wrong place. `WordBoxPlacer` now waits until the caret sample (selection, caret x, trailing width) has been unchanged for 80 ms before placing, because Electron reports the caret late. It also calibrates each host's text scale from caret travel: actual caret movement ÷ measured width of the text typed since placement, once that is ≥ 16 pt, clamped 0.6–1.6. This corrects the current box and seeds the host's next estimate. The highlight log reports `estimate settling` while waiting.
- Still a letter off in Claude in some cases. Logs showed estimates restarting every poll: IMK and Accessibility carets differ by a few points vertically, which failed the 2 pt same-line test. Same line is now within max(4 pt, half the caret height). `WordBoxPlacer` now fits `caretX = wordEnd + scale × trailingWidth` across all settled readings (settle 0.15 s). It uses the median edge under the known scale until the trailing text spans 16 pt, and drops one disagreeing reading by leave-one-out. The log records `Estimate fit: N readings, scale S`.
- Fast typing in Claude still put boxes a letter right. Claude's learned scale is about 1.2, so the fit itself was right. During fast typing, though, Electron reported the caret and the text from different moments for longer than the 0.15 s settle time. Readings now also require 0.3 s since the last key (`WordBoxPlacer.typingPause`), so the box appears at the next pause in typing. Learned scales persist in the `WordBoxScales` default, so a restart after an update no longer starts each host 20% too narrow.
- Phrase corrections drew one box over the whole phrase, too narrow because the app had no learned scale (scale 1.0). Now:
  - The highlight covers only the whole words that differ (`CorrectionOverlayAnchor.changedWords`): “I have multple” → “I have multiple” highlights “multiple”. Pure deletions or splits keep the full range.
  - A host without a learned scale whose font had to be guessed starts from the mean of other hosts' scales, or 1.25 when none are known. Hosts that report fonts start at 1.0.
- Highlights now carry iOS-style selection handles: a 2 pt blue line at each end of the box, an 8.5 pt dot (was 7) above the start and one below the end. Both correction and suggestion highlights use them. The highlight window grows by `handleMargin` around the unchanged box so the dots are not clipped, and the window still ignores the mouse. A render test checks the dots, lines and the readable middle.
- Boxes in Claude were about half width: two stale readings had fitted a slope at the 0.6 clamp, which was learned and persisted. Fitted scales must now be within 0.85–1.6 and agree with their readings within 3 pt. They are learned only from three or more readings and blended with the previous value. Stored implausible scales are ignored on load. A guessed-font baseline applies only to the current placement and is never stored as learned. The Accessibility backoff after a structural failure is now 0.6 s (was 3 s), so exact bounds that arrive a moment late replace the estimate.
- The highlight fade used to step alpha from the 0.12 s timer, about 8 fps. It now fades in over 0.15 s and out over the last 0.35 s using Core Animation. Reduce Motion skips both.
- The highlight felt delayed: 0.25–0.7 s after the capsule in Claude, from the 0.3 s typing pause, 0.15 s settle, 0.12 s polling and 0.15 s fade-in. Highlights now poll every 30 ms until first visible, then every 0.12 s. The gates are 0.2 s pause and 0.1 s settle, the fade-in is 0.08 s, and refined positions slide over 0.12 s instead of jumping. Hosts with exact geometry are limited only by polling and the fade.

### Typing lag, moving boxes, one box at a time (October 15, follow-up 3)

- Lag: 30 ms polling queried the host (IMK range rects, caret, text, Accessibility) while the user typed. Chromium answers uncached `firstRectForCharacterRange` with a synchronous round trip to the page, so these queries stalled typing in Claude itself. Now no highlight or capsule tracking queries are made within 0.15 s of a key (`CorrectedWordHighlights.typingQuiet`). `IMKRangeSupport` stops asking a host for IMK range geometry after 3 unanswered attempts with none answered.
- Moving: a highlight's frame is fixed once placed. The capsule moves at most once, from caret/editor placement to the word, then stays. Readings still feed `WordBoxPlacer` during pauses so the host's scale keeps being learned for the next box.
- One box at a time: a new correction fades out the previous highlight (0.12 s), and any undo (button, ⌃⌥Z, Backspace, ⌘Z) removes it through `CorrectionSession.onUndo`.

### Exact bounds only, fetched in the background (October 15, rebuild)

The caret-based estimate is removed (`WordBoxPlacer`, font measurement, scale fitting and persistence, `WordBoxScales` no longer read). It was wrong whenever the guessed font or a lagging caret reading was off. The blue box now appears only with exact bounds:

- IMK range bounds, synchronously, only from hosts that answer them (`IMKRangeSupport`).
- Otherwise `AccessibleWordLocator` runs on a background queue. It finds the corrected word by content near the caret (`AccessibleWordMatch`: whole words, nearest to the expected distance, ±6 units), not by IMK offsets. It uses text markers walked back from the editor's caret (Chromium/Electron/WebKit), then `AXValue` plus `AXBoundsForRange` (native). Whole-editor and empty rectangles are rejected.
- It retries every 50 ms for up to 2 s, waiting for an 80 ms gap in typing before each attempt, so Accessibility calls never compete with keystrokes on the host's main thread. Results apply on the main thread unless cancelled by a newer correction, undo or hide.
- No exact bounds means no box. The capsule still appears at the caret/editor/window and moves once to the word when bounds arrive. Suggestion highlights use the same path.
- Chrome web pages (probed: contenteditable on a local page) return only the editor's frame for marker ranges and reject `AXEnhancedUserInterface` (-25208), so they may show no box. Logs showed Electron apps (Claude, Discord, Codex) returning exact marker bounds.
- `--diagnose-accessibility` accepts `CAPPY_DIAGNOSE_WORD` and `CAPPY_DIAGNOSE_TRAILING` to report exact-bounds lookup results.
- In Claude, exact bounds now arrive in 3–406 ms. Chrome lookups gave up after about 30 attempts. Chromium builds the inline text boxes that word bounds come from only when a client reads text elements' children, so on attempts 2 and 13 the locator reads up to 300 elements of the editor's subtree (`requestTextLayout`). This is unverified and untested by request. Gave-up logs now say why: `no focused editor`, `word not in text near caret`, or `word found, no text bounds`.
