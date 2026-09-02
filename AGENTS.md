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

## Release publishing

For a public release, update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
both build configurations, add user-facing notes to `CHANGELOG.md`, and make the
README download/install requirements accurate. Run all focused executable suites,
build the signed Release, install and launch that exact app, and compare the built
and installed executable hashes before packaging.

Package `Copi.app` with resource forks preserved, verify the extracted archive's
version and signature, then commit and push the complete source before creating the
matching `v<version>` GitHub release and uploading `Copi.zip`. Record the tag, asset
checksum, release URL and validation in `PROJECT_STATUS.md`. Never publish local
clipboard data, logs, passphrases, keys, derived data or temporary captures.
