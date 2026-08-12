# Airtable → Salesforce migration pipeline

This directory holds the scripts that move Login.gov applicant data from Airtable into the
`gsa-peo` Salesforce sandbox (and eventually production). The pipeline has three stages that run
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
| `Build-PartnerAccountLoad.ps1`, `Build-ContactLoad.ps1`, `Build-OpportunityLoad.ps1` | Prep — independent parents | Not built |
| `Build-ApplicationLoad.ps1`, `Build-OpportunityImpedimentLoad.ps1`, `Build-ApplicationContactLoad.ps1` | Prep — dependent/junction objects | Not built |
| `Build-OpportunityContactRoleLoad.ps1` | Prep — blocked on an `sfdx-metadata-sync` fix (`OpportunityContactRole.LDGCRM_External_ID__c` needs `externalId=true`) | Not built |
| `Build-MeetingLoad.ps1` | Prep — Activity/Event, needs a default-duration convention for synthesized `StartDateTime`/`EndDateTime` | Not built |
| `Invoke-SalesforceLoad.ps1` | Load — generic `sf data upsert bulk`/`sf data update bulk` wrapper, any object | Built |

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
  -> LDGCRM_Opportunity_Impediment__c (needs LDGCRM_Impediment__c + Opportunity first)
  -> LDGCRM_Application_Contact__c
  -> OpportunityContactRole (blocked, see above)
  -> Activity / Meetings (needs Account + Opportunity first)
```

## Running what's built so far

```powershell
# From the repo root:
scripts\data-migration\Get-AirtableExport.ps1
scripts\data-migration\Build-AccountReconciliation.ps1
scripts\data-migration\Build-ImpedimentLoad.ps1

# Actually load a prepped CSV into gsa-peo (prompts "Type LOAD to continue"):
scripts\data-migration\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_Impediment__c" `
    -CsvFile "data\salesforce-loads\LDGCRM_Impediment__c-upsert.csv"

# Account uses -Operation Update (Id-keyed) instead of the Upsert default:
scripts\data-migration\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "Account" `
    -CsvFile "data\salesforce-loads\Account-update.csv" `
    -Operation Update
```

`Build-AccountReconciliation.ps1` is read-only against Salesforce (a single SOQL query) and only
writes local files:

- `data/salesforce-loads/Account-update.csv` — matched rows (`Id`, `LDGCRM_External_ID__c`,
  `LDGCRM_Market_Segment__c`, `Type`) ready for a Data Loader **update** (not upsert) once Stage 3
  exists.
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

See the full mapping table and current sandbox-state notes in the root `CLAUDE.md` under
"Airtable → Salesforce mapping".
