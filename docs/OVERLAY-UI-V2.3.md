# Archived v2.3 overlay contract

Last maintained: 2026-09-07

Historical only: superseded in the unreleased integrated-header Debug preview.
See `OVERLAY-UI.md` for the current source contract.

This document records the former interaction and layout contract for Copi's macOS 26
command overlay. It describes implemented behavior; future ideas must be labelled
**not implemented** until built and validated.

## Design baseline

- Use current macOS 26 SwiftUI/AppKit materials and Liquid Glass APIs. Do not
  substitute older-looking custom controls for an available current native surface.
- Appearance is application-wide. **Auto** follows the current macOS system appearance;
  explicit **Light** and **Dark** choices apply to every Copi window. Materials, labels,
  symbols, chips and selection states remain legible in both appearances.
- The window is structurally an AppKit `NSSplitViewController` with
  `NSSplitViewItem(sidebarWithViewController:)`, pane-local SwiftUI hosting
  controllers and a real `NSToolbar`. The toolbar, navigation and result list belong
  to that one window; do not reproduce the relationship with a custom `HStack`, a
  hybrid root `NavigationSplitView`, detached materials or manual width animation.
- Minimize pointer travel, clicks and permanent controls.
- Keep the result pane compact. Revealing navigation keeps the leading window edge,
  native Close control and Types/Favorites pill stationary; AppKit opens the sidebar
  beneath that header and moves the search/result detail column right. AppKit is the
  sole owner of the split item's width curve. During that native transition the
  window delegate preserves only the starting x-coordinate; it never runs a second
  width animation. Copi must not preserve the detail pane's screen position.
- The overlay retains one compact seven-row opening height for the whole session.
  Sidebar visibility, card selection and search filtering do not resize it vertically.
- Results are a flat list on the window surface, not a nested rounded card. Seven
  contiguous divider-free 36-point rows use 8-point horizontal and 12-point vertical
  outer spacing while retaining Search alignment.
- Preserve Copi's existing result rows and numbered multi-selection chips.

## Window and toolbar

- Every new overlay session starts at All Clipboard with the sidebar closed.
- The overlay is a nonactivating titled panel with only the native Close control;
  minimize and zoom are hidden.
- Initial placement uses the final ordered AppKit frame after unified-toolbar chrome
  exists, then clamps that complete frame to the cursor screen's `visibleFrame`.
  Clamping the smaller construction-time content rectangle is forbidden because it
  leaves the toolbar-height strip offscreen at the bottom edge.
- The top row contains one two-segment `[Types | Favorites]` Liquid Glass pill,
  one fixed native `NSSearchField` toolbar view, one `.sidebarTrackingSeparator`, and one Copi
  menu. The controls are native AppKit toolbar items; Copi does not draw a replacement
  toolbar shell.
- The two icon segments use the regular compact control size with 32-point segments.
  When navigation opens, the tracking separator and native spacer align Search with
  the Results list rather than with the outer window or sidebar cards.
- The Copi menu is one 36-point native macOS 26 `NSButton` using `.glass` bezel style.
  It retains the original `doc.on.clipboard` symbol at 13 points and matches the
  measured scale of Calculator's toolbar buttons. It has no wrapping glass view,
  duplicate toolbar-item image, disclosure arrow or nested selection ring and opens a
  native menu containing Always On Top, Settings and Quit.
- The search icon calls AppKit's native window-drag gesture and the native title-bar
  remains a drag surface. Content background does not move the window, so sidebar
  reorder and scroll gestures are never intercepted. The text field keeps native caret movement,
  selection and input-method behavior. Its system-blue focus ring is suppressed; a
  restrained neutral glass edge and the caret indicate Search ownership.
- Closing a pinned overlay disables Always On Top and closes the panel.

## Sidebar

- Types and Favorites share the native leading column supplied by the sidebar
  `NSSplitViewItem`, containing a two-column colored clear-glass card grid that
  follows Reminders. It remains inside the split window and owns the full-height
  titlebar region while visible.
