# Suggestion ranking

Status: destination-first ranking rule v2 was implemented and validated on
2026-08-22. This document describes current behavior. The previous cumulative
lexicographic model is retained below only as migration history.

## Goal

Copi predicts which clipboard item or Favorite the user is likely to use in the
paste destination frozen immediately before a transient overlay opens. A pinned
Always On Top overlay may span several applications, so it captures the active
external destination and starts a fresh learning session immediately before each
selection; this prevents a later paste from being learned against the application
that was active when pinning began. The verified current clipboard remains row 1.
Typing replaces suggestions immediately with the normal searchable list.

The primary question is:

> Where has this item previously been used?

Copy source is provenance and a small broad-popularity prior. It is never treated
as the intended paste destination and never satisfies a contextual promotion
threshold.

## Stable terms

- **Copy source**: application and semantic context observed at the poll that
  detected a genuine external pasteboard generation.
- **Paste destination**: application and semantic context frozen before Copi
  opens a transient overlay, or refreshed before selection from a pinned overlay.
- **Selection**: the user chose an item. This proves intent, not delivery.
- **Paste dispatched**: Copi verified that the destination application was active
  and posted `⌘V`. macOS does not report whether the target consumed the data.
- **Surface**: a stable part of an application, such as Outlook Compose.
- **Focused area**: a stable semantic role, such as Recipient, Subject or Address
  bar.
- **Exact context**: application + meaningful surface + a reliable focused area
  and/or relevant stable subcontext.

## Current destination-first model

### Event lifecycle

A selection creates one destination-use event. If Copi later dispatches `⌘V`, the
same event is upgraded to dispatched; it is not counted twice.

| Final event state | Multiplier | Meaning |
| --- | ---: | --- |
| Paste dispatched | 1.00 | Strongest positive evidence Copi can verify |
| Selected, dispatch not observed | 0.25 | Intent without verified delivery |
| Impression only | 0.00 | Diagnostic exposure, never positive or negative preference |

Selection intent is recorded before Automatic Paste Events permission is
resolved. Permission denial and later activation/paste failures therefore remain
selection-only evidence. Source copies are stored separately.

### Exclusive scoring tiers

For each historical destination-use event, Copi compares its frozen destination
with the current frozen destination and assigns it to exactly one tier:

| Tier | Match | Weight |
| --- | --- | ---: |
| Exact | Same app + meaningful surface + reliable focused area/relevant subcontext | 40 |
| Surface | Same app + known semantic surface, excluding exact events | 15 |
| Application | Same known application, excluding exact/surface events | 5 |
| Global | Used elsewhere or current/historical app is unknown | 1 |

Missing information is not evidence. `unknown == unknown`, `focus:none ==
focus:none`, and two absent hostnames never create exact or surface matches.
Outlook Compose with no focused element is surface evidence, not exact evidence.

The weighted model deliberately allows sufficiently strong broader history to
outweigh sparse exact history. This replaces the old absolute lexicographic
dominance rule. Specificity receives substantially more weight but is not an
uncrossable band.

### Confidence, recency and diminishing returns

Context confidence describes the weakest evidence needed for the matched tier:

| Classifier evidence | Confidence |
| --- | ---: |
| Stable focused role or identifier | 1.00 |
| Stable structural landmarks | 0.85 |
| Window-title inference | 0.60 |
| Application identity | Lower application tier, full app-identity confidence |

For exact and surface matches, match confidence is:

```text
min(historical capture confidence, current capture confidence)
```

Every event has a 45-day half-life and evidence older than 180 days is excluded:

```text
recency = 2 ^ (-ageInDays / 45)
effective event = event multiplier × recency × match confidence
```

Let `E`, `S`, `A` and `G` be effective totals in the four exclusive buckets:

```text
destination score =
    40 × log2(1 + E)
  + 15 × log2(1 + S)
  +  5 × log2(1 + A)
  +  1 × log2(1 + G)
```

The logarithm provides diminishing returns. One event is assigned once; exact
evidence is not numerically repeated in surface, application and global buckets.

### Cumulative eligibility

Eligibility counters differ intentionally from exclusive scoring buckets. A
dispatched exact paste also proves use on its surface and in its application:

```text
exact eligibility count   = exact dispatches
surface eligibility count = exact + surface dispatches
app eligibility count     = exact + surface + application dispatches
```

A normal history item becomes a learned contextual suggestion after, within the
last 180 days:

- 2 dispatched pastes in the exact destination;
- 3 cumulative dispatched pastes on the same surface; or
- 5 cumulative dispatched pastes in the same application.

