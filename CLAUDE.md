# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

This repo builds the Salesforce CRM app that the **Login.gov Airtable -> Salesforce CRM Migration
Project** is migrating data into. There are two kinds of work here: maintaining the Salesforce app's
metadata (`sfdx/`), and PowerShell automation for pulling metadata/data out of an org and loading
migrated data into it (`scripts/`).

Records created by the migration carry an external ID field, `LDGCRM_External_ID__c`, used to
correlate Salesforce records back to their Airtable source.

## Environments (read this before running anything)

**This is no longer a single-org setup.** Every script takes `-Environment Dev|QA|Full|Prod`
(default `Dev`) and resolves the alias from the registry in `scripts/powershell-scripts/Common.Orgs.ps1`, which
`Common.ps1` dot-sources so every script gets it. **Never hard-code an org alias in a script again.**

The registry now carries **`InstanceUrl` and `LightningUrl` for every environment** (added
2026-08-14) — the browser URL is printed in the pre-run banner so an operator can confirm by eye
which org they are about to touch. It also carries **`AllowsAccountRebuild`**, see below.

| `-Environment` | Alias | Sandbox | Instance URL | Browser URL | Accounts | Purpose |
| --- | --- | --- | --- | --- | --- | --- |
| `Dev` (default) | `peodv8dvn` | PEOdV8DVn | `https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com` | `https://gsa-peo--peodv8dvn.sandbox.lightning.force.com` | rebuilt | Development and pipeline testing. Everything documented below was done here. |
| `QA` | `peodv15dvn` | PEOdV15DVn | `https://gsa-peo--peodv15dvn.sandbox.my.salesforce.com` | `https://gsa-peo--peodv15dvn.sandbox.lightning.force.com` | rebuilt | Full end-to-end migration rehearsal |
| `Full` | `peofl2stgp` | PEOfL2STGp | `https://gsa-peo--peofl2stgp.sandbox.my.salesforce.com` | `https://gsa-peo--peofl2stgp.sandbox.lightning.force.com` | **real** | Operations team integration testing: scripts + change sets, immediately before production |
| `Prod` | `gsa-peo` | — | `https://gsa-peo.my.salesforce.com` | `https://gsa-peo.lightning.force.com` | **real** | Live GSA PEO org *(not authorized here)* |

**An alias is the org's own sandbox name**, so it can be checked against the instance URL and cannot
silently drift. `Assert-LdgcrmOrgTarget` runs at the start of every script and refuses to continue
if the alias resolves to an org that disagrees with the registry — including sandbox-vs-production,
which it reads from `Organization.IsSandbox` (`sf org display` doesn't report it, and `sf org list`
reads a local cache, which is the thing being verified). **Production is now identity-checked too**
(2026-08-14): it has no sandbox name, so until the registry recorded its URL it was the one
environment verified only as "is not a sandbox". `Assert-LdgcrmOrgTarget` now compares the **My
Domain label** — the first host segment, stable across `my.salesforce.com` / `lightning.force.com` /
`file.force.com` — so an org on a different domain stops the run.

### ⚠️ Accounts are rebuilt in Dev/QA ONLY — never in Full or Prod

Decided 2026-08-14. `Test-LdgcrmAccountRebuildAllowed` (`Common.Orgs.ps1`) is the **single
definition**, and three scripts consume it rather than each testing `-Environment` themselves:
`Invoke-SandboxFactoryReset.ps1` filters `Account` out of its delete list (loudly — a silent
removal would let an operator conclude the Accounts *were* reset), `Invoke-AccountBootstrap.ps1`
refuses to start, and `Invoke-FullMigrationLoad.ps1` rejects `-BootstrapAccounts`.

The reason is the same for both blocked environments: **a Full sandbox is a copy of production**, so
its Accounts *are* the real records this migration reconciles onto. Deleting them would destroy the
thing being tested and replace it with a stale export — a rehearsal passing against data that no
longer resembles production is worse than no rehearsal. Every *other* object still resets normally
in a Full sandbox; they carry `LDGCRM_External_ID__c` because this migration created them.

`Invoke-AccountBootstrap.ps1`'s `-Environment` ValidateSet is now **`Dev|QA`** — Full and Prod are
rejected at parameter-bind time, the same structural block the factory reset uses against
production. Its `-ProductionConfirmation` parameter was removed: a flag whose only purpose is to
approve something the script can no longer do reads as though a production path exists.

Writes/deletes against `Prod` need the org alias typed at an extra guard
(`Assert-LdgcrmProductionConsent`) on top of the script's own confirmation. See `docs/engineering/ARCHITECTURE.md`,
"Environments and org aliases", for the authorization runbook for a new sandbox.

**QA (`peodv15dvn`) is authorized on this machine as of 2026-08-13** (`dave.larrimore@gsa.gov.peo.peodv15dvn`),
so `-Environment QA` works. It can trail Dev by a change set — **never assume Dev's metadata state
applies to QA**; verify against the org you are actually loading. Confirmed example: `priority_type__c`
exists in Dev and **does not exist in QA at all**.

**Full (`peofl2stgp`, sandbox `PEOfL2STGp`) is PROVISIONED and in the registry, but is NOT authorized
on this machine** — only Dev and QA are. Those are different claims and the registry says which org
Full *is*, not whether you can currently reach it: `Assert-LdgcrmOrgTarget` fails with "could not
reach org alias", which is the correct outcome. Authorize with
`sf org login web --alias peofl2stgp --instance-url https://gsa-peo--peofl2stgp.sandbox.my.salesforce.com`.
**Anything saying Full is "not provisioned" is stale** — that was true until 2026-08-14.

**QA was fully loaded on 2026-08-14: 8,740 records, 0 unexpected failures**, using the same two
commands as Dev (factory reset, then `Invoke-FullMigrationLoad.ps1 -BootstrapAccounts`). Every object
matched Dev except three explainable differences: Account 587 vs 584 (different pre-existing
population), Contact 1,871 vs 1,870 (**the org duplicate rule fires on 10 rows here, 11 in Dev** —
the only behavioural difference found between the orgs), and 2 extra junction rows following from
that extra Contact. **Counts in this file are Dev's unless it says otherwise.**

**⚠️ THAT QA LOAD WAS NOT ACTUALLY CLEAN, and the counts above are exactly why it looked like it
was.** Discovered 2026-08-14: **all nine LDGCRM Flows were inactive in QA for the whole run.** Every
figure in the paragraph above is still accurate — that is the point. Rows loaded, nothing failed,
nothing was withheld, and the object counts matched Dev, because flow activation changes field
*contents*, not row counts. Market Segment came out blank on all 92 Partner Accounts, all 842
Opportunities and all 1,026 Applications. **Do not cite that run as a successful rehearsal.** The
flows were activated on 2026-08-14 (9 of 9 now active), but activating them does **not** backfill the
existing records — all three Market Segment flows fire on create or on parent change, and the
pipeline upserts, so a re-run is an update that will not re-trigger them. **QA needs a factory reset
and a full reload before it is a valid rehearsal again.**

## ⚠️ Metadata promotion is by CHANGE SET only

**Do not promote metadata between orgs with `sf project deploy`.** Outbound/inbound change sets are
the only sanctioned path, and the rule is strict (user, 2026-08-13). From this repo, a CLI deploy is
permitted for exactly one purpose: **DELETING corrupted or incorrect metadata.** Anything additive —
a new field, a new picklist value, a new record-type assignment — goes in a change set, even when the
change is obviously correct and even when it is only going to a sandbox.

Practical consequences when a load is blocked by missing metadata: **write down what needs adding and
hand it to whoever builds the change set.** Do not "just deploy it to Dev to unblock testing" — Dev is
the source org for change sets, so anything deployed there silently becomes part of the next
promotion whether or not it was reviewed.

Two `sf` behaviours to know before touching picklists:
- **A metadata deploy cannot delete a picklist value — it deactivates it** (`isActive=false`). The
  value survives in the value set. Only a Setup "Del" removes it. `sf sobject describe` **hides
  inactive values**, so it will report the field as clean; the retrieved metadata file is the
  authority.
- **Renaming a value via `<fullName>` does not rename in place** — it adds the new value and
  deactivates the old one. Check usage first
  (`SELECT <field>, COUNT(Id) FROM <Object> GROUP BY <field>`); a rename is only safe at zero.

See [README.md](README.md) for human-facing setup/quick-start steps (auth, prerequisites, common
commands). This file focuses on conventions and architecture for working in the code.

## Repository layout

- `scripts/` — **THE OPERATIONS BUNDLE.** PowerShell automation, organized by purpose (`cleanup/`,
  `powershell-scripts/`, `common/`), plus `docs/`, `data/`, `logs/`, `.env` and its own `.gitignore`.
  Self-contained — see the next section. This is what ships. See "Scripts" below.
