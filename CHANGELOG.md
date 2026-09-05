# Copi changelog

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
