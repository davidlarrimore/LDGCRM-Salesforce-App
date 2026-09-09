# Login.gov Partnerships CRM

Login.gov's partnership team tracks agencies, applications and opportunities in a
**Salesforce app** running in GSA PEO's org. This repo holds that app, and the
tooling used to develop it.

The app's data came from an **Airtable base**, migrated in Sprint 1 and **shipped
to production on 2026-09-08**. That migration is complete. What remains here is
the app itself, plus the tools to rebuild a developer sandbox so it can be worked
on against realistic data.

---

## Where to go

| I want to… | Go to |
| --- | --- |
| **Change the Salesforce app** *(start here if that's you)* | [Salesforce app changes](#salesforce-app-changes), below |
| **Load a dev or QA sandbox** with realistic data | [Loading a sandbox](#loading-a-sandbox), below |
| Understand how the loading tools work | [docs/engineering/ARCHITECTURE.md](docs/engineering/ARCHITECTURE.md) |
| Look up what an Airtable column maps to | [docs/engineering/TRANSFORMATION-RULES.md](docs/engineering/TRANSFORMATION-RULES.md) |
| Fix something in the Airtable source data | [docs/data-quality/](docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) |
| See what shipped, component by component | [docs/engineering/PRODUCTION-CHANGE-SET-INVENTORY.md](docs/engineering/PRODUCTION-CHANGE-SET-INVENTORY.md) |
| Find Sprint 1's operator runbooks | `archive/sprint_1_scripts.zip`, `archive/sprint_1_docs.zip` |

---

## Repository layout

```
sfdx/                    THE PRODUCT. Salesforce DX project.
  force-app/             Retrieved metadata - the source of truth for the data model
  manifest/package.xml   Retrieval scope, and the basis for change sets

tools/                   Engineering-only. Nothing here ships.
  data-loading/          Dev/QA sandbox load + factory reset (26 scripts)
  metadata/              Sync-Metadata, data dictionary, change-set inventory
  Backup-AirtableBase.ps1, Export-ReportPdf.ps1, Test-AccountMatching.ps1

data/                    GITIGNORED - APPLICANT PII
  airtable-exports/      The pulled Airtable base (all 22 tables)
  prod-accounts/         Production Account export, seeds a sandbox rebuild
  salesforce-loads/      Load-ready CSVs staged for the Bulk API

logs/                    GITIGNORED. One directory per run.
archive/                 Sprint 1, frozen: scripts + docs zips
scripts/                 EMPTY - reserved for Sprint 2
reference/               Salesforce user roster
docs/engineering/        How the app and its tooling work
docs/data-quality/       Open asks for the data owners
.env / .env.example      Airtable credentials (the .env is gitignored)
```

**The root `.gitignore` is the only thing protecting `data/` and `.env`.** Sprint
1's bundle carried its own nested `.gitignore` that travelled with the folder;
that file is gone with the bundle. If you add a new output location, add the
ignore rule **in the same change**.

---

## Environments

The loading tools take `-Environment Dev|QA` (default **Dev**) and resolve the
org alias themselves. **You never pass a Salesforce username or alias by hand.**

| `-Environment` | Alias | Used for |
| --- | --- | --- |
| `Dev` *(default)* | `peodv8dvn` | Day-to-day development |
| `QA` | `peodv15dvn` | Shared testing against a freshly loaded sandbox |

**These tools cannot reach production.** `Dev` and `QA` are the only accepted
values, rejected at parameter binding rather than by a runtime check, and the
registry ([`tools/data-loading/Common.Orgs.ps1`](tools/data-loading/Common.Orgs.ps1))
contains no production entry. Every script also asks the org for its own identity
before reading or writing and stops if it disagrees — because an alias is just a
pointer on your laptop, and the only trustworthy statement about what it points
at comes from the org.

---

## Salesforce app changes

```powershell
# Pull metadata listed in sfdx/manifest/package.xml into sfdx/force-app.
# Discovers new LDGCRM_ components and adds them to the manifest first.
powershell tools/metadata/Sync-Metadata.ps1 -Environment Dev

# Report only - no manifest edit, no retrieve
powershell tools/metadata/Sync-Metadata.ps1 -Environment Dev -WhatIf

# Export a full object/field data dictionary CSV
powershell tools/metadata/Get-LDGCRMDataDictionary.ps1 -Environment Dev
```

From inside `sfdx/`:

```bash
npm run lint            # ESLint over aura/ and lwc/ JS
npm test                # sfdx-lwc-jest
npm run prettier        # format
```

A Husky `pre-commit` hook runs Prettier, ESLint and related Jest tests on staged
files.

**Metadata moves between orgs by change set only.** Never `sf project deploy` a
change from this repo — not even to Dev, which is the *source* org for change
sets, so anything deployed there silently joins the next promotion. The one
exception is deleting incorrect metadata. See [CLAUDE.md](CLAUDE.md).

> **Deploying is currently blocked org-wide by an unrelated app.** A pre-existing
> Apex compile error in `GSA_FCIC_AC_Manual_InitialBatch` fails *any* deploy that
> runs tests, because Salesforce compiles all Apex in the org first. For
> metadata-only changes on a sandbox, use
> `sf project deploy start --test-level NoTestRun --target-org peodv8dvn`.

**Retrieving is scoped on purpose.** The manifest covers this app only; the org
also hosts FCIC and TTS OTCRM. A broad wildcard retrieve pulls the entire org —
review `git status sfdx/force-app` before committing if you run one. Note also
that **a retrieve never deletes local files**, so a component removed from the
org stays in `force-app/` looking current.

---

## Loading a sandbox

```powershell
# 1. Authenticate, at the sandbox's own My Domain URL (not test.salesforce.com)
sf org login web --alias peodv8dvn `
    --instance-url https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com

# 2. Windows long-path support, once per clone
git config core.longpaths true

# 3. Check the org and the inputs are in a fit state. Read-only.
#    Its "export is N days old" warning is expected and permanent - see below.
powershell tools/data-loading/Test-LdgcrmReadiness.ps1 -Environment Dev

# 4. See what a load would do - runs every transform, writes nothing
powershell tools/data-loading/Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly
```

> **⚠️ There is no "pull Airtable" step any more. Airtable is shut down.** The
> source data is the frozen 2026-09-02 export already in `data/airtable-exports/`,
> and it is the **last copy** — `Get-AirtableExport.ps1` and
> `Backup-AirtableBase.ps1` cannot succeed and should not be run. The Airtable
> token in `.env` is therefore dead too. Export age is not a defect, so the
> readiness check's ">7 days old" warning is now permanent noise. See
> [CLAUDE.md](CLAUDE.md) for the preservation problem this creates.

A sandbox that has just been refreshed holds **no records at all**, so the load
needs `-BootstrapAccounts` to build an Account universe from the production
export first — the transforms reconcile *onto* existing Accounts rather than
creating them, and without it every downstream step silently withholds
everything.

> **Nothing writes to Salesforce except the load step.** Every `Build-*.ps1`
> transform is read-only against the org, so you can always see exactly what
> *would* be written before anything is. Every write is gated behind a typed
> token — `-Confirmation "LOAD"`, `"HARD DELETE"`, `"BOOTSTRAP"`, `"ROLLBACK"` —
> passable non-interactively but never bypassable.

---

## Coordination

**More than one person can write to these orgs.** At least one colleague uses the
Data Loader GUI against the same sandbox, and other teams share the org entirely.
Before any write — even a small test batch — check that nobody else is mid-load.
Two load processes against one org can race or double-load.

---

> For conventions aimed at AI coding assistants — data model detail, PowerShell
> traps, record-type scoping, org gotchas — see [CLAUDE.md](CLAUDE.md).

**Integration user:** `ldgcrm_integration@gsa.gov.peo1.peodv8dvn`