Selections without dispatch never satisfy these thresholds. Global use and
source copies never satisfy them.

### Small priors

```text
source popularity bonus = min(3, 0.5 × log2(1 + effective source-copy count))
Favorite bonus          = 3
strong type affinity    = 8
```

Source-copy evidence uses the same 45-day decay and 180-day window. The Favorite
bonus follows payload identity, so content saved as a Favorite retains the bonus
when its history representation is shown. Priors affect ordering but do not
satisfy learned-promotion thresholds.

Current affinity rules are:

- Address bar → Link
- Recipient or Invitees → Email
- Secure field → Password

Additional affinities require an explicit product decision and evidence from
real use. They are not inferred from raw window titles or clipboard text.

## Default-list assembly

1. Pin the verified current clipboard at row 1.
2. Score learned-eligible candidates and Favorites that have relevant
   exact/surface/application destination evidence.
3. Admit up to three semantic-only cold-start matches, guaranteeing one matching
   Favorite slot when available.
4. Sort the admitted suggestion pool by final score, then strongest matched tier,
   most recent relevant dispatch, and original order.
5. Append normal clipboard history in recency order.
6. Unrelated Favorites do not enter All merely because of the three-point prior.
   They remain in their categories; when clipboard history is empty, Favorite
   order is the fallback.

Equivalent Favorite/history payloads are deduplicated. Favorite category and Content
Type card orders are manually persisted and never learned. Selecting a Content Type
filters the normal clipboard-recency list; learned scoring does not reorder that list.

Deduplication also merges presentation safety by the same keyed content identity.
If any equivalent history/Favorite representation is a Password or explicitly masked,
every overlay snapshot for that identity is masked; Password protection and its safe
label take precedence over an automatically classified history representation. This
merge is in memory and does not copy payload text into the learning store.

## Relevant exact context

- Browser address bar: app + Browser page + Address bar; hostname is excluded.
- Browser page content: app + Browser page + focused area + hostname in a
  confidently standard window when available.
- Outlook Compose: app + Compose + Recipient/Subject/Body when known.
- Outlook Compose without focus: app + Compose at structural/title confidence;
  it is a surface match and Copi does not invent Body.
- Private/incognito or uncertain browser mode: hostname is never retained.
- Raw subjects, document names, paths, queries and arbitrary window titles are
  never learning-key components.

## Migration and storage

Learning schema v3 stores detailed selection events for the 180-day ranking
window and upgrades them idempotently with `dispatched_at`. It also stores bounded
source-copy events separately.

The SQLite learning store contains HMAC candidate identifiers and context evidence,
not clipboard/Favorite payloads. Clipboard history and Favorite content retain their
separate encrypted persistence and retention lifecycles.

The v2 migration is conservative:

- historical selections remain selection-only events with 0.60 legacy context
  confidence;
- no historical selection is invented as dispatched;
- existing global source-copy counts seed a capped source-prior record;
- encrypted clipboard/Favorite payload storage and HMAC candidate identities are
  unchanged.

Compact v2 cumulative rows remain for diagnostics/migration auditing, but rule v2
ranking uses detailed bounded events. Evidence outside 180 days is pruned.

## Explainability

The hover card and JSONL candidate-score events expose:

- current destination key, evidence and confidence;
- exclusive dispatched and selection-only counts per tier;
- recency/confidence-adjusted effective counts and each tier subtotal;
- cumulative exact/surface/application eligibility counts;
- destination subtotal;
- source count, effective count and capped source bonus;
- Favorite and semantic-affinity bonuses;
- final score, eligibility, placement reason, reference time and rule version.

Candidate identity remains HMAC-derived. Diagnostics never contain clipboard or
Favorite payload text, passwords, passphrases or encryption keys.

## Previous model — replaced on 2026-08-22

The previous implementation incremented exact, surface, application and global
aggregates for every source copy and every overlay selection. It used
`selectionCount + copyCount`, promoted after three interactions at exact/surface/
application scope, never decayed counts, and ranked with capped lexicographic
bands of `1,000,000,000 / 1,000,000 / 1,000 / 1`.

That behavior is no longer current. Its v2 aggregate data is not treated as proof
of paste dispatch.

## Validation

- Pure deterministic scoring tests cover exclusive buckets, cumulative
  thresholds, mutually exclusive event states, confidence, half-life, expiry,
  missing-context semantics and priors.
- SQLite integration tests cover v2→v3 migration, conservative legacy evidence,
  idempotent dispatch upgrades and source-copy storage.
- Debug and signed Release builds validate application integration.
