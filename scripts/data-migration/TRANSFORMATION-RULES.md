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
4. **A field's declared type can lie about how much it holds.** `TextArea` in Salesforce metadata
   means a 255-character cap, identical to a single-line Text field, *not* "long text" — nothing
   about the label ("Description", "Current Status Summary") signals this. Before trusting a
   TextArea-typed field, check the longest real value in the export against 255; if it's close or
   over, that field needs a metadata fix (`LongTextArea`) before loading, not truncation. Two fields
   have hit this so far: Impediment's `Description`/`Talking Point` (255 cap vs. up to 1,210 chars)
   and Partner Account's `Current Status Summary` (255 cap vs. up to 9,590 chars, an ever-appended
   dated log). A plain `Text` field's declared `<length>` can be just as wrong — Partner Account's
   `Agreement Short Name` was `Text(10)` against real values up to 37 characters.
5. **The same Airtable *concept* can be spelled differently in two different tables.** Both the
   Accounts and Partner Accounts tables have a "Market Segment" column, and neither one's values
   match `LDGCRM_Market_Segment__c`'s 5 real names/external IDs in every case, but they mismatch
   *differently* — Accounts uses `"Defense & National Security"`, Partner Accounts uses `"Defense"`
   (the segment's real name, no mapping needed) but `"Finance & Regulation (F&R)"` (does need
   mapping). Don't assume a mapping table built for one table's version of a column applies to
   another table's column of the same name — check each independently. (This one was caught only
   after `Build-AccountReconciliation.ps1` was already built and "working" against a small sample —
   it hadn't actually been loaded yet, so no bad data resulted, but it's a reminder to check a
   transform's *values*, not just that it runs without error, before considering it done.)

**When writing a lookup or Master-Detail field's value into a CSV, the column header is not the
field's own API name.** Bulk API 2.0 resolves a parent by external ID only when the header uses the
relationship name (replace the field's trailing `__c` with `__r`) followed by `.` and the external ID
field: `LDGCRM_Account__r.LDGCRM_External_ID__c`, not `LDGCRM_Account__c`. A plain field-name header
is instead interpreted as a literal 15/18-character Salesforce Id — writing an Airtable `rec...` ID
under that header wouldn't upsert-via-external-ID, it would just fail as an invalid Id. Confirmed
against Salesforce's own docs: [Relationship Fields in a Header Row
(2.0)](https://developer.salesforce.com/docs/atlas.en-us.api_asynch.meta/api_asynch/relationship_fields_in_a_header_row__2_0.htm).
This was actually wrong in `Build-AccountReconciliation.ps1`'s first version (plain
`LDGCRM_Market_Segment__c` header) — fixed alongside gotcha #5 above, before any real load exercised
it. Every `Build-*.ps1` script's lookup columns should use this `__r.LDGCRM_External_ID__c` form.

When a transform script includes an explicit value-mapping table (like Impediment's `$CategoryMap`),
treat any value that doesn't match the map as a signal to stop and ask a human, not something to
silently blank out and move on from unnoticed — every script here logs unmapped/unmatched values to
a review CSV in `logs/data-migration/` rather than dropping them silently.

---

## Notes (deferred — final chunk, not built)

Freeform/journal-style Airtable columns that don't belong in a dedicated Salesforce field aren't
dropped — they become **`ContentNote`** records (confirmed via the Account layout's
`RelatedContentNoteList` related list: gsa-peo uses Enhanced Notes, not the legacy `Note` object),
attached to the migrated parent record via `ContentDocumentLink`. This has to be the **last** chunk
built, after every other object's records exist in gsa-peo — a Note can't attach to a parent record
that hasn't been created yet.

**Scope decision (2026-08-12, user-confirmed): forward-only, not retroactive.** Fields already
migrated as dedicated Salesforce fields — Partner Account's `Current Status Summary` (despite being
structurally an ever-appended dated log, exactly the shape this chunk is meant for) and Impediment's
`Description`/`Talking Point` — **stay as dedicated fields, unchanged**. This chunk only covers
note-like columns that don't have anywhere else to go. Don't revisit the already-built objects'
field mappings because of this.

**Mechanically different from every other chunk so far**: `ContentNote.Content` is a base64-encoded
body, and attaching a note to a record is a second object (`ContentDocumentLink.LinkedEntityId`) —
not a single-object CSV upsert like every `Build-*.ps1` script so far. Figure out the exact load
mechanics (Bulk API CSV with a base64 `Content` column is supported, but untested here yet) when
this chunk actually gets built.

