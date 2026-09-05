# Copi project status and handoff

Last maintained: 2026-09-05

This is the canonical starting point for the next conversation. Read
`docs/SUGGESTION-RANKING.md` before changing context learning or ranking. It is the
canonical description of deployed ranking rule v2 and its migration history.

## Product direction

Copi is a fast macOS clipboard manager whose overlay keeps the verified current
clipboard first and learns which history items or Favorites are likely to be used
in the active paste destination. Prediction should be local, deterministic,
privacy-preserving and explainable in the diagnostic hover card and debug logs.

The current product decision is destination-first learning:

- previous paste destinations are the primary prediction signal;
- source-copy context is useful provenance and only a very weak popularity signal;
- more-specific, reliable destination matches receive more weight;
- destination-first ranking rule v2 is implemented, versioned and explainable in
  `docs/SUGGESTION-RANKING.md`.

## Current implemented state

- The project marketing version is 2.2.0 with build number 11. `CHANGELOG.md` is the
  user-facing release history; this handoff remains the engineering source of truth.
- The current clipboard is pinned to result row 1 when the overlay opens.
- The command overlay now uses an AppKit `NSSplitViewController` with a native
  `NSSplitViewItem(sidebarWithViewController:)`, pane-local `NSHostingController`s
  and one native `NSToolbar`. The former custom `HStack`, hybrid SwiftUI
  `NavigationSplitView`, glass shell and parallel window-width animation have been
  removed.
  Only Close is visible; minimize and zoom are hidden. Its toolbar has one
  `[Types | Favorites]` icon pill, one scoped search field and one Copi menu. The
  complete contract is in `docs/OVERLAY-UI.md`.
- The native leading column is closed by default and opens with AppKit's system
  split transition. The window's leading edge and Close control stay in place; the
  sidebar reveals beneath the stationary navigation pill and moves the search/result
  detail column right, matching the interaction requested from Reminders. Colored
  clear-glass cards follow Reminders. Types and
  Favorites share its geometry; All Clipboard/All Favorites appear first. Hover is
  visual only and never loads results. Click and keyboard activation are immediate,
  and the selected card uses a neutral glass outline plus its own tint instead of an
  unrelated system-blue selection ring. Cards are 56 points high in a symmetrical
  two-column grid with 8-point outer and inter-column spacing.
- Favorite categories and Content Types use live row-major reordering: cards do not lift
  or scale, the cursor becomes a closed hand once dragging engages, and neighboring cards
  move while the pointer crosses them. The final arrangement is written once on release;
  a release outside the grid restores the pre-drag order. All Favorites and All Clipboard
  remain fixed first. Type order includes hidden/empty kinds so they return in their saved
  position. Type-filtered results always use clipboard recency; the former “Rank Type
  Lists by Previous Usage” setting and behavior have been removed.
- The native search capsule suppresses its blue focus ring while retaining its caret,
  editing and input-method behavior. Sidebar wheel/trackpad events are routed by
  pointer location into the native scroll view; wheel input over Results retains the
  established seven-row paging behavior. Results wheel input shares one screen-coordinate
  handler across the local and global monitors, so paging continues after pointer travel
  while the non-activating panel leaves the paste destination active.
- Hiding the sidebar clears its selected type/category and returns scoped search and
  results to All Clipboard. Existing query text is rerun against clipboard history and all
  Favorites, matching both Favorite names and content. The empty All list remains governed
  by clipboard-first suggestion assembly. Sidebar
  width persists independently at 220–290 points (228 default),
  while open state never persists. Favorites and Content Type scopes search only within
  their current filter
  and no duplicate title, breadcrumb, filter row or search control is shown. Clicking
  either toolbar segment or a sidebar card restores the native search focus on the
  next AppKit turn, so typing can continue immediately in the newly selected scope.
- Result-row hover selects synchronously in the pointer event turn, with no debounce.
  The seven divider-free 36-point rows form one flat list directly on the window surface
  with 8-point horizontal and 4-point vertical outer spacing; there is
  no nested rounded Results card.
  One transform-only backdrop glides between visible slots using the first command
  panel's 0.26-response, 0.82-damping spring. Entry rows remain outside that animation,
  so wheel paging never inherits its transaction. Existing numbered-chip ordered
  multi-selection is unchanged. The search capsule displays the hovered row's numbered
  shortcut with the historical 17-point rounded keycap metrics, shifted five points
  inward, and replaces its magnifying glass with the native Shift symbol while Shift is held.
  The former Favorite/type hover lock UI and its Settings control are no longer part
  of the active overlay interaction.
- Window-level result hover now converts into the flipped detail hosting view and
  includes its unified-toolbar safe-area inset. Top-to-bottom pointer travel therefore
  selects top-to-bottom rows instead of reflecting the row index vertically.
- Empty-search horizontal navigation is spatial and non-wrapping: either arrow from
  closed Results opens Favorites; Favorites Left opens Types and Right closes;
  Types Right opens Favorites and Left stops. Query text preserves native caret keys.
- Finder-style Preview is hidden by default, toggles with a leading plain Space,
  opens in the active screen's centre, and is strictly display-only. Its key panel
  routes Up/Down to Results, Space toggles Preview, and Escape closes Preview before
  clearing or closing the overlay. Pointer hover remains frozen while it is open. Its header is a
  dedicated drag surface; a user-chosen location is preserved across later dynamic
  content resizes and clamped to the active screen.
- Preview sizing is content-aware and reversible on every entry change. Short text
  can use the 240×220 minimum; paragraphs grow by estimated wrapping; code, tables
  and structured data favor useful line width. Images preserve aspect ratio within
  the visible screen. Programmatic frame animation cannot be mistaken for manual
  live resize; an actual user resize disables auto-sizing only for that session.
- Link, Email and File Path rows expose a direct Quick Action. Their highlighted state names
  **Open in Browser**, **Open in Mail** or **Open in Finder** in the Search capsule beside
  `⌘ ↩`. Command-Return uses the existing classification, does not touch the pasteboard or
  paste-dispatch learning, closes a transient overlay and leaves a pinned overlay open.
- An HTTP(S) Link now loads the actual website in a larger read-only WebKit surface only
  after the user deliberately opens Preview. The surface uses non-persistent website
  storage, blocks clicks, pop-ups, non-web navigation and autoplay, and retains the normal
  loading/failure presentation. Non-web and credential-bearing URLs never enter WebKit.
  Website loads still make normal observable network requests to the destination and its
  subresources; merely highlighting a Link does not.
- Image display no longer performs encrypted file I/O or lazy full-resolution
  decoding from SwiftUI body evaluation. Preview images (2200-pixel bound) and row
  thumbnails (80-pixel bound) use cancellable background Image I/O preparation,
  eager decode, and bounded caches. A stable placeholder appears while cold work
  completes, and full-resolution encrypted data remains reserved for paste.
- Suggested results use the normal row surface and white text with no row animation,
  glow or surrounding wash. A borderless glossy cyan–green–purple numbered chip is
  the sole AI cue, unless selection restores standard selected-chip styling. Result
  rows and numbered-chip hit targets remain unchanged.
- The status menu exposes a persistent checked “Always On Top” item immediately
  above “Show Copi Settings.” It opens and pins the command overlay—not Settings—
  at its existing high window level. A pinned overlay survives outside movement,
  outside clicks, root Escape, hotkey presses and completed pastes; it reopens on
  launch, refreshes for new clipboard captures, and resolves a fresh active paste
  destination plus learning session before every paste. Turning the option off
  closes it and restores normal transient behavior. It is also available from the
  overlay's compact Copi menu. The search icon and unused native title-bar surface
  can move the overlay, while the text field remains editable. Native Close on a
  pinned panel disables the option before closing.
- The non-activating overlay routes screen-coordinate mouse movement through the
  same handler from both local and global event monitors. The destination app
  normally stays active, so the global route remains required for result hover,
  outside-dismissal and Preview travel behavior during real overlay use.
- Suggestions are prepared before the first frame and refresh without requiring a
  hover event.
- SQLite learning schema v3 stores HMAC candidate identifiers, selection-only
  events, idempotent dispatched-paste upgrades and bounded source-copy evidence.
- Ranking assigns each event to one exclusive exact/surface/application/global
  bucket with weights 40/15/5/1, logarithmic diminishing returns, a 45-day
  half-life, a 180-day window and match confidence.
- Promotion uses cumulative dispatched-paste counts inside the window: exact 2,
  surface 3 or application 5. Selections without dispatch, global use and source
  copies cannot satisfy promotion.
- Unknown/missing context cannot match itself as exact or surface evidence.
  Address-bar exact context excludes hostname; ordinary standard browser content
  retains safe hostname context.
- Favorites receive a small score prior but unrelated Favorites do not crowd All.
  Relevant Favorite destination evidence or one of three semantic cold-start
  slots can admit one before clipboard-recency fallback.
- Destination capture has bounded classifiers for Outlook, Apple Mail, Calendar,
  Safari, Chrome and generic applications.
- Outlook appointment/event editors remain distinct from mail Compose and retain
  meaningful event-title, location, invitee and notes focus when exposed.
