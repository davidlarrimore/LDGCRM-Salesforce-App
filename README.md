# Login.gov Airtable → Salesforce CRM Migration

Login.gov's partnership team tracks agencies, applications and opportunities in an **Airtable base**.
This repo moves that data into **Salesforce**, and maintains the Salesforce app it lands in.

Two kinds of work live here:

- **`sfdx/`** — the Salesforce app's metadata: custom objects prefixed `LDGCRM_`, flows, layouts,
  permission sets.
- **`scripts/`** — PowerShell automation that pulls from Airtable, transforms the data, and loads it
  into a Salesforce org. Repeatably: it reads Airtable fresh every time and matches against what is
  already in Salesforce, so running it twice does not create duplicates.

---

## Where to go

| I want to… | Go to |
| --- | --- |
| **Run a data migration** *(start here if that's you)* | **[docs/operations/SETUP.md](docs/operations/SETUP.md)** |
| Understand or change how the migration works | [docs/engineering/ARCHITECTURE.md](docs/engineering/ARCHITECTURE.md) |
| Look up what a field maps to | [docs/engineering/TRANSFORMATION-RULES.md](docs/engineering/TRANSFORMATION-RULES.md) |
| Fix something in the Airtable source data | [docs/data-quality/](docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) |
| Read the status report | [docs/migration-load-report-2026-08-13-post-reload.pdf](docs/migration-load-report-2026-08-13-post-reload.pdf) |
| Change the Salesforce app itself | [Salesforce app changes](#salesforce-app-changes), below |

Full index: **[docs/engineering/ARCHITECTURE.md](docs/engineering/ARCHITECTURE.md)**.

---

## Environments

Every script takes `-Environment Dev|QA|Full|Prod` (default **Dev**) and resolves the org alias
itself. **You never pass a Salesforce username or alias by hand.**

| `-Environment` | Alias | Used for |
| --- | --- | --- |
| `Dev` *(default)* | `peodv8dvn` | Day-to-day development and pipeline testing |
| `QA` | `peodv15dvn` | Full end-to-end migration rehearsal |
| `Full` | *not yet provisioned* | Operations dress rehearsal, immediately before production |
| `Prod` | `gsa-peo` | **The live GSA PEO org. Real partner data.** |

> ### ⚠️ `gsa-peo` means production
>
> It changed meaning on 2026-08-13. It used to be the alias for the **Dev sandbox**, despite being
> the *production* org's name. Any stale command line saying `--target-org gsa-peo` was talking about
> Dev and is now **a silent retarget to production**. Treat finding one as a defect, not a typo.
>
> The local alias was deleted and production is not authorized on development machines, so a stale
> reference fails loudly rather than writing to production. Don't re-create it pointing anywhere
> else.

**An alias is the org's own sandbox name**, so it can be cross-checked and cannot quietly drift. The
registry is [`scripts/common/Common.Orgs.ps1`](scripts/common/Common.Orgs.ps1); nothing else
hard-codes an alias. Before reading or writing, every script asks the org for its own identity and
stops if it disagrees with the registry — because an alias is just a pointer on your laptop, and the
only trustworthy statement about what it points at comes from the org itself.

Writes and deletes against `Prod` need the org alias typed at an **extra** gate, on top of whatever
the script already asks for.

---

## Repository layout

```
sfdx/                    Salesforce DX project (force-app, manifest, tests)
scripts/
  common/                Shared helpers: logging, org registry, confirmation gates
  metadata/              Pull metadata + export a data dictionary
  cleanup/               Sandbox factory reset (destructive, sandbox-only)
  data-migration/        Pull Airtable → transform → load → roll back
docs/
  operations/            How to RUN a migration        ← start here
  engineering/           How the pipeline WORKS
  data-quality/          Asks for the Airtable data owners
logs/                    Gitignored run output — transcripts, restore points, review CSVs
data/                    Gitignored Airtable exports and load-ready CSVs
```

**`logs/` and `data/` are gitignored deliberately** — their contents can include PII from Login.gov
applicants sourced via Airtable. Only `.gitkeep` and `README.md` are tracked there. Don't commit
anything else from them.

---

## Quick start

```powershell
# 1. Authenticate to a sandbox, at its own My Domain URL (not test.salesforce.com)
sf org login web --alias peodv8dvn `
    --instance-url https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com

# 2. Airtable credentials — needs an admin account on the base and a Personal
#    Access Token. See docs/operations/SETUP.md; it needs two scopes and
#    someone has to grant you base access first.
Copy-Item .env.example .env    # then fill in AIRTABLE_API_KEY

# 3. Windows long-path support, once per clone
git config core.longpaths true

# 4. See what a load would do — runs every transform, writes nothing
powershell scripts/data-migration/Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly
```

Then read **[docs/operations/RUNNING-A-LOAD.md](docs/operations/RUNNING-A-LOAD.md)**.

> **Nothing writes to Salesforce except the load step.** Every `Build-*.ps1` transform is read-only
> against the org, so you can always see exactly what *would* be written before anything is. Every
> write is gated behind a typed token — `-Confirmation "LOAD"`, `"HARD DELETE"`, `"BOOTSTRAP"`,
> `"ROLLBACK"` — which is passable non-interactively but never bypassable.

---

## Salesforce app changes

Working on the app's metadata rather than the data migration.

```powershell
# Pull metadata listed in sfdx/manifest/package.xml into sfdx/force-app.
# Discovers new LDGCRM_ components and adds them to the manifest first.
powershell scripts/metadata/Sync-Metadata.ps1 -Environment Dev

# Export a full object/field data dictionary CSV to logs/metadata/
powershell scripts/metadata/Get-LDGCRMDataDictionary.ps1 -Environment Dev
```

From inside `sfdx/`:

```bash
npm run lint            # ESLint over aura/ and lwc/ JS
npm test                # sfdx-lwc-jest
npm run prettier        # format
```

A Husky `pre-commit` hook runs Prettier, ESLint and related Jest tests on staged files.

> **Deploying is currently blocked org-wide by an unrelated app.** A pre-existing Apex compile error
> in another application sharing the sandbox fails *any* deploy that runs tests, because Salesforce
> compiles all Apex in the org first. For metadata-only changes on a sandbox, use
> `sf project deploy start --test-level NoTestRun --target-org peodv8dvn`. See
> [docs/operations/TROUBLESHOOTING.md](docs/operations/TROUBLESHOOTING.md#sf-project-deploy-fails-on-apex-unrelated-to-this-app).

**Retrieving metadata is scoped on purpose.** The manifest covers this app only; the sandbox hosts
unrelated applications. A broad wildcard retrieve pulls the entire org — review
`git status sfdx/force-app` before committing if you run one.

---

## Coordination

**More than one person can write to these orgs.** At least one colleague uses the Data Loader GUI
against the same sandbox, and other teams share the org entirely. Before any write — even a small
test batch — check that nobody else is mid-load. Two load processes against one org can race or
double-load.

---

> For conventions aimed at AI coding assistants — data model detail, script patterns, gitignore
> rationale — see [CLAUDE.md](CLAUDE.md).