- `sfdx/` — the Salesforce DX project (`sf` CLI). `force-app/main/default/` holds retrieved metadata,
  synced from an authoritative Salesforce Outbound Change Set (`LDGCRM_Sprint_1_12`) rather than
  hand-picked components. `manifest/package.xml` mirrors that scope for repeat syncs via
  `sf project retrieve start -x manifest/package.xml`.
- `tools/` — **engineering-only**, added 2026-08-14. Scripts that read `sfdx/` or `docs/` and
  therefore cannot live in the bundle: `metadata/` (Sync-Metadata, Get-LDGCRMDataDictionary,
  Find-UnexposedLDGCRMFields), `Export-ReportPdf.ps1`, the superseded `Build-ProdAccountSeed.ps1`,
  `Export-OpsBundle.ps1` and `Test-BundleStructure.ps1`. They dot-source `tools/Common.Tools.ps1`
  (which defines `Get-RepoRoot` and `Start-ToolLog`) *and* the bundle's `Common.ps1` for the
  confirmation gate and Salesforce helpers.
- `logs/` — **gitignored**. Run output from `tools/` only, in `logs/tools/<Script>-<ts>/`.
  Separate from the pipeline's `scripts/logs/` on purpose — see the next section.
- `dist/` — **gitignored**. Where `Export-OpsBundle.ps1` writes the hand-off zip.
- `scripts/logs/`, `scripts/data/` — **gitignored** (except `.gitkeep`/`README.md`), by
  `scripts/.gitignore`, not the root one.

## ⚠️ METADATA IS NOT THE OPERATIONS TEAM'S JOB — nor is its output

Standing rule, user-stated 2026-08-14. **The metadata scripts exist to build the app and diagnose
problems. They are a development aid.** Operations never retrieves or deploys metadata, and this
project is **not responsible for pushing or pulling it** on anyone's behalf — metadata moves between
orgs by change set only.

So **none of it ships**: not the scripts (`tools/metadata/`), not their logs (`logs/tools/`, outside
the bundle), not their CSV output. The bundle's `Get-LogDirectory` no longer even accepts a
`metadata` category — it is `cleanup|data-migration` only, and `scripts/logs/metadata/` was removed.
Shipping the tooling would invite exactly what the change-set policy forbids; shipping the *output*
would imply the pipeline owns a metadata state it does not.

**What IS in scope for the bundle** — the distinction that matters, because it is easy to over-read
the rule and strip out things the pipeline legitimately needs:

| | |
| --- | --- |
| ✅ **READ the org to check what a load needs exists** | a field, a picklist value, a record-type assignment, whether an external ID is still `unique`. The pipeline already does this — `Build-ApplicationLoad.ps1` reads live field definitions before deciding whether to send two columns. **A consolidated pre-flight check belongs in the bundle**, and is wanted. |
| ✅ **TOGGLE a documented switch a load needs, then put it back** | `Invoke-SalesforceLoad.ps1`'s `TriggerControls__c` bypass is the model: capture, flip, restore in a `finally`, verify the restore. |
| ✅ **ROUND-TRIP a component to flip its STATUS, where no record-level API exists** | Added 2026-08-15 for the Contact duplicate/matching rules. `Disable-LdgcrmContactDuplicateRules` retrieves the rule **from the target org**, changes one element (`isActive` / `ruleStatus`), and deploys it **straight back to the same org**. No XML moves between orgs, no component is created, no definition changes. This is the `-ActivateFlows` category — a setting flip — and it is only a metadata deploy because Salesforce exposes no other write path (`DuplicateRule` isn't a Tooling object and its `IsActive` is `updateable=false`; `MatchingRule` has no `Metadata` field). **The test is round-trip-to-same-org and status-only.** |
| ❌ **DEPLOY metadata FROM this repo, or RETRIEVE INTO it, to change what a component IS** | Adding a field, editing a definition, promoting anything between orgs. If a load is blocked by missing metadata, the pipeline's job is to say so precisely and stop. Someone else builds the change set. |

## ⚠️ `scripts/` is a SELF-CONTAINED BUNDLE — never resolve a path above its root

Changed 2026-08-14. The GSA Salesforce Operations team runs this pipeline from **their own GitHub
repo**, where it lands as a plain `/scripts` folder. So `data/`, `logs/`, `.env`, `.env.example` and
the operator docs all moved *inside* `scripts/`, and everything resolves off **`Get-LdgcrmRoot`**
(`scripts/powershell-scripts/Common.ps1`), which returns the bundle folder itself.

**`Get-RepoRoot` was DELETED from the bundle**, not just unused. Left in place it would have kept
resolving happily after the folder moved and quietly returned *Operations'* repo root — paths would
still join, files would still be written, just into someone else's tree. A missing function fails on
first call instead. It now lives only in `tools/Common.Tools.ps1`.

The practical rule when adding a script: **if it needs `sfdx/` or `docs/`, it belongs in `tools/`.
If it reads Airtable or writes to Salesforce, it belongs in the bundle and must use
`Get-LdgcrmRoot`.** There is a structural test for this — nothing in the bundle may call
`Get-RepoRoot`, and no dot-source may use `..\..`.

**`scripts/.gitignore` is the authority for `data/`, `logs/` and `.env`** — deliberately not
duplicated in the root `.gitignore`. Git applies a `.gitignore` to its own directory and below in
*whatever repository contains it*, so the PII protection travels with the folder instead of being
left behind. Those trees can carry PII from Login.gov applicants sourced via Airtable; if you add a
new output location to the pipeline, add it to `scripts/.gitignore` **in the same change**.

`tools/Export-OpsBundle.ps1` builds the zip: it excludes `.env`, `data/` and `logs/` contents (but
ships their folders, `.gitkeep`s and READMEs), then **reads the finished archive back** and deletes
it if anything unexpected is inside — the build and the check can only agree by both being right.

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
  `LDGCRM_Application__c`. Opportunity *also* carries a direct `LDGCRM_Partner_Account__c` lookup; the
  single-lookup structure is correct, but **the real linkage is far sparser than Airtable suggests**.
  The Partner Accounts table's `Opportunities` column looks like a rich relationship (961 links over
  469 Opportunities) but is actually a **roll-up of the parent Account's Opportunities** — verified
  exact-match for 72 of 76 Partner Accounts, which is why all 8 DOD Partner Accounts show the same
  identical 50 Opportunities. The only authored path is via `LDGCRM_application__c` (which references
  both): **82 Opportunities, all unambiguous, ~9% coverage**. See
  `docs/engineering/TRANSFORMATION-RULES.md`'s Opportunity section — it also records the wrong intermediate
  conclusion this produced, and the "identical sets across unrelated records = rollup, not
  relationship" tell that caught it.
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

**⚠️ These Flows must be ACTIVE in the target org, and being inactive is INVISIBLE to every count
this pipeline produces.** QA was loaded 2026-08-14 with 8,740 records and 0 unexpected failures while
all nine were switched off — nothing failed, nothing was withheld, every object count matched Dev,
and Market Segment was blank on 100% of Partner Accounts, Opportunities and Applications. Flow
activation changes field *contents*, not row counts. `Invoke-FullMigrationLoad.ps1`'s pre-flight now
asserts all nine are active and **blocks the run**; `-ActivateFlows` switches on whatever is off
(sandbox only — rejected for `Prod`). It cannot *create* a Flow: absent means change set. See
`docs/engineering/ARCHITECTURE.md`, "Pre-flight: the nine Flows must be ACTIVE".

**A Flow's version number is a PER-ORG counter and means nothing across orgs** — every save in the
source org increments that org's sequence, every change set deployment increments the target's
independently, so Dev on v4 while QA is on v2 is normal and is *not* drift. Only active-vs-latest
**within one org** is a meaningful comparison (a version deployed but never switched on). Also note
flows can arrive via change set **inactive** — all nine landed in QA as Draft.

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
`tools/metadata/Get-LDGCRMDataDictionary.ps1` when you want it flattened to CSV instead of XML.

## Airtable API

`scripts/powershell-scripts/Get-AirtableExport.ps1` pulls current Airtable data straight from the REST API
into `scripts/data/airtable-exports/<Table>.json` (one file per table, overwritten each run — see "Scripts"
below). This replaced an earlier manual CSV/XLSX export-zip workflow; don't recreate that structure —
the JSON pull is the only source of truth for Airtable data in this repo now.

**The pull is a BACKUP OF THE WHOLE BASE, not just the migration's inputs** (widened 2026-08-16 at the
project owner's direction). It pulls **all 22 tables**; only **10** are read by the transforms, and the
other 12 exist purely so the pull is a faithful copy. `$DefaultTables` marks each one `Migration` or
`Backup`. **A `Migration` label is load-bearing** — `Get-AirtableTablePath` opens `<Label>.json` by that
exact string, so renaming one breaks a transform; a `Backup` label is just a filename.
`-MigrationOnly` pulls the 10 when you only want to refresh load inputs.

