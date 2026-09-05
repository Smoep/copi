# Lessons Learned

## Tuning values that worked

- Idle memory target after lightweight pass: about 21 MB physical footprint.
- Previous idle footprint before lazy UI and disk-backed history: about 156 MB physical footprint.
- Pasteboard polling interval: 0.25 seconds with a main-queue `DispatchSourceTimer`.
- Menu bar preview can safely use the configured short preview length, tested at 6 characters.
- Current pasteboard preview cache: first 256 characters in memory.
- History item preview stored in metadata: first 512 characters.
- Text payload storage cap after disk-backed change: 10 MB per text item.
- Total stored text payload budget after disk-backed change: 50 MB.
- Rich pasteboard capture cap: 512 KB.
- Image payload cap: 4 MB per image.
- Total image payload budget after disk-backed change: 32 MB.
- Synthetic 300 KB text payload was successfully stored on disk with only metadata in UserDefaults.
- UserDefaults history after disk-backed migration measured about 89 KB JSON.
- Payload directory after migration and test measured about 3.1 MB.
- Overlay search backdrop sync debounce: 0.06 seconds.
- Connector line widths that read better: 2 pt normal, 3.25 pt highlighted.

## Things that caused problems

- Storing full clipboard history in UserDefaults caused high memory and slow search.
- Excel/table copies created very large plain-text clipboard payloads.
- A 200-item history with huge text entries produced about 25 MB of preferences data before compaction.
- Deriving the menu bar preview from `items.first` broke when oversized clipboard entries were skipped from history.
- `(NSApp.delegate as? AppDelegate)` was unreliable with SwiftUI `@NSApplicationDelegateAdaptor`; `AppDelegate.shared` worked.
- Repeated test markers starting with the same first 6 characters looked like menu bar failures because the visible preview did not change.
- Immediate plist reads can race `UserDefaults` flushing; rechecking after a moment confirmed saved history.
- `WindowGroup { ContentView() }` eagerly loaded the settings/history UI and raised idle memory.
- Opening the settings UI loads SwiftUI views and temporarily raises memory; this is expected.
- SwiftUI content placed as a child of `NSVisualEffectView` made overlay labels transparent.
- Search result numbering broke when selection used original history indexes instead of filtered results.
- Search rejected shifted symbols until printable character input was accepted.
- Plain `Timer` polling was less reliable during diagnostics than a main-queue `DispatchSourceTimer`.

## Build/run steps that work

### Stable Copi development signing

- Use the project’s Apple Development team and normal Xcode signing for every
  iterative install. Verify the installed app with `codesign -d -r- -vvv
  /Applications/Copi.app`; its designated requirement must be certificate-based,
  not `designated => cdhash ...`.
- An ad-hoc signature changes identity on every build. Historically that made a
  Keychain ACL prompt repeatedly, and it can still invalidate Accessibility or
  Automatic Paste Events grants, so it is not a stable development workaround.
- A permission failure must link to the macOS pane that owns the permission, not back
  to an app-local Enable button that repeats the same request. Name the exact
  **Privacy & Security → Accessibility** path, open it directly, and tell the user
  when macOS requires the app to be quit and reopened.
- Development payload encryption now uses a passphrase-derived, session-only key
  instead of Keychain. Persist only a random salt, bounded KDF parameters, and an
  AES-GCM verifier; never persist the passphrase or derived key. Unlock before
  constructing settings/history owners so passive rendering cannot trigger an
  authorization sheet.
- Apply observable UI state before scheduling an encrypted manifest save. A
  Keychain sheet or full-manifest encryption must not make a content-type choice
  look ignored; coalesce the save and flush it on termination.

- Release build:
  ```sh
  xcodebuild -project kopy.xcodeproj -scheme kopy -configuration Release -derivedDataPath build-release
  ```
- Deploy Release build to Applications:
  ```sh
  rm -rf /Applications/Kopy.app && ditto build-release/Build/Products/Release/Kopy.app /Applications/Kopy.app
  ```
- Relaunch normally:
  ```sh
  pkill -x Kopy || true && '/Applications/Kopy.app/Contents/MacOS/Kopy' >/tmp/kopy-launch.log 2>&1 & disown
  ```
- Relaunch with menu preview debug logging:
  ```sh
  pkill -x Kopy || true && KOPY_DEBUG_MENU=1 '/Applications/Kopy.app/Contents/MacOS/Kopy' >/tmp/kopy-launch.log 2>&1 & disown
  ```
- Measure current process memory:
  ```sh
  pid=$(pgrep -x Kopy | head -n 1); ps -o pid,rss,vsz,etime,command -p "$pid"; vmmap -summary "$pid"
  ```
