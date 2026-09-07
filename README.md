# Copi

Copi is a macOS menu bar clipboard manager built for fast paste-by-number workflows.

## Project documentation

- [Project status and cross-conversation handoff](PROJECT_STATUS.md)
- [Illustrated Copi help](https://smoep.github.io/copi/)
- [Command overlay UI contract](docs/OVERLAY-UI.md)
- [Suggestion ranking: current destination-first behavior and migration history](docs/SUGGESTION-RANKING.md)
- [Engineering lessons](Lessons%20Learned.md)
- [Release history](CHANGELOG.md)

Future development conversations should begin with `PROJECT_STATUS.md`. Repository
guidance in `AGENTS.md` requires material changes and validation results to be
reflected in the handoff so planned behavior is never mistaken for deployed
behavior.

## Download Copi 2.3

[**→ Download Copi.zip from the latest release**](https://github.com/Smoep/copi/releases/latest)

New to Copi? Read the [illustrated feature and settings guide](https://smoep.github.io/copi/).

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
- Menu bar app (runs in background) with a compact two-page template glyph matching
  the app icon's overlapping Liquid Glass pages
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
- Assigned Favorites show a dimmed, filled category-colored star that becomes vivid on direct hover; an unassigned row reveals a neutral filled star only when its trailing favorite target is hovered. The hand-pointer star menu assigns, moves or removes the item's single Favorite category.
- Auto, Light and Dark appearance choices apply consistently to every Copi window; Auto follows the current macOS system appearance.
- Optional **Start Copi at Login** control backed by the macOS login-item service.
- Image clipboard support with thumbnails and previews
- Read-only website previews for HTTP(S) links, including YouTube links
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
categories. Suggestions preserve normal result text. Typing in the default search
searches clipboard history plus every Favorite's optional name and content; scoped
Favorites and Content Type searches retain their own boundaries. Favorite category and Content Type sidebar
ordering are manual, persisted and never changed by suggestion learning. Content Type
results themselves remain in normal clipboard recency order.

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
is declined, Copi explains that nothing was copied or pasted and offers to open
**System Settings → Privacy & Security → Accessibility** directly. Turn on Copi there,
then quit and reopen it so macOS applies the event-synthesis grant.
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
| `⌘ F` / `⌘ T` | Open Favorites / Content Types; pressing the active panel's shortcut again closes it |
| `⌘ 0` | Return to All Clipboard, close the sidebar and focus Results |
| `⌘ D` | Open the highlighted result's Favorite-category menu |
| `⇧⌘ P` | Toggle Always On Top |
| `⌘ 1`–`⌘ 7` | Paste the entry in that visible row |
| `1`–`9` | Type in Search; otherwise activate the numbered sidebar card (`1`–`9`) or visible Result (`1`–`7`) |
| `⌥⌘ 1`–`⌥⌘ 9` | Jump to Favorites, then the available content types |
| `⌘` + assigned letter | Open a Favorite category or Content Type (`D`, `F` and `T` are reserved); a transient overlay intercepts it while its frozen paste destination remains frontmost, while a pinned overlay requires a key Copi panel |
| `↑` / `↓` | Move through results, or one sidebar row while the sidebar has focus |
| `←` / `→` | Open and move spatially through `Types ↔ Favorites ↔ Results`; within a sidebar row, move between its paired cards first |
| `space` | From a sidebar, focus Results; before typing or in Results, open or close Preview |
| `↩` | Paste the highlighted entry |
| `⌘ ↩` | Run the highlighted Link, Email or File Path Quick Action |
| `⇥` / `⇧⇥` | Move focus through search, Favorites, Content Types and the results |
| `⇧` | Invert plain-text pasting for one paste |
| `esc` | Close Preview first, then clear query/scope, then close |

Tab and Shift-Tab move keyboard focus through the search capsule, Favorites, Content
Types and the results. Landing on Favorites or Content Types opens that sidebar panel;
Tab never closes the sidebar, so a card you pick on the way keeps its filter. Only the
search capsule holds the text cursor. Hovering Search, a sidebar card, or a Result transfers
keyboard ownership to that area consistently. Sidebar hover does not activate its card or
change the current filter. Plain digits retain their local card/result meaning and
Results keeps Space for Preview; sidebar-owned Space enters Results instead of leaking into
Search. Typing any other printable character resumes Search at the
end of the existing query. Tab, Up from the first Result, or a direct Search click also returns
to typing. Sidebar arrows immediately activate the addressed card and refresh Results while
keeping keyboard ownership in the sidebar; Return, a plain number or Space hands ownership to
Results. Plain numbers also activate the indicated visible
Result. The first Down from Search enters Result 1, while Up from Result 1 returns to Search.
Search uses a fixed native field that remains a visible capsule after keyboard ownership leaves it.
Search, Favorites, Content Types and Results use a quiet neutral silver/gray glass edge rather
than the system accent blue. Favorites and Content Types place it around the complete
full-height sidebar—including its toolbar controls, cards, padding, empty space and Add control—
instead of an item-level keyboard border. Results uses the matching treatment around its content
surface, with its leading edge separated from the sidebar divider and aligned beneath the Search
capsule. The Sidebar edge slides and fades with native expansion/collapse; when it closes, the
Results edge fades in only after the native collapse completes and its compact geometry has settled,
so ownership outlines do not overlap. Keyboard
arrow navigation activates the addressed Sidebar card immediately, giving it the stronger selected
treatment while ownership remains in the sidebar and idle cards stay dimmer. The capsule's
trailing keycaps show the hovered/focused card or row number. Sidebar-card hover changes that
trailing number badge and selects the Sidebar area, without replacing the capsule text or
activating the card; dual actions use
a separator such as `3 / ⌘ ↩`. A Favorite category or Content Type with an assigned letter
shows its local card number followed by that shortcut, such as `3 / ⌘ L`; unassigned Type cards
retain the plain number. Hovering the toolbar icons shows **Open Favorites** with
`⌘ F` or **Open Content Types** with `⌘ T` in the capsule; hovering the row star shows
`⌘ D`, and hovering All Clipboard shows `⌘ 0`.

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
compact, circularly outlined Add button with a hand pointer at the bottom of the sidebar. Its menu offers New Favorite or New
Category. New Favorite opens the glass content editor immediately with a category
selector; New Category opens the same name, optional shortcut, color and icon editor used by Edit
Category. A Favorite category's context menu
can create original Favorite text directly in that category,
reopen the category editor or offer guarded deletion. A Content Type card's context menu
opens a shortcut-only editor. Both kinds share one collision-checked letter namespace;
category and Content Type assignments are optional and can be removed with **No Shortcut**.
Using an assigned category or type shortcut applies its filter, keeps the sidebar visible and
moves keyboard focus directly to Results. New Favorite opens a compact
optional-name/content/mask editor; it writes nothing until Add is pressed and detects
the content type automatically. The optional name becomes the Favorite's display title;
without one, content provides the title. User categories and Content Types can be
reordered by dragging the whole card. The cursor becomes a closed hand after the drag
engages, while the card does not lift, scale or gain a drag decoration. Cards move into
their row-major positions as the pointer crosses them, and the final order is persisted
once on release. Dropping outside the grid restores the original order. All Favorites
and All Clipboard remain pinned first. Content Types with no current entries are hidden
without losing their saved position.
Closing navigation clears the selected card/category and returns results and scoped
search to All Clipboard; an entered query, if any, is rerun against that full set.
Its width is resizable from 220–290 points and remembered. The two-column cards use
compact 52-point heights with symmetrical 8-point outer and inter-column spacing.
The grid scrolls with the wheel or trackpad whenever the pointer is over the sidebar;
the same gesture continues to page results when the pointer is over the result pane.
Precise trackpad input advances at most one result row per event and re-resolves the row
under the stationary pointer, preventing an accelerated event from replacing the whole
visible window or leaving its highlight attached to a different item.
The icon pill uses compact 32-point segments, and the open-state search field aligns
with the Results list. When sidebar expansion would cross a screen's visible edge,
the native transition moves the whole overlay only by the overflow amount.
Initial placement clamps the final titled/toolbar window frame—not only its content
rectangle—to the cursor's visible work area, so the complete overlay remains reachable
at the Dock, menu-bar and side edges.

Results sit directly on the window surface instead of inside a second rounded card.
Seven contiguous divider-free 36-point rows use 8-point horizontal and 12-point vertical
outer spacing while retaining the numbered multi-selection chips.
The overflow count at the bottom trailing edge is inset far enough to preserve the Favorite-star
target and never competes with that control.
The active Result row uses a subtle blue-glass fill. During Favorite-result reordering,
that highlight remains attached to the Favorite being moved rather than to its former index.
In Light Mode the row label keeps the same semantic primary color as unhighlighted rows;
the glass fill does not invert it to white.
The overlay keeps this compact seven-row opening height throughout the session.
Opening navigation, switching cards and filtering results never resize it vertically.

For visual work, `scripts/copi-overlay-visual-fixture.sh` builds and launches a
Debug-only instance with a distinct bundle identifier and synthetic in-memory rows.
It skips the database passphrase and never reads clipboard history, Favorites or
learning data, making compact/open/sidebar screenshots safe and repeatable.

There is exactly one search field. A fixed native `NSSearchField` toolbar view owns the
focus, text selection and input-method behavior; it searches only the currently
selected card's result set. Its native blue focus ring is suppressed while the caret
continues to communicate typing focus. A restrained appearance-adaptive shadow separates
the capsule from the toolbar, including in Light Mode. The native search-cell metrics remain,
but its system bezel drawing is suppressed so Copi can provide an opaque-white Light interior
without the darker default gray. The field owns typing on first open and regains it
through Tab, Up from Result 1, a direct click, or unambiguous printable input; toolbar/card
interaction otherwise keeps keyboard ownership with the visible sidebar or Results.
The existing numbered result chips remain
separate controls for ordered multi-selection and never paste merely because they
were clicked. Result-row hover updates the model in the same event turn, without a
pointer-intent delay. One transform-only backdrop glides between visible slots with the
original panel's 0.26-response spring; entry rows never join that animation, so wheel
paging does not move or fade list content. Because the overlay is non-activating, Results
wheel input is handled from both local and global event routes; scrolling therefore keeps
working after the pointer moves while the paste destination remains active. The capsule
shows the highlighted row's shortcut
with the original 17-point rounded keycap metrics, shifted five points inward on its trailing
edge, and replaces its leading magnifying glass with the native Shift symbol while
Shift is held. For a highlighted Link, Email or File Path, it instead names the Quick
Action and shows `⌘ ↩`: open in the default browser, compose in the default mail app,
or reveal in Finder. Hover geometry is
resolved in the visible top-origin Results coordinate system, so moving down the list
moves the highlight down rather than reflecting it vertically.

The result-row context menu can assign or clear a content-type override. A choice is
persisted when the row is stored, applied to the exact visible model snapshot
immediately, and reconciles counts, the active type filter and any entered search so
the displayed row and result set cannot remain stale. Ordinary clipboard-history rows
also offer Delete from History; deleting one removes its encrypted stored payload but
does not alter the current macOS pasteboard.

Preview is hidden by default and opens Finder-style in the active screen's centre
with a leading plain Space. Once search has started, Space remains text input while Search
owns the keyboard; after result hover, arrow navigation or sidebar selection hands ownership
to Results, Space opens Preview even with a non-empty query. Preview
is display-only. Opening it makes Preview the keyboard surface and freezes pointer-driven
result hover, so moving the mouse across Results cannot replace the displayed item.
Up/Down always navigates Results and refreshes Preview, Space toggles it, and Escape
closes it before the overlay's remaining dismissal layers. Its header
can be dragged like a normal title bar; later content resizing preserves the chosen
position. Preview and the main overlay are independent peer windows: dragging either one
does not move the other. Text windows size
from their visible structure, so a word receives a compact panel while paragraphs,
code and tables grow within the screen bounds. Image windows preserve aspect ratio
and may grow or shrink for every selection; a manual resize wins for that overlay
session. An HTTP(S) Link keeps its saved name and URL visible above the actual website,
which loads in a larger read-only WebKit surface only after Preview is deliberately opened.
The site cannot accept clicks, open pop-ups,
autoplay media or retain cookies and other website data between previews. Loading still
makes normal network requests to the site and its subresources, so the destination can
observe the request and IP address; merely highlighting or browsing a Link in Results
does not contact it. Invalid, non-web and failed URLs fall back to a safe unavailable/text
presentation. Preview images and result thumbnails are read, decrypted, downsampled and
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
Settings also provides application-wide **Auto**, **Light** and **Dark** appearance choices
and a **Start Copi at Login** toggle using macOS's login-item service. Auto follows system
appearance changes; explicit choices apply to the overlay, Settings, Preview and diagnostics.

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

Maintainers publishing a tagged download should follow the one-pass checklist in
[`docs/RELEASING.md`](docs/RELEASING.md). Release mode deliberately excludes new UI
testing and repeated builds when the current source is already validated.

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
