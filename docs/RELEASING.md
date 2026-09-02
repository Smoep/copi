# Copi release checklist

This is the required fast path for publishing an already-validated Copi build. A release
packages and publishes completed work; it is not a new UI-debugging or research phase.

## Preconditions

- `PROJECT_STATUS.md` records validation for the current product changes.
- `git status` has been inspected and every pending file belongs in the release.
- The current Apple Development signing identity is available.
- The proposed `v<version>` tag does not already exist locally or on GitHub.

If source changes after its recorded validation, run the affected focused suites once.
Otherwise, reuse that recorded result and do not repeat UI or Computer Use testing.

## One-pass release mode

1. Select the next semantic version and increment the build number.
2. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in both Xcode build
   configurations, add the user-facing `CHANGELOG.md` entry, and update download or
   compatibility text only where it changed.
3. Update `PROJECT_STATUS.md` before committing. The release URL is deterministic:
   `https://github.com/Smoep/copi/releases/tag/v<version>`.
4. Run only validation missing for the current source. Do not restart product testing.
5. Make one signed Release build using the command in `README.md`.
6. Package `Copi.app` once with resource forks preserved:

   ```bash
   ditto -c -k --sequesterRsrc --keepParent \
     build-release/Build/Products/Release/Copi.app Copi.zip
   ```

7. Verify the local archive once: extract it into a new temporary directory, confirm its
   version/build, compare its executable hash with the build, run strict deep signature
   verification, and record the archive SHA-256. Do not reinstall the app merely to
   publish it when the same source was already installed and validated.
8. Commit the complete source and documentation, push `main`, then create the matching
   public GitHub release and upload `Copi.zip`.
9. Perform one remote metadata check confirming the tag, public release URL and asset
   name. Do not download the uploaded archive again unless upload integrity is in doubt
   or the user explicitly requests it.

## Scope and timing guardrails

- Do not use screenshots, Computer Use, UI fixtures, web research or design work during
  release mode.
- Do not rebuild or rerun a passing check without a source change or concrete failure.
- Do not create a second documentation-only commit after publication; record the
  deterministic release URL before the release commit.
- Aim to finish within three to five minutes. At five minutes, report the exact active
  blocker and continue only the work necessary to resolve it.
- Never package DerivedData, logs, screenshots, clipboard/Favorite content, passphrases,
  keys or local encrypted stores.

## Failure behavior

Stop publication if the build, version, signature, extracted hash, push or GitHub upload
fails. Report that exact failure and fix only it. Do not compensate by adding unrelated
validation or product changes.

## Planned automation

A one-command script that performs this checklist is **not implemented**. Until it is,
follow these steps manually in one uninterrupted pass and never claim the script exists.
