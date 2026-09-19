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

## Download Copi 2.4

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

The verified current clipboard remains row 1. The opening view shows at most five
results total. Search and category/type browsing are unrestricted; choose All Clipboard
in Content Types to browse full history. Copi learns from where an item was
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

## Copi 2.4 integrated overlay

Copi 2.4 has a 40-point compact header, centers the pointer in Search on opening,
and keeps the complete overlay inside the screen edges. Category creation and editing
are in the right-click menu; the plus button and redundant toolbar controls are removed.
Moving left/right into header approach zones unfolds
Favorites/Types inward over 200 ms. Up to eleven icon targets fit, with arrows/scrolling
for overflow. Clicking the native search field restores its width and keeps the scope.
A quick left/right movement during that animation still reveals the requested filters.
Slow continuous pointer movement also reveals filters; motion accumulates across events.
Passing over Search no longer takes keyboard focus; click, type or use keyboard navigation
to resume editing.
Prompts name the scope (“All items…”, “Work…”), without the word “Search”. The star sits
in a header with a 4-point outer inset; Close, the redundant Types button and enclosing focus outlines
are removed.

A slightly lifted neutral system material distinguishes the header from translucent Results,
without a divider or enclosing border.
There is no custom color tint. The original 36-point row spacing is retained with less
4-point outer padding around Results. Width stays 520 points; height adapts from a balanced four-row minimum
footprint to seven rows (192–300 points), keeping the header and first result anchored.
Reduce Motion skips structural animations; system accessibility settings govern material.

Double-click an empty Search to reset Favorites/type filtering. With entered text,
double-click keeps native selection. Escape clears active filters/query and returns to
All items; Escape again dismisses. An outside click also dismisses,
including Always On Top. Preview consumes its own first Escape, and native editors and
menus keep their interaction protection. Command-0 resets filters without dismissing.

Drag the empty center of Search to move the overlay; an ordinary click still focuses
Search, and entered text keeps native selection. Preview opens on whichever side has
more room, with a 12-point gap and width adjusted to fit. A manually moved Preview
keeps its chosen position.

Category/type reordering and context-menu editing remain available. Right-click the
header to add categories or favorites, or a category to edit/delete it. App actions remain in the menu-bar menu. See the
[interaction contract](docs/OVERLAY-UI.md). See [what changed in 2.4](CHANGELOG.md#240--2026-09-19).

## Shortcuts and overlay behavior

| Key / gesture | Action |
| --- | --- |
| `⌘ J` | Open the overlay (configurable) |
| Move left / right in header | Reveal Favorites / Content Types |
| Hover a filter icon | Show its results |
| `⌘ F` / `⌘ T` | Toggle Favorites / Content Types |
| `⌘ 0` | Reset to the five-result opening view |
| `⌘ 1`–`⌘ 7` | Paste the corresponding visible result |
| `↑` / `↓` | Navigate results |
| `Space` | Toggle Preview; inserts a space once typing in Search |
| `⌘ Return` | Open a Link, compose an Email or reveal a File Path |
| `⌘ D` | Open the selected result’s Favorite-category menu |
| `Escape` | Close Preview first; otherwise clear filters/query, then close |
| Double-click empty Search | Reset filtering |
| `⇧⌘ P` | Toggle Always On Top |

The [illustrated guide](https://smoep.github.io/copi/) covers search, filters,
Favorites, Preview, privacy and all keyboard shortcuts. The complete current
interaction contract is [docs/OVERLAY-UI.md](docs/OVERLAY-UI.md); the previous
sidebar contract is archived in [docs/OVERLAY-UI-V2.3.md](docs/OVERLAY-UI-V2.3.md).

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