- Sample idle activity:
  ```sh
  pid=$(pgrep -x Kopy | head -n 1); sample "$pid" 2 -file /tmp/kopy-sample.txt
  ```
- Inspect stored history size:
  ```sh
  pref="$HOME/Library/Preferences/com.jos.kopy.plist"; plutil -extract clipboardHistory raw -o /tmp/kopy-history.b64 "$pref"; base64 -D -i /tmp/kopy-history.b64 -o /tmp/kopy-history.json; wc -c /tmp/kopy-history.json
  ```
- Check disk-backed payload size:
  ```sh
  du -sh "$HOME/Library/Application Support/Kopy/History"
  ```
- Controlled clipboard test:
  ```sh
  marker="READYOK-$(date +%s)"; printf '%s' "$marker" | pbcopy
  ```

## Useful log messages and what they mean

- `[Kopy] menu bar preview updated: ABC123` means the status item update path ran and rendered that visible preview.
- `[Kopy] Global hotkey registered` means the Carbon hotkey registration succeeded.
- `[Kopy] Failed to register hotkey: <code>` means the global shortcut did not register.
- `[Kopy] Failed to install event handler: <code>` means the Carbon hotkey event handler did not install.
- `Physical footprint: 21.xM` from `vmmap -summary` confirmed the lean idle mode after lazy UI and disk-backed history.
- `Physical footprint: 130M+` after opening settings confirmed the SwiftUI settings/history UI was loaded.
- `ClipboardEngine.checkPasteboard()` in a `sample` confirms the pasteboard poller is firing.
- `ClipboardEngine.saveHistory()` in a `sample` confirms a clipboard item reached history persistence.
- `HistoryPayloadStore.writeText` in a `sample` confirms full text was written to disk-backed payload storage.

## Content classification (1.2.4)

### What works

- Classify SQL by **parsing** it, not by keywords: feed the text to `sqlite3_prepare_v2` against an
  in-memory database. An error of `no such table` / `no such column` means the grammar matched and only
  the schema is missing, i.e. it *is* SQL. `SQLite3` links without any project change.
- Normalise T-SQL before handing it to SQLite: `CREATE OR ALTER|REPLACE` → `CREATE`, strip
  `TOP n` / `TOP (n)` / `TOP n PERCENT`, `[ident]` → `"ident"`, `N'…'` → `'…'`, `ISNULL(` → `IFNULL(`.
- Accept the parser error `incomplete input` **only** when the text is known to be truncated.
- Some DDL never parses cleanly across dialects, so match its *shape* with a regex instead
  (`create|alter|drop|truncate` + optional modifiers + `table|view|index|procedure|…`).
- Scan up to 5 statement openings, but only in the first half of the text, so a note that merely
  mentions SQL later does not flip to SQL.
- Code detection needs both a symbol **density** (0.05) and an absolute **minimum count** (4).
  Density alone makes short prose like `Update last week:` look like code.
- highlight.js (34 grammars, ~127 KB, BSD-3) runs in `JSContext` for the *language label only*, resolved
  lazily on preview and cached per item UUID. Keep it off the classification hot path.
- Benchmarked per item at 2048 chars: 0.16 ms SQL, 0.58 ms Code, 0.37 ms prose. highlight.js was
  11–65 ms per item, which is 27× slower and unusable during history load.

### Things that caused problems

- The **512-character in-memory preview cap** was the dominant hidden cause of misclassification:
  everything was classified on truncated text. Raised to 2048, and truncation is now derived from
  `text.utf8.count < textByteCount` so it stays cap-independent.
- `contains("SELECT ")` is case sensitive, so lowercase SQL was never detected.
- Keyword lists like `"let "`, `"return "` match ordinary English sentences.
- `NLLanguageRecognizer` is useless here: prose, Swift and SQL all score English 0.76–1.00. Measured,
  then rejected.
- highlight.js ranked `vbnet` above `sql` on real queries; relevance ranking is not a classifier.
- The overlay type strip shows `commandMaxTypeButtons = 6` kinds. Slicing in **declaration order**
  meant `.sql` (10th of 12) could never appear. Pick the top kinds by **frequency**, then render in
  declaration order.
- Swift raw strings do not support `\` line continuation: inside `#"""…"""#` a trailing backslash is a
  literal character. It silently broke a multi-line regex. Build long patterns by `+` concatenating
  several `#"…"#` literals.
- Raising the preview cap made `isTruncated` false for the 31 items already stored at 512 characters;
  existing history keeps its old preview until re-copied.

### Process lesson

- Four rounds of failures were spent on invented test samples. The bugs only surfaced when the suite
  was rebuilt from the user's **real clipboard history JSON**. Test against real data first.
