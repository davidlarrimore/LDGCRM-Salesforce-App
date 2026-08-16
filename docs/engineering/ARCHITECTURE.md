# Migration pipeline architecture

> **Who this is for:** engineers changing how the migration works — adding an object, altering a
> transform, or working out why the pipeline is built the way it is.
>
> **If you just need to RUN a load, you're in the wrong place.** Go to
> [../../scripts/docs/RUNNING-A-LOAD.md](../../scripts/docs/RUNNING-A-LOAD.md), which assumes no
> prior knowledge of this project.
>
> **New here?** Read [../../scripts/docs/SETUP.md](../../scripts/docs/SETUP.md) first for what this
> project is and how the two systems connect. Then come back.

## ⚠️ `scripts/` is a self-contained bundle (2026-08-14)

Read this before adding a script or a file path anywhere in `scripts/`.

The GSA Salesforce Operations team runs this pipeline from **their own GitHub repository**, where it
lands as a plain `/scripts` folder. Nothing else from this repo goes with it. So `data/`, `logs/`,
`.env`, `.env.example` and the operator runbooks all live *inside* `scripts/`, and every path
resolves off **`Get-LdgcrmRoot`** (`scripts/powershell-scripts/Common.ps1`) — the bundle folder itself.

**`Get-RepoRoot` no longer exists in the bundle.** It was deleted rather than left unused: it would
have kept resolving perfectly well after the folder moved, and quietly returned *Operations'*
repository root. Paths would still join and files would still be written — into someone else's tree.
A missing function fails on the first call instead. It now lives in `tools/Common.Tools.ps1`.

| If your script… | It belongs in | And uses |
| --- | --- | --- |
| reads Airtable, or reads/writes Salesforce | `scripts/` | `Get-LdgcrmRoot` |
| reads `sfdx/` or `docs/` | `tools/` | `Get-RepoRoot` (from `tools/Common.Tools.ps1`) |

`tools/` is also the policy boundary, not just a technical one: metadata moves between orgs by
**change set only**, so Operations has no use for a retrieve or deploy script and shipping them one
would invite exactly what the policy forbids.

Two supporting pieces:

- **`scripts/.gitignore`** is the authority for `data/`, `logs/` and `.env` — deliberately *not*
  duplicated in the root `.gitignore`. Git applies a `.gitignore` to its own directory and below in
  whatever repository contains it, so the PII protection travels with the folder rather than being
  left behind. **Add any new output location there in the same change that creates it.**
- **`tools/Export-OpsBundle.ps1`** builds the hand-off zip. It excludes `.env`, `data/` and `logs/`
  contents (shipping their folders, `.gitkeep`s and READMEs), then **reads the finished archive back**
  and deletes it if anything unexpected is inside — the build and the check can only agree by both
  being right, which is the only way to be sure a credential or a PII extract has not been published
  to a repository this project does not control.

`scripts/powershell-scripts/` holds the scripts that move Login.gov applicant data from Airtable into a
GSA PEO Salesforce org — the Dev sandbox today, QA and a Full sandbox next, production last. See
[Environments and org aliases](#environments-and-org-aliases) for how a script is pointed at one.
The pipeline has four stages that run in order:

1. **Pull** — `Get-AirtableExport.ps1` pulls current data from the Airtable REST API into
   `scripts/data/airtable-exports/<Table>.json`. Already built. See the root `CLAUDE.md` ("Airtable API")
   for auth/connection details.
2. **Prep / transform** — `Build-*.ps1` scripts read the Airtable JSON and the current state of
   `gsa-peo`, and write CSVs into `scripts/data/salesforce-loads/` ready for a Bulk API upsert/update. This
   is what's being built out now (see "Build status" below).
3. **Load** — `Invoke-SalesforceLoad.ps1` wraps `sf data upsert bulk` / `sf data update bulk`
   (Bulk API 2.0) against those CSVs. **Decided 2026-08-12, not the headless Data Loader CLI
   originally planned**: Data Loader CLI isn't installed anywhere in this environment and current
   versions need Java 11+ (this machine only has Java 8), while `sf` is already installed,
   authenticated, and used by every other script in this repo — one fewer tool for whoever ends up
   operating this pipeline (Operations team included) to install and maintain. Both tools sit on the
   same underlying Bulk API and resolve lookups by external ID the same way, so this didn't require
   changing anything about how the `Build-*.ps1` scripts write their CSVs. If there's ever an
   org/compliance reason to switch to literal Data Loader, only `Invoke-SalesforceLoad.ps1` — not the
   transform scripts — would need to change. Built and proven: loaded all 39 Impediment records into
   gsa-peo this way (see `TRANSFORMATION-RULES.md`'s Impediment section for what that first real load
   surfaced).
4. **Notes** — freeform/journal-style Airtable columns that don't belong in a dedicated field become
   `ContentNote` records (Enhanced Notes) attached to their parent record. **Runs last** — a note
   needs its parent to already exist. **Built 2026-08-13**: `Build-NotesLoad.ps1` +
   `Invoke-NotesLoad.ps1`. This is the one chunk that does **not** use the Bulk API — `ContentNote.Content`
   is a binary field that Bulk 2.0 CSV refuses, so it loads over REST
   (`POST /composite/sobjects`), proven end to end against Dev. See `TRANSFORMATION-RULES.md`'s
   "Notes" section.

## Environments and org aliases

Every script takes `-Environment Dev|QA|Full|Prod` (default **Dev**) and resolves the alias from the
registry in [`scripts/powershell-scripts/Common.Orgs.ps1`](../../scripts/powershell-scripts/Common.Orgs.ps1). No script
hard-codes an alias any more.

| `-Environment` | Alias | Sandbox name | Instance URL | Purpose |
| --- | --- | --- | --- | --- |
| `Dev` *(default)* | `peodv8dvn` | PEOdV8DVn | `https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com` | Day-to-day development and pipeline testing |
| `QA` | `peodv15dvn` | PEOdV15DVn | `https://gsa-peo--peodv15dvn.sandbox.my.salesforce.com` | Full end-to-end migration rehearsal |
| `Full` | `peofl2stgp` | PEOfL2STGp | `https://gsa-peo--peofl2stgp.sandbox.my.salesforce.com` | Operations team integration testing — the scripts **and** the change sets, immediately before production. *(Provisioned; not authorized on this machine)* |
| `Prod` | `gsa-peo` | — | *(not authorized on this machine)* | The live GSA PEO org |

**The convention: an alias is the org's own sandbox name.** Chosen 2026-08-13 precisely because an
`sf` alias is a local, mutable pointer that can be repointed by a stray `sf org login web`, and a
name like `dev` gives you no way to notice. `peodv8dvn` can be checked against the instance URL.

### ⚠️ `gsa-peo` changed meaning on 2026-08-13

It used to be this repo's only alias, and it pointed at the **Dev sandbox** — while being the name
of the **production** org. 146 references across 26 files read as though they targeted production
and didn't. Under the new scheme `gsa-peo` means production, so a stale `--target-org gsa-peo` would
be a silent retarget in the dangerous direction. Two things prevent that:

1. Every reference in this repo was updated in the same change.
2. The local `gsa-peo` alias was **deleted**, and production is not authorized on this machine. A
   stale reference fails with "No authorization information found" instead of writing to production.

Don't re-create a `gsa-peo` alias pointing anywhere but production.

### Authorizing a new environment

The alias is always the sandbox's own name. Pass the sandbox's **own My Domain URL** as
`--instance-url` — `https://gsa-peo--<sandboxname>.sandbox.my.salesforce.com` — rather than the
generic `test.salesforce.com`: the browser then lands on exactly the org the alias names, so the
alias can't be attached to the wrong sandbox in the first place. (Production would be
`login.salesforce.com`, and is deliberately not authorized here.) A new sandbox's URL follows the
same pattern; confirm it in the Setup → Sandboxes list or the org's own address bar before using it.

```powershell
# 1. Log in. A browser window opens; use your @gsa.gov.peo.<sandbox> credentials.
sf org login web --alias peodv15dvn --instance-url https://gsa-peo--peodv15dvn.sandbox.my.salesforce.com

# 2. Confirm you landed on the org you meant to. "Instance Url" must match the table above.
sf org display --target-org peodv15dvn
sf data query --target-org peodv15dvn --query "SELECT Name, IsSandbox FROM Organization"

# 3. Prove the registry agrees, before running anything real. This is the same
#    check every script runs at startup, and it fails loudly on a mismatch.
powershell -Command ". ./scripts/powershell-scripts/Common.ps1; Assert-LdgcrmOrgTarget -Environment QA"
```

