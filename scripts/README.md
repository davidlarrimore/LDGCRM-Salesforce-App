# Login.gov CRM migration — Airtable → Salesforce

**Start here.** This folder is everything needed to pull data out of Airtable and
load it into a Salesforce org. It is self-contained: it reads and writes only
paths inside itself, so it runs correctly wherever it is placed.

New to this? Read [`docs/SETUP.md`](docs/SETUP.md) first — it assumes no prior
knowledge of the project.

---

## What this does

The Login.gov partnership team tracked its work in Airtable. This pipeline moves
that data into the GSA PEO Salesforce org: ten Airtable tables become Accounts,
Contacts, Opportunities, Applications, Partner Accounts, Impediments, junction
records, and Notes.

Every record it creates carries `LDGCRM_External_ID__c`, holding the Airtable
row's `rec...` ID. That is what makes the whole thing **re-runnable**: loads are
upserts keyed on that field, so running a load twice updates rather than
duplicates.

**One important exception to the mental model: the migration does not create
Accounts.** Accounts already exist in Salesforce and pre-date this project, so
the pipeline *reconciles onto* them by name and external ID. See
[`data/prod-accounts/README.md`](data/prod-accounts/README.md) for what that
means when you are working in an empty Dev or QA sandbox.

---

## Where to go

