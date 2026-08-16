# logs/

Run output from everything in `scripts/`. **Gitignored** — it can contain PII pulled from Airtable
or a Salesforce org, so only `.gitkeep` and this `README.md` are tracked. Nothing else here should
ever be committed.

Structure mirrors `scripts/`:

| Folder | Produced by |
| --- | --- |
| `data-migration/` | Pulls, transforms, loads, rollbacks |
| `cleanup/` | Factory resets |

Both come from `powershell-scripts/`. The category names describe **what a run
did**, not which folder its script lives in — every script is in one folder now.

> **There is no `metadata/` category** (removed 2026-08-14). Metadata tooling —
> data dictionary, retrieve/sync — is a **development aid** that is not part of
> this bundle and is not the Operations team's responsibility. Metadata moves
> between orgs by **change set only**; nothing here pushes or pulls it. Those
> scripts and their output live in the engineering repository instead, and
> `Get-LogDirectory` accepts `cleanup` and `data-migration` only.

## One directory per run

**Everything a run produces goes in one folder**, named after the script that started it:
`logs/<category>/<ScriptName>-<timestamp>/`. Nothing is written loose.

That includes the steps of an orchestrated load. `Invoke-FullMigrationLoad.ps1` runs each transform
and loader as a **child process**, and they all write into the orchestrator's directory — so one
folder holds a dozen transcripts, twenty review CSVs, the bulk failure rows, the restore point and
the report. Every file in a run shares **one** timestamp, taken from the folder name.

> **Changed 2026-08-13.** Each script used to write its transcript and review CSVs loose into
> `logs/<category>/` *and* create its own typed folder — `full-load-<ts>/`, `notes-load-<ts>/`,
> `bulk-results/<obj>-<ts>/`, `rollback-<ts>/`, `account-bootstrap-<ts>/`. One logical load scattered
> output across four folder shapes plus ~30 loose files, correlated only by a timestamp — and since
> each child script stamped its own, the timestamps didn't even match. `logs/data-migration/` reached
> **330 loose CSVs across ~40 runs**.
>
> Now the first script to start publishes the run directory in `$env:LDGCRM_RUN_DIRECTORY` and
> `Get-LogDirectory` returns it, so every existing caller redirects into it unchanged. Run a script
> standalone and it gets its own run directory the same way.

---

## What each kind of run leaves behind

### A load that succeeded

```
data-migration/
  Invoke-FullMigrationLoad-20260813-142110/
    SUMMARY.txt                             ← START HERE. The whole run, in one file
    load-summary.csv                        one row per step
    errors.csv                              one row per distinct error, classified
    findings.csv                            one row per review CSV the run produced
    step-result-<Step>.json                 what each load step reported

    Invoke-FullMigrationLoad.log            the orchestrator's transcript
    Build-<Object>Load.log                  one per transform
    Invoke-SalesforceLoad-<Object>.log      one per load

    <Object>-skipped-<ts>.csv               review CSVs, from every transform
    <Object>-<jobid>-failed-records.csv     the rows Salesforce rejected, with payloads
    Load-<Object>-<ts>.json                 Bulk job result, written ON SUCCESS ONLY

    baseline-counts.csv                     per-object counts BEFORE the run
    external-ids-<Object>.csv               which records existed before  ← rollback needs these
    restore-point-Account.csv               pre-image of every Account
    fcic-junk-baseline.txt                  junk-Account count before the run
    post-load-counts.csv                    before / after / delta per object
```

That directory is also the **restore point**. It is what `Invoke-MigrationRollback.ps1` takes as its
`-RunDirectory`, and with no `external-ids-*.csv` a rollback is refused outright. Keep these.

> Rollback still accepts the old `external-ids/` **subfolder** layout, so a run directory written
> before 2026-08-13 can still be rolled back.

#### `SUMMARY.txt` — read this before anything else

One file answering "how did the load go, and was anything in it new?". It is also printed at the
end of the run, so it is the last thing in the transcript. Its sections, in order:

| Section | |
| --- | --- |
| **What loaded** | Per object: submitted, loaded, failed, **withheld** |
| **Load failures** | Split **UNEXPECTED** (stops the run) / **EXPECTED** (a known cause for that object) / **gone since the last run** |
| **Rows withheld** | Rows the transform never submitted, by reason |
| **Needs a human** | Where the pipeline refused to guess |
| **Loaded with a caveat** | Values derived, dropped or truncated on the way in |
| **Post-load validation** | The quiet failures a success count cannot show |
| **Where to look next** | |

**"Withheld" is the number to read first, and it is not a load error.** Those rows were never sent
to Salesforce, so no job result, exit code or success count mentions them anywhere. The 2026-08-13
reload failed 31 rows and *withheld* several hundred.

#### Every count is compared with the previous run

Each run reads the most recent earlier `Invoke-FullMigrationLoad-*/findings.csv` and `errors.csv`, so
lines read `62  Withheld - not submitted  (was 126, -64)`. Nothing maintains a list of expected
counts — a hard-coded expectation is wrong the moment Airtable is fixed, and a check that cries wolf
every run stops being read.

Consequences worth knowing:

- **The first run in a fresh clone has no baseline**, and says so rather than marking everything new.
- A cause that failed rows last run and none this run is listed under **gone since the last run**,
  not silently dropped — otherwise "we fixed it" and "the check stopped running" look identical.