For the **Full sandbox**, whose name isn't known yet, also fill in `Alias` and `SandboxName` for the
`Full` entry in `Common.Orgs.ps1` — until then every script targeting it stops with a pointer back
to this section rather than falling through to a default org.

### What the startup check actually verifies

`Assert-LdgcrmOrgTarget` runs before any script reads or writes, and stops the run if:

- the alias doesn't resolve or the org is unreachable;
- sandbox/production status disagrees with the registry (`Organization.IsSandbox`, queried from the
  org — `sf org display` doesn't report it, and `sf org list` reads a local cache, which is the very
  thing being verified);
- the instance URL doesn't contain the expected sandbox name, i.e. the alias has been repointed.

An explicit `-OrgAlias` overrides the registry for one-offs, and says so on screen; the identity
checks are skipped in that case, because there's nothing to check it against.

### Production

`Prod` is gated twice on the scripts that can legitimately target it: whatever the script already
asks for (`LOAD`, `BOOTSTRAP`), plus typing the org alias in full at a separate production guard.
Nothing about production is authorized on this machine today, and per the coordination note below, a
production run also needs the Operations team in the loop.

**One script cannot target production at all**: the **Sandbox Factory Reset**. It has no gate for
production because it has no path to production — see the next section.

## Sandbox Factory Reset

`scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1` returns a pre-production sandbox to a known starting
state, so a migration rehearsal begins from the same baseline every time. It does two things in one
run:

1. **Hard-deletes every record this migration created** — scoped to rows carrying
   `LDGCRM_External_ID__c`, in child-before-parent order, exporting the ids first for an audit trail
   and behind a typed `HARD DELETE` confirmation.
2. **Rebuilds the Account universe** by offering to run `Invoke-AccountBootstrap.ps1` against the same
   environment, so the org looks like production before anything is loaded into it. `-BootstrapAccounts`
   answers yes up front; `-SkipBootstrap` suppresses the prompt.

```powershell
powershell -File scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1 -Environment Dev
powershell -File scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1 -Environment QA -BootstrapAccounts
```

### It cannot run against production — by construction, not by policy

A factory reset has no legitimate production use, so production isn't a guarded option; it isn't an
option. Three independent layers, any one of which stops it:

1. **`-Environment` does not accept `Prod`.** The ValidateSet is `Dev|QA|Full`, so PowerShell rejects
   the argument before a line of the script runs. There is deliberately no typed-confirmation path,
   unlike the load scripts which legitimately need one.
2. **The registry is checked.** If the resolved environment is ever marked `IsProduction`, the run
   aborts — catching someone repointing a sandbox key in `Common.Orgs.ps1`.
3. **The org itself is asked.** `Organization.IsSandbox` is read from the target and the run aborts
   unless it's true. This closes the `-OrgAlias` escape hatch, which deliberately bypasses the
   registry's identity checks.

Layer 3 is the one that matters most: an `sf` alias is a local, mutable pointer, so the only
trustworthy statement about what it points at comes from the org on the other end.

### Two things it handles that aren't obvious

- **`OpportunityContactRole` is in the delete list** (added 2026-08-13). It was missing, and the gap
  was easy to miss because those rows cascade away when their Opportunity is deleted — so a *full*
  reset looked complete. A scoped run excluding Opportunity would have left all 515 behind, and
  `Build-OpportunityContactRoleLoad.ps1` diffs against what exists, so the survivors would have
  suppressed the re-insert rather than erroring.
- **Notes are found by walking their parents, and deleted first.** `ContentNote` permits no custom
  fields, so it can't be scoped by external ID like everything else. Worse, deleting a record removes
  its `ContentDocumentLink` but leaves the note orphaned in Files — so ignoring notes would quietly
  accumulate junk across every reset. They're located via the links from records that *do* carry an
  external ID, while those parents still exist to be walked, and scoped to `FileType = 'SNOTE'` so
  genuine uploaded files are never touched.

`LDGCRM_Market_Segment__c` is deliberately **not** reset: all 6 records are correct, three before-save
Flows depend on them, and nothing in the migration recreates them.

## Rebuilding an org's Account tree (the bootstrap)

`Invoke-AccountBootstrap.ps1` rebuilds an org's Account names **and parent hierarchy** from a
production Account export (`scripts/data/prod-accounts/`). It supersedes
`Build-ProdAccountSeed.ps1`, which seeded names only.

**Why any of this is needed:** Account is the one object the migration does *not* create.
`Build-AccountReconciliation.ps1` matches Airtable rows onto Accounts that already exist, because in
production they do. In a cleaned or freshly refreshed sandbox they don't, so every downstream load
has nothing to attach to and a rehearsal proves nothing. The bootstrap supplies that starting
universe.

**Why it takes multiple passes:** `Account.ParentId` is a self-referential lookup and the export
names parents by *name*, so a parent's Salesforce Id doesn't exist until its row has been inserted.
The tree is built outward from the roots — insert, re-query, resolve the next layer — until a pass
changes nothing. Four levels deep in the current export.

```powershell
# Always dry-run first: read-only, writes the pass plan to scripts/logs/data-migration/
powershell scripts/powershell-scripts/Invoke-AccountBootstrap.ps1 -Environment QA -PlanOnly

# Apply it (typed BOOTSTRAP confirmation)
powershell scripts/powershell-scripts/Invoke-AccountBootstrap.ps1 -Environment QA
```

It is idempotent — it inserts only what's missing by name and only ever *fills in* a blank
`ParentId`, never reparents an Account that already has one. `Invoke-SandboxFactoryReset.ps1` offers to run
it automatically once its deletes finish.

### What it refuses to guess

Three findings from the first dry run, all reported to review CSVs rather than resolved:

- **14 Account names are borne by two or more distinct Accounts** in the export ("Office of the
  Inspector General" appears under four departments). A child naming one of those as its parent
  can't be resolved by name, so it is inserted **parentless** and reported — `-StrictHierarchy`
  skips it entirely instead.
- **31 planned rows can't be mapped onto the Dev sandbox's existing Accounts** at all, because the
  earlier name-only seed deduplicated those 14 names down to one record each. There's no way to tell
  which planned Account an existing record represents, so their parents are left unset. An org
  bootstrapped from empty won't have this gap.
- **1 Account is already parented differently** from the export (`U.S. Citizenship And Immigration
  Services`). Existing hierarchy in the target org wins.

### Two traps in the export itself

Both found by checking what the columns contain rather than trusting the headers — the same lesson
as `CLAUDE.md`'s "Not every Airtable column is a simple same-name mapping":

- **The `Account ID` column is not the row's own Account ID.** The same Id appears on completely
  unrelated rows — 378 collisions across 1,369 rows. It's a misaligned report column, and
  `Import-ProdAccountExport` deliberately doesn't return it, so nothing can key off it.
- **`Parent Account` is authoritative; the `Level 1/2/3 Account` columns are not.** They agree on
  1,365 of 1,369 rows, and the 4 exceptions are the interesting ones: 3 rows name themselves as
  their own parent, and 1 depth-4 row's real parent sits below the deepest ancestor column.

**Owner is loaded, on INSERT only** (added 2026-08-13). The export's `Account Owner` is a *display
name*, not an email, so this uses `Resolve-SalesforceOwnerIdsByName` rather than the email resolver.
A display name is a weaker join — not unique, not stable, not an identifier — so it carries the same
active-only and refuse-to-guess-on-duplicates guards, and both fire on this data (`Matthew Taylor`
matches two Users in Dev, `SNA JTScholz` two). An Account that already exists keeps whatever owner it
has; the bootstrap never reassigns one.

Expect a large share to fall back to the loading user anyway: only 5 of the export's 14 owner names
match an *active* User in Dev, and `SNA MSadi` — who owns 607 production Accounts — is inactive
there. That is expected, not a failure. It also means **Contact ownership still can't be meaningfully
demonstrated outside production**, since Contacts inherit their Account's owner (see
`TRANSFORMATION-RULES.md`'s "Record ownership", which also argues that production Account ownership
may not be worth inheriting at all — 92% of it is one service account plus one person).

## Production Account seed (one-time bootstrap, not a pipeline stage)

> **Superseded 2026-08-13** by `Invoke-AccountBootstrap.ps1` (above), which does everything below
> *and* rebuilds the hierarchy. The account of the 2026-08-13 rebuild is kept because the record
> counts elsewhere in these docs refer to it.


