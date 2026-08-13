---
name: sfdx-data-migration
description: Use when building or running Data Loader / sf-CLI-based migration scripts that move Login.gov applicant data from Airtable exports into a GSA PEO Salesforce org.
---

# Airtable → Salesforce data migration

`scripts/data-migration/` holds `Get-AirtableExport.ps1` (pulls source data straight from the Airtable
REST API — see CLAUDE.md's "Scripts" section) plus, eventually, the upsert/load scripts that move that
data into a GSA PEO org. This skill is the convention to follow when adding those.

## Where things live

- **Source extracts:** `data/airtable-exports/<Table>.json` (gitignored — PII), written by
  `Get-AirtableExport.ps1` and overwritten each run — always current Airtable state, not a history.
- **Field mappings:** `data/mappings/` (gitignored) — Data Loader `.sdl` files or equivalent
  object/field mapping docs.
- **Scripts:** `scripts/data-migration/*.ps1`.
- **Run output:** `logs/data-migration/` (gitignored), via `scripts/common/Common.ps1`.

## Required conventions for new scripts

1. **Dot-source the shared helpers**, same as every other script in this repo:
   ```powershell
   . (Join-Path $PSScriptRoot "..\common\Common.ps1")
   $Timestamp = Start-ScriptLog -Category "data-migration" -ScriptName "<Name>"
   # ... work ...
   # in a finally block:
   Stop-ScriptLog
   ```
2. **Windows PowerShell 5.1+ (`#Requires -Version 5.1`), no PS7-only syntax.** Use `Join-Path`/`Split-Path`
   (two-argument form), never hardcoded backslashes; avoid `??`, `?.`, ternary `?:`, `-AsHashtable`, `-Parallel`.
3. **Upsert on `LDGCRM_External_ID__c`, not insert.** Every migrated record must carry this external
   ID so re-running a load updates existing records instead of duplicating them:
   ```bash
   sf data upsert bulk --sobject <Object> --external-id LDGCRM_External_ID__c --file <csv> --target-org peodv8dvn
   ```
   (or the equivalent Data Loader upsert config, if using Data Loader directly rather than `sf`.)
4. **Load order follows the data model's dependencies** — parents before children/junctions:
   Account / `LDGCRM_Partner_account__c` before `LDGCRM_Application__c`, Contact before
   `LDGCRM_Application_Contact__c`, Opportunity before `LDGCRM_Opportunity_Impediment__c`, etc. This
   is the reverse of the delete order in `scripts/cleanup/Invoke-SandboxFactoryReset.ps1` — that script's object
   list is a ready reference for the dependency order either direction.
5. **Dry run before a full load.** Validate mapping and row counts against a small batch (or a
   CSV-only export step) before loading everything — Bulk API loads at scale are hard to partially
   undo. See `sfdx-sandbox-ops` for the broader safety checklist (preflight counts, export-before-write,
   explicit confirmation) that applies here too.

## Known gotchas (from the 2026-08-12 export)

Full table→object mapping and current sandbox state live in `CLAUDE.md` under "Airtable → Salesforce
mapping" — read that first. The short version of what will bite a naive load:

- **Account and Market Segment are already migrated** (531/531 Accounts, 6/6 Market Segments exist in
  the Dev sandbox; 527 Accounts already carry a `rec...` `LDGCRM_External_ID__c`). Don't re-insert them —
  reconcile the remaining Airtable Account rows (757 in Airtable vs. 531 in Salesforce) against what's
  there by external ID, then by name, and surface unmatched rows for human review instead of
  auto-creating new Accounts.
- **`OpportunityContactRole.LDGCRM_External_ID__c` has `externalId=false`** — fix that field's metadata
  before this object can be loaded with `sf data upsert bulk --external-id`.
- **`LDGCRM_Market_Segment__c.LDGCRM_External_ID__c` stores the segment name**, not the Airtable
  `rec...` ID other objects use — match on name for this object, or backfill the `rec...` ID first if
  you want it consistent with everything else.
- Airtable cells that hold multiple linked records (e.g. Impediments' `Opportunities blocked` /
  `Opportunities requested`, or an Application's multiple Contacts) come through `Get-AirtableExport.ps1`'s
  JSON as real arrays of `rec...` IDs (not the comma-joined strings a CSV export would give you) — split
  each array into one junction row per linked record.

## Before running a load

This writes to shared sandbox state. Confirm scope (which objects, how many records, upsert vs.
insert) with the user before running, the same as any other hard-to-reverse action — even though the
target is a sandbox, migration data is expensive to reconstruct if a load goes wrong.
