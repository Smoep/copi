# Copi

Copi is a macOS menu bar clipboard manager built for fast paste-by-number workflows.

## Project documentation

- [Project status and cross-conversation handoff](PROJECT_STATUS.md)
- [Command overlay UI contract](docs/OVERLAY-UI.md)
- [Suggestion ranking: current destination-first behavior and migration history](docs/SUGGESTION-RANKING.md)
- [Engineering lessons](Lessons%20Learned.md)
- [Release history](CHANGELOG.md)

Future development conversations should begin with `PROJECT_STATUS.md`. Repository
guidance in `AGENTS.md` requires material changes and validation results to be
reflected in the handoff so planned behavior is never mistaken for deployed
behavior.

## Download Copi 2.0

[**→ Download Copi.zip from the latest release**](https://github.com/Smoep/copi/releases/latest)

Requires **macOS 26.4 or later**. Unzip and drag **Copi.app** to Applications.

> **First launch:** Copi is signed but not notarized. Right-click (or Control-click)
> **Copi.app**, choose **Open**, then confirm **Open**. Create the database passphrase
> Copi will use to unlock encrypted local history and Favorites on future launches.

See [what changed in Copi 2.0](CHANGELOG.md#200---2026-09-02).

## Why Copi
- Keep a searchable clipboard history for text and images
- Paste quickly from anywhere with a global keyboard shortcut
- Open a Spotlight-style command panel right at your cursor
- Filter by content type without leaving the keyboard
- Group frequently used snippets into favorite categories

## Features
- Menu bar app (runs in background)
- Menu-bar “Always On Top” toggle that keeps the command overlay open above other apps
- Clipboard history with configurable depth
- Compact macOS 26 Liquid Glass command panel with one scoped search field
- Context-aware suggestions that always keep the verified current clipboard first
- Scope filters for Favorites and the content types currently present, including Password
- Favorite categories with their own icon, colour and shortcut
- Scrolling results, with `⌘ 1`–`⌘ 7` addressing the seven visible rows
- Automatic content detection: Table, JSON, XML, Markdown, SQL, Code, Link, Email, File Path, Number, Image, Text
- Permanent manual content-type overrides, including an always-masked Password type
- SQL is recognised by actually parsing it (SQLite grammar with T-SQL normalisation), not by keyword guessing
- Code entries show their detected language, resolved lazily with highlight.js
- Favorite snippets with drag-and-drop between categories and explicitly Masked entries
- Image clipboard support with thumbnails and previews
- Optional plain-text pasting, with `⇧` to invert it for a single paste
- An optional diagnostic card after a 0.5-second row hover while Debug Logging is enabled
- Optional rotating JSONL debug logs with Reveal and Clear controls in Settings

## Context-aware suggestions

When the panel opens, Copi freezes the destination application and its useful
Accessibility metadata before taking focus. It has semantic classifiers for
Outlook mail and appointment editors, Apple Mail, Calendar, Safari and Chrome, plus a generic classifier for
other apps. Browser context keeps only the hostname—not the path, query or
fragment—and suppresses it whenever a Private/Incognito window is detected or
the browser's privacy mode cannot be established confidently.

Outlook sometimes exposes its focused window but no focused Accessibility
control. Copi still recognizes a compose surface from the window's stable
metadata and, when needed, a deadline-bound scan for compose landmarks such as
the To and Subject controls. That scan reads labels and identifiers only—never
recipient, subject, or message-body values. If Outlook does not respond within
the normal capture budget, Copi immediately falls back to application context.

New clipboard entries also retain a compact, encrypted copy-source snapshot:
the source application, semantic surface, and focused control (for example,
`Google Chrome · Browser page · Address bar`). In a confidently standard browser
window it may also retain the hostname, but it never reads a field's value or
stores a full browser URL; private or uncertain browser modes suppress the host.
Because clipboard changes are polled, the card labels this as the source observed
at the next poll (normally about 250 ms after copying, but potentially later when
the app is busy), not an infallible copy-event attribution. It keeps that observation
separate from the current paste destination;
older and startup-reconciled entries say that source location was not captured
instead of guessing it.

The verified current clipboard remains row 1. Copi learns from where an item was
selected and paste-dispatched, not where it was copied. A selection whose dispatch
fails remains weak intent evidence; a verified `⌘V` dispatch upgrades that same
event to full-strength evidence. Source-copy observations are a small capped
popularity prior and can never promote an item by themselves.

Historical destination use has a 45-day half-life and expires from ranking after
180 days. Exact, surface, application and global events enter one exclusive score
bucket with weights 40/15/5/1 and logarithmic diminishing returns. Context
confidence attenuates exact/surface matches. Learned promotion requires two
dispatched exact pastes, three cumulative surface pastes, or five cumulative
application pastes inside the 180-day window. Missing context never matches itself
as exact or surface evidence.

A few high-confidence destination controls provide cold-start suggestions:
Address bar prefers Links, recipient/invitee fields prefer Emails, and secure
fields prefer Passwords. Up to three semantic-only rows are admitted. Favorites
receive a small scoring prior but an unrelated Favorite does not crowd the default
All list merely because it was saved; Favorites remain available in their
categories. Suggestions preserve normal result text, and typing immediately
returns to normal searchable history. Favorite category and content-type sidebar
ordering remain explicit and static.

The learning database stores semantic context keys, HMAC candidate identifiers,
impressions, bounded destination-use events, dispatch outcomes, source-copy
evidence and timestamps. It does not store clipboard or Favorite text. The hover
card and optional JSONL log expose every effective count, score component,
eligibility rule and ranking-rule version. The exact model and migration behavior
are in [the suggestion-ranking specification](docs/SUGGESTION-RANKING.md).

## Passwords, masking and storage

- **Password** is a manual content type. It stays masked in results and never offers a
  Mask/Unmask action. A Favorite may have an optional name: Results and Preview use it
  as the visible title, otherwise they fall back to its content (masked when protected).
  Clicking a masked Preview explicitly reveals the value without enabling editing.
  After automatic paste, Copi restores the prior clipboard;
  if that prior clipboard is the same password, Copi clears it instead. Copying a
  Password from Settings expires it after 30 seconds if nothing else replaced it.
- **Mask/Unmask** is a separate shoulder-surfing control for ordinary favorites.
  It changes presentation, not the favorite's content type.
- Clipboard history, favorite metadata and payload files are encrypted before
  persistence with AES-256-GCM. The root key is derived from the launch passphrase
  and retained only in memory; locked or invalid storage fails
  closed without overwriting existing ciphertext.
- If encrypted storage becomes unrecoverable, Settings offers a confirmed secure
  reset instead of silently replacing the key or exporting an empty backup.
- Exported settings/favorites backups are AES-256-GCM ciphertext derived from a
  user passphrase; clipboard history is excluded.
- A password must briefly exist on the macOS pasteboard so the destination can
  receive `⌘V`. Copi minimizes that interval and uses pasteboard generation checks
  so an external copy or newer Copi paste cannot be overwritten by a stale restore.

The Copi 2.0 secure-storage migration intentionally starts legacy clipboard
history and favorites fresh once, rather than carrying plaintext-era records into
the encrypted schema.

## Diagnostics and permissions

While Debug Logging is enabled, the separate hover card explains the selected
entry, captured pasteboard formats, effective type/override, destination classifier,
suggestion counts and actual storage state. Disabling Debug Logging cancels a pending
card and closes one that is already visible. Password content is shown only in its
masked form.

Settings requests Accessibility Context and Automatic Paste Events separately.
Copi checks Automatic Paste Events before changing the pasteboard or closing the
overlay. A selection can therefore trigger the macOS permission request; if access
is declined, Copi explains that nothing was copied or pasted instead of failing
silently.
Debug logging is off by default. When enabled, Copi writes bounded, rotating JSONL
files (10 MB each, approximately 50 MB retained) with capture, context, ranking,
selection and paste outcomes. Logs never include clipboard/favorite payload text,
password text, passphrases or encryption keys, and can be revealed or cleared from
Settings.

Result-row context-menu edits update the visible overlay as the native menu closes,
without waiting for another mouse movement. Favorite Mask/Unmask also coalesces its
encrypted persistence work off the interaction path.

When Debug Logging is enabled, the overlay also records metadata-only type-hover
target changes, scope commits, result-materialization time, layout passes slower
than 16 ms, main-queue stalls of at least 200 ms, and one session summary. Raw
pointer coordinates and clipboard contents are never recorded. The helper script
can enable logging for the next launch, summarize the hover events, and save a
non-intrusive metadata report after the hang is observed:

```sh
scripts/copi-hover-diagnostics.sh enable
scripts/copi-hover-diagnostics.sh report
scripts/copi-hover-diagnostics.sh capture
```

The separate `sample 15` command attaches `/usr/bin/sample` for stack inspection,
but is deliberately not part of the first reproduction pass: on the current test
system the attachment can itself make Copi appear paused. Correlate any sample
window with watchdog timestamps before treating it as causal evidence.

Latency-sensitive paths also emit Points of Interest signposts for hotkey-to-first
frame, Accessibility capture, clipboard processing, suggestion preparation/ranking,
interactive search/refinement, Preview image preparation, persistence, and
selection-to-paste dispatch. Record
Copi with Instruments' Points of Interest template to compare p50/p95/max timings.
Accessibility detail capture uses a 60 ms traversal budget with 12 ms call caps and
falls back to application-level context if a call runs beyond the 75 ms ceiling.
Search publishes a cancellable quick pass within a 10 ms work budget, then refines
off the main thread. Clipboard polling remains at 250 ms.

## Shortcuts

| Key | Action |
| --- | --- |
| `⌘ J` | Open or close the panel (configurable) |
| `⌘ 1`–`⌘ 7` | Paste the entry in that visible row |
| `⌥⌘ 1`–`⌥⌘ 9` | Jump to Favorites, then the available content types |
| `⌘` + letter | Open a favorites category |
| `↑` / `↓` | Move through results |
| `←` / `→` | Open and move through `Types ↔ Favorites ↔ Results` when search is empty |
| `space` | Open or close the centered Preview before typing begins |
| `↩` | Paste the highlighted entry |
| `⇥` | Cycle scope filters |
| `⇧` | Invert plain-text pasting for one paste |
| `esc` | Close Preview first, then clear query/scope, then close |

The compact panel starts with its navigation panel closed. Its structure is an AppKit
`NSSplitViewController` with a native sidebar split item, pane-local SwiftUI hosting
controllers and a real `NSToolbar`—not a custom stack or a SwiftUI/AppKit hybrid.
Opening the sidebar uses AppKit's system split transition: the leading window edge,
Close control and `[Types | Favorites]` pill remain in place while the sidebar reveals
beneath them and moves the search/result detail column right. The sidebar contains a
scrollable two-column grid following Reminders' colored tiles. A card hover is visual
only; clicking a card or using the keyboard applies its filter immediately. The
borderless cards use subtle directional tint gradients; selection strengthens the
gradient and shadow without introducing a blue or drawn outline. Favorites has a
compact Add button at the bottom of the sidebar. It opens a native popover containing
the category name, a reliable Reminders-style color palette and an icon picker. A
card's context menu can create original Favorite text directly in that category,
reopen the category editor or offer guarded deletion. New Favorite opens a compact
optional-name/content/mask editor; it writes nothing until Add is pressed and detects
the content type automatically. The optional name becomes the Favorite's display title;
without one, content provides the title. User categories
can be reordered by dragging the whole card; an open hand becomes a closed hand while
the lifted card is engaged, the target brightens, and the persisted order updates on
drop. All Favorites remains pinned first.
Closing navigation clears the selected card/category and returns results and scoped
search to All Clipboard; an entered query, if any, is rerun against that full set.
Its width is resizable from 220–290 points and remembered. The two-column cards use
compact 56-point heights with symmetrical 8-point outer and inter-column spacing.
The grid scrolls with the wheel or trackpad whenever the pointer is over the sidebar;
the same gesture continues to page results when the pointer is over the result pane.
The icon pill uses compact 32-point segments, and the open-state search field aligns
with the Results list. When sidebar expansion would cross a screen's visible edge,
the native transition moves the whole overlay only by the overflow amount.
Initial placement clamps the final titled/toolbar window frame—not only its content
rectangle—to the cursor's visible work area, so the complete overlay remains reachable
at the Dock, menu-bar and side edges.

Results sit directly on the window surface instead of inside a second rounded card.
Seven contiguous 38-point rows use native-style hairline dividers, 8-point horizontal
and 4-point vertical outer spacing, while retaining the numbered multi-selection chips.
The overlay keeps this compact seven-row opening height throughout the session.
Opening navigation, switching cards and filtering results never resize it vertically.

For visual work, `scripts/copi-overlay-visual-fixture.sh` builds and launches a
Debug-only instance with a distinct bundle identifier and synthetic in-memory rows.
It skips the database passphrase and never reads clipboard history, Favorites or
learning data, making compact/open/sidebar screenshots safe and repeatable.

There is exactly one search field. AppKit's `NSSearchToolbarItem` owns the top-toolbar
field, focus, text selection and input-method behavior; it searches only the currently
selected card's result set. Its native blue focus ring is suppressed while the caret
continues to communicate typing focus. Toolbar and card selections return focus to that native
field on the next AppKit turn, so typing immediately filters the newly selected scope.
The existing numbered result chips remain
separate controls for ordered multi-selection and never paste merely because they
were clicked. Result-row hover updates the model in the same event turn, without a
pointer-intent delay. One transform-only backdrop glides between visible slots with the
original panel's 0.26-response spring; entry rows never join that animation, so wheel
paging does not move or fade list content. The capsule shows the hovered row's shortcut
with the original 17-point rounded keycap metrics, shifted five points inward on its trailing
edge, and replaces its leading magnifying glass with the native Shift symbol while
Shift is held. Hover geometry is
resolved in the visible top-origin Results coordinate system, so moving down the list
moves the highlight down rather than reflecting it vertically.

The result-row context menu can assign or clear a content-type override. A choice is
persisted when the row is stored, applied to the exact visible model snapshot
immediately, and reconciles counts, the active type filter and any entered search so
the displayed row and result set cannot remain stale. Ordinary clipboard-history rows
also offer Delete from History; deleting one removes its encrypted stored payload but
does not alter the current macOS pasteboard.

Preview is hidden by default and opens Finder-style in the active screen's centre
with a leading plain Space; once search has started, Space remains text input. Preview
is display-only. Opening it makes Preview the keyboard surface and freezes pointer-driven
result hover, so moving the mouse across Results cannot replace the displayed item.
Up/Down always navigates Results and refreshes Preview, Space toggles it, and Escape
closes it before the overlay's remaining dismissal layers. Its header
can be dragged like a normal title bar; later content resizing preserves the chosen
position. Text windows size
from their visible structure, so a word receives a compact panel while paragraphs,
code and tables grow within the screen bounds. Image windows preserve aspect ratio
and may grow or shrink for every selection; a manual resize wins for that overlay
session. Preview images and result thumbnails are read, decrypted, downsampled and
eagerly decoded off the main thread, with bounded display-size caches and a stable
loading placeholder. The full-resolution encrypted payload remains the paste source.
Masked values reveal only after a deliberate click and remain display-only. Favorite
editing is explicit: right-click one Favorite and choose **Edit Favorite…** to open the
same optional-name/content/mask form used for creation. Escape cancels it without saving;
Save updates Results and an open Preview immediately in one persistence transaction.
While either Favorite editor is open, it exclusively owns keyboard and pointer input:
Space inserts text, and mouse travel cannot change Results or dismiss the parent overlay.
The same input ownership applies to New/Edit Category. Search's native field editor is
not considered a modal editor: while its value is empty, the first Space opens Preview
and is not inserted into Search.

Suggestion learning never stores payload text. Equivalent history and Favorite values
share a keyed content identity for ranking/deduplication; the overlay now also merges
their strongest Password/Mask policy and safe label into every in-memory representation.
This prevents an unclassified history representation of a Password Favorite from being
chosen and displayed unmasked.

Suggested rows keep the normal result background and text color, with no entrance
sweep, glow or surrounding wash. Their numbered chip alone remains the glossy
cyan–green–purple AI cue; selection takes precedence and restores the standard
selected-chip appearance. Selecting a Favorite category or Content Type reuses the
overlay's initial staggered top-to-bottom result reveal. Its first row responds
immediately—only later rows are staggered—so an already-materialized result set never
looks as though it is still loading. Search typing updates without replaying that
animation. The search field keeps the active
scope or category in its high-contrast placeholder without adding a second title,
breadcrumb, filter row or search control.

The search icon uses AppKit's native window-drag gesture and the native title-bar
surface can reposition the overlay. Sidebar cards and other content do not drag the
window, preserving their native click, scroll and reorder gestures;
the text field itself keeps normal caret and text-selection behavior. The compact
Copi menu is one 36-point native macOS 26 `NSButton` using `.glass` bezel style and
the original `doc.on.clipboard` symbol at 13 points. It has no wrapping
`NSGlassEffectView`, duplicate toolbar-item image, disclosure arrow or second selection
ring. It opens the native menu containing
Always On Top, Settings and Quit. Enabling “Always On Top” from
either menu opens the command overlay immediately and keeps
it visible across outside clicks, app switches, hotkey presses, Escape at the
root view, and completed pastes. The setting is restored on launch. Each paste
refreshes the active external paste destination and starts fresh learning evidence
for that destination, while new clipboard captures refresh the pinned result list.
Turning “Always On Top” off closes the pinned overlay and restores normal transient
panel behavior. The Settings window is not pinned by this option. The overlay has
only a native Close control; closing a pinned overlay also disables Always On Top.

## Build & install

Requires macOS 26.4 and Xcode 26+.

```bash
git clone https://github.com/Smoep/copi.git
cd copi
xcodebuild -project copi.xcodeproj -scheme copi -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build-release build
ditto build-release/Build/Products/Release/Copi.app /Applications/Copi.app
open /Applications/Copi.app
```

Development builds must keep a stable code-signing identity. The project is set
to automatic Apple Development signing for its owner team; on another Mac, choose
one persistent Development Team in Xcode once and keep using it. Do not build with
`CODE_SIGNING_ALLOWED=NO` and then ad-hoc sign iterative installs: an ad-hoc build's
changing identity can invalidate Accessibility and Automatic Paste Events grants.

Copi's local encrypted database does not use macOS Keychain. On each launch, enter
the database passphrase once; the derived encryption key remains in memory until
Copi quits. Only the salt, derivation parameters, and an encrypted verifier are
persisted. Forgetting the passphrase requires starting the local encrypted store
again; external passphrase-encrypted backups remain independent.

## Built With
- Swift
- SwiftUI
- AppKit

## Search Keywords
macOS clipboard manager, clipboard history, menu bar clipboard app, clipboard manager, paste by number, Spotlight-style clipboard panel, global shortcut paste, clipboard favorites, image clipboard, snippets, pasteboard history, SwiftUI mac app
