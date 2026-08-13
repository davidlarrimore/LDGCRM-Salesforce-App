# Airtable → Salesforce field transformation rules

This is the authoritative, field-by-field record of how each Airtable table's columns become each
Salesforce object's fields in this migration — every mapping decision, every excluded field, and
every gotcha discovered while building the `Build-*.ps1` transform scripts in this directory. When
in doubt about why a script does something a particular way, this is where the reasoning lives.

`CLAUDE.md`'s "Airtable → Salesforce mapping" section has the short cross-object summary (which
table maps to which object, load order); `docs/README.md` has the pipeline
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
6. **A picklist's field-level values are NOT the values a record type will accept, and the API
   enforces the record type's narrower set.** `sf sobject describe` reports the field's full value
   set; if the object has more than one record type, that is not what a load can actually write. An
   Opportunity test batch failed 19/19 on two picklists whose values were "verified" against the
   describe output. When the target object has multiple record types, also read
   `objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml` — and note its `fullName` entries
   are URL-encoded (`,`→`%2C`, `/`→`%2F`, `(`/`)`→`%28`/`%29`, `&`→`%26`, `'`→`%27`), so compare
   decoded values, not raw strings. See the Opportunity section.
7. **A field's declared type doesn't mean it's writable.** `<type>Percent</type>` (or `Number`,
   `Text`, etc.) looks like a plain writable field, but check for a `<formula>` tag before mapping
   anything to it — Application's `LDGCRM_Level_1_Complete_Pct__c`/`Level_3`/`Level_4`/
   `Launch_Checklist_Completion__c` are all formula fields computed from other fields already being
   migrated; writing to them directly fails outright. Same instinct as checking a picklist's
   restricted values or a TextArea's real length — the declared type is necessary but not sufficient
   information before deciding a field is a normal migration target.

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

## Opportunity