**Candidate fields found so far** (from Partner Accounts' currently-excluded columns — re-evaluate
every other table's excluded columns the same way when this chunk is reached, don't assume this list
is exhaustive):
- **Strong candidate:** `Account Description` — genuine multi-paragraph freeform prose (e.g. "App
  Name: OneWYOPOC\nDescription: MAX is a driver services application...").
- **Moderate candidate:** `Known Blockers` — short phrases (`"N/A"`, `"None"`, `"Agreement
  Alignment"`, `"Unresponsive"`, `"Feature - IAL2"`), less prose-like than `Account Description` but
  still a distinct "type" of note per the user's framing.
- **Not a Notes candidate — flag as a separate open question instead:** `Escalated User Support
  Cases` looks like a linked-record field (`"Unnamed record"` placeholders, or a single Google Doc
  link) pointing at some Airtable table **not among the nine tables this migration currently pulls**.
  Needs its own investigation (does that source table need pulling at all?) before it's clear whether
  this becomes Notes, a real relationship, or gets dropped.
- **Ambiguous — decide when building this chunk, not now:** `Goals` has a small set of repeated
  short values (`"Add Identity Verification"`, `"Increase Adoption"`, `"Increasing IDV usage"`,
  `"Launch Large Applications"`) that read more like a controlled vocabulary than freeform notes —
  might deserve its own dedicated multi-select picklist field on Partner Account instead of becoming
  a `ContentNote`. Not every currently-excluded column is a Notes candidate; some may need a
  dedicated-field decision of their own, same as any other field.

**Heuristic for Title/Body (proposed, not yet implemented or user-confirmed in detail)**: one
`ContentNote` per (record, note-type-field) that has content, not one note merging multiple fields —
each Airtable "type" of note (Account Description, Known Blockers, etc.) stays its own distinct note
rather than being concatenated together, per the user's explicit instruction that each note's
original "type" has to be considered in how it's presented. `Title` carries the type label (e.g.
`"Known Blocker"`, `"Account Description"`); `Body` is the field's value close to verbatim. Revisit
this once real candidate fields across every table are inventoried — a single global heuristic may
not fit every table's shape (e.g. a dated running-log field, if one turns up elsewhere, likely needs
splitting into one note per dated entry rather than one note for the whole log — same idea already
flagged for `Current Status Summary` above, deliberately not applied there per the forward-only
scope decision, but worth reconsidering for other tables' equivalent fields when they're built).

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
| `Market Segment` (plain text, e.g. `"Infrastructure"`) | `LDGCRM_Market_Segment__c` (lookup, CSV column `LDGCRM_Market_Segment__r.LDGCRM_External_ID__c` — see General Principle above) | Value-mapped, **not** direct passthrough (fixed 2026-08-12 — see gotcha below): `"Defense & National Security"` → `"Defense"`, `"Finance (Regulation & Compliance)"` → `"Finance & Regulation"`, `"State & Local (SLTT)"` → `"State & Local"`; `"Benefits"`/`"Infrastructure"` already match and pass through unchanged. Works because `LDGCRM_Market_Segment__c.LDGCRM_External_ID__c` stores the segment **name**, not its Airtable `rec...` ID (the one deliberate exception to the external-ID-passthrough convention — see `CLAUDE.md`). All 6 Market Segments are already loaded, so every mapped value resolves. |
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
- **The Market Segment mapping above was a real bug in this script's first version**, caught only
  after the fact by comparing its output against gsa-peo's actual Market Segment records (not caught
  by running the script, since it "worked" without erroring — it just silently produced values that
  wouldn't have resolved on load). No harm done since Account had never actually been loaded yet at
  that point, but it's why every `Build-*.ps1` script's *values*, not just its exit code, need
  checking against real Salesforce data before considering it done. Also fixed the CSV header itself,
  which was the plain `LDGCRM_Market_Segment__c` field name instead of the `__r.LDGCRM_External_ID__c`
  relationship form required for external-ID resolution (see General Principle above) — this would
  have failed the load outright (invalid Id) rather than merely mismatching, so it likely would have
  been caught at load time regardless, but the value bug would not have been.

---

## Partner Account