Because that list is hardcoded, **a table added to the base later would simply never be pulled, and
nothing would say so** — the same silent shape of failure as an inactive Flow. So after every pull the
script asks `GET /v0/meta/bases/{baseId}/tables` what the base actually holds and reports any table it
missed (ready to paste into `$DefaultTables`), any it expected that has gone, and any renamed. It runs
*after* the data is written and is **never fatal**: it needs `schema.bases:read`, and a token that
pulls every record perfectly well may still be unable to list tables, so a self-check that cannot run
must not fail a good pull. `-SkipCoverageCheck` turns it off.

**The folder is overwritten by the next pull** — it is a current-state mirror, not a retained backup.
Copy it elsewhere if a particular snapshot needs keeping.

**An export can go stale in ways that change a column's SHAPE, not just its values** — Airtable
converted Opportunities' `Existing Identity Platforms` / `Alternative Identity Platforms` from linked
records (`rec...` IDs) to plain multi-selects (vendor names). A transform written for one shape reads
the other as garbage. `Build-OpportunityLoad.ps1` therefore **hard-fails** rather than silently
dropping the 453 affected values (`Assert-IdentityPlatformsResolved`), telling you to re-pull. Treat
that as the pattern to copy: when a column's shape is load-bearing, assert it and fail loudly, because
"453 tags quietly missing" is invisible in a load that otherwise reports success. As of 2026-08-13 the
committed export (2026-08-12) **predates that conversion**, so Opportunity cannot build until
`Get-AirtableExport.ps1` is re-run — and re-running shifts every documented count, so re-baseline
rather than treating the old figures as pass/fail targets.

