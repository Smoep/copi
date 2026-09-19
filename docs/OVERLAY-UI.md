# Command overlay UI contract

Last maintained: 2026-09-19

Status: the latest compact-header changes are in the **Debug preview**. Installed
local testing build 2.3.0 (13) contains the preceding integrated-header design; the
published download remains 2.3.0 (12). The prior sidebar design is recorded in
[the archived v2.3 contract](OVERLAY-UI-V2.3.md). See PROJECT_STATUS.md for validation
and the exact testing artifact. This build has not been published.

## Single integrated header

- One 520-point-wide command window contains the native toolbar and up to seven
  Results. The frame varies between 520 × 192 and 520 × 300 points: a four-row
  minimum footprint preserves balanced proportions for short/empty lists. The
  top edge and first row remain fixed while the bottom edge eases over 160 ms.
  Header reveal itself never changes window width or row positions.
- The header has one 512-point custom AppKit view inset 4 points from the window:
  a Favorites star at the left with a 32-point hit target,
  a genuine native search field and an inward-revealing filter strip. The redundant
  Content Types edge button is removed; the right approach zone opens Types.
  No nested Search capsule, separate glass icon bubbles, sidebar or Copi menu is drawn.
  The native Close, minimize and zoom controls are absent. The global overlay
  shortcut opens/reveals the overlay; Escape resets active filtering first, then dismisses the unfiltered overlay.
- Use neutral native materials with slight behind-window translucency: `.headerView`
  for the header and `.popover` beneath Results. A neutral 0.55 veil of the system unemphasized-selection color lifts the header
  above the 0.35 window-background veil beneath Results. Material contrast provides
  separation without a divider or enclosing border. There is no custom color tint or gradient.
  Reduce Transparency retains opaque veils. The user selected option C, Soft Material.
  SwiftUI supplies the icon strip and
  existing category/content-type editors; AppKit owns the header geometry, native
  search editor, clipping, scrolling and window. Public macOS 26 APIs run on macOS 27;
  no SDK upgrade or private API is required for this header.
- A toolbar placeholder reserves the native 40-point header height; the actual header
  extends beyond that container to avoid native item gutters while retaining toolbar
  event routing. Edge buttons dispatch native actions before gutter hit-testing. The filter hosting
  controller ignores titlebar safe areas so icons remain centered and fully clickable.
- Dragging the empty center of Search moves the overlay; a normal click focuses
  Search. Entered text retains native drag selection. The magnifier remains a drag grip.
- Header controls are 28 points tall in the 40-point compact native toolbar. On open,
  clamp the complete measured frame to the active display’s visible area, then move
  the pointer to the actual Search center. Result expansion is clamped again if needed.
- Native Search retains text selection, editing, input methods and clear button.
  Its own bezel/background/shadow and focus ring are suppressed. Its caret communicates
  typing ownership. The existing shortcut badge and Shift symbol remain. No enclosing Search/Results
  ownership outline is shown; the caret and highlighted row communicate focus.
- Search stays at least 100 points wide by construction (100 points with eleven icons
  and overflow arrows in the 512-point header view). Below 160 points it hides the shortcut badge; clicking restores the full field.
  Prompts name only the scope (“All items…”, “Code…”, “Work…”), without “Search”.
  Long labels truncate, with
  each icon's full name/count available in its tooltip and Accessibility label.

## Directional hover and filters

- On opening, no filter strip is visible. All Clipboard contains the verified current
  clipboard first, followed by the existing suggestion/list assembly. Ranking is unchanged.
- Move left/right into the outer 108 points of the header to reveal Favorites/Types
  inward, before reaching the edge. Direction accumulates across small mouse events (including subpixel steps) rather
  than requiring any single event to exceed the movement threshold. It is evaluated within the header,
  excluding exposed filter targets; vertical movement from Results does not trigger
  a collection switch. The Favorites star also remains a direct trigger. The compact Search remnant in
  Types is protected from approach switching, so it remains reachable for clicking. Only one strip is revealed at a time.
  These hover transitions are custom behavior, not standard NSSegmentedControl behavior.