- Fixing *which* items a limit selects is not the same as fixing the limit. Ranking the type strip by
  frequency made SQL (22 items) appear and was declared done, but Email (2 items) was still cut by the
  6-button cap. Always check what falls off the bottom, not just that the reported case appears.

## Type strip ordering

- `ContentKind` declaration order is only the fresh-install default. The current sidebar
  shows present kinds in the user's persisted order and lets the whole card be dragged.
- Persist a complete type order, not only the currently visible subset. Empty kinds can
  disappear from the filtered sidebar and later return without silently moving.
- When a visible subset is reordered, replace only its occupied slots in the complete
  order. This preserves every hidden kind's relative position.
- Type-card ordering and type-result ranking are separate concerns. Manual card order
  does not justify learned ordering inside a type; scoped results remain clipboard-recency.

## Context learning, secure storage and delayed UI work

- “Overlay open” is not one Boolean state once preparation becomes asynchronous.
  Treat preparing and visible as one cancellable request generation, and reject
  every delayed callback whose window/model/session identity no longer matches.
- Force-reconcile the live pasteboard once at launch; use an ordinary `changeCount`
  reconciliation before later opens. Forcing every open can ingest Copi's own
  temporary Password/Favorite payload, while a genuine new copy already has a new
  generation. An initialization-time `changeCount` alone does not prove saved row
  1 is current.
- Learn from every selectable candidate, including favorites that are not yet
  eligible for the default list. Filtering a candidate out of presentation must
  not filter it out of selection accounting, or it can never reach the threshold.
- Copy-source provenance and suggestion learning are separate responsibilities.
  Refreshing a deduplicated row's source card does not teach the ranker unless the
  genuine external pasteboard generation also increments a source-copy counter.
  Copi-owned temporary paste writes remain excluded by synchronizing change counts.
- Provenance is not preference. Where an item was copied is a weak popularity
  signal; where it was selected and paste-dispatched is the primary prediction
  signal. Keep source-copy, selection-intent and dispatched-paste counters separate
  so one cannot silently stand in for another.
- Context specificity and context reliability are different dimensions. A focused
  field from a stable identifier can receive full confidence; a surface inferred
  from stable descendants can still be useful at lower confidence; a title-only
  inference should be weaker. Never manufacture a focused area from a known
  surface.
- Do not mechanically include every available attribute in an exact context. The
  current hostname is useful for browser page content but usually irrelevant when
  the address bar is focused, because it describes the page being left rather
  than the destination being entered.
- A missing `AXFocusedUIElement` does not mean an app exposes no useful context.
  Outlook compose windows still expose stable descendant identifiers such as
  `toTextField` and `subjectTextField`. Use a strict breadth/depth/time-bounded
  metadata scan, never `AXValue`, and keep an immediate window-title/app fallback.
- “Source location” is surface plus focused area, not focused area alone. When an
  app exposes a compose window but no focused element, show `Compose`; when it
  exposes both, show a value such as `Compose · Subject field`.
- Record impressions only after the panel is actually visible. Serialize session,
  impression, selection and end writes so a fast choice cannot overtake its own
  session creation.
- Specificity should receive much more weight, but absolute lexicographic dominance
  is not always the best predictor. With logarithmic 40/15/5/1 scoring, a strong
  repeated surface habit may intentionally beat sparse exact evidence. Record that
  as a product decision and test the crossover values instead of inheriting the old
  numeric-band invariant accidentally.
- Scoring buckets and promotion counters answer different questions. Partition
  each event into exactly one score tier to prevent double-counting, but calculate
  eligibility cumulatively because an exact paste also proves surface/application
  use. Diagnostics must show both views.
- Missing context is not a match: never let `unknown == unknown`, `none == none` or
  two absent subcontexts create exact/surface evidence. A known Compose window with
  no focused field is surface-only evidence.
- A selection and its later dispatch are one stateful, idempotent event. Upgrade
  selection-only intent to dispatched instead of inserting a second event, or a
  successful paste silently becomes worth 1.25.
- Decayed scores need bounded eligibility too. Lifetime raw promotion counters can
  keep a years-old item eligible after its score has vanished; use a fixed window
  for thresholds alongside smooth in-window decay.
- Aggregate count plus last timestamp cannot reconstruct historical exponential
  decay or dispatch outcomes. During migration, preserve detailed selections as
  weak intent, never manufacture dispatches, and limit unreconstructable copy
  totals to a separately capped prior.
- Version encrypted directories, manifest keys and envelope formats. Advance a
  plaintext-cleanup marker only after cleanup succeeds, and never generate a new
  Keychain key while ciphertext already exists.
