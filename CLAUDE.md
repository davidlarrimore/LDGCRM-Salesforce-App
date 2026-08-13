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
- **`LDGCRM_Application__c`** has a required **Lookup** (not Master-Detail) to
  **`LDGCRM_Partner_Account__c`** (`LDGCRM_Partner_Account__c` field), and carries a "Partner Portal
  Admin" flag on its `LDGCRM_Application_Contact__c` junction rows. It also has an optional Lookup to
  Opportunity (filtered to the `Login_gov` record type).
- **`LDGCRM_Partner_Account__c`** is the true Master-Detail child of **Account** (via `LDGCRM_Account__c`,
  filtered to the `Federal` Account record type) and relates to Opportunity indirectly through
  `LDGCRM_Application__c`.
- **Account** has an Owner (User), a parent Account lookup, and a lookup to `LDGCRM_Market_Segment__c`.
- **`LDGCRM_Opportunity_Impediment__c`** is a true junction with **two Master-Detail relationships** —
  to `LDGCRM_Impediment__c` and to Opportunity — so both parents must exist before a junction row can
  be created (and both parent rows are deleted if either side deletes them). `LDGCRM_Application_Contact__c`,
  by contrast, links `LDGCRM_Application__c` and Contact via two plain **Lookups**, not Master-Detail —
  that's why it needs the duplicate-record-check Flow mentioned below (Master-Detail junctions don't).
- **Activity** (Task/Event) reaches both an Account and an Opportunity through the single polymorphic
  `WhatId` field — there's no separate custom Account lookup. A meeting tied to a specific Opportunity
  gets `WhatId` = that Opportunity (its Account is reachable via `Opportunity.AccountId`); a meeting
  tied only to an Account (no Opportunity) gets `WhatId` = that Account directly.

Nine record-triggered **Flows** (`force-app/main/default/flows/`) implement the automation layer:
duplicate-record checks on the two junction objects, Partner Account re-parent cascades, and
status/blocked-revenue rollups. Three before-save Flows assign `LDGCRM_Market_Segment__c`
automatically from the related Account, cascading down the hierarchy — **data-migration load scripts
must never set this field themselves on these three objects**, only rely on the Flow:
`LDGCRM_Partner_Account_Before_Save_Create_Update_Market_Segment` (from
`LDGCRM_Account__r.LDGCRM_Market_Segment__r`), `LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment`
(from `Account.LDGCRM_Market_Segment__r`), and `LDGCRM_Application_Before_Save_Assign_Market_Segment`
(from `LDGCRM_Partner_Account__r.LDGCRM_Account__r.LDGCRM_Market_Segment__r`) — Account itself has no
such Flow and is the one object in this chain whose Market Segment the migration sets directly (see
`Build-AccountReconciliation.ps1`). Sharing is managed via
explicit **SharingRules** (owner + criteria based) on Account, Contact, Opportunity, and the three
`LDGCRM_` objects with org-wide-default-restricted sharing, plus three **PermissionSets**
(`LDGCRM_Partnership_Team_Member_CRE`, `LDGCRM_Partnership_Viewer_R`, `LDGCRM_Production_Support_CRED`)
grouped into matching **PermissionSetGroups** and assigned via the **Group**s `LDGCRM_Team_Members` /
`LDGCRM_Viewers`.

Prefer reading `force-app/main/default/objects/` for field-level detail; use
`scripts/metadata/Get-LDGCRMDataDictionary.ps1` when you want it flattened to CSV instead of XML.

## Airtable API

`scripts/data-migration/Get-AirtableExport.ps1` pulls current Airtable data straight from the REST API
into `data/airtable-exports/<Table>.json` (one file per table, overwritten each run — see "Scripts"
below). This replaced an earlier manual CSV/XLSX export-zip workflow; don't recreate that structure —
the JSON pull is the only source of truth for Airtable data in this repo now.