**Source:** Airtable `Partner Accounts` table (99 rows as of 2026-08-12; the export file is named
`Partner Accounts.json` but the Airtable table's current display name is "Partners" — see
`CLAUDE.md`'s Airtable API section on why the pull keys off table ID, not name).
**Target:** `LDGCRM_Partner_Account__c`.
**Script:** `Build-PartnerAccountLoad.ps1`. **Mode: upsert on `LDGCRM_External_ID__c`**, but it
still queries Salesforce once (to resolve `Account Owner` — see below) unlike Impediment's fully
offline transform.

### Why this needs Account loaded first

`LDGCRM_Account__c` is a true **Master-Detail** to Account (not a plain Lookup — every Partner
Account requires a parent Account at insert time, and Salesforce enforces this). The CSV resolves
that parent via `LDGCRM_Account__r.LDGCRM_External_ID__c` (see General Principle above), which only
works once the referenced Account's `LDGCRM_External_ID__c` is actually populated in gsa-peo — i.e.
`Build-AccountReconciliation.ps1`'s output must be loaded first. Checked before building this script:
of the 76 distinct parent Accounts these 99 rows reference, 63 already carry the right external ID in
gsa-peo; the remaining 13 need the Account backfill loaded first.

### Market Segment is NOT set by this script — it's Flow-derived

`LDGCRM_Partner_Account_Before_Save_Create_Update_Market_Segment` (a before-save Flow, fires on new
Partner Accounts) already sets `LDGCRM_Market_Segment__c` automatically from
`$Record.LDGCRM_Account__r.LDGCRM_Market_Segment__r.Id` — copied straight from the linked Account's
own Market Segment. The first version of this script *did* set it directly (with its own value map,
mirroring Account's fix), which the user caught and corrected: don't populate a field an existing
Flow already owns, even correctly, since it's redundant (the Flow would overwrite it on insert
regardless) and needlessly reintroduces the value-mapping risk that bit `Build-AccountReconciliation.ps1`.
**This is not Partner-Account-specific** — Opportunity
(`LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment`, from `$Record.Account.LDGCRM_Market_Segment__r.Id`)
and Application
(`LDGCRM_Application_Before_Save_Assign_Market_Segment`, from
`$Record.LDGCRM_Partner_Account__r.LDGCRM_Account__r.LDGCRM_Market_Segment__r.Id`) have the same
kind of before-save Flow deriving Market Segment from their related Account. **Neither of those
not-yet-built transform scripts should set `LDGCRM_Market_Segment__c` either** — check for a
before-save Flow on the target object before assuming a field needs populating directly, the same way
you'd check a picklist's restricted values or a field's actual length.

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Partner Account Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough — the upsert key. |
| *(none — see gotcha below)* | `Name` (required `nameField`) | Sourced from `Agreement Short Name`, not a dedicated Name column (there isn't one) — see gotcha below. |
| `Agreement Short Name` | `LDGCRM_Agreement_Short_Name__c` (`Text`, length extended 10→50 — see gotcha below) | Direct passthrough — same value as `Name` above. |
| `Account Record ID` (linked, single value expected) | `LDGCRM_Account__c` (Master-Detail, CSV column `LDGCRM_Account__r.LDGCRM_External_ID__c`) | Direct passthrough of the linked Account's `rec...` ID. Rows with zero or more-than-one linked Account are skipped — see gotcha below. |
| `Active Account Folder` | `LDGCRM_Active_Accounts_Folder_URL__c` (`Url`) | Direct passthrough — checked all 75 non-blank values are genuine URLs first. |
| `Agency Summary` | `LDGCRM_Partner_Summary_URL__c` (`Url`) | Direct passthrough **only when the value looks like a URL** (`^https?://`) — matches this field's own description ("A link to the agency/partner summary documentation…") despite the misleading Airtable column name. 7 of 87 non-blank values are placeholder text (`"N/A"`, `"Not available"`, a bare state name like `"State of Wyoming"`) instead of real links — left blank rather than written into a URL field. |
| `Current Status Summary` | `LDGCRM_Current_Status_Summary__c` (`TextArea`→`LongTextArea`, length 131,072 — see gotcha below) | Direct passthrough. |
| `Initial Agreement Date` | `LDGCRM_Initial_Agreement_Date__c` (`Date`) | Direct passthrough — Airtable's `YYYY-MM-DD` format matches Bulk API's expected Date format exactly. |
| `Market Segment` | *(not written — see "Market Segment is NOT set by this script" above)* | Deliberately excluded: a before-save Flow already derives `LDGCRM_Market_Segment__c` from the linked Account. |
| `Account Complexity` | `LDGCRM_Partner_Account_Complexity__c` (restricted picklist) | Direct passthrough — all 5 distinct Airtable values checked against the field's 10 allowed values; all matched exactly, no map needed. |
| `Account Health` | `LDGCRM_Partner_Account_Health__c` (restricted picklist) | Direct passthrough — all 5 distinct values checked; all matched exactly. |
| `Account Owner` (object with `.email`) | `LDGCRM_Partner_Account_Owner__c` (Lookup to `User`) | **Resolved to a real Salesforce `Id`, not external-ID passthrough** — `User` has no external ID field to hang a relationship-header resolution on, so this is the one lookup in this script handled like Account's Owner-style reconciliation instead of a plain CSV passthrough. See gotcha below for the email-matching mechanics. |
| `Account Priority Level` | `LDGCRM_Partner_Account_Priority__c` (restricted picklist) | Direct passthrough — all 3 distinct values matched exactly. |
| `Login.gov Service Type` | `LDGCRM_Service_Type__c` (restricted picklist) | Direct passthrough — both distinct values used (`Authentication`, `Identity Verification`) matched exactly out of the field's 4 allowed values. |
| `Status` | `LDGCRM_Status__c` (restricted picklist) | Direct passthrough — all 3 distinct values matched exactly. |

### Fields deliberately excluded (no destination, or feed a different object/chunk)

Roughly 30 Airtable columns have no home on this object: rollup/computed counts (`# of Applications`,
`Account Health Score`, `IdV Application Count*`, `Months Since Last Meeting (from Account)`, etc.),
Airtable's own change-tracking columns (`(c) Account Health Change Date`, `(c) Current Status Summary
Updated`, …), and linked-record columns that drive *other* objects/chunks rather than this one
(`Contacts Record ID`, `Applications Record ID`, `Opportunities`, `Partner Portal Admin Confirmed` —
the last feeds `LDGCRM_Application_Contact__c`'s Partner Portal Admin flag per `CLAUDE.md`, not this
object). None of these were assumed-and-skipped without checking — each was confirmed to have no
corresponding field on `LDGCRM_Partner_Account__c` before being left out.

A handful of these — `Account Description`, `Known Blockers`, and possibly `Goals` — aren't
"no destination forever," they're candidates for the deferred **Notes** chunk (see the "Notes"
section above) or a not-yet-decided dedicated field. `Escalated User Support Cases` looks like a
linked-record column pointing at an Airtable table this migration doesn't currently pull at all —
flagged there as its own open question, not assumed to be a Notes candidate.

### Known data-quality gotchas

- **No Name column exists in Airtable for this table**, but `LDGCRM_Partner_Account__c.Name` is
  required. Two real candidates existed: `Tag` (Airtable's actual primary/title field, e.g.
  `"general_services_admin"` — but a snake_case slug, and missing on 9 of 99 rows) and `Agreement
  Short Name` (e.g. `"GSA-OSI"`, human-readable, present and non-duplicated on all 99 rows). Chose
  `Agreement Short Name` — a deliberate, user-confirmed decision, not a default guess, precisely
  because this table breaks the general pattern (every other table so far has had an obvious Name
  source).
- **Two fields were too short for real data, both fixed via `sfdx-metadata-sync` before this script
  was written** (same category as Impediment's fields, see General Principle #4):
  `LDGCRM_Agreement_Short_Name__c` was `Text(10)` against real values up to 37 characters (24 of 99
  rows affected — extended to `Text(50)`); `LDGCRM_Current_Status_Summary__c` was a 255-char
  `TextArea` against values up to 9,590 characters, an ever-appended dated log that will keep growing
  — converted to `LongTextArea` at 131,072 (Salesforce's max, not just 32,768 like Impediment's
  fields, specifically because this field's content only grows over time).
- **5 of 99 rows skipped for missing/ambiguous parent Account**: 4 have no linked Account at all (all
  `Inactive`/placeholder agreements — `USDT(inactive)`, `DOD-AFRL-Bifrost - placeholder`, `USACE`,
  `DOD-ARMY-CAC (INACTIVE AGREEMENT)`); 1 (`USDT-SSP`) links to *two* Accounts, and Master-Detail only
  supports one parent. All 5 written to `PartnerAccount-skipped-<ts>.csv` for human review rather than
  guessed at.
- **A real bug was caught while building this script's parent-Account check**: PowerShell's `@($null)`
  produces a **1-element array containing `$null`, not an empty array** — the first version wrapped
  the raw Airtable field in `@()` before checking `.Count -eq 0`, which meant the 4 rows with no
  parent Account at all silently passed the "missing" check (count was 1, not 0) and would have been
  written to the upsert CSV with a blank Master-Detail parent reference instead of being skipped. Only
  the genuinely multi-valued row was caught correctly. Fixed by checking `-not $RawValue` **before**
  wrapping in `@()`. Worth remembering for any future transform that checks a linked-record array's
  presence/count.
- **Owner email matching needed a sandbox-specific transform**: gsa-peo appends `.invalid` to every
  User's `Email` (standard Salesforce sandbox behavior, confirmed by querying `User` directly — a
  plain email match against the 7 distinct Airtable owner emails returned zero results until this was
  accounted for). Matched by querying `Email IN (<airtable-email>.invalid, ...)` and stripping the
  suffix back off to build the lookup key. 5 of 7 emails matched an active User; the other 2
  (`elizabeth.mays@gsa.gov`, `tony.parrilla@gsa.gov`) match no User at all in gsa-peo — those rows'
  owner is left blank (the field isn't required) and written to
  `PartnerAccount-unmapped-owner-<ts>.csv` for review, rather than the whole row being skipped.

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