- Outlook compose windows can be recognized even when Outlook exposes no focused
  Accessibility element. Copi scans a bounded metadata-only subtree for stable
  Editor/Send or To/Subject landmarks and never requests `AXValue`.
- The hover card’s Observed source location combines semantic surface and focused
  area, for example `Compose` or `Browser page · Address bar`.
- Copy-source snapshots store semantic context, browser mode/hostname when safe,
  capture timing and AX issues; raw message bodies and control values are excluded.
- Password entries are always masked in results and encrypted at rest. They may have
  a separate descriptive label. A Favorite's optional name is its Results/Preview title;
  content is the fallback. Preview reveals a Password or explicitly masked Favorite
  only after a deliberate click and never enables editing. Favorite editing uses an
  explicit prefilled row-context-menu form. Local encrypted storage uses a launch passphrase with a memory-only
  derived key; Keychain is not used.
- Debug logging can be enabled, revealed and cleared in Settings. JSONL files
  rotate and exclude payload text, passwords, passphrases and keys.
- Context capture, ranking, search and paste paths have performance signposts and
  bounded deadlines. Clipboard polling remains at 250 ms.
- The rapid-type-hover diagnostic pipeline is implemented in source. With Debug
  Logging enabled it records privacy-safe target transitions, scope commits,
  result-materialization timing, throttled slow-layout events, main-queue stalls
  and a per-overlay summary. `scripts/copi-hover-diagnostics.sh` enables the gate,
  produces a concise hover-only JSON report and saves a non-intrusive report
  snapshot. Its separate stack-sampling command is explicitly marked invasive.
  The signed diagnostic build is deployed and the physical rapid-hover hang was
  captured; the diagnostics do not change hover selection behavior.

## Most recent work

- Tab and Shift-Tab now move keyboard focus through the Search capsule, Favorites, Content
  Types and Results instead of cycling scopes. Landing on Favorites or Content Types opens
  that sidebar panel, and Tab never closes the sidebar, so a card chosen on the way to
  Results keeps its scope. Only Search keeps the native field editor, so the caret is the
  Search focus cue while the focused sidebar card and Results row show a neutral outline;
  typing a printable character from any other region returns the field editor and inserts
  that character. Sidebar focus gives Up/Down two-column row movement and Left/Right
  single-card movement with clamped, non-wrapping bounds and immediate card activation,
  and Return hands focus on to Results. The former `cycleScope`/`scopeAfterCycling` Tab
  path has been removed. New pure helpers `overlayKeyboardRegionAfterTab` and
  `overlaySidebarCardIndexAfterMove` live in `HoverIntent.swift` with regression cases in
  `tests/HoverIntentTests.swift`; those cases were compiled and executed standalone and
  pass. The complete Apple Development-signed Release build passes and was installed to
  `/Applications/Copi.app` and relaunched as PID 50700; built and installed executables
  are byte-identical at MD5 `dbe1ab87dadfd454bded4b44bbfaf21b`. The new focus behavior
  has not yet been exercised interactively by the user.

- Added Command-Return Quick Actions for Link, Email and File Path entries, with the concrete
  action and `⌘ ↩` displayed in the Search capsule. Links open in the default browser, emails
  compose in the default mail app and paths reveal in Finder. The implementation deliberately
  reuses Copi's existing content classification and remains separate from paste dispatch and
  suggestion learning. The complete Apple Development-signed Debug build and diff hygiene
  check pass. The privacy-safe synthetic fixture visually confirms **Open in Browser** with
  the `⌘ ↩` keycaps for a highlighted Link. External browser, mail and Finder handoff has not
  been exercised to avoid launching those applications during the visual check. The capsule
  now observes highlighted-entry identity directly, so keyboard navigation and paging refresh
  it just like pointer hover; signed Debug and Release builds pass. The Release was installed
  to `/Applications/Copi.app` and relaunched as PID 10783. Built and installed executables are
  byte-identical at SHA-256
  `f47c8302d2e60c5525d2ae4188cb1acde492245d72b7a74f68165b4ef8546cd0`.
  The installed signature check reports the already-known `CSSMERR_TP_NOT_TRUSTED` trust-chain
  condition.

- Copi 2.1.0 build 10 is the signed release at
  `https://github.com/Smoep/copi/releases/tag/v2.1.0`. It includes live
  read-only website Preview, live/persisted Content Type and Favorite ordering,
  divider-free 36-point Results, resilient wheel paging and corrected Automatic Paste
  Events permission guidance. `Copi.zip` extracts as version 2.1.0 build 10, its
  executable matches the Release build at SHA-256
  `d79c3a235b88aee08865b7acd3c04c8ecf97319ce56dc7474b5d372cac9f0cb3`,
  strict deep signature verification passes, and the archive SHA-256 is
  `a7e9de6444de1804c8ad45c094895bfa6b49813792304482d0d85e1cedf0622d`.
- Copi 2.2.0 build 11 is prepared for publication at
  `https://github.com/Smoep/copi/releases/tag/v2.2.0`. It adds direct Link, Email and
  File Path actions, unified pointer/keyboard selection, full keyboard-region navigation,
  streamlined single-category Favorite assignment, typed Favorite search, adaptive Light
  and Dark Mode, and the refined Favorites Add control. `Copi.zip` extracts as version
  2.2.0 build 11 and its executable matches the Release build at SHA-256
  `10b0d62d1f0885c6bafa4e511c8becc2ab4dea0d818ceda5a089e920f87525df`; the archive
  SHA-256 is `9216812e053e4a6cf5a8529a7f791d6f37b441f042f7bf7949b6d7d5b67fe5d6`.
  A repeated strict deep verification passes for both the built and extracted apps and both
  satisfy their designated requirement. The initial transient `CSSMERR_TP_NOT_TRUSTED` result
  was investigated by extracting the embedded chain: the Apple Development leaf is current,
  its WWDR G3 intermediate is present, and `security verify-cert -p codeSign` succeeds.
- Fixed the Automatic Paste Events denial guidance. The alert now names the exact
  **System Settings → Privacy & Security → Accessibility** path, explains that Copi
  must be quit and reopened after enabling it, and opens that macOS pane directly.
  The former “Open Copi Settings” loop has been removed. The complete Apple
  Development-signed Debug build passes; the deep-link destination has not yet been
  exercised through a denied-permission fixture.
- Added deliberate live website previews for Link entries. Space now gives HTTP(S) links,
  including YouTube URLs, a bounded 760×620 maximum read-only WebKit canvas instead of
  displaying only the opaque URL. WebKit is constructed only for visible Preview content,
  uses a non-persistent data store, requires user action for media playback, blocks page
  clicks, pop-ups and non-web navigation, and shows an inert failure state. URL guards cover
  file/script and credential-bearing inputs. The focused interaction/geometry suite passes,
  and the complete Apple Development-signed Debug and Release builds pass. The Release was
  installed to `/Applications/Copi.app` and relaunched as PID 93221. Build and installed
  executables are byte-identical at SHA-256
  `646fcc594877b81ab1640098a5f11c1be2719086bac3947022774de441ff0d1c`;
  strict deep signature verification passes and TeamIdentifier remains `A6CM288C33`. Live
  remote-page rendering has not yet been visually validated.
- Link Preview now retains the local entry name and URL above the live website surface.
  Default-scope typed search now includes clipboard history and all Favorites, so a
  Favorite can be found by its optional name immediately after the overlay opens; empty
  default results and suggestion ranking are unchanged. The focused overlay helper suite,
  diff hygiene check and complete Apple Development-signed Debug and Release builds pass.
  The Release was installed to `/Applications/Copi.app` and relaunched as PID 99984; built
  and installed executables are byte-identical at SHA-256
  `76281dbc78cb3cff46caf76d5b2023d2e82b603db639c2454cf489826ce72243`, and the installed
  signature retains TeamIdentifier `A6CM288C33`. The current machine's trust-chain check
  reports `CSSMERR_TP_NOT_TRUSTED`; the unchanged published v2.1.0 archive now reports the
  same condition, so this is not introduced by these source changes. The updated Preview
  layout and live named-Favorite search have not yet been visually exercised.
- Assigned Favorites retain an outline star; unassigned rows reveal a filled star only when the
  pointer enters the trailing favorite target, which uses a hand pointer. Clicking opens a native
  category menu that assigns an unsaved item, moves an existing Favorite to its one category, or
  removes it. The full row width participates in hover selection. The sidebar `+` first offers New
  Favorite or New Category, and the Search capsule derives its numbered shortcut from the latest
  highlighted row for both pointer and keyboard navigation. The corrected synthetic interaction
  fixture verified full-row click selection, immediate capsule synchronization, hidden unassigned
  stars at rest, hover reveal/fill, and the native Work/Personal category menu. A follow-up live
  check found that the sidebar `+` menu's interactive glass layer swallowed its click; the control
  now uses a non-interactive circular background around the native Menu. The synthetic fixture
  interaction test visibly opened the two-item New Favorite/New Category menu, including the
  Work/Personal category submenu. The complete signed Release build and diff hygiene check pass.
  It was installed to `/Applications/Copi.app` and relaunched as PID 25496; the built and installed
  executables are byte-identical at SHA-256
  `66cc255d049c8a1302a9ad4f47191cb71a9ad0fc1ba069d78b1923cba0da861a`, with TeamIdentifier
  `A6CM288C33`.