**Authentication:** a Personal Access Token (PAT), not the old-style API key — Airtable removed
`key...` API keys in Feb 2024, so a token must start with `pat...`. Create/manage one in the Airtable
Builder hub (profile avatar → Builder hub → Personal access tokens); it needs the **`data.records:read`**
scope at minimum, **`schema.bases:read`** too if you need to look up table IDs/names (see below), and
must be explicitly granted access to this base (PATs are scoped per-base/workspace, not account-wide).
Send it as `Authorization: Bearer <token>`. Locally it lives in the gitignored repo-root `.env` as
`AIRTABLE_API_KEY` (named after the deprecated concept, but the value is a PAT) alongside
`AIRTABLE_BASE_ID` (the `app...` string from the base's API docs page or its browser URL) — copy
`.env.example` to start. `scripts/common/Common.ps1`'s `Import-DotEnv` loads `.env` into the process
environment; nothing else in this repo reads it.

**REST API shape:**
- Base URL: `https://api.airtable.com/v0/{baseId}/{tableIdOrName}` — table names work but **table IDs
  are preferred and are what this repo's script uses**, because table *names* are user-editable in
  Airtable and a rename silently 403s a name-based request (this actually happened here: the "Partner
  Accounts" table was renamed to "Partners" in Airtable, breaking a name-keyed pull — Airtable returns
  403 uniformly for "no permission" and "table doesn't exist/isn't visible", so a rename looks
  identical to an auth failure until you check). `Get-AirtableExport.ps1`'s `$DefaultTables` hardcodes
  the current table-ID mapping (captured 2026-08-12) as the single source of truth — update it there,
  not here, if a table is renamed/added/removed.
- Discover table names/IDs via the metadata endpoint: `GET /v0/meta/bases/{baseId}/tables` (needs the
  `schema.bases:read` scope — separate from `data.records:read`, so a 403 here doesn't mean the record
  endpoints are broken too).
- **Pagination:** one page at a time, 100 records max per page (`pageSize` param). Pass the previous
  response's `offset` value back as a query param to get the next page; no `offset` in the response
  means you're done.
- **Rate limit:** 5 requests/sec per base; exceeding it returns `429`. `Get-AirtableExport.ps1` paces
  requests ~250ms apart and retries on `429` with a 30s backoff.
- **Record shape:** each record is `{ id: "rec...", createdTime, fields: { ... } }`. Linked-record
  fields come back as real JSON arrays of `rec...` IDs — not the comma-joined strings a CSV export
  would give — which is the main advantage of pulling via the API over the old manual export.

## Airtable → Salesforce mapping

**External ID convention:** every Airtable table has a record ID column (`rec...`, e.g. `recqKg0hKPxCCH4M1`
on `Accounts Record ID`) that is the upsert key for `LDGCRM_External_ID__c` on the matching Salesforce
object — one Airtable base row becomes one Salesforce record carrying that ID. Two exceptions to hold
onto:
- **`LDGCRM_Market_Segment__c` currently stores the segment *name*** (`"Benefits"`, `"Defense"`, …) in
  `LDGCRM_External_ID__c`, not the Airtable `rec...` ID from the Market Segments table's `Unique ID`
  column. There are only 5 real segments plus a `Test Market Segment` row, all already loaded — decide
  once (backfill to the `rec...` ID for consistency, or keep matching by name since the segment list is
  small and stable) rather than let a load script silently create duplicates by upserting on the wrong
  value.
- **`OpportunityContactRole.LDGCRM_External_ID__c` has `externalId=false`** in its field metadata (every
  other object's copy is `externalId=true`). A Bulk API `upsert --external-id` call needs that flag set,
  so this field needs a metadata fix (`sfdx-metadata-sync`) before the Opportunity Contacts pull can be
  loaded idempotently.
- On every object, `LDGCRM_External_ID__c` is `externalId=true` but **`unique=false` and `required=false`**
  — Salesforce will not reject a duplicate value at the database level. A load script upserting on this
  field is safe (Bulk API upsert still matches correctly), but anything that inserts instead of upserts,
  or edits the field by hand, can silently create duplicates. Consider flipping `unique` to `true` on the
  objects driven entirely by this migration (not on Account, see below) as a guardrail.

See `scripts/data-migration/TRANSFORMATION-RULES.md` for the full field-by-field mapping rules and
every gotcha discovered per object (Account's Type/Market Segment logic, Impediment's Category
value map, etc.) — this section is the short cross-object summary.

**Airtable table → Salesforce object**, with the linking columns that matter for load order:

| Airtable table | Salesforce object | Airtable link columns → Salesforce lookup |
| --- | --- | --- |
| Accounts | Account (`Federal` record type) | *(already migrated — see below)*; also `States + DC/PR` (checkbox) → `Type` (`"State"` if checked, else `"Federal"` — confirmed against gsa-peo's existing data, not just Airtable's field name; see below) |
| Partner Accounts | `LDGCRM_Partner_Account__c` | `Account Record ID` → `LDGCRM_Account__c` (Master-Detail, requires Account loaded first); `Name`/`LDGCRM_Agreement_Short_Name__c` ← `Agreement Short Name` (no dedicated Name column exists) |
| Applications | `LDGCRM_application__c` (`LDGCRM_Application` record type) | `Partner Account Record ID (from Partner Agreement)` → `LDGCRM_Partner_Account__c`; `Opportunity Record ID` → `LDGCRM_Opportunity__c` |
| Contacts | Contact (`Federal` record type) | no direct Account/Application lookup on Contact itself — relationships go through the junctions below |
| Applications × Contacts (embedded in Contacts/Applications exports) | `LDGCRM_Application_Contact__c` | needs both the Application's and the Contact's `rec...` IDs; splits Airtable's comma-joined multi-value cells into one junction row per pair |
| Opportunities | Opportunity (`Login_gov` record type) | `Account Record ID` → `AccountId` |
| Opportunity Contacts | `OpportunityContactRole` | `Opportunity Record ID` + Contact `rec...` ID; `Contact Type` → `Role`, `Primary` → `IsPrimary` (blocked on the `externalId` fix above) |
| Impediments | `LDGCRM_Impediment__c` | — ; `Category` needs an explicit value map, not passthrough — see below |
| Impediments × Opportunities (`Opportunities blocked` / `Opportunities requested` columns) | `LDGCRM_Opportunity_Impediment__c` | one junction row per Opportunity in each list; `Opportunities blocked` → `LDGCRM_Severity__c = "Blocker"`, `Opportunities requested` → `"Impediment"` |
| Market Segments | `LDGCRM_Market_Segment__c` | *(already migrated — see above)* |
| Meetings | Activity, as an **Event** (`LDGCRM_Meeting_Type__c` from `Meeting Type`) | `Opportunity Record ID` if present, else `Accounts Record ID`, → `WhatId` |

Meetings only carry a single `Date` column (no start/end time) — loading them as Event means
synthesizing `StartDateTime`/`EndDateTime` (e.g. a fixed default duration off that date), since
Airtable has no time-of-day to carry over.

**Not every Airtable column is a simple same-name mapping.** `States + DC/PR` looks like it might
hold a state name but is actually a plain checkbox distinguishing state/DC/territory government
Accounts from federal ones — it maps to the standard `Type` field, not a new custom field, and its
value isn't "true"/"false", it's `"State"` vs `"Federal"`. This was confirmed empirically against
gsa-peo's existing Accounts (54 already `Type="State"`, 530 already `Type="Federal"` — note
`"Federal"`, not the `Type` picklist's defined `"Federal Agency"` value, which only 3 records use;
the field isn't restricted) before being encoded in `Build-AccountReconciliation.ps1`, rather than
assumed from the Airtable column name. Treat every table in the mapping above the same way —
check what a column *actually* contains and how existing Salesforce data already uses the target
field before writing a transform, don't assume the Airtable column name describes its content or
that Salesforce's picklist metadata reflects what's actually stored. Same lesson on Impediments:
Airtable's free-text `Category` column (`"Issue on their end"`, `"Relationship Issue"`, `"Product /
Feature request"`) doesn't match `LDGCRM_Category__c`'s restricted 3-value picklist verbatim
(`"Issue on partner end"`, `"Relationship issue"`) — a restricted picklist rejects anything outside
its defined values, so `Build-ImpedimentLoad.ps1` maps them explicitly. Also don't assume every
Airtable column has a Salesforce field to land in — Impediments' `Blocked revenue`/`Requested
revenue`/`Blocked Annual IdV users`/count columns are Airtable-side rollups with no equivalent
field (and `LDGCRM_Blocked_Revenue__c` is itself a roll-up Summary field computed from
`LDGCRM_Opportunity_Impediment__c` — Salesforce rejects direct writes to it), so none of those are
migrated.

**Not every "no destination" Airtable column is actually excluded forever, though.** Freeform/
journal-style columns with nowhere to land (e.g. Partner Accounts' `Account Description`, `Known
Blockers`) become `ContentNote` records (Enhanced Notes — confirmed enabled in gsa-peo, not the
legacy `Note` object) attached to their parent record, in a dedicated **Notes chunk that has to be
built last**, after every other object's records exist. This is forward-only — it does not apply to
columns already migrated as dedicated fields (Partner Account's `Current Status Summary`,
Impediment's `Description`/`Talking Point` stay exactly as built). See
`scripts/data-migration/TRANSFORMATION-RULES.md`'s "Notes" section for the full mechanism, current
candidate-field list, and open questions (e.g. Partner Accounts' `Escalated User Support Cases`
appears to reference an Airtable table this migration doesn't currently pull at all).

**Current sandbox state (checked 2026-08-12, re-verified same day via
`Build-AccountReconciliation.ps1`):** Account and Market Segment are effectively **pre-migrated** —
588 Accounts now exist (all `Federal` record type; this count moved from an earlier same-day
reading of 531, so treat it as a moving target, not a fixed baseline), 585 now carry a `rec...`
`LDGCRM_External_ID__c` after the Account reconciliation backfill load, and all 6 Market Segments
exist. **Impediment (40 records) and Partner Account (76 records) are now loaded** via
`Build-ImpedimentLoad.ps1`/`Build-PartnerAccountLoad.ps1` + `Invoke-SalesforceLoad.ps1` — see
`scripts/data-migration/TRANSFORMATION-RULES.md` for what each load surfaced. Every other object is
still essentially empty (2 Opportunities, 3 Contacts, 4 Applications, 0 Tasks/Events/
OpportunityContactRoles) — a handful of obvious test/sample rows (`Test Account`, `HHS - Test`,
`Test Partner Account`, `Test Market Segment`, …). Airtable has 757 Account rows against those 588
Salesforce Accounts, so **don't assume 1:1** — reconcile by external ID first, then by name, and treat
any Airtable Account row that doesn't match an existing Salesforce Account as an exception for human
review rather than auto-creating a new Account (this is also why Account's `LDGCRM_External_ID__c`
should stay `unique=false`/non-enforced for now, rather than being tightened like the other objects —
a premature uniqueness constraint would block the reconciliation pass on the currently-172 untagged
rows, one of which, `Depart of Homeland Security`, looks like a typo'd duplicate of an existing tagged
Account and needs a human decision, not a script, to resolve). `Build-AccountReconciliation.ps1`
(`scripts/data-migration/`) automates this reconciliation — external ID, Market Segment, and Type
backfill — read-only against Salesforce, writing an update CSV plus human-review CSVs for anything
it can't confidently match; see `scripts/data-migration/README.md` for the full pipeline.

**Load order** (parents before children/junctions — the reverse of the delete order in
`scripts/cleanup/cleanup-gsa-peo.ps1`): Market Segment → Account → `LDGCRM_Partner_Account__c` →
Contact → Opportunity → `LDGCRM_application__c` → `LDGCRM_Opportunity_Impediment__c` (needs
`LDGCRM_Impediment__c` and Opportunity first) → `LDGCRM_Application_Contact__c` →
`OpportunityContactRole` → Activity (Meetings, needs Account/Opportunity first).

## Scripts

All scripts are PowerShell, **targeting Windows PowerShell 5.1+** (this repo's dev machines don't have
PowerShell 7/`pwsh` installed, and installing it is blocked by Group Policy on at least one of them —
so `#Requires -Version 5.1` at the top of every script, not 7.0). Avoid syntax that only exists in
PowerShell 6+ (`??`, `?.`, ternary `?:`, `ConvertFrom-Json -AsHashtable`, `ForEach-Object -Parallel`,
multi-argument `Join-Path`) — stick to `Join-Path`/`Split-Path` with the classic two-argument form, as
the existing scripts do. Scripts still run fine under `pwsh` 7+ if a machine happens to have it; they
just don't require it.

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
- `scripts/metadata/Sync-Metadata.ps1` — before retrieving, scans the sandbox for components whose
  name matches `LDGCRM_`/`LGDCRM_` but aren't yet in `sfdx/manifest/package.xml`, adds them
  automatically, and reports anything new that *doesn't* match the naming convention for manual
  review instead of guessing (this sandbox hosts unrelated apps like FCIC that share the same
  metadata types — see `scripts/metadata/ldgcrm-manifest-ignore.json` for confirmed non-LDGCRM
  components that should stop resurfacing in that report). Then runs `sf project retrieve start`
  against the manifest. `-WhatIf` reports only; `-SkipDiscovery` retrieves the manifest as-is.
- `scripts/cleanup/cleanup-gsa-peo.ps1` — **interactive and destructive**: hard-deletes sandbox
  records by object (only rows where `LDGCRM_External_ID__c` is populated), after a typed
  `HARD DELETE` confirmation. Exports the record IDs it deletes first for an audit trail. Treat with
  the same caution as any prod-affecting script even though it targets a sandbox.
- `scripts/data-migration/Get-AirtableExport.ps1` — pulls current data directly from the Airtable REST
  API (one JSON file per table, paginated via `offset`) into `data/airtable-exports/<Table>.json`,
  **overwriting** the previous pull each run (a timestamped transcript + `pull-summary-<timestamp>.csv`
  still land in `logs/data-migration/` via `Common.ps1`, so run history isn't lost, just the data
  itself isn't duplicated per run). See "Airtable API" above for auth/connection details. `-Tables`
  limits the pull to a subset; defaults to all nine tables in the "Airtable table → Salesforce object"
  mapping above.
- `scripts/data-migration/` is otherwise still a placeholder for the upsert/load scripts (Airtable ->
  Salesforce) — not built yet. Those should follow the same `Common.ps1` logging/PII conventions as
  the rest of `scripts/`.

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

- **Any `sf project deploy validate` (or a `deploy start` that runs tests) currently fails org-wide**
  due to a pre-existing Apex compile error unrelated to this app: `GSA_FCIC_AC_Manual_InitialBatch`
  (part of the unrelated FCIC app that shares this sandbox — see the wildcard-retrieve warning below)
  has a genuine compile error (`line 23: Variable does not exist: metadata`). Salesforce compiles
  *all* Apex in the org as a prerequisite for running any tests, so this one broken class cascades
  into "Dependent class is invalid and needs recompilation" errors and test failures across the
  entire org, regardless of what you're actually deploying — discovered 2026-08-12 while deploying
  an unrelated two-field metadata change (see `scripts/data-migration/TRANSFORMATION-RULES.md`'s
  Impediment section). **Workaround for metadata-only changes with no Apex/trigger component**, on
  this sandbox (not production): `sf project deploy start --test-level NoTestRun --target-org
  gsa-peo` skips test execution entirely, sidestepping the recompilation cascade. This does *not*
  fix the underlying problem — a deploy that actually includes Apex, or that must run tests for any
  other reason, is still blocked until someone who owns the FCIC app fixes
  `GSA_FCIC_AC_Manual_InitialBatch`.
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
