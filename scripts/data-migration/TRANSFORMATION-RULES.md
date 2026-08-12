# Airtable → Salesforce field transformation rules

This is the authoritative, field-by-field record of how each Airtable table's columns become each
Salesforce object's fields in this migration — every mapping decision, every excluded field, and
every gotcha discovered while building the `Build-*.ps1` transform scripts in this directory. When
in doubt about why a script does something a particular way, this is where the reasoning lives.

`CLAUDE.md`'s "Airtable → Salesforce mapping" section has the short cross-object summary (which
table maps to which object, load order); `scripts/data-migration/README.md` has the pipeline
architecture and build status. This document is the detail underneath both — add a new `##` section
here every time a `Build-*.ps1` script is built, before considering that chunk done.

## General principle (read this before writing a new transform)

**Never assume an Airtable column maps to a Salesforce field by name, shape, or the target field's
declared picklist values alone — verify against real data first.** Three ways this has already gone
wrong in this migration:

1. **A column's name can lie about its content.** Accounts' `States + DC/PR` sounds like it holds a
   state name; it's actually a boolean checkbox. Always open the actual JSON in
   `data/airtable-exports/` and look at real values before assuming.
2. **Salesforce's picklist metadata can lie about what's actually stored.** `Account.Type`'s
   `Federal` record type declares `"Federal Agency"` as a value, but 530 of 588 existing gsa-peo
   Accounts actually use the plain string `"Federal"` (the field isn't restricted, so old loads
   didn't have to conform to the declared set). Query existing Salesforce data
   (`sf data query ... GROUP BY <field>`) to see what convention is *actually* in production use,
   not just what the metadata declares is allowed.
3. **A restricted picklist will reject anything not an exact string match.** Impediments' `Category`
   column uses `"Issue on their end"` and `"Relationship Issue"` in Airtable; the target field
   `LDGCRM_Category__c` is a *restricted* picklist whose only valid values are `"Issue on partner
   end"` and `"Relationship issue"`. A passthrough load of either would fail the whole batch record.
   Restricted picklists need an explicit value map, checked against every distinct value actually
   present in the export (`Group-Object` over the field), not just the couple of examples in a
   sample record.

When a transform script includes an explicit value-mapping table (like Impediment's `$CategoryMap`),
treat any value that doesn't match the map as a signal to stop and ask a human, not something to
silently blank out and move on from unnoticed — every script here logs unmapped/unmatched values to
a review CSV in `logs/data-migration/` rather than dropping them silently.

---

## Account

**Source:** Airtable `Accounts` table (757 rows as of 2026-08-12).
**Target:** Salesforce `Account`, `Federal` record type only (no other record type is used, and
this migration never changes `RecordType`).
**Script:** `Build-AccountReconciliation.ps1`. **Mode: UPDATE, not upsert or insert.**

### Why Account is different from every other object in this migration

Every other object here is *created* by this migration (upsert-on-external-ID is safe because the
Salesforce record only exists because Airtable said so). Accounts are the opposite: they already
exist in Salesforce independently of Airtable — someone else created and has been managing them —
and in production most don't yet carry `LDGCRM_External_ID__c` at all. There is no reliable
external ID to upsert against yet, so this script's job is to *find* the matching existing Account
and backfill three fields onto it, never to create a new Account. Airtable rows with no confident
match are a decision for a human (see `CLAUDE.md`'s `Depart of Homeland Security` typo example),
not something the script auto-resolves.

### Matching algorithm

1. **External ID match** — if the Airtable row's `id` (`rec...`) already equals some existing
   Account's `LDGCRM_External_ID__c`, that's the match. No further logic needed.
2. **Exact Name match (fallback)** — among Accounts that do *not* yet have an external ID, look for
   one whose `Name` exactly matches the Airtable row's `Name` (case-insensitive, trimmed).
   - Zero candidates → **unmatched**, written to `Account-reconciliation-unmatched-<ts>.csv`. Not
     auto-created as a new Account.
   - Exactly one candidate → matched; claimed (removed from the candidate pool) so a second
     Airtable row with the same Name can't also match it.
   - More than one candidate → **ambiguous**, written to `Account-reconciliation-ambiguous-<ts>.csv`
     with all candidate Salesforce IDs listed. Not guessed at.
3. A matched Account is only added to the update file if something would actually change (external
   ID needs setting, Market Segment differs, or Type differs) — already-correct rows are counted but
   not re-written.

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Accounts Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough, only on matched rows. |
| `Name` | *(not written)* | Used only as the matching key in step 2 above — this script never overwrites `Account.Name`. |
| `Market Segment` (plain text, e.g. `"Infrastructure"`) | `LDGCRM_Market_Segment__c` (lookup) | Direct passthrough of the text value. Works because `LDGCRM_Market_Segment__c.LDGCRM_External_ID__c` stores the segment **name**, not its Airtable `rec...` ID (the one deliberate exception to the external-ID-passthrough convention — see `CLAUDE.md`). All 6 Market Segments are already loaded, so this always resolves. |
| `States + DC/PR` (boolean checkbox) | `Type` (standard picklist field) | `"State"` if checked, `"Federal"` if unchecked/absent. **Not a literal boolean-to-text cast** — confirmed by querying gsa-peo's existing `Type` distribution (`GROUP BY Type, RecordType.Name`): 54 Accounts already `Type="State"`, 530 already `Type="Federal"` (the plain string, not the `Type` picklist's nominal `"Federal Agency"` value — see General Principle #2 above), closely matching the ~52 Airtable rows with the checkbox set. Does not touch `RecordType` — every Account, State or Federal `Type`, uses the `Federal` record type. |

### Known data-quality gotchas

- **Sandbox Account count is a moving target, not a fixed baseline.** It moved from 531 to 588
  within the same day this migration work started (2026-08-12) — other people/processes touch this
  data. Don't hardcode a count anywhere; always re-query.
- **Airtable (757 rows) is not 1:1 with Salesforce (588 Accounts).** As of the last run, 343 rows
  matched and needed an update, 242 matched and were already current, and 172 had no match at all
  (0 were ambiguous, though 4 Airtable rows share a duplicate Name, so ambiguity is possible on a
  future run against different data). Never assume every Airtable Account row has, or should get, a
  Salesforce counterpart.
- **`LDGCRM_External_ID__c` is deliberately `unique=false`/`required=false`** on Account (unlike
  every other object, where tightening this is a live consideration) specifically so this
  reconciliation pass isn't blocked by the unmatched rows. Don't tighten it until reconciliation is
  fully resolved.

---

## Impediment

**Source:** Airtable `Impediments` table (41 rows as of 2026-08-12).
**Target:** `LDGCRM_Impediment__c`.
**Script:** `Build-ImpedimentLoad.ps1`. **Mode: upsert on `LDGCRM_External_ID__c`** (standard
convention — Impediment has no lookups to other objects, so it's created fresh like any other
non-Account object, and this script never queries Salesforce at all).

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Impediments Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough — the upsert key. |
| `Name` | `Name` (the object's required Text `nameField`, not autonumber) | Direct passthrough. Rows with no `Name` are **skipped**, not loaded with a placeholder — see gotchas below. |
| `Category` (free text) | `LDGCRM_Category__c` (**restricted** picklist, 3 values) | Explicit value map, not passthrough — see gotchas below. |
| `Description` | `LDGCRM_Description__c` (**LongTextArea** as of 2026-08-12 — see gotcha below) | Direct passthrough. Blank on 17 of 41 rows — that's fine, the field isn't required. |
| `Talking Point` | `LDGCRM_Talking_Point__c` (**LongTextArea** as of 2026-08-12 — see gotcha below) | Direct passthrough. Blank on 25 of 41 rows — fine, not required. |
| `Opportunities blocked`, `Opportunities requested` (linked-record arrays) | *(not handled by this script)* | Drive `LDGCRM_Opportunity_Impediment__c` junction rows in a later chunk, which needs Opportunity loaded first. Splitting these into one junction row per linked Opportunity happens there, not here. |

### Fields deliberately excluded (no destination, or destination forbids writes)

| Airtable field | Why excluded |
| --- | --- |
| `Blocked revenue`, `Requested revenue`, `Blocked Annual IdV users`, `Opportunities blocked (count)`, `Opportunities requested (count)` | No corresponding Salesforce field at all — these are Airtable-side rollups/computed columns. |
| *(Salesforce-side)* `LDGCRM_Blocked_Revenue__c` | A roll-up **Summary** field (`sum` of `LDGCRM_Opportunity_Impediment__c.LDGCRM_Blocked_Revenue__c`) — Salesforce computes this automatically from junction records and rejects direct writes to it. Populating the junction (a later chunk) populates this for free. |

### Category value map (restricted picklist)

| Airtable `Category` value | Salesforce `LDGCRM_Category__c` value | Notes |
| --- | --- | --- |
| `Product / Feature request` | `Product / Feature request` | Exact match already. |
| `Relationship Issue` | `Relationship issue` | Case differs (`Issue` vs `issue`) — a restricted picklist match is case-sensitive, so this would otherwise fail. |
| `Issue on their end` | `Issue on partner end` | Wording differs entirely, same underlying meaning. |

Any Airtable `Category` value not in this table is **not** silently dropped: the row still loads
(with `LDGCRM_Category__c` left blank, since the field isn't required) but is also written to
`Impediment-unmapped-category-<ts>.csv` for human review. As of the last run, all 39 loadable rows'
Category values matched this table (0 unmapped).

### Known data-quality gotchas

- **2 of 41 Airtable rows are entirely empty** — no `Name`, `Category`, `Description`, `Talking
  Point`, or Opportunity links, just zeroed-out rollup numbers. These look like accidental blank
  rows in Airtable, not real Impediments. Skipped (written to
  `Impediment-skipped-<ts>.csv`) rather than loaded with an invented Name, since `Name` is a
  required field with no sensible default here.
- **`LDGCRM_Category__c` is restricted** — confirmed by reading the field's metadata
  (`valueSet><restricted>true</restricted>`) *and* by checking the one existing test record in
  gsa-peo (`Test Impediment`, `Category = "Product / Feature request"`), which validated that string
  as the real, exact value Salesforce expects before trusting the mapping table above.
- **`TextArea` in Salesforce metadata does NOT mean "long text."** `LDGCRM_Description__c` and
  `LDGCRM_Talking_Point__c` were originally declared `<type>TextArea</type>` with no `<length>` —
  that's the plain "Text Area" field type, capped at **255 characters**, same as a single-line Text
  field just rendered as a multi-line box. It looks identical to `LongTextArea` in the UI and in a
  casual metadata read, and nothing about the field label ("Description", "Talking Point") signals
  the cap. The first real load attempt (2026-08-12) failed 13 of 39 rows with `STRING_TOO_LONG` —
  real partner-facing talking points and descriptions in Airtable run 500-1,500+ characters, well
  past 255. Fixed by deploying both fields as `LongTextArea` (`length=32768`, `visibleLines=6` — the
  data itself only needs ~1,200 chars max, so this is standard Salesforce headroom, not a size fitted
  to the content) via `sfdx-metadata-sync`, confirmed first that the Airtable source has no HTML
  markup to preserve (checked every Description/Talking Point value for tags/entities — zero found;
  what looked like `<br>` and `&quot;` in the Bulk API's *error message* for the failed rows turned
  out to be Salesforce's own error-text escaping of embedded newlines/quotes, not anything present in
  the source data or the generated CSV), so `LongTextArea` was the right call over `Html`
  (Rich Text). **Lesson: before building a transform against a TextArea-typed field, check its
  `<length>` — if there isn't one, or it's ≤255, verify against the longest real value in the
  Airtable export before assuming the field can hold it.**
- **Deploying this fix hit an unrelated org-wide blocker**: any `sf project deploy validate` (which
  runs tests) currently fails across the *entire* gsa-peo org due to a pre-existing Apex compile
  error in an unrelated FCIC-app class, unrelated to this migration. See `CLAUDE.md`'s "Operational
  gotchas" section — this will block any future metadata deploy that runs tests, not just this one.