**Authentication:** a Personal Access Token (PAT), not the old-style API key — Airtable removed
`key...` API keys in Feb 2024, so a token must start with `pat...`. Create/manage one in the Airtable
Builder hub (profile avatar → Builder hub → Personal access tokens); it needs the **`data.records:read`**
scope at minimum, **`schema.bases:read`** too if you need to look up table IDs/names (see below), and
must be explicitly granted access to this base (PATs are scoped per-base/workspace, not account-wide).
Send it as `Authorization: Bearer <token>`. Locally it lives in the gitignored repo-root `.env` as
`AIRTABLE_API_KEY` (named after the deprecated concept, but the value is a PAT) alongside
`AIRTABLE_BASE_ID` (the `app...` string from the base's API docs page or its browser URL) — copy
`.env.example` to start. `scripts/powershell-scripts/Common.ps1`'s `Import-DotEnv` loads `.env` into the process
environment; nothing else in this repo reads it.

**REST API shape:**
- Base URL: `https://api.airtable.com/v0/{baseId}/{tableIdOrName}` — table names work but **table IDs
  are preferred and are what this repo's script uses**, because table *names* are user-editable in
  Airtable and a rename silently 403s a name-based request (this actually happened here: the "Partner
  Accounts" table was renamed to "Partners" in Airtable, breaking a name-keyed pull — Airtable returns
  403 uniformly for "no permission" and "table doesn't exist/isn't visible", so a rename looks
  identical to an auth failure until you check). `Get-AirtableExport.ps1`'s `$DefaultTables` hardcodes
  the current table-ID mapping as the single source of truth — update it there, not here, if a table
  is renamed/added/removed. A rename needs no action at all: the pull is keyed on ID, and the script
  reports the drift as information rather than a problem.
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
- **`LDGCRM_Market_Segment__c` stores the segment *name*** (`"Benefits"`, `"Defense"`, …) in
  `LDGCRM_External_ID__c`, not the Airtable `rec...` ID. **Decided 2026-08-14: keep the name**, and
  `Build-MarketSegmentLoad.ps1` now loads the object on that key. Rationale: the set is five fixed,
  human-meaningful values; `Build-AccountReconciliation.ps1` already resolves a segment by matching
  Airtable's segment name against that external ID, so `rec...` IDs would add a name→id→record hop
  for no benefit and orphan the external IDs already loaded. **If this is ever revisited, that
  script's `$MarketSegmentMap` and the transform must change together**, or a load will silently
  create duplicates by upserting on the wrong value. The transform hard-fails if two Airtable rows
  share a name, since the name is the key.
- **`OpportunityContactRole.LDGCRM_External_ID__c` has `externalId=false` and CANNOT be changed.**
  Deploying `externalId=true` fails with *"Fields on Opportunity Contact Role do not support the
  property Is External Identifier."* — Salesforce forbids External ID fields on this object entirely,
  so no metadata fix exists (an earlier note here claimed one was needed; it isn't possible).
  `OpportunityContactRole` is therefore **the one object loaded by INSERT + read-then-diff** rather
  than upsert: `Build-OpportunityContactRoleLoad.ps1` queries what exists, keys it on
  `(OpportunityId, ContactId, Role)`, and inserts only what's missing. The field is still populated
  for traceability. **Loaded 2026-08-13: 515 rows.** Two source traps documented in
  `docs/engineering/TRANSFORMATION-RULES.md`: `Opportunity Record ID` on that table is the row's OWN id (0 of 520
  are real Opportunity ids — the real link is `Opportunity Record ID (from Opportunities)`), and the
  table has no Contact link at all.
- On every object, `LDGCRM_External_ID__c` is `externalId=true` but **`unique=false` and `required=false`**
  — Salesforce will not reject a duplicate value at the database level. A load script upserting on this
  field is safe (Bulk API upsert still matches correctly), but anything that inserts instead of upserts,
  or edits the field by hand, can silently create duplicates. Consider flipping `unique` to `true` on the
  objects driven entirely by this migration (not on Account, see below) as a guardrail.

See `docs/engineering/TRANSFORMATION-RULES.md` for the full field-by-field mapping rules and
every gotcha discovered per object (Account's Type/Market Segment logic, Impediment's Category
value map, etc.) — this section is the short cross-object summary.

**Airtable table → Salesforce object**, with the linking columns that matter for load order:

| Airtable table | Salesforce object | Airtable link columns → Salesforce lookup |
| --- | --- | --- |
| Accounts | Account (`Federal` record type) | *(already migrated — see below)*; also `States + DC/PR` (checkbox) → `Type` (`"State"` if checked, else `"Federal"` — confirmed against Dev's existing data, not just Airtable's field name; see below) |
| Partner Accounts | `LDGCRM_Partner_Account__c` | `Account Record ID` → `LDGCRM_Account__c` (Master-Detail, requires Account loaded first); `Name`/`LDGCRM_Agreement_Short_Name__c` ← `Agreement Short Name` (no dedicated Name column exists) |
| Applications | `LDGCRM_application__c` (`LDGCRM_Application` record type — its only active record type) | `Partner Account Record ID (from Partner Agreement)` → `LDGCRM_Partner_Account__c` (required); `Opportunity Record ID` → `LDGCRM_Opportunity__c`; `Demographic Served` needed a Global Value Set expansion (6 → 25 values) — see `docs/engineering/TRANSFORMATION-RULES.md` for the full analysis and justification |
| Contacts | Contact (`Federal` record type) | no direct Account/Application lookup on Contact itself — relationships go through the junctions below |
| Applications × Contacts (embedded in Contacts/Applications exports) | `LDGCRM_Application_Contact__c` | needs both the Application's and the Contact's `rec...` IDs; splits Airtable's comma-joined multi-value cells into one junction row per pair |
| Opportunities | Opportunity (`Login_gov` record type) | `Account Record ID` → `AccountId` |
| Opportunity Contacts | `OpportunityContactRole` | `Opportunity Record ID` + Contact `rec...` ID; `Contact Type` → `Role`, `Primary` → `IsPrimary` (blocked on the `externalId` fix above) |
| Impediments | `LDGCRM_Impediment__c` | — ; `Category` needs an explicit value map, not passthrough — see below |
| Impediments × Opportunities (`Opportunities blocked` / `Opportunities requested` columns) | `LDGCRM_Opportunity_Impediment__c` | one junction row per Opportunity in each list; `Opportunities blocked` → `LDGCRM_Severity__c = "Blocker"`, `Opportunities requested` → `"Impediment"` |
| Market Segments | `LDGCRM_Market_Segment__c` | *(loaded by the pipeline as step 1 — `Build-MarketSegmentLoad.ps1`, added 2026-08-14)* |
| Meetings | Activity, as an **Event** (`LDGCRM_Meeting_Type__c` from `Meeting Type`) | `Opportunity Record ID` if present, else `Accounts Record ID`, → `WhatId` |
| Issuer Strings | *(no object of its own)* — collapses up onto `LDGCRM_application__c` | `Applications` → the Application whose `LDGCRM_P3_Partner_Portal_Team_Name__c` / `LDGCRM_P3_Team_UUID__c` it supplies. **Airtable records the team per issuer string, Salesforce per Application**, so the value only migrates where all of an Application's issuer strings agree — see below |

Meetings only carry a single `Date` column (no start/end time) — loading them as Event means
synthesizing `StartDateTime`/`EndDateTime` (e.g. a fixed default duration off that date), since
Airtable has no time-of-day to carry over.

**Before mapping a column, confirm the target field is even OURS — check the `LDGCRM_` prefix, not
the label.** This sandbox hosts TTS OTCRM and FCIC, which label their fields in the same business
vocabulary, so a Salesforce field whose **label** matches an Airtable column name is not evidence of
anything. Opportunity carries both `priority_type__c` (labelled "Priority Type", un-prefixed, owned by
TTS OTCRM, assigned to the `TTS_OTCRM_Opportunity` record type) and `LDGCRM_Level_of_Priority__c`
(ours). Airtable's column is called `Priority Type`, so the exact label match points straight at the
wrong field — and it was mapped that way on 2026-08-13 before the user caught it. **If the best label
match is un-prefixed, stop and ask** rather than treating the match as a discovery; writing another
app's field is worse than migrating nothing. A related coupling to watch: the three `LDGCRM_`
permission sets grant FLS on `priority_type__c`, which **does not exist in QA** — so that reference
will fail a change set into any org lacking the field, independent of the migration.

**Not every Airtable column is a simple same-name mapping.** `States + DC/PR` looks like it might
hold a state name but is actually a plain checkbox distinguishing state/DC/territory government
Accounts from federal ones — it maps to the standard `Type` field, not a new custom field, and its
value isn't "true"/"false", it's `"State"` vs `"Federal"`. This was confirmed empirically against
Dev's existing Accounts (54 already `Type="State"`, 530 already `Type="Federal"` — note
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
Blockers`) become `ContentNote` records (Enhanced Notes — confirmed enabled in Dev, not the
legacy `Note` object) attached to their parent record, in a dedicated **Notes chunk that has to be
built last**, after every other object's records exist. This is forward-only — it does not apply to
columns already migrated as dedicated fields (Partner Account's `Current Status Summary`,
Impediment's `Description`/`Talking Point` stay exactly as built). See
`docs/engineering/TRANSFORMATION-RULES.md`'s "Notes" section for the full mechanism, current
candidate-field list, and open questions (e.g. Partner Accounts' `Escalated User Support Cases`
appears to reference an Airtable table this migration doesn't currently pull at all).

**Before mapping any field that looks like a plain calculated/aggregate value — Percent, Number,
even Text — check its metadata for a `<formula>` tag before writing a transform against it.** The
declared `<type>` alone doesn't mean it's writable: Application's `LDGCRM_Level_1_Complete_Pct__c`/
`Level_3`/`Level_4`/`Launch_Checklist_Completion__c` all declare `<type>Percent</type>`, identical to
a normal writable field, but each is actually a formula computed from other fields already being
migrated (mostly checkboxes) — Salesforce rejects direct writes to a formula field outright. Caught
before `Build-ApplicationLoad.ps1` was written, not after a failed load. Same instinct as checking a
picklist's restricted values or a TextArea's real length before trusting a field's surface
appearance — see `docs/engineering/TRANSFORMATION-RULES.md`'s General Principle #7 and the
Application section's dedicated note for the full example.

**The `LDGCRM_Opportunity_Impediment__c` junction is loaded as of 2026-08-13: 267 records** (267/267).
Severity comes from *which* Airtable column an Opportunity appears in (`Opportunities blocked` →
`Blocker`, `Opportunities requested` → `Impediment`); `Blocker` wins the 122 pairs listed in both.
**The Airtable Impediment named `None` is deliberately excluded** — it has no Description/Talking
Point and 465 links (5× any real impediment), reads as a placeholder for "no impediment", and would
have swamped the `LDGCRM_Blocked_Revenue__c` roll-up with a meaningless figure. It accounted for 53%
of otherwise-loadable pairs. Reversible via `-PlaceholderImpedimentName`. Uses the same composite
external ID pattern as the Application-Contact junction.

**The `LDGCRM_Application_Contact__c` junction is loaded as of 2026-08-13: 1,880 records** (1,880/1,880).
Its `LDGCRM_External_ID__c` is a **composite key** `<contactExtId>|<applicationExtId>`, not a single
Airtable `rec...` ID — the one object that departs from the external-ID convention, and deliberately:
the object's duplicate-check Flow throws on duplicates, only fires on Create, and **misses
intra-batch duplicates entirely** (its Get Records reads committed state), so it cannot be relied on
as a safety net. The composite key makes one-row-per-pair structural instead. Two API-name typos to
respect: **`LDGCRM_contact__c`** (lower-case `c`) and **`LGDCRM_P3_Partner_Portal_Admin__c`**
(transposed `LGDCRM_` prefix). `Name` is an AutoNumber — never supply it.

**Partner Portal Admin has TWO sources and they are UNIONed (updated 2026-08-13).**
`Contacts.Roles` containing `Partner Portal Admin` (999 pairs) *and* the **Issuer Strings** table's
`Partner Portal Admin Email` (968 pairs), matched by email via `Get-CleanContactEmail`. They agree on
882; Roles-only 117, Issuer-Strings-only 86. Union, never intersection — both are authored, so a
silent source is not evidence of absence. **The 86 are the important part: none had a junction row at
all** (34 people administering 68 Applications the Contacts table never links them to), so Issuer
Strings *creates associations*, it doesn't just set a flag — reading it as flag-only would lose the
association entirely. Per the project owner: a Partner Portal Admin should *be* an Application Contact
with the box checked. Provenance per flag lands in
`scripts/logs/data-migration/ApplicationContact-admin-source-*.csv`. **The Applications table's own
`Partner Portal Admin` column stays excluded** — it's a roll-up not positionally aligned with
`Contacts Record ID` (lengths differ on 709 of 875 rows), so it would assign the flag at random.

**Contact is loaded as of 2026-08-13: 1,483 records** (1,483 of 1,487 submitted; 4 rejected by an
org-level duplicate rule). 1,115 carry an Account and 933 a Partner Account. Record types:
**Federal for partner-agency contacts, GSA for anyone with an `@gsa.gov` address** (user-confirmed —
this migration creates only those two, never the FCIC/TTS record types). **1,599 Airtable rows became
1,532 Contacts**: rows sharing an email are merged, because Airtable has no person↔Application
junction and enters the same person once per association. The merge logic lives in
`Get-AirtableContactGroups` (`Common.DataMigration.ps1`), shared so the Application-Contact junction
chunk maps every Airtable Contact ID onto the surviving Contact. **Loaded with
`-DisableTriggerControl "Contact"`** — see Operational gotchas.

**Opportunity is loaded as of 2026-08-13: 742 records** (742/742 succeeded). All 742 have their
Account lookup resolved and Market Segment populated by the before-save Flow; 467 compute a non-zero
revenue. 186 rows withheld (142 unreconciled Accounts, 28 no Status, 16 no Account link). Two
metadata fixes were required first: `LDGCRM_App_Description__c` TextArea(255)→LongTextArea, and
**adding 6 picklist values to the `Login_gov` record type** — see the next paragraph, it's the most
transferable lesson from this object.

**Record-type picklist restrictions ARE enforced by the Bulk API, and `sf sobject describe` does not
show them.** A 19-row Opportunity test batch failed 19/19 with
`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on `LDGCRM_Opportunity_Type__c` and
`LDGCRM_Likely_Service_Level_Needed__c` — both values verified valid against the describe output,
which reports *field*-level values only. **When a target object has more than one record type (as
Opportunity does: `Login_gov` and `TTS_OTCRM_Opportunity`), also read
`objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml`**, whose `fullName` entries are
URL-encoded (`,`→`%2C`, `/`→`%2F`, `(`/`)`→`%28`/`%29`, `&`→`%26`, `'`→`%27`). Always prove a new
object's picklist assumptions with a small test batch before a full load.

**Application is loaded as of 2026-08-13: 688 records** (688/688 succeeded, 0 failures; 691 total on
the object including 3 pre-existing test records). 359 more Airtable rows are deliberately withheld
until the duplicate/unmatched Account data is fixed in Airtable, and 92 loaded rows have a blank
Opportunity lookup pending the Opportunity load — both resolve on a plain re-run of
`Build-ApplicationLoad.ps1`, no code change needed. That script now queries the target org (it is no longer a
purely offline transform) to skip rows whose parent Partner Account doesn't exist rather than
submitting guaranteed failures. **`LDGCRM_Broker_App_Parent__c` is deliberately not loaded** — a
self-referential lookup can't resolve within its own upsert batch and needs a second pass (not built).

**Partner portal team on Application (added 2026-08-13, BLOCKED on a change set).**
`LDGCRM_P3_Partner_Portal_Team_Name__c` / `LDGCRM_P3_Team_UUID__c` are sourced from the **Issuer
Strings** table — documented here twice as having "no Airtable source" until PR #1 pulled the table.
The source column search that produced that wrong answer only covered the *Applications* table's own
columns: **"not in any export" is far weaker than "not in Airtable" — check
`GET /v0/meta/bases/{baseId}/tables` before declaring a Salesforce field sourceless.**
**The team is a property of the APPLICATION** (user-confirmed); Airtable stores it on each issuer
string, so it is duplicated and **every copy should be identical**. This is therefore a
de-duplication — read the agreed value, update the Application **once** — not a merge of distinct
facts, which is what makes disagreement a *defect* rather than a legitimate two-team Application.
Of 887 Applications: 678 agree everywhere, **18 carry it on only some issuer strings** (unambiguous,
so they migrate correctly — reported as tidy-up), **9 carry two different teams** (left blank +
reported, never tie-broken), 182 have none. `#N/A` is a literal string in that table (273 cells) and
must be filtered.
**RESOLVED 2026-08-14: both fields are now `unique=false` and Text(255)** (was `unique=true`,
Text(50)). `Build-ApplicationLoad.ps1` reads the live field definitions and **omits the two columns
while either is unique** — omitted, not blanked, because an empty column in an upsert *clears* the
org's value — so the fix needed no code change, just a re-run. Verified: **681 Applications carry a
portal team**, 0 failures. The widening to 255 also cleared the 6 over-long team names.
**`#N/A` is transformed to blank** (`Get-CleanIssuerStringValue`), and **issuer strings / team name /
team UUID are OPTIONAL by business rule (2026-08-14)** — a missing value is an accepted outcome, not
a data-quality ask. The 9 Applications whose issuer strings name two teams stay blank deliberately.
**`LDGCRM_PP_Issuer_Strings__c` was DELETED 2026-08-14** — never migrated. It could not be a plain
delete because `LDGCRM_Level_1_Complete_Pct__c` counted it as 1 of 9 checklist items and
`LDGCRM_Launch_Checklist_Completion__c` hard-codes that 9 as a weight, so dropping the item would
have silently moved a second metric. **Resolved by re-pointing the checklist item at
`LDGCRM_P3_Team_UUID__c` rather than removing it** — denominator stays 9, the second formula needed
no change, and the item keeps its meaning. Ceiling moved 78 → 89.

**A field delete only hard-blocks on a FORMULA reference.** Layout, permission-set FLS and
report-type columns are cascaded away by Salesforce automatically — 78 lines across 8 files here.
And **`sf project deploy start --metadata-dir` silently ignores a destructive manifest**: it reported
"Succeeded" having deployed 0 components. Use `--manifest` + `--post-destructive-changes`, and check
`numberComponentsDeployed` / `deleted=True`, not just the status. `sf sobject describe` also served a
stale cached answer; the Tooling API's `FieldDefinition` gave the truthful one.

**Salesforce config changes the pipeline cannot make live in
`docs/engineering/SALESFORCE-CHANGE-REQUESTS.md`** — the config-owner counterpart to the Airtable
data-quality doc, and like it, that file holds **only what is still open**. As of 2026-08-15 **every
change request that blocked a load has landed in Dev and QA** (verified against both orgs, not
against the change-set record); only two cosmetic tidy-ups remain. Full and Prod are unverified.

**One settled decision that is now load-bearing in the pipeline:** a blank `Launch Level` falls
through the `CASE` in `LDGCRM_Launch_Checklist_Completion__c` to its else value of `1`, so an
Application with an empty Launch Level reports 100% launch-complete. The project owner **accepted
this as-is** rather than changing the formula, which makes `Build-ApplicationLoad.ps1`'s default of
`1 - Very Low Impact` the thing keeping the metric honest — **removing that default silently returns
hundreds of Applications to reporting 100%.**

**Current sandbox state (rebuilt 2026-08-13 — see `docs/engineering/ARCHITECTURE.md`'s "Production Account seed"
section for the full rebuild):** the Account/Partner Account chain was deliberately hard-deleted
(scoped, via `scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1`) and rebuilt from a real production Account
export to make reconciliation testing meaningful, rather than testing against arbitrary sandbox seed
data. **Treat every count below as a moving target, not a fixed baseline** — it's shifted several
times in a single day already. Current: 1,346 Accounts (1,342 inserted from the production export +
4 untouched pre-existing test records), 588 carry `LDGCRM_External_ID__c` after the reconciliation
backfill, **Market Segment is now IN the reset scope and IS loaded by the pipeline** (changed
2026-08-14 — 5 tagged segments deleted and reloaded by `Build-MarketSegmentLoad.ps1`; the untagged
`Test Market Segment` survives like any other untagged row), **Partner Account has 76 records**
(74 loaded + 2 pre-existing test records) and
**Impediment has 40** (untouched by the rebuild — deliberately preserved, not part of the Account
chain). Airtable has 757 Account rows against 588 tagged Salesforce Accounts — **don't assume 1:1**
— reconcile by external ID first, then by name, and treat any Airtable Account row that doesn't
match an existing Salesforce Account as an exception for human review rather than auto-creating a
new Account (this is also why Account's `LDGCRM_External_ID__c` should stay `unique=false`/
non-enforced for now). 169 rows remain unmatched as of the rebuild — confirmed 2026-08-13 that most
checked so far are duplicate rows *within Airtable itself* (e.g. `Army`/`Navy`/`Air Force` alongside
already-linked `Department of the Army`/`Department of the Navy`/`Department of the Air Force`
entries), not genuinely missing Accounts — see `docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md` for the
full list and a human decision needed for each. `Build-AccountReconciliation.ps1`
(`scripts/powershell-scripts/`) automates this reconciliation — external ID, Market Segment, and Type
backfill — read-only against Salesforce, writing an update CSV plus human-review CSVs for anything
it can't confidently match; see `docs/engineering/ARCHITECTURE.md` for the full pipeline.

**Load order** (parents before children/junctions — the reverse of the delete order in
`scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1`): **Market Segment (loaded by the pipeline as of
2026-08-14 — `Build-MarketSegmentLoad.ps1`, step 1 of 12)** → Account → `LDGCRM_Partner_Account__c` →
Contact → Opportunity → `LDGCRM_application__c` → `LDGCRM_Opportunity_Impediment__c` (needs
`LDGCRM_Impediment__c` and Opportunity first) → `LDGCRM_Application_Contact__c` →
`OpportunityContactRole` → Activity (Meetings, needs Account/Opportunity first).

## Scripts

### ⚠️ PowerShell is the language of this repo. Do not reach for Python.

**Everything here is built in PowerShell — automation, transforms, one-off analysis, throwaway
checks. There is no Python in this project and none is wanted.** Do not go looking for a Python
interpreter, do not write a `.py` helper "just for this bit", and do not shell out to `python`/`py`
to parse JSON or crunch a CSV. If you need to inspect an Airtable export, count picklist values, or
diff two lists, write it in PowerShell — `ConvertFrom-Json`, `Import-Csv`, `Group-Object`,
`Compare-Object` and a `foreach` cover essentially every case this repo has needed.

This is a hard convention, not a preference. The operators who inherit this pipeline (GSA IT
Operations included) have `sf` and Windows PowerShell and nothing else guaranteed; a Python
dependency would be a tool they cannot install. It also keeps one language across `scripts/`, so
there's a single set of helpers, one logging convention, and one confirmation-gate pattern.

The same goes for **ad-hoc analysis during a session**: use PowerShell inline rather than a scratch
Python script, so anything worth keeping can be lifted straight into `scripts/` unchanged.

All scripts are PowerShell, **targeting Windows PowerShell 5.1+** (this repo's dev machines don't have
PowerShell 7/`pwsh` installed, and installing it is blocked by Group Policy on at least one of them —
so `#Requires -Version 5.1` at the top of every script, not 7.0). Avoid syntax that only exists in
PowerShell 6+ (`??`, `?.`, ternary `?:`, `ConvertFrom-Json -AsHashtable`, `ForEach-Object -Parallel`,
multi-argument `Join-Path`) — stick to `Join-Path`/`Split-Path` with the classic two-argument form, as
the existing scripts do. Scripts still run fine under `pwsh` 7+ if a machine happens to have it; they
just don't require it.

**PowerShell 5.1 traps that have actually cost time here** — all of these fail *quietly* or blame the
wrong thing:

- **Never redirect a native command's stderr** (`2>&1`, `2>$null`) — on `sf`, `git`, `powershell`.
  PS 5.1 wraps each stderr line in an ErrorRecord, so the CLI's harmless "update available" banner
  becomes a `NativeCommandError` that kills the script, and the error points at the line that ran the
  command rather than at the redirect. `sf`'s output is captured anyway; just don't redirect.
- **`Export-Csv -Encoding UTF8` writes a BOM**, and the Bulk API rejects the file with
  *"Found unescaped quote"* — the BOM lands in front of the first `"`. Use `Export-DataLoaderCsv`
  (`Common.DataMigration.ps1`), which writes UTF-8 **no-BOM**, for anything Salesforce will read.
  Its parameter is `-InputObject`, not `-Rows`.
- **Never count CSV records with `Get-Content`/`Measure-Object -Line`.** Rich-text fields contain
  newlines and are legally quoted across multiple physical lines, so line count wildly overstates —
  it reported Partner Account as 1,017 records when the real figure was 94. Use
  `@(Import-Csv $path).Count`.
- **`$json.records` on an array of pages returns 928 nulls, not 928 records.** Member enumeration
  over an array whose elements lack the property yields `$null` per element, so `.Count` looks
  right and `[0]` is null. Inspect the actual shape (`$j[0].PSObject.Properties.Name`) before
  trusting a count — see [[powershell-array-return-gotchas]] and the `@()` convention.
- **`return ,$Array` and a caller's `@()` are mutually exclusive — pick one.** The leading comma
  exists to stop PowerShell unrolling a returned collection, and it is *required* when the callee
  returns a `List<T>` the caller assigns bare (see `Read-ProdAccountExportGrid`). But combine it with
  the repo's usual `@(...)` at the call site and you get a **one-element array containing the array**:
  `.Count` becomes 1 and the real contents hide one level down. Caught by a test on
  `Select-LdgcrmResettableObjects`, where a 4-item list silently became `Count=1`. Rule of thumb:
  **plain array + caller wraps in `@()` → return it bare; `List<T>` the caller uses as an object →
  return it with the comma.** State which contract a function has in its help block.
- **A here-string (`@'…'@`) does not reliably bind as a single argument to a native command.**
  `git commit -m @'…'@` split on the apostrophe in "Airtable's" and turned the message body into
  pathspecs. For multi-line commit messages write the message to a file and use `git commit -F`.
- **`Get-Content -Raw` WITHOUT `-Encoding` silently corrupts UTF-8 files that have no BOM.** PS 5.1
  falls back to the system ANSI codepage (Windows-1252 here), so every em dash, arrow and ⚠ is
  mis-decoded; writing the result back as UTF-8 bakes the damage in. This mangled 14 files in one
  bulk find-and-replace on 2026-08-14 — and *only* the BOM-less ones, because `Get-Content` honours
  a BOM when there is one, which is why the corruption looked random. **Any script that reads a file
  and writes it back must pass `-Encoding UTF8` (or use `[System.IO.File]::ReadAllText` with an
  explicit encoding).** Note this cuts both ways: `powershell.exe` also decodes a BOM-less `.ps1` as
  ANSI, so a repair script containing the very characters it hunts for will not parse — write that
  kind of tool in pure ASCII using regex `\u` escapes.

Every script dot-sources `scripts/powershell-scripts/Common.ps1` and uses its helpers rather than writing output
next to the script or inventing new log locations:
- **`Get-LdgcrmRoot`** — the **bundle** root (`scripts/`), resolved from the script's own location.
  Replaced `Get-RepoRoot` on 2026-08-14; see "`scripts/` is a SELF-CONTAINED BUNDLE" above. Anything
  in `tools/` uses `Get-RepoRoot` from `tools/Common.Tools.ps1` instead.
- `Get-LogDirectory -Category <cleanup|data-migration>` — ensures/returns the matching
  `logs/<category>/` folder. **`metadata` was removed as a category on 2026-08-14** — it was only
  ever used by the engineering-only metadata tooling, which now logs to `logs/tools/` outside the
  bundle via `Start-ToolLog`.
- `Start-ScriptLog -Category ... -ScriptName ...` — opens a transcript in that folder and returns a
  shared timestamp for the run's other output files (CSVs, summaries). Pair with `Stop-ScriptLog` in
  a `finally` block so the transcript closes even on early `exit`.

Current scripts:
- `tools/metadata/Get-LDGCRMDataDictionary.ps1` — exports a full object/field data dictionary CSV
  via `sf sobject describe`; discovers custom objects by Salesforce label under the `LDGCRM_` prefix.
- `tools/metadata/Sync-Metadata.ps1` — before retrieving, scans the sandbox for components whose
  name matches `LDGCRM_`/`LGDCRM_` but aren't yet in `sfdx/manifest/package.xml`, adds them
  automatically, and reports anything new that *doesn't* match the naming convention for manual
  review instead of guessing (this sandbox hosts unrelated apps like FCIC that share the same
  metadata types — see `tools/metadata/ldgcrm-manifest-ignore.json` for confirmed non-LDGCRM
  components that should stop resurfacing in that report). Then runs `sf project retrieve start`
  against the manifest. `-WhatIf` reports only; `-SkipDiscovery` retrieves the manifest as-is.
- `tools/Export-OpsBundle.ps1` — builds the hand-off zip from `scripts/`. Run `-WhatIf` first.
- `tools/Test-BundleStructure.ps1` — **run this after touching anything under `scripts/`.** Touches
  no org, so it is always safe. It checks the things that *cannot* be noticed by running the pipeline
  normally here, because everything the bundle must not depend on is sitting one level up and
  resolves fine: no bundle script calls `Get-RepoRoot`, no dot-source uses `..\..`, every data/log
  path lands inside the bundle, `git check-ignore` actually ignores `.env`/`data/`/`logs/` (asked of
  git, not read off the file — later negations can re-admit what an earlier rule excluded), the
  registry is coherent, and the Dev/QA-only blocks still reject `Full`/`Prod` at bind time.
- `scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1` — **the Sandbox Factory Reset**: returns a
  pre-production sandbox to a known starting state so a migration rehearsal always begins from the
  same baseline. **Interactive and destructive**: hard-deletes records by object (only rows where
  `LDGCRM_External_ID__c` is populated), after a typed `HARD DELETE` confirmation. Exports the
  record IDs it deletes first for an audit trail.
  **It cannot target production, by construction rather than by policy** — `-Environment` doesn't
  accept `Prod` (rejected at parameter binding), the registry's `IsProduction` flag aborts the run,
  and `Organization.IsSandbox` is read from the org itself to close the `-OrgAlias` escape hatch.
  There is deliberately no production confirmation prompt: offering one would only create a way to
  approve it by mistake. Two non-obvious inclusions: `OpportunityContactRole` (which cascades away
  on a full reset, so its absence was invisible until a scoped run) and migrated **Notes**, which
  can't be scoped by external ID and are instead found by walking `ContentDocumentLink` from tagged
  parents *before* those parents are deleted — otherwise the notes survive orphaned in Files.
  **In Dev/QA only**, when the deletes finish it **offers to run `Invoke-AccountBootstrap.ps1`**
  against the same environment, if an export exists in `data/prod-accounts/` — because deleting is
  only half a rebuild (see the next bullet). `-BootstrapAccounts` / `-SkipBootstrap` answer that
  prompt non-interactively. In a Full sandbox `Account` is filtered out of the delete list entirely
  and the bootstrap is not offered — see the Environments section.
- `scripts/powershell-scripts/Invoke-AccountBootstrap.ps1` — **Dev/QA only** (ValidateSet, enforced at
  bind time) — rebuilds an org's Account **names and parent hierarchy** from the production export.
  Needed because the pipeline *reconciles onto* existing Accounts rather than creating them, so a
  cleaned or freshly refreshed sandbox gives the downstream loads nothing to attach to. **Multi-pass
  by necessity**: `Account.ParentId` is a self-lookup and the export names parents by name, so each
  layer can only be resolved after the one above it exists. Idempotent; only ever fills in a *blank*
  `ParentId`; refuses to guess an ambiguous parent (14 Account names are borne by 2+ distinct
  Accounts) and reports those instead. Run `-PlanOnly` first. Supersedes
  `tools/Build-ProdAccountSeed.ps1`, which seeded names only — and whose name-dedupe is why 31 rows
  in the Dev sandbox can no longer be mapped to a hierarchy.

  **The source export lives in `scripts/data/prod-accounts/` and its FORMAT IS SNIFFED, NOT ASSUMED**
  (changed 2026-08-14). Its own folder, because the file no longer has a fixed name *or* a fixed
  format: whoever re-exports the PEO Accounts report next may save it as `.xlsx` or `.csv`, and the
  old "must be called `peo-prod-accounts-<date>.xls`" convention failed *silently* — the bootstrap
  offer simply never appeared. Now the newest file in that folder wins (all candidates are printed),
  and `Get-ProdAccountExportFormat` reads the first bytes to decide:
  - **The `.xls` extension is already lying.** The file shipped as `peo-prod-accounts-2026-07-16.xls`
    is an HTML `<table>` — what Salesforce's report "Export → Formatted Report" produces. Dispatching
    on the extension would hand it to an Excel parser and fail on a file that parses fine.
  - **A real `.xlsx` is read without Excel and without any module** — it is a ZIP of XML, and
    `System.IO.Compression` ships with the .NET Framework PS 5.1 already runs on. Two traps handled:
    the first sheet is resolved through `xl/_rels/workbook.xml.rels` (Excel does *not* renumber
    `sheet1.xml` when tabs are reordered), and each cell is placed by decoding the **column letter**
    in its `r` attribute — Excel omits empty cells entirely, so positional reading would silently
    shift every column after a blank and *reparent Accounts without erroring*.
  - **A genuine legacy binary `.xls` (OLE2) is refused with an instruction** to re-save as
    `.xlsx`/`.csv`. Excel COM would work but would make Excel a prerequisite on an operator's
    machine, which this pipeline does not get to assume.
  All three paths feed one `Read-ProdAccountExportGrid` and the same column mapping, so only the
  container varies. Ragged rows are read via `Get-GridCell` (indexing past a `string[]` throws in
  PS 5.1) and the grid readers `return ,$List` to survive PowerShell's output unrolling.
- `scripts/powershell-scripts/Get-AirtableExport.ps1` — pulls current data directly from the Airtable REST
  API (one JSON file per table, paginated via `offset`) into `scripts/data/airtable-exports/<Table>.json`,
  **overwriting** the previous pull each run (a timestamped transcript + `pull-summary-<timestamp>.csv`
  still land in `scripts/logs/data-migration/` via `Common.ps1`, so run history isn't lost, just the data
  itself isn't duplicated per run). See "Airtable API" above for auth/connection details. Defaults to
  **all 22 tables in the base** — it is a backup, not just a migration input. `-MigrationOnly` narrows
  it to the 10 in the "Airtable table → Salesforce object" mapping above; `-Tables` names an explicit
  subset. A post-pull coverage check reports any table the base holds that the script does not.
- `scripts/powershell-scripts/Build-*.ps1` — one transform per object, each reading the Airtable JSON
  (and, where it has lookups, querying the target org read-only) and writing a load-ready CSV to
  `scripts/data/salesforce-loads/` plus review CSVs to `scripts/logs/data-migration/`. Built so far:
  `Build-AccountReconciliation.ps1`, `Build-PartnerAccountLoad.ps1`, `Build-ImpedimentLoad.ps1`,
  `Build-OpportunityLoad.ps1`, `Build-ApplicationLoad.ps1`, plus the one-off
  `Build-ProdAccountSeed.ps1`. **They never write to Salesforce** — that's `Invoke-SalesforceLoad.ps1`,
  a separate explicit step behind a typed `LOAD` confirmation.
- `scripts/powershell-scripts/Invoke-SalesforceLoad.ps1` — wraps `sf data upsert bulk` /
  `sf data update bulk` / `sf data import bulk` (`-Operation Upsert|Update|Insert`) against any
  object/CSV, with preflight counts and a typed confirmation gate.
- **Built since:** `Build-ContactLoad.ps1`, both junctions (`Build-OpportunityImpedimentLoad.ps1`,
  `Build-ApplicationContactLoad.ps1`), `Build-OpportunityContactRoleLoad.ps1` (insert + read-then-diff,
  *not* blocked on an `externalId` fix — that fix is impossible, see the mapping section), the
  Application second pass for `LDGCRM_Broker_App_Parent__c`, and the Notes chunk
  (`Build-NotesLoad.ps1` + `Invoke-NotesLoad.ps1`, which loads over REST because `ContentNote.Content`
  is binary and Bulk 2.0 CSV refuses it). Plus `Invoke-FullMigrationLoad.ps1` (orchestrator) and
  `Invoke-MigrationRollback.ps1`.
- **Still to build:** Meetings (Activity/Event). See `docs/engineering/ARCHITECTURE.md` for per-script status —
  **that file, not this one, is the authority on build status**; this list goes stale fastest.

**Everything one run produces goes in ONE directory** (changed 2026-08-13):
`logs/<category>/<ScriptName>-<timestamp>/`. There are no longer `full-load-`/`notes-load-`/
`bulk-results/`/`rollback-` folders, and nothing is written loose. The mechanism is one change in
`Common.ps1` — `Start-ScriptLog` publishes the directory in `$env:LDGCRM_RUN_DIRECTORY` and
`Get-LogDirectory` returns it, so every existing caller redirects unchanged and child processes
inherit it. **Never reintroduce a per-script subfolder**; write into `Get-LogDirectory`. Use
`Get-LogCategoryDirectory` only for things genuinely about the *set* of runs.

**That directory holds one report: `SUMMARY.txt`** (built by `Common.LoadReport.ps1`), also printed
at the end of the transcript. Read it before opening anything else. Two things about it are
load-bearing:

- **"Withheld" is not a load error, and it is usually the bigger number.** Transforms skip rows whose
  parent isn't loaded, whose Account won't resolve, whose junction partner was itself withheld — those
  rows are never *submitted*, so the Bulk API says nothing, the step reports success, and the records
  are simply absent. The 2026-08-13 reload failed 31 rows and withheld several hundred. Any new
  "how much migrated?" question must account for both.
- **Expected-vs-unexpected is decided two different ways.** A *row failure* is expected if it matches
  that object's `ExpectedFailurePatterns` in `Invoke-FullMigrationLoad.ps1`'s `$Steps` table. A
  *count* is expected by comparison with the previous run — each run writes `findings.csv`/`errors.csv`
  and the next diffs against them. Do not add a hard-coded expected count anywhere: it is wrong the
  moment Airtable is fixed, and this repo has already killed one check that cried wolf every run.

Findings are attributed to a step **by time window**, not by file name, which is why none of the
transforms needed changing — see ARCHITECTURE.md's "Reading a run". A new review CSV whose suffix
isn't in `$Script:LoadFindingKinds` still appears, under "unclassified"; add the suffix there.

**Programme status lives in `docs/PRODUCTION-READINESS.md`** — seven gates between here and the
production load, with an owner each. It is the source-controlled counterpart to the per-run
`SUMMARY.txt`, which is gitignored and disposable. Update a gate in the same change that moves it,
and **don't paste run counts into it** — point at the object and let ARCHITECTURE.md or a run report
carry the number.

## sfdx/ commands

Run from inside `sfdx/`:
- `sf project retrieve start -x manifest/package.xml --target-org peodv8dvn` — pull metadata (or use
  `tools/metadata/Sync-Metadata.ps1` from the repo root, which wraps this with logging).
- `npm run lint` — ESLint over `aura`/`lwc` JS.
- `npm test` / `npm run test:unit` — `sfdx-lwc-jest`; `test:unit:watch` and `test:unit:coverage` variants
  exist. To run a single test file: `npx sfdx-lwc-jest path/to/file.test.js`.
- `npm run prettier` / `npm run prettier:verify` — formats `.cls,.cmp,.component,.css,.html,.js,.json,.md,.page,.trigger,.xml,.yaml,.yml`.
- Husky's `pre-commit` hook runs `lint-staged` (Prettier on all matched files, ESLint on `aura`/`lwc`
  JS, `sfdx-lwc-jest --bail --findRelatedTests --passWithNoTests` on `lwc` changes).

## Operational gotchas

- **The repo's metadata is NOT a complete picture of what fires in this org — always check the live
  org for Apex triggers, duplicate rules and flows before loading a new object.** `manifest/package.xml`
  is deliberately LDGCRM-scoped, so automation belonging to the other apps sharing this sandbox was
  never retrieved and is invisible to any amount of careful reading of `sfdx/force-app`. Loading
  Contact surfaced three such things at once, none of them in the repo:
  - **`GSA_FCIC_ContactTrigger`** (unmanaged, the FCIC app) fires on every Contact insert and creates
    a junk Account — named after the person, hard-coded to the `FCIC_Individual` Account record type —
    for **every Contact inserted with a blank `AccountId`**. An 18-row test batch created 4 Accounts.
    It also runs a `dedupContact()` routine over inserted rows.
  - **`purecloud.ContactWebHookv1`** (installed **managed** package, Genesys PureCloud) also fires on
    Contact insert. Its body returns `(hidden)` and it cannot be retrieved, so **what it does is
    unknowable from here**, and it has no kill switch. A webhook on Contact insert is an
    outward-facing side effect this pipeline cannot inspect — user-confirmed inert in Dev
    (2026-08-13), but **re-confirm before any production run**.
  - An **org-level duplicate rule** on Contact (First + Last name) that rejected 4 records with
    `DUPLICATES_DETECTED`. Also not in the repo. **This is `OTCRM_Contact_Duplicate`, and as of
    2026-08-15 the LOAD ITSELF SWITCHES IT OFF, permanently, in every environment including Prod** —
    it later cost 167 Contacts in one Dev run. Pre-flight check 8 calls
    `Disable-LdgcrmContactDuplicateRules`, which retrieves the rule from the target org, flips
    `isActive`/`ruleStatus`, deploys it back to that same org, and then **decides whether to proceed
    on a verifying re-query, never on the deploy's own success report**. It blocks only if a rule is
    still active afterwards. **Nothing is restored** — unlike the `TriggerControls__c` bypass, these
    stay off. The plan to add `Email` to the matching rule and promote it by change set was
    abandoned: a change set cannot carry a matching-rule change, because Salesforce refuses to modify
    a rule that is Active in the target *and* refuses to change a definition and a status in one
    deployment, and a change set always carries the source org's status with no way to edit it. It is
    TTS OTCRM's rule, but **TTS OTCRM is defunct** (user, 2026-08-15), so this needs no cross-team
    sign-off.

  Useful live-org checks before a first load of any object:
  `sf data query --use-tooling-api -q "SELECT Name, Status, TableEnumOrId FROM ApexTrigger WHERE TableEnumOrId = '<Object>'"`
  and read any unmanaged trigger's `Body` the same way (managed ones return `(hidden)`).
- **The FCIC app ships a supported kill switch, and `Invoke-SalesforceLoad.ps1` uses it.** The
  `TriggerControls__c` custom setting has one record per object (`Task`, `Case`, `Contact`,
  `LiveChatTranscript`) with an `On__c` flag the trigger checks first. Passing
  `-DisableTriggerControl "Contact"` captures the current value, switches it off for the load, and
  restores it in a `finally` block with a **verifying re-query** — so it is restored even when the
  load throws (which it did, on the real Contact load, and the restore still ran and verified).
  Read the `TRIGGER BYPASS` comment block in that script before using it. It is off by default, it
  flips config owned by another app, and it needs explicit human sign-off per load.

- **Any `sf project deploy validate` (or a `deploy start` that runs tests) currently fails org-wide**
  due to a pre-existing Apex compile error unrelated to this app: `GSA_FCIC_AC_Manual_InitialBatch`
  (part of the unrelated FCIC app that shares this sandbox — see the wildcard-retrieve warning below)
  has a genuine compile error (`line 23: Variable does not exist: metadata`). Salesforce compiles
  *all* Apex in the org as a prerequisite for running any tests, so this one broken class cascades
  into "Dependent class is invalid and needs recompilation" errors and test failures across the
  entire org, regardless of what you're actually deploying — discovered 2026-08-12 while deploying
  an unrelated two-field metadata change (see `docs/engineering/TRANSFORMATION-RULES.md`'s
  Impediment section). **Workaround for metadata-only changes with no Apex/trigger component**, on
  this sandbox (not production): `sf project deploy start --test-level NoTestRun --target-org
  peodv8dvn` skips test execution entirely, sidestepping the recompilation cascade. This does *not*
  fix the underlying problem — a deploy that actually includes Apex, or that must run tests for any
  other reason, is still blocked until someone who owns the FCIC app fixes
  `GSA_FCIC_AC_Manual_InitialBatch`.
- **`sf project retrieve start` requires running from inside `sfdx/`** (or passing paths relative to
  it) — it needs `sfdx-project.json` in the working directory. Running it from the repo root fails
  with `InvalidProjectWorkspaceError`.
- **A targeted `-m "RecordType:<Object>.<RT>"` retrieve is LOSSY — always retrieve
  `-m "CustomObject:<Object>"` instead.** Retrieving the record type on its own returned **4 of 33**
  `<picklistValues>` blocks and would have silently deleted the other 29 from `force-app/` had it been
  committed. Nothing warns you; the file just gets shorter. After any metadata retrieve, check
  `git diff --stat` and confirm the change is confined to what you expected. To inspect another org
  without touching `force-app/`, retrieve to a scratch dir instead:
  `--target-metadata-dir <scratch> --unzip`.
- **Retrieving a Salesforce Outbound Change Set's contents:** Change Sets have no direct Metadata/
  Tooling API or `sf` support for listing/querying them, but a change set's **Name** (not its Setup
  URL ID) works as an unmanaged package name for retrieval: `sf project retrieve start --package-name
  "<Change Set Name>" --target-org peodv8dvn`. This is how `force-app/` was synced from `LDGCRM_Sprint_1_12`.
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