- A global pasteboard is shared mutable state. Every delayed paste/restore needs an
  operation token plus the exact `changeCount` it owns; otherwise a stale restore
  can overwrite a newer user copy.
- Do not collapse hover selection, settlement and locking into one “delay.” They
  are separate interaction states. Preserve the control's existing initial hover
  response; pointer rest should arm protection, not start consuming it. Begin the
  short bounded protection window only when the pointer departs the settled choice
  toward a sibling—the moment accidental traversal becomes possible. Purposeful
  movement postpones arming, small jitter does not, and expiry must restore responsive
  hover without requiring another target or event. Keep logical regions independent,
  reset only lock state at their boundaries, and exclude controls such as the search
  capsule unless the product decision explicitly includes them. Keep click/keyboard
  activation immediate and describe the setting in terms of what it actually tunes.
- Equal timing values do not create equal interactions when controls receive
  pointer state differently. A continuous group-level tracker and independent
  child enter/leave callbacks can cancel and rearm the same state machine at
  different moments. When one group already feels correct, use its event topology
  as the behavioral reference instead of layering another timeout onto both.
- A non-activating overlay cannot rely on an application-local event monitor for
  pointer-driven behavior. Route one screen-coordinate handler from both local and
  global monitors because the destination app commonly keeps receiving mouse events.
- A visual button collection's interaction region includes its internal spacing.
  If hit-testing classifies every gap as “outside,” an armed hover lock is cleared
  before the pointer can reach the next sibling. Distinguish internal travel gaps,
  excluded controls and true region exits explicitly. Do not clear hover-driven
  scale or presentation state inside those gaps either: moving controls under a
  stationary pointer can create another transition and defeat the protected path.
- A temporary interaction guard needs visible feedback. When the real selection is
  intentionally held during pointer travel, render the latest candidate distinctly
  (subdued, not selected) and promote it directly when the guard expires. Reusing
  the control's initial hover delay after the guard ends makes the UI feel late and
  obscures why it is waiting.
- Interaction diagnostics must not become another source of main-thread pressure.
  Count raw pointer events in memory, persist target transitions rather than every
  movement, throttle slow-layout records, and allow only one outstanding watchdog
  ping. Correlate target, commit, materialization, layout and stall events by one
  overlay session ID without recording pointer coordinates or clipboard payloads.
- A SwiftUI model mutation performed by an `NSMenu` action is not sufficient visual
  confirmation in a nonactivating panel. AppKit runs menu tracking in a private event
  mode, so the changed row may remain stale until another pointer event. Keep the menu
  action's in-memory mutation synchronous, observe `NSMenu.didSendActionNotification`
  for the immediate presentation commit, and repeat at `didEndTracking` as a fallback;
  validate with screenshots taken while the pointer remains stationary.
- Validate the profiler as part of the experiment. `/usr/bin/sample` can visibly
  perturb a Release app while attached, so a watchdog delay matching the sample
  window is confounded. Reproduce with lightweight structured counters first,
  preserve that report, and attach a stack profiler only as an explicitly invasive
  second pass. An overlapping call graph can locate a hot subsystem, but its wall
  time alone cannot prove the unprofiled hang duration.
- Rapid selection bugs can be rendering bugs even when each data query is cheap.
  Correlate commits with total layout passes and inspect native-view lifecycle:
  replacing an animated SwiftUI subtree containing `TextField`/`TextEditor` for
  every selection can accumulate outgoing editors and synchronous draft loads.
  Measure result construction separately before adding latency to the selection UI.
- Debounce the expensive consequence, not visual acknowledgement. Keep the hovered
  control's selected state immediate and drive list/Preview content from a separate
  delayed scope. Cancel on every newer target and region exit, and use a generation
  token as well as `DispatchWorkItem.cancel()` so already-enqueued stale work cannot
  activate. Key result animations to the delayed scope; otherwise unchanged rows
  still animate for every transient visual selection.
- A debounce is load shedding, not a lifecycle repair. Test both sides of its timing
  boundary: a sweep faster than the interval proves stale work is cancelled, while a
  sweep just slower than it forces consecutive activations and exposes accumulated
  rendering work. Here, 50 ms passed the first case but a 65 ms sweep reproduced a
  13.1-second main-thread stall after nine result activations, confirming that the
  Preview editor/layout lifecycle still needs correction.
- Suggestion provenance does not need row-level motion when a compact, high-contrast
  numbered chip already carries the distinction. Keep the normal row surface and text,
  and avoid glow, surrounding washes and suggestion-specific animation; this makes the
  stable cue clearer and prevents it from competing with navigation transitions.
- Commit an encrypted manifest before pruning payloads. Cleaning encrypted orphans
  on a later successful launch is safer than deleting the previous generation
  while a preferences write may still be flushing.
