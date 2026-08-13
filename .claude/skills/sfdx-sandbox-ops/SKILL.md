---
name: sfdx-sandbox-ops
description: Safety checklist for running or modifying any script that deletes, hard-deletes, or bulk-modifies records in a GSA PEO org (Dev sandbox by default) (e.g. scripts/cleanup/Invoke-OrgCleanup.ps1, future data-migration loads).
---

# Destructive org operations (Dev/QA/Full/Prod)

The Dev and QA sandboxes are not production — but they hold real (or real-shaped) Login.gov applicant data
during the migration, and mistakes here still cost real rework. Treat destructive operations against
it with real caution, not sandbox-so-it-doesn't-matter carelessness.

## Pick the environment explicitly

Scripts take `-Environment Dev|QA|Full|Prod` (default `Dev`) and resolve the alias from
`scripts/common/Common.Orgs.ps1`. Never pass a bare `--target-org`/`-OrgAlias` to reach a registered
environment — that skips the registry's identity checks.

**`gsa-peo` means PRODUCTION** as of 2026-08-13; it used to be the alias for the Dev sandbox
(`peodv8dvn`). Anything older referring to `gsa-peo` meant Dev. Never re-create that alias pointing
at a sandbox.

`Prod` is gated twice — `Assert-LdgcrmProductionConsent` requires the operator to type the org alias
in full, *in addition to* the script's own typed confirmation. That is not optional and not
something to route around.

## Before running any destructive script

1. **Confirm the target org.** `Assert-LdgcrmOrgTarget -Environment <env>` does this and refuses to
   continue if the alias resolves to an org that disagrees with the registry (instance URL vs
   expected sandbox name, and `Organization.IsSandbox` queried from the org — `sf org display`
   doesn't report it and `sf org list` reads a local cache). Never run a destructive script against
   an alias you haven't just confirmed.
2. **Preflight with a read-only count first.** Show the user how many records will be affected
   (`SELECT COUNT() FROM <Object> WHERE ...`) before anything is deleted or modified —
   `scripts/cleanup/Invoke-OrgCleanup.ps1` already does this; keep the pattern in any new script.
3. **Export before delete/modify.** Write the affected record IDs to a CSV in `logs/<category>/`
   before the destructive step runs, so there's an audit trail even though the folder is gitignored.

## Never bypass the confirmation gate

`Invoke-OrgCleanup.ps1` requires the operator to type `HARD DELETE` verbatim before anything is deleted.
Don't:
- pre-answer or script around the `Read-Host` prompt,
- add a `-Force` / `-Confirm:$false` flag to skip it,
- run it non-interactively "to save time."

That prompt is the one safety gate before a permanent, non-recoverable delete (`--hard-delete`, not
Recycle Bin). If a task genuinely requires skipping it, that's a decision for the user to make
explicitly, not something to work around.

## Order of operations

Child/junction objects before parents when deleting, parents before children when loading — the
existing object order in `Invoke-OrgCleanup.ps1` (`LDGCRM_Application_Contact__c`,
`LDGCRM_Opportunity_Impediment__c`, `LDGCRM_Application__c`, `Opportunity`, `Contact`,
`LDGCRM_Impediment__c`, `LDGCRM_Partner_account__c`, `Account`) reflects the master-detail/lookup
dependencies in the data model — don't reorder it without checking those dependencies still hold.

## Applies to future data-migration scripts too

Anything added under `scripts/data-migration/` that upserts, updates, or deletes at scale should
follow the same pattern: confirm org, preflight count, export-before-write, explicit typed
confirmation for anything irreversible, and logging via `scripts/common/Common.ps1` into
`logs/data-migration/`.