## Documentation layout

Documentation is split by **audience**, because they barely overlap. Put new documentation in the
right place rather than growing this file or `docs/README.md`:

| Path | Audience | Contents |
| --- | --- | --- |
| `docs/PRODUCTION-READINESS.md` | **The project owner and whoever is building it, together** | **The north star** — seven gates between here and the production load, with an owner each |
| **`scripts/README.md`** | People **running** a migration — the bundle's front door | Routes to the runbooks below; environments, layout, the two traps |
| **`scripts/docs/`** | People **running** a migration, assuming no prior knowledge | `SETUP.md`, `RUNNING-A-LOAD.md`, `TROUBLESHOOTING.md`, `ROLLBACK.md`, `RELOAD-QA-CHECKLIST.md` |
| `docs/engineering/` | People **changing** the pipeline | `ARCHITECTURE.md` (was `docs/README.md`), `TRANSFORMATION-RULES.md`, `BACKLOG.md`, `SALESFORCE-CHANGE-REQUESTS.md` |
| `docs/data-quality/` | The **data owners** — not developers | `AIRTABLE-DATA-QUALITY-REQUESTS.md` (Airtable owners) and `SALESFORCE-ACCOUNT-CLEANUP.md` (the GSA Salesforce team — duplicate/misfiled Accounts, to be worked **after** the production migration) |
| `docs/*.html` | **Stakeholders** | The current dated status report. Never edit an old one to refresh it — generate a new dated one |
| `scripts/logs/README.md` | Anyone reading run output | What each kind of run leaves behind |