- Check an object cache before accessing a file-backed encrypted computed property.
  A guard that reads/decrypts the payload before the cache lookup turns every visual
  cache hit into synchronous I/O even when no new image object is constructed.
- Caching `NSImage` is not the same as caching display-ready pixels. `NSImage(data:)`
  may defer decode until drawing; use Image I/O to create a display-sized thumbnail
  with immediate caching on a background task, cancel obsolete selection work, and
  bound the decoded-pixel cache by cost. Keep the original payload path separate for
  paste fidelity.
- Sizing, loading and rendering are separate stages. Use persisted metadata for the
  first window frame, never decode a payload merely to learn its dimensions, and
  show a stable same-geometry placeholder while a cold image prepares. This makes
  the unavoidable cold cost visible without allowing it to block pointer handling.
- Content-aware Preview sizing must be reversible: calculate every entry from its
  own bounded text structure or image aspect ratio. Distinguish real mouse-driven
  live resize from AppKit's programmatic frame animation, or the first growth will
  accidentally disable all later shrinking.
- `NSWindow.setFrame(..., animate: true)` can run a synchronous AppKit animation
  loop. Repeated content-driven window resizing then delays pointer delivery even
  when payload preparation is off-main. Use the window animator proxy with a short
  animation context so the event loop remains available between frames.
- A draggable borderless Preview needs a narrow explicit drag region, not
  `isMovableByWindowBackground`, which would steal gestures from editors and image
  controls. Preserve the dragged centre during later automatic resizes and clamp
  the result to the visible screen.
- Informative search placeholder text is part of the interaction contract, not
  expendable layout slack. Reserve its full width before revealing sibling scope
  buttons and increase contrast directly; shrinking the capsule hides the very
  feedback that explains the active filter.
- “Always on top” is a lifecycle contract, not only a window-level flag. A pinned
  overlay must account for every dismissal route (outside pointer/click, Escape,
  hotkey and post-paste cleanup), open immediately and on relaunch, refresh while
  it remains alive, and recapture both the active paste destination and its
  learning session before each selection. Applying the flag to a similarly named
  Settings window is a usability regression even when that window floats correctly.
- A native search field consumes drag gestures for caret and text selection.
  `isMovableByWindowBackground` cannot make that input a dependable drag surface;
  give the capsule a small explicit non-input drag handle so typing and selection
  remain native.
- Sidebar close semantics are a product contract, not an incidental consequence of
  split-view visibility. When closing navigation is defined as returning to All,
  reset the selected category, remembered type, placeholder and materialized result
  scope in one model transition; otherwise the compact toolbar and visible results
  can disagree. Preserve an entered query only by rerunning it against the reset scope.
- For a compact result picker, card hover should acknowledge the pointer without
  committing navigation. Click/keyboard activation eliminates speculative result
  materialization during rapid travel and makes the selection border an honest
  statement of the loaded result set. Remove any exposed timing setting once that
  timing path is no longer part of the active UI.
- System-app behavior comes from system structure, not a matching material. Before
  recreating Calculator or Reminders, inspect the accessibility hierarchy and the
  current SDK. An accessibility “split group” proves the runtime relationship but
  not that SwiftUI owns it. When exact toolbar/sidebar ownership matters, AppKit's
  `NSSplitViewController` plus a sidebar `NSSplitViewItem` provides the native
  splitter, titlebar integration and collapse transition without a custom `HStack`
  or parallel `NSWindow.setFrame` state machine.
- `NSSplitViewItem.CollapseBehavior.preferResizingSplitViewWithFixedSiblings`
  explicitly preserves sibling panes onscreen and may grow the window in either
  direction. For Copi it produced the correct continuous width curve but chose a
  right-edge-fixed expansion. Do not add a second width animator to counter it: two
  width owners produced pauses, reversals and a final snap. Let AppKit own width and
  preserve only the initial x-coordinate from `windowDidResize` for the short native
  transition. Verify both width and origin frame-by-frame away from screen edges;
  edge clamping can hide the mistake.
- A full-size hosting view includes unified-toolbar safe area, and converting from a
  window's base coordinates into a flipped SwiftUI hosting view changes the y-axis
  contract. Result hover hit-testing must use the converted view point plus
  `safeAreaInsets.top`; a pure top-origin row test prevents first/last-row reflection,
  while a live check must account for concurrent physical pointer movement.
- If the product needs an app-specific control before the native sidebar tracking
  separator, own the toolbar and split view in AppKit. Relying on SwiftUI's generated
  sidebar toggle and then searching for private toolbar identifiers is brittle; hiding
  it while separately rebuilding the toolbar can also create a hybrid layout pass.
