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
| **Run a data migration** *(start here if that's you)* | **[scripts/docs/SETUP.md](scripts/docs/SETUP.md)** |
| Understand or change how the migration works | [docs/engineering/ARCHITECTURE.md](docs/engineering/ARCHITECTURE.md) |
| Look up what a field maps to | [docs/engineering/TRANSFORMATION-RULES.md](docs/engineering/TRANSFORMATION-RULES.md) |
| Fix something in the Airtable source data | [docs/data-quality/](docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) |
| **See where the project is** — what's left before production | **[docs/PRODUCTION-READINESS.md](docs/PRODUCTION-READINESS.md)** |
| Read the status report | [docs/migration-load-report-2026-08-14.html](docs/migration-load-report-2026-08-14.html) — render the PDF before sending |
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
registry is [`scripts/powershell-scripts/Common.Orgs.ps1`](scripts/powershell-scripts/Common.Orgs.ps1); nothing else
hard-codes an alias. Before reading or writing, every script asks the org for its own identity and
stops if it disagrees with the registry — because an alias is just a pointer on your laptop, and the
only trustworthy statement about what it points at comes from the org itself.

Writes and deletes against `Prod` need the org alias typed at an **extra** gate, on top of whatever
the script already asks for.

---

## Repository layout

```
scripts/                 ← THE OPERATIONS BUNDLE. Self-contained; ships to the Ops team.
  README.md              Its own entry point — start here to RUN a migration
  common/                Shared helpers: logging, org registry, confirmation gates
  cleanup/               Sandbox factory reset (destructive, sandbox-only)
  powershell-scripts/        Pull Airtable → transform → load → roll back
  docs/                  Operator runbooks (moved out of the repo-level docs/)
  data/                  Gitignored: Airtable exports, prod Account export, load CSVs
  logs/                  Gitignored: transcripts, restore points, review CSVs
  .env / .env.example    Airtable credentials (the .env is gitignored)
  .gitignore             Travels WITH the folder — see below

sfdx/                    Salesforce DX project (force-app, manifest, tests)
tools/                   Engineering-only. Needs sfdx/ or docs/, so NOT in the bundle.
  metadata/              Pull metadata + export a data dictionary
  Export-OpsBundle.ps1   Builds the zip handed to Operations
docs/
  PRODUCTION-READINESS.md  The seven gates to production
  engineering/           How the pipeline WORKS
  data-quality/          Asks for the Airtable data owners
```

### `scripts/` is a self-contained bundle, on purpose

The GSA Salesforce Operations team runs this pipeline out of **their own** GitHub
repository, where it lives as a plain `/scripts` folder. So (changed 2026-08-14):

- **Nothing in `scripts/` resolves a path above its own root.** Everything hangs off
  `Get-LdgcrmRoot` in `scripts/powershell-scripts/Common.ps1`, which is the folder itself. The old
  `Get-RepoRoot` was *deleted* from the bundle rather than left in place — it would have kept
  resolving happily and quietly returned someone else's repository root.
- **`scripts/.gitignore` is the authority** for `data/`, `logs/` and `.env`, not the root
  `.gitignore`. A nested `.gitignore` applies in whatever repository contains it, so the PII
  protection travels with the folder instead of being left behind on the move.
- **Anything needing `sfdx/` or `docs/` lives in `tools/`** and uses `tools/Common.Tools.ps1`.
  That is also the policy boundary: metadata moves by change set only, so Operations has no use
  for a retrieve/deploy script.

Build the hand-off zip with `tools/Export-OpsBundle.ps1`. It excludes `.env`, `data/` and `logs/`
contents, then reads the finished archive back to prove it — and deletes the zip if anything
unexpected is in it.

---

## Quick start

```powershell
# 1. Authenticate to a sandbox, at its own My Domain URL (not test.salesforce.com)
sf org login web --alias peodv8dvn `
    --instance-url https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com

# 2. Airtable credentials — needs an admin account on the base and a Personal
#    Access Token. See scripts/docs/SETUP.md; it needs two scopes and
#    someone has to grant you base access first.
Copy-Item scripts/.env.example scripts/.env    # then fill in AIRTABLE_API_KEY

# 3. Windows long-path support, once per clone
git config core.longpaths true

# 4. See what a load would do — runs every transform, writes nothing
powershell scripts/powershell-scripts/Invoke-FullMigrationLoad.ps1 -Environment Dev -PlanOnly
```

Then read **[scripts/README.md](scripts/README.md)** and
**[scripts/docs/RUNNING-A-LOAD.md](scripts/docs/RUNNING-A-LOAD.md)**.

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
powershell tools/metadata/Sync-Metadata.ps1 -Environment Dev

# Export a full object/field data dictionary CSV to logs/tools/
powershell tools/metadata/Get-LDGCRMDataDictionary.ps1 -Environment Dev
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
> [scripts/docs/TROUBLESHOOTING.md](scripts/docs/TROUBLESHOOTING.md#sf-project-deploy-fails-on-apex-unrelated-to-this-app).

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