**The operator docs moved from `scripts/docs/` into `scripts/docs/` on 2026-08-14**, because they
have to travel with the code they describe — Operations gets the bundle, not this repository. Only
the *engineering* audiences are left under `docs/`.

That split has one consequence to respect: **a runtime message an operator will see must point at
`docs/<file>.md` inside the bundle, never at `docs/engineering/` or `docs/data-quality/`**, which
will not exist for them. Comments in script headers may still reference the engineering docs — those
are read by people changing the pipeline, who have this repo. The five operator-facing pointers were
re-aimed at `docs/SETUP.md` / `docs/TROUBLESHOOTING.md` in the same change.

`docs/README.md` is an **index only** — it routes by audience and holds no content of its own.

**Only the CURRENT stakeholder report is kept, and only its HTML** (changed 2026-08-13). The PDF is
generated by `tools/Export-ReportPdf.ps1` and is **gitignored** (`docs/*.pdf`) — it is build output
whose source is already tracked, and it is not in a fresh clone, so render it before sending. Superseded
reports are removed rather than retained: their numbers are wrong within hours, and a stale report in
the repo is likelier to be re-sent by mistake than to be useful. Status over time belongs in
`PRODUCTION-READINESS.md`, which is maintained rather than snapshotted.

### ⚠️ EVERY document records what is TRUE NOW, not how it got there

