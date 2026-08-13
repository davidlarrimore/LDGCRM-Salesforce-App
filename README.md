# Login.gov Airtable → Salesforce CRM Migration

This repo builds the Salesforce CRM app used by the Login.gov Airtable → Salesforce CRM migration
project, and the automation around it: pulling metadata from the Salesforce sandbox, exporting a
data dictionary, cleaning up test data, and pulling/transforming/loading migrated records from
Airtable via the Salesforce CLI's Bulk API.

Everything here targets a single sandbox: org alias **`gsa-peo`**.

> For AI-agent-oriented conventions (data model, script patterns, gitignore rationale), see
> [CLAUDE.md](CLAUDE.md). This README is the human quick start.

## Repository layout

```
sfdx/                   Salesforce DX project (force-app, manifest, package.json, tests)
scripts/
  common/                Shared PowerShell helpers (logging, repo-root resolution)
  metadata/              Pull metadata + export the data dictionary from the sandbox
  cleanup/               Interactive, destructive sandbox record cleanup
  data-migration/        Pull Airtable data, transform to load-ready CSVs, load into gsa-peo
docs/                    Data-migration pipeline docs (architecture, field mappings, data-quality asks)
logs/                    Gitignored run output (transcripts, CSV exports)
data/                    Gitignored Airtable exports, prepped load CSVs, and mapping files
```

`logs/` and `data/` are gitignored on purpose — their contents can include PII pulled from Login.gov
applicants via Airtable or the sandbox. Only `.gitkeep`/`README.md` placeholders are tracked there.

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`)
- Windows PowerShell 5.1+ (`powershell`, built into Windows) — all automation scripts target this;
  they also run fine under [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
  (`pwsh`) if you have it, but nothing in `scripts/` requires it
- Node.js (for `sfdx/`'s lint/test/prettier tooling — see `sfdx/package.json`)
- Access to the `gsa-peo` Salesforce sandbox

## Setup

```bash
# Authenticate to the sandbox once per machine (sandboxes use test.salesforce.com)
sf org login web --alias gsa-peo --instance-url https://test.salesforce.com

# Verify the connection
sf org display --target-org gsa-peo

# Install sfdx/ tooling (lint, prettier, jest, husky pre-commit hook)
cd sfdx && npm install

# If retrieving metadata into sfdx/force-app fails with "Filename too long",
# this machine's disk mount adds a long path prefix that trips Windows' 260-char
# limit on deeply nested Salesforce metadata paths. Fix once per clone:
git config core.longpaths true

# For the Airtable pull script: copy the template and fill in your own
# Personal Access Token + base ID (both gitignored, never commit .env)
cp .env.example .env
```

## Common tasks

Run these from the repo root with `powershell`:

```powershell
# Pull metadata listed in sfdx/manifest/package.xml into sfdx/force-app
powershell scripts/metadata/Sync-Metadata.ps1

# Export a full object/field data dictionary CSV to logs/metadata/
powershell scripts/metadata/Get-LDGCRMDataDictionary.ps1
```

**Destructive — sandbox test-data cleanup:**

```powershell
powershell scripts/cleanup/cleanup-gsa-peo.ps1
```

Hard-deletes records (only rows where `LDGCRM_External_ID__c` is set) after a typed `HARD DELETE`
confirmation, exporting the deleted IDs to `logs/cleanup/` first as an audit trail. Read the prompts.

Every script writes a transcript (and any CSV output) under `logs/<category>/` via
`scripts/common/Common.ps1`, so history of what ran and when is always available locally, without
ever needing to be committed.

## Salesforce app changes

Standard SFDX workflow inside `sfdx/`:

```bash
cd sfdx
npm run lint              # ESLint over aura/lwc JS
npm test                  # sfdx-lwc-jest
npm run prettier:verify   # Prettier check
sf project deploy validate --source-dir force-app --target-org gsa-peo
sf project deploy start    --source-dir force-app --target-org gsa-peo
```

The Husky `pre-commit` hook runs `lint-staged` (Prettier + ESLint + related Jest tests) automatically.

> **Known issue:** `deploy validate` (and any `deploy start` that runs tests) currently fails
> org-wide due to a pre-existing Apex compile error in an unrelated app (FCIC) that shares this
> sandbox — not something caused by changes in this repo. See `CLAUDE.md`'s "Operational gotchas"
> for the `--test-level NoTestRun` workaround for metadata-only changes with no Apex involved.

## Data migration

Moves data from Airtable into `gsa-peo`, in three stages — pull, prep/transform, load. See
[docs/README.md](docs/README.md) for the full pipeline and
build status, and
[docs/TRANSFORMATION-RULES.md](docs/TRANSFORMATION-RULES.md)
for the field-by-field mapping rules and every data-quality gotcha found per object.
[docs/AIRTABLE-DATA-QUALITY-REQUESTS.md](docs/AIRTABLE-DATA-QUALITY-REQUESTS.md) is the
non-developer-facing list of Airtable data issues blocking the migration — that's the file to hand to
whoever maintains the Airtable base.

**Loaded into `gsa-peo` so far:** Market Segment, Account (588 reconciled of 1,350), Partner Account
(74), Impediment (39), Application (688), Opportunity (742), Contact (1,483), and the
Application↔Contact junction (1,880), the Impediment↔Opportunity junction (267), and
OpportunityContactRole (515). Meetings and the Notes chunk are not built yet — see `docs/README.md`
for per-script build status.

⚠️ **Loading Contact temporarily disables another app's Apex trigger** (`-DisableTriggerControl`) —
read "Loading Contact" in [docs/README.md](docs/README.md) before running it.

```powershell
# Pull every table straight from the Airtable REST API into data/airtable-exports/<Table>.json
# (overwrites each run). Requires AIRTABLE_API_KEY + AIRTABLE_BASE_ID in .env — see Setup above.
powershell scripts/data-migration/Get-AirtableExport.ps1

# Transform a pulled table into a load-ready CSV in data/salesforce-loads/
powershell scripts/data-migration/Build-ImpedimentLoad.ps1

# Load a prepped CSV into gsa-peo (prompts "Type LOAD to continue")
powershell scripts/data-migration/Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_Impediment__c" `
    -CsvFile "data/salesforce-loads/LDGCRM_Impediment__c-upsert.csv"
```

Loading uses the Salesforce CLI's Bulk API (`sf data upsert bulk`/`sf data update bulk`), not the
Data Loader CLI originally planned — that tool isn't installed in this environment and needs Java
11+, while `sf` is already installed and used everywhere else in this repo. See the pipeline
README's Stage 3 section for the full reasoning. Every load is keyed on `LDGCRM_External_ID__c` for
idempotent upserts, except Account, which is a Salesforce-`Id`-keyed update (Accounts already exist
independently of this migration — see `docs/TRANSFORMATION-RULES.md`).
