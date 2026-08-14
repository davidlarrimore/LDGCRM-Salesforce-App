# Undoing a load

`powershell-scripts\Invoke-MigrationRollback.ps1` reverses **one run** of
`Invoke-FullMigrationLoad.ps1`, using the restore point that run captured before it wrote anything.

---

## Read this before you rely on it

**This is a best-effort tidy-up, not a safety net.**

The real safety net for a production migration is a **backup taken immediately before the run and a
rehearsed restore path**, plus loading in stages small enough that "stop and fix forward" beats
"undo". Do not let the existence of this script justify skipping the backup.

Everything under [What it cannot do](#what-it-cannot-do) is a property of Salesforce, not a gap in
the implementation. None of it will be fixed by a better script.

---

## The asymmetry that shapes everything

**Undoing an insert is easy. Undoing an update is not.**

Most of this migration *creates* records — delete them and the org is back where it started. But the
pipeline also **updates records it does not own**:

| What | Overwrites | Recoverable by deleting? |
| --- | --- | --- |
| `Build-AccountReconciliation.ps1` | External ID, `Type`, Market Segment on Accounts that pre-date the migration by years | **No** |
| The ownership pass | `OwnerId` on Opportunity / Application / Contact | Only if the record is deleted outright |
| `Invoke-AccountBootstrap.ps1` | `ParentId` on Accounts that had none | **No** |

So the rollback does two different things to two different populations:

- **Created by the run → deleted.**
- **Updated by the run → restored from a pre-image, never deleted.**

Deleting a migrated record does not restore an updated one. That is the single most important thing
to understand here.

---

## How it knows what the run created

Not from the load CSVs. Those say what was *planned*, they get overwritten by any later transform
run, and they cannot tell a row that was inserted from one that already existed and was merely
updated.

Instead it uses the run's own external-ID capture:

```
created = (external IDs tagged in the org NOW) − (external IDs tagged BEFORE the run)
```

Measured on both sides. In a sandbox those two definitions usually agree; **in production they do
not**, and the difference is the entire point — a second production run must not delete the first
run's records.

> A run directory with **no `external-ids/` folder is refused**, rather than treated as "nothing was
> tagged beforehand". Missing data reads as *unknown*, and unknown must never authorise a delete.
> Run directories written before 2026-08-13 pre-date that capture and cannot be rolled back.

---

## Running it

```powershell
# ALWAYS dry-run first. Writes the full plan to logs/, changes nothing.
.\powershell-scripts\Invoke-MigrationRollback.ps1 `
    -Environment Dev `
    -RunDirectory logs/data-migration/full-load-20260813-132744 `
    -PlanOnly

# Apply it
.\powershell-scripts\Invoke-MigrationRollback.ps1 `
    -Environment Dev `
    -RunDirectory logs/data-migration/full-load-20260813-132744 `
    -Confirmation "ROLLBACK"
```

`-RunDirectory` is what scopes the rollback — it undoes **that run**, not "the migration" in general.
Each `Invoke-FullMigrationLoad.ps1` run prints its directory at the end; they live in
`logs/data-migration/Invoke-FullMigrationLoad-<timestamp>/`.

**Always `-PlanOnly` first.** It is free and it is how you find out that the plan is not what you
expected. On 2026-08-13 the dry run caught a real bug in the rollback script itself — it was reading
the wrong column from the note-id file and would have silently reported "0 notes" while 537 sat in
the org.

### What the plan looks like

```
  OBJECT                               BEFORE      NOW  CREATED
  LDGCRM_Application_Contact__c             0    1,878    1,878
  LDGCRM_Opportunity_Impediment__c          0      267      267
  OpportunityContactRole                    0      516      516
  ...
  ContentDocument (notes)                   -        -      537

  Accounts in pre-image                 1,355
  Changed since, to be restored           582
  In pre-image but now deleted              0

  HARD DELETE    5,752 record(s) created by this run
  HARD DELETE      537 note(s)
  UPDATE           582 Account(s) back to their pre-run values
```

Check those numbers against what you know the load did before approving.

### Options

| Flag | Effect |
| --- | --- |
| `-PlanOnly` | Report only, write nothing |
| `-Confirmation "ROLLBACK"` | Approve non-interactively. Its own token — a load approval cannot be pasted into a rollback |
| `-ProductionConfirmation <alias>` | Additionally required against production |
| `-SkipAccountRestore` | Delete only; leave Account field values as they are |
| `-NoteIdFile <path>` | Point at the created-note-ids file explicitly instead of auto-discovering it |
| `-IgnoreDrift` | Proceed despite the drift check below — see the warning |

---

## The drift check, and why it stops you

Rollback is scoped by a **baseline**, not by a run ID. So if another load ran *after* the one you
are rolling back, that load's records are also newer than this baseline and **would be deleted as
though this run had created them**.

The script therefore compares the org's current totals against the run's own `post-load-counts.csv`
and **stops if they disagree**:

```
THE ORG HAS CHANGED SINCE THIS RUN FINISHED:
  - Contact: 1,552 at end of run, 1,601 now
```

`-IgnoreDrift` overrides it, deliberately awkwardly. Use it only when you genuinely intend to undo
more than one run's worth of change.

---

## Rollback has a shelf life

It is safe in the minutes after a load and **increasingly destructive once users touch the data**.
Restoring the Account pre-image overwrites whatever anyone has changed since — the script cannot
distinguish "the migration set this" from "a human corrected it afterwards".

**That window, not the script, is the real constraint.** If a load happened yesterday and people
have been working in the org since, rolling back will destroy their work. Fix forward instead.

---

## What it cannot do

State these before anyone relies on the script:

- **Hard deletes are irreversible.** Rollback deletes; it cannot resurrect. Anything a factory reset
  removed is gone short of Salesforce's paid Data Recovery service.
- **It clobbers post-load human edits** — see the shelf life above.
- **Cascades delete more than the run created.** Removing an Account takes its Master-Detail Partner
  Accounts and their children with it, including any that pre-dated the run.
- **Flows, triggers and roll-ups fire on the way back out**, including automation from other apps
  that this repo does not control and cannot inspect.
- **Records updated on objects other than Account keep their new values.** Only Account has a
  pre-image.

---

## Why not just run the factory reset?

`Invoke-SandboxFactoryReset.ps1` deletes **everything carrying an external ID**. In a sandbox that
happens to be the same set the migration created, so it works. In production it is not: a second
migration run would delete the *first* run's records too. And the factory reset is blocked from
production by construction anyway.

A production rollback has to be scoped to **one run**. That is what this script is for.

---

## The audit trail

Every rollback writes to `logs/data-migration/rollback-<timestamp>/`:

| File | What it is |
| --- | --- |
| `deleted-<Object>.csv` | The records deleted, with their external IDs — the only record of what went |
| `restore-Account.csv` | The values Accounts were restored to |
| `rollback-summary.csv` | Per-step outcome |
| `would-delete-*.csv` | `-PlanOnly` only: what it would have deleted |

Keep these. They are gitignored (`logs/` carries PII) but they are the only evidence of the
operation.
