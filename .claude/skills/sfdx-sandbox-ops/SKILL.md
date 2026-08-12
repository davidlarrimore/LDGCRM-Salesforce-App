---
name: sfdx-sandbox-ops
description: Safety checklist for running or modifying any script that deletes, hard-deletes, or bulk-modifies records in the gsa-peo sandbox (e.g. scripts/cleanup/cleanup-gsa-peo.ps1, future data-migration loads).
---

# Destructive sandbox operations (gsa-peo)

`gsa-peo` is a sandbox, not production — but it holds real (or real-shaped) Login.gov applicant data
during the migration, and mistakes here still cost real rework. Treat destructive operations against
it with real caution, not sandbox-so-it-doesn't-matter carelessness.

## Before running any destructive script

1. **Confirm the target org.** `sf org display --target-org gsa-peo` and check the instance URL /
   `isSandbox` in the output actually matches what you expect. Never run a destructive script against
   an alias you haven't just confirmed.
2. **Preflight with a read-only count first.** Show the user how many records will be affected
   (`SELECT COUNT() FROM <Object> WHERE ...`) before anything is deleted or modified —
   `scripts/cleanup/cleanup-gsa-peo.ps1` already does this; keep the pattern in any new script.
3. **Export before delete/modify.** Write the affected record IDs to a CSV in `logs/<category>/`
   before the destructive step runs, so there's an audit trail even though the folder is gitignored.

## Never bypass the confirmation gate

`cleanup-gsa-peo.ps1` requires the operator to type `HARD DELETE` verbatim before anything is deleted.
Don't:
- pre-answer or script around the `Read-Host` prompt,
- add a `-Force` / `-Confirm:$false` flag to skip it,
- run it non-interactively "to save time."

That prompt is the one safety gate before a permanent, non-recoverable delete (`--hard-delete`, not
Recycle Bin). If a task genuinely requires skipping it, that's a decision for the user to make
explicitly, not something to work around.

## Order of operations

Child/junction objects before parents when deleting, parents before children when loading — the
existing object order in `cleanup-gsa-peo.ps1` (`LDGCRM_Application_Contact__c`,
`LDGCRM_Opportunity_Impediment__c`, `LDGCRM_Application__c`, `Opportunity`, `Contact`,
`LDGCRM_Impediment__c`, `LDGCRM_Partner_account__c`, `Account`) reflects the master-detail/lookup
dependencies in the data model — don't reorder it without checking those dependencies still hold.

## Applies to future data-migration scripts too

Anything added under `scripts/data-migration/` that upserts, updates, or deletes at scale should
follow the same pattern: confirm org, preflight count, export-before-write, explicit typed
confirmation for anything irreversible, and logging via `scripts/common/Common.ps1` into
`logs/data-migration/`.
