# Login.gov CRM migration — Airtable → Salesforce

This folder is everything needed to move the Login.gov partnership team's data out of **Airtable**
and into the GSA PEO **Salesforce** org. It is self-contained: it reads and writes only paths inside
itself, so it runs correctly wherever it is placed.

### 👉 New here? Read [`docs/OVERVIEW.md`](docs/OVERVIEW.md) first

It assumes no knowledge of this project, Salesforce, Airtable or PowerShell, and explains what the
migration is, what every folder and script does, what happens during a load, and how to tell whether
it worked. Twenty minutes there will save you a day. **Everything below is the short version.**

### The four commands

Run them from this folder, in this order. Everything else in this README explains these.

```powershell
.\powershell-scripts\Get-AirtableExport.ps1                                    # 1. PULL from Airtable
.\powershell-scripts\Test-LdgcrmReadiness.ps1     -Environment Dev             # 2. CHECK (read-only)
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly   # 3. DRY RUN (writes nothing)
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -Confirmation "LOAD"   # 4. LOAD
```

**Command 1 is the one people miss.** Nothing else pulls from Airtable — not the readiness check, not
the dry run, not the load. See [Pulling from Airtable](#pulling-from-airtable).

First time on this machine, do the one-off setup in [Quick start](#quick-start) first — execution
policy, `sf` login, and the `.env` the pull needs.

---

## What this does

The Login.gov partnership team tracked its work — agencies, applications, deals, the people involved,
and the things blocking them — in an Airtable base. This pipeline moves that data into Salesforce,
where it becomes Accounts, Contacts, Opportunities, and a set of custom objects prefixed `LDGCRM_`.

It runs in three stages, and they are deliberately separate:

```
   PULL                    TRANSFORM                      LOAD
   ────                    ─────────                      ────
   Airtable  ──────────►   Build-*.ps1        ──────────► Invoke-*.ps1
   REST API                writes a CSV to disk           writes to Salesforce
   Get-AirtableExport      (READ-ONLY)                    (the only step that writes)
        │                       │                              │
        ▼                       ▼                              ▼
   data/airtable-exports/  data/salesforce-loads/         the org
   <Table>.json            <Object>-upsert.csv
```

**Each stage hands the next one files on disk**, and you run each stage yourself. In particular the
transforms read `data/airtable-exports/` — they never call Airtable — so **`Get-AirtableExport.ps1`
is a step you have to run**, not something the load does for you. See
[Pulling from Airtable](#pulling-from-airtable).

**Nothing writes to Salesforce except the load step.** You can always inspect exactly what *would* be
written, as a plain CSV, before anything is.

Every record it creates carries `LDGCRM_External_ID__c`, holding the Airtable row's `rec...` ID. That
is what makes the whole thing **re-runnable**: loads are upserts keyed on that field, so running a
load twice updates rather than duplicates. A load that goes wrong is normally fixed by fixing the
cause and running it again.

**One important exception to the mental model: the migration does not create Accounts.** Agencies
already exist in Salesforce and pre-date this project, so the pipeline *reconciles onto* them by name
and external ID, creating only the few that genuinely have nowhere to land. See
[`data/prod-accounts/README.md`](data/prod-accounts/README.md) for what that means when you are
working in an empty Dev or QA sandbox.

---

## Where to go

| You want to… | Read |
| --- | --- |
| **Understand the project before touching it** | [`docs/OVERVIEW.md`](docs/OVERVIEW.md) |
| **Stand the app up in an org it has never run in** | [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) |
| Install the tools and get credentials | [`docs/SETUP.md`](docs/SETUP.md) |
| **Pull fresh data out of Airtable** | [Pulling from Airtable](#pulling-from-airtable) — `.\powershell-scripts\Get-AirtableExport.ps1`. You run it yourself; no other script does |
| **Check everything is set up correctly** | `.\powershell-scripts\Test-LdgcrmReadiness.ps1` — read-only, safe anywhere. See [`docs/RUNNING-A-LOAD.md`](docs/RUNNING-A-LOAD.md#am-i-ready--the-readiness-check) |
| Run a load | [`docs/RUNNING-A-LOAD.md`](docs/RUNNING-A-LOAD.md) |
| Work out why something failed | [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) |
| Undo a load | [`docs/ROLLBACK.md`](docs/ROLLBACK.md) |
| Sign off a full rehearsal | [`docs/RELOAD-QA-CHECKLIST.md`](docs/RELOAD-QA-CHECKLIST.md) |
| Understand what a run left behind | [`logs/README.md`](logs/README.md) |

---

## Quick start

**Open PowerShell in this folder and stay here.** Every command in this README and in `docs/` is
written relative to it — `.\powershell-scripts\Something.ps1`. Nothing resolves outside this folder,
so it works wherever the folder happens to live.

```powershell
# 0. Where you should be standing
cd <wherever-this-folder-is>\scripts

# 0b. ONE TIME PER MACHINE. Windows blocks .ps1 files by default and every
#     command below fails with "running scripts is disabled on this system".
#     No admin rights needed. See docs/SETUP.md if it does not stick.
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#     ...and if you got this folder as a downloaded .zip, also clear the
#     internet mark Windows puts on every extracted file:
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File

# 1. Authenticate to the sandbox, at its own My Domain URL (not test.salesforce.com)
sf org login web --alias peodv8dvn `
  --instance-url https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com

# 2. Airtable credentials. Copy the template and fill in your token.
#    You need an admin account on the base first - see docs/SETUP.md.
Copy-Item .env.example .env

# 3. Pull the data out of Airtable. NOTHING ELSE DOES THIS FOR YOU.
#    data/ ships empty, so on a fresh copy of this folder there is no data to
#    load until this runs. It overwrites data/airtable-exports/ each time.
.\powershell-scripts\Get-AirtableExport.ps1

# 4. Confirm the machine, the Airtable pull and the org are all ready.
#    Read-only: writes nothing, fixes nothing, safe against any environment.
.\powershell-scripts\Test-LdgcrmReadiness.ps1 -Environment Dev

# 5. See what a load would do. Runs every transform, writes NOTHING to Salesforce.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly

# 6. Apply it
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -Confirmation "LOAD"
```

**Step 3 is the one people miss.** The load reads Airtable data from `data/airtable-exports/` on
disk — it never calls Airtable itself. That folder is gitignored and ships empty, so until you run
`Get-AirtableExport.ps1` there is nothing there and a load has nothing to do. The readiness check in
step 4 fails loudly if you skip it, and so does the load's own pre-flight, but neither one pulls the
data for you. See [Pulling from Airtable](#pulling-from-airtable) below.

Always run `-PlanOnly` first. It is a genuine dry run: it executes every transform against the real
org, captures a restore point, and reports what each step *would* load — without writing anything.

---

## Pulling from Airtable

**This is the command:**

```powershell
.\powershell-scripts\Get-AirtableExport.ps1
```

That is the whole thing for a normal run. It pulls **all 22 tables** in the base, because the pull
doubles as a backup of the whole base, and it is what you want before a real load.

It takes no `-Environment` and cannot touch a Salesforce org — it only reads Airtable and writes
files. Running it is always safe.

The flags, for when you need them:

| Flag | Use it when |
| --- | --- |
| *(none)* | **The normal case.** All 22 tables |
| `-MigrationOnly` | You only want the 10 tables the transforms actually read. Faster |
| `-Tables "Contacts","Opportunities"` | One or two tables. **Separate arguments** — `"Contacts,Opportunities"` as a single comma-joined string binds as one label and is rejected |
| `-SkipCoverageCheck` | Your token lacks the `schema.bases:read` scope and the post-pull warning is noise. The pull itself still works |
| `-BaseId "app…"` | You need to point at a different Airtable base than the `AIRTABLE_BASE_ID` in `.env`. Rare |

It writes one JSON file per table to `data/airtable-exports/<Table>.json`, and a transcript plus
`pull-summary-<timestamp>.csv` to `logs/data-migration/`.

**When to re-run it:** before any load you intend to keep, after anyone edits the base, and whenever
a transform tells you an export looks stale. It is cheap and idempotent — re-pulling is never the
wrong move, except when you are deliberately trying to reproduce an older run's counts.

Four things to know before you run it:

- **It needs `.env`.** `AIRTABLE_API_KEY` (a Personal Access Token starting `pat`, *not* a `key…`
  API key — Airtable removed those in Feb 2024) and `AIRTABLE_BASE_ID`. Getting a token, and the two
  scopes it needs, is [`docs/SETUP.md` §3](docs/SETUP.md). Without `.env` the pull is the *first*
  thing that fails, which is why it is the first command you run.
- **Every pull overwrites the last.** `data/airtable-exports/` is a mirror of what Airtable holds
  *now*, not a history. That is deliberate — always load the newest pull. If you are trying to
  reproduce a count from a previous run, do **not** re-pull; the counts will move.
- **A stale export can change a column's *shape*, not just its values.** Airtable turned
  Opportunities' identity-platform columns from linked records into multi-selects once, and a
  transform written for one reads the other as garbage. `Build-OpportunityLoad.ps1` hard-fails rather
  than silently dropping the values, and tells you to re-pull. Take it at its word.
- **A `403` means "no permission" *or* "that table isn't there".** Airtable returns the same code for
  both, so a renamed table looks exactly like a bad token. See
  [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md#airtable-returns-403).

---

## How it is laid out

**You run everything from this folder**, and every path below is relative to it.

```
powershell-scripts/   EVERY script. One folder, no sub-folders.
  Common.*.ps1          Shared code: logging, paths, the environment registry,
                        the confirmation gate. Never run directly.
  Get-*.ps1             Pull from Airtable.
  Build-*.ps1           Transform. Read-only against Salesforce.
  Invoke-*.ps1          Write: load, reset, bootstrap, roll back.
  Test-*.ps1            Check. Reads only.
docs/                 The runbooks in the table above.
reference/            Small hand-maintained business inputs. Tracked in git.
data/                 Inputs and staged output. Gitignored.
  airtable-exports/     One JSON file per Airtable table - all 22, so the pull
                        backs up the base. Overwritten each pull.
  prod-accounts/        The production Account export. Dev/QA only.
  salesforce-loads/     Load-ready CSVs the transforms produce.
logs/                 One folder per run. Gitignored.
.env                  Your Airtable token. Gitignored - never commit it.
.env.example          The template. Committed, contains no secrets.
```

**The prefix on a script's name tells you what it can do to your org.** That is the whole folder
structure — there are no sub-folders because the names carry the meaning:

| Prefix | Does | Can it change your org? |
| --- | --- | --- |
| `Get-` | Reads from a source system | **No** |
| `Build-` | Transforms data into a load-ready CSV | **No** |
| `Test-` | Checks that things are in order | **No** |
| `Invoke-` | Loads, deletes, rebuilds, rolls back | **Yes** |

**If a script's name starts with `Build`, it cannot change your org.** A full index of all 25 scripts,
with what each one does, is in [`docs/OVERVIEW.md`](docs/OVERVIEW.md#6-the-scripts).

Two more conventions worth knowing up front:

- **Everything one run produces lands in one folder**, `logs/<category>/<ScriptName>-<timestamp>/`,
  including any child scripts an orchestrated run spawns. Read `SUMMARY.txt` in there before anything
  else.
- **Writes are gated by a typed token**, not a `-Force` switch: `-Confirmation "LOAD"`,
  `-Confirmation "HARD DELETE"`. A token cannot be copy-pasted between a load and a delete by habit,
  and production needs a *second*, different one.

---

## Environments

Scripts never take a bare org alias. They take `-Environment`, and resolve it through the registry in
[`powershell-scripts/Common.Orgs.ps1`](powershell-scripts/Common.Orgs.ps1) — the single source of
truth.

| `-Environment` | Sandbox | Alias | Browser URL | Accounts |
| --- | --- | --- | --- | --- |
| `Dev` *(default)* | PEOdV8DVn | `peodv8dvn` | `gsa-peo--peodv8dvn.sandbox.lightning.force.com` | Rebuilt from an export |
| `QA` | PEOdV15DVn | `peodv15dvn` | `gsa-peo--peodv15dvn.sandbox.lightning.force.com` | Rebuilt from an export |
| `UAT` | **PEOfL1UATp** | `peofl1uatp` | `gsa-peo--peofl1uatp.sandbox.lightning.force.com` | **Real — never touched** |
| `Full` | **PEOfL2STGp** | `peofl2stgp` | `gsa-peo--peofl2stgp.sandbox.lightning.force.com` | **Real — never touched** |
| `Prod` | — | `gsa-peo` | `gsa-peo.lightning.force.com` | **Real — never touched** |

**An alias is the org's own sandbox name**, so it can be checked against the org it reaches. Every
script calls `Assert-LdgcrmOrgTarget` before doing anything, which asks the org itself who it is
(`Organization.IsSandbox`, plus its My Domain) and refuses to continue if the answer disagrees with
the registry. A repointed alias stops the run instead of silently retargeting it.

### Accounts are rebuilt in Dev and QA, and never anywhere else

Dev and QA are empty developer sandboxes, so an Account universe has to be invented for them before
anything else will attach. A **Full sandbox is a copy of production**, so its Accounts *are* the real
records this migration reconciles onto — replacing them with a stale export would invalidate the very
rehearsal the sandbox exists for.

This is enforced in code, in one place (`Test-LdgcrmAccountRebuildAllowed`), and three scripts obey
it: the factory reset drops Account from its delete list, the Account bootstrap refuses to start, and
the orchestrator rejects `-BootstrapAccounts`. Every *other* object still resets normally in a Full
sandbox — they carry an external ID because this migration made them.

---

## Two things that will bite you

**"Withheld" is not an error, and it is usually the bigger number.** Transforms skip rows whose parent
is not loaded, whose Account will not resolve, or whose junction partner was itself withheld. Those
rows are never submitted, so the Bulk API reports nothing, the step reports success, and the records
are simply absent. Any "how much migrated?" question has to account for withheld rows as well as
failed ones — `SUMMARY.txt` reports both.

**The org contains automation this folder cannot show you.** The sandbox hosts other GSA apps (FCIC,
TTS OTCRM, a Genesys managed package) whose triggers, duplicate rules and flows fire on records this
pipeline creates. A Contact insert with a blank `AccountId` makes a junk Account via another team's
trigger; an org duplicate rule was silently rejecting real people until the load started switching it
off. Both are known and handled — see [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — but check
the live org before loading a *new* object for the first time.

A third, related to both: **a successful-looking load is not evidence of a correct load.** One QA run
reported 8,740 records and zero failures while silently leaving a field blank on 1,960 of them.
[`docs/OVERVIEW.md`](docs/OVERVIEW.md#8-how-you-know-it-worked) explains what to check instead.

---

## Requirements

- **Windows PowerShell 5.1.** Every script declares `#Requires -Version 5.1` and avoids PowerShell
  7-only syntax, because PowerShell 7 is not installable on some GSA machines. They run fine under 7
  if you have it.
- **Salesforce CLI (`sf`)**, authenticated to the target org.
- **An Airtable Personal Access Token**, only for pulling fresh data. Loading from an existing export
  needs no Airtable access at all.

There is deliberately **no Python** and no third-party PowerShell module. Excel is not required even
to read an `.xlsx` export.

---

## Before you write to any org

Coordinate first. Loads are re-runnable, but a load nobody expected is still an incident, and this
org is shared with other teams. Production additionally needs a change window agreed in advance.

Metadata (fields, picklists, record types) moves between orgs by **change set only** — never by CLI
deploy. If a load is blocked because a field is missing, write it down and hand it to whoever builds
the change set.
