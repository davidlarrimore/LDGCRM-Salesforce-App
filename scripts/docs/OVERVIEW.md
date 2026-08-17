# Overview — what this project is and how it works

**Start here if you have never seen this folder before.** This page assumes no knowledge of the
project, of Salesforce, of Airtable, or of PowerShell. It explains what the migration is, what each
folder holds, what each script does, and what actually happens when you run a load.

It contains no commands you need to type. When you are ready to run something, go to
[SETUP.md](SETUP.md) and then [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md).

**Contents**

1. [The project in plain terms](#1-the-project-in-plain-terms)
2. [The two systems](#2-the-two-systems)
3. [The vocabulary](#3-the-vocabulary)
4. [What a load actually does](#4-what-a-load-actually-does)
5. [The folders](#5-the-folders)
6. [The scripts](#6-the-scripts)
7. [How the pipeline keeps you safe](#7-how-the-pipeline-keeps-you-safe)
8. [How you know it worked](#8-how-you-know-it-worked)
9. [Where to go next](#9-where-to-go-next)

---

## 1. The project in plain terms

The **Login.gov partnership team** works with federal and state agencies that want to use Login.gov
as their sign-in provider. For years they tracked that work — the agencies, the people, the deals,
the applications, the things blocking them — in an **Airtable base**. Airtable is a spreadsheet-like
database that a small team can run themselves.

That worked until it didn't. The team is now moving into **Salesforce**, the CRM that GSA PEO
already runs, so that this work lives alongside the rest of the organisation's.

**This folder is the machinery that moves the data.** It reads the Airtable base, reshapes every row
into the form Salesforce expects, and loads it into a Salesforce org. It is a *pipeline*, not a
one-time script — it is designed to be run over and over, in a test environment, until the result is
right, and then run once for real.

### The single most important property: it is re-runnable

Every record this migration creates carries a field called **`LDGCRM_External_ID__c`**, which holds
the ID of the Airtable row it came from (`recqKg0hKPxCCH4M1`, and so on).

That one field is what makes everything else possible. When the pipeline loads a record, it does not
say *"create this."* It says *"the record for Airtable row `recqKg0...` should look like this — make
it so."* If the record exists, it is updated. If it does not, it is created. This is called an
**upsert**, and it is why you can run the whole migration ten times and end up with one copy of
everything rather than ten.

So: a load that goes wrong is usually fixed by fixing the cause and running it again. That is the
intended way to work.

### The one big exception: Accounts

**The migration does not create Accounts.** Agencies already exist in Salesforce as Account records,
entered by other teams, often years ago and with different names than Airtable uses.

So for Accounts the pipeline *reconciles* rather than creates: it tries to match each Airtable
Account row onto an Account that is already there, and tags the match with the external ID. Only
where a row genuinely has nowhere to land does it create a new Account — and it says exactly which
ones and why, before it does.

This is why Accounts are handled by **two** steps rather than one, and why an empty test sandbox
needs its Accounts rebuilt from a production export before anything else will attach to them.

---

## 2. The two systems

You will be working with two systems and a set of PowerShell scripts that talk to both.

### Airtable — where the data comes from

The source. One **base** (Airtable's word for a database) containing **22 tables**. The pipeline
reads **10** of them; the other 12 are pulled anyway so that the export doubles as a full backup of
the base.

The pipeline talks to Airtable over its REST API using a **Personal Access Token** you create
yourself. It only ever **reads**. Nothing this folder does can change the Airtable base.

### Salesforce — where the data goes

The destination. A Salesforce **org** is one environment — one instance with its own data, users
and configuration. There are four in play here, and you will spend nearly all your time in the first
two:

| Name | What it is |
| --- | --- |
| **Dev** | A developer sandbox. Where the pipeline is built and tested. Safe to destroy. |
| **QA** | A second developer sandbox. Where a full end-to-end rehearsal is run. Safe to destroy. |
| **Full** | A **copy of production**, including its real Accounts. The dress rehearsal, immediately before the real thing. |
| **Prod** | The live GSA PEO org. Real partner data. |

The pipeline talks to Salesforce through the **Salesforce CLI**, a command-line tool called `sf`
that you install and log into once.

### Why the data has to be reshaped

Airtable and Salesforce disagree about almost everything. Airtable lets a cell hold a list of links
to other rows; Salesforce wants one record per link. Airtable lets a column hold free text;
Salesforce may have a dropdown that rejects anything not on its list. Airtable has one table for
people; Salesforce splits the same information across a Contact and a set of link records.

**That reshaping is what the `Build-*.ps1` scripts do**, and it is the bulk of the code in this
folder. The rules they encode were worked out field by field against real data — not guessed from
column names.

---

## 3. The vocabulary

Terms you will meet constantly, in the sense this project uses them.

### Salesforce terms

| Term | What it means here |
| --- | --- |
| **Org** | One Salesforce environment. Dev, QA, Full and Prod are four separate orgs. |
| **Sandbox** | A non-production org used for testing. Dev, QA and Full are sandboxes. |
| **Object** | A *type* of record — Salesforce's word for a table. `Account`, `Contact`, `Opportunity`. |
| **Standard object** | An object Salesforce ships with. `Account`, `Contact`, `Opportunity`. |
| **Custom object** | One somebody built. Names end in `__c`. Ours all start `LDGCRM_`, e.g. `LDGCRM_Application__c`. |
| **Record** | One row — one agency, one person, one deal. |
| **Field** | One column on an object. Custom fields also end `__c`. |
| **Lookup** | A field holding a link to another record — like a foreign key. |
| **Master-Detail** | A stricter link: the child cannot exist without its parent, and is deleted with it. |
| **Junction object** | A record whose only job is to link two others, when the relationship is many-to-many. A person can be on many applications and an application has many people, so a junction record represents each pairing. |
| **Picklist** | A dropdown field. A *restricted* picklist rejects any value not on its list — a common cause of load failures. |
| **Record type** | A variant of an object, which can narrow the picklist values allowed. Our Opportunities use the `Login_gov` record type; other teams' use theirs. |
| **Flow** | Salesforce's built-in automation, which runs when a record is saved. **Nine of them matter to this migration** and must be switched on — see below. |
| **External ID** | A field marked as a stable key from an outside system. Ours is `LDGCRM_External_ID__c`. |
| **Bulk API** | Salesforce's interface for loading lots of records at once. It takes a CSV file. |
| **`sf`** | The Salesforce CLI — the command-line tool every script uses to talk to an org. |

### This project's terms

| Term | What it means here |
| --- | --- |
| **The bundle** | This `scripts/` folder. Everything needed to run a migration, self-contained. |
| **Pull** | Fetching current data from Airtable into `data/airtable-exports/`. |
| **Transform** | Turning that Airtable data into a load-ready CSV. Done by a `Build-*.ps1` script. **Never writes to Salesforce.** |
| **Load** | Sending a CSV to Salesforce. Done by an `Invoke-*.ps1` script. **The only thing that writes.** |
| **Upsert** | Update the record matching this external ID, or create it if there isn't one. What makes re-runs safe. |
| **Step** | One object's transform-and-load, e.g. `Contact`. A full load is 13 steps in order. |
| **The orchestrator** | `Invoke-FullMigrationLoad.ps1` — runs all 13 steps in the correct order. |
| **Pre-flight** | Checks the orchestrator runs *before* touching anything, looking for the problems that would otherwise fail silently. |
| **Withheld** | A row the transform deliberately did **not** send, usually because something it depends on isn't there. **Not an error, and usually the bigger number.** See [section 8](#8-how-you-know-it-worked). |
| **Restore point** | Files a run captures before writing, recording what the org looked like. A rollback needs them. |
| **Factory reset** | Deleting every migrated record from a sandbox to get a clean starting point. |
| **Bootstrap** | Rebuilding a Dev or QA sandbox's Accounts from a production export, so downstream records have something to attach to. |
| **`-PlanOnly`** | A dry run. Runs every transform for real, writes nothing to Salesforce, and reports what it *would* do. |

---

## 4. What a load actually does

### The three stages

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

**Stage 1 — Pull.** `Get-AirtableExport.ps1` downloads the Airtable base into one JSON file per
table. Each pull overwrites the last: this folder is a mirror of what Airtable holds *now*, not a
history.

**Stage 2 — Transform.** A `Build-*.ps1` script reads that JSON, applies this object's mapping rules,
and writes a CSV to `data/salesforce-loads/`. It also *queries* Salesforce, read-only, to find out
what already exists — that is how it resolves links and decides what to withhold. **A transform can
never change your org.** You can run one as often as you like, against any environment.

**Stage 3 — Load.** `Invoke-SalesforceLoad.ps1` sends that CSV to Salesforce over the Bulk API.
This is the only step that writes, and it requires a typed confirmation before it will run.

**That separation is the main safety property of the whole pipeline.** You can always look at
exactly what would be written, in a plain CSV file, before anything is.

### Why order matters, and why getting it wrong is quiet

The objects depend on each other. An Application belongs to a Partner Account; a Partner Account
belongs to an Account; a junction record needs both the records it links. **A child cannot be loaded
before its parent exists.**

Getting the order wrong does **not** produce an error. Every transform skips rows whose parent isn't
in the org yet — so a mis-ordered run produces a *smaller* migration and a clean-looking summary.
Nothing turns red. You just get less data.

That is the failure this pipeline is built to prevent, and it is why there is one orchestrator that
knows the order rather than a list of thirteen commands in a document.

### The 13 steps

`Invoke-FullMigrationLoad.ps1` runs these in exactly this order:

| # | Step | Object it loads | Why it is here |
| --- | --- | --- | --- |
| 1 | `MarketSegment` | `LDGCRM_Market_Segment__c` | **First** — everything downstream derives its market segment from these |
| 2 | `Impediment` | `LDGCRM_Impediment__c` | Depends on nothing |
| 3 | `AccountCreate` | Account | **Creates** only the Accounts Airtable needs that the org genuinely lacks |
| 4 | `Account` | Account | **Updates** existing Accounts with their external ID and a couple of fields |
| 5 | `PartnerAccount` | `LDGCRM_Partner_Account__c` | A Master-Detail child of Account |
| 6 | `Contact` | Contact | People. Temporarily disables another team's trigger while it runs |
| 7 | `Opportunity` | Opportunity | Needs Accounts |
| 8 | `Application` | `LDGCRM_application__c` | Needs Partner Account *and* Opportunity |
| 9 | `PopulateBrokerParent` | `LDGCRM_application__c` | A second pass over step 8's records — creates nothing |
| 10 | `OpportunityImpediment` | `LDGCRM_Opportunity_Impediment__c` | A junction — both sides must exist |
| 11 | `ApplicationContact` | `LDGCRM_Application_Contact__c` | A junction — both sides must exist |
| 12 | `OpportunityContactRole` | `OpportunityContactRole` | Links people to deals |
| 13 | `Notes` | `ContentNote` | **Last** — a note attaches to a record that must already exist |

Roughly 8,500 records across all 13 steps, on a full Dev load.

Three of them behave differently from the rest, and it is worth knowing which before you meet them:

- **Account takes two steps, and neither is a plain upsert.** Step 4 *updates* Accounts that already
  exist. Step 3 *inserts* the handful with nowhere to land — after sweeping the whole org, because
  production disambiguates same-named offices with an agency suffix (`Office of Civil Rights - GSA`)
  while Airtable stores the bare name.
- **`OpportunityContactRole` cannot be upserted at all.** Salesforce forbids external ID fields on
  that object, full stop — there is no configuration that would fix it. It is loaded by reading what
  already exists, comparing, and inserting only what is missing.
- **Notes do not go through the Bulk API.** A note's content is a binary field, which Bulk rejects.
  They have their own loader that uses a different interface.

### The nine Flows, and the failure that makes this worth reading

Salesforce Flows are automation that runs when a record is saved. Nine of them belong to this app,
and three of those fill in each record's Market Segment from its parent when it is created.

On 2026-08-14 a QA load reported **8,740 records and zero unexpected failures** while every one of
those Flows was switched off in that org. Nothing failed. Nothing was withheld. Every object count
matched Dev exactly. What was actually wrong: Market Segment came out **blank on all 92 Partner
Accounts, all 842 Opportunities and all 1,026 Applications.**

**Flow activation changes what is *in* the fields, not how many records there are** — so no count,
anywhere, would have caught it.

Pre-flight now checks all nine and **blocks the run** if any is off. This is the clearest example of
the general lesson on this project: *a successful-looking load is not evidence of a correct load.*

---

## 5. The folders

You run everything from the top of this folder, and every path is relative to it.

```
scripts/
├── README.md              The front door. Start there, then this file.
│
├── powershell-scripts/    EVERY script. One flat folder, no sub-folders.
├── docs/                  The runbooks — including this file.
├── reference/             Small hand-maintained business inputs. Tracked in git.
├── data/                  Inputs and staged output.        NEVER COMMITTED
├── logs/                  One folder per run.              NEVER COMMITTED
├── .env                   Your Airtable token.             NEVER COMMITTED
└── .env.example           The template for .env. Safe — contains no secrets.
```

### `powershell-scripts/` — all the code

One flat folder holding all 25 scripts. There are no sub-folders: the naming convention carries the
meaning instead, and [section 6](#6-the-scripts) is the index.

### `docs/` — the runbooks

| File | For |
| --- | --- |
| `OVERVIEW.md` | This file — orientation before you run anything |
| `DEPLOYMENT-GUIDE.md` | Standing the app up in a new org: change set, Flows, users, then the load |
| `SETUP.md` | Getting your machine ready: tools, Salesforce login, Airtable token |
| `RUNNING-A-LOAD.md` | Running a load, start to finish |
| `TROUBLESHOOTING.md` | Every failure this pipeline has actually produced, and what to do |
| `ROLLBACK.md` | Undoing a load, and what cannot be undone |
| `RELOAD-QA-CHECKLIST.md` | The full wipe-and-reload rehearsal, with verification at each stage |

### `data/` — inputs and staged output

**Gitignored, and it must stay that way** — these files carry personal information about Login.gov
applicants and partner staff.

| Folder | Holds |
| --- | --- |
| `airtable-exports/` | The Airtable pull, one JSON file per table. All 22 tables. **Overwritten by every pull.** |
| `prod-accounts/` | A production Account export, used to rebuild a Dev or QA sandbox's Accounts. `.xls`, `.xlsx` or `.csv` — the newest file wins and the format is detected by reading it |
| `salesforce-loads/` | The load-ready CSVs the transforms produce. Regenerated every run — **never hand-edited** |

### `logs/` — what each run left behind

**Gitignored**, for the same reason. **Everything a single run produces lands in one folder**, named
after the script that started it: `logs/<category>/<ScriptName>-<timestamp>/`. That includes every
child script an orchestrated load spawns, so one folder holds the whole run.

Two categories: `data-migration/` for pulls, transforms, loads and rollbacks; `cleanup/` for factory
resets.

**Inside each run folder, `SUMMARY.txt` is the thing to read.** See
[section 8](#8-how-you-know-it-worked) and [`logs/README.md`](../logs/README.md).

### `reference/` — hand-maintained business inputs

Small files the pipeline reads but never writes, owned by the business rather than by engineering.
Tracked in git, because they need reviewing and versioning. Currently one:
`salesforce-user-roster.csv`, which states who is *expected* to have a Salesforce account so that a
missing one is reported before a load rather than discovered after.

---

## 6. The scripts

### The naming convention is the folder structure

The prefix on a script's name tells you what it can do to your org. This is the single most useful
thing to know about the code:

| Prefix | What it does | Can it change your org? |
| --- | --- | --- |
| **`Get-`** | Reads from a source system | **No** |
| **`Build-`** | Transforms data into a load-ready CSV | **No** — reads Salesforce, writes only to disk |
| **`Test-`** | Checks whether things are in order | **No** |
| **`Invoke-`** | Does the thing — loads, deletes, rebuilds, rolls back | **Yes** |
| **`Common.`** | Shared code the others use. Never run directly | — |

**If a script's name starts with `Build`, it cannot change your org.** That is a guarantee, not a
convention, and it is what makes it safe to re-run a transform whenever you want to see what it would
produce.

### The full index

**Pull — from Airtable**

| Script | What it does |
| --- | --- |
| `Get-AirtableExport.ps1` | Downloads the Airtable base to `data/airtable-exports/`, one JSON file per table. All 22 tables by default, because the pull doubles as a backup; `-MigrationOnly` narrows it to the 10 the load reads. Afterwards it asks Airtable what tables the base actually holds and reports any it doesn't know about |

**Transform — Airtable JSON into load-ready CSV. None of these write to Salesforce**

| Script | Builds | Notes |
| --- | --- | --- |
| `Build-MarketSegmentLoad.ps1` | `LDGCRM_Market_Segment__c` | Step 1. Depends on nothing |
| `Build-ImpedimentLoad.ps1` | `LDGCRM_Impediment__c` | Things blocking a deal. Depends on nothing |
| `Build-AccountCreationLoad.ps1` | Account (insert) | The Accounts that genuinely need creating, after exhausting every way of matching an existing one |
| `Build-AccountReconciliation.ps1` | Account (update) | Matches Airtable rows onto Accounts already in the org and tags them. Creates nothing |
| `Build-PartnerAccountLoad.ps1` | `LDGCRM_Partner_Account__c` | The agreements under an Account |
| `Build-ContactLoad.ps1` | Contact | People. Merges Airtable rows sharing an email address into one Contact |
| `Build-OpportunityLoad.ps1` | Opportunity | Deals. Skips rows whose Account cannot be resolved |
| `Build-ApplicationLoad.ps1` | `LDGCRM_application__c` | Needs both Partner Account and Opportunity loaded first |
| `Build-OpportunityImpedimentLoad.ps1` | `LDGCRM_Opportunity_Impediment__c` | Junction: which impediments block which deals |
| `Build-ApplicationContactLoad.ps1` | `LDGCRM_Application_Contact__c` | Junction: which people are on which applications |
| `Build-OpportunityContactRoleLoad.ps1` | `OpportunityContactRole` | Junction: which people are on which deals. Resolves real Salesforce IDs rather than upserting |
| `Build-NotesLoad.ps1` | `ContentNote` | Freeform Airtable text with no field to land in, turned into notes on the record it describes. Must be last |

**Load and operate — these write**

| Script | What it does | Confirmation |
| --- | --- | --- |
| `Invoke-FullMigrationLoad.ps1` | **The one you will normally run.** Every transform and every load, all 13 steps in dependency order, with pre-flight checks before and validation after | `LOAD` |
| `Invoke-SalesforceLoad.ps1` | Loads one CSV into one object over the Bulk API. What the orchestrator calls for each step | `LOAD` |
| `Invoke-NotesLoad.ps1` | Loads the notes. Separate because note content is binary and the Bulk API refuses it | `LOAD` |
| `Invoke-SandboxFactoryReset.ps1` | **Destructive.** Hard-deletes every record this migration created, to give a sandbox a clean starting point. Exports the IDs first as an audit trail. Cannot target production | `HARD DELETE` |
| `Invoke-AccountBootstrap.ps1` | Rebuilds a **Dev or QA** sandbox's Account names and parent hierarchy from a production export. Rejected outright for Full and Prod | `BOOTSTRAP` |
| `Invoke-MigrationRollback.ps1` | Undoes one run, using the restore point that run captured. A best-effort tidy-up, **not** a safety net — read [ROLLBACK.md](ROLLBACK.md) | `ROLLBACK` |

**Check — reads only**

| Script | What it does |
| --- | --- |
| `Test-LdgcrmReadiness.ps1` | Answers "is this machine, this Airtable pull and this org ready for a load?" Checks your `.env`, the token's shape, every Airtable table, which orgs you can reach, who you are in the target org, and that every field the load writes exists and is writable there. **Writes nothing, fixes nothing** — each finding names the command that would. Safe against any environment, production included |

**Shared code — never run these directly**

| Script | Holds |
| --- | --- |
| `Common.ps1` | Logging, paths, the confirmation gate. Every script loads this |
| `Common.Orgs.ps1` | The environment registry — which org each of Dev/QA/Full/Prod means, and the identity checks |
| `Common.DataMigration.ps1` | Helpers shared by the transforms — CSV writing, contact grouping, value cleaning |
| `Common.AccountMatching.ps1` | The rules for "is this Airtable row the same agency as this Salesforce Account?", in one place so every script answers it identically |
| `Common.LoadReport.ps1` | Builds `SUMMARY.txt` — the one report that says how a run went |

---

## 7. How the pipeline keeps you safe

Several deliberate design choices exist because of things that have actually gone wrong. Knowing why
they are there makes them much less annoying.

### You name an environment, never an org

No script takes a Salesforce username or org alias by hand. They take `-Environment Dev|QA|Full|Prod`
and look the real org up themselves from a registry in `Common.Orgs.ps1`.

Then, before doing anything, every script **asks the org who it is** and refuses to continue if the
answer disagrees with the registry. An alias is just a pointer on your laptop and can be repointed;
the only trustworthy statement about which org you have reached comes from the org itself.

### Writes are approved with a typed word, not a `-Force` flag

`-Confirmation "LOAD"`, `-Confirmation "HARD DELETE"`, `-Confirmation "BOOTSTRAP"`,
`-Confirmation "ROLLBACK"`. Comparison is case-sensitive.

A token says *what* is being approved and cannot travel between commands by habit — you cannot paste
a load approval into a delete. A `-Force` switch reads identically on every command and gets copied
without thought, which is exactly the failure a confirmation gate exists to prevent.

**Production needs a second, different token on top** (`-ProductionConfirmation gsa-peo`), so that
someone who automated a sandbox run cannot retarget it at production by changing one word.

### Accounts are rebuilt in Dev and QA only — never in Full or Prod

Dev and QA are empty developer sandboxes, so an Account universe has to be invented for them before
anything else will attach. But a **Full sandbox is a copy of production**, so its Accounts *are* the
real records this migration reconciles onto. Replacing them with a stale export would invalidate the
very rehearsal the sandbox exists for.

This is enforced in code in one place, and three scripts obey it: the factory reset drops Account
from its delete list *and says so loudly*, the bootstrap refuses to start, and the orchestrator
rejects the flag. Every *other* object still resets normally in a Full sandbox.

### Dry runs are real runs

`-PlanOnly` is not a simulation. It executes every transform against the real org, read-only, and
reports what each step would load. So it genuinely proves each script runs, can reach Salesforce and
reads real data.

One consequence surprises everyone once: **on a freshly reset org, a plan run's row counts collapse
to almost nothing.** Because it writes nothing, every step after the first few queries an org that is
still empty, finds no parents, and withholds everything. That is correct behaviour, not a fault, and
only an actual load resolves it. [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md#what--planonly-gives-you) has
the detail.

### The org contains automation this folder cannot show you

The sandbox is shared with unrelated GSA applications — FCIC, TTS OTCRM, and an installed Genesys
package — whose triggers, duplicate rules and Flows fire on records this pipeline creates. They are
invisible to any amount of careful reading of the code here.

Two are known and handled automatically: another team's Contact trigger is switched off for the
duration of the Contact step and switched back on afterwards (with the restore verified), and an
old duplicate rule that was silently rejecting real people is switched off permanently. Both are
documented in [SETUP.md](SETUP.md) and [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md).

The general rule stands, though: **check the live org before loading a new object for the first
time.**

### What the load changes in the org itself

Beyond writing records, a load changes four org settings — three permanently. If you are running
against an org somebody else owns, send them that list first; it is in
[RUNNING-A-LOAD.md](RUNNING-A-LOAD.md#-what-the-load-changes-in-your-org).

**What it will never do:** add a field, add a picklist value, change a record type, or move
configuration between orgs. If a load needs something that is missing, it **stops and names it**.
Adding it is a change set, built by someone else.

---

## 8. How you know it worked

### Success counts are not evidence

This is the single most important habit to build. **Every serious defect found in this migration
passed its load cleanly.** The QA Flow failure above reported 8,740 records and zero errors while
silently blanking a field on 1,960 records.

So there are three different questions, and a green run only answers the first:

1. Did the rows Salesforce received get accepted? — the load result
2. Were all the rows *sent*? — **withheld** rows
3. Is what landed in them correct? — post-load validation

### "Withheld" is not an error, and it is usually the bigger number

A transform skips rows it cannot safely load — a row whose parent isn't in the org, whose Account
won't resolve, whose junction partner was itself withheld. **Those rows are never submitted**, so
Salesforce never sees them, no job result mentions them, no exit code reflects them, and the step
reports success. The records are just absent.

On one real reload, 31 rows *failed* and several hundred were *withheld*. Any "how much migrated?"
question has to account for both.

### `SUMMARY.txt` — read this before anything else

Every run writes one report into its own folder, and prints it at the end of the transcript. It is
the whole run in one file. Read it in this order:

1. **Unexpected load failures** — rows Salesforce rejected for a cause not known for that object.
   These stop the run.
2. **Rows withheld** — the number most likely to surprise you.
3. **The deltas** — every line carries `(was N, ±M)` against the previous run. A count that moved
   without anyone changing anything is worth understanding.
4. **Needs a human** — where the pipeline refused to guess, e.g. an Airtable row matching two
   Salesforce Accounts.
5. **Loaded with a caveat** — values derived, dropped or truncated on the way in.

Nothing keeps a list of expected counts, deliberately. A hard-coded expectation is wrong the moment
Airtable is fixed, and a check that cries wolf every run stops being read. Each run compares itself
against the previous one instead — including reporting causes that have **gone since the last run**,
so that a fix is visible *as* a fix rather than as a silent absence.

### The review CSVs are the actual output

The transcript narrates; the review CSVs are what a run *found*. Every transform writes them for rows
it could not load or loaded with a caveat — unmatched, ambiguous, skipped, truncated. `SUMMARY.txt`
groups and counts all of them for you, so start there and open the individual files for the rows.

**Findings sitting unread in `logs/` are the exact failure mode those files exist to prevent.**

---

## 9. Where to go next

| You want to | Read |
| --- | --- |
| Deploy the app into an org for the first time | [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) |
| Get your machine ready | [SETUP.md](SETUP.md) |
| Check whether you are ready, without running a load | `Test-LdgcrmReadiness.ps1` — read-only, safe anywhere |
| Run a load | [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md) |
| Work out why something failed | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Undo a load | [ROLLBACK.md](ROLLBACK.md) |
| Wipe and reload a sandbox properly | [RELOAD-QA-CHECKLIST.md](RELOAD-QA-CHECKLIST.md) |
| Understand what a run left behind | [`logs/README.md`](../logs/README.md) |
| Know what a specific Airtable column maps to | **TRANSFORMATION-RULES.md** † |
| Understand why the pipeline is built this way | **ARCHITECTURE.md** † |

† Not in this folder. Those live in the engineering repository, because they are written for people
*changing* the pipeline rather than running it. Ask whoever handed you this bundle if you need them.

**Before you write to any org, coordinate.** More than one person can load into these orgs — at least
one colleague uses the Data Loader GUI against the same sandbox, and other teams share the org
entirely. Loads are re-runnable, but a load nobody expected is still an incident.
