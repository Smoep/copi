# Copi repository guidance

## Required reading at the start of a conversation

Before planning or changing Copi, read these files in order:

1. `PROJECT_STATUS.md` — current handoff, deployed state, open work and validation.
2. `docs/SUGGESTION-RANKING.md` — current and agreed-next suggestion behavior.
3. `README.md` — product behavior, privacy, permissions and build instructions.
4. The relevant sections of `Lessons Learned.md` before touching an affected area.

Inspect `git status` before editing. The worktree may contain valuable in-progress
changes from earlier conversations; preserve unrelated changes and never assume an
untracked file is disposable.

## Documentation maintenance

After every material product, architecture, storage, context-capture, suggestion,
performance or deployment change:

- update `PROJECT_STATUS.md` with the new current state, remaining work, validation
  performed and the date;
- update the relevant design document when a decision or algorithm changes;
- update `README.md` when user-visible current behavior changes;
- add a durable lesson to `Lessons Learned.md` when the change reveals a reusable
  engineering or process lesson;
- clearly label planned behavior as **not implemented** until it exists and has
  been validated.

This repository documentation is the canonical cross-conversation handoff. A
session-memory note may supplement it, but must not be the only record.

## Stable terminology

- **Copy source**: the application/surface/focused area observed when an external
  pasteboard change is captured.
- **Paste destination**: the application/surface/focused area frozen immediately
  before Copi opens its overlay. This is the primary prediction context.
- **Selection**: the user chose an item in Copi. It is evidence of intent, but it
  does not prove that a paste event was posted or accepted.
- **Paste dispatched**: Copi verified the destination was active and posted `⌘V`.
  macOS does not confirm that the target consumed the data.
- **Exact context**: application + semantic surface + focused area, plus only a
  stable subcontext that is relevant to the focused area.

Do not use “source” and “destination” interchangeably in code, diagnostics or docs.

## Development environment

- Keep the same Apple Development signing identity for iterative installations.
  Do not deploy an ad-hoc-signed replacement over `/Applications/Copi.app`.
- Local encrypted storage uses the launch passphrase and a memory-only derived key;
  it does not use Keychain.
- Use the Release build/install commands in `README.md` for deployed checks.
- Never include clipboard payloads, password text, passphrases or encryption keys
  in tests, diagnostic logs, screenshots or handoff documents.

## Mandatory overlay UI validation

For every overlay layout, focus, border, hover or animation change, compilation and
off-screen fixture rendering are necessary diagnostics but are **not** visual approval.
Before saying the UI is fixed or asking the user to inspect it:

1. Build the Apple Development-signed Debug app. Debug must retain a bundle identifier
   distinct from Release; verify the built `Info.plist` rather than trusting project intent.
2. Launch the exact built app with the privacy-safe synthetic fixture, resolve its exact
   executable path, PID and WindowServer window ID, and verify the live window dimensions.
   Do not infer that `open` foregrounded the intended process when an installed Copi is running.
3. Capture the real on-screen window from WindowServer at original resolution. A SwiftUI/AppKit
   `cacheDisplay` snapshot may differ in vibrancy, private-frame offsets, pointer routing and
   focus ownership, so it cannot be the sole acceptance artifact.
4. Move the pointer outside the window before deterministic launch captures, then generate the
   actual mouse or keyboard event required for hover/focus states. Validate what the event path
   renders, not only controller state or requested launch flags.
5. Check the complete boundary-state matrix relevant to the change: collapsed and expanded,
   Search/Sidebar/Results ownership, first and final visible rows, and before/during/after any
   structural animation. Exercise real drag-and-drop whenever sidebar/grid identity changes.
6. Review captures at full resolution with a critical end-user eye. Explicitly reject any row
   highlight crossing an ownership edge, unequal optical margins, borders touching window edges,
   duplicate split/divider rules, clipped corners, misaligned Search/Results edges, or a final
   animation snap. Inspect all four sides, not merely the area changed in code.
7. If the live capture differs from the off-screen fixture or intended geometry, treat the live
   result as authoritative, fix it and repeat the matrix. Never call a visual change validated
   while noting a visible defect for the user to discover.

Keep the validated Debug preview open for the user. Do not make or install a Release build until
the user approves the live preview or explicitly asks for the final build.

## Release publishing

Follow `docs/RELEASING.md` exactly.

When the user asks to publish an already-validated build, enter **release mode**:

- treat product work and UI validation as complete unless source changes or an actual
  release check fails;
- do not perform UI automation, screenshots, research, redesign, repeated test runs,
  repeated builds, local reinstall or a post-upload download check unless the user asks;
- update the version, changelog and release records, run any validation that has not
  already passed for the current source, make one signed Release build, package and
  verify it once, then commit, push, tag and publish;
- use the deterministic release URL in `PROJECT_STATUS.md` before the release commit,
  so publication does not require a second documentation-only commit;
- if the release has not completed within five minutes, immediately state the exact
  active blocker rather than silently expanding the workflow.

Never publish local clipboard data, logs, passphrases, keys, derived data or temporary
captures. A proposed one-command release script is **not implemented**; do not claim or
assume that it exists.
