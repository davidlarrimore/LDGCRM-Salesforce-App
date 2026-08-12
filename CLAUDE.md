# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

This repo builds the Salesforce CRM app (in a Salesforce sandbox, org alias `gsa-peo`) that the
**Login.gov Airtable -> Salesforce CRM Migration Project** is migrating data into. There are two
kinds of work here: maintaining the Salesforce app's metadata (`sfdx/`), and PowerShell automation
for pulling metadata/data out of the sandbox and (upcoming) loading migrated data into it (`scripts/`).

This is a single-org setup: every script targets the `gsa-peo` sandbox alias. Records created by the
migration carry an external ID field, `LDGCRM_External_ID__c`, used to correlate Salesforce records
back to their Airtable source.

See [README.md](README.md) for human-facing setup/quick-start steps (auth, prerequisites, common
commands). This file focuses on conventions and architecture for working in the code.

## Repository layout

- `sfdx/` — the Salesforce DX project (`sf` CLI). `force-app/main/default/` holds retrieved metadata,
  synced from an authoritative Salesforce Outbound Change Set (`LDGCRM_Sprint_1_12`) rather than
  hand-picked components. `manifest/package.xml` mirrors that scope for repeat syncs via
  `sf project retrieve start -x manifest/package.xml`.
- `scripts/` — PowerShell automation, organized by purpose (`metadata/`, `cleanup/`, `data-migration/`,
  `common/`). See "Scripts" below.
- `logs/` — **gitignored** (except `.gitkeep`/`README.md`). Run output: PowerShell transcripts and CSV
  exports (data dictionaries, cleanup exports/summaries), mirroring the `scripts/` categories.
- `data/` — **gitignored** (except `.gitkeep`/`README.md`). `airtable-exports/` and `mappings/` are
  placeholders for future Airtable source extracts and Data Loader field-mapping files.

`logs/` and `data/` are gitignored by default because their contents can carry PII from Login.gov
applicants sourced via Airtable. Don't commit anything under those trees beyond `.gitkeep`/`README.md`
without a specific reason.

## Data model

`sfdx/force-app/main/default/objects/` is now the source of truth (synced from the `LDGCRM_Sprint_1_12`
change set) — read it directly for exact fields/relationships. Custom objects use the `LDGCRM_` prefix:
`LDGCRM_Application__c`, `LDGCRM_Application_Contact__c`, `LDGCRM_Partner_Account__c`,
`LDGCRM_Impediment__c`, `LDGCRM_Opportunity_Impediment__c`, `LDGCRM_Market_Segment__c`. Standard
objects carrying custom fields: Account, Contact, Opportunity, `OpportunityContactRole`, Activity
(Task/Event).

- **Contact** is the central hub, linked to Opportunity via the standard **OpportunityContactRole**
  junction, and to `LDGCRM_Application__c` via `LDGCRM_Application_Contact__c` (junction).
- **Opportunity** has an Owner (User) and an Account reference; parents related Activities
  (Task/Event, labeled "Meeting") and Impediments.
- **`LDGCRM_Application__c`** is a Master-Detail child of **`LDGCRM_Partner_Account__c`**, and carries
  a "Partner Portal Admin" flag on its `LDGCRM_Application_Contact__c` junction rows.
  `LDGCRM_Partner_Account__c` also relates to Opportunity.
- **Account** has an Owner (User), a parent Account lookup, and a lookup to `LDGCRM_Market_Segment__c`.
- **`LDGCRM_Impediment__c`** relates to Opportunity via **`LDGCRM_Opportunity_Impediment__c`** (junction).
- **Activity** (Task/Event) references both an Account and an Opportunity.

Nine record-triggered **Flows** (`force-app/main/default/flows/`) implement the automation layer:
duplicate-record checks on the two junction objects, Market Segment assignment on Application/Opportunity
save, Partner Account re-parent cascades, and status/blocked-revenue rollups. Sharing is managed via
explicit **SharingRules** (owner + criteria based) on Account, Contact, Opportunity, and the three
`LDGCRM_` objects with org-wide-default-restricted sharing, plus three **PermissionSets**
(`LDGCRM_Partnership_Team_Member_CRE`, `LDGCRM_Partnership_Viewer_R`, `LDGCRM_Production_Support_CRED`)
grouped into matching **PermissionSetGroups** and assigned via the **Group**s `LDGCRM_Team_Members` /
`LDGCRM_Viewers`.

Prefer reading `force-app/main/default/objects/` for field-level detail; use
`scripts/metadata/Get-LDGCRMDataDictionary.ps1` when you want it flattened to CSV instead of XML.

## Scripts

All scripts are PowerShell, **requiring pwsh 7+** (cross-platform: Windows/macOS/Linux). Never
reintroduce Windows-only path syntax (hardcoded backslashes, `$env:`-only assumptions, etc.) into
shared script code — use `Join-Path`/`Split-Path` as the existing scripts do.

