# Command overlay UI contract

Last maintained: 2026-09-05

This document is the canonical interaction and layout contract for Copi's macOS 26
command overlay. It describes implemented behavior; future ideas must be labelled
**not implemented** until built and validated.

## Design baseline

- Use current macOS 26 SwiftUI/AppKit materials and Liquid Glass APIs. Do not
  substitute older-looking custom controls for an available current native surface.
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
  contiguous divider-free 36-point rows use 8-point horizontal and 4-point vertical
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
  one native `NSSearchToolbarItem`, one `.sidebarTrackingSeparator`, and one Copi
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
  selection and input-method behavior. Its blue focus ring is suppressed; the caret
  remains the focus indication inside the compact capsule.
- Closing a pinned overlay disables Always On Top and closes the panel.

## Sidebar

- Types and Favorites share the native leading column supplied by the sidebar
  `NSSplitViewItem`, containing a two-column colored clear-glass card grid that
  follows Reminders. It remains inside the split window and owns the full-height
  titlebar region while visible.
- All Clipboard and All Favorites are the first cards in their respective panels.
- Cards show an icon, name and item count in compact 56-point tiles. The grid uses
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
  prefilled name/color/icon editor. Delete always shows a confirmation whose destructive
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
- Card activation is click/keyboard-driven and immediate. After toolbar or card
  activation, focus returns to the native search field on the next AppKit turn so
  typing immediately filters the selected result set.
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
- Paste shortcuts and numbered-chip ordered multi-selection remain unchanged.
- Result-row hover changes model selection in the same pointer event turn and has no
  debounce. A single transform-only backdrop glides between visible slots using the
  historical 0.26-response, 0.82-damping spring. Entry rows are outside that animation,
  so wheel paging cannot animate or displace list content. The search capsule displays
  the hovered row's numbered shortcut with the original 17-point rounded keycap metrics,
  shifted five points inward; while Shift is held,
  its leading search glyph is the native Shift symbol rather than a magnifying glass.
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
  begins, Space remains text input. The empty native Search field remains the shortcut
  surface even while its field editor is first responder; do not require the
  nonactivating panel to report itself key before consuming that leading Space.
- An open Preview follows result selection and uses reversible content-aware sizing.
- An HTTP(S) Link uses a larger, read-only WebKit surface that begins loading only after
  the user deliberately opens Preview. It uses a non-persistent website data store,
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
- Equivalent history/Favorite payloads share the strongest Password/Mask presentation
  policy and safe label in overlay snapshots. Deduplication must never choose a weaker,
  unmasked representation of content known to be protected elsewhere.

## Keyboard path

- With an empty search field, either horizontal arrow from closed Results opens
  Favorites.
- From Favorites, Left opens Types and Right closes the sidebar to Results.
- From Types, Right opens Favorites and Left stops at the spatial boundary.
- The path never wraps. With query text present, Left/Right remain native caret keys.
- Up/Down navigate results. Escape closes Preview, clears multi-selection or query,
  hides the sidebar and resets to All Clipboard, then closes the transient overlay.