- The Favorites-sidebar `New Favorite…` action now opens the glass content editor directly instead
  of first showing a category submenu. The editor contains a native Category picker, defaulted to
  the selected category or first available category, and persists only when Add is pressed. Assigned
  result stars are explicitly tinted with their Favorite category color. The synthetic fixture
  visually confirmed the direct editor, its Work category selector, and blue Work/green Personal
  star outlines. The complete signed Release build and diff hygiene check pass. It was installed
  to `/Applications/Copi.app` and relaunched as PID 27148; built and installed executables are
  byte-identical at SHA-256
  `2b4bd242e44b1aed844e5d36e141ef4034c31dd0aae7ae570d271551f86bbe82`.
- Unassigned result-star hover is neutral white/gray instead of the default Favorite green.
  Assigned Favorites use a dimmed filled category star at rest and restore the vivid original
  color on direct hover. The sidebar Add control uses a visibly rendered native `plus.circle` and
  the hand pointer. The synthetic fixture visually confirmed neutral unassigned hover, dim/vivid
  assigned states, and the circled Add control. Final Release deployment details follow the signed
  build and relaunch. The circled Add symbol was then softened to 55% white to match the surrounding
  glass UI. The complete signed Release build and diff hygiene check pass. It was installed to
  `/Applications/Copi.app` and relaunched as PID 31572; built and installed executables are
  byte-identical at SHA-256
  `cf7655bd04f9c97606062d267be4c572f92ca1e69220852140dc06b436a8d1f6`.
- The sidebar Add control now uses the approved plain `+` on a soft circular glass surface with a
  faint adaptive fill and a hand pointer. That surface is a separate non-hit-tested sibling so the
  native Menu remains responsible for interaction and AppKit cannot strip the surface. Copi's
  command overlay no longer forces Dark Mode and automatically inherits the macOS system
  appearance. Semantic foreground colors keep result text, toolbar symbols, shortcut chips and
  Favorite cards readable in both appearances. The privacy-safe fixture visually confirmed the
  Light Mode result list and Favorites sidebar, including adaptive pastel cards, dim/vivid
  category-colored stars and native category menus. The synthetic fixture's no-key identity path
  also now uses a Debug-only plaintext fallback, so assigning a result visibly updates its star;
  the focused executable regression reports `favorite-assignment-check assigned=true`. Production
  retains encrypted content identity. The complete Apple Development-signed Debug and Release
  builds and diff hygiene check pass. After separating the Add button's glass surface from its
  Menu label and adding the faint adaptive fill, the Release was installed to
  `/Applications/Copi.app` and relaunched as PID 38220; built and installed executables are
  byte-identical at SHA-256
  `160ee7ba7eb9b3cbe279ead5089554ebbf4500424e7412c55afdeb32372ae991`, with TeamIdentifier
  `A6CM288C33`.
- Removed the hairline separators between Results rows and tightened the shared row
  height from 38 to 36 points. The seven-row window, selection backdrop, hover geometry,
  paging and chip hit targets all derive from that shared metric. The focused boundary
  suite and signed Debug fixture build pass; the privacy-safe fixture visually confirmed
  seven aligned divider-free rows and a 14-point-shorter window. The complete signed
  Release build also passes and was installed and relaunched as PID 74513. Build and
  installed executables are byte-identical at SHA-256
  `df3665851ef7cc0d02363f61a3d0203fe5a3f118e1c2f50394fc1bf01d11f1b0`;
  strict deep signature verification passes and TeamIdentifier remains `A6CM288C33`.
- Fixed intermittent Results scrolling after pointer travel in the non-activating overlay.
  Local and global wheel events now use the same ownership checks and paging accumulator;
  Sidebar, Preview and diagnostics keep their existing native ownership. A privacy-safe
  synthetic fixture reproduced the immediate-scroll, move-down, scroll-again sequence,
  and physical trackpad validation confirmed that paging continued after movement. The
  focused interaction suite and complete signed Release build pass. The Release was
  installed and relaunched as PID 73201; build and installed executables are byte-identical
  at SHA-256 `7224a9da6c3ccdade3793f4917aad96a816c7ddb1d4b4678952c0751d6c0708b`,
  strict deep signature verification passes and TeamIdentifier remains `A6CM288C33`.
- Extended the live Favorite-category reorder interaction to Content Types and restored
  a closed-hand cursor only for an engaged drag. Content Type order starts from the normal
  declaration order, persists as a complete list in preferences and encrypted backups,
  and preserves hidden kinds when only the visible subset is moved. All Clipboard stays
  fixed first. Removed the “Rank Type Lists by Previous Usage” Settings toggle and its
  learned scoped-result sorting; type-filtered results now always retain clipboard
  recency. The focused ordering suite and complete Debug build pass. In the privacy-safe
  fixture, Email moved after Link in real time and the new order survived a full fixture
  quit/relaunch without changing card geometry. The complete signed Release build passed,
  was installed to `/Applications/Copi.app` and relaunched as PID 49054. Build and
  installed executables are byte-identical at SHA-256
  `73096703675eaaaec1d5c2eb53887d2067c44736efd6e4000ff15c5faf4456a3`;
  strict deep signature verification passes with TeamIdentifier `A6CM288C33`.
- Replaced the Favorite-category lifted/drop-only drag with Reminders-style live
  reordering. Static inspection of Reminders 7.0 on macOS 26.6.2 found a custom AppKit
  pinned-list view with dedicated dragged-item, drop-target and cached-next-layout state;
  direct UI inspection confirmed the ordinary arrow and unchanged card geometry. Copi
  now updates its transient category array on every crossed card, animates grid positions,
  commits the encrypted manifest once on release and restores the starting order when a
  drag ends outside the grid. Removed the open/closed-hand cursor overrides, hover/drag
  scaling, lifted shadow and target emphasis. The focused interaction suite and complete
  Debug build pass; the privacy-safe synthetic fixture confirmed Work moved behind the
  crossed categories during the drag without changing card size. The complete signed
  Release build also passed, was installed to `/Applications/Copi.app` and relaunched;
  PID 41173 is running that installed executable. Build and installed executables are
  byte-identical at SHA-256
  `d37865319ee0040832e45fd9de0d45fd92c438ba9f4421d64f6628e00d0cbb56`.
  Strict deep signature verification passes with TeamIdentifier `A6CM288C33` and the
  expected Apple Development certificate chain.
- Added a strict one-pass release-mode contract in `AGENTS.md` and
  `docs/RELEASING.md`. Publishing an already-validated build is now explicitly separate
  from product/UI work: no repeated tests, builds, installs, screenshots, research or
  post-upload downloads without a concrete failure or user request. The checklist uses
  the deterministic release URL before committing and requires a blocker update after
  five minutes. The proposed automation script is clearly **not implemented**.
- Reproduced a leading-Space regression in the real synthetic overlay: after Search
  received focus, Space increased its value from zero to one character and Preview did
  not open. The local monitor was incorrectly treating Search's own native field editor
  as a modal editor and also required the nonactivating panel to report itself key.
  Leading Space now routes through one production controller method: empty Search opens
  Preview and remains empty, while explicit New/Edit Category or Favorite popovers own
  Space and all other editor input. A Debug fixture feeds a real `NSEvent` through that
  exact route instead of relying on foreground-app delivery.
- Published Copi 2.0.1 build 9 as the signed patch release for these post-2.0 fixes.
  `Copi.zip` extracts as version 2.0.1 build 9, preserves the Release executable hash,
  and passes strict deep signature verification with TeamIdentifier `A6CM288C33`. The
  public release is `v2.0.1` at
  `https://github.com/Smoep/copi/releases/tag/v2.0.1`; downloading its published
  `Copi.zip` again produced the documented archive SHA-256 exactly.
- Fixed Favorite-editor input ownership at the AppKit event boundary. New/Edit Favorite
  now has explicit controller-level presentation state, so a leading Space is always
  native editor text, local pointer movement cannot route into Results, and the global
  mouse monitor cannot dismiss the parent overlay during editing. Ending the context menu
  no longer steals focus back to search when it opened an editor. Presentation lifetime is
  tracked by the popover binding rather than SwiftUI content disappearance, which may occur
  during an ordinary subtree redraw.
- Made Preview a strictly display-only Finder-style surface. It contains no editable
  text controls, so opening it cannot silently enter edit mode: Up/Down continues to
  change Results, Space toggles Preview, Escape closes it, and frozen result hover cannot
  steal its key-window state. Masked values retain click-to-reveal without enabling edit.
  A Favorite row now offers Edit Favorite in its context menu, opening the same prefilled
  optional-name/content/mask form as New Favorite. Saving applies all fields in one
  encrypted-manifest mutation and refreshes Results/Preview immediately. An optional
  Favorite name is now the display title for every content kind, with content fallback.