- All Clipboard and All Favorites are the first cards in their respective panels.
- Cards show an icon, name and item count in compact 52-point tiles. The grid uses
  symmetrical 8-point outer and inter-column spacing so both columns consume the
  available width evenly. Cards have no drawn border: a subtle top-left-to-bottom-right
  tint gradient and top sheen provide Reminders-style depth. Selection strengthens
  that gradient and its tint-matched shadow; it does not introduce a system-blue ring.
  Hover is visual feedback only and never changes or loads results.
- Favorites has a compact icon-only Add control fixed to the bottom trailing edge.
  It presents a native popover with category name, a Reminders-style preset color
  palette and a grouped SF Symbol picker. The palette stays inside the popover rather
  than opening `NSColorPanel`, which is unreliable from a nonactivating command panel.
  Creating a category selects it immediately; blank names are rejected.
- Right-clicking a user category offers New Favorite, Edit Category and Delete Category.
  New Favorite opens a compact editor already bound to that category, accepts an
  optional name, original multiline content and Mask choice, and detects its content
  type automatically. The name is the display title when supplied; otherwise content
  is the title fallback. It persists only when Add is pressed. Edit opens the same
  prefilled name/color/icon editor. Its Shortcut picker includes **No Shortcut**, which
  clears the category's assignment without affecting its Favorites. Delete always shows a confirmation whose destructive
  label includes the number of Favorites that will also be removed.
- User-created Favorite cards and Content Type cards are reorderable by dragging the
  whole card. Once a drag engages, the pointer becomes a closed hand while the card keeps
  its normal size, position treatment and shadow. Crossing another card updates the
  row-major arrangement immediately and animates neighboring cards into place; releasing
  inside the grid persists that final order once, while releasing outside restores the
  pre-drag order. All Favorites and All Clipboard stay pinned first. Empty Content Types
  are hidden without losing their slots in the complete saved order. Type-filtered
  results always keep normal clipboard recency order; there is no ranking-mode setting.
- The grid is vertically scrollable. Window-level wheel handling must forward the
  native event when the pointer is inside the sidebar's local bounds; the result pane
  keeps its existing result paging when the pointer is outside those bounds.
- Results paging uses one screen-coordinate ownership handler from both local and global
  wheel monitors. Pointer travel in the nonactivating panel must not stop paging when the
  active paste destination continues to own the event stream; Sidebar, Preview and
  diagnostics remain excluded from that result handler.
- Card activation is click/keyboard-driven and immediate. Hovering a card gives its
  number priority in the capsule's trailing shortcut badge and gives its whole sidebar
  keyboard ownership without loading the filter or replacing the capsule text. Keyboard
  arrows activate each addressed card while retaining Sidebar ownership; click, Return,
  a plain number or Space hands ownership to Results.
- Keyboard ownership is shown at area level: Search keeps a fixed native field and capsule
  treatment even after its editor resigns, while the active Sidebar or Results surface receives
  one restrained rounded adaptive glass edge without a pane-wide color wash. The Sidebar edge follows the
  complete full-height pane, including its toolbar controls, padding, empty space and Add control,
  rather than outlining only the card grid. The Results edge begins beneath the Search capsule,
  separated from the sidebar divider, and encloses the remaining Results surface. Individual cards
  and rows do not gain keyboard-focus borders; their current number remains available in
  the capsule. During native Sidebar expansion/collapse, derive the edge from the currently visible
  pane width so it slides and fades with the pane. On close, suppress the incoming Results edge until
  the Sidebar edge has receded, then fade it in after layout settles; ownership edges must not coexist
  or snap between endpoint frames. Preserve expansion in the same native animation group as pane
  width. Do not use an independent opacity context or a fixed-duration timer to declare collapse
  complete; hand Results ownership over only from native completion and a presented-frame settle.
- Pointer hover keeps the restrained card lift without activating a filter. A keyboard-arrow target
  activates immediately and therefore takes the stronger selected tint, while idle cards remain
  deliberately quieter. The pane edge continues to communicate keyboard ownership independently.
- Hiding the sidebar clears the selected type/category and returns scope and results
  to All Clipboard. Existing query text is retained and rerun against All Clipboard.
- Width is resizable and persisted, clamped to 220–290 points; open state is not
  persisted. The default width is 228 points.
