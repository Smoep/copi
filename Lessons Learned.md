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

- `marker-count=1` from a decoded history check confirms the controlled clipboard marker was stored.