- Fixed Preview's cross-window focus loss. Opening Preview now makes its panel key and
  freezes both result-hover selection and hover diagnostics/shortcut presentation;
  moving across Results cannot replace the displayed entry or return key focus to the
  main panel. Up/Down retains Finder-style result navigation until an editable native
  text view becomes first responder, after which arrows, Space and text input remain in
  the editor. Favorite category context menus now include New Favorite, which opens a
  category-bound name/content/mask editor, detects type automatically and persists only
  on Add. Space events from that popover are explicitly excluded from Preview toggling.
  The editable-Preview portion of this intermediate change is superseded by the
  display-only contract above.
- Reproduced the perceived first-open result lag with deterministic synthetic frames:
  at 0, 80 and 160 ms the selected backdrop was visible while every materialized row
  was still hidden by a shared 140 ms entrance delay. Removed that common delay while
  retaining the 30 ms row-to-row stagger. After the change the first row begins by the
  80 ms capture, all seven initial rows settle by 300 ms, and a three-row Favorites
  transition is already readable at 160 ms. The timing contract now has a focused
  regression test, and the Debug fixture can capture initial-open frames without real
  clipboard content.
- Reproduced the bottom-edge placement defect with the pointer six points above the
  display edge. The 520×326 WindowServer frame started 52 points below the display
  because placement clamped the 274-point content rectangle before AppKit realized the
  unified toolbar. Initial placement now orders the native window, lays out its chrome,
  and clamps that actual frame to the cursor screen's `visibleFrame` in the same main-
  loop turn. The repeated bottom launch ended exactly at the visible boundary; an
  opposite top-right launch ended exactly at both the menu-bar and trailing boundaries.
- Removed the suggestion-row aurora backdrop, shimmer and chip shadow; suggestion
  provenance is now communicated only by the existing colorful numbered chip. Scope
  and category changes replay the same staggered top-to-bottom row reveal used on the
  overlay's first opening, while normal search typing remains immediate and does not
  animate each keystroke. The Debug-only synthetic fixture now includes one explicit
  suggestion and deterministic transition-frame capture so both contracts can be
  checked without real clipboard content.
- Replaced the nested rounded Results card with a flat Reminders-style list directly
  on the window surface. Seven contiguous rows are now 38 points high with subtle
  separators, 8-point horizontal and 4-point vertical outer spacing. The existing
  numbered multi-selection chips, immediate hover selection, transform-only glide,
  wheel paging and independent Preview default size are unchanged. Local Reminders
  binary inspection confirmed its list is built on AppKit table/outline-view cells,
  supporting a flat native list rather than another decorative card. A Debug-only,
  synthetic-fixture snapshot path rendered the complete window without reading real
  clipboard or Favorite content; its capture confirmed the separate Results box is
  gone and all seven compact rows remain aligned.
- Rechecked the pre-redesign implementation at repository commit `dd09fb6`. Replaced
  baseline-sensitive AppKit label controls with a lightweight custom-drawn badge using
  the earlier 17-point rounded key, 3-point gap, rounded font and opacity metrics. The
  badge retains its 80 ms token cross-fade and 100–120 ms show/hide ease.
- Restored the first panel's smooth row-to-row selection motion without restoring its
  expensive matched-geometry subtree: one transform-only backdrop uses the historical
  spring while entry text/icons receive color-only easing. Wheel paging leaves that
  backdrop in its visible slot and does not animate replacement row content.
- Rebuilt the top-right menu control as one 36-point macOS 26 `NSButton` using the
  native `.glass` bezel and the original `doc.on.clipboard` symbol at 13 points. Local
  Calculator binary inspection confirmed SwiftUI glass-effect/container imports,
  small control sizing and a unified toolbar; the current AppKit SDK exposes the direct
  single-control equivalent as `NSBezelStyleGlass`. Removed Copi's wrapping
  `NSGlassEffectView`, its tint and the duplicate `NSToolbarItem.image`. The menu button
  now owns interaction and glass in one layer, matching Calculator's measured 44×52 AX
  toolbar target and approximately 36-point visible control.
- Restored the original shortcut-keycap treatment inside the native AppKit search
  field: two compact 17-point rounded caps fade in on its trailing edge while native
  editing, IME and clear-button behavior remain intact. Result selection still commits
  without delay; the visible backdrop follows it with the historical spring.
- Preview Update now invalidates and reconciles the active result cache, then publishes
  an explicit presentation revision so the separate nonactivating Results panel redraws
  without waiting for pointer movement. The synthetic fixture verified both label-only
  and secret-plus-label updates immediately changed row 2; the latter created a new
  identity, stayed Password-classified and re-masked.
- Closed a protection gap at suggestion deduplication. History and Favorites remain
  separate encrypted stores, while the overlay merges their strongest Password/Mask
  policy and safe label by the existing HMAC content identity. Thus an equivalent
  automatic history row cannot represent a Password Favorite unmasked. The learning
  SQLite database continues to contain keyed identities and context evidence only,
  never payload text.
- Restored immediate result-row hover feedback. The model and visible matched-row
  highlight now update without debounce or spring travel; the native search capsule
  displays the hovered numbered shortcut and substitutes the Shift symbol for its
  magnifying glass while Shift is held. A same-frame synthetic fixture capture showed
  row 4 and `⌘ 4` together, and Accessibility exposed `Shift pressed` for the leading
  search button while the modifier was held.
- Added separate encrypted labels for Password clipboard items and Favorites. Preview
  now keeps Password and explicitly masked Favorite values concealed until a deliberate
  click, permits label/value editing, and re-masks after Update. A recaptured duplicate
  retains its label and content-type override. The synthetic fixture verified label
  persistence, secret editing/re-masking, and the masked-Favorite reveal path without
  exposing live clipboard data.
- Added Delete from History to ordinary clipboard-row context menus. Deletion removes
  selected history records, encrypted payload files and model references without
  touching the current system pasteboard. The native menu item was visually verified;
  no real history record was deleted during acceptance testing.
- Shortened the development unlock message to “Enter your passphrase to unlock Copi's
  encrypted database.” while retaining specific error and destructive-reset guidance.
- Validation: all four focused executable suites passed (hover/geometry, suggestion
  ranking, learning-store and destination-context), as did signed Debug fixture and
  complete signed Release builds. The privacy-safe fixture verified same-frame hover,
  Shift accessibility, masked reveal/edit/re-mask, labels and the native Delete menu.
  The Release was installed and relaunched to the shortened unlock gate. Build and
  installed executables are byte-identical at SHA-256
  `c725f5d8a840588f36c402124966b55233f444e05aae86d47e6f2c7dcc5c2937`;
  the installed signature retains TeamIdentifier `A6CM288C33`. Debug Logging and
  Always On Top were restored to off.
- Reproduced two context-menu/diagnostic defects in the privacy-safe visual fixture.
  With Debug Logging disabled, row hover now cancels pending diagnostics and closes
  any visible Entry diagnostics card; when logging is enabled, the existing 0.5-second
  diagnostic behavior remains available. A disabled-logging 1.1-second stationary
  hover produced only the main overlay window.
- Mask/Unmask and other row-menu actions no longer depend on a later pointer event to
  redraw the nonactivating SwiftUI panel. The overlay publishes an explicit observed
  presentation revision on native `didSendAction` and again after `didEndTracking`,
  then synchronously commits layout/display. In a stationary-pointer fixture capture,
  Mask was visibly applied by 200 ms as the native menu closed; the 100 ms frame still
  showed the menu open. Favorite encrypted persistence remains coalesced away from the
  menu action's immediate in-memory update.
- Native menu tracking now owns hover and key focus for its full lifetime. Right-click
  aligns Copi's independent row highlight to the clicked row, crossed rows cannot steal
  it while the menu is open, and the native search field is restored afterward. A
  pinned overlay no longer steals key focus from the current paste destination merely
  because the pointer crosses it; before automatic paste it explicitly resigns its main
  and Preview panels and yields one AppKit turn before destination verification.
- Validation: the focused hover/geometry executable passes; signed Debug fixture builds
  pass. Computer Use's app-state reader stalled and was terminated, so the same visual
  acceptance path used the local privacy-safe Accessibility geometry driver plus window
  screenshots containing synthetic fixture data only. The complete signed Release build
  succeeded, was installed and relaunched; build and installed executables are
  byte-identical at SHA-256
  `5551f269079196e25fd7d4bfc0df0d7b29b8424fd34f4d98a375ff4f3dcc0fb1`, and the
  installed signature retains TeamIdentifier `A6CM288C33`. The temporary real-app
  Debug Logging and Always On Top test preferences were restored to off.
- Completed the Favorite-category interaction pass requested after the first sidebar
  reorder build. Create/Edit now share a native popover with category name, a reliable
  in-popover Reminders-style color palette and grouped SF Symbol picker. Right-clicking
  a card offers the prefilled editor and a guarded Delete action whose confirmation
  includes affected Favorite count. Persistent and synthetic-overlay snapshots update
  through the same model operations.