- The native sidebar animation normally holds the leading edge stationary. If its
  expanded width would cross the active screen's visible trailing edge, the outer
  window shifts left continuously by only the overflow amount; it remains clamped at
  the visible leading edge as well.

## Search, results and Preview

- There is exactly one search field. It searches within the selected card's result
  set and communicates that scope through its placeholder.
- No result-pane title, breadcrumb, duplicate filter row or duplicate search field
  appears when a card is selected.
- Suggested rows use the normal row surface and text with no glow, wash or suggestion-
  specific animation. Only the glossy cyan–green–purple numbered chip identifies a
  suggestion; selected-chip styling still takes precedence.
- Opening Results or selecting a Favorite category or Content Type starts the first
  row immediately and staggers only the later rows in the top-to-bottom reveal. There
  is no common blank delay before an already-materialized result set appears. Typing
  in Search updates directly and must not replay the reveal for every character.
- Command-modified paste shortcuts and numbered-chip ordered multi-selection remain
  unchanged. Plain digits are focus-local: Search types them, a sidebar addresses its
  first nine stable row-major cards, and Results addresses its seven visible rows.
- A highlighted Link, Email or File Path replaces the Search capsule placeholder with
  **Open in Browser**, **Open in Mail** or **Open in Finder** and shows `⌘ ↩` at the trailing
  edge. Command-Return invokes that action from either Results or Preview using the entry's
  existing content classification. It does not write to the pasteboard or enter the paste-
  dispatch learning path. Capsule state and its numbered shortcut follow highlighted-entry changes from hover, keyboard
  navigation and paging. A transient overlay closes after invocation; a pinned overlay remains.
- Result-row hover changes model selection in the same pointer event turn and has no
  debounce. A single transform-only backdrop glides between visible slots using the
  historical 0.26-response, 0.82-damping spring. Entry rows are outside that animation,
  so wheel paging cannot animate or displace list content. Its subtle blue-glass fill never
  forces a white label; semantic primary text retains the same Light/Dark appearance as
  neighboring rows. The search capsule displays
  the hovered row's numbered shortcut with the original 17-point rounded keycap metrics,
  shifted five points inward; while Shift is held,
  its leading search glyph is the native Shift symbol rather than a magnifying glass.
  The capsule is also the sidebar shortcut surface: hovering an assigned Favorite category
  or Content Type card shows `number / ⌘ letter`; All cards and unassigned Type cards retain
  their existing indicators. Arrow focus shows the focused card's number, and choosing that card replaces
  it with the focused Result number. Results with a Quick Action show both the plain row
  number and `⌘ ↩`, separated as `number / ⌘ ↩`; while Search owns typing, the existing
  `⌘ number` cue remains truthful. Hovering the toolbar icons temporarily changes the
  capsule text to **Open Content Types** or **Open Favorites**.
- The native Search capsule has a restrained appearance-adaptive drop shadow. It must remain
  visible against the Light toolbar material without becoming heavier than the Copi menu
  button's elevation. Its Light-mode interior must match the surrounding toolbar rather than
  inheriting AppKit's darker default field gray. Retain the native bezeled text/icon metrics
  and editable semantics, suppress only the cell's system bezel drawing, and let Copi's layer
  provide the opaque-white Light fill.
- The bottom-trailing overflow count is inset from the Result row's Favorite-star hit target; neither
  its text nor its padding may overlap or visually crowd the star.
- Opening Preview makes its panel the keyboard surface and freezes result-row hover.
  Mouse movement over Results cannot change the displayed entry or transfer key focus
  back to Results. Preview is display-only: Up/Down always navigates entries, Space
  toggles Preview, and Escape closes Preview before acting on the overlay. Closing it
  restores the main panel's keyboard surface.
- A row's Content Type context-menu action updates its stored record and the exact
  visible model snapshot as one operation. Counts, active type scope and non-empty
  search results are reconciled immediately after either assignment or Automatic.
- A stored clipboard-history row offers Delete from History. Deletion removes that
  record and its encrypted payload without modifying the system pasteboard.