- For current macOS design work, Apple's downloadable Landmarks Liquid Glass sample
  is a better visual baseline than a third-party Calculator/Reminders clone. Its
  sparse `NavigationSplitView`, native content and toolbar remain useful references,
  but they are not proof that the same root architecture fits a nonactivating utility
  panel with custom toolbar ordering. Select SwiftUI or AppKit ownership from the
  required behavior, then keep that shell single-owner.
- A design-system name is not a visual acceptance test. Before claiming parity with
  a system app, capture both running UIs and compare structure: shared window surface,
  control-to-panel alignment, which content moves, and where the revealed pane begins.
  Here, valid Liquid Glass modifiers still produced the wrong design because toolbar,
  sidebar and results were composed as three detached islands.
- Passphrase-gated UI needs a privacy-safe visual fixture. A Debug-only build with a
  distinct bundle identifier, synthetic in-memory rows and an activating inspection
  panel allows Computer Use to test compact/open states without reading or screenshotting
  clipboard history, Favorites, learning records or the development passphrase.
- Native toolbar and sidebar buttons become first responder when clicked, even if an
  `NSSearchToolbarItem` field was focused immediately beforehand. In a keyboard-first picker,
  restore the search focus asynchronously on the next AppKit turn after changing the
  scope; restoring it synchronously races the button action and silently leaves later
  typing unhandled. Prove this with a real click followed by literal typing, not only
  by checking that the placeholder changed.
- A SwiftUI `NavigationSplitView` cannot be treated as an interchangeable content
  child after replacing its generated toolbar with a separately owned AppKit toolbar.
  That hybrid produced competing sidebar/toolbar constraints, compressed the column,
  and made Copi compensate with manual window geometry. When the required Reminders-
  style order is custom controls, tracking separator, search and menu, make AppKit's
  `NSSplitViewController` the single shell, use a real sidebar `NSSplitViewItem`, and
  host SwiftUI only inside the two panes. Set the desired `isCollapsed` state through
  AppKit's animator. A relative `toggleSidebar:` call can lose parity when rapid input
  arrives during an in-flight collapse animation; a parallel panel-width animator can
  also fight the split controller. Keep one width owner and isolate any required
  spatial anchoring to origin only.
- A window-level scroll monitor must decide ownership in the destination view's local
  coordinate system. Comparing a screen point with an independently derived screen
  frame can look correct while still sending sidebar gestures to result paging. Convert
  the window point into the sidebar hosting view, test its local bounds, then return the
  event unchanged so the native `ScrollView` owns momentum and physics.
- A context-menu metadata edit has two consistency targets: durable storage and the
  overlay's value snapshots. Mutating only the singleton store leaves copied rows,
  counts, filters and active search results stale until a later reload—and makes a
  synthetic fixture silently no-op. Return the updated record from persistence, replace
  the exact snapshot immediately, then reconcile active scope and rerun search.
- `isMovableByWindowBackground` applies more broadly than an apparently empty visual
  background and can preempt a SwiftUI card drag before its minimum distance is met.
  Keep window movement on explicit title-bar/drag-handle surfaces when content owns
  click, scroll or reorder gestures, and regression-test both operations afterward.
- A popover containing a text field may initially leave focus in the toolbar search
  field while its field editor is being installed. Move focus asynchronously on the
  next AppKit turn; otherwise Return can activate the underlying result instead of the
  popover's Create action.
- Multi-display pointer automation is reliable only when window, screen and AX/CG
  coordinate spaces are deliberately aligned. Move a privacy-safe fixture to a known
  display and verify element frames before treating a failed synthetic drag as a product
  failure.
- `NSColorPanel` is a separate activating window and can fail to accept input when its
  owner is a nonactivating command panel. For a small Reminders-style choice set, keep
  accessible color swatches inside the owning popover; this also makes selection state
  deterministic and testable through Accessibility.
- A Reminders-style grid reorder is an arrangement interaction, not a lifted-card
  affordance. A closed hand may mark the engaged drag while card geometry stays stable;
  update a transient
  row-major order whenever the pointer crosses a new card, animate only the resulting
  layout positions, and persist once when the gesture ends. Retain the original identity
  order so an outside drop can cancel without writing intermediate arrangements.
- A native split transition needs edge-aware origin ownership. Preserve the leading edge
  while the expanded frame fits, but clamp each animation frame to
  `visibleFrame.maxX - currentWidth`; restoring the original x unconditionally at
  completion simply moves the final sidebar back offscreen.
- A matched-geometry selection can look excellent yet make every entry participate in
  SwiftUI layout. Preserve the motion with one transform-only backdrop instead: update
  model selection synchronously, animate only that backdrop, and limit entry views to
  color-only easing.