- The earlier category-drag pass added an open/closed-hand cursor, lifted/scaled source
  and bright target. That historical interaction is superseded by the current unchanged-
  card, standard-arrow, live-reordering behavior recorded above.
- Sidebar edge handling now clamps every frame of the native width transition. The
  synthetic fixture reproduced an expansion from 520 to 748 points near the right edge;
  the overlay moved left exactly 37 points, the minimum required to keep the expanded
  window visible, while an unconstrained opening preserves its leading edge.
- Accessibility-driven fixture validation selected Purple and `heart.fill`, created a
  synthetic Planning category, and visually confirmed the resulting purple heart card.
  Its context menu exposed Edit Category and Delete Category; Edit reopened with all
  three values prefilled, and Delete presented the guarded confirmation without data
  removal. A historical cursor-inclusive held-drag capture showed the former closed hand,
  lifted source and bright target before release; that affordance has since been removed.
  All four focused executable suites passed. The signed
  Release was installed and relaunched; build and installed executables are byte-identical
  at SHA-256
  `34acd58169a94e7c14f32399c75a9286cbfd99222770700925a7392373eadb54`, and the
  installed signature retains TeamIdentifier `A6CM288C33`.
- Added Reminders-style Favorite category management directly to the overlay sidebar.
  A compact bottom Add button opens a native popover containing only category name and
  color; creation selects the new category immediately. Favorite cards are now
  borderless directional gradients with tint-matched selection feedback, and
  user categories reorder by dragging the whole card. The exact order is persisted;
  All Favorites remains pinned first and Content Types keep their semantic order.
- Disabled whole-content background window dragging because AppKit intercepted the
  category gesture before SwiftUI's drag threshold. The native title bar and explicit
  search-icon drag handle remain available, so overlay repositioning still works while
  card dragging and sidebar scrolling own their intended gestures.
- The privacy-safe fixture exercised the actual native category popover and Create
  action, then dragged Personal ahead of Work and verified the card frames exchanged
  positions. A regression drag on the search icon still moved the overlay. All four
  focused executable suites pass, including forward/backward reorder cases. The signed
  Release built, was installed and relaunched; build and installed executables are
  byte-identical at SHA-256
  `337603f2ca89118f0b76544a47ce7156faac9c5230d055101ac26b332cae1284`, and the
  installed signature retains TeamIdentifier `A6CM288C33`.
- Removed the remaining native blue focus ring from the search capsule and reduced
  sidebar cards from 64 to 56 points without changing their two-column proportions.
  Corrected window-level wheel routing to compare the pointer in sidebar-local
  coordinates and return the native event to its `ScrollView`; the synthetic fixture
  scrolled from the first cards to Number/JSON/XML/File Path while Results remained on
  the same seven rows.
- Corrected result-row Content Type actions so persistence and the visible overlay
  snapshot update through one model operation. The model now refreshes card counts,
  clears an emptied active type scope, and reruns an entered search rather than leaving
  stale results. The privacy-safe fixture follows this exact action path for rows that
  intentionally do not exist in persistent storage. Computer Use plus the row's native
  accessibility context-menu actions verified assigning Password immediately changed
  the visible first row to its masked form.
- The hover/sidebar geometry, suggestion-ranking, learning-store and destination-
  context executable suites all pass. The signed Release built successfully, was
  installed and relaunched to the expected development-passphrase gate. The build and
  installed executables are byte-identical at SHA-256
  `c95f4d7c2a5c679ee45b7c0e1c135e235a65e97b9f4b3f7bbec7b4d0a0584a75`, and the
  installed signature retains TeamIdentifier `A6CM288C33`. No live clipboard payload
  was exposed during validation; final visual interaction checks used the synthetic
  fixture.
- Compacted the native overlay without changing its architecture or interaction
  responsiveness. The Results card now uses symmetrical 8-point top/bottom insets
  beneath the toolbar while retaining its proven horizontal Search alignment. Sidebar
  cards are 56 rather than 72 points high and use the available column width with
  matching 8-point outer and grid spacing. The selected-card outline is neutral glass
  with a tint-matched shadow instead of the hard-coded system-blue ring.
- Closing Types or Favorites is now one atomic model transition back to All Clipboard:
  selected category, remembered type, placeholder and result scope reset together;
  entered query text remains and is rerun against the full clipboard set. Computer Use
  reproduced the old retained Text scope, then verified the corrected Text and Work
  category close paths in the synthetic fixture: both restored `Search clipboard…`
  and all seven rows. All four focused executable suites passed. The signed Release
  was installed and build/installed executables match SHA-256
  `da0071b2343b546ca01d82db95f72f992e0ec1a671c4d972f1123c22393b54a8`.
- Corrected the September 1 overlay feedback in the native AppKit shell. Result hover
  now resolves rows in the detail hosting view's flipped, safe-area-adjusted coordinate
  system. The toolbar's Types/Favorites control uses a compact 32-point regular native
  segmented control; `.sidebarTrackingSeparator` plus the native fixed spacer aligns
  scoped search with the Results card when the sidebar is open.
- Reproduced the opening glitch with frame sampling. A parallel split-item/window-width
  animation paused at 740 points and snapped to 748; the pure fixed-sibling split
  transition was continuous but moved the leading edge left. The implemented contract
  gives AppKit sole ownership of width and uses `windowDidResize` only to restore the
  starting x-coordinate during the 200 ms transition. The post-audit synthetic fixture
  measured opening `520 → 522 → 528 → … → 742 → 748`, with x fixed at 41. The
  byte-identical installed Release measured `520 → 521 → 531 → … → 738 → 747 → 748`,
  with x fixed at 1474 throughout; the preceding installed close trace was likewise
  monotonic to 520 with a fixed origin.
- The hover/geometry, ranking, learning-store and destination-context executable suites
  pass. The signed Release was installed and relaunched after the prefilled Unlock
  action; `/Applications/Copi.app` is byte-identical to the Release build. Computer Use
  verified the compact toolbar and aligned open search. The temporary Always On Top test
  setting was restored to off.

The following four bullets are superseded implementation history retained to explain
why the current AppKit split shell replaced the earlier hybrid:

- Replaced the custom sidebar/window imitation with the same native structural
  family exposed by Calculator: `NavigationSplitView`, an `NSHostingController`,
  and a real toolbar. AppKit now owns split expansion/collapse, the full-height
  sidebar titlebar and traffic-light integration. Removed the manual frame animator,
  custom glass shell and coordinate-driven overlay drag. Following Apple's official
  macOS 26 Landmarks sample, search is now SwiftUI's native `.searchable` toolbar
  item and the two collection buttons are a native `ToolbarItemGroup`; the public
  `.toolbar(removing: .sidebarToggle)` customization replaces the redundant system
  toggle. No private SwiftUI toolbar identifier is inspected or mutated after
  installation. The leading search icon alone invokes `NSWindow.performDrag(with:)`
  while the rest of the system field retains native text and IME behavior.
- The native split item uses `preferResizingSplitViewWithFixedSiblings`; the window
  controller preserves only the result pane's screen edge (clamped to the active
  display) while AppKit owns sidebar width and animation. In the synthetic fixture,
  compact `{x:400,w:520}` and open `{x:169,w:751}` both measured the same result
  edge at `x=920`, and collapse restored the exact compact geometry. A separate
  near-edge check clamped the expanded origin to `x=0` rather than placing the
  sidebar offscreen.
- Corrected the overlay after live visual comparison with macOS 26 Calculator. The
  earlier build incorrectly rendered three detached surfaces and placed the sidebar
  beside, rather than beneath, its navigation control. The shell is now continuous;
  its control transitions into the leading header, sidebar cards start immediately
  below it, and search/results remain one right-hand column. Added a Debug-only,
  synthetic visual fixture with a separate bundle identifier so this layout can be
  inspected without unlocking or exposing user clipboard data.
- Rechecked the running Calculator and Reminders accessibility hierarchies and the
  downloadable Apple Landmarks Liquid Glass source instead of relying on screenshots
  or third-party replicas. Calculator exposes a sidebar `NavigationSplitView`;
  Reminders exposes a native toolbar group plus `NSSearchField`. The synthetic Copi
  fixture now exposes that same structural family: split group, native grouped
  collection buttons, native scoped search field and Close integrated into the open
  sidebar. Fixture validation confirmed initial search focus and typing, Escape
  collapse, Right-arrow opening Favorites, a 256-point open sidebar and reversible
  compact/open layout.
- Rebuilt the command shell around the implemented macOS 26 overlay contract:
  native Close-only panel, Liquid Glass toolbar, floating two-column sidebar,
  one scoped search field, click-driven cards, persisted width, anchored leftward
  expansion, exact horizontal-arrow state machine and compact Copi menu. Existing
  result rows, numbered multi-selection, ranking, paste dispatch and Preview were
  preserved. Removed the now-inoperative Filter Hover Lock Delay from Settings.

Historical steps below are retained for diagnosis; the current-state section above
supersedes older strip/hover behavior where they differ.

