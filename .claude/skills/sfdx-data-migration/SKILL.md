---
name: sfdx-data-migration
description: Use when building or running Data Loader / sf-CLI-based migration scripts that move Login.gov applicant data from Airtable exports into the gsa-peo Salesforce sandbox.
---

# Airtable → Salesforce data migration (gsa-peo)

`scripts/data-migration/` is currently empty — it's the target location for every migration script
this work produces. This skill is the convention to follow when adding the first one.

## Where things live

- **Source extracts:** `data/airtable-exports/` (gitignored — PII).
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
2. **PowerShell 7+, cross-platform.** Use `Join-Path`/`Split-Path`, never hardcoded backslashes.
3. **Upsert on `LDGCRM_External_ID__c`, not insert.** Every migrated record must carry this external
   ID so re-running a load updates existing records instead of duplicating them:
   ```bash
   sf data upsert bulk --sobject <Object> --external-id LDGCRM_External_ID__c --file <csv> --target-org gsa-peo
   ```
   (or the equivalent Data Loader upsert config, if using Data Loader directly rather than `sf`.)
4. **Load order follows the data model's dependencies** — parents before children/junctions:
   Account / `LDGCRM_Partner_account__c` before `LDGCRM_Application__c`, Contact before
   `LDGCRM_Application_Contact__c`, Opportunity before `LDGCRM_Opportunity_Impediment__c`, etc. This
   is the reverse of the delete order in `scripts/cleanup/cleanup-gsa-peo.ps1` — that script's object
   list is a ready reference for the dependency order either direction.
5. **Dry run before a full load.** Validate mapping and row counts against a small batch (or a
   CSV-only export step) before loading everything — Bulk API loads at scale are hard to partially
   undo. See `sfdx-sandbox-ops` for the broader safety checklist (preflight counts, export-before-write,
   explicit confirmation) that applies here too.

## Before running a load against gsa-peo

This writes to shared sandbox state. Confirm scope (which objects, how many records, upsert vs.
insert) with the user before running, the same as any other hard-to-reverse action — even though the
target is a sandbox, migration data is expensive to reconstruct if a load goes wrong.