- Any implicit animation attached to an entry-owned row can become a scrolling bug when
  identity changes during manual wheel paging. Keep suggestion decoration in stable
  visible slots and selection in one separate transform layer; list content can then be
  replaced without inheriting either animation transaction.
- Rebuilding a SwiftUI keycap from AppKit label controls changes baseline, typography
  and spacing even when the nominal dimensions match. For a tiny established visual,
  reuse its exact drawing metrics instead of substituting a semantically similar control.
- Content-identity deduplication must merge safety metadata as well as ranking evidence.
  If an equivalent Favorite is Password/masked, choosing its automatically classified
  history representation must not weaken presentation. Keep payload stores separate
  when their lifecycles differ, but enforce the strongest privacy policy at the shared
  identity boundary.
- A Preview editor and Results list hosted in separate native panels need an explicit
  reconciliation/render commit. Updating encrypted persistence alone can leave a cached
  value snapshot visible until the next pointer event.
- Treat a secret's human-readable label as separate encrypted metadata. Keep the value
  masked until an explicit reveal action, permit editing only after that action, and
  re-mask after commit so an editor does not silently weaken result-list privacy.
- Deleting a clipboard-history record and changing the live macOS pasteboard are
  separate operations. A history context-menu deletion should remove its encrypted
  payload and model references without touching the current pasteboard.
- When a user asks to correct a toolbar control's chrome, preserve the established icon
  unless they explicitly request a symbol change. Container, scale and alignment are
  separate decisions from identity. Inspect the result at 1:1 pixels, but do not turn a
  visual diagnosis into an unsolicited branding change.
- A macOS 26 glass button is already a complete interactive surface. Do not wrap a
  glass-bezel `NSButton` in `NSGlassEffectView`, tint that wrapper, or also assign its
  image to the containing `NSToolbarItem`; those layers create a permanent selected fill
  and doubled outline. Match system-app scale from the AX hit target and visible control,
  then let the one native button own rest, hover, press and menu interaction.
- A compact native list should not be placed inside a second rounded surface when the
  containing window already supplies the material. Reminders' underlying AppKit
  table/outline-view architecture uses flat rows and separators. When reducing row
  height, update the single shared layout and pointer-geometry constants together,
  preserve one stable selection backdrop, and test exact first/last-row boundaries so
  visual compaction cannot create hover dead zones or mismatched selection.
- A titled full-size-content `NSPanel` does not have its final frame when initialized
  from a content rectangle. On macOS 26 the unified toolbar is realized when the window
  is ordered and can extend the frame by about 52 points below that requested origin.
  Clamp the ordered window's actual frame to `NSScreen.visibleFrame` in the same main-
  loop turn; content-size clamping alone can look correct in math while losing exactly
  the native-chrome strip at the bottom edge.
- A staggered entrance should acknowledge ready content with its first row immediately.
  A common base delay applied to every row creates a blank interval that users correctly
  perceive as result-loading latency even when the data is already materialized. Keep
  the stagger on subsequent rows, and capture timestamped first-open frames—not only a
  settled screenshot—to distinguish animation latency from preparation latency.
- Pointer-driven key-window transfer must yield to an active auxiliary workflow. When
  Preview is open, freeze result hover and make Preview the explicit keyboard surface;
  otherwise an ordinary mouse move can both replace the item being edited and steal its
  native field editor. Also scope global Space handling to the main/Preview panels so
  text entered into a category popover cannot be mistaken for the Preview shortcut.
- A direct-create menu should collect a complete draft before touching encrypted
  persistence. Binding the editor to its category up front gives the user context, while
  committing only on Add avoids abandoned empty Favorites and keeps Cancel truthful.
- A Finder-style Preview should not also be an editor. Making an auxiliary panel key
  while it contains editable SwiftUI controls lets a field editor claim first responder,
  which silently disables arrow navigation and can trap Escape. Keep Preview display-only,
  retain explicit reveal as a presentation action, and move mutation into a separately
  invoked, cancellable editor. Apply an optional Favorite name as title metadata for every
  content kind—not only Password—and fall back to content when the name is absent.
- A live Link Preview is a network action even when its surface is read-only. Start it only
  from the user's deliberate Preview command, use an ephemeral WebKit data store, suppress
  pop-ups, clicks and autoplay, and document that the destination and its subresources can
  still observe the request. Keep non-HTTP(S), credential-bearing and failed URLs on a
  bounded inert fallback so copied text cannot turn Preview into a general URL launcher.
  Keep local identity metadata (the saved name and URL) above the remote surface: the page
  can fail, redirect or obscure what the user originally saved.
