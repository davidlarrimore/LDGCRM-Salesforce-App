# logs/

Run output from everything in `scripts/`. **Gitignored** — it can contain PII pulled from Airtable
or a Salesforce org, so only `.gitkeep` and this `README.md` are tracked. Nothing else here should
ever be committed.

Structure mirrors `scripts/`:

| Folder | Produced by |
| --- | --- |
| `data-migration/` | `scripts/data-migration/*.ps1` — pulls, transforms, loads, rollbacks |
| `cleanup/` | `scripts/cleanup/*.ps1` — factory resets |
| `metadata/` | `scripts/metadata/*.ps1` — data dictionary, metadata sync |

Every script opens a **transcript** named `<ScriptName>-<timestamp>.log` capturing its entire
console output, and shares that timestamp with any other file the run produces — so everything from
one run sorts together.

---

## What each kind of run leaves behind

### A load that succeeded

```
data-migration/
  Invoke-FullMigrationLoad-20260813-142110.log     full transcript
  full-load-20260813-142110/
    baseline-counts.csv                            per-object counts BEFORE the run
    external-ids/<Object>.csv                      which records existed before  ← rollback needs this
    restore-point-Account.csv                      pre-image of every Account
    fcic-junk-baseline.txt                         junk-Account count before the run
    post-load-counts.csv                           before / after / delta per object
  Build-<Object>Load-20260813-142110.log           one per transform
  Load-<Object>-20260813-142110.json               Bulk job result, written ON SUCCESS ONLY
```

The `full-load-<timestamp>/` directory is the **restore point**. It is what
`Invoke-MigrationRollback.ps1` takes as its `-RunDirectory`, and without the `external-ids/` folder
a rollback is refused outright. Keep these.

### A load that failed

Same as above **minus** `Load-<Object>-*.json` — the loader writes that only on success, so its
absence is itself a signal. Get the per-row failures from the CLI using the job ID in the transcript:

```powershell
sf data bulk results --job-id 750cq00000C3JNNAA3 --target-org peodv8dvn
```

A failed run may also leave a partial `post-load-counts.csv` or none at all. That matters: a run
directory without it cannot be drift-checked by the rollback.

### A Notes load

```
data-migration/notes-load-<timestamp>/
  created-note-ids.csv          THE ONLY HANDLE ON MIGRATED NOTES
  contentnote-batch-N.json      request bodies actually sent
  no-edit-access.csv            parents the preflight rejected, if any
  failures.csv                  per-record failures, if any
```

**`created-note-ids.csv` is not optional.** `ContentNote` permits no custom fields, so a migrated
note carries no external ID and cannot be found by querying for one. This file is the only record of
what a run created. It is written after **every** batch, not at the end, precisely so an interrupted
run is still recoverable.

If a Notes run dies before writing it, the notes exist and are effectively orphaned. Find them by
looking for `SNOTE` documents linked only to a User:

```powershell
sf data query -q "SELECT ContentDocumentId, LinkedEntityId, LinkedEntity.Type FROM ContentDocumentLink WHERE ContentDocument.FileType = 'SNOTE'" --target-org peodv8dvn --result-format csv
```

### A factory reset

```
cleanup/
  Invoke-SandboxFactoryReset-<timestamp>.log
  sandbox-factory-reset-<timestamp>/
    <Object>.csv                 the IDs it deleted, exported BEFORE deleting
    ContentDocument-ids.csv      migrated notes it removed
    cleanup-summary.csv          per-object outcome
```

These are the **only** record of what a hard delete removed. Hard deletes bypass the Recycle Bin and
are not recoverable, so treat this directory as the audit trail it is.

### A rollback

```
data-migration/rollback-<timestamp>/
  deleted-<Object>.csv           what it removed, with external IDs
  restore-Account.csv            the values Accounts were restored to
  rollback-summary.csv           per-step outcome
  would-delete-*.csv             -PlanOnly runs only
```

### Setup and inspection runs

```
metadata/
  Get-LDGCRMDataDictionary-<timestamp>.log
  ldgcrm-data-dictionary-<timestamp>.csv          every object/field, flattened
  Sync-Metadata-<timestamp>.log
  UnexposedLDGCRMFields-<timestamp>.csv           fields present but not on a layout
```

---

## The review CSVs are the actual output

Transcripts narrate; the review CSVs are what a run *found*. Every transform writes them for rows it
could not load, or loaded with a caveat.

| Pattern | Meaning |
| --- | --- |
| `*-skipped-*.csv` | Not loaded, with the reason |
| `*-unmatched-*.csv` | Airtable rows matching no Salesforce record |
| `*-ambiguous-*.csv` | Matched more than one candidate — deliberately not guessed |
| `*-unresolved-owner-*.csv` | Owner emails with no active, eligible Salesforce user |
| `*-value-review-*.csv` | Values blanked or dropped because the target field wouldn't take them |
| `*-domain-inferred-account-*.csv` | The only inferred links in the pipeline — worth spot-checking |

**Read these after every run.** Findings left unread here are the failure mode they exist to
prevent; anything new belongs in
[`docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md`](../docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md).

---

## Housekeeping

Nothing prunes this directory. Run directories accumulate, and each full load adds a restore point
containing a copy of every Account — a few MB per run.

Before deleting old runs, check you are not throwing away the only handle on something: a
`created-note-ids.csv` for notes still in an org, or a factory reset's deleted-ID export. Restore
points for runs that have since been superseded are generally safe to remove.

For how to interpret what you find here, see
[`docs/operations/TROUBLESHOOTING.md`](../docs/operations/TROUBLESHOOTING.md).
