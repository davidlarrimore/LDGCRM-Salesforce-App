# Running a data load

How to move Airtable data into Salesforce, end to end. Assumes you have worked through
[SETUP.md](SETUP.md) and can reach both systems.

**If anything fails, go to [TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — it lists every failure this
pipeline has actually produced, what the error text means, and what to do. Several of them look
alarming and are expected.

> **If you have not read [OVERVIEW.md](OVERVIEW.md), start there.** It explains the vocabulary this
> page uses without stopping to define it — object, upsert, transform, withheld, pre-flight, restore
> point — and what each of the 13 steps is actually for.

---

## The short version

Two commands, in this order, and the rest of this page is the detail behind them:

```powershell
# 1. Dry run. Executes every transform for real, writes NOTHING to Salesforce.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly

# 2. Apply it.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -Confirmation "LOAD"
```

Then read `SUMMARY.txt` in the run's folder under `logs/data-migration/`.

Everything below covers what those two commands do, how to approve them, what to do when a step
fails, and how to check the result properly — because **a clean run is not by itself evidence of a
correct one**.

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

## "Am I ready?" — the readiness check

One read-only command answers it, without starting a load:

```powershell
.\powershell-scripts\Test-LdgcrmReadiness.ps1 -Environment Dev

# ...or probe every registered org for reachability while you are at it
.\powershell-scripts\Test-LdgcrmReadiness.ps1 -Environment Dev -AllEnvironments

# ...or check the bundle and the Airtable pull with no org at all
.\powershell-scripts\Test-LdgcrmReadiness.ps1 -SkipOrgChecks
```

**It writes nothing, changes nothing and fixes nothing**, so it needs no confirmation token and is safe
against any environment including production. Every finding names the command that would fix it and
stops there. Exit code is 0 unless something FAILED; warnings do not fail it.

Six categories:

| | Checks |
| --- | --- |
| **Config** | `.env` present, the Airtable token's *shape* (a PAT starts `pat`; `key…` was removed by Airtable in Feb 2024), `data/` and `logs/` writable, the production Account export |
| **Airtable** | All 10 Migration tables pulled, row count each, age, and the **column shapes** that are load-bearing |
| **Environments** | Every registry entry probed for reachability and identity. Only the *target* failing is a FAIL — Full and Prod being unauthorized is reported as INFO, because that is normal |
| **Access** | Who you are, your profile and UserType, and whether the fallback owner resolves |
| **Metadata** | Each object exists, `LDGCRM_External_ID__c` is still `externalId=true`, and **every column in every load CSV** resolves to a real, writable field |
| **Automation** | The nine Flows, the trigger kill switch, Market Segment resolvability |

Two of those deserve a sentence, because they catch things nothing else does:

- **The column check is driven off the load CSVs, not a hard-coded field list**, so it cannot go stale
  — whatever the transforms emit today is what gets verified. It resolves `__r.` relationship headers
  back to the lookup on the object. This is what catches a field that exists in Dev and **not at all
  in QA**, which is a real difference between these orgs, not a hypothetical.
- **The Airtable check verifies SHAPE, not just presence.** A stale export can change a column's type
  rather than its values — Opportunities' identity-platform columns went from linked records to
  multi-selects, and a transform written for one reads the other as garbage.

### Wired into the load as `-Readiness`

```powershell
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -Readiness -Confirmation "LOAD"
```

Runs the check **before** pre-flight and refuses to start if anything failed. `-ContinueOnError` does
not override it: that switch is about a step failing partway through, this is a refusal to begin.

**Off by default**, because it costs a describe per object (~30s) and repeats work on a pipeline you
have already run today. Pass it when it earns that: the first load into an org you have not loaded
before, after a change set lands, or any time you are about to write to QA, Full or Prod.

> **Readiness and pre-flight are not the same check and neither replaces the other.** Pre-flight asks
> *"will this run behave correctly?"* — Flows, duplicate rules, the trigger switch — and **always
> runs**, with or without `-Readiness`. Readiness asks the earlier question: *"is this machine, this
> pull and this org's SHAPE ready at all?"* Passing readiness disarms no pre-flight check.

---

## The normal case: run the whole thing

One script runs every transform and every load in dependency order:

```powershell
# ALWAYS do this first. Runs every transform (read-only), captures a restore
# point, and reports what each step found. Writes nothing.
# NOTE: on a freshly RESET org its row counts collapse to near zero by design -
# see "What -PlanOnly gives you" below before reading anything into them.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly

# Then apply it
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -Confirmation "LOAD"
```

That is the whole job in the ordinary case. The rest of this document is what the steps are, how to
approve them, how to resume when one fails, and how to check the result.

### What `-PlanOnly` gives you

It is not a simulation — it genuinely runs every transform against the real org, read-only. So it
proves each script executes, can reach Salesforce, and reads real data. It also captures the
**restore point** (see [ROLLBACK.md](ROLLBACK.md)), which costs nothing and is occasionally exactly
what you want.

> ### ⚠️ On a freshly reset org, `-PlanOnly` row counts are MEANINGLESS below the first few steps
>
> This surprises everyone once, and it is the direct consequence of `-PlanOnly` being honest rather
> than simulated. Each transform asks the org which parents exist. `-PlanOnly` **writes nothing**, so
> every step after the roots queries an org that is still empty, finds no parents, and withholds
> everything. The withholding then cascades: no Accounts loaded → Opportunity withholds; no Partner
> Accounts → Application withholds; no Applications → both junctions and Notes withhold.
>
> Measured on a just-reset Dev, 2026-08-16: **918 rows planned against ~8,500 that a real load
> produces.** Opportunity planned **3 of 904**, Application **0 of 1,058**, and every junction 0.
> Nothing was wrong.
>
> **What `-PlanOnly` still tells you truthfully here**, because these steps do not depend on anything
> the run would have loaded:
>
> | Step | Trustworthy after a reset? |
> | --- | --- |
> | `MarketSegment`, `Impediment` | ✅ Yes — no lookups at all |
> | `AccountCreate`, `Account` | ✅ Yes — they match against Accounts the **bootstrap** created |
> | `PartnerAccount` | ✅ Yes — parents resolve by external ID in the CSV, not by a pre-load query |
> | `Contact` onward | ❌ No — reads an empty org, withholds nearly everything |
>
> Section 4 of `SUMMARY.txt` (**NEEDS A HUMAN**) is also fully trustworthy for those steps, and is the
> real value of a plan run in this state — unmatched and ambiguous Accounts, unmapped Partner Account
> owners, conflicting portal teams. Read that; ignore the downstream volumes.
>
> **Do not try to "fix" the cascade before loading, and do not re-run the plan expecting different
> numbers.** The only thing that resolves it is an actual load, where each step's records exist by the
> time the next step queries for them.
>
> On an org that is **already populated**, none of this applies — the counts are meaningful, because
> the parents really are there.

Treat a `-PlanOnly` run as the readiness check for *execution* — every script ran, reached Salesforce
and produced a file. Treat its **volumes** as meaningful only when the org already holds the parent
records.

### Pre-flight, and the nine Flows

Before any step runs, the orchestrator checks the things that go wrong **silently** — a stale
Airtable export, Market Segments with no external ID, an unresolvable fallback owner, a missing
Contact trigger switch, and **whether the app's nine Flows are switched on in the target org**.

That last one is the reason pre-flight is worth reading rather than skipping. On 2026-08-14 a QA load
reported **8,740 records and zero unexpected failures** while every LDGCRM Flow in that org was
inactive. Nothing failed. Nothing was withheld. The object counts matched Dev exactly. What was
actually wrong: three before-save Flows derive `LDGCRM_Market_Segment__c` from the parent Account, so
Market Segment came out blank on all 92 Partner Accounts, all 842 Opportunities and all 1,026
Applications. **Flow activation changes field contents, not row counts** — so no count, anywhere,
would have caught it.

Pre-flight prints one line per category:

```
  LDGCRM Flows           9 of 9 active and current
```

**Pre-flight switches on any that are off, and you do not have to ask it to.** There is no flag:

```powershell
# Reports what a real run would switch on. Writes nothing.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment QA -PlanOnly

# Switches on whatever is off, then loads.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment QA -Confirmation "LOAD"
```

> **There is no `-ActivateFlows` switch** (removed 2026-08-18). It existed, and it was sandbox-only.
> Activation now happens in **every environment, production included**, exactly as the Contact
> duplicate and matching rules are already handled — and for the same reason. The flows have to be on
> for the load to be correct everywhere, so making production the one org where that depends on
> somebody remembering a manual step is how a production migration acquires a defect nobody sees
> until afterwards.
>
> It is also the *lighter* of the two things the load does to production configuration: a one-field
> setting PATCH pointing the org at a flow version already in it, against the full metadata
> retrieve-and-redeploy the duplicate rules need.

Three things to know:

- **It is permanent.** Unlike the Contact trigger bypass, nothing is restored afterwards. That is
  deliberate: a Flow that had to be on for the load to be correct must stay on, or the org goes back
  to producing wrong data for every record anyone creates in the UI.
- **It cannot create a Flow.** If pre-flight says a Flow is ABSENT, or present with no versions, that
  needs a **change set** — the pipeline does not deploy metadata. Hand the list to whoever builds it.
- **Turning the Flows on does not fix records that are already loaded.** All three Market Segment
  Flows fire on create (or when the parent lookup changes), and the pipeline upserts — so re-running
  a load is an *update* and will not re-trigger them. Records loaded while the Flows were off need a
  factory reset and a full reload. See [Preparing a sandbox from scratch](#preparing-a-sandbox-from-scratch).

There is one inverted check worth knowing about: `LDGCRM_Screen_Flow_Developer_Data_Delete_Flow`
bulk-deletes migrated records and is **Dev-only**. Pre-flight fails if it is found in QA, Full or
Prod. If that fires, find out how it got there — do not just deactivate it.

### ⚠️ What the load changes in your org

**The load does not only write records — it changes four org settings.** Three are permanent. If you
are running against an org somebody else owns, this is the list to send them *before* you run it.

| Change | When | Environments | Put back after? |
| --- | --- | --- | --- |
| Active **Contact duplicate rules** switched off | Pre-flight, automatically. No flag | **All, production included** | **No** |
| Active **Contact matching rules** switched off | Pre-flight, right after the duplicate rules | **All, production included** | **No** |
| The nine **LDGCRM Flows** switched on | Pre-flight, automatically. No flag. Skipped on `-PlanOnly` | **All, production included** | **No** |
| FCIC's **Contact trigger** switched off (`TriggerControls__c`) | During the Contact step only — step 6 of 13 | All | **Yes**, and the restore is verified |

Each is covered in full elsewhere on this page: the Flows [just above](#pre-flight-and-the-nine-flows),
the duplicate rules in [SETUP.md](SETUP.md) section 5, and the trigger bypass in
[The Contact step disables another team's trigger](#the-contact-step-disables-another-teams-trigger).

**Why they are permanent.** A setting that had to be in that state for the load to be correct has to
stay in it. Put it back and the next run flips it again, and in between, the org returns to producing
exactly the wrong data the change prevented — a re-enabled duplicate rule blocks Contacts created in
the UI, a switched-off Flow leaves Market Segment blank on every record anyone creates by hand. The
Contact trigger is the exception because it belongs to a **different live application**, so switching
it off is a loan, not a correction.

**What it will never do:** add a field, add a picklist value, change a record type, or move metadata
between orgs. Every change above flips the status of something that already exists in the org it is
running against. If a load needs metadata that is missing, the run **stops and names it** — that
needs a change set, from someone else. The readiness check (`-Readiness`) changes nothing at all.

> **The full reasoning, and the mechanics for each, are in `ARCHITECTURE.md` under "What the load
> turns on and off".** That file is **not in this folder** — it lives in the engineering repository
> under `docs/engineering/` and is written for people changing the pipeline. Ask whoever handed you
> this bundle if you need it.

### The steps, in order

| # | Step | Object | Why here |
| --- | --- | --- | --- |
| 1 | `MarketSegment` | `LDGCRM_Market_Segment__c` | **First** — everything downstream derives its Market Segment from these |
| 2 | `Impediment` | `LDGCRM_Impediment__c` | No lookups — can go first |
| 3 | `AccountCreate` | Account | **INSERT** — creates only the Accounts Airtable needs that the org genuinely lacks. Must precede the reconciliation, which tags them |
| 4 | `Account` | Account | **UPDATE, not upsert** — matches Airtable rows onto Accounts that already exist, including the ones step 3 just created |
| 5 | `PartnerAccount` | `LDGCRM_Partner_Account__c` | Master-Detail child of Account |
| 6 | `Contact` | Contact | Disables another app's trigger — see below |
| 7 | `Opportunity` | Opportunity | Must precede Application |
| 8 | `Application` | `LDGCRM_application__c` | Needs Partner Account *and* Opportunity |
| 9 | `PopulateBrokerParent` | `LDGCRM_application__c` | **Second pass, creates nothing** — fills `LDGCRM_Broker_App_Parent__c` on Applications step 8 already made |
| 10 | `OpportunityImpediment` | `LDGCRM_Opportunity_Impediment__c` | Two Master-Details, both must exist |
| 11 | `ApplicationContact` | `LDGCRM_Application_Contact__c` | Junction — needs both sides |
| 12 | `OpportunityContactRole` | `OpportunityContactRole` | **Insert + read-then-diff**, never upsert |
| 13 | `Notes` | `ContentNote` | **Last** — a note attaches to a record that must already exist |

Those are the step names `-StartAtStep` and `-OnlySteps` expect, spelled exactly as above.

Three of them deserve a sentence, because they are the ones that surprise people:

- **Account is handled in TWO steps, and only the second is an update.** Step 4 matches Airtable rows
  onto Accounts that already exist and updates them with an external ID and a couple of fields — it
  creates nothing. Step 3 covers what is left: rows with genuinely nowhere to land. It **inserts**,
  and it only proposes an Account after sweeping the whole org, because production disambiguates
  same-named offices with an agency suffix (`Office of Civil Rights - GSA`) while Airtable stores the
  bare name plus a `Parent` column — a naive matcher would propose creating dozens of records that
  already exist. Run `Build-AccountCreationLoad.ps1 -PlanOnly` to see exactly what it would create
  without creating it. On 2026-08-16 that was **9 Accounts** out of 719 Airtable rows.
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
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 `
    -Environment Dev -StartAtStep Contact -Confirmation "LOAD"

# Or run a specific subset
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 `
    -Environment Dev -OnlySteps "Impediment,Account" -Confirmation "LOAD"
```

Step names are the ones in the table above.

> ### ⚠️ A step can fail *as its correct outcome*, and that stops the sequence
>
> **This is the single most confusing thing about running this pipeline**, so read it before you
> conclude something is broken.
>
> `Invoke-SalesforceLoad.ps1` exits non-zero if *any* row fails, and the orchestrator halts at the
> first failing step. But a step can have known, documented failures that are the right answer —
> `PartnerAccount` is the one that has historically done this, when a row's parent Account is one of
> the unmatched Airtable rows. `SUMMARY.txt` classifies each failure as **EXPECTED** or **UNEXPECTED**
> by matching it against that step's patterns; expected ones are the ones this note is about.
>
> **As of 2026-08-16, this should no longer happen on a clean run.** The Airtable Account merges
> landed and step 3 now creates the Accounts that are genuinely missing, so all **99 of 99** Partner
> Accounts load. Historically it was ~20 of 94 failing, then 2 of 94 on the 2026-08-13 reload. If you
> see `PartnerAccount ... LOAD FAILED (exit 1)`, that is now worth investigating rather than shrugging
> at — but it is still not automatically a defect.
>
> **Verify what actually landed, then resume past it** — do not re-run the step:
>
> ```powershell
> # 99 tagged + 2 pre-existing = 101 as of 2026-08-16
> sf data query -q "SELECT COUNT() FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" --target-org peodv8dvn
>
> .\powershell-scripts\Invoke-FullMigrationLoad.ps1 `
>     -Environment Dev -StartAtStep Contact -Confirmation "LOAD"
> ```
>
> To prove failures are the known cause rather than something new, check that each missing row's
> parent external ID is absent from the org's tagged Accounts.
> [TROUBLESHOOTING.md](TROUBLESHOOTING.md#a-step-reports-load-failed-and-you-think-the-counts-look-right)
> has the script.

---

## Running one piece at a time

Sometimes you want a single object — re-running a transform after an Airtable fix, say.

```powershell
# 1. Pull fresh Airtable data (OVERWRITES data/airtable-exports/)
#    Defaults to all 22 tables - the pull backs up the whole base.
.\powershell-scripts\Get-AirtableExport.ps1

# ...or only the 10 tables the load actually reads
.\powershell-scripts\Get-AirtableExport.ps1 -MigrationOnly

# ...or just one or two tables. SEPARATE ARGUMENTS, not one comma-joined
# string - "Contacts,Opportunities" binds as a single label and is rejected.
.\powershell-scripts\Get-AirtableExport.ps1 -Tables "Contacts","Opportunities"

# 2. Transform (read-only — safe to run any time)
.\powershell-scripts\Build-OpportunityLoad.ps1 -Environment Dev

# 3. Load
.\powershell-scripts\Invoke-SalesforceLoad.ps1 -Environment Dev `
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
.\powershell-scripts\Invoke-SandboxFactoryReset.ps1 `
    -Environment Dev -BootstrapAccounts -Confirmation "HARD DELETE"
```

Two things it does, and both matter:

1. **Hard-deletes every record this migration created** — scoped strictly to rows carrying
   `LDGCRM_External_ID__c`, in child-before-parent order, exporting the IDs first as an audit trail.
   Hard delete means **permanent**, not the Recycle Bin.
2. **Rebuilds the Account universe** from whatever export sits in `data/prod-accounts/`, because
   deleting is only half a rebuild. This migration *matches onto* existing Accounts rather than
   creating them, so an emptied org gives the downstream loads nothing to attach to. Any of `.xls`,
   `.xlsx` or `.csv` works — the format is detected by reading the file, the filename does not
   matter, and the newest file wins. See
   [`data/prod-accounts/README.md`](../data/prod-accounts/README.md).

### ⚠️ Step 2 happens in Dev and QA ONLY

**In a Full sandbox, Accounts are never deleted and never rebuilt.** A Full sandbox is a copy of
production, so its Accounts *are* the real records this migration reconciles onto — replacing them
with a stale export would invalidate the very rehearsal the sandbox exists for.

Run the factory reset against `Full` and it still resets everything else (all those records carry an
external ID because this migration created them), but:

- `Account` is dropped from the delete list, and **it says so, loudly** — a silent removal would let
  you conclude the Accounts had been reset when they had not;
- the Account bootstrap is not offered, and `-BootstrapAccounts` is rejected;
- `Invoke-AccountBootstrap.ps1` will not accept `-Environment Full` or `Prod` at all — PowerShell
  rejects the argument before the script runs.

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

# Partner Portal Team. The change set clearing Unique on both fields LANDED on 2026-08-14, so this
# must now be a large positive number - roughly 696 of the loaded Applications as of 2026-08-16.
# A 0 here means the columns were withheld again, which the transform says out loud when it happens.
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
| Tell an org owner what the load will change | [What the load changes in your org](#-what-the-load-changes-in-your-org), above |
| Know what a specific field maps to | **TRANSFORMATION-RULES.md** † |
| Fix the source data | **AIRTABLE-DATA-QUALITY-REQUESTS.md** † |
| Understand *why* the load changes org settings | **ARCHITECTURE.md**, "What the load turns on and off" † |

† Not in this folder — those live in the engineering repository under `docs/`, because they are
written for people changing the pipeline or fixing the Airtable base rather than for people running
a load. Ask whoever handed you this bundle if you need them.
