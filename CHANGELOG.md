# Copi changelog

## 2.4.0 — 2026-09-19

Copi 2.4 brings Favorites, Content Types and Search into one compact, translucent
header. Move your pointer to reveal filters and hover an icon to see its results.

### New UI

- Move left for Favorites or right for Content Types. Filters unfold inward with
  a short animation; overflow arrows and scrolling expose additional icons.
- The opening view shows at most five results total, including the current
  clipboard first. Search and category/type browsing retain access to the full
  collection; All Clipboard in Content Types shows complete recent history.
- A compact 40-point header and tighter result margins reclaim space. Neutral
  native materials separate the header from Results without an extra divider.
- Search regains its width when clicked, preserving the selected scope. Passing
  over it no longer steals keyboard focus from filter browsing.
- Preview opens on the side with more space. Drag the empty center of Search
  to reposition the overlay; populated fields retain native text selection.

### Smoother interaction

- Opening centers the pointer in Search and keeps the full overlay on screen,
  including near the bottom edge.
- Double-click empty Search to reset filters. Escape clears active filters/query
  first, then dismisses; Preview receives its own first Escape. Outside clicks
  dismiss the overlay, including while Always On Top is enabled.
- Right-click the header to add a category or Favorite. Category editing and
  deletion remain in the context menu; the old plus and redundant controls are gone.
- Slow pointer movement and movement during Search expansion now reliably reopen
  the filter strip. Reduced Motion and Reduced Transparency remain supported.

### Maintenance

- Removed unused legacy overlay code and enabled Release dead-code stripping.
- Updated the product website and guide with real screenshots of synthetic data.
- Requires macOS 26.4 or later. Signed with the existing Apple Development identity;
  not notarized. Existing encrypted data and launch passphrase are preserved.

## 2.3.0 — 2026-09-07

Copi 2.3 sharpens the native keyboard workflow, makes its floating surfaces easier
to arrange, and introduces a simpler visual identity shared by the app and menu bar.

### Added

- Auto, Light and Dark appearance choices now apply consistently across Copi, plus
  a native Start Copi at Login setting.
- Favorite categories and Content Types can leave their optional letter shortcut
  unassigned, and assigned shortcuts route directly into their Results.
- Preview and the main overlay can be positioned independently.

### Improved

- Search, Sidebar and Results now have explicit keyboard ownership with spatial
  left/right navigation and clearer shortcut feedback.
- Sidebar cards use a compact 52-point grid and live row-major reordering, while
  Favorite results keep their highlight attached during drag reordering.
- The Light Mode search capsule and selected Result text now preserve native contrast.
- Copi has a new two-page Liquid Glass app icon and a matching monochrome menu-bar
  glyph that remains clear at native size.

### Fixed

- Application appearance is applied without initializing encrypted Favorites before
  the launch passphrase is available.
- Trackpad paging is bounded to one row step per event, preventing accelerated input
  from causing an unbounded sequence of result replacements.
- Preview movement, overlay shortcut interception and sidebar-to-Results focus no
  longer depend on stale child-window or field-editor state.

### Upgrade notes

- Requires macOS 26.4 or later.
- The downloadable app is signed but not notarized. Control-click Copi.app and
  choose Open for the first launch.

## 2.2.0 — 2026-09-05

Copi 2.2 makes the overlay faster to operate from the keyboard, adds direct actions
for actionable clipboard content, and brings the interface to Light Mode.

### Added

- `Command-Return` opens Links in the default browser, starts an Email in the
  default mail app, or reveals a File Path in Finder. The Search capsule names the
  available action and shows its shortcut.
- Tab and Shift-Tab move focus through Search, Favorites, Content Types and Results;
  arrow keys navigate the focused two-column sidebar cards.
- The command overlay now follows the macOS system Light or Dark appearance.

### Improved

- Keyboard and pointer selection now share one highlighted row, so the Search
  capsule and numbered shortcut always follow the latest selection.
- Favorite assignment uses a compact native category menu. Assigned rows show a
  dimmed filled star in their category color and restore that color on hover;
  unassigned rows reveal a neutral star only over the favorite target.
- The Favorites Add control offers New Favorite or New Category. New Favorite opens
  its editor directly with a single category selector, while the plain `+` uses a
  subtle circular glass surface and hand pointer.
- Default typed search includes Favorite names and content without changing the
  empty-list suggestion ranking or scoped-search boundaries.
- Link Preview keeps the saved name and URL visible above the read-only website.

### Fixed

- Hover selection covers the complete result-row width, including its trailing edge.
- Native menu changes refresh immediately in the nonactivating overlay.

### Upgrade notes

- Requires macOS 26.4 or later.
- The downloadable app is signed but not notarized. Control-click Copi.app and
  choose Open for the first launch.

## 2.1.0 — 2026-09-05

Copi 2.1 makes links understandable at a glance and further tightens the native
overlay interaction.

