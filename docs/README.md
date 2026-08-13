# Airtable → Salesforce migration pipeline

This directory holds the scripts that move Login.gov applicant data from Airtable into the
`gsa-peo` Salesforce sandbox (and eventually production). The pipeline has four stages that run
in order:

1. **Pull** — `Get-AirtableExport.ps1` pulls current data from the Airtable REST API into
   `data/airtable-exports/<Table>.json`. Already built. See the root `CLAUDE.md` ("Airtable API")
   for auth/connection details.
2. **Prep / transform** — `Build-*.ps1` scripts read the Airtable JSON and the current state of
   `gsa-peo`, and write CSVs into `data/salesforce-loads/` ready for a Bulk API upsert/update. This
   is what's being built out now (see "Build status" below).
3. **Load** — `Invoke-SalesforceLoad.ps1` wraps `sf data upsert bulk` / `sf data update bulk`
   (Bulk API 2.0) against those CSVs. **Decided 2026-08-12, not the headless Data Loader CLI
   originally planned**: Data Loader CLI isn't installed anywhere in this environment and current
   versions need Java 11+ (this machine only has Java 8), while `sf` is already installed,
   authenticated, and used by every other script in this repo — one fewer tool for whoever ends up
   operating this pipeline (Operations team included) to install and maintain. Both tools sit on the
   same underlying Bulk API and resolve lookups by external ID the same way, so this didn't require
   changing anything about how the `Build-*.ps1` scripts write their CSVs. If there's ever an
   org/compliance reason to switch to literal Data Loader, only `Invoke-SalesforceLoad.ps1` — not the
   transform scripts — would need to change. Built and proven: loaded all 39 Impediment records into
   gsa-peo this way (see `TRANSFORMATION-RULES.md`'s Impediment section for what that first real load
   surfaced).