- Window-level hover is converted into the flipped detail hosting view and offset by
  its unified-toolbar safe area. Moving down the visible list must always move the
  highlighted row down; this mapping is covered by a top-origin geometry regression.
- Leading Space toggles the separate centered Finder-style Preview. Once search typing
  begins, Space remains text input only while Search still owns the keyboard. Hovering or
  arrowing to Results transfers ownership, after which Space opens Preview even for a
  non-empty query. The empty native Search field remains the shortcut surface even while
  its field editor is first responder; do not require the nonactivating panel to report
  itself key before consuming that leading Space.
- While Favorites or Content Types owns the keyboard, Space is consumed as a handoff to
  Results. It never inserts a leading space into the dormant native Search editor.
- An open Preview follows result selection and uses reversible content-aware sizing. It is
  ordered as a peer panel, never an AppKit child of the main overlay, so each window's
  explicit drag surface moves only that window.
- An HTTP(S) Link uses a larger, read-only WebKit surface that begins loading only after
  the user deliberately opens Preview. The Favorite/clipboard name and URL remain visible
  above the live page. It uses a non-persistent website data store,
  requires user action for media playback, rejects pop-ups, link activation and non-web
  navigation, and shows a bounded failure state. Loading the page still sends ordinary
  network requests to the destination and its subresources. Other URL schemes and URLs
  containing credentials remain plain text rather than entering the web surface.
- A Favorite's optional name is independent of its content. It is the visible title in
  Results and Preview; content is the fallback when no name exists. Preview keeps
  Password and explicitly masked Favorite values masked until a deliberate click, then
  reveals them without becoming editable. A single Favorite's context menu offers
  **Edit Favorite…**, using the same prefilled name/content/mask form as creation; Save
  refreshes Results and Preview immediately. New/Edit Favorite is an explicit modal
  interaction inside the transient overlay: its native popover owns Space, arrows,
  pointer movement and dismissal until Save, Cancel or native outside dismissal closes it.
  Result hover and the overlay's global pointer-dismiss route remain suspended meanwhile.
  New/Edit Category uses the same explicit editor ownership.
- The full result-row width participates in hover selection. Assigned Favorites show a dimmed,
  filled category-colored star at rest and restore its vivid category color on direct hover;
  unassigned rows reveal a filled star only while the pointer
  is over that trailing target. Unassigned stars remain neutral rather than borrowing the default
  Favorite green. The target uses a hand pointer. Clicking it opens a native menu:
  an unsaved item is assigned to the chosen category, while an existing Favorite can be moved
  to exactly one category or removed. The marker follows equivalent content identity when
  deduplication displays a clipboard-history representation.
- The Favorites-sidebar `+` first offers **New Favorite…** or **New Category…**. New Favorite
  opens the glass Favorite editor immediately; its Category dropdown defaults to the selected
  category, or the first category from All Favorites, and can be changed before Add is pressed.
  The plain `+` sits on a soft, non-interactive circular glass surface and uses a hand
  pointer. The glass is visual only so it cannot consume the native Menu click.
- The empty All Clipboard list remains clipboard-first and may contain only Favorites
  admitted by suggestion ranking. Once the user types in the default search, its corpus is
  clipboard history plus every Favorite, and matching covers both optional names and content.
  All Favorites and selected Favorite-category searches retain their Favorite boundary;
  Content Type searches remain limited to clipboard history of the selected type.
- Equivalent history/Favorite payloads share the strongest Password/Mask presentation
  policy and safe label in overlay snapshots. Deduplication must never choose a weaker,
  unmasked representation of content known to be protected elsewhere.

## Keyboard path

- Tab moves keyboard focus in the order Search capsule → Favorites → Content Types →
  Results, and Shift-Tab reverses it. Landing on Favorites or Content Types opens that
  sidebar panel. Tab never closes the sidebar, so a card chosen on the way to Results
  keeps its scope; Escape, the toolbar pill and the horizontal arrows still close it.
  Hiding the sidebar returns focus to Results.