`gsa-peo`'s Account data has been a moving target (531 → 588 → growing) and doesn't reliably match
the real universe of production Accounts, which makes testing `Build-AccountReconciliation.ps1`
against it a weak proxy for how the actual production migration will behave. `Build-ProdAccountSeed.ps1`
closes that gap: it parses a real production Account export (`data/PEO PROD Accounts <date>.xls` —
despite the extension, actually an HTML table from a Salesforce report export, not a binary Excel
file) and produces an insert-ready CSV of every production Account name gsa-peo doesn't already have,
Name only (no Owner/Parent Account hierarchy — user-confirmed 2026-08-13, since nothing in this
migration's scripts reads either field). Read-only against Salesforce (two queries: existing Account
names, the Federal RecordTypeId) — writes nothing itself.

This is the first half of a two-phase test the user asked for, to prove out the real production
process end to end:

1. **`Build-ProdAccountSeed.ps1`** → `Invoke-SalesforceLoad.ps1 -Operation Insert` — seed gsa-peo
   with the real production Account names first.
2. **Re-run the existing, unmodified `Build-AccountReconciliation.ps1` → load →
   `Build-PartnerAccountLoad.ps1` → load chain** against that now-realistic baseline. This is exactly
   what the real production reconciliation pass will look like, not a sandbox-only approximation.