| You want to… | Read |
| --- | --- |
| Install the tools and get credentials | [`docs/SETUP.md`](docs/SETUP.md) |
| **Check everything is set up correctly** | `.\powershell-scripts\Test-LdgcrmReadiness.ps1` — read-only, safe anywhere. See [`docs/RUNNING-A-LOAD.md`](docs/RUNNING-A-LOAD.md#am-i-ready--the-readiness-check) |
| Run a load | [`docs/RUNNING-A-LOAD.md`](docs/RUNNING-A-LOAD.md) |
| Work out why something failed | [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) |
| Undo a load | [`docs/ROLLBACK.md`](docs/ROLLBACK.md) |
| Sign off a full rehearsal | [`docs/RELOAD-QA-CHECKLIST.md`](docs/RELOAD-QA-CHECKLIST.md) |
| Understand what a run left behind | [`logs/README.md`](logs/README.md) |

---

## Environments

Scripts never take a bare org alias. They take `-Environment`, and resolve it
through the registry in [`powershell-scripts/Common.Orgs.ps1`](powershell-scripts/Common.Orgs.ps1) —
the single source of truth.

| `-Environment` | Sandbox | Alias | Browser URL | Accounts |
| --- | --- | --- | --- | --- |
| `Dev` *(default)* | PEOdV8DVn | `peodv8dvn` | `gsa-peo--peodv8dvn.sandbox.lightning.force.com` | Rebuilt from an export |
| `QA` | PEOdV15DVn | `peodv15dvn` | `gsa-peo--peodv15dvn.sandbox.lightning.force.com` | Rebuilt from an export |
| `Full` | **PEOfL2STGp** | `peofl2stgp` | `gsa-peo--peofl2stgp.sandbox.lightning.force.com` | **Real — never touched** |
| `Prod` | — | `gsa-peo` | `gsa-peo.lightning.force.com` | **Real — never touched** |

> ### ⚠️ `gsa-peo` means PRODUCTION
>
> It used to be the alias for the Dev sandbox. Any older note, transcript or
> command line saying `--target-org gsa-peo` was talking about **Dev** — running
> it today would target production. Read the hazard note at the top of
> `powershell-scripts/Common.Orgs.ps1` before re-creating that alias.

**An alias is the org's own sandbox name**, so it can be checked against the org
it reaches. Every script calls `Assert-LdgcrmOrgTarget` before doing anything,
which asks the org itself who it is (`Organization.IsSandbox`, plus its My
Domain) and refuses to continue if the answer disagrees with the registry. A
repointed alias stops the run instead of silently retargeting it.

### Accounts are rebuilt in Dev and QA, and never anywhere else

Dev and QA are empty developer sandboxes, so an Account universe has to be
invented for them before anything else will attach. A **Full sandbox is a copy
of production**, so its Accounts *are* the real records this migration
reconciles onto — replacing them with a stale export would invalidate the very
rehearsal the sandbox exists for.

This is enforced in code, in one place (`Test-LdgcrmAccountRebuildAllowed`), and
three scripts obey it: the factory reset drops Account from its delete list, the
Account bootstrap refuses to start, and the orchestrator rejects
`-BootstrapAccounts`. Every *other* object still resets normally in a Full
sandbox — they carry an external ID because this migration made them.

---

## Quick start

**Open PowerShell in this folder and stay here.** Every command in this README
and in `docs/` is written relative to it — `.\powershell-scripts\Something.ps1`.
Nothing needs to be run from a parent directory, and nothing resolves outside
this folder, so it works wherever the folder happens to live.

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

# 3. See what a load would do. Runs every transform, writes NOTHING to Salesforce.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly

# 4. Apply it
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev
```

Always run `-PlanOnly` first. It is a genuine dry run: it executes every
transform, captures a restore point, and reports what each step *would* load.

---

## How it is laid out

**You run everything from this folder**, and every path below is relative to it.

```
powershell-scripts/   EVERY script. One folder, no sub-folders.
  Common.ps1            Shared helpers: logging, paths, the confirmation gate.
  Common.Orgs.ps1       The environment registry - which org each name means.
  Get-*.ps1             Pull from Airtable.
  Build-*.ps1           Transform. Read-only against Salesforce.
  Invoke-*.ps1          Write: load, reset, bootstrap, roll back.
docs/                 The runbooks in the table above.
data/                 Inputs and staged output. Gitignored.
  airtable-exports/     One JSON file per Airtable table - all 22, so the pull
                        backs up the base. Overwritten each pull.
  prod-accounts/        The production Account export. Dev/QA only.
  salesforce-loads/     Load-ready CSVs the transforms produce.
logs/                 One folder per run. Gitignored.
.env                  Your Airtable token. Gitignored - never commit it.
.env.example          The template. Committed, contains no secrets.
```

**The scripts are deliberately in one flat folder.** They used to be split across
`common/`, `cleanup/` and `data-migration/`, which implied a distinction that did
not survive contact with the work — `cleanup/` held one file, `common/` held two,
and everything else was in the third. The split cost a mental hop on every
command while separating almost nothing. They are all PowerShell scripts for one
pipeline, so they live together.

Three naming conventions now carry all of the meaning:

- **`Get-*.ps1`** reads from a source system. **`Build-*.ps1`** transforms, and
  *never writes to Salesforce* — it only produces a CSV. **`Invoke-*.ps1`**
  writes. If a script's name starts with `Build`, it cannot change your org.
- **Everything one run produces lands in one folder**,
  `logs/<category>/<ScriptName>-<timestamp>/`, including any child scripts an
  orchestrated run spawns. Read `SUMMARY.txt` in there before anything else.
- **Writes are gated by a typed token**, not a `-Force` switch:
  `-Confirmation "LOAD"`, `-Confirmation "HARD DELETE"`. A token cannot be
  copy-pasted between a load and a delete by habit, and production needs a
  *second*, different one.

---

## Two things that will bite you

**"Withheld" is not an error, and it is usually the bigger number.** Transforms
skip rows whose parent is not loaded, whose Account will not resolve, or whose
junction partner was itself withheld. Those rows are never submitted, so the
Bulk API reports nothing, the step reports success, and the records are simply
absent. Any "how much migrated?" question has to account for withheld rows as
well as failed ones — `SUMMARY.txt` reports both.

**The org contains automation this folder cannot show you.** The sandbox hosts
other GSA apps (FCIC, TTS OTCRM, a Genesys managed package) whose triggers,
duplicate rules and flows fire on records this pipeline creates. A Contact
insert with a blank `AccountId` makes a junk Account via another team's trigger;
an org duplicate rule rejects a handful of Contacts every run. Both are known
and handled — see `docs/TROUBLESHOOTING.md` — but check the live org before
loading a *new* object for the first time.

---

## Requirements

- **Windows PowerShell 5.1.** Every script declares `#Requires -Version 5.1` and
  avoids PowerShell 7-only syntax, because PowerShell 7 is not installable on
  some GSA machines. They run fine under 7 if you have it.
- **Salesforce CLI (`sf`)**, authenticated to the target org.
- **An Airtable Personal Access Token**, only for pulling fresh data. Loading
  from an existing export needs no Airtable access at all.

There is deliberately **no Python** and no third-party PowerShell module. Excel
is not required even to read an `.xlsx` export.

---

## Before you write to any org

Coordinate first. Loads are re-runnable, but a load nobody expected is still an
incident, and this org is shared with other teams. Production additionally needs
a change window agreed in advance.

Metadata (fields, picklists, record types) moves between orgs by **change set
only** — never by CLI deploy. If a load is blocked because a field is missing,
write it down and hand it to whoever builds the change set.