- Only the Search capsule holds the native field editor. Handing focus to a sidebar
  panel or Results resigns it, so the caret disappears and typed characters cannot
  land in an unwatched field. Plain digits remain local shortcuts and Results owns Space;
  any other printable character unambiguously resumes Search at the end of its existing
  query. Tab, Up from Result 1, and a direct Search click also restore text input. Active
  IME composition is never resigned merely because the pointer crossed another region.
- The focused region is visible: Search shows its caret and a subtle neutral silver/gray glass
  edge, the complete full-height sidebar gains the matching rounded edge, and Results gains the matching
  content edge aligned beneath Search rather than against the sidebar divider. Individual
  card and row highlights do not acquire an additional keyboard border.
- With focus in a sidebar panel, Up/Down move one two-column row. Left/Right first move
  between the paired cards in that row and immediately activate the addressed filter without
  leaving the sidebar, then cross at the pane edge:
  Favorite 1 Left opens Content Types at Type 1, the right edge of Content Types enters
  Favorites at Favorite 1, and the right edge of Favorites returns to Results. The path
  does not wrap or clamp the user inside a pane. The capsule follows the active card target;
  Return or Space hands focus to Results.
- Plain `1`–`9` in a sidebar activates that stable row-major card (`1` is All Favorites
  or All Clipboard), scrolls it into view if necessary and hands focus to Results. Plain
  `1`–`7` in Results invokes that visible row. Missing positions and `0` are consumed.
- Actual pointer hover over Search, a sidebar card or a Result transfers keyboard ownership
  to that complete area and displays its pane-level edge. Sidebar hover changes only the
  capsule's trailing card number and does not activate the filter.
- `⌘F` opens Favorites, `⌘T` opens Content Types, and repeating the shortcut for the
  already-open panel closes it. `⌘0` returns to All Clipboard,
  `⌘D` opens the highlighted row's Favorite-category menu and `⇧⌘P` toggles Always On Top.
  Favorite categories and Content Types share one optional Command-letter namespace;
  D, F and T are reserved for overlay actions. New/Edit Category use the same optional letter picker,
  while a Type card's context menu opens a shortcut-only editor. Hovering the corresponding toolbar
  segments, row star or All Clipboard card shows the shortcut in the existing Search-capsule
  keycaps. An event tap exists only for the lifetime of the open overlay and consumes an exact
  assigned letter while a transient overlay's frozen paste destination remains frontmost, even
  though Copi's nonactivating panel is not key. If the user switches to a different app, the event
  passes through unchanged. A pinned overlay can outlive destination changes and therefore consumes
  assigned letters only while the main Copi panel or Preview is key. Applying an assigned
  category or Content Type shortcut leaves its sidebar visible but hands keyboard ownership
  directly to Results.
  Search has no dedicated shortcut; unmodified printable input resumes it.
- With focus in Search or Results and an empty search field, either horizontal
  arrow from closed Results opens Favorites at Favorite 1.
- Within either two-column grid, arrows continue moving the internal card target until
  they reach a pane boundary; only the far-left boundary of Content Types stops.
- The path never wraps. With query text present, Left/Right remain native caret keys.
- The first Down from Search focuses Result 1 rather than advancing to Result 2. Further
  Down/Up presses navigate Results, and Up from the first unscrolled Result returns to
  Search with its insertion point at the end. Escape closes Preview, clears multi-selection or query,
  hides the sidebar and resets to All Clipboard, then closes the transient overlay.
- Command-Return runs the highlighted entry's available Quick Action; Return retains its
  paste behavior.
- Result rows can be reordered only while one specific Favorite category is selected and
  Search is empty. All Favorites remains read-only and flattens category order first, then
  each category's stored item order. Pressing a draggable row immediately changes the normal arrow
  to a closed hand; release or cancellation explicitly restores it. Panel-level pointer tracking
  evaluates both movement and the final mouse-up row, so a fast/coalesced drag does not depend on
  SwiftUI receiving a long gesture stream. The blue-glass row highlight follows the dragged
  Favorite's stable identity as its index changes. Preview order changes are published immediately.
- Precise trackpad paging emits at most one row step per event, discards accelerated excess
  and stale opposite-direction accumulation, and re-resolves the row under a stationary
  pointer after the visible seven-row window changes.