**Full rebuild completed 2026-08-13**, after the user asked to first hard-delete the Dev sandbox's
existing test-created Account/Partner Account data (via `scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1`,
then named `cleanup-gsa-peo.ps1`, scoped to just those two objects with its `-ObjectsCsv` override —
see that script's own docs) rather than layer the seed on top of it, for a genuinely clean test:
- Cleanup: 584 of 585 external-ID-tagged Accounts deleted, all 74 external-ID-tagged Partner Accounts
  deleted. One Account (blocked by a pre-existing test `LDGCRM_Application_Contact__c` junction
  record) and all other pre-existing non-external-ID test data were deliberately left alone —
  user-confirmed not to touch pre-existing test data at all, migrate or delete.
- Seed: 1,342 of 1,369 production Account names were missing from the cleaned baseline (up from 786
  before the cleanup, since the earlier run had partial overlap with already-loaded data) — inserted,
  Name only.
- Reconciliation: re-run against the refreshed 1,346-Account baseline matched **587 Accounts** (up
  from 7 before the cleanup+reseed) — a far more realistic number for what the real production
  migration will actually do. 169 still unmatched (see `AIRTABLE-DATA-QUALITY-REQUESTS.md`).
- Partner Account: 74 of 94 loaded successfully (same 20 failures as before the rebuild — all trace
  to Partner Accounts whose parent Account is still among the 169 unmatched, a data-quality gap this
  rebuild couldn't fix on its own).

`Invoke-SalesforceLoad.ps1` gained a third operation for this: `-Operation Insert` (wraps
`sf data import bulk`, a pure insert with no key column — different from `Upsert`/`Update`, which
both need a key column since they're matching against existing records).

## ⚠️ Coordination: two people can load into gsa-peo

Rahul is separately using the **Data Loader GUI** against the same `gsa-peo` sandbox. This
pipeline uses **`sf data upsert bulk`/`sf data update bulk`** (see Stage 3 above for why). Both
write to the same org, so before anyone actually runs a load (GUI or CLI) — even a small test
batch — coordinate first so two loads don't
race each other or double-load the same records. Nothing in this directory automatically loads
anything; every `Build-*.ps1` script here only reads Airtable/Salesforce and writes local CSVs.
Actually loading is always a separate, explicit step behind a typed confirmation —
`Invoke-SalesforceLoad.ps1` for every object bar one, `Invoke-NotesLoad.ps1` for Notes — and should
not happen without that coordination.

**For the full field-by-field mapping rules and every gotcha discovered per object, see
[`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md)** — that's the authoritative detail; this file
covers pipeline architecture, build status, and how to run things.

**Before running a full wipe-and-reload, work through
[`RELOAD-QA-CHECKLIST.md`](../../scripts/docs/RELOAD-QA-CHECKLIST.md)** — the operational runbook: pre-flight, baseline
capture, delete order, the ownership test-batch gate, per-object load verification, and a
side-effect sweep. It exists because ownership is set by the transforms at load time and cannot be
verified any other way.

**For a running list of Airtable data-quality issues that block or would improve the migration —
written for the data owner, not developers — see
[`AIRTABLE-DATA-QUALITY-REQUESTS.md`](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md).** Every `Build-*.ps1`
script's skipped/unmapped review CSVs should feed into this list as they're found, not just sit in
`scripts/logs/data-migration/` unnoticed.

**Stakeholder-facing status reports are generated on demand, not kept.** Write a dated
`docs/migration-load-report-<date>.html` for the Login.gov Partnerships lead when one is asked for,
render the PDF from it with `Export-ReportPdf.ps1`, send the PDF, then delete both when they are
superseded — their numbers go stale within hours, and a stale report in the repo is more likely to be
re-sent by mistake than to be useful. Programme status over time belongs in
[`PRODUCTION-READINESS.md`](../PRODUCTION-READINESS.md), which is maintained rather than
snapshotted.

**Send the PDF, not the HTML.** Google Drive won't render a standalone `.html` file — it displays the
raw markup — so the HTML is only useful opened directly in a browser. Regenerate the PDF with
`tools/Export-ReportPdf.ps1` after editing the HTML; it renders through headless
Chrome and verifies the page count, because a failed render still writes a valid-looking one-page
file.

**It is a point-in-time snapshot, deliberately dated in the filename.** Both Airtable and gsa-peo stay
in active use and these counts have already moved several times within a single day, so don't edit
this file to "refresh" it — generate a new dated report and leave the old one as the record of what
was true when it was sent. The figures in it were taken from the sandbox on 2026-08-13 against the
Airtable pull of 2026-08-12.

## Conventions

- **Upsert on `LDGCRM_External_ID__c`**, not insert, for every object *except* Account (see
  below) — the Airtable record's `rec...` ID becomes the Salesforce record's external ID, which is
  what keeps re-running a load idempotent and what lets child records reference parents without
  the transform scripts having to resolve real Salesforce IDs themselves. Cross-object lookups
  (e.g. Application → Partner Account) are written to CSV as the parent's Airtable `rec...` ID and
  resolved at load time by the Data Loader field mapping (`ParentObject:LDGCRM_External_ID__c`),
  not pre-resolved by the transform script. This only works once the parent object's external ID
  is reliably populated — which is why load order matters (see below).
- **Account is the exception.** Accounts already exist in Salesforce independently of this
  migration (they aren't being created by it), and in production most don't yet carry
  `LDGCRM_External_ID__c`. So there's no reliable external ID to upsert against yet — the
  reconciliation script (`Build-AccountReconciliation.ps1`) resolves each Airtable Account row to
  a real Salesforce `Id` itself (external-ID match first, then exact `Name` match) and produces an
  **update** file keyed on `Id`, not an upsert file keyed on external ID. Rows it can't confidently
  match are written to a review CSV instead of guessed at — see `CLAUDE.md`'s note on the
  `Depart of Homeland Security` typo case for why. Once this backfill lands, every other object's
  lookup *back to* Account can use the normal external-ID passthrough. The same script also backfills
  the standard `Type` field from Airtable's `States + DC/PR` checkbox (`"State"` if checked, else
  `"Federal"`) — a column whose name doesn't describe what it actually maps to; see `CLAUDE.md`'s
  "Not every Airtable column is a simple same-name mapping" note before assuming any other table's
  columns map 1:1 by name.
- **Windows PowerShell 5.1**, same as every other script in this repo — no `??`, `?.`, ternary
  `?:`, `ConvertFrom-Json -Depth` (that flag is PS6+ only; 5.1's default max depth of 100 is fine
  here), or `-AsHashtable`.
- **Every CSV handed to the Bulk API is UTF-8 without a BOM — including DELETE files.**
  `Export-DataLoaderCsv` in `Common.DataMigration.ps1` writes this way deliberately: PowerShell
  5.1's `Export-Csv -Encoding UTF8` always adds a BOM, and the Bulk API reads those three bytes as
  the start of an unquoted first field, hits the opening quote of `"Id"`, and fails the **whole job**
  with:

  ```
  InvalidBatch : Failed to parse CSV. Found unescaped quote. A value with quote should be within a quote
  ```

  **That message names neither the BOM nor the encoding**, which is what makes it expensive — it
  cost a failed Sandbox Factory Reset on 2026-08-13, when the note-deletion step (the one hand-built
  CSV in a script whose other delete files all come from `sf data export bulk`, which emits no BOM)
  used plain `Export-Csv`. If a Bulk job dies on an unescaped quote, check the first three bytes for
  `EF BB BF` before looking at the data.

  Files meant for **human review** (unmatched/ambiguous-row reports, audit summaries) still use plain
  `Export-Csv -Encoding UTF8` — the BOM there is harmless and helps Excel detect UTF-8 correctly.
- **Record ownership is set by the transforms, not by a backfill script** (decided 2026-08-13). Each
  object takes its owner from its own Airtable source where that person has an **active** Salesforce
  User, and otherwise falls back to a **named** owner — `peter.marks@gsa.gov`, overridable per run
  with `-FallbackOwnerEmail`. The fallback is resolved to a real User Id at run time and written
  **explicitly**, never left blank. Two shared resolvers in `Common.DataMigration.ps1` do the work:
  `Resolve-SalesforceOwnerIds` (email → active User) and `Resolve-FallbackOwnerId`, which **throws**
  rather than degrading if the address doesn't match an active User.
  **This reversed an earlier design, and the earlier rationale no longer applies.** The first version
  left `OwnerId` blank so Bulk API 2.0 would read it as "not supplied" — which handed the record to
  whoever ran the load, and left a manual reassignment alone on a re-run. That was correct only while
  the loading user *was* the intended owner; it stopped being true once it was confirmed that GSA IT
  Operations runs the production load. The cost of the reversal is real and worth knowing before
  anyone reports it as a bug: **a re-run re-asserts the fallback owner**, so a fallback-owned record
  that someone manually reassigns gets pushed back. Per-object sources, coverage, the three silent
  resolution traps, and the full rationale are in
  [`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md)'s "Record ownership" section.
- **Every write is gated by a typed token, which can also be passed as a flag.** Interactive by
  default; non-interactive by supplying the same token the prompt asks for — `-Confirmation "LOAD"`,
  `"HARD DELETE"`, `"BOOTSTRAP"`. That makes the pipeline runnable by CI, an agent, or the Operations
  team without weakening the gate: a token states *what* is being approved, where a `-Force` switch
  would read the same on every command and travel between them by habit. Comparison is
  case-sensitive, and every non-interactive approval prints an audit banner into the run transcript.
  Production needs a second, separate token (`-ProductionConfirmation <alias>`) so a sandbox
  automation can't be retargeted at production by changing `-Environment` alone.
- **Dry run before a full load**, per `sfdx-sandbox-ops` — export/preflight-count before writing,
  small batch before the full object, explicit confirmation before anything destructive or
  hard-to-reverse.

## Files

| File | Stage | Status |
| --- | --- | --- |
| `Get-AirtableExport.ps1` | Pull | Built. **Ten tables as of 2026-08-13** — `Issuer Strings` was added by PR #1 and is the only source of the partner-portal Team Name / Team UUID and of the Partner Portal Admin email. An export missing it makes `Build-ApplicationLoad.ps1` fail outright and silently halves the admin flags on the junction. |
| `Common.DataMigration.ps1` | shared helpers (Airtable JSON loading, Data Loader CSV writing, read-only SOQL, owner email → User resolution) | Built |
| `Build-MarketSegmentLoad.ps1` | Prep — Market Segment. **STEP 1 of the load** | Built 2026-08-14. 7 Airtable rows → 5 loaded, 2 skipped for having no Name. Added because Market Segment was the one object the pipeline **required but refused to load** — pre-flight hard-failed on a count of zero while no transform created the records. That produced a live defect in QA, which held all five segments with the right names and **no external IDs**: the Account reconciliation resolves a segment through `LDGCRM_Market_Segment__r.LDGCRM_External_ID__c`, so it would have matched nothing and left Market Segment blank across the whole migration, silently. ⚠️ **The external ID is the segment NAME**, not the Airtable `rec...` ID — the one deliberate exception to the repo convention; the transform hard-fails if two rows share a name. |
| `Build-AccountReconciliation.ps1` | Prep — Account (update, not upsert) | Built |
| `Build-ImpedimentLoad.ps1` | Prep — Impediment (independent parent, straight upsert) | Built |
| `Build-PartnerAccountLoad.ps1` | Prep — Partner Account (Master-Detail to Account, requires Account loaded first) | Built |
| `Build-OpportunityLoad.ps1` | Prep — Opportunity (needs Account **and Partner Account** loaded first) | Built and **loaded 2026-08-13: 742/742 succeeded**, including the `LDGCRM_Partner_Account__c` lookup (66 linked). Required a Login_gov record-type picklist fix found by a test batch (see `TRANSFORMATION-RULES.md`) and an `LDGCRM_App_Description__c` LongTextArea deploy. 186 rows withheld (142 unreconciled Accounts, 28 no Status, 16 no Account link). **Ownership added 2026-08-13** (`Pod Opportunity Lead` → `OwnerId`): 476 of 742 resolve, 266 fall back — needs a reload to take effect. |
| `Build-ContactLoad.ps1` | Prep — Contact (independent parent; optional Account/Partner Account lookups) | Built and **loaded 2026-08-13: 1,483 of 1,487** (4 rejected by an org duplicate rule). **Merges rows sharing an email** (1,599 → 1,532) since Airtable lacks a person↔Application junction; also emits `Contact-identity-map.csv` for the junction chunk. Loaded with `-DisableTriggerControl "Contact"` — see "Loading Contact" below. **Ownership added 2026-08-13** (inherits the Account's owner), but it cannot be demonstrated in gsa-peo — the Account seed is Name-only, so nearly every Account is owned by the loading user. |
| `Build-ApplicationLoad.ps1` | Prep — Application, needs Partner Account **and Opportunity** loaded first (see "Load order") | Built and **loaded 2026-08-13: 688/688 succeeded, 0 failures**. Took three attempts — the first failed 1,045 of 1,047 rows — which drove six fixes (Service Level array unwrap, Broker App Parent moved to a second pass, Name/URL platform-limit handling across *all* Url fields, out-of-range date check, live Partner Account/Opportunity preflight, plus an `Invoke-SalesforceQuery` array bug). 359 rows remain skipped pending Airtable Account fixes; 92 Opportunity links pending the Opportunity load. See `TRANSFORMATION-RULES.md`'s Application section for the full 55-field mapping and the failure post-mortem. **Ownership added 2026-08-13** (inherits its Partner Account's owner, *not* Airtable's rollup `Account Owner`): 511 of 688 resolve. **Partner portal team added 2026-08-13** from the new Issuer Strings table — 696 of 887 Applications resolve to one team, 9 name two and are left blank + reported. ⚠️ **Both columns are currently WITHHELD from the load**: they are `unique=true` in the org, which 442 of the 696 would violate (one portal team owns many Applications), so the script reads the live field definitions and omits the columns rather than failing most of the load. **Needs a change set setting `Unique = false` on both**, then a plain re-run. Re-baselined against the re-pulled export: **689 ready, 360/329 ownership**. |
| `Build-ApplicationContactLoad.ps1` | Prep — Application↔Contact junction (needs Application + Contact loaded) | Built and **loaded 2026-08-13: 1,880/1,880**; re-baselined after the re-pull to **1,779 ready / 573 admin flags**. Uses a **composite external ID** (`<contact>\|<application>`) so uniqueness is structural — the object's duplicate-check Flow throws on duplicates *and* misses intra-batch ones. **Partner Portal Admin has TWO sources as of 2026-08-13**, UNIONed: `Contacts.Roles` and Issuer Strings' `Partner Portal Admin Email` (matched by email). They agree on 882; Roles-only 117, Issuer-Strings-only **86 — and none of those 86 had a junction row at all**, so that source *creates associations*, it doesn't just set a flag. Provenance per flag in `ApplicationContact-admin-source-*.csv`. |
| `Build-OpportunityImpedimentLoad.ps1` | Prep — Impediment↔Opportunity junction (two Master-Details, both required) | Built and **loaded 2026-08-13: 267/267**. Composite external ID; severity comes from *which* Airtable column an Opportunity appears in. **Excludes the placeholder Impediment named "None"** (465 links, 53% of the loadable set) — see `TRANSFORMATION-RULES.md`. 44 pairs pending an unloaded Opportunity. |
| `Build-OpportunityContactRoleLoad.ps1` | Prep — OpportunityContactRole. **The one object that cannot be upserted** | Built and **loaded 2026-08-13: 515 rows**. The previously-documented `externalId=true` fix is **impossible** — Salesforce forbids External ID fields on this object entirely — so it uses an INSERT + read-then-diff for idempotency instead. Extended the `ContactRole` StandardValueSet with 2 new Role values. 83 rows skipped pending an unresolved Opportunity/Contact. |
| `Build-MeetingLoad.ps1` | Prep — Activity/Event | **Not built, and the approach changed 2026-08-13.** Airtable holds a date but no time, and synthesizing one fabricates scheduling history. Instead: stand up **Einstein Activity Capture**, let real calendar events sync, and fuzzy-match Airtable's meetings onto them (date + organizer + attendee overlap + subject), enriching the real event rather than inventing one. Depends on org configuration outside this repo and an unresolved spike — see `BACKLOG.md` §2. |
| `Invoke-SalesforceLoad.ps1` | Load — generic `sf data upsert bulk`/`sf data update bulk` wrapper, any object | Built. Classifies each row failure against that object's `-ExpectedFailurePatterns` and exits **2** for an expected partial. **`-StepResultPath` (added 2026-08-13)** additionally writes that classification, the counts and the job id as JSON, because it runs as a child process and an exit code carries three states — which is why the orchestrator's summary could say "PARTIAL" but never how many or why. Written in a `finally`, so a step that throws still reports. |
| `Invoke-FullMigrationLoad.ps1` | Load — the orchestrator. Runs every transform and load in dependency order as one operation | Built. Pre-flight → restore point → sequence → post-load validation → **run report**. `-PlanOnly` runs every transform and loads nothing (read-only, doubles as the readiness check); `-StartAtStep`/`-OnlySteps` resume. Stops at the first real failure, because everything downstream would silently withhold rows. **Pre-flight asserts the nine LDGCRM Flows are ACTIVE (added 2026-08-14) and blocks if not** — see below. `-ActivateFlows` switches on whatever is off (sandbox only, rejected for `Prod`). |
| `Common.LoadReport.ps1` | Load — builds the per-run report (`SUMMARY.txt` + `load-summary.csv`/`errors.csv`/`findings.csv`) | Built 2026-08-13. See "Reading a run" below. |
| `Build-NotesLoad.ps1` | Notes — prep `ContentNote`/`ContentDocumentLink` for freeform columns, last chunk | Built 2026-08-13. ~537 notes ready; ~59 placeholder values (`None`/`N/A`) skipped, ~200 waiting on a parent the Account data-quality issue withheld. Diffs against what is already attached, which is what makes a re-run safe. |
| `Invoke-NotesLoad.ps1` | Notes — load. **The one chunk with its own loader**, not `Invoke-SalesforceLoad.ps1` | Built 2026-08-13. Attaching a note is three steps against two objects (insert `ContentNote` → read back each `ContentDocumentId` → insert `ContentDocumentLink`), and `ContentNote` has no external ID, so created note Ids are written to disk before anything else is attempted. Has an access preflight for the org's unmanaged `ContentDocumentLinkTrigger`, whose kill switch is inert. |
| `tools/Build-ProdAccountSeed.ps1` | Bootstrap — production Account **name** seeding, not a regular pipeline chunk | **Superseded 2026-08-13** by `Invoke-AccountBootstrap.ps1`, and **moved to `tools/` on 2026-08-14** — kept for provenance, not shipped to Operations. Still runs (now via the shared parser). Its name-dedupe is what left 31 rows unmappable for the hierarchy pass — see "Rebuilding an org's Account tree". |
| `Invoke-MigrationRollback.ps1` | Rollback — undo ONE `Invoke-FullMigrationLoad.ps1` run from its restore point | Built 2026-08-13. Takes a `full-load-<ts>/` run directory, not a list of objects. Deletes only what that run *created* — external IDs tagged in the org now minus those tagged before the run, measured on both sides rather than read from the load CSVs — and **restores** the Account pre-image rather than deleting, because the migration updates Accounts it does not own. Refuses to run against a run directory with no `external-ids/` folder, and stops if the org has drifted from that run's post-load counts (`-IgnoreDrift` overrides). Typed `ROLLBACK` gate. **A best-effort tidy-up, not a safety net** — see `BACKLOG.md` §4a for what it can never undo. |
| `Invoke-AccountBootstrap.ps1` | Bootstrap — production Account **names + parent hierarchy**, multi-pass. **Dev/QA only as of 2026-08-14** | Built 2026-08-13. `-Environment` is now `Dev\|QA` — Full and Prod are rejected at parameter-bind time, because a Full sandbox is a copy of production whose Accounts are the real records the migration reconciles onto. `-ProductionConfirmation` was removed with them. Source export moved to `scripts/data/prod-accounts/` and its **format is sniffed, not assumed** — HTML-table-`.xls`, real `.xlsx` (read via `System.IO.Compression`, no Excel needed), or `.csv`. |

## Load order

Parents before children/junctions (the reverse of the delete order in
`scripts/powershell-scripts/Invoke-SandboxFactoryReset.ps1`). In an org that has just been cleaned or refreshed, the
Account step means running `Invoke-AccountBootstrap.ps1` first — reconciliation has nothing to match
against otherwise:

```
Market Segment (STEP 1 - Build-MarketSegmentLoad.ps1)
  -> Account (reconciliation/backfill, not create - see Build-AccountReconciliation.ps1)
  -> LDGCRM_Partner_Account__c
  -> Contact
  -> Opportunity
  -> LDGCRM_application__c
  -> LDGCRM_application__c SECOND PASS (Broker App Parent self-lookup only - see below)
  -> LDGCRM_Opportunity_Impediment__c (needs LDGCRM_Impediment__c + Opportunity first)
  -> LDGCRM_Application_Contact__c
  -> OpportunityContactRole (blocked, see above)
  -> Activity / Meetings  [DEFERRED - depends on Einstein Activity Capture, see BACKLOG.md 2]
```

**Opportunity must be loaded before Application** — this is a real ordering dependency, not just a
nice-to-have, even though `LDGCRM_Opportunity__c` is an *optional* lookup on Application. Confirmed
empirically by the first real Application load (2026-08-13): 99 Application rows failed outright with
`INVALID_FIELD: Foreign key external ID ... not found ... in entity Opportunity` because they carry an
`Opportunity Record ID` pointing at an Opportunity that doesn't exist in gsa-peo yet. Bulk API rejects
the **whole row**, not just the unresolvable lookup — "optional field" means "may be blank," not "may
reference something nonexistent." Loading Application before Opportunity therefore silently costs you
every row that has an Opportunity link.

**`LDGCRM_Broker_App_Parent__c` needs a second pass over Application, after the main load.** This is a
self-referential lookup (Application → Application) resolved by external ID. `TRANSFORMATION-RULES.md`
originally guessed Bulk API might resolve these within a single upsert batch since the parent row is
in the same file — **it does not**: the same 2026-08-13 load failed 68 rows with `Foreign key external
ID ... not found ... in entity LDGCRM_application__c`, referencing parent Applications that were
present in the very same CSV. `Build-ApplicationLoad.ps1` therefore keeps this column out of the main
file and **writes a separate second-pass file automatically** (built 2026-08-13):
`scripts/data/salesforce-loads/LDGCRM_application__c-broker-parent-upsert.csv`, carrying just
`LDGCRM_External_ID__c` + `LDGCRM_Broker_App_Parent__r.LDGCRM_External_ID__c`.

**There is no second transform script to run** — that was the point. Only the *load* is a separate
step, and it must come after the main Application load; the transform prints the exact command when
it finishes. A link is emitted only when both sides will exist once the main load completes (the
planned set plus whatever is already in the org), so a re-run picks up newly-resolvable links with no
code change.

### ⚠️ The second pass creates nothing, and the step name says so

The orchestrator step is called **`PopulateBrokerParent`**. It was `BrokerParent` until 2026-08-13,
which read as "load the broker parents" and drew exactly the objection it deserved: *surely parents
have to be loaded before their children?*

They do — and they are. **A broker parent IS an ordinary Application**, created by the Application
step along with everything else; nothing distinguishes it in the data except that another Application
points at it. So both ends of the relationship are created in one job, and the second pass is a
**2-column update** on the *child*:

```
LDGCRM_External_ID__c , LDGCRM_Broker_App_Parent__r.LDGCRM_External_ID__c
```

The general rule — parents before children — applies to *cross-object* dependencies (Account →
Partner Account → Application), where there genuinely is an earlier step to put the parent in. It
cannot apply to a self-reference: parent and child come from the same Airtable table, the same
transform and the same CSV, so "load the parents first" and "load the children first" are the same
operation. What must be deferred is only the **pointer**, because Bulk resolves an external-ID
lookup against *committed* org state, not against rows in its own in-flight batch — and Bulk 2.0
does not guarantee row order, so sorting the file topologically would not help either.

Verified on the 2026-08-13 reload: 64 links set, 0 unresolved, 0 self-references, 0 cycles, deepest
chain 1, and Application totals identical before and after the pass (1,026 → 1,026) — the proof that
it inserts nothing.

Current state: 70 Airtable rows carry a Broker App Parent → **63 ready**, 6 waiting on an Application
withheld by the Account data-quality issue, 1 dropped as a **self-reference** (one Application lists
itself as its own parent; the script drops that single link and records it in the review CSV — the
record migrates normally otherwise, nothing else is affected, and it is deliberately *not* raised as
a data-quality ask). No cycles, and the deepest chain is 1,
so no multi-pass hierarchy walk is needed here — unlike `Invoke-AccountBootstrap.ps1`, which goes four
levels deep.

General rule for any future self-referential lookup in this pipeline: it always needs its own second
pass, and that pass should be generated by the same script rather than left to a human to remember.

## Reading a run

**Everything one run produces goes in one directory**, `logs/<category>/<ScriptName>-<timestamp>/`,
and `Invoke-FullMigrationLoad.ps1` writes **`SUMMARY.txt`** into it and prints it at the end of the
transcript. That is the one artifact answering "how did the load go, and was anything in it new?".
`scripts/logs/README.md` describes the file layout; this section covers why it is built the way it is.

### One directory per run (2026-08-13)

Each script used to write its transcript and review CSVs loose into `logs/<category>/` **and** create
its own typed folder — `full-load-<ts>/`, `notes-load-<ts>/`, `bulk-results/<obj>-<ts>/`,
`rollback-<ts>/`, `account-bootstrap-<ts>/`. One logical load therefore scattered output across four
folder shapes plus ~30 loose files, correlated only by a timestamp — and since **each child script
stamped its own**, the timestamps didn't even match. `scripts/logs/data-migration/` reached 330 loose CSVs
across ~40 runs.

The mechanism is deliberately one small change in `Common.ps1` rather than an edit to every script:

- `Start-ScriptLog` creates the run directory and publishes it in `$env:LDGCRM_RUN_DIRECTORY`.
- `Get-LogDirectory` returns that whenever it is set, so **every existing caller redirects into it
  unchanged**.
- Child processes inherit the variable — which is what makes an orchestrated load land in one folder
  while each step still keeps its own transcript. The orchestrator runs steps as child processes
  precisely so a failing step cannot take down its own log.
- The variable is process-scoped, so it cannot leak into an unrelated shell, and running any script
  standalone still gets its own run directory.
- `Get-LogCategoryDirectory` is the escape hatch for the few things that are genuinely *about* the
  set of runs — finding the previous run to compare against.

**Every file in a run now shares one timestamp**, taken from the folder name rather than the clock at
the moment each child started.

Two contracts changed with it, both kept backward compatible:

- `external-ids/<Object>.csv` became `external-ids-<Object>.csv`. `Invoke-MigrationRollback.ps1`
  accepts **both**, so a run directory written before this change can still be rolled back.
- Bulk failure rows are renamed from the CLI's job-id-only name to
  `<object>-<jobid>-failed-records.csv`. The job id is kept deliberately: it is what
  `sf data bulk results` needs to fetch them again, **and** it keeps two steps that load the same
  object apart — Application and PopulateBrokerParent both write `LDGCRM_application__c`, so a label-only
  name would have the second silently overwrite the first.

### The problem it solves: a withheld row is not an error

Every step reports success or failure per *submitted* row. But each transform **withholds** rows
before submitting anything — a Contact with no resolvable Account, an Application whose Partner
Account isn't loaded, a junction row whose other side was itself withheld. Those rows are never sent,
so the Bulk API has nothing to say about them, the step is recorded as a clean success, and the
records are simply absent from the CRM.

On the 2026-08-13 reload that was **31 rows failed against several hundred withheld**. The failures
were visible in three places; the withholdings were in twenty separate review CSVs and no summary.
`SUMMARY.txt` puts both in one table and labels the distinction explicitly.

### Findings are attributed to a step by TIME, not by file name

Transforms name their review CSVs inconsistently (`Contact-no-account-*`,
`ApplicationContact-skipped-*`, `Account-reconciliation-unmatched-*`) and each child script stamps
its own timestamp from its own `Start-ScriptLog` — so the orchestrator's timestamp never appears in
them and cannot be matched on. What the orchestrator *does* know exactly is when each step started
and finished, and steps run strictly in sequence.

This is why the feature needed **no changes to any transform**. They already write everything; the
report only had to collect it.

### Expected vs unexpected: two different mechanisms

| | Decided by | Where |
| --- | --- | --- |
| **A row failure** is expected | matching that object's `ExpectedFailurePatterns` | `$Steps` table → `Invoke-SalesforceLoad.ps1` |
| **A count** is expected | comparing with the previous run | `Common.LoadReport.ps1` |

The second is deliberately a **comparison, not a declared list**. A hard-coded expected count is
wrong the moment Airtable is fixed — nine data-quality items closed in a single day — and the
pipeline has already learned that a check which cries wolf every run is one nobody reads (see the
FCIC junk-Account delta in `Save-RestorePoint`). Each run writes `findings.csv`/`errors.csv` and the
next run diffs against the most recent earlier one, so it re-baselines itself.

Three consequences that are design decisions rather than omissions:

- **A cause that stopped firing is listed**, under "gone since the last run" — otherwise "we fixed
  it" and "the check stopped running" are indistinguishable.
- **An empty review CSV is reported at zero**, not skipped, for the same reason.
- **No previous run means no deltas**, stated as such. Everything reading `(NEW)` on a first run
  would be noise.

### It is written on every path, and it can never fail a load

A run that stopped at step four is exactly the run whose report is worth reading — it shows what the
first three steps withheld, which is usually *why* step four failed. So the report is written after a
failure too, before the non-zero exit.

Conversely `Write-LoadRunReport` is called inside a `try`, and a failure there degrades to a thinner
report and a warning. Reporting must never be able to change the outcome of a load, and post-load
validation — not this — remains the thing that decides whether a run passed.

## ⚠️ Pre-flight: the nine Flows must be ACTIVE (added 2026-08-14)

`Invoke-PreflightChecks` (in `Invoke-FullMigrationLoad.ps1`) asserts that all nine LDGCRM Flows exist
and are active in the target org, and **blocks the run** if not. It is the last check added and the
most consequential.

### The run that caused it

QA was loaded on 2026-08-14: **8,740 records, zero unexpected failures**, with every LDGCRM Flow in
that org inactive. Nothing failed. Nothing was withheld. Every object count matched Dev, so the
Dev-vs-QA comparison in `RELOAD-QA-CHECKLIST.md` passed as well.

What was actually wrong: three before-save Flows derive `LDGCRM_Market_Segment__c` from the parent
Account, so it was blank on all 92 Partner Accounts, all 842 Opportunities and all 1,026
Applications — 100% of the migrated records on those objects, with the parent chain fully resolvable
in every case.

**Flow activation changes field contents, not row counts.** That is what made it invisible: there is
no count anywhere in this pipeline that would have moved. The tell was that Account — the one object
in the chain whose Market Segment the pipeline writes *directly*, in `Build-AccountReconciliation.ps1`
— was 587/587 populated, while all three flow-driven objects were 0%. The field was correct exactly
where a script wrote it and empty exactly where a Flow was supposed to.

### The three checks

| Check | Blocks on |
| --- | --- |
| Expected flows present and active | any of the nine absent, or present and switched off |
| **Dev-only flows absent** | `LDGCRM_Screen_Flow_Developer_Data_Delete_Flow` found in QA/Full/Prod |
| Active version behind latest **in the same org** | a newer version deployed but never switched on |

The second is deliberately an *inversion* — that screen flow bulk-deletes migrated records, and its
absence outside Dev is the expected state, so finding it is a failure rather than a suppressed note.
Before this check, the only thing keeping it out of a non-Dev org was someone hand-picking change set
contents.

### ⚠️ Flow version numbers are PER-ORG and are not comparable across orgs

A Flow's `VersionNumber` is a local counter: every save in the source org increments that org's
sequence, and every change set deployment increments the target's independently. Dev on v4 while QA
is on v2 is the ordinary result of four saves there and two deployments here — **not** evidence that
QA is behind. An earlier version of this check asserted otherwise and was wrong (corrected by the
project owner, 2026-08-14).

The only meaningful comparison is **within one org**: active version vs latest version. That is what
the stale check uses, and it is the one form of drift visible from inside a single org. Whether the
active version carries the *intended logic* is a change-set question the bundle cannot answer — it
has no access to `sfdx/`.

### What it may and may not fix

`-ActivateFlows` switches on whatever is off. This is allowed because it flips an **org setting**
(`FlowDefinition.Metadata.activeVersionNumber`) pointing at a version already in the org — it moves
no XML and creates no component, so it stays on the right side of the change-set rule. Per the
project owner (2026-08-14): *"There is a difference between changing settings in the org via CLI and
adding/updating core object definitions. We want change sets to migrate all xml, but allow for our
pre-flight script to prep and validate the environment for a successful load."*

It is **sandbox only** — rejected for `-Environment Prod`, the same structural block
`-BootstrapAccounts` uses. Pre-flight still reports on Prod, because that report is read-only and is
exactly what you want before a production load.

Two properties that differ from the other switch this pipeline flips:

- **Nothing is restored.** `Invoke-SalesforceLoad.ps1`'s `TriggerControls__c` bypass captures, flips
  and restores in a `finally`. This does not, on purpose: a Flow that had to be on for the load to be
  correct must stay on, or the org resumes producing wrong data for every record created in the UI.
- **It cannot create a Flow.** ABSENT, or present with no versions, needs a change set. The pipeline
  says so precisely and stops.

Implemented by `Get-LdgcrmFlowState` / `Set-LdgcrmFlowActiveVersion`, which PATCH the Tooling API over
`sf api request rest` — `Metadata` is a compound field, so `sf data update record --values` cannot
express it. A successful PATCH returns **204 No Content**, so an empty response is the success case
here, the opposite of every other call in this repo. The write is followed by a verifying re-query,
the same principle as the `TriggerControls__c` restore.

## ⚠️ Pre-flight: the Contact duplicate rule must be OFF (added 2026-08-15)

Check 8 in `Invoke-PreflightChecks`. `OTCRM_Contact_Duplicate` matches Contacts on **first + last
name only**, both `Exact`. It **blocks the run** in every environment, Prod included.

The failure it guards has the same shape as the inactive-Flows one, which is why it is blocking
rather than a warning: the Contact step **does not fail**. It reports success having dropped the
rejected rows, and every junction keyed on those Contacts is short by the same people. One Dev run
lost **167 Contacts** this way.

### The pipeline switches them off itself — via a same-org metadata round-trip

`Disable-LdgcrmContactDuplicateRules` runs inside pre-flight, in **every environment including
Prod** (project owner, 2026-08-15). Unlike `-ActivateFlows` there is no sandbox-only gate: the rules
block the Contact load identically everywhere and the decision is that they stay off everywhere, so
making Prod the one org needing a remembered manual step is how a production load acquires a silent
167-record hole.

**Why it is a Metadata API deploy and not a PATCH.** Flow activation gets to be a one-field PATCH
because `FlowDefinition` exposes a `Metadata` compound field. Neither rule here does:

| Object | Why there is no record-level write |
| --- | --- |
| `DuplicateRule` | Not a Tooling API object at all (`INVALID_TYPE`); on the standard API `IsActive` is `updateable=false` |
| `MatchingRule` | Readable in Tooling, but has **no `Metadata` field**, so there is nothing for the `FlowDefinition`-style PATCH to bind to |

So it retrieves the rule **from the target org**, changes one element, and deploys it **back to that
same org**. No XML crosses an org boundary, no component is created, no definition changes — the
rule's own retrieved body is what goes back. That is the `-ActivateFlows` category, and CLAUDE.md's
metadata table carries the carve-out explicitly: **round-trip-to-same-org and status-only**.

### Four mechanics that are not obvious

1. **The retrieve needs no SFDX project.** `--target-metadata-dir` works from any directory — which
   is what lets this live in the bundle at all, since `scripts/` has no `sfdx-project.json` and must
   never reach up to the repo's `sfdx/`.
2. **`DuplicateRule` members must be object-qualified** (`Contact.OTCRM_Contact_Duplicate`). An
   unqualified name fails with *"Need to specify full name, Required Delimiter: ."* while the
   retrieve still reports `Succeeded` — so the failure is in `messages`, not in the status.
3. **`--unzip` nests the payload** (`unpackaged/unpackaged/…`), so `package.xml` is located by
   search rather than by an assumed path.
4. **`MatchingRules` is a per-object container file** — one `Contact.matchingRule` holds every
   Contact matching rule. A targeted retrieve returns only the requested rules and the same file
   goes back, keeping it a round-trip of the org's own content.

**Order is not negotiable:** a matching rule cannot be deactivated while an active duplicate rule
consumes it, so duplicate rules always go first. The matching-rule pass is **non-fatal by design** —
once no active duplicate rule consumes it a matching rule enforces nothing, so the load is already
safe after the first pass, and failing a production load over a cosmetic tidy-up would be the wrong
trade.

**The decision to proceed rests on a verifying re-query, never on the deploy's own success report** —
the same principle as the flow activation and the `TriggerControls__c` restore. CLAUDE.md records a
deploy that reported "Succeeded" having deployed 0 components, so `Invoke-LdgcrmRuleDeploy` checks
`numberComponentErrors` and `numberComponentsDeployed` too.

### Why it is not promoted by change set either

The obvious fix — add `Email` to the matching rule — was built and verified in Dev, then abandoned as
a promotion path. A change set cannot carry a matching-rule change at all:

| Target state | Error |
| --- | --- |
| Rule **Active** | *"Before you change a matching rule, you must deactivate it."* |
| Rule **Inactive** | *"Change the matching rule status separately from other changes."* |

A change set always uploads the **source org's** status and gives you no way to edit the XML, so it
necessarily attempts a definition change and a status change in one deployment. No target state
passes. Both rules were removed from the change set and are deactivated by hand in Setup instead.

### It stays off

Unlike `TriggerControls__c`, **nothing restores it**. Do not add a `finally` that puts it back — a
rule switched off for the load must stay off, or the next load switches it off again and the org
oscillates. The pipeline blocks only when a rule is *still active* after it has tried.

An active *matching* rule with no active duplicate rule consuming it is inert, so that case warns
rather than blocks.

These are TTS OTCRM's rules, not this app's — but **TTS OTCRM is defunct** (project owner,
2026-08-15) and its metadata will eventually be removed wholesale, so there is no owning team to
clear this with and no live users behind the rule. Deactivating it is the same action in Prod as in a
sandbox. That wholesale removal is a separate future exercise and not this migration's job.

## Running what's built so far

```powershell
# From the repo root:
scripts\powershell-scripts\Get-AirtableExport.ps1
scripts\powershell-scripts\Build-AccountReconciliation.ps1
scripts\powershell-scripts\Build-ImpedimentLoad.ps1
scripts\powershell-scripts\Build-PartnerAccountLoad.ps1
scripts\powershell-scripts\Build-OpportunityLoad.ps1
scripts\powershell-scripts\Build-ContactLoad.ps1
scripts\powershell-scripts\Build-ApplicationLoad.ps1
scripts\powershell-scripts\Build-ApplicationContactLoad.ps1
scripts\powershell-scripts\Build-OpportunityImpedimentLoad.ps1

# Actually load a prepped CSV into gsa-peo (prompts "Type LOAD to continue"):
scripts\powershell-scripts\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_Impediment__c" `
    -CsvFile "data\salesforce-loads\LDGCRM_Impediment__c-upsert.csv"

# Account uses -Operation Update (Id-keyed) instead of the Upsert default:
scripts\powershell-scripts\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "Account" `
    -CsvFile "data\salesforce-loads\Account-update.csv" `
    -Operation Update

# Partner Account is Master-Detail to Account - load Account first, or its
# parent lookup won't resolve:
scripts\powershell-scripts\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_Partner_Account__c" `
    -CsvFile "data\salesforce-loads\LDGCRM_Partner_Account__c-upsert.csv"

# Application needs Partner Account loaded (required lookup) and ideally
# Opportunity too - see "Load order". Build-ApplicationLoad.ps1 queries the org
# first and skips rows whose parent doesn't exist yet, so it's safe to run at
# any point; re-run it after fixing Airtable data or loading Opportunity to
# pick up whatever newly resolves:
scripts\powershell-scripts\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "LDGCRM_application__c" `
    -CsvFile "data\salesforce-loads\LDGCRM_application__c-upsert.csv"
```

### ⚠️ Loading Contact requires disabling another app's Apex trigger

**Contact is the one object whose load flips a setting owned by a different application. Read this
before running it.**

gsa-peo is shared with the unrelated FCIC app, whose `GSA_FCIC_ContactTrigger` fires on every Contact
insert. Its before-insert path creates a **junk Account** — named after the person, hard-coded to the
`FCIC_Individual` Account record type — for **every Contact inserted with a blank `AccountId`**. None
of this is visible in `sfdx/force-app`: the manifest is LDGCRM-scoped, so other apps' automation was
never retrieved. It was found only because an 18-row test batch silently created 4 Accounts.

371 of the migrated Contacts have no resolvable Account (mostly the unmatched-Account data-quality
issue), so a normal load would create 371 junk Accounts in an org where Account counts are already a
moving target *and* where this migration's own Account reconciliation depends on those counts being
meaningful.

The FCIC app ships a supported kill switch — a `TriggerControls__c` custom setting the trigger checks
first — so `Invoke-SalesforceLoad.ps1` uses it via `-DisableTriggerControl`:

```powershell
scripts\powershell-scripts\Invoke-SalesforceLoad.ps1 `
    -ObjectApiName "Contact" `
    -CsvFile "data\salesforce-loads\Contact-upsert.csv" `
    -DisableTriggerControl "Contact"
```

What that flag does, and the guarantees around it:
1. Reads and **records the current value** before changing anything (it does not assume "on").
2. Switches it off, runs the load.
3. **Restores it in a `finally` block** — so it is restored even if the load throws, the CLI dies, or
   the operator interrupts. This is not theoretical: the real Contact load *did* exit non-zero (4
   duplicate-rule rejections) and the restore still ran.
4. **Verifies the restore with a re-query** and prints a loud, explicit manual-fix command if it
   fails. Leaving FCIC's trigger disabled would silently break another team's app.
5. It is **off by default** and should stay that way. It changes config another app owns, so it needs
   explicit human sign-off per load.

Confirmed after the real load: **zero junk Accounts created** (org total held at 1,350) and
`TriggerControls__c.Contact.On__c` back to `true`.

**Not covered by any of this:** the *other* active Contact trigger, `purecloud.ContactWebHookv1`,
belongs to an installed **managed** package (Genesys PureCloud). Its body is hidden, it cannot be
retrieved, and it has no kill switch — so it fires on every Contact insert and **what it does is
unknowable from this repo**. It was user-confirmed inert in gsa-peo (2026-08-13). **Re-confirm before
any production run**: a webhook on Contact insert is an outward-facing side effect this pipeline
cannot inspect.

`Build-AccountReconciliation.ps1` is read-only against Salesforce (a single SOQL query) and only
writes local files:

- `scripts/data/salesforce-loads/Account-update.csv` — matched rows (`Id`, `LDGCRM_External_ID__c`,
  `LDGCRM_Market_Segment__r.LDGCRM_External_ID__c`, `Type`) ready for a Data Loader **update** (not
  upsert) once Stage 3 exists.
- `scripts/logs/data-migration/Account-reconciliation-unmatched-<timestamp>.csv` — Airtable rows with no
  confident Salesforce match, for human review.
- `scripts/logs/data-migration/Account-reconciliation-ambiguous-<timestamp>.csv` — Airtable rows matching
  more than one unclaimed Salesforce Account by name, for human review.

`Build-ImpedimentLoad.ps1` doesn't touch Salesforce at all (Impediment has no lookups to other
objects, so there's nothing to reconcile) and writes:

- `scripts/data/salesforce-loads/LDGCRM_Impediment__c-upsert.csv` — external-ID-keyed rows ready for a
  Data Loader upsert. Excludes `LDGCRM_Blocked_Revenue__c` (a roll-up Summary field Salesforce
  computes from `LDGCRM_Opportunity_Impediment__c` — writes to it are rejected) and maps
  Airtable's free-text `Category` column onto `LDGCRM_Category__c`'s restricted 3-value picklist
  via an explicit table in the script, since two of the three Airtable strings don't match the
  Salesforce values verbatim (`"Relationship Issue"` → `"Relationship issue"`, `"Issue on their
  end"` → `"Issue on partner end"`).
- `scripts/logs/data-migration/Impediment-skipped-<timestamp>.csv` — Airtable rows with no `Name` (2 of
  41, both otherwise-empty placeholder rows), skipped rather than loaded with a placeholder.
- `scripts/logs/data-migration/Impediment-unmapped-category-<timestamp>.csv` — rows whose Category value
  doesn't match the script's mapping table; loaded anyway with Category left blank rather than
  blocked, but flagged for human review.

`Build-PartnerAccountLoad.ps1` queries Salesforce once (to resolve `Account Owner` emails to `User`
records — see `TRANSFORMATION-RULES.md` for why that lookup can't use the usual external-ID
passthrough) and writes:

- `scripts/data/salesforce-loads/LDGCRM_Partner_Account__c-upsert.csv` — external-ID-keyed rows. Requires
  `Account-update.csv` already loaded first (`LDGCRM_Account__c` is Master-Detail to Account).
- `scripts/logs/data-migration/PartnerAccount-skipped-<timestamp>.csv` — rows with no parent Account, or
  more than one (Master-Detail only supports one parent).
- `scripts/logs/data-migration/PartnerAccount-unmapped-owner-<timestamp>.csv` — rows whose owner email
  matches no Salesforce User; loaded anyway with Owner left blank.

`Build-ApplicationLoad.ps1` queries Salesforce twice — for the Partner Accounts and Opportunities
that actually exist — so it can skip rows that would be guaranteed load failures instead of
submitting them (the first load attempt submitted 442 such rows and got 442 errors back). It writes:

- `scripts/data/salesforce-loads/LDGCRM_application__c-upsert.csv` — external-ID-keyed rows whose parent
  Partner Account is confirmed present in the org. Deliberately does **not** include
  `LDGCRM_Broker_App_Parent__c` — that goes in the auto-generated second-pass file below.
- `scripts/data/salesforce-loads/LDGCRM_application__c-broker-parent-upsert.csv` — the **second pass**
  (63 rows), written automatically. Load it *after* the main Application file; see "Load order".
- `scripts/logs/data-migration/Application-broker-parent-skipped-<timestamp>.csv` — Broker App Parent links
  not emitted: one side withheld by the Account data-quality issue, or a self-reference.
- `scripts/logs/data-migration/Application-skipped-<timestamp>.csv` — rows skipped for a missing required
  Partner Account, split by reason: no Partner Account linked in Airtable at all, vs. linked but not
  loaded in the org (the latter almost always traces to an unresolved Account — see
  `AIRTABLE-DATA-QUALITY-REQUESTS.md`).
- `scripts/logs/data-migration/Application-overlength-<timestamp>.csv` — values Salesforce can't store as-is:
  Names over 80 chars (truncated), URLs over 255 chars (blanked), and implausible dates (blanked).
  All three are platform limits, not fixable field metadata.
- `scripts/logs/data-migration/Application-unmapped-rampup-<timestamp>.csv` — rows whose Ramp Up Approach
  value doesn't map; loaded anyway with the field blank.

Re-running it is the intended way to pick up newly-fixed data: rows skipped for an unresolved parent,
and Opportunity links blanked because Opportunity wasn't loaded yet, both resolve on a later run with
no code change. **Demonstrated 2026-08-13**: loading Opportunity and re-running this script dropped
the blank-Opportunity-link count from 92 to 7 with no edits.

`Build-ContactLoad.ps1` queries Salesforce (record types, existing Contacts, Accounts, Partner
Accounts) and writes:

- `scripts/data/salesforce-loads/Contact-upsert.csv` — one row per **merged** Contact, not per Airtable row.
- `scripts/data/salesforce-loads/Contact-identity-map.csv` — **an input to the Application-Contact junction
  chunk, not a review file.** Maps every Airtable Contact record ID to the Contact that survived the
  merge. The junction chunk must use this rather than re-deriving the grouping, or the two can drift.
- `scripts/logs/data-migration/Contact-name-review-<ts>.csv` — every Contact whose name was recovered from an
  existing Salesforce Contact or replaced with its email address as a placeholder.
- `scripts/logs/data-migration/Contact-no-account-<ts>.csv` — Contacts with no resolvable Account (each one
  would spawn a junk FCIC Account if the trigger weren't bypassed).
- `scripts/logs/data-migration/Contact-value-review-<ts>.csv` — dropped `Subscription Type` values.

`Build-OpportunityLoad.ps1` queries Salesforce for the Login_gov RecordTypeId and the reconciled
Account set (read-only), then writes:

- `scripts/data/salesforce-loads/Opportunity-upsert.csv` — external-ID-keyed rows. **Requires
  `Account-update.csv` loaded first**; rows whose Account isn't reconciled are skipped, not blanked,
  because an unresolvable lookup fails the whole row.
- `scripts/logs/data-migration/Opportunity-skipped-<timestamp>.csv` — split by reason: no Status (StageName is
  required with no default), no Account link in Airtable, or Account not reconciled in the org.
- `scripts/logs/data-migration/Opportunity-closedate-fallback-<timestamp>.csv` — **read this one.** Salesforce
  requires `CloseDate` but only 199 of 928 rows have a real `Est. Go Live`, so the rest fall back to
  the last status-change date, then the created date. Every fallback row is listed here with the field
  used, so a synthesized date is never mistaken for a forecast.
- `scripts/logs/data-migration/Opportunity-value-review-<timestamp>.csv` — values blanked or dropped
  (non-URL text in Url fields, over-length URLs, unmappable Focus Level or Demographic values).

See the full mapping table and current sandbox-state notes in the root `CLAUDE.md` under
"Airtable → Salesforce mapping".