**Source:** Airtable `Opportunities` table (928 rows, **72 distinct columns** as of 2026-08-13 — note
the first record only exposes ~35 keys, since Airtable omits empty fields per record; enumerate keys
across *all* rows, not just `[0]`, or you'll silently miss half the table).
**Target:** `Opportunity`, `Login_gov` record type.
**Script:** `Build-OpportunityLoad.ps1`. **Mode: upsert on `LDGCRM_External_ID__c`.** Queries
Salesforce read-only for the Login_gov RecordTypeId and the reconciled Account set.
**Loaded 2026-08-13: 742/742 succeeded, 0 failures** (after a 21-row test batch caught a blocker —
see below).

### The record type silently blocks picklist values — and the API DOES enforce it

**This is the most important finding on this object, and it contradicts a common assumption.** A
19-row test batch failed 19/19 with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on two fields whose
values were verified valid at *field* level:

| Field | Airtable needs | Login_gov record type exposed |
| --- | --- | --- |
| `LDGCRM_Opportunity_Type__c` | `OM - New Agreement` (433), `AM - Account Growth` (272), `AM - Renewal` (9) | only 5 generic TTS values (`New Business`, `Add-on/Mod`, `Follow-on`, `Renewal`, `Winback`) |
| `LDGCRM_Likely_Service_Level_Needed__c` | `Basic IdV` (232), `Authentication Only` (170), `Enhanced IdV (IAL2)` (82) | only `IdV, Auth-only` — a value that appears nowhere in Airtable |

**Lesson: `sf sobject describe` reports a picklist's FIELD-level values, which is not the set a given
record type will accept.** Checking the describe output — the habit that worked for every other
object — is *not sufficient* when the target has more than one record type. Read
`objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml` too, and remember its `fullName`
entries are URL-encoded (`,`→`%2C`, `/`→`%2F`, `(`/`)`→`%28`/`%29`, `&`→`%26`, `'`→`%27`) so a naive
string compare against field values will report false mismatches.

**Resolution (user-confirmed 2026-08-13): expose the 6 missing values on the Login_gov record type**
rather than dropping the fields or redirecting to the standard `Type` field. Justification, in order
of weight:
1. **This object's own revenue formula proves intent**:
   `LDGCRM_Est_Annual_Revenue_fully_ramped__c` = `MAX(IF(ISPICKVAL(LDGCRM_Opportunity_Type__c, "OM - New Agreement"), 30000, 0), …)`.
   The formula is keyed on a value the record type wouldn't allow anyone to select — self-evidently a
   record-type configuration gap, not a deliberate restriction. Verified post-load: 467 Opportunities
   now compute a non-zero revenue, which would have been 0 had the values gone to the standard `Type`
   field instead (the formula doesn't read `Type`).
2. The 3 service-level values are byte-identical to what `LDGCRM_application__c.LDGCRM_Service_Level__c`
   already uses in production.

Deployed via `sf project deploy start --metadata "RecordType:Opportunity.Login_gov" --test-level NoTestRun`
and **re-verified by re-running the identical test batch, which then passed 21/21** — not assumed from
a successful deploy.

### Three required standard fields, and only one has a complete source

`Name`, `StageName`, and `CloseDate` are required by the platform (the Login.gov business process
defines **no default stage**, so `StageName` must be supplied explicitly on every insert).

- **`Name` ← `Opportunity Name`** — present on all 928 rows, max length 100 against the standard 120
  cap. No handling needed.
- **`StageName` ← `Status`** — a clean passthrough: all 7 Airtable values (`Identified`,
  `Prospecting`, `Qualified`, `Scoped`, `Agreements`, `Closed Won`, `Closed Lost`) are exactly the 7
  stages in the Login.gov business process. **28 rows have a blank Status and are skipped** — they
  cannot load. Do **not** also map `Status` onto `LDGCRM_Status__c`: that field's Login_gov record
  type strips the six values that overlap, and it's a different concept (a granular sales-motion
  status, not a stage).
- **`CloseDate` ← a documented 3-step fallback.** Only 199 of 928 rows have `Est. Go Live`, and the
  gap is structural rather than sloppy: 524 of 531 `Identified` opportunities have none, because a
  go-live date isn't estimated until a deal qualifies. Since the field is mandatory, the script falls
  back `Est. Go Live` → `(c) Last Status Change Date` → `Created`, **always a real date from the
  record's own history, never invented**, and writes every fallback row to
  `Opportunity-closedate-fallback-<ts>.csv` (576 rows on the first load) so nobody mistakes these for
  real forecast dates. `Est. Go Live` is *also* mapped independently to
  `LDGCRM_Estimated_Go_Live_Date__c`, so the genuine estimate is never conflated with the synthesized
  CloseDate.

### Rich text fields need escaping AND `<br>` — they are Html, not LongTextArea

`LDGCRM_Current_Status_Summary__c`, `LDGCRM_Recent_Conversations__c` and
`LDGCRM_Estimate_Rationale__c` are **`Html`** (rich text) fields. This inverts the Impediment lesson,
where the fix was choosing LongTextArea *over* Html — here the fields are already Html, and writing
plain text into them loses data two ways:
1. **Bare `<`/`>`/`&` are parsed as markup.** 7 `Recent Conversations` values contain
   `<https://…>` autolinks that would vanish entirely, and 63 values across the three fields contain a
   bare `&`. Escaped first (`&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`).
2. **Newlines don't render.** All 559 `Recent Conversations` values and 119 `Current Status Summary`
   values are multi-line dated logs that would collapse into one unreadable paragraph. Newlines become
   `<br>` — **after** escaping, never before, or the generated tags get escaped too.

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` | `LDGCRM_External_ID__c` | Passthrough — the upsert key. |
| `Opportunity Name` | `Name` | Passthrough. |
| `Status` | `StageName` | Passthrough; row skipped if blank. |
| *(derived)* | `RecordTypeId` | The `Login_gov` RecordTypeId, queried at runtime. **Must be set explicitly** — Opportunity has two active record types, unlike `LDGCRM_application__c` which has one and could rely on the default. |
| `Est. Go Live` → `(c) Last Status Change Date` → `Created` | `CloseDate` | 3-step fallback, see above. |
| `Account Record ID` (linked array) | `AccountId` (CSV column `Account.LDGCRM_External_ID__c`) | `@(...)[0]`. Rows whose Account isn't reconciled in gsa-peo are **skipped**, not blanked — an unresolvable lookup fails the whole row. |
| `Opportunity Type` | `LDGCRM_Opportunity_Type__c` | Passthrough — after the record-type fix above. |
| `Focus Level` | `LDGCRM_Focus_Level__c` (restricted) | **Leading-token map**: Airtable embeds the review cadence in the label (`"High (2 month update)"`, `"Backlog (12 month update)"`); Salesforce stores just `Highest`/`High`/`Backlog`/`Developing`. Same shape as Application's Ramp Up Approach rule. |
| `Likely Service Level Needed` | `LDGCRM_Likely_Service_Level_Needed__c` | Passthrough — after the record-type fix above. |
| `Technical Readiness` | `LDGCRM_Technical_Readiness__c` (restricted) | `@(...)[0]` — a 1-element array. All 7 distinct values match the picklist exactly. |
| `Estimate source` | `LDGCRM_Estimate_Source__c` (restricted) | Passthrough — both values match exactly. |
| `Demographic Served` | `LDGCRM_Demographic_Served__c` (multiselect) | Array whose elements are themselves semicolon-joined (`"General Population; Gov?t Employees"`) — split on `;`, map, re-join. See the apostrophe note below. **No picklist expansion needed**, unlike Application: all 6 Airtable values map to the field's existing 6. |
| `Est. Go Live` | `LDGCRM_Estimated_Go_Live_Date__c` | Passthrough of the genuine estimate (distinct from CloseDate). |
| `Est. Annual IdV Users (fully ramped)` | `LDGCRM_Est_Annual_Idv_Users__c` | Passthrough. |
| `Est. Annual Auth-only Users (fully ramped)` | `LDGCRM_Est_Annual_Auth_Only_Users__c` | Passthrough. |
| `Est. Auth-only Avg Active Months` | `LDGCRM_Est_Auth_Only_Avg_Active_Months__c` | Passthrough. |
| `Est. First Year Ramp %` | `LDGCRM_Est_First_Year_Ramp__c` (`Percent`, scale 0) | **×100.** Airtable stores a 0–1 fraction (`0.5`); Salesforce Percent fields take the raw 0–100 number over the API. Rounded to a whole number since the field's scale is 0. This is the conversion that was moot on Application because every Percent field there was a formula — here it is live. |
| `App Description` | `LDGCRM_App_Description__c` | Passthrough — **after a metadata fix**, see below. |
| `Current Status Summary` | `LDGCRM_Current_Status_Summary__c` (`Html`) | Escape + `<br>`, see above. |
| `Recent Conversations` | `LDGCRM_Recent_Conversations__c` (`Html`) | Escape + `<br>`. |
| `Estimate rationale` | `LDGCRM_Estimate_Rationale__c` (`Html`) | Escape + `<br>`. |
| `Cost Estimate URL`, `Summary URL`, `Sandbox URL` | matching `Url` fields | Shared helper: strip Airtable's angle-bracket autolink wrapper (`<https://…>`), drop `N/A`/`None`/`TBD` placeholders, require `^https?://`, and blank anything over the 255-char platform cap. |

**The `Gov?t Employees` apostrophe trap (three different characters, one concept):**
- Airtable literally stores **`Gov?t Employees`** — an ASCII `?` (U+003F), on 25 rows. Confirmed *not*
  an export artifact: 82 curly apostrophes survive intact elsewhere in the same JSON file, so the
  corruption is in Airtable itself (logged in `AIRTABLE-DATA-QUALITY-REQUESTS.md`).
- `Opportunity.LDGCRM_Demographic_Served__c` (the target) uses a **straight** apostrophe `Gov't Employees` (U+0027).
- `Opportunity.Demographic_Served__c` (deprecated, not touched) uses a **curly** `Gov’t Employees` (U+2019).
- `LDGCRM_application__c`'s Global Value Set uses **`Gov't Employees (Contractors)`** — a different
  string again. **Do not share a Demographic mapping table between Application and Opportunity.**

### A metadata fix that WAS ours to make (unlike Name/Url)

`LDGCRM_App_Description__c` was `TextArea` with no `<length>` — the 255-char trap, hit for the third
time in this migration (after Impediment's Description/Talking Point and Partner Account's Current
Status Summary). 95 of 379 values exceed it, up to 1,711 chars. Deployed as `LongTextArea`
(32768/6 lines) before the load. Confirmed plain LongTextArea was right, not `Html`: the 17 values
matching an HTML-tag pattern are all angle-bracket-wrapped URLs (`<https://…>`), not markup.
**Contrast with `Name` (80) and `Url` (255) on Application, which are platform hard limits with no
`<length>` override** — always determine which kind you're facing before reaching for a metadata fix.

### Fields deliberately excluded

| Field | Why |
| --- | --- |
| `LDGCRM_Market_Segment__c` | Before-save Flow `LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment` derives it from `Account.LDGCRM_Market_Segment__r` on create and on any `AccountId` change. Verified post-load: all 742 populated. |
| `LDGCRM_Status_Summary_Modified_Datetime__c` | Owned by a before-save Flow that stamps it whenever `LDGCRM_Current_Status_Summary__c` changes. Any migrated value is stomped on the next update touching the summary, so writing it produces a misleading timestamp. |
| `LDGCRM_Days_Since_Last_Activity__c`, `LDGCRM_Est_Annual_Revenue_fully_ramped__c`, `LDGCRM_Est_First_Year_Revenue__c`, `LDGCRM_Status_Summary_Indicator__c` | Formula fields. The two revenue ones compute *from* the estimate fields this script does set, so Airtable's own revenue columns aren't migrated — they recompute themselves. |
| `priority_type__c` | Airtable's Priority Type values all exist at field level, but the Login_gov record type exposes **only a single malformed concatenated value** (`"HISP - High Volume, HISP - Lower Volume, Volume, Strategic, IDV Upgrade, Leadership Escalation"`). No valid target. Not force-fitted onto `LDGCRM_Level_of_Priority__c`, which is a different concept (Low/Medium/High). Flagged for the data owners. |
| `LDGCRM_Existing_Identity_Platforms__c`, `LDGCRM_Alternative_Identity_Platforms__c` | The Airtable columns hold `rec...` IDs pointing at a table this migration doesn't pull, while the Salesforce fields are multipicklists of vendor names. Unresolvable without that table — same open question as Partner Accounts' `Escalated User Support Cases`. |
| `LDGCRM_Partner_Account__c` | **Structural mismatch — deliberately left blank pending a team decision, not an oversight.** See the dedicated analysis below. |
| `Requested Features`, `Current Blockers`, `Opportunity Status Changes`, `Meetings`, `Opportunity Contacts`, `Applications` | Linked-record arrays that drive other objects/chunks (Meetings, OpportunityContactRole) or reference untracked tables. |
| `Market Segment`, `Market Segment (from Account Name)`, `(c) *` rollups, `Created By`, `Updated?`, `Months in Status`, `Meeting Count`, `(legacy data) *` | Airtable-side rollups/computed/system columns, or superseded by the Flow-derived Market Segment. |

### `LDGCRM_Partner_Account__c`: a structural mismatch, not a missing mapping

Raised 2026-08-13 by the user ("did you link up the partner account to the opportunity?"). The short
answer is no, and the reason turned out to be more interesting than a missed column.

**The Airtable Opportunities table has no Partner Account column at all** — so there is nothing to map
directly. (An earlier version of this script's header wrongly claimed the column existed but was
empty; reading a non-existent property in PowerShell just returns `$null`, which is
indistinguishable from an empty column unless you enumerate the actual key set. Corrected — and worth
remembering as a distinct failure mode from the `@($null)` trap: *"the field is empty"* and *"the
field doesn't exist"* look identical unless you check.)

The relationship does exist, from the **other** side, and in a shape Salesforce can't hold:

| Source of truth | Coverage | Shape |
| --- | --- | --- |
| Partner Accounts' `Opportunities` column | 961 links over **469** Opportunities | **many-to-many** — 146 Opportunities are claimed by 2+ Partner Accounts (max 8) |
| Applications (which link to both) | 82 Opportunities | one-to-one, but **disagrees with the above on 12** of them |

Salesforce's `Opportunity.LDGCRM_Partner_Account__c` is a single Lookup, so the 146 multi-linked
Opportunities are unrepresentable without a schema change. Against the 742 loaded records: 278 would
resolve cleanly, 104 are multi-linked, 360 have no link at all.

Populating it from the Applications path alone (the narrow, tempting fix — it is unambiguous for all
82) would have silently encoded the *minority* interpretation of the relationship, disagreeing with
the Partner Accounts table on 12 records and covering 11% of Opportunities. **Left blank on all 742
instead**, with the decision written up for the data owners in
`AIRTABLE-DATA-QUALITY-REQUESTS.md` — the three options being: treat the multi-links as data errors
and clean them up, add a real junction object to Salesforce, or confirm the lookup is redundant given
the Partner Account is already reachable via the Application (which is how `CLAUDE.md` describes the
intended model). Nothing is blocked meanwhile; the field is optional.

### Load results (2026-08-13)

742 of 928 rows loaded; **742/742 submitted rows succeeded**. Verified post-load: all 742 have the
Account lookup resolved, all 742 have Market Segment populated by the Flow, and 467 compute a
non-zero revenue. The 186 not loaded:

| Reason | Rows | Resolution |
| --- | --- | --- |
| Account not reconciled in gsa-peo | 142 | The duplicate/unmatched Airtable Account problem — fix the Accounts and re-run. |
| No Status (StageName required) | 28 | Needs a Status in Airtable. |
| No Account link in Airtable at all | 16 | Needs an Account link in Airtable. |

Re-running `Build-ApplicationLoad.ps1` afterward dropped its blank-Opportunity-link count from 92 to
7 and the reload wrote those links (85 Applications now linked to an Opportunity).

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

---

## Application

**Source:** Airtable `Applications` table (1,064 rows as of 2026-08-13; 78 columns).
**Target:** `LDGCRM_application__c`, `LDGCRM_Application` record type (the object's only active
record type — "Master Login.gov Record Type" per its own description, so every migrated row uses
it; no record-type decision logic needed here, unlike Account's Federal-vs-State split).
**Script:** `Build-ApplicationLoad.ps1`. 55 Salesforce custom fields on this object; this is the
largest/most complex table mapped so far, investigated carefully before writing any code per the
user's explicit request. Built 2026-08-13; its **first real load attempt failed 1,045 of 1,047 rows**
— see the post-mortem section below for all four causes and what changed as a result. The script now
also queries Salesforce for the set of Partner Accounts that actually exist before writing its CSV
(it is no longer a purely offline transform), so rows whose parent Partner Account is missing are
skipped up front rather than submitted as guaranteed Bulk API failures.

### Demographic Served — picklist expansion (heavily documented per explicit request)

**The problem:** Airtable's `Demographic Served` (multi-value) uses 32 distinct categories across
913 of 1,064 records (85.8% of all Applications; 1.39 categories per tagged record on average, up to
7 on one record). `LDGCRM_Demographic_Served__c` is a `MultiselectPicklist` backed by the
**`Demographic_Served` Global Value Set**, which originally had only 6 values: `Federal Employees`,
`General Population`, `Gov't Employees (Contractors)`, `Government Employees (Military)`, `Non-USC`,
`Veterans`. Only 4 of Airtable's 32 categories matched a picklist value exactly; loading as-is would
have silently dropped tagging on 400 of the 913 tagged records (43.8%).

**Step 1 — ruled out "these are just old/unused categories."** Cross-referenced every category
against its Active-status rate and median Application go-live year, looking for a pattern where a
category skews toward old/decommissioned applications (which would suggest it was abandoned):

| Category (top 10 by volume) | Records | % of all Applications | % Active | Median go-live year |
| --- | --- | --- | --- | --- |
| General Population | 428 | 40.2% | 82.0% | 2023 |
| Federal Employees | 338 | 31.8% | 78.1% | 2023 |
| Contractors | 156 | 14.7% | 67.9% | 2022 |
| Agency Staff | 119 | 11.2% | 92.4% | 2022 |
| State & Local Employees | 31 | 2.9% | 93.5% | 2024 |
| Grantees | 28 | 2.6% | 67.9% | 2023 |
| Banking Organization | 18 | 1.7% | 50.0% | 2023 |
| Employers | 16 | 1.5% | 93.8% | 2023 |
| Educators | 15 | 1.4% | 86.7% | 2023 |
| Agency Customers | 12 | 1.1% | 100% | 2023 |

The remaining 22 categories (1–10 records each) spanned go-live years 2019–2026 with no consistent
skew toward old/inactive records — low volume alone didn't correlate with obsolescence, so a
volume-based cutoff (e.g. "only categories over 1% usage") would have been arbitrary, not justified.

**Step 2 — the actual signal was recency of last use, not volume or median year.** For each
category, found the most recent Application go-live date (falling back to Estimated Go-Live Date for
applications not yet launched) it appears on, checked as of 2026-08-12:

| Category | Records | Most recent go-live | Months since last use |
| --- | --- | --- | --- |
| Brokers | 1 | 2019-07-18 | 84.8 |
| Health Care Workers | 4 | 2021-03-11 | 65.0 |
| First Responders | 2 | 2022-08-22 | 47.7 |
| Veterans* | 7 | 2023-04-13 | 40.0 |
| Retirees - General Population | 3 | 2023-11-01 | 33.3 |
| Travelers | 3 | 2024-05-21 | 26.7 |
| Small Business Owners | 3 | 2024-07-18 | 24.8 |
| International Users | 5 | 2024-07-18 | 24.8 |
| Active Duty Military | 7 | 2024-08-01 | 24.3 |
| *(everything else — 23 categories)* | | | ≤ 17.2 |

\* `Veterans` is one of the 6 original picklist values, so it required no schema action regardless
of this finding — noted for completeness, not acted on.

These 8 categories (excluding `Veterans`) hadn't been used in 18+ months (several not in 2+ years),
a real recency cutoff distinct from volume — e.g. `Students` (10 records) and `Minors 13-18` (2
records) are both low-volume *and* recently used (within 3.6 months), while `Active Duty Military`
(7 records, comparable volume) hasn't been used in over 2 years. This is the basis actually acted on.

**Decision (user-confirmed 2026-08-12): expand the Global Value Set to the 24 categories used within
the last 18 months; leave the 8 stale ones out.** Estimated data-loss impact: ~28 records (2.6% of
all Applications) whose only Demographic Served tag falls in the 8 excluded categories — a
substantially smaller and better-justified gap than the original ~400-record estimate.

**Implementation:**
- `sfdx/force-app/main/default/globalValueSets/Demographic_Served.globalValueSet-meta.xml` — added
  19 new `customValue` entries (the 24 recent categories minus the 4 that already existed as exact
  matches: `Federal Employees`, `General Population`, `Government Employees (Military)`, `Veterans`).
- `Airtable's "Contractors" (156 records) maps to the existing "Gov't Employees (Contractors)"
  value, not a new value.` Chosen over creating a separate `Contractors` value because no Salesforce
  data exists yet under either label (Application hasn't been loaded), and having two
  near-identical values (`Contractors` and `Gov't Employees (Contractors)`) side by side in a
  picklist a user has to choose from would be confusing. This is the one part of the mapping that's
  a judgment call rather than a direct string match — documented here in case it turns out
  `Gov't Employees (Contractors)` was intended to mean something narrower than Airtable's
  `Contractors`.
- `LDGCRM_application__c/recordTypes/LDGCRM_Application.recordType-meta.xml` — the record type
  restricts which Global Value Set members are actually selectable (a separate `picklistValues`
  block listing only 6 `fullName`s originally); added the same 19 values here too, or they'd exist
  in the value set but not be assignable on this record type. Salesforce's RecordType metadata
  encodes special characters in `fullName` (`&` → `%26`, as seen on the pre-existing `Gov%27t
  Employees %28Contractors%29` entry) — used `State %26 Local Employees` accordingly.
- Deployed via `sf project deploy start --metadata "GlobalValueSet:Demographic_Served"
  --metadata "RecordType:LDGCRM_application__c.LDGCRM_Application" --test-level NoTestRun`
  (NoTestRun for the same pre-existing FCIC-blocker reason as every other deploy this session).
  Verified live via `sf sobject describe` afterward — 25 total values present in gsa-peo, not just
  assumed from a successful deploy.

**The 8 excluded categories are not gone forever** — if a later reporting need requires them, add
them to the Global Value Set (and this record type's picklist) the same way. Airtable rows tagged
only with an excluded category should have that tag dropped, not the whole row skipped — this is a
per-value filter, not a row-level skip like a missing required lookup.

### Opportunity has a *different* Demographic Served field — separate analysis needed later

Flagged mid-investigation (user prompt) and checked before finalizing the above, specifically so this
decision wouldn't need redoing: Opportunity has **two** demographic fields, and neither is this
migration's concern today:
- `Opportunity.Demographic_Served__c` — explicitly labeled **"Demographic Served (Deprecated)"**,
  `"Originally created for TTS OTCRM - Login.gov Opportunities"`, its own independent 5-value
  picklist (`Foreign Nationals`, `General Population`, `Gov't Employees`, `Non-USC`, `Veterans`).
  Not touched by this migration under any circumstance.
- `Opportunity.LDGCRM_Demographic_Served__c` — the current one, but it does **not** reference the
  shared `Demographic_Served` Global Value Set edited above. It has its own independent inline
  6-value list (same 6 as Application originally had, except its "contractors" value is spelled
  `Gov't Employees`, not `Gov't Employees (Contractors)`). **Editing the Global Value Set above did
  not affect this field.**

A quick check of Airtable's `Opportunities` table's own `Demographic Served` column (928 rows) shows
a much smaller, largely-matching set already (`General Population`, `Federal Employees`,
`Government Employees (Military)`, `Non-USC`, plus semicolon-joined combinations like `General
Population; Gov't Employees`) — encouraging, but this needs its own full recency/volume analysis the
same way Application's did, not an assumption that it's fine, when the Opportunity chunk is built.

### Field mapping

Grouped by shape rather than listed as one flat table, given the size (55 fields).

**Identifiers / lookups:**

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Applications Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough — the upsert key. |
| `Name` | `Name` | Direct passthrough — unlike Partner Account, Applications has a real, complete (`0` missing) `Name` column. 9 duplicate-name groups exist but aren't a problem (this is upsert-on-external-ID, not name-matching). |
| `Partner Account Record ID (from Partner Agreement)` | `LDGCRM_Partner_Account__c` (**required** Lookup, CSV column `LDGCRM_Partner_Account__r.LDGCRM_External_ID__c`) | Direct passthrough. Required — rows with no linked Partner Account can't load. 17 of 1,064 rows have none, written to `Application-skipped-<ts>.csv`. Investigated individually (not assumed) rather than batch-excluded — see the dedicated subsection right after this table. |
| `Opportunity Record ID` | `LDGCRM_Opportunity__c` (optional Lookup, filtered to Opportunity's `Login_gov` record type, CSV column `LDGCRM_Opportunity__r.LDGCRM_External_ID__c`) | Direct passthrough when present. Optional — blank is fine. Needs Opportunity loaded first to resolve (not built yet), same dependency shape as Partner Account needing Account. |
| `Broker App Parent` | `LDGCRM_Broker_App_Parent__c` (self-Lookup to `LDGCRM_application__c`) | **Not written by this script — deferred to a second pass.** Holds a single `rec...` ID pointing at another Application (confirmed by sampling). Same-batch external-ID resolution was assumed workable when this table was first written; the 2026-08-13 load **disproved that** — all 68 rows carrying this field failed even though the parent Application was in the same CSV. Needs its own follow-up upsert after every Application row exists in the org. See the post-mortem section above. |
| `Parent Application` | *(not written)* | Redundant display-text rollup of `Broker App Parent`'s Name (e.g. `"Microsoft Azure Platform (MS AAD)"`) — not a separate relationship, excluded. |
| `Broker App Children` | *(not written)* | Reverse rollup of `Broker App Parent` (which Applications point at this one) — computed from the other side, excluded. |
| `Market Segment (from Agreement)` | *(not written)* | `LDGCRM_Application_Before_Save_Assign_Market_Segment` (before-save Flow) already derives `LDGCRM_Market_Segment__c` from `LDGCRM_Partner_Account__r.LDGCRM_Account__r.LDGCRM_Market_Segment__r` — see `CLAUDE.md`. Same rule as Partner Account. |

#### The 17 rows with no Partner Account are two different populations, not one

Investigated individually (user's request, after noticing Airtable's own UI didn't obviously show
rows missing a Partner Account — a reminder that Airtable's UI can show rollup/lookup views that
don't match what the raw API export actually contains) rather than assumed to all be the same kind
of "bad data":

- **6 are genuinely decommissioned**: `CBP I'm Ready`, `SAMS (CBP)`, `GSA Federal Advisory Committee
  Act Training`, `CCP Truck Staging`, `SPEARS Opportunity Portal | HUD Section 3 Opportunity Portal`,
  `Army Contract Writing System's (ACWS) Vendor Self Service (VSS)` — all `Status = "Decomissioned"`
  (the same misspelling mapped elsewhere), several with `Actual Go-Live Date` back to 2018–2022.
  **User-confirmed (2026-08-13): reasonable to exclude these permanently** — retired applications
  whose Partner Account link was apparently dropped as part of decommissioning, not worth chasing
  down a historical link for.
- **11 are the opposite of stale — active drafts**: `DOL - ICAM`, `HHS OIG` (×3 separate records),
  `HHS`, `SSA Secure Online Services`, `Test Application`, `MyTravelGov`, `DOL EBSA` (×2). All have
  **blank `Status`, no dates, and were created within the last ~7 weeks** as of 2026-08-12 (several
  within the last 8 days) — these read as records someone is actively typing into Airtable right
  now, not old/abandoned data. `Test Application` fits the same "in-progress, not yet real" pattern.
  **Not excluded permanently** — re-run `Build-ApplicationLoad.ps1` closer to the actual production
  load date to pick up whichever of these get a real Partner Account link (and Status) by then,
  rather than assuming today's snapshot is final. This is why the script re-reads the current
  Airtable export every run instead of caching a decision per record.

**Booleans derived from presence, not a literal value** (Airtable omits the field entirely when
unchecked — these are true Airtable checkboxes and map straightforwardly, present→`true`):
`Account Manager Approved`, `Agreement Finalization Email Sent`, `Customer Support Meeting Deemed
Unnecessary`, `Finalized Application Details`, `Fraud Meeting Deemed Unnecessary`, `IdV Upgrade?`,
`Confirmed pre-launch or launch day activities`, `Launch Day Activities Completed`, `Launch
Coordinators Kick-off Call`, `Launch Kick-off Meeting Unnecessary`, `Launch Tested`, `Launch to
Production Completed by OE`, `Marketing/Comms Strategy`, `Requested Contact Center Reporting`,
`Security Meeting Deemed Unnecessary`, `Coordinated Optional Follow-up Tech Sync`, `UX Meeting
Deemed Unnecessary` → their correspondingly-named `LDGCRM_*__c` Checkbox fields.

**Booleans derived from presence of a *linked-record* column, not a literal checkbox** (confirmed by
sampling — values are `rec...` IDs pointing at the not-yet-migrated Meetings table, or in Security
Meeting's case, freeform meeting-name text): `Customer Support Meeting`, `Fraud Meeting`, `Launch
Kick-off Meeting`, `UX Meeting`, `Security Meeting` → `LDGCRM_Customer_Support_Meeting__c`,
`LDGCRM_Fraud_Meeting_Held__c`, `LDGCRM_Launch_Kickoff_Meeting_Held__c`, `LDGCRM_UX_Meeting_Held__c`,
`LDGCRM_Security_Meeting__c`. **Deliberately not resolving which specific meeting** (user-confirmed)
— true if the Airtable column has any value, blank otherwise. No attempt to link the actual Meeting
record; there's no field on Application for that relationship anyway.

**Booleans derived from an explicit two-valued text field** (not presence-based — the column is
always populated with one of two strings): `Broker Application` (`"Yes"`/`"No"`, 936 No / 50 Yes) →
`LDGCRM_Broker_Application__c`; `Launch Risk` (only ever blank or the single value `"At Risk"`, 622
records) → `LDGCRM_Launch_Risk__c` (true when the value is present/equals `"At Risk"`).

**Picklists needing an explicit value map** (checked every distinct value against the target's
actual allowed set before assuming passthrough — see General Principle):

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `Status` | `LDGCRM_Status__c` (restricted picklist) | 7 of 8 distinct values match exactly. `"Decomissioned"` (89 records, one *m*) → `"Decommissioned"` (correct spelling, matches the record type's actual value) — a spelling-drift gotcha, same category as Impediment's Category fix. |
| `Ramp Up Approach` | `LDGCRM_Ramp_Up_Approach__c` (restricted picklist: `Gradual`/`Immediate`/`Spikes`) | Airtable's values are verbose labels with the real value as a leading word, e.g. `"Gradual Level 2: Low Impact < 350K users"` → map by taking the leading `Gradual`/`Immediate`/`Spikes` token, not the whole string. 2 records (`"Q1 - FY'23"`, `"146"`) have no extractable value — left blank on load. **User-confirmed (2026-08-13): acceptable as-is** — this looks like old data on an otherwise solid picklist field, and the Salesforce field is optional, so nulling these 2 rows rather than guessing is fine; no further review needed. |
| `Launch Level` | `LDGCRM_Launch_Level__c` (restricted picklist, 5 values) | Airtable stores bare numbers (`"1"`–`"5"`); map to the full label (`"1"` → `"1 - Very Low Impact"`, … `"5"` → `"5 - Very High Impact"`). |
| `Demographic Served` | `LDGCRM_Demographic_Served__c` (multiselect) | See dedicated section above — this is the big one. |
| `Service Level` | `LDGCRM_Service_Level__c` (restricted picklist) | Already an exact match on all 3 distinct values (`Authentication Only`, `Basic IdV`, `Enhanced IdV (IAL2)`) — direct passthrough, no map needed. |

**Direct passthrough (Text/URL/Date/Number, values already compatible):**
`Actual Go-Live Date`, `Current Go Live Date` → their `Date` fields (Airtable `YYYY-MM-DD` matches
Bulk API's expected format); `# of Estimated Annual IdV Transactions`, `# of
Estimated Monthly Active Users` → their `Number` fields; `Completed Customer Support Survey`,
`Completed Fraud Survey`, `Completed Security Survey`, `Launch Checklist URL`, `Launch Deck URL` →
their `Url` fields (checked all 5 for the same `"TBD"`-placeholder issue found on `URL`/
`Description` — 0 occurrences across all of them, so no filter needed here).

**Not mapped — also formula fields, same lesson as the Percent fields above:**
`LDGCRM_Opportunity_Lead__c` (`HYPERLINK` formula pulling `LDGCRM_Opportunity__r.Owner`'s name) and
`LDGCRM_Opportunity_Stage__c` (`TEXT(LDGCRM_Opportunity__r.StageName)`) both looked like plain `Text`
fields — a type that's normally always safe to write to — but are entirely computed from the linked
Opportunity once `LDGCRM_Opportunity__c` is set. Airtable's `Opportunity Lead` and `Opportunity
Status` columns are excluded from the transform entirely, not mapped. (These two stay blank until
Opportunity is loaded and the Application's `LDGCRM_Opportunity__c` lookup actually resolves — same
dependency as the lookup itself, not a new one.)

**Passthrough with a placeholder filter** (checked real values before assuming clean data — see
General Principle): `URL` and `Description` both use the literal placeholder `"TBD"` (with a
trailing newline) on a meaningful minority of rows (32 of 944 non-blank `URL` values; 30 of 1,026
non-blank `Description` values) — treat `"TBD"`-prefixed values as blank rather than loading the
literal placeholder text, same pattern as Partner Account's non-URL `Agency Summary` filter.

### Load history (2026-08-13): three attempts, 1,045 failures → 688/688 clean — full post-mortem

**Final state: 688 of 688 submitted rows loaded successfully, 0 failures.** Verified post-load that
all 688 resolved their Partner Account lookup and all 688 had `LDGCRM_Market_Segment__c` populated by
the before-save Flow (confirming the "never set Market Segment directly" rule). Of the 1,064 Airtable
rows, 359 were deliberately withheld pending Airtable Account fixes and 17 have no Partner Account at
all — those load on a re-run once the data is corrected, no code change needed.

Getting there took three attempts. Every failure is catalogued below, because most of these causes
generalize to the objects still to be built.

**Attempt 1 — 1,045 of 1,047 rows failed:**

| Error | Rows | Cause |
| --- | --- | --- |
| `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on Service Level | 521 | **A real bug in this script.** See below. |
| `INVALID_FIELD` — Partner Account FK not found | 343 | Expected: parent Partner Account never loaded (its own parent Account is unresolved). Data-quality gap, not a code bug. |
| `INVALID_FIELD` — Opportunity FK not found | 99 | Expected: Opportunity isn't built/loaded yet. |
| `INVALID_FIELD` — Broker App Parent FK not found | 68 | **Disproved an assumption this document previously recorded as "likely fine."** See below. |
| `STRING_TOO_LONG` on Name / URL | 14 | Salesforce platform hard limits. See below. |

**Attempt 2 — 686 of 688 succeeded.** Two rows exposed gaps in the attempt-1 fixes, both worth noting
because each was a *narrow* fix where a general one was needed:

| Error | Rows | Cause |
| --- | --- | --- |
| `STRING_TOO_LONG` on Launch Deck URL | 1 | The attempt-1 fix length-checked only `LDGCRM_URL__c` — the field that happened to have obviously long values — leaving the object's five *other* `Url` fields unguarded. Now every Url field runs through one shared `Resolve-UrlValue` helper driven by a field table. **Lesson: when a platform limit bites one field, fix it for every field of that type on the object, not just the one that failed.** |
| `FIELD_INTEGRITY_EXCEPTION` on Actual Go-Live Date | 1 | One row carries `0202-02-18` — a mistyped `2022`. Every date value in the export is validly *formatted* `YYYY-MM-DD`, so a format check passes it; the year is simply not a real date Salesforce accepts. Now range-checked (1900–2100) via `Resolve-DateValue`. **Lesson: correct format ≠ sane value — the same instinct as checking a picklist's actual values rather than trusting its type.** |

**Attempt 3 — 688 of 688 succeeded, 0 failures.**

**1. `Service Level` was a 1-element array, not a scalar — the `System.Object[]` trap.** Airtable
returns `Service Level` as a linked-record-style array (`["Authentication Only"]`) even though it
reads as a plain single-select in the Airtable UI and its *values* all matched the target picklist
exactly. The transform passed `$Row.fields.'Service Level'` straight through, and PowerShell's CSV
export stringified the array as the literal text `System.Object[]`, which the restricted picklist
rejected on every row that had a value. **The pre-build investigation checked the field's distinct
values but not its JSON shape** — which is exactly why it slipped through: `Group-Object` over an
array-valued field still reports the inner strings, so the values "looked" clean. Fixed with the same
`@(...)[0]` unwrap used for every genuine linked-record field. **Every other direct-passthrough field
on this object was then re-checked for the same shape (`-is [array]`); Service Level was the only
one.** Lesson, and it's a new one for this migration: checking a field's *values* isn't enough —
check its *shape* (`$value -is [array]`) before treating any Airtable field as a scalar passthrough,
even one that looks like a simple single-select. A stringified `System.Object[]` in a load CSV is the
tell.

**2. Self-referential lookups do NOT resolve within a single upsert batch.** This document previously
recorded, on the `Broker App Parent` row of the field-mapping table, that same-batch external-ID
resolution was "likely fine since Bulk API resolves external-ID references after all rows in a batch
are inserted, but worth verifying when the script is built rather than assumed." **Verified: it's
false.** All 68 rows carrying a `Broker App Parent` failed with `Foreign key external ID ... not found
... in entity LDGCRM_application__c`, even though the referenced parent Application was in the same
CSV. `LDGCRM_Broker_App_Parent__c` is therefore no longer written by this script at all — it needs a
**second pass** re-upserting only `LDGCRM_External_ID__c` + the parent reference, after every
Application row exists in the org (see `docs/README.md`'s Load order). Applies to any future
self-referential lookup in this pipeline, not just this one.

**3. `Name` (80) and `Url` (255) are Salesforce platform hard limits, not fixable field metadata.**
Unlike Impediment's `TextArea`→`LongTextArea` fix and Partner Account's `Text(10)`→`Text(50)`
extension — both genuine metadata shortcomings this migration corrected — these two can't be raised:
a custom object's `nameField` is capped at 80 characters by the platform (no `<length>` override
exists for it) and `Url`-type fields are fixed at 255. 5 rows exceeded the Name cap (truncated to 80
and flagged) and 9 exceeded the URL cap (left blank rather than truncated — a cut-off URL is a broken
URL, whereas a cut-off name is still recognizable). Both go to
`Application-overlength-<ts>.csv` for human review, and both are written up in
`AIRTABLE-DATA-QUALITY-REQUESTS.md` asking for shorter canonical values at the source. **Lesson: when
a length limit bites, check whether it's a field setting we control or a platform limit before
reaching for a metadata fix** — the earlier TextArea/Text cases in this migration made "just extend
the field" feel like the default answer, and it isn't always available.

**4. An "optional" lookup still fails the whole row if it points at something nonexistent.** The 99
Opportunity-FK failures are worth stating explicitly because the field-mapping table below describes
`LDGCRM_Opportunity__c` as optional and says "blank is fine" — true, but blank is not the same as
*populated with an unresolvable reference*. Bulk API rejects the entire record, not just the
offending field. This is why Opportunity is now documented as a hard prerequisite for Application in
the load order, despite the lookup being nominally optional.

### Six fields are actually formula fields — don't write to them

`LDGCRM_Launch_Checklist_Completion__c`, `LDGCRM_Level_1_Complete_Pct__c`,
`LDGCRM_Level_3_Complete_Pct__c`, and `LDGCRM_Level_4_Complete_Pct__c` all declare
`<type>Percent</type>` in metadata, indistinguishable at a glance from a normal writable Percent
field — but each also has a `<formula>` tag: they're computed automatically from the very
Checkbox/URL fields already being migrated (e.g. `LDGCRM_Level_1_Complete_Pct__c` = count of 9
specific checkboxes/fields being true or non-blank, divided by 9). `LDGCRM_Opportunity_Lead__c` and
`LDGCRM_Opportunity_Stage__c` are the same trap wearing a `Text` type instead of `Percent` —
computed from the linked Opportunity's Owner/StageName once `LDGCRM_Opportunity__c` is set.
Salesforce rejects direct writes to formula fields outright, regardless of declared type. Airtable's
matching columns (`Checklist Completion %`, `Level 1+ Complete %`, `Level 3+ Complete %`, `Level 4+
Complete %`, `Opportunity Lead`, `Opportunity Status`) are **excluded entirely** — not mapped, not
filtered, just not referenced in the transform at all. Once the underlying checkboxes/URLs/
Opportunity lookup load correctly, these compute themselves; loading them independently would have
failed the batch outright (a much louder failure than the TextArea-length issue, which at least
loaded the *other* columns on the same row). This also made a percent-unit question moot for the
Percent fields: Airtable stores these as 0–1 fractions (e.g. `0.111` for what Airtable displays as
`11.11%`) while Salesforce Percent fields expect the raw
0–100 number via the API — would have needed a ×100 conversion if any Percent field here had been
genuinely writable, but none are, so it never came up. **Lesson: check for a `<formula>` tag before
mapping *any* field that looks like a plain calculated/aggregate value (Percent, Number, even Text)
— "the type looks normal" isn't the same as "it's writable," the same way `<type>TextArea</type>`
without a length doesn't mean "255 characters is enough" (see General Principle #4).**

### Fields with no destination — the full inventory (as requested)

Every Airtable column not covered above, and why:

**Feed a different chunk, not this object:** `Agreement Contacts`, `Contacts Record ID`, `Email
(from Agreement Contacts)` (all drive `LDGCRM_Application_Contact__c`); `Partner Portal Admin`
(drives a checkbox on `LDGCRM_Application_Contact__c` specifically — **not** a field on Application
itself; user-confirmed this is where it now lives, contacts junction chunk, not here).

**Rollups/lookups from a parent record, redundant with data already on that parent:** `Account`,
`Account Owner`, `Department` (from Account/Partner Account); `Est. Go Live (Opportunity)`, `Initial
Agreement Size (from Opportunity)` (from Opportunity); `Most Recent PoP End Date`, `Most Recent PoP
Start Date` (from Partner Account, same fields already excluded there for the same reason).

**Airtable system/computed metadata, not real data:** `Created By`, `Last Modified`, `Updated?`,
`Count (Issuer Strings)`.

**Freeform/journal-style — deferred `ContentNote` candidates** (per the Notes chunk, see above in
this document): `Notes` (a literal Notes column — the strongest possible candidate), `Launch Notes`,
`IdV Upgrade Notes`.

**No Salesforce field found at all — genuinely unmapped, not just deferred:**
- `Issuer Strings` — **confirmed not migrated** (user-explicit decision). Links to a table this
  migration doesn't pull, and the Salesforce target (`LDGCRM_PP_Issuer_Strings__c`) is a plain
  `Text(40)`, not a Lookup, so a raw linked-record ID wouldn't be meaningful there anyway.
- `Pilots` — short categorical values (`No Pilots` 754, `IPP` 23, `Unemployment Insurance Pilot` 8,
  `FCC Pilot` 3, `Biometric` 3, `Disaster Pilot` 1). No dedicated field exists. **User-confirmed
  (2026-08-13): not migrating this field** — closed, not just deferred.
- `Migrated to the partner portal` (boolean, 296 `True`) — no matching field found; likely
  owned/set by the Partner Portal system directly rather than sourced from this migration.
  **User-confirmed (2026-08-13): fine not to have this for now** — not a permanent "never," just not
  a current priority, so don't read this as fully closed the way Usage Tracker/Vital Update % are.
- `Usage Tracker Application Name` — a different external system's app name (Login.gov's usage
  analytics tool), not a Salesforce concept. **User-confirmed (2026-08-13): does not need to
  transfer** — closed, not just deferred.
- `Vital Update %` — no matching field found despite the Percent shape; not the same thing as
  `Checklist Completion %` or the `Level N+ Complete %` fields (those all have their own distinctly-
  named Airtable source columns already mapped above). **User-confirmed (2026-08-13): does not need
  to transfer** — closed, not just deferred.

**Salesforce fields on this object with no Airtable source at all — not yet confirmed either way:**
`LDGCRM_Annual_Revenue_Amount__c`, `LDGCRM_P3_Partner_Portal_Team_Name__c`,
`LDGCRM_P3_Team_UUID__c`. Presumed populated by the Partner Portal application directly rather than
this migration (no Airtable column resembling `revenue`/`uuid`/`team name` exists), but that's an
assumption, not a confirmed fact the way the four items above are — worth a explicit check with
whoever owns the Partner Portal integration before treating it as settled.

**Salesforce fields with no Airtable source at all** (confirmed by searching every Airtable column
name for `revenue`/`uuid`/`team`/`portal` — only `Partner Portal Admin` and `Migrated to the partner
portal` matched, neither of which populates these): `LDGCRM_Annual_Revenue_Amount__c`,
`LDGCRM_P3_Partner_Portal_Team_Name__c`, `LDGCRM_P3_Team_UUID__c`. Left unset by this migration —
likely populated by a different system (the Partner Portal application itself) rather than Airtable.