4. **Notes** — freeform/journal-style Airtable columns that don't belong in a dedicated field become
   `ContentNote` records (Enhanced Notes, confirmed via the Account layout's `RelatedContentNoteList`)
   attached to their parent record. **Must be the last chunk built** — a Note needs its parent record
   to already exist, so this can't run until every other object's records are loaded. Not started; see
   `TRANSFORMATION-RULES.md`'s "Notes" section for the mechanism, candidate fields found so far, and
   the proposed (not yet implemented) Title/Body heuristic.

## Production Account seed (one-time bootstrap, not a pipeline stage)

`gsa-peo`'s Account data has been a moving target (531 → 588 → growing) and doesn't reliably match
the real universe of production Accounts, which makes testing `Build-AccountReconciliation.ps1`
against it a weak proxy for how the actual production migration will behave. `Build-ProdAccountSeed.ps1`
closes that gap: it parses a real production Account export (`data/PEO PROD Accounts <date>.xls` —
despite the extension, actually an HTML table from a Salesforce report export, not a binary Excel
file) and produces an insert-ready CSV of every production Account name gsa-peo doesn't already have,
Name only (no Owner/Parent Account hierarchy — user-confirmed 2026-08-13, since nothing in this
migration's scripts reads either field). Read-only against Salesforce (two queries: existing Account
names, the Federal RecordTypeId) — writes nothing itself.

This is the first half of a two-phase test the user asked for, to prove out the real production
process end to end:

1. **`Build-ProdAccountSeed.ps1`** → `Invoke-SalesforceLoad.ps1 -Operation Insert` — seed gsa-peo
   with the real production Account names first.
2. **Re-run the existing, unmodified `Build-AccountReconciliation.ps1` → load →
   `Build-PartnerAccountLoad.ps1` → load chain** against that now-realistic baseline. This is exactly
   what the real production reconciliation pass will look like, not a sandbox-only approximation.

**Full rebuild completed 2026-08-13**, after the user asked to first hard-delete gsa-peo's existing
test-created Account/Partner Account data (via `scripts/cleanup/cleanup-gsa-peo.ps1`, scoped to just
those two objects with its new `-ObjectsCsv` override — see that script's own docs) rather than layer
the seed on top of it, for a genuinely clean test:
- Cleanup: 584 of 585 external-ID-tagged Accounts deleted, all 74 external-ID-tagged Partner Accounts
  deleted. One Account (blocked by a pre-existing test `LDGCRM_Application_Contact__c` junction
  record) and all other pre-existing non-external-ID test data were deliberately left alone —
  user-confirmed not to touch pre-existing test data at all, migrate or delete.
- Seed: 1,342 of 1,369 production Account names were missing from the cleaned baseline (up from 786
  before the cleanup, since the earlier run had partial overlap with already-loaded data) — inserted,
  Name only.
- Reconciliation: re-run against the refreshed 1,346-Account baseline matched **587 Accounts** (up
  from 7 before the cleanup+reseed) — a far more realistic number for what the real production
  migration will actually do. 169 still unmatched (see `AIRTABLE-DATA-QUALITY-REQUESTS.md`).
- Partner Account: 74 of 94 loaded successfully (same 20 failures as before the rebuild — all trace
  to Partner Accounts whose parent Account is still among the 169 unmatched, a data-quality gap this
  rebuild couldn't fix on its own).

`Invoke-SalesforceLoad.ps1` gained a third operation for this: `-Operation Insert` (wraps
`sf data import bulk`, a pure insert with no key column — different from `Upsert`/`Update`, which
both need a key column since they're matching against existing records).

## ⚠️ Coordination: two people can load into gsa-peo

Rahul is separately using the **Data Loader GUI** against the same `gsa-peo` sandbox. This
pipeline uses **`sf data upsert bulk`/`sf data update bulk`** (see Stage 3 above for why). Both
write to the same org, so before anyone actually runs a load (GUI or CLI) — even a small test
batch — coordinate first so two loads don't
race each other or double-load the same records. Nothing in this directory automatically loads
anything; every `Build-*.ps1` script here only reads Airtable/Salesforce and writes local CSVs.
Actually invoking the Data Loader CLI is a separate, explicit step (Stage 3, not built yet) that
should not happen without that coordination.

**For the full field-by-field mapping rules and every gotcha discovered per object, see
[`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md)** — that's the authoritative detail; this file
covers pipeline architecture, build status, and how to run things.

**For a running list of Airtable data-quality issues that block or would improve the migration —
written for the data owner, not developers — see
[`AIRTABLE-DATA-QUALITY-REQUESTS.md`](AIRTABLE-DATA-QUALITY-REQUESTS.md).** Every `Build-*.ps1`
script's skipped/unmapped review CSVs should feed into this list as they're found, not just sit in
`logs/data-migration/` unnoticed.

## Conventions

- **Upsert on `LDGCRM_External_ID__c`**, not insert, for every object *except* Account (see
  below) — the Airtable record's `rec...` ID becomes the Salesforce record's external ID, which is
  what keeps re-running a load idempotent and what lets child records reference parents without
  the transform scripts having to resolve real Salesforce IDs themselves. Cross-object lookups
  (e.g. Application → Partner Account) are written to CSV as the parent's Airtable `rec...` ID and
  resolved at load time by the Data Loader field mapping (`ParentObject:LDGCRM_External_ID__c`),
  not pre-resolved by the transform script. This only works once the parent object's external ID
  is reliably populated — which is why load order matters (see below).
- **Account is the exception.** Accounts already exist in Salesforce independently of this
  migration (they aren't being created by it), and in production most don't yet carry
  `LDGCRM_External_ID__c`. So there's no reliable external ID to upsert against yet — the
  reconciliation script (`Build-AccountReconciliation.ps1`) resolves each Airtable Account row to
  a real Salesforce `Id` itself (external-ID match first, then exact `Name` match) and produces an
  **update** file keyed on `Id`, not an upsert file keyed on external ID. Rows it can't confidently
  match are written to a review CSV instead of guessed at — see `CLAUDE.md`'s note on the
  `Depart of Homeland Security` typo case for why. Once this backfill lands, every other object's
  lookup *back to* Account can use the normal external-ID passthrough. The same script also backfills
  the standard `Type` field from Airtable's `States + DC/PR` checkbox (`"State"` if checked, else
  `"Federal"`) — a column whose name doesn't describe what it actually maps to; see `CLAUDE.md`'s
  "Not every Airtable column is a simple same-name mapping" note before assuming any other table's
  columns map 1:1 by name.
- **Windows PowerShell 5.1**, same as every other script in this repo — no `??`, `?.`, ternary
  `?:`, `ConvertFrom-Json -Depth` (that flag is PS6+ only; 5.1's default max depth of 100 is fine
  here), or `-AsHashtable`.
- **Data Loader CSVs are UTF-8 without a BOM.** `Export-DataLoaderCsv` in
  `Common.DataMigration.ps1` writes this way deliberately — PowerShell 5.1's
  `Export-Csv -Encoding UTF8` always adds a BOM, which some Data Loader CLI versions misread as
  part of the first column header. Files meant for human review (unmatched/ambiguous-row reports)
  still use plain `Export-Csv -Encoding UTF8` — the BOM there is harmless and helps Excel detect
  UTF-8 correctly.
- **Dry run before a full load**, per `sfdx-sandbox-ops` — export/preflight-count before writing,
  small batch before the full object, explicit confirmation before anything destructive or
  hard-to-reverse.

## Files

| File | Stage | Status |
| --- | --- | --- |
| `Get-AirtableExport.ps1` | Pull | Built |
| `Common.DataMigration.ps1` | shared helpers (Airtable JSON loading, Data Loader CSV writing, read-only SOQL) | Built |
| `Build-AccountReconciliation.ps1` | Prep — Account (update, not upsert) | Built |
| `Build-ImpedimentLoad.ps1` | Prep — Impediment (independent parent, straight upsert) | Built |
| `Build-PartnerAccountLoad.ps1` | Prep — Partner Account (Master-Detail to Account, requires Account loaded first) | Built |
| `Build-OpportunityLoad.ps1` | Prep — Opportunity (needs Account **and Partner Account** loaded first) | Built and **loaded 2026-08-13: 742/742 succeeded**, including the `LDGCRM_Partner_Account__c` lookup (66 linked). Required a Login_gov record-type picklist fix found by a test batch (see `TRANSFORMATION-RULES.md`) and an `LDGCRM_App_Description__c` LongTextArea deploy. 186 rows withheld (142 unreconciled Accounts, 28 no Status, 16 no Account link). |
| `Build-ContactLoad.ps1` | Prep — Contact (independent parent; optional Account/Partner Account lookups) | Built and **loaded 2026-08-13: 1,483 of 1,487** (4 rejected by an org duplicate rule). **Merges rows sharing an email** (1,599 → 1,532) since Airtable lacks a person↔Application junction; also emits `Contact-identity-map.csv` for the junction chunk. Loaded with `-DisableTriggerControl "Contact"` — see "Loading Contact" below. |
| `Build-ApplicationLoad.ps1` | Prep — Application, needs Partner Account **and Opportunity** loaded first (see "Load order") | Built and **loaded 2026-08-13: 688/688 succeeded, 0 failures**. Took three attempts — the first failed 1,045 of 1,047 rows — which drove six fixes (Service Level array unwrap, Broker App Parent moved to a second pass, Name/URL platform-limit handling across *all* Url fields, out-of-range date check, live Partner Account/Opportunity preflight, plus an `Invoke-SalesforceQuery` array bug). 359 rows remain skipped pending Airtable Account fixes; 92 Opportunity links pending the Opportunity load. See `TRANSFORMATION-RULES.md`'s Application section for the full 55-field mapping and the failure post-mortem. |
| `Build-OpportunityImpedimentLoad.ps1`, `Build-ApplicationContactLoad.ps1` | Prep — dependent/junction objects | Not built |
| `Build-OpportunityContactRoleLoad.ps1` | Prep — blocked on an `sfdx-metadata-sync` fix (`OpportunityContactRole.LDGCRM_External_ID__c` needs `externalId=true`) | Not built |
| `Build-MeetingLoad.ps1` | Prep — Activity/Event, needs a default-duration convention for synthesized `StartDateTime`/`EndDateTime` | Not built |
| `Invoke-SalesforceLoad.ps1` | Load — generic `sf data upsert bulk`/`sf data update bulk` wrapper, any object | Built |
| `Build-NotesLoad.ps1` (name TBD) | Notes — `ContentNote`/`ContentDocumentLink` for freeform columns, last chunk | Not started |
| `Build-ProdAccountSeed.ps1` | Bootstrap — production Account name seeding, not a regular pipeline chunk | Built. Tested: 786 of 1,369 production Account names missing from gsa-peo, ready to insert. |

## Load order

Parents before children/junctions (the reverse of the delete order in
`scripts/cleanup/cleanup-gsa-peo.ps1`):

```
Market Segment (already migrated)
  -> Account (reconciliation/backfill, not create - see Build-AccountReconciliation.ps1)
  -> LDGCRM_Partner_Account__c
  -> Contact
  -> Opportunity
  -> LDGCRM_application__c
  -> LDGCRM_application__c SECOND PASS (Broker App Parent self-lookup only - see below)
  -> LDGCRM_Opportunity_Impediment__c (needs LDGCRM_Impediment__c + Opportunity first)
  -> LDGCRM_Application_Contact__c
  -> OpportunityContactRole (blocked, see above)
  -> Activity / Meetings (needs Account + Opportunity first)
```

**Opportunity must be loaded before Application** — this is a real ordering dependency, not just a
nice-to-have, even though `LDGCRM_Opportunity__c` is an *optional* lookup on Application. Confirmed
empirically by the first real Application load (2026-08-13): 99 Application rows failed outright with
`INVALID_FIELD: Foreign key external ID ... not found ... in entity Opportunity` because they carry an
`Opportunity Record ID` pointing at an Opportunity that doesn't exist in gsa-peo yet. Bulk API rejects
the **whole row**, not just the unresolvable lookup — "optional field" means "may be blank," not "may
reference something nonexistent." Loading Application before Opportunity therefore silently costs you
every row that has an Opportunity link.

**`LDGCRM_Broker_App_Parent__c` needs a second pass over Application, after the main load.** This is a
self-referential lookup (Application → Application) resolved by external ID. `TRANSFORMATION-RULES.md`
originally guessed Bulk API might resolve these within a single upsert batch since the parent row is
in the same file — **it does not**: the same 2026-08-13 load failed 68 rows with `Foreign key external
ID ... not found ... in entity LDGCRM_application__c`, referencing parent Applications that were
present in the very same CSV. `Build-ApplicationLoad.ps1` therefore no longer writes this column at
all; a follow-up pass (not yet built) has to re-upsert just `LDGCRM_External_ID__c` +
`LDGCRM_Broker_App_Parent__r.LDGCRM_External_ID__c` once every Application row already exists in the
org. General rule for any future self-referential lookup in this pipeline: it always needs its own
second pass.

## Running what's built so far

```powershell
# From the repo root:
scripts\data-migration\Get-AirtableExport.ps1
scripts\data-migration\Build-AccountReconciliation.ps1
scripts\data-migration\Build-ImpedimentLoad.ps1
scripts\data-migration\Build-PartnerAccountLoad.ps1
scripts\data-migration\Build-OpportunityLoad.ps1
scripts\data-migration\Build-ContactLoad.ps1
scripts\data-migration\Build-ApplicationLoad.ps1

# Actually load a prepped CSV into gsa-peo (prompts "Type LOAD to continue"):
scripts\data-migration\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_Impediment__c" `
    -CsvFile "data\salesforce-loads\LDGCRM_Impediment__c-upsert.csv"

# Account uses -Operation Update (Id-keyed) instead of the Upsert default:
scripts\data-migration\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "Account" `
    -CsvFile "data\salesforce-loads\Account-update.csv" `
    -Operation Update

# Partner Account is Master-Detail to Account - load Account first, or its
# parent lookup won't resolve:
scripts\data-migration\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_Partner_Account__c" `
    -CsvFile "data\salesforce-loads\LDGCRM_Partner_Account__c-upsert.csv"

# Application needs Partner Account loaded (required lookup) and ideally
# Opportunity too - see "Load order". Build-ApplicationLoad.ps1 queries the org
# first and skips rows whose parent doesn't exist yet, so it's safe to run at
# any point; re-run it after fixing Airtable data or loading Opportunity to
# pick up whatever newly resolves:
scripts\data-migration\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_application__c" `
    -CsvFile "data\salesforce-loads\LDGCRM_application__c-upsert.csv"
```

### ⚠️ Loading Contact requires disabling another app's Apex trigger

**Contact is the one object whose load flips a setting owned by a different application. Read this
before running it.**

gsa-peo is shared with the unrelated FCIC app, whose `GSA_FCIC_ContactTrigger` fires on every Contact
insert. Its before-insert path creates a **junk Account** — named after the person, hard-coded to the
`FCIC_Individual` Account record type — for **every Contact inserted with a blank `AccountId`**. None
of this is visible in `sfdx/force-app`: the manifest is LDGCRM-scoped, so other apps' automation was
never retrieved. It was found only because an 18-row test batch silently created 4 Accounts.

371 of the migrated Contacts have no resolvable Account (mostly the unmatched-Account data-quality
issue), so a normal load would create 371 junk Accounts in an org where Account counts are already a
moving target *and* where this migration's own Account reconciliation depends on those counts being
meaningful.

The FCIC app ships a supported kill switch — a `TriggerControls__c` custom setting the trigger checks
first — so `Invoke-SalesforceLoad.ps1` uses it via `-DisableTriggerControl`:

```powershell
scripts\data-migration\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "Contact" `
    -CsvFile "data\salesforce-loads\Contact-upsert.csv" `
    -DisableTriggerControl "Contact"
```

What that flag does, and the guarantees around it:
1. Reads and **records the current value** before changing anything (it does not assume "on").
2. Switches it off, runs the load.
3. **Restores it in a `finally` block** — so it is restored even if the load throws, the CLI dies, or
   the operator interrupts. This is not theoretical: the real Contact load *did* exit non-zero (4
   duplicate-rule rejections) and the restore still ran.
4. **Verifies the restore with a re-query** and prints a loud, explicit manual-fix command if it
   fails. Leaving FCIC's trigger disabled would silently break another team's app.
5. It is **off by default** and should stay that way. It changes config another app owns, so it needs
   explicit human sign-off per load.

Confirmed after the real load: **zero junk Accounts created** (org total held at 1,350) and
`TriggerControls__c.Contact.On__c` back to `true`.

**Not covered by any of this:** the *other* active Contact trigger, `purecloud.ContactWebHookv1`,
belongs to an installed **managed** package (Genesys PureCloud). Its body is hidden, it cannot be
retrieved, and it has no kill switch — so it fires on every Contact insert and **what it does is
unknowable from this repo**. It was user-confirmed inert in gsa-peo (2026-08-13). **Re-confirm before
any production run**: a webhook on Contact insert is an outward-facing side effect this pipeline
cannot inspect.

`Build-AccountReconciliation.ps1` is read-only against Salesforce (a single SOQL query) and only
writes local files:

- `data/salesforce-loads/Account-update.csv` — matched rows (`Id`, `LDGCRM_External_ID__c`,
  `LDGCRM_Market_Segment__r.LDGCRM_External_ID__c`, `Type`) ready for a Data Loader **update** (not
  upsert) once Stage 3 exists.
- `logs/data-migration/Account-reconciliation-unmatched-<timestamp>.csv` — Airtable rows with no
  confident Salesforce match, for human review.
- `logs/data-migration/Account-reconciliation-ambiguous-<timestamp>.csv` — Airtable rows matching
  more than one unclaimed Salesforce Account by name, for human review.

`Build-ImpedimentLoad.ps1` doesn't touch Salesforce at all (Impediment has no lookups to other
objects, so there's nothing to reconcile) and writes:

- `data/salesforce-loads/LDGCRM_Impediment__c-upsert.csv` — external-ID-keyed rows ready for a
  Data Loader upsert. Excludes `LDGCRM_Blocked_Revenue__c` (a roll-up Summary field Salesforce
  computes from `LDGCRM_Opportunity_Impediment__c` — writes to it are rejected) and maps
  Airtable's free-text `Category` column onto `LDGCRM_Category__c`'s restricted 3-value picklist
  via an explicit table in the script, since two of the three Airtable strings don't match the
  Salesforce values verbatim (`"Relationship Issue"` → `"Relationship issue"`, `"Issue on their
  end"` → `"Issue on partner end"`).
- `logs/data-migration/Impediment-skipped-<timestamp>.csv` — Airtable rows with no `Name` (2 of
  41, both otherwise-empty placeholder rows), skipped rather than loaded with a placeholder.
- `logs/data-migration/Impediment-unmapped-category-<timestamp>.csv` — rows whose Category value
  doesn't match the script's mapping table; loaded anyway with Category left blank rather than
  blocked, but flagged for human review.

`Build-PartnerAccountLoad.ps1` queries Salesforce once (to resolve `Account Owner` emails to `User`
records — see `TRANSFORMATION-RULES.md` for why that lookup can't use the usual external-ID
passthrough) and writes:

- `data/salesforce-loads/LDGCRM_Partner_Account__c-upsert.csv` — external-ID-keyed rows. Requires
  `Account-update.csv` already loaded first (`LDGCRM_Account__c` is Master-Detail to Account).
- `logs/data-migration/PartnerAccount-skipped-<timestamp>.csv` — rows with no parent Account, or
  more than one (Master-Detail only supports one parent).
- `logs/data-migration/PartnerAccount-unmapped-owner-<timestamp>.csv` — rows whose owner email
  matches no Salesforce User; loaded anyway with Owner left blank.

`Build-ApplicationLoad.ps1` queries Salesforce twice — for the Partner Accounts and Opportunities
that actually exist — so it can skip rows that would be guaranteed load failures instead of
submitting them (the first load attempt submitted 442 such rows and got 442 errors back). It writes:

- `data/salesforce-loads/LDGCRM_application__c-upsert.csv` — external-ID-keyed rows whose parent
  Partner Account is confirmed present in the org. Deliberately does **not** include
  `LDGCRM_Broker_App_Parent__c` (needs a second pass, see "Load order").
- `logs/data-migration/Application-skipped-<timestamp>.csv` — rows skipped for a missing required
  Partner Account, split by reason: no Partner Account linked in Airtable at all, vs. linked but not
  loaded in the org (the latter almost always traces to an unresolved Account — see
  `AIRTABLE-DATA-QUALITY-REQUESTS.md`).
- `logs/data-migration/Application-overlength-<timestamp>.csv` — values Salesforce can't store as-is:
  Names over 80 chars (truncated), URLs over 255 chars (blanked), and implausible dates (blanked).
  All three are platform limits, not fixable field metadata.
- `logs/data-migration/Application-unmapped-rampup-<timestamp>.csv` — rows whose Ramp Up Approach
  value doesn't map; loaded anyway with the field blank.

Re-running it is the intended way to pick up newly-fixed data: rows skipped for an unresolved parent,
and Opportunity links blanked because Opportunity wasn't loaded yet, both resolve on a later run with
no code change. **Demonstrated 2026-08-13**: loading Opportunity and re-running this script dropped
the blank-Opportunity-link count from 92 to 7 with no edits.

`Build-ContactLoad.ps1` queries Salesforce (record types, existing Contacts, Accounts, Partner
Accounts) and writes:

- `data/salesforce-loads/Contact-upsert.csv` — one row per **merged** Contact, not per Airtable row.
- `data/salesforce-loads/Contact-identity-map.csv` — **an input to the Application-Contact junction
  chunk, not a review file.** Maps every Airtable Contact record ID to the Contact that survived the
  merge. The junction chunk must use this rather than re-deriving the grouping, or the two can drift.
- `logs/data-migration/Contact-name-review-<ts>.csv` — every Contact whose name was recovered from an
  existing Salesforce Contact or replaced with its email address as a placeholder.
- `logs/data-migration/Contact-no-account-<ts>.csv` — Contacts with no resolvable Account (each one
  would spawn a junk FCIC Account if the trigger weren't bypassed).
- `logs/data-migration/Contact-value-review-<ts>.csv` — dropped `Subscription Type` values.

`Build-OpportunityLoad.ps1` queries Salesforce for the Login_gov RecordTypeId and the reconciled
Account set (read-only), then writes:

- `data/salesforce-loads/Opportunity-upsert.csv` — external-ID-keyed rows. **Requires
  `Account-update.csv` loaded first**; rows whose Account isn't reconciled are skipped, not blanked,
  because an unresolvable lookup fails the whole row.
- `logs/data-migration/Opportunity-skipped-<timestamp>.csv` — split by reason: no Status (StageName is
  required with no default), no Account link in Airtable, or Account not reconciled in the org.
- `logs/data-migration/Opportunity-closedate-fallback-<timestamp>.csv` — **read this one.** Salesforce
  requires `CloseDate` but only 199 of 928 rows have a real `Est. Go Live`, so the rest fall back to
  the last status-change date, then the created date. Every fallback row is listed here with the field
  used, so a synthesized date is never mistaken for a forecast.
- `logs/data-migration/Opportunity-value-review-<timestamp>.csv` — values blanked or dropped
  (non-URL text in Url fields, over-length URLs, unmappable Focus Level or Demographic values).

See the full mapping table and current sandbox-state notes in the root `CLAUDE.md` under
"Airtable → Salesforce mapping".