- Hover an icon to apply its filter immediately, update the scoped Search placeholder
  and refresh Results. There is no dwell, hover lock or repeated list entrance animation.
  Repeated movement inside the same target does not reactivate it.
- Crossing into Results preserves both the filter and the revealed strip. Crossing Search
  does not transfer keyboard focus or rearrange the strip; clicking, typing or explicit
  keyboard navigation restores Search ownership. Clicking Search or
  typing restores full search width while retaining scope and query. A left/right approach
  made during Search restoration is retained and applied once the animated frames settle;
  moving away cancels that pending approach. Approaching either
  edge reveals filters again. No query text is discarded by presentation changes.
- The star click selects All Favorites. The first icon inside
  either strip also selects that collection's All scope. Command-0 provides reset. Double-clicking an empty Search resets category/type filters;
  double-clicking entered text retains native selection. Escape clears active filters/query
  and restores All items; the next Escape dismisses. Preview consumes its own Escape first.
- Up to eleven 32-point icon targets fit at once in the 512-point header. Longer lists use a clipped horizontal native
  scroll view with previous/next arrows. Wheel/trackpad movement over the strip scrolls
  filters, never Results. Keyboard targeting scrolls only enough to reveal its icon.
  Order remains manually persisted, never prediction-driven. Hidden types keep their slots.
  Drag autoscroll at overflow edges is **not implemented**; bring reorder targets into view
  with the arrows/wheel first.
- Header and Result hit-testing use the shared local/global pointer path because the
  nonactivating overlay can leave the paste destination frontmost. Hover cannot navigate
  while a menu/editor, Preview, a drag or an IME composition owns input.
- Reveal and Search restoration interpolate actual native child frames over 200 ms
  with cubic ease-out and a strip fade. No overshoot or outer-window animation is used.
  Reduce Motion applies the final geometry immediately. Moving filter targets do not
  activate during the transition; pointer-triggered reveals evaluate the settled target
  on completion. Keyboard-triggered reveals retain keyboard ownership and scroll their
  final target into view. The outer width and first Result position remain fixed; changes in match count
  can resize the bottom edge within the bounded Results height.

## Editing and reordering

- Category and type controls retain stable content identities and the existing
  live drag-to-reorder gestures. A drop outside cancels; persistence happens once
  on a successful release. All is fixed first. Fixture reordering never writes preferences.
- Category context menus retain New Favorite, Edit Category and Delete Category.
  Type context menus retain Edit Shortcut. The header context menu offers
  New Favorite and Add Category, without an inline plus button.
- Favorite star assignment, result context menus, explicit Favorite editing and
  Favorite-result reordering retain their existing behavior. Editors keep exclusive
  pointer/keyboard ownership until dismissal; ordinary Search is not a modal editor.
- Settings, Always On Top and Quit remain in the menu-bar menu. The header has no
  three-dot/app menu.

## Keyboard and focus

- Search initially owns input. Hovering a filter or Result transfers logical input
  ownership to that region without leaving a hidden native text editor active.
- Empty Search/Results Left opens Favorites; Right opens Types. Within a filter strip,
  Left/Right selects adjacent icons. At Favorites' left boundary return to Search;
  at its right boundary enter Types. Types' left boundary enters Favorites and its
  right boundary enters Results. There is no wrap.
- Up from a filter returns to Search; Down, Return or Space enters Results. Down from
  Search enters row 1; Up from row 1 returns to Search. Result Up/Down moves the selection.
- Tab/Shift-Tab retain Search/Favorites/Types/Results region navigation. Command-F/T
  toggle their collection; Command-0 resets to All Clipboard and focuses Results.