1. Stabilized the Preview editor lifecycle; separated immediate type-button feedback,
   50 ms result activation and a Preview-only 200 ms deadline; added Finder-style
   Space toggling, centered presentation and reversible content-aware sizing. The
   latest change removes image payload I/O and lazy decoding from the main-thread
   render path via cancellable Image I/O downsampling, eager decode, bounded display
   caches and a stable placeholder. The legacy NSImage cache now checks for a hit
   before reading/decrypting its payload. Privacy-safe hover diagnostics remain
   available and image preparation has a Points of Interest interval.
2. Replaced cumulative lexicographic ranking with destination-first rule v2.
3. Added mutually exclusive selection-only/dispatched event states and connected
   learning to the verified `pasteDispatched` callback, including combined paste.
4. Added conservative v2→v3 learning migration: old selections remain weak intent,
   never invented dispatches; global copy totals seed only the capped source prior.
5. Added exclusive score buckets, cumulative eligibility, confidence matching,
   decay/expiry, small priors and deterministic tie-breaking.
6. Added full hover/JSONL score decomposition and pure ranking plus SQLite
   migration/event-lifecycle tests.
7. Corrected the hover model after interaction review: initial selection retains
   the existing 45 ms row response and immediate strip response; pointer rest locks
   the selected choice, rather than delaying every selection.
8. Added one shared movement-sensitive time-to-lock setting across rows, Favorite
   categories and clipboard types, persisted locally and in encrypted backups.
   A settled lock protects one transition and is then consumed; it does not transfer
   continuously from choice to choice.
9. Aligned the event model as well as the timing: results now resolve their row
   from the same continuous panel-level pointer stream used by categories/types,
   instead of using independent SwiftUI enter/leave callbacks on every row.
10. Made the hover lock a one-shot guard. After it protects one deliberate takeover,
   it is consumed and the new selection returns to normal responsive hover. A
   later lock requires a fresh resting cycle.
11. Corrected the final lifecycle: a lock is a fixed 500 ms temporary guard, not a
    transferred state. Results and Favorite/type buttons reset independently at
    their boundaries, and search-capsule behavior is excluded from locking.
12. Corrected the timer anchor: resting arms protection but does not start its
    500 ms clock. The clock starts only when the pointer departs the settled choice
    toward a sibling, so idle time cannot consume the useful travel window.
13. Corrected strip-region geometry: the visual spacing between adjacent category
    or content-type buttons is internal travel, not a region exit. Those gaps now
    cancel an unfinished settle or start/preserve armed travel; only actual strip
    exit or entry into the excluded search capsule resets the strip lock.
14. Added a pending-result affordance during protected row travel: the candidate
    row turns subdued grey immediately while the settled row remains blue, then
    becomes blue directly at travel-window expiry.

## Validation completed

- The leading-Space regression was first reproduced through the focused synthetic UI
  (`searchLength=1`, no Preview window). After the fix, the production-event fixture
  reports `searchEditorActive=true`, `previewConsumed=true`, `previewOpened=true`,
  `queryUnchanged=true` and `editorProtected=true`. The complete AppKit fixture also
  reports true for Preview key ownership, display-only behavior, arrow navigation,
  Favorite create/edit/name fallback, Escape, editor Space protection, frozen pointer
  selection and editor dismissal protection. All four focused executable suites pass.
  The signed Release was installed and relaunched; build and installed executables are
  byte-identical at SHA-256
  `5ad7b7fc2652e683ae4bf333995bc50d5c78e3b39efd9a9c99669cd903a9bd6f`. The verified
  `Copi.zip` archive SHA-256 is
  `e19993639bb6c5f6e8d23d5838f24481feee6b8371971c392f580f3da4b1891d`; strict signature
  verification passes and TeamIdentifier remains `A6CM288C33`.
- Preview focus ownership and direct Favorite creation passed the focused hover/
  geometry suite, all three ranking/storage suites, and complete signed Debug and
  Release builds. The latest Debug-only synthetic two-panel integration check reports
  `keyOnOpen=true`, `hoverFrozen=true`, `displayOnly=true`, `arrowNavigation=true`,
  `previewFocusPreserved=true`, `favoriteCreated=true`, `favoriteEdited=true`,
  `optionalName=true`, `contentFallback=true` and `escapeClosed=true`; its Favorites
  are in-memory synthetic content and do not touch the real encrypted store. The Release was
  installed and relaunched; build and installed executables are byte-identical at
  SHA-256 `0bd48f2163c062688ebef18a57eae8dc25b5f73ed2ec147f2371dcec67612182`,
  strict signature verification passes and TeamIdentifier remains `A6CM288C33`.
- The Favorite-editor regression contract passed the focused hover/geometry suite and the
  Debug AppKit fixture reports `editorSpaceProtected=true`, `editorPointerFrozen=true` and
  `editorDismissProtected=true`. All destination-context, ranking and learning-store suites
  also pass. In the direct executable invocation the LSUI fixture did not become the macOS
  foreground app, so its unrelated `keyOnOpen`/`previewFocusPreserved` assertions were not
  counted as validation. Computer Use likewise could not attach to the nonactivating panel.
  The signed Release was installed and relaunched; build and installed executables are
  byte-identical at SHA-256
  `85f2ac02ac2f922961df2cf37974d101b758d9fe6f7fec195dc3474648bffcae`, strict signature
  verification passes and TeamIdentifier remains `A6CM288C33`.
- The immediate-first-row result reveal passed the hover/geometry regression suite,
  the suggestion-ranking, learning-store and destination-context suites, and complete
  signed Debug and Release builds. Synthetic first-open captures at 0/20/80/160/300/
  550 ms reproduced the former blank interval and then confirmed the first row starts
  by 80 ms and all seven rows settle by 300 ms; matching Favorites captures confirmed
  all three filtered rows are readable by 160 ms and settle by 300 ms. No real
  clipboard or Favorite payload was rendered. The Release was installed and relaunched;
  build and installed executables are byte-identical at SHA-256
  `5a2b416690ae9c463dad07518cd8307f99dd1255755df5e600338d92fa6ec870`,
  strict signature verification passes and TeamIdentifier remains `A6CM288C33`.
- Copi 2.0.0 build 8 passed all four focused executable suites and complete signed
  Debug/Release builds. The installed Release is running and its executable matches
  the build at SHA-256
  `e165cbd172a842e03b5747f4e3a4b60a6440cbb7a2ef4e735251bc4e41af6915`.
  The 520×326 bottom-edge fixture moved from 52 points offscreen to WindowServer
  bounds ending exactly at display y=1490; the top-right fixture started at y=50 and
  ended at x=2294, exactly matching the visible work-area boundaries. The packaged
  `Copi.zip` extracts as version 2.0.0 build 8, preserves that executable hash, and
  passes strict deep signature verification with TeamIdentifier `A6CM288C33`. Archive
  SHA-256 is `c361b9529293e31a8cd586ca367b4884609fa6885f0be72e65ce2b4e207e2739`.
  The public release is `v2.0.0` at
  `https://github.com/Smoep/copi/releases/tag/v2.0.0` with that archive as
  `Copi.zip`; Debug Logging and Always On Top remain off in the installed app.
- The simplified suggestion cue and repeated result reveal passed signed Debug and
  Release builds plus all four focused executable suites. A deterministic synthetic
  still showed the suggested row using only its colorful numbered chip—no row wash,
  shimmer or chip glow. Transition captures at 20/80/160/300/550 ms showed a three-row
  Favorites result set assemble from the first row downward and reach its settled state;
  the capture path removes pointer monitors so a real cursor cannot alter the fixture.
  No clipboard or Favorite payload was read. The Release was installed and relaunched;
  build and installed executables are byte-identical at SHA-256
  `fd703468dfd8a6d94be76998034b4f4bbf1afd6109647b4de44112ad147e6ce5`.
  The running app retains Apple Development TeamIdentifier `A6CM288C33`; Debug Logging
  and Always On Top remain off.
- The compact flat Results list passed the focused hover/geometry executable at exact
  38-point row boundaries, plus the suggestion-ranking, learning-store and destination-
  context suites. A Debug-only self-render of the synthetic fixture confirmed the
  nested Results card is gone, all seven rows and separators align, and numbered chips
  remain present; no live clipboard or Favorite payload was loaded. The complete signed
  Release built, was installed and relaunched. Build and installed executables are
  byte-identical at SHA-256
  `834b26bfc31225ab4ddbd25904c39e4f072b624e6833fb3ec2785bade83ab338`.
  The installed app is running with Apple Development TeamIdentifier `A6CM288C33`;
  Debug Logging and Always On Top remain off.
- The rebuilt top-right menu passed signed Debug and Release builds plus window-only
  synthetic visual and interaction checks. Local Calculator inspection found SwiftUI's
  glass container/effect imports, small control size and unified toolbar; its toolbar
  button measured 44×52 through AX with an approximately 36-point visible circle. The
  final fixture uses one 36-point `.glass` AppKit button and 13-point original clipboard
  symbol, with no wrapping glass view or duplicate toolbar image. Window-only captures
  confirmed a quiet unoutlined rest state and a distinct native hover outline. An
  element-scoped AXPress produced a separate layer-1001 menu window containing Always
  On Top, Settings and Quit, and Escape completed the tracking cycle. The focused hover
  regression executable also passed. Computer Use's state reader stalled, so verification
  used privacy-safe synthetic AX/window metadata and window-only captures rather than
  making claims from an incomplete reader result. The Release was installed and
  relaunched; build and installed executable SHA-256 values both equal
  `8e65e13b9b1eb8b6bfcac7678fed4ab83586f66ea0ec69cb2c5f497d9f98cc99`.
  The signature retains Apple Development team `A6CM288C33`; production Debug Logging
  and Always On Top were restored to off.
