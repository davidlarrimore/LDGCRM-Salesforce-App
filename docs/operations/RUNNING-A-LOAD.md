# Running a data load

How to move Airtable data into Salesforce, end to end. Assumes you have worked through
[SETUP.md](SETUP.md) and can reach both systems.

**If anything fails, go to [TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — it lists every failure this
pipeline has actually produced, what the error text means, and what to do. Several of them look
alarming and are expected.

---

## The shape of the thing

Three stages, and they are deliberately separate:

```
   PULL                    TRANSFORM                      LOAD
   ────                    ─────────                      ────
   Airtable  ──────────►   Build-*.ps1        ──────────► Invoke-SalesforceLoad.ps1
   REST API                reads Airtable JSON            writes to Salesforce
                           + queries Salesforce
   Get-AirtableExport      (READ-ONLY)                    (the only step that writes)
        │                       │                              │
        ▼                       ▼                              ▼
   data/airtable-exports/  data/salesforce-loads/         the org
   <Table>.json            <Object>-upsert.csv
```

**Nothing writes to Salesforce except the load step.** Every `Build-*.ps1` transform is read-only
against the org — it queries to find out what already exists, then writes a CSV to disk. You can run
transforms as often as you like, on any environment, without consequence. That separation is the
main safety property of this pipeline: you can always look at exactly what *would* be written before
anything is.

### Why order matters, and why getting it wrong is quiet

The objects form a dependency chain — a child record cannot reference a parent that doesn't exist
yet. Getting the order wrong **does not fail loudly**. Every transform skips rows whose parent isn't
in the org, so a mis-ordered run produces a *smaller* migration and a clean-looking summary.

That is the failure this pipeline is built to prevent, and it is why there is an orchestrator that
knows the order rather than a list of eighteen commands in a document.

---

## The normal case: run the whole thing

One script runs every transform and every load in dependency order:

```powershell
# ALWAYS do this first. Runs every transform (read-only), captures a restore
# point, and reports exactly what each step would load. Writes nothing.
powershell scripts/data-migration/Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly

# Then apply it
powershell scripts/data-migration/Invoke-FullMigrationLoad.ps1 -Environment Dev -Confirmation "LOAD"
```

That is the whole job in the ordinary case. The rest of this document is what the steps are, how to
approve them, how to resume when one fails, and how to check the result.

### What `-PlanOnly` gives you

It is not a simulation — it genuinely runs every transform against the real org, read-only. So it
proves each script executes, can reach Salesforce, and reports the true row counts it would load. It
also captures the **restore point** (see [ROLLBACK.md](ROLLBACK.md)), which costs nothing and is
occasionally exactly what you want.

Treat a `-PlanOnly` run as the readiness check. If it is clean, the load usually is too.

### The steps, in order

| # | Step | Object | Why here |
| --- | --- | --- | --- |
| 1 | `MarketSegment` | `LDGCRM_Market_Segment__c` | **First** — everything downstream derives its Market Segment from these |
| 2 | `Impediment` | `LDGCRM_Impediment__c` | No lookups — can go first |
| 3 | `Account` | Account | **UPDATE, not upsert** — Accounts pre-exist and are matched, never created |
| 4 | `PartnerAccount` | `LDGCRM_Partner_Account__c` | Master-Detail child of Account |
| 5 | `Contact` | Contact | Disables another app's trigger — see below |
| 6 | `Opportunity` | Opportunity | Must precede Application |
| 7 | `Application` | `LDGCRM_application__c` | Needs Partner Account *and* Opportunity |
| 8 | `PopulateBrokerParent` | `LDGCRM_application__c` | **Second pass, creates nothing** — fills `LDGCRM_Broker_App_Parent__c` on Applications step 6 already made |
| 9 | `OpportunityImpediment` | `LDGCRM_Opportunity_Impediment__c` | Two Master-Details, both must exist |
| 10 | `ApplicationContact` | `LDGCRM_Application_Contact__c` | Junction — needs both sides |
| 11 | `OpportunityContactRole` | `OpportunityContactRole` | **Insert + read-then-diff**, never upsert |
| 12 | `Notes` | `ContentNote` | **Last** — a note attaches to a record that must already exist |

Three of those deserve a sentence, because they are the ones that surprise people:

- **Account is an UPDATE.** This migration does not create Accounts. They already exist in
  Salesforce, so Airtable rows are *matched* onto them and the matched record is updated with an
  external ID and a couple of fields. Rows that match nothing are reported for human review, never
  auto-created.
- **`OpportunityContactRole` cannot be upserted.** Salesforce forbids External ID fields on that
  object entirely — there is no metadata fix. It is loaded by reading what exists, diffing, and
  inserting only what's missing.
- **Notes load over REST, not Bulk.** `ContentNote.Content` is a binary field and Bulk API rejects
  it outright. It has its own loader.

---

## Approving a load

Every write is gated by a **typed token** — the same word the interactive prompt would ask a human
to type:

| Token | Script |
| --- | --- |
| `-Confirmation "LOAD"` | `Invoke-SalesforceLoad.ps1`, `Invoke-NotesLoad.ps1`, `Invoke-FullMigrationLoad.ps1` |
| `-Confirmation "HARD DELETE"` | `Invoke-SandboxFactoryReset.ps1` |
| `-Confirmation "BOOTSTRAP"` | `Invoke-AccountBootstrap.ps1` |
| `-Confirmation "ROLLBACK"` | `Invoke-MigrationRollback.ps1` |

Comparison is **case-sensitive**. Every non-interactive approval prints an audit banner into the run
transcript recording who approved what, from which machine, when.

**Why a token and not a `-Force` switch:** a token states *what* is being approved and cannot travel
between commands by habit — you cannot paste a load approval into a delete. A boolean reads
identically on every command and gets copied without thought, which is precisely the failure a
confirmation gate exists to prevent. Do not add one.

### Production needs a second, different token

```powershell
-Confirmation "LOAD" -ProductionConfirmation gsa-peo
```

Two distinct flags on purpose: an operator who automated a sandbox run **cannot** retarget it at
production by changing `-Environment` alone. Never bake `-ProductionConfirmation` into a saved
script, a scheduled job or a CI variable. A production migration is a supervised event, not a job
that can fire on its own.

---

## When a step fails

The sequence **stops at the first failure**, by design — everything downstream of a failed step
would silently withhold rows that depend on it. It tells you how to resume:

```powershell
# Resume from a named step once the cause is fixed
powershell scripts/data-migration/Invoke-FullMigrationLoad.ps1 `
    -Environment Dev -StartAtStep Contact -Confirmation "LOAD"

# Or run a specific subset
powershell scripts/data-migration/Invoke-FullMigrationLoad.ps1 `
    -Environment Dev -OnlySteps "Impediment,Account" -Confirmation "LOAD"
```

Step names are the ones in the table above.

> ### ⚠️ Two steps fail *as their correct outcome*, and will stop the sequence every time
>
> **This is the single most confusing thing about running this pipeline**, so read it before you
> conclude something is broken.
>
> `Invoke-SalesforceLoad.ps1` exits non-zero if *any* row fails. But some steps have known,
> documented, expected failures:
>
> | Step | Expected failures | Cause |
> | --- | --- | --- |
> | `PartnerAccount` | ~20 of 94 | Their parent Account is one of the unmatched Airtable rows |
> | `Application` | varies | Rows whose parent isn't loaded, if run out of order |
>
> So a healthy run still reports `PartnerAccount ... LOAD FAILED (exit 1)` and halts.
>
> **Verify it is the expected failure, then resume past it** — do not re-run the step:
>
> ```powershell
> # 74 tagged + 2 pre-existing = 76 means it did exactly what it should
> sf data query -q "SELECT COUNT() FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" --target-org peodv8dvn
>
> powershell scripts/data-migration/Invoke-FullMigrationLoad.ps1 `
>     -Environment Dev -StartAtStep Contact -Confirmation "LOAD"
> ```
>
> To prove the failures are the known cause rather than something new, check that each missing row's
> parent external ID is absent from the org's tagged Accounts. On 2026-08-13 that accounted for
> 20 of 20. [TROUBLESHOOTING.md](TROUBLESHOOTING.md#a-step-reports-load-failed-but-the-counts-look-right)
> has the script.

---

## Running one piece at a time

Sometimes you want a single object — re-running a transform after an Airtable fix, say.

```powershell
# 1. Pull fresh Airtable data (OVERWRITES data/airtable-exports/)
powershell scripts/data-migration/Get-AirtableExport.ps1

# ...or just one or two tables
powershell scripts/data-migration/Get-AirtableExport.ps1 -Tables "Contacts,Opportunities"

# 2. Transform (read-only — safe to run any time)
powershell scripts/data-migration/Build-OpportunityLoad.ps1 -Environment Dev

# 3. Load
powershell scripts/data-migration/Invoke-SalesforceLoad.ps1 -Environment Dev `
    -ObjectApiName "Opportunity" `
    -CsvFile "data/salesforce-loads/Opportunity-upsert.csv" `
    -Operation Upsert -Confirmation "LOAD"
```

`-Operation` is `Upsert` (default), `Update` or `Insert`. Account uses `Update`;
`OpportunityContactRole` uses `Insert`.

> **A fresh Airtable pull overwrites `data/airtable-exports/` in place** and shifts every count you
> may be comparing against. If you are reproducing documented figures, do **not** re-pull. The run
> transcript and a summary CSV still land in `logs/data-migration/`, so run history isn't lost —
> only the data snapshot is.

### The Contact step disables another team's trigger

Contact is the one load that touches configuration owned by a different application. The org hosts
an unrelated app (FCIC) whose Contact trigger creates a junk Account named after the person for
**every Contact inserted with a blank `AccountId`**. That app ships a supported kill switch, and the
loader uses it:

```powershell
-DisableTriggerControl "Contact"
```

It captures the current value, switches it off for the load, and restores it in a `finally` block
with a **verifying re-query** — so it is restored even when the load throws, which has been proven
under real failure. The orchestrator passes this automatically.

**Check it afterwards anyway.** Leaving it off silently breaks another team's app:

```powershell
sf data query -q "SELECT Name, On__c FROM TriggerControls__c WHERE Name = 'Contact'" --target-org peodv8dvn
```

---

## Preparing a sandbox from scratch

Only for sandboxes — this is how you get a clean, repeatable starting point for a rehearsal.

```powershell
# Deletes every migrated record, then rebuilds the Account tree from the production export
powershell scripts/cleanup/Invoke-SandboxFactoryReset.ps1 `
    -Environment Dev -BootstrapAccounts -Confirmation "HARD DELETE"
```

Two things it does, and both matter:

1. **Hard-deletes every record this migration created** — scoped strictly to rows carrying
   `LDGCRM_External_ID__c`, in child-before-parent order, exporting the IDs first as an audit trail.
   Hard delete means **permanent**, not the Recycle Bin.
2. **Rebuilds the Account universe** from `data/peo-prod-accounts-<date>.xls`, because deleting is
   only half a rebuild. This migration *matches onto* existing Accounts rather than creating them,
   so an emptied org gives the downstream loads nothing to attach to.

**It cannot target production, by construction rather than by policy.** `-Environment` doesn't
accept `Prod` (rejected at parameter binding), the registry's production flag aborts the run, and
`Organization.IsSandbox` is read from the org itself to close the `-OrgAlias` escape hatch. There is
deliberately no production confirmation prompt — offering one would only create a way to approve it
by mistake.

Records **without** an external ID survive: pre-existing test data, and the bootstrapped Accounts
themselves. That is what makes the bootstrap safely repeatable.

For the full wipe-and-reload procedure with verification at every stage, use
[RELOAD-QA-CHECKLIST.md](RELOAD-QA-CHECKLIST.md).

---

## Who ends up owning the records

Ownership is decided **at load time** and it is not cosmetic: these objects use
org-wide-default-restricted sharing with owner-based rules, so the owner decides **who can see the
record**.

The rule: if the Airtable owner matches an **active** Salesforce user who is **eligible to own
records**, assign it to them; otherwise assign a **named fallback owner**
(`peter.marks@gsa.gov`, overridable per run with `-FallbackOwnerEmail`).

| Object | Owner comes from |
| --- | --- |
| Opportunity | Airtable's `Pod Opportunity Lead` |
| `LDGCRM_application__c` | Its Partner Account's owner |
| Contact | Its resolved Account's owner |
| `LDGCRM_Impediment__c` | *nothing in Airtable* — always the fallback |
| `LDGCRM_Partner_Account__c` | **n/a** — Master-Detail child, inherits Account's owner |

Three things to know before a production run:

1. **"Active" is not the same as "can own a record."** Chatter Free, portal and community users are
   active and can own nothing. Assigning one fails with `OP_WITH_INVALID_USER_TYPE_EXCEPTION`, an
   error naming neither the field nor the user. The resolvers filter on `UserType = 'Standard'`
   because of this.
2. **A re-run re-asserts the fallback owner.** Because the fallback is written explicitly rather
   than left blank, a fallback-owned record that someone manually reassigns gets pushed back on the
   next load. That is a deliberate trade — the alternative hands thousands of records to whichever
   engineer ran the job — but it means manual ownership changes belong *after* the final load.
3. **Run production loads as a dedicated integration user, not a personal login.** Otherwise "the
   loading user" is whoever was on shift, and records land on someone with no relationship to them.
   There is already precedent in this org: a service account owns 651 production Accounts for
   exactly this reason.

---

## Checking the result

**Success counts are not evidence.** Every serious defect in this migration passed its load and was
found by looking at something else. The orchestrator runs a post-load validation automatically, but
walk these regardless.

### Start with the run report

**Everything the run produced is in one folder:**
`logs/data-migration/Invoke-FullMigrationLoad-<ts>/` — every transcript, every review CSV, the bulk
failure rows, the restore point and the report, all sharing one timestamp.

`Invoke-FullMigrationLoad.ps1` writes **`SUMMARY.txt`** into it and prints it as the last thing in
the transcript. Read it before anything else — it is the whole run in one file, including everything
the individual review CSVs found, compared against the previous run.

Read it in this order:

1. **UNEXPECTED load failures.** Rows Salesforce rejected for a cause not configured for that
   object. These stopped the run.
2. **ROWS WITHHELD.** The number most likely to surprise you, and **it is not a load error** — those
   rows were never sent, so no job result, exit code or success count mentions them anywhere. On the
   2026-08-13 reload, 31 rows failed and several hundred were withheld.
3. **The deltas.** Every line carries `(was N, ±M)` against the previous run. A count that moved
   without anyone changing anything is worth understanding; a count that moved *because* Airtable was
   fixed is the point.
4. **NEEDS A HUMAN**, then **LOADED WITH A CAVEAT**.

A cause that failed rows last run and none this run appears under **gone since the last run** rather
than just vanishing, so a fix is visible as a fix.

**The first run has nothing to compare against** and says so. So does the first run after old
`Invoke-FullMigrationLoad-*` directories are deleted — keep the most recent one.

### Automatic

`Invoke-FullMigrationLoad.ps1` finishes with a **POST-LOAD VALIDATION** block covering before/after
counts per object, junk Accounts created, the trigger switch, records owned by inactive users,
records missing a Market Segment, and — added 2026-08-13 — **whether the partner-portal fields
actually landed**. Anything it finds is printed as a problem and exits non-zero.

Those last checks compare the org against **the load file that was just written**, not a hard-coded
number, so they re-baseline themselves whenever Airtable changes instead of going stale and being
ignored. They exist because the Issuer Strings-sourced fields can go missing with no load error at
all: a stale export, or the admin email match ceasing to resolve, both produce a CSV that loads 100%
successfully with a field left blank.

Two things to know when reading that block:

- **`KNOWN INCOMPLETE` is a separate section from `PROBLEMS`, and does not fail the run.** It reports
  data that is legitimately missing while something outside this repo is pending — currently the
  Partner Portal Team fields, which are withheld until a change set clears their `Unique` setting.
  Kept separate deliberately: a run that is always red stops being read.
- **Only *fewer* records than intended is a problem.** More is normal — an upsert never deletes, so
  the org keeps rows from earlier, larger runs whose Airtable source has since been withheld.

### By hand

```powershell
# Record counts, total vs migration-tagged
foreach ($o in 'Account','Contact','Opportunity','LDGCRM_application__c','LDGCRM_Partner_Account__c') {
  $t = (sf data query -q "SELECT COUNT() FROM $o" --target-org peodv8dvn --json | ConvertFrom-Json).result.totalSize
  $x = (sf data query -q "SELECT COUNT() FROM $o WHERE LDGCRM_External_ID__c != null" --target-org peodv8dvn --json | ConvertFrom-Json).result.totalSize
  "{0,-30} {1,6} total {2,6} migrated" -f $o, $t, $x
}

# Ownership distribution
sf data query -q "SELECT Owner.Name, COUNT(Id) FROM Opportunity WHERE LDGCRM_External_ID__c != null GROUP BY Owner.Name ORDER BY COUNT(Id) DESC" --target-org peodv8dvn --result-format csv

# No record should be owned by an inactive user
sf data query -q "SELECT COUNT() FROM Opportunity WHERE Owner.IsActive = false AND LDGCRM_External_ID__c != null" --target-org peodv8dvn

# The trigger switch must be back on
sf data query -q "SELECT Name, On__c FROM TriggerControls__c WHERE Name = 'Contact'" --target-org peodv8dvn

# Partner Portal Admin flags. A count of 0 means the SOURCE broke, not that nobody
# is an admin - both Contacts.Roles and Issuer Strings would have to be silent at
# once, which in practice means the Airtable export is missing Issuer Strings.json.
sf data query -q "SELECT COUNT() FROM LDGCRM_Application_Contact__c WHERE LGDCRM_P3_Partner_Portal_Admin__c = true" --target-org peodv8dvn

# Partner Portal Team. Expect 0 until the change set clears Unique on both fields;
# after that, ~422 of the loaded Applications.
sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_P3_Team_UUID__c != null" --target-org peodv8dvn
```

Then walk **Phase 5b** of [RELOAD-QA-CHECKLIST.md](RELOAD-QA-CHECKLIST.md) — it covers the same
ground with the expected figures and what each failure actually means.

### Side effects — the things that go wrong quietly

- **Junk Accounts from the Contact trigger.** Measure a *delta*, not a total: some orgs permanently
  carry junk Accounts from earlier testing and the count never returns to zero.
  ```powershell
  sf data query -q "SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" --target-org peodv8dvn
  ```
- **Objects nobody loaded** — Event, Task, Case and Lead should be unchanged.
- **Pre-existing untagged test records** should still be at their previous counts.
- **Every review CSV in `logs/data-migration/`** from this run. `SUMMARY.txt` summarises all of them
  with per-reason counts, so start there and open the individual files for the rows. Findings sitting
  unread in `logs/` are the failure mode those files exist to prevent — see
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md#reading-the-logs).

---

## Coordinate before you write

**More than one person can load into these orgs.** At least one colleague uses the Data Loader GUI
against the same sandbox, and other teams share the org entirely — during one session on
2026-08-13, a third party created test records and two custom fields were deleted out from under a
running load.

Before any write, even a small test batch, check that nobody else is mid-load. Two load processes
against the same org can race or double-load.

---

## Where to go next

| You want to | Read |
| --- | --- |
| Undo a load | [ROLLBACK.md](ROLLBACK.md) |
| Diagnose a failure | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Wipe and reload a sandbox properly | [RELOAD-QA-CHECKLIST.md](RELOAD-QA-CHECKLIST.md) |
| Know what a specific field maps to | [../engineering/TRANSFORMATION-RULES.md](../engineering/TRANSFORMATION-RULES.md) |
| Fix the source data | [../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) |