**Standing convention, user-stated 2026-08-15, generalizing the 2026-08-14 rule that previously
applied only to the data-quality document.** Completed work, resolved items, superseded status and
run history are **deleted, not struck through, not archived in a "Resolved log", not marked ✅.**
Git carries the history; per-run detail lives in each run's `SUMMARY.txt`.

The reason is the one that forced the original reversal: closed items outnumber open ones within
days, and a reader then has to work out which is which. A 1,100-line data-quality doc and a 630-line
backlog of built work are what this rule exists to prevent.

Applies to all of these, and re-measure the survivors in the same change so every number describes
today:

| Document | Holds only |
| --- | --- |
| `docs/data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md` | Currently-open asks that **cost records**. Its absence *is* the confirmation a fix landed |
| `docs/data-quality/SALESFORCE-ACCOUNT-CLEANUP.md` | Duplicate/misfiled Accounts still present in the production org. Delete an item once it is resolved |
| `docs/engineering/SALESFORCE-CHANGE-REQUESTS.md` | Config changes not yet promoted. Delete a CR once it is in every org |
| `docs/engineering/BACKLOG.md` | Work agreed but **not yet built**. A built item is deleted, not marked done |
| `docs/PRODUCTION-READINESS.md` | Current gate status. No struck-through gates, no superseded run write-ups |
| `docs/*.html` | Nothing, normally — reports are generated on demand and removed once superseded |

**The one exception is a RULE.** A business or transformation rule stays even after it is
implemented, because it describes how the system must behave, not what happened. Those live in
`docs/engineering/TRANSFORMATION-RULES.md` ("Settled business rules") and must not be deleted as
"completed" — deleting one invites it being re-litigated as an open question.

`scripts/docs/RELOAD-QA-CHECKLIST.md` — update the matching expectation **in the same change**. A
resolved item usually invalidates a row count, an "expect N skipped", a known-empty field, or makes
an optional step mandatory. A checklist saying "expect 142 blocked" must not outlive the fix that
unblocked them. Keep **one** current baseline, not a stack of superseded ones.

## Skills

Project-specific skills live in `.claude/skills/` and load automatically when relevant:
- `sfdx-metadata-sync` — retrieving/deploying metadata, extending `sfdx/manifest/package.xml`.
- `sfdx-sandbox-ops` — safety checklist for any destructive or bulk operation against a sandbox
  (confirm org, preflight counts, export-before-write, never bypass the typed confirmation gate).
- `sfdx-data-migration` — conventions for the `scripts/powershell-scripts/` scripts: where source and
  mapping files live, upsert-on-external-ID, load ordering, dry-run-first.