- The historical keycap, stable-slot hover animation and arrowless circular popup
  changes passed the focused hover/geometry executable and a complete signed Release
  build. The synthetic fixture showed seven aligned rows after rapid traversal and
  advanced exactly four entries after four wheel ticks; a window-only capture confirmed
  the two 17-point keycaps and round top-right button with no disclosure arrow. The
  Release was installed and relaunched; its build and installed executable SHA-256
  values both equal
  `529d4392b7d26695b42b0f31d1e1c4558aa6bb6947f651eaa995c2b71d33101d`.
  The installed signature retains Apple Development team `A6CM288C33`, and production
  Debug Logging and Always On Top were restored to off.
- The shortcut-keycap, immediate local hover-ease, Preview-to-Results reconciliation
  and shared content-identity protection changes passed all four focused executable
  suites: hover intent, suggestion ranking, destination-context ranking and the
  suggestion learning store. A clearly synthetic fixture visually verified the two
  trailing keycaps, an equivalent history/Password-Favorite value rendering with its
  safe label and mask, immediate same-identity label refresh, and immediate
  new-identity secret-plus-label refresh followed by re-masking. No live clipboard
  payload was used or recorded. The complete signed Release then built, was installed
  and relaunched; the build and installed executable SHA-256 values both equal
  `d5cbe60bac1d4777b3aa741564973360e2eb1723dd43448e6a7582010fabef70`.
  The running installed app retains Apple Development team `A6CM288C33`; production
  debug logging and Always On Top were restored to off after validation.
- Current native AppKit split-shell validation: the signed Debug fixture exposes one
  AX split group with a 228-point native splitter. Computer Use verified compact,
  Favorites-open and Types-open states; stationary toolbar controls; aligned sidebar
  and result surfaces; the full non-wrapping arrow path; and native scoped search.
  The first installed Release run reproduced
  the stale-collapse transition described above before the correction. After the
  correction, signed Debug and Release builds succeeded and all four focused
  executable suites passed. The installed executable matches the final corrected
  Release SHA-256 `1dbb2f925f726545245619be2367d70e0527738f22d5918de32fb01813d7b7e7`.
  After unlock, exact final-installed frames measured away from screen edges were
  compact `{x:749,w:520,h:400}`, open `{x:749,w:748,h:400}`, filtered to one result
  `{x:749,w:748,h:400}`, and collapsed `{x:749,w:520,h:400}`. This confirms the
  leading edge and height remain fixed while only the detail/right edge moves. The
  synthetic fixture was closed.
- The final signed Release was installed, relaunched and exercised through Computer
  Use against the unlocked real overlay and live result sets, not only the synthetic
  fixture. The settled first frame was compact with native search focused. Types and
  Favorites opened a 256-point native leading column; selecting Favorites → Work
  changed the scoped placeholder, restored search focus and accepted `SELECT`
  immediately, reducing the real Work list to its matching row. Layered Escape first
  cleared the query and then collapsed the sidebar. Right from closed opened
  Favorites and Left changed it to Types, preserving the documented spatial path.
  A leading Space opened the separate Preview; Down changed its entry and reversibly
  reduced the window for shorter text; Space closed it. Dragging the search-leading
  grip changed the overlay's settled screen position. With Always On Top enabled,
  Calculator became frontmost while Copi's overlay remained present; disabling the
  option closed the overlay and the preference was restored to off after the test.
  All four focused executable suites passed after the final focus fix. The installed
  and Release-build executables exactly match at SHA-256
  `f71cebea2a871dd84c954616b1ba965f66c4f2f39e7b603aad165383bd66064e`.
  The installed app has the certificate-based Apple Development designated
  requirement for team `A6CM288C33`; the local strict trust-chain check reports
  `CSSMERR_TP_NOT_TRUSTED`, so this handoff does not misstate that check as a pass.
- The native synthetic fixture built successfully and Computer Use verified both
  compact and expanded states. Its accessibility hierarchy is a real split group;
  opening Favorites uses the system expansion, moves Close into the sidebar titlebar,
  leaves results fixed, exposes a native splitter, and keeps exactly the two Copi
  navigation segments. Left switched the already-open column to Types and the
  documented arrow path collapsed it back. That earlier filter-preservation behavior
  has since been superseded by the current reset-to-All close contract.
  Forty alternating Types/Favorites activations at 50 ms intervals forced repeated
  result-set changes without a hang; the split geometry remained stable and the app
  remained immediately inspectable. This fixture evidence preceded and is now
  supplemented by the unlocked installed-app validation above.
- The macOS 26 overlay redesign passed all four focused executable suites: hover/
  sidebar intent and geometry, suggestion ranking, SQLite learning-store migration,
  and destination-context ranking. Signed Debug and Release builds succeeded.
  The Release was installed and the installed executable exactly matched the build
  at SHA-256 `ecd03ba63fce795395eed79b51d5123120360d03a137b92e9cd94fdb2434309a`.
- Before the final passphrase-gated relaunch, Computer Use exercised the installed
  overlay rather than Settings: compact default state; Favorites and Types glass
  sidebars; two-column cards and selection borders; Work-scoped search; the exact
  horizontal-arrow path; all present
  types in a scrollable grid; clickable existing result layout; and the overlay
  menu labels Always On Top, Settings and Quit. A real Space key opened Preview.
  Preview resized reversibly from 240×220 for tiny content to 901×428 for an
  873×328 landscape image, then back to 240×220. The width-resize path persisted
  its test value; the live preference was restored from the 290-point test maximum
  to 229 points, effectively the approved 228-point default.
- The signed rapid-hover diagnostic Release build was installed and relaunched;
  installed executable SHA-256 was
  `e0cf9fe20d8c2f773b676a97776a6d78dbe478902a26cac09131ee3d1cd883ea`.
  A physical rapid content-type sweep generated 498 pointer events, 72 target
  transitions and 69 committed result sets. Result materialization took about
  0.03–0.23 ms, but those commits triggered 1,890 hosting-view layout passes
  (about 27 per commit). Six individual passes exceeded 16 ms; the maximum was
  48.3 ms.
- A stack capture overlapping the observed freeze placed 6,251 samples in
  `NSHostingView.layout`; 3,991 were in SwiftUI's platform TextField adapter and
  CoreText sizing. The preview changes view identity and animates for every new
  highlighted entry while loading a new full draft/editor, making preview-native-
  editor churn and accumulated SwiftUI layout the leading causal finding. Filtering
  and result-array construction are ruled out by direct timings. No usability fix
  has been implemented from this finding yet.
- Two 14–15 second watchdog delays aligned with active `/usr/bin/sample` windows,
  and a later sample found the main thread idle. The profiler can perturb the app,
  so the safe pipeline now captures structured logs first and labels stack sampling
  as an invasive second step. The overlapping call graph remains useful for locating
  the layout hot path, but sampler-length delays are not treated as independent
  proof of the original hang.
- The 50 ms latest-target activation was compiled into a signed Release build,
  installed and relaunched. The built and installed executables matched SHA-256
  `10ff7260defcab91c42bc2ec6702de6a4ddc6470a50cfdd038afc9401341447d`.
  Focused hover-intent tests passed, including the exact 50 ms contract, latest-wins,
  region-exit cancellation, stale-generation rejection and single consumption.
- In a fast installed-app sweep, 89 visible type selections produced only 8 real
  result/Preview activations, 804 layout passes and no watchdog stalls. The original
  capture produced 69 activations and 1,890 layout passes, so the delay substantially
  reduces pass-through work while preserving immediate button feedback.
- The stronger no-profiler test deliberately held each type for 65 ms so every hover
  could cross the activation threshold. Copi processed 10 target transitions and 9
  measured result activations before a 13,125 ms main-queue stall; only 20 pointer
  events were handled while the driver posted 50 targets. Individual result filtering
  remained 0.03–0.04 ms, and the session accumulated 415 layout passes. This is an
  unconfounded reproduction of the remaining Preview/layout freeze and proves that
  50 ms debounce alone is insufficient.

- Swift parsing and focused type-checking passed for destination-context code.
- Synthetic classifier smoke checks passed:
  - Outlook `Untitled` compose title → Compose;
  - Outlook Subject landmark → Compose;
  - generic Outlook window → Unknown.
- Deterministic ranking tests passed for exclusive/cumulative counts, event-state
  upgrades, thresholds, confidence, half-life, expiry, missing context and priors.
- Destination-key tests passed for address-bar hostname exclusion, standard page
  hostname retention, structural surface-only Compose and title-only confidence.