- An empty review CSV is reported at **zero rows**, not omitted, for the same reason.
- Deleting old `Invoke-FullMigrationLoad-*` directories removes the baseline. Keeping the most
  recent one is enough.

### A load that failed

Same as above **minus** `Load-<Object>-*.json` — the loader writes that only on success, so its
absence is itself a signal.

**`SUMMARY.txt` is still written**, and a failed run is exactly the one worth reading it for: it
shows what the steps *before* the failure withheld, which is usually why the failing step failed.
The step that died reports `Outcome: "failed"` (or `"error"`) in its `step-result-<Step>.json`.

Get the per-row failures from the CLI using the job ID in the transcript:

```powershell
sf data bulk results --job-id 750cq00000C3JNNAA3 --target-org peodv8dvn
```

A failed run may also leave a partial `post-load-counts.csv` or none at all. That matters: a run
directory without it cannot be drift-checked by the rollback.

### A Notes load

Into the run directory alongside everything else — the same folder as the load that ran it, when it
runs as a step of `Invoke-FullMigrationLoad.ps1`:

```
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
  Invoke-SandboxFactoryReset-<timestamp>/
    Invoke-SandboxFactoryReset.log
    <Object>.csv                 the IDs it deleted, exported BEFORE deleting
    ContentDocument-ids.csv      migrated notes it removed
    cleanup-summary.csv          per-object outcome
```

These are the **only** record of what a hard delete removed. Hard deletes bypass the Recycle Bin and
are not recoverable, so treat this directory as the audit trail it is.

### A rollback

```
data-migration/Invoke-MigrationRollback-<timestamp>/
  deleted-<Object>.csv           what it removed, with external IDs
  restore-Account.csv            the values Accounts were restored to
  rollback-summary.csv           per-step outcome
  would-delete-*.csv             -PlanOnly runs only
```

A rollback gets its **own** run directory rather than writing into the load it is undoing — that
folder is the restore point, and an undo must not write into the evidence it is reading.

### Setup and inspection runs

Nothing writes here. The org-inspection tooling (data dictionary, metadata sync,
unexposed-field report) is engineering-only and logs outside this folder
entirely — see the note at the top.

What this bundle *does* do against the org before a load is **read to check**,
not retrieve: `Invoke-FullMigrationLoad.ps1` runs preflight counts, and several
transforms read live field definitions before deciding what to send. Those land
in the load's own run directory, above.

---

## The review CSVs are the actual output

Transcripts narrate; the review CSVs are what a run *found*. Every transform writes them for rows it
could not load, or loaded with a caveat.

**A full load now summarises all of them for you** — `SUMMARY.txt` groups every review CSV the run
produced by kind, with per-reason counts and a comparison against the previous run. Read that first
and open the individual files for the rows. These patterns are what it classifies on:

| Pattern | Meaning | Reported as |
| --- | --- | --- |
| `*-skipped-*.csv` | Not loaded, with the reason | Withheld |
| `*-no-account-*.csv` | No resolvable Account, so not loaded | Withheld |
| `*-pending-*.csv` | Deferred to a later pass | Withheld |
| `*-unmatched-*.csv` | Airtable rows matching no Salesforce record | Needs a human |
| `*-ambiguous-*.csv` | Matched more than one candidate — deliberately not guessed | Needs a human |
| `*-unresolved-owner-*.csv` / `*-unmapped-owner-*.csv` | Owner emails with no active, eligible Salesforce user | Needs a human |
| `*-conflict*-*.csv` | Sources disagree — not tie-broken | Needs a human |
| `*-domain-inferred-account-*.csv` | The only inferred links in the pipeline — worth spot-checking | Needs a human |
| `*-value-review-*.csv` | Values blanked or dropped because the target field wouldn't take them | Caveat |
| `*-name-review-*.csv` | Name derived rather than authored | Caveat |
| `*-overlength-*.csv` | Value truncated to fit the field | Caveat |
| `*-closedate-fallback-*.csv` | Required date defaulted | Caveat |

**A file matching none of these is still reported**, under "unclassified review output" — a new
transform inventing a new suffix must show up as unrecognised rather than vanish. If you add one,
add it to `$Script:LoadFindingKinds` in
[`powershell-scripts/Common.LoadReport.ps1`](../powershell-scripts/Common.LoadReport.ps1).

**Read these after every run.** Findings left unread here are the failure mode they exist to
prevent. Anything new — a row withheld for a reason not seen before, a count that moved without an
explanation — goes back to the migration team, who own the source-data fix list.

---

## Housekeeping

Nothing prunes this directory. Run directories accumulate, and each full load adds a restore point
containing a copy of every Account — a few MB per run.

Before deleting old runs, check you are not throwing away the only handle on something:

- a **`created-note-ids.csv`** for notes still in an org — `ContentNote` has no external ID, so this
  is the only way to find them again;
- a **factory reset's deleted-ID export** — the only record of what a hard delete removed;
- the **most recent load run**, which is both the restore point and the baseline the next run's
  `SUMMARY.txt` compares against.

Restore points for runs that have since been superseded are otherwise safe to remove.

For how to interpret what you find here, see
[`docs/operations/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md).