Every script dot-sources `scripts/common/Common.ps1` and uses its helpers rather than writing output
next to the script or inventing new log locations:
- `Get-RepoRoot` — resolves the repo root from the script's own location.
- `Get-LogDirectory -Category <metadata|cleanup|data-migration>` — ensures/returns the matching
  `logs/<category>/` folder.
- `Start-ScriptLog -Category ... -ScriptName ...` — opens a transcript in that folder and returns a
  shared timestamp for the run's other output files (CSVs, summaries). Pair with `Stop-ScriptLog` in
  a `finally` block so the transcript closes even on early `exit`.

Current scripts:
- `scripts/metadata/Get-LDGCRMDataDictionary.ps1` — exports a full object/field data dictionary CSV
  via `sf sobject describe`; discovers custom objects by Salesforce label under the `LDGCRM_` prefix.
- `scripts/metadata/Sync-Metadata.ps1` — runs `sf project retrieve start` against
  `sfdx/manifest/package.xml`; extend the manifest as the app grows rather than hardcoding new types
  into scripts.
- `scripts/cleanup/cleanup-gsa-peo.ps1` — **interactive and destructive**: hard-deletes sandbox
  records by object (only rows where `LDGCRM_External_ID__c` is populated), after a typed
  `HARD DELETE` confirmation. Exports the record IDs it deletes first for an audit trail. Treat with
  the same caution as any prod-affecting script even though it targets a sandbox.
- `scripts/data-migration/` — placeholder; not built yet. Upcoming Data Loader-based scripts
  (Airtable export -> Salesforce load) belong here and should follow the same `Common.ps1`
  logging/PII conventions as the rest of `scripts/`.

## sfdx/ commands

Run from inside `sfdx/`:
- `sf project retrieve start -x manifest/package.xml --target-org gsa-peo` — pull metadata (or use
  `scripts/metadata/Sync-Metadata.ps1` from the repo root, which wraps this with logging).
- `npm run lint` — ESLint over `aura`/`lwc` JS.
- `npm test` / `npm run test:unit` — `sfdx-lwc-jest`; `test:unit:watch` and `test:unit:coverage` variants
  exist. To run a single test file: `npx sfdx-lwc-jest path/to/file.test.js`.
- `npm run prettier` / `npm run prettier:verify` — formats `.cls,.cmp,.component,.css,.html,.js,.json,.md,.page,.trigger,.xml,.yaml,.yml`.
- Husky's `pre-commit` hook runs `lint-staged` (Prettier on all matched files, ESLint on `aura`/`lwc`
  JS, `sfdx-lwc-jest --bail --findRelatedTests --passWithNoTests` on `lwc` changes).

## Operational gotchas

- **`sf project retrieve start` requires running from inside `sfdx/`** (or passing paths relative to
  it) — it needs `sfdx-project.json` in the working directory. Running it from the repo root fails
  with `InvalidProjectWorkspaceError`.
- **Retrieving a Salesforce Outbound Change Set's contents:** Change Sets have no direct Metadata/
  Tooling API or `sf` support for listing/querying them, but a change set's **Name** (not its Setup
  URL ID) works as an unmanaged package name for retrieval: `sf project retrieve start --package-name
  "<Change Set Name>" --target-org gsa-peo`. This is how `force-app/` was synced from `LDGCRM_Sprint_1_12`.
  It retrieves into a new folder named after the package (not into `force-app/`) — merge it in and
  regenerate/hand-check `manifest/package.xml` afterward rather than leaving a second package directory.
- **Broad wildcard retrieves (e.g. `CustomApplication:*`) pull the entire org**, not just this app —
  every standard Salesforce app and every unrelated custom app comes down too. Prefer the manifest or
  a change-set/package-name retrieve; if you do run a wildcard retrieve, review `git status
  sfdx/force-app` before committing and discard anything outside this app's scope
  (`git clean -fd -- sfdx/force-app` for untracked noise, since nothing here should ever be force-pushed
  over tracked content without review).
- **Long paths on this machine:** the local disk mount used by this Windows environment adds a long
  internal prefix to every path, so retrieved Salesforce metadata (deeply nested object/field files,
  verbose flow/layout names) can exceed the Windows 260-character path limit. If `git` operations on
  `sfdx/force-app` fail with `Filename too long`, run `git config core.longpaths true` (already set in
  this repo's local git config) and retry; for non-git file deletion, use `robocopy <empty-dir> <target>
  /MIR` rather than `Remove-Item -Recurse`, which does not reliably handle the same long paths.

## Skills

Project-specific skills live in `.claude/skills/` and load automatically when relevant:
- `sfdx-metadata-sync` — retrieving/deploying metadata, extending `sfdx/manifest/package.xml`.
- `sfdx-sandbox-ops` — safety checklist for any destructive or bulk operation against `gsa-peo`
  (confirm org, preflight counts, export-before-write, never bypass the typed confirmation gate).
- `sfdx-data-migration` — conventions for the (not yet built) `scripts/data-migration/` Data Loader
  scripts: where source/mapping files live, upsert-on-external-ID, load ordering, dry-run-first.