- Alternate actions should reuse the content type already presented to the user. Name the
  exact action in the existing keyboard-feedback surface, keep Return as paste, and route
  Command-Return outside the pasteboard and paste-dispatch learning lifecycle.
- AppKit toolbar accessories do not automatically follow an observable SwiftUI selection model.
  Observe the highlighted entry's stable identity at the hosting-view boundary and explicitly
  refresh native toolbar state, including when keyboard paging replaces the visible row set.
- An empty default result list and its typed-search corpus serve different jobs. Keep the
  empty list tightly ranked, but make the default typed search global across clipboard and
  Favorites, including user-authored labels; otherwise saved metadata appears searchable
  in code while remaining unreachable from the overlay's launch state.
- A Favorite indicator describes saved content identity, not merely the row representation.
  When Favorite/history deduplication retains a clipboard snapshot, derive the marker and
  category colour from the same keyed identity or the UI contradicts the saved state.
- A trailing row affordance must not create a dead selection strip. Let the full row own hover
  selection, then give the nested star its own click and menu behavior. Category assignment
  should be singular: choosing another category moves the Favorite instead of duplicating it.
- Do not set a hover-revealed SwiftUI `Menu` to exactly zero opacity on macOS: it can fall out of
  hover tracking and become impossible to reveal. Preserve its tiny hit-tested rendering, and
  interaction-test the native menu selection—not only the resting screenshot—before deployment.
- Avoid placing `.glassEffect(.interactive())` on a SwiftUI `Menu` label: the glass interaction can
  consume the click while accessibility still reports a valid menu button. Use a non-interactive
  drawn background and verify that clicking visibly opens the menu.
- When an object-creation workflow needs a required classification, put that selector inside the
  creation editor instead of adding a submenu before the editor. This keeps `New Favorite` a direct
  action while still making its single category explicit and changeable before commit.
- Reserve category color for content that is actually assigned to that category. A hover-only Add
  affordance should stay neutral, or its color falsely implies saved Favorite state.
- Menu-label styling can discard or visually flatten custom-drawn backgrounds. Put the circular
  glass surface in a separate, non-hit-tested sibling behind the Menu, with a very low-contrast
  adaptive fill so it remains visible over both sidebar materials. Leave the enclosing Menu in
  charge of clicks; never add `.interactive()` to that visual layer, and verify both its rendered
  contrast and the opened menu before deployment.
- Do not force `.darkAqua` or SwiftUI Dark Mode on a transient overlay. Let the panel inherit the
  system appearance, use semantic label colors, and fixture-test both list and sidebar states in
  Light Mode; a material changing correctly does not guarantee hard-coded text remains readable.
- An intentionally keyless visual fixture cannot exercise production HMAC identity matching.
  Give only that Debug-only in-memory path a safe synthetic identity fallback, then assert the
  state after a menu-equivalent assignment; otherwise a real mutation can look like a dead menu.
- A SwiftUI popover hosted by a transient AppKit overlay needs explicit presentation state
  at the controller's event-routing boundary. The local/global monitors and a context menu's
  `didEndTracking` callback must all yield while that editor is open. Track its lifetime in
  the presentation binding, not the popover content's `onDisappear`: SwiftUI may rebuild or
  remove that subtree without the native editing session actually having ended.
- A search field's native `NSTextView` field editor is not evidence that the user has begun
  a modal editing workflow. In Copi it is first responder before the first character, when
  leading Space must still open Preview. Protect actual Category/Favorite popovers with
  explicit presentation state, and never require a nonactivating panel to be key before
  routing its local event; both shortcuts otherwise fail by silently inserting into Search.
- Pointer movement and wheel input can change event ownership independently in a
  nonactivating panel. Sharing mouse-move routing across local/global monitors is not enough:
  Results wheel paging needs the same dual route and one ownership/accumulator implementation.
  Validate this with physical input after moving the pointer; a generated `CGEvent` sequence
  may not reproduce WindowServer's real routing transition.
- Removing an overlaid list divider does not reclaim layout space. If the requested result
  is a denser list, change the one shared row-height metric as well and verify the window,
  backdrop, pointer boundaries and chip hit targets continue to derive from it.
- Release execution is not another product-validation phase. Once the current source has
  recorded passing validation, reopening UI automation, reinstalling repeatedly, extracting
  and downloading the same artifact multiple times, or making a second status-only commit
  adds latency without proportional confidence. Use one signed build and one local archive
  verification, write the deterministic release URL before committing, then push and publish.
  Surface a real blocker after five minutes instead of silently broadening the task.

- `marker-count=1` from a decoded history check confirms the controlled clipboard marker was stored.