- Outlook appointment regression coverage passed for event-editor classification
  and exact event-title focus rather than mail Compose.
- SQLite v2→v3 integration tests passed for conservative legacy migration,
  idempotent dispatch upgrades and source-copy evidence.
- Hover-lock regression tests pass for movement-based time-to-lock rearming, jitter
  tolerance, ignored sibling crossing during the active lock, bounded expiry,
  stale-expiry rejection, restored responsive hover and region reset.
- An installed-app pointer proof ran from a blank TextEdit destination with the
  configured 300 ms activation delay. After row 2 rested for 380 ms, crossing row
  3 left row 2 highlighted at 100 ms; at 620 ms row 3 was highlighted, proving the
  fixed 500 ms lock expired and deferred hover resumed. Moving into Preview kept
  row 3 selected while resetting helper state, and returning to row 4 selected it
  within 150 ms. The proof posted real macOS pointer events, made no clicks or
  pastes, and sampled only a four-pixel text-free highlight gutter.
- The pending-result affordance compiled in the focused hover-lock test pass and a
  complete signed Release build. It was installed to `/Applications/Copi.app`;
  installed and build executable SHA-256 values matched
  (`57950df3fba5e55a732bb28d5188efa33c2181d91ca3a5da7290f8399423e7e2`).
  The visual transition still needs an installed-app pointer check after unlock.
- The static aurora suggestion treatment compiled in the focused hover-lock test
  pass and a complete signed Release build. It was installed to
  `/Applications/Copi.app`; installed and build executable SHA-256 values matched
  (`939197a1114462025b79950bf897070d6d5efb82cdf2fc0164b0b1e79f2ee83c`).
- The one-time suggestion shimmer, softened pending highlight and restored
  top-down entrance compiled in the focused hover-lock test pass and a complete
  signed Release build. It was installed to `/Applications/Copi.app`; installed
  and build executable SHA-256 values matched
  (`befaeab3491d790abc00a37372b0c58d8e81759a3eca6aa649473ebff5ee77a5`).
- The transient suggestion shimmer, glossy high-contrast suggestion number chip
  and fixed-width search capsule compiled in the focused hover-lock test pass and
  a complete signed Release build. It was installed to `/Applications/Copi.app`;
  installed and build executable SHA-256 values matched
  (`63f5506511f2bb9296c0c20c9ee6e431c12940f0499ce6fa1b1459f61887aa62`).
- The restored full-width capsule in both collection states, higher-contrast
  suggestion chip and right-edge-synchronized shimmer exit compiled in the focused
  hover-lock test pass and a complete signed Release build. It was installed to
  `/Applications/Copi.app`; installed and build executable SHA-256 values matched
  (`578a7bd929f848b384280dd900814737401ae7cf28f964e6b43bf96ce74b62a0`).
- The full-row suggestion sweep with smooth post-sweep fade, darker cyan–purple
  AI chip and selection-priority chip styling compiled in the focused hover-lock
  test pass and a complete signed Release build. It was installed to
  `/Applications/Copi.app`; installed and build executable SHA-256 values matched
  (`59c95b3386a70c2ead6c3ef2906ca88a6e047778e690feb8707408a34632bad6`).
- The earlier temporary-backdrop fade, uninterrupted glimmer sweep and borderless
  cyan–green–purple AI chip compiled in the focused hover-lock test pass and a
  complete signed Release build. It was installed to `/Applications/Copi.app`;
  installed and build executable SHA-256 values matched
  (`33b0702785d58fb66834ab4c24cec74340d7b97663f1eae8acb912d1db829e59`).
- The group-level hover alignment compiled in signed Debug and Release builds. A
  real-use failure then exposed that the non-activating overlay was routing the
  new hover path only through Copi's local event monitor; the shared local/global
  pointer-routing correction compiled in the complete signed Release build. It was
  installed to `/Applications/Copi.app`; installed and build executable SHA-256
  values matched
  (`ff6464be9971aa019922025f4504cc6c5ed53411825a5b4e44f8d23497d87553`),
  the signature satisfied its certificate-based designated requirement, and the
  installed app was relaunched. Tracker tests and the installed-app pointer proof
  described above both pass; subjective physical mouse/trackpad feel remains for
  user evaluation.
- The complete application succeeded in an escalated Debug build. The ordinary
  sandboxed build could not run Swift compiler plugins; this was an environment
  restriction rather than a code failure.
- Live read-only Outlook inspection confirmed stable Editor, Send, To and Subject
  Accessibility landmarks are exposed without relying on field values.
- Signed Release builds succeeded using the stable Apple Development identity.
- The corrected command-overlay Always On Top lifecycle passed its focused pure
  dismissal-contract test and a complete signed Release build. In the installed
  app, the persisted checked preference opened the command overlay automatically;
  activating and clicking Calculator did not dismiss it, a controlled selection
  produced privacy-safe `pasteStarted`/`pasteCompleted` diagnostics for the active
  external destination, and Accessibility still reported the same overlay window
  afterward. New clipboard capture also appeared without reopening the overlay.
  The final build, including the widened explicit search-icon drag grip, was
  installed with matching build/installed executable SHA-256
  `aa7953485939c5dfeec8c28b8dc0f0e5d860a3c9bdca536d405d72383f232105`.
  That historical build has since been superseded by the final installed validation
  and matching executable hash recorded at the top of this section.
- The deployed app migrated the live learning database to schema v3; metadata-only
  verification returned SQLite integrity `ok` and the new source-event table was
  present. No clipboard payloads were inspected.

## Validation still required

- Open a controlled public HTTP(S) link and a YouTube link in the signed fixture/app and
  confirm the page paints, remains click-through-safe and does not autoplay; then confirm
  Up/Down, Space and Escape retain Preview navigation ownership.
- Evaluate the compact 56-point card density and pointer feel with a physical mouse
  or trackpad. Synthetic Computer Use checks cover both sidebar modes, scoped search,
  close-to-All reset, the horizontal-arrow path and reversible dynamic Preview sizing.
  Card hover is intentionally visual-only and cannot materialize another result set.
- Perform a fresh, controlled copy from Outlook after the latest deployment and
  verify the new entry records `sourceSurface=compose`, classifier `outlook-v2`,
  and shows Observed source location `Compose` in the hover card. Older source
  snapshots are intentionally not reclassified.
- Exercise Outlook Inbox/search, Apple Mail and Calendar with real interactions to
  expand classifiers only where stable metadata is demonstrated.
- The UI driver cannot reliably test Copi’s Carbon global hotkey because its
  synthetic app-directed keystrokes bypass the global handler; use a physical
  hotkey or an appropriate system-level test for end-to-end validation.

## Remaining ranking validation and tuning

- Run controlled physical-hotkey scenarios with repeated dispatched pastes in
  Outlook, Safari/Chrome, Apple Mail and Calendar; compare visible ordering with
  hover-card and database evidence.
- Measure first-frame and ranking p50/p95/max with real accumulated event volume.
  The scorer is bounded to 180 days and cached for the first frame, but production
  Instruments data remains the tuning authority.
- Tune weights, half-life or thresholds only from reproducible usage evidence;
  any change requires a new scoring-rule version.

## Important constraints and decisions

- Keep current clipboard row 1 regardless of ranking.
- Typing switches immediately to the normal searchable list.
- Favorites participate in suggestions, but manually persisted Favorite-category and
  Content Type card orders remain user-controlled and must not be reordered by suggestion
  learning. Type-filtered result lists stay in clipboard recency order.
- Source context must not read or persist control values. Browser hostname is the
  maximum retained URL detail and is suppressed for private/uncertain windows.
- Never infer a focused field that Accessibility did not establish; surface-only
  context such as Outlook Compose is still valuable.
- Weighted ranking intentionally permits strong broader evidence to outrank sparse
  exact evidence; specificity is heavily weighted but no longer lexicographic.
- Keep Accessibility capture within its deadline and display app-level context
  rather than delaying the overlay when an app is unresponsive.
- Preserve the stable signing identity across iterative installations.
- Preserve user changes in the dirty worktree; inspect before editing.

## Key files

- `copi/DestinationContext.swift` — bounded AX capture and semantic classifiers.
- `copi/SuggestionEngine.swift` — candidates, current promotion and scoring.
- `copi/SuggestionRanking.swift` — pure versioned scoring arithmetic and rules.
- `copi/SuggestionLearningStore.swift` — event schema, migration and persistence.
- `copi/CommandOverlay.swift` — overlay preparation, selection and paste initiation.
- `copi/OverlayPlumbing.swift` — target activation and paste dispatch.
- `copi/DiagnosticHoverCard.swift` — readable per-entry/context/ranking diagnostics.
- `copi/DiagnosticLog.swift` — structured privacy-filtered JSONL diagnostics.
- `copi/SecureStorage.swift` — passphrase-derived encryption and encrypted payloads.

## Build and deployment

Use the signed Release workflow in `README.md`. Keep the project’s Apple
Development identity; do not substitute ad-hoc signing. After installing, compare
the built and installed executable hashes, launch `/Applications/Copi.app`, and
verify the process/UI plus the newest diagnostic-log lifecycle event.
