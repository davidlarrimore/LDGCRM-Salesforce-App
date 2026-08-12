# Login.gov Airtable → Salesforce CRM Migration

This repo builds the Salesforce CRM app used by the Login.gov Airtable → Salesforce CRM migration
project, and the automation around it: pulling metadata from the Salesforce sandbox, exporting a
data dictionary, cleaning up test data, and (upcoming) loading migrated records with Data Loader.

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
  data-migration/        Data Loader migration scripts (not built yet)
logs/                    Gitignored run output (transcripts, CSV exports)
data/                    Gitignored Airtable exports + Data Loader mapping files
```

`logs/` and `data/` are gitignored on purpose — their contents can include PII pulled from Login.gov
applicants via Airtable or the sandbox. Only `.gitkeep`/`README.md` placeholders are tracked there.

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`)
- [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`) — all automation scripts are cross-platform PowerShell, not Windows-only
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
```

## Common tasks

Run these from the repo root with `pwsh`:

```bash
# Pull metadata listed in sfdx/manifest/package.xml into sfdx/force-app
pwsh scripts/metadata/Sync-Metadata.ps1

# Export a full object/field data dictionary CSV to logs/metadata/
pwsh scripts/metadata/Get-LDGCRMDataDictionary.ps1
```

**Destructive — sandbox test-data cleanup:**

```bash
pwsh scripts/cleanup/cleanup-gsa-peo.ps1
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

## Data migration (Data Loader)

Not built yet. `scripts/data-migration/` is reserved for the Data Loader wrapper scripts that will
move Airtable exports (`data/airtable-exports/`) into Salesforce using the field mappings in
`data/mappings/`, keyed on `LDGCRM_External_ID__c` for idempotent upserts.