### Added

- Link entries now load the actual HTTP(S) website in a large, read-only Preview
  after Space is pressed. Website data is non-persistent; clicks, pop-ups,
  autoplay and non-web navigation are blocked.
- Content Types can be reordered with the same live row-major interaction as
  Favorite categories. Hidden types retain their saved position.

### Improved

- Favorite and Content Type cards rearrange live as the pointer crosses them,
  preserve their normal geometry, persist once on release and restore their
  original order when a drag ends outside the grid.
- Results use denser 36-point divider-free rows while retaining seven visible
  entries, aligned hover geometry and the existing numbered selection targets.
- Type-filtered lists consistently use clipboard recency instead of an optional
  learned ordering mode.
- Automatic-paste permission guidance now opens the correct macOS Accessibility
  privacy pane and explains the required enable-and-relaunch steps.

### Fixed

- Results continue paging after the pointer moves while Copi's non-activating
  overlay leaves the paste destination active.

### Privacy

- Live Link Preview starts only after the deliberate Space command. Loading a
  website makes ordinary network requests to that site and its subresources;
  merely highlighting a Link does not contact it.

### Upgrade notes

- Requires macOS 26.4 or later.
- The downloadable app is signed but not notarized. Control-click Copi.app and
  choose Open for the first launch.

## 2.0.1 — 2026-09-03

Copi 2.0.1 focuses on a predictable Finder-style Preview and smoother direct
Favorite workflows.

### Improved

- Preview is now display-only: Up/Down always navigates results, Space toggles
  Preview, Escape closes it, and masked values retain deliberate click-to-reveal.
- Favorites can be created directly from a category and edited from a result row.
  Their optional name is used as the display title, with content as the fallback.
- Result sets begin rendering immediately and retain a lightweight top-to-bottom
  entrance instead of appearing to pause on first open.
- New/Edit Category and Favorite popovers now explicitly own keyboard and pointer
  input while open.

### Fixed

- Leading Space once again opens Preview from an empty Search field instead of
  being inserted as the first search character.
- Moving the pointer while editing no longer changes the underlying result or
  dismisses the overlay.
- Context-menu completion no longer steals focus from a newly opened editor.
- Preview focus remains stable while navigating, and Favorite saves refresh the
  visible Results and Preview immediately.

### Upgrade notes

- Requires macOS 26.4 or later.
- The downloadable app is signed but not notarized. Control-click Copi.app and
  choose Open for the first launch.

## 2.0.0 — 2026-09-02

Copi 2.0 is a major native macOS 26 redesign with encrypted local storage,
destination-aware suggestions and a substantially faster clipboard workflow.

### Highlights

- Rebuilt the overlay as a native AppKit split window with macOS 26 Liquid Glass
  toolbar controls and a Reminders-style Types/Favorites sidebar.
- Added a compact flat seven-row result list, immediate hover selection, numbered
  multi-selection, scoped search and smooth category result transitions.
- Added Finder-style Preview, toggled with Space, with content-aware reversible
  sizing, full image fitting, editable text/labels and explicit masked-value reveal.
- Added Favorite category creation, color and icon selection, context-menu editing,
  guarded deletion and drag-and-drop ordering.
- Added persistent Always On Top mode for a reusable clipboard workspace.
- Added destination-aware local suggestions using bounded semantic context for
  browsers, Outlook, Mail, Calendar and generic applications. Suggestion evidence
  stores keyed identities and metadata—not clipboard payload text.
- Added encrypted clipboard history, Favorite metadata and payload storage using a
  launch passphrase and a memory-only derived key, plus encrypted backup import/export.
- Added Password classification, independent encrypted labels, Mask controls and
  secure pasteboard restoration/expiration behavior.
- Added privacy-filtered diagnostics, rotating JSONL logging and performance signposts.

### Fixed

- Removed the rapid content-type hover hang by separating immediate visual feedback
  from bounded result and Preview activation, then eliminating expensive render work
  from hover-owned row subtrees.
- Result and sidebar scrolling, context-menu type changes, Mask updates and Preview
  edits now refresh immediately without waiting for another pointer event.
- Images are downsampled and eagerly decoded off the main thread, preventing Preview
  stalls and correctly fitting landscape and portrait content.
- The overlay's final native toolbar frame is now clamped to the complete visible work
  area, keeping every edge visible when opened beside the Dock, menu bar or screen edge.

### Upgrade notes

- Requires macOS 26.4 or later.
- Copi 2.0's encrypted-storage migration starts legacy plaintext-era local history,
  Favorites and suggestion counts fresh. External encrypted backup files are not
  modified.
- On first launch, create a database passphrase of at least 12 characters. The
  passphrase and derived key are never persisted; the key remains in memory until
  Copi quits.
- The downloadable app is signed but not notarized. Control-click Copi.app and choose
  Open for the first launch.