- Plain digits type in Search, select addressed filters in a strip, or invoke Results.
  Command-1…7 pastes visible rows. Assigned category/type letters retain their existing
  command shortcuts and destination/key-window restrictions. Command-D opens the
  highlighted result's Favorite menu. Shift-Command-P toggles Always On Top.
- Typing resumes Search at the existing query's end. Search retains normal caret
  movement for nonempty queries. Never interrupt marked-text composition on hover.
- Escape closes Preview first when visible. In the main overlay it clears an active
  query/filter/strip and restores All items; when already reset it dismisses, even
  with Always On Top enabled.
  Native editors and menus retain their own Escape handling. An outside click also
  explicitly dismisses, through both local and global event paths; clicks inside
  Preview or tracked menus/editors do not tear down the main window. Passive
  deactivation and post-paste persistence still respect Always On Top.

## Results, Preview and paste

- Up to seven contiguous 36-point rows keep 8-point internal gutters and 4-point outer padding on all sides.
  They remain flat on the window surface with no nested result card or row dividers.
  A transform-only hover highlight keeps its existing spring; rows do not move or
  replay entrances as filters change. First and last highlights remain inside the window margins. Row hit-testing derives
  from the visible window top edge, not a hosting view safe-area conversion that can
  shift during resize. Text previews allow up to 256 characters before native
  width-based truncation, avoiding premature truncation of narrow text.
- Suggestions keep normal text and use only the numbered-chip cue. Number-chip ordered
  multi-selection remains separate from clicking the row to paste. Semantic label color
  stays legible in both Light and Dark appearance. The overflow count reserves star space.
- Preview remains a separate independently movable, display-only panel, opened by a
  leading Space or Results-owned Space. It opens on the roomier side of the overlay
  with a 12-point gap and adapts width to available space. Narrow screens use vertical
  space if neither side can fit a readable panel; overlap is possible only when the
  display cannot fit both. Reopening recalculates placement; a manually moved Preview
  keeps its position during later content resizing. Its Up/Down, Space and Escape routing is unchanged.
  Opening Preview freezes hover changes in the main window. Protected content stays masked.
- Link/Email/File Path Quick Actions still use Command-Return, without touching clipboard
  data or dispatch learning. Scoped Search text remains visible while browsing filters;
  the shortcut badge retains the action accelerator. Preview network and image-loading
  privacy/performance contracts from v2.3 are unchanged.
- Capture, ranking, masking, encrypted storage, multi-selection, destination activation
  and paste dispatch are unchanged. This is a presentation/navigation change.

## Validation contract

Follow AGENTS.md: build with the stable Apple Development identity and a distinct Debug
bundle identifier, capture the exact synthetic window through WindowServer, and drive
real pointer/keyboard input. Check resting/Favorites/Types, overflow, Search/filter/Results
ownership, first/final rows, both appearances, real drag-and-drop and Preview. Off-screen
rendering is diagnostic only. Keep the validated Debug preview open; do not install Release
until the user approves it. The comparison images from the design conversation are mockups,
not pixel-perfect native-rendering specifications.

### Category context menu

Toolbar display-mode customization is disabled; “Icon and Text” is absent. Right-click
the header/Favorites controls for Add Category and New Favorite. When a category is
selected, Edit Category and Delete Category are also available. Category editors retain
name, color, symbol and shortcut controls. Type-icon context menus keep their existing
editing actions. The inline plus button is removed; creation popovers have a stable
invisible anchor in the Favorites strip.

## Five-result opening view (2.4)

The untyped opening/reset view contains at most five results total, including the
pinned current clipboard. Its actual content height is measured at launch, before
measuring native toolbar height. Search, Favorites and individual types remain
unrestricted; All Clipboard in the Types strip exposes the full recency list.
The entries cache includes strip mode so switching between these two All views
cannot reuse the capped snapshot. Five rows produce a 520 × 228 window; browsing
can expand to the existing seven-row maximum. No extra history tail exists in the
opening view.